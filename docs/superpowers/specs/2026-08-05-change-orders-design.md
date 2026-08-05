# Change Orders — Design Spec

**Date:** 2026-08-05
**Status:** Design approved in sections (owner, 2026-08-05); spec pending owner review
**Origin:** Owner request — "scope changes documented and approved before extra
work begins," fitting the existing estimate-approval and payment-ledger
infrastructure.

## 1. Goal

Let a tradesperson document a mid-job scope change ("found rotted subfloor,
+$850"), get the customer's sign-off **before** doing the extra work, and have
the approved amount flow automatically into billing. The paper trail — what was
approved, by whom, when — is the point: it's what makes the extra charge
defensible in a dispute.

**Owner scope decisions (2026-08-05):**

- **Change orders only.** No new progress-billing mechanism — deposits,
  partial payments, pre-work invoices, and finalize already cover collection.
  Approved change orders simply raise the job's billable total and ride the
  existing machinery.
- **Both approval paths:** a customer-facing e-sign link (reusing the shipped
  estimate-approval flow) AND a manual on-site record ("verbal OK"), mirroring
  the manual-mark-paid vs Stripe-webhook duality.
- **Fast entry:** a change order is title + description + amount. No mini
  pricing calculator in v1 (the calculator remains available separately).
  Negative amounts are allowed — a descope credit.
- **Architecture A:** change orders live as an array on the Job blob. No new
  collection, no Supabase migration, no new Vercel function.

## 2. Data model (types/models.ts — additive, no migration)

```ts
/** Device-written record of an on-site (verbal) change-order decision. */
export interface ChangeOrderDecision {
  decision: "approved" | "declined";
  decidedAt: DateString;   // local "YYYY-MM-DD", device clock
  note?: string;           // e.g. "verbal OK on site"
}

/**
 * A documented scope change on a job. Approved change orders raise the job's
 * billable total (utils/changeOrders.ts jobBillableTotal); job.estimateTotal
 * itself is NEVER mutated — it stays the as-approved baseline that
 * computeEstimateBreakdown's residual math depends on.
 */
export interface ChangeOrder {
  id: string;              // co<timestamp>_<counter> (newCustomerId pattern)
  title: string;
  description?: string;
  /** Dollars. Negative = descope credit. */
  amount: number;
  createdAt: DateString;
  /**
   * Link-based approval. Reuses EstimateApproval VERBATIM (token, sentAt,
   * frozen snapshot, server-written decision/consentAt/signerName/ip/ua).
   * Written server-side only, exactly like Job.approval.
   */
  approval?: EstimateApproval;
  /**
   * On-site manual decision — device-written. Kept SEPARATE from `approval`
   * so the device never writes into the server-owned object.
   */
  manualDecision?: ChangeOrderDecision;
  /**
   * One-way cancel stamp (mirrors Payment.voidedAt). Cancelled COs stay in
   * the list as data and are excluded from billable totals. Nothing may
   * clear this field.
   */
  cancelledAt?: DateString;
}

// On Job:
changeOrders?: ChangeOrder[];   // absent on every pre-feature job — deliberate
```

**Derived status — never stored.** `changeOrderStatus(co)` in
`utils/changeOrders.ts`:

1. `cancelledAt` present → `cancelled`
2. `approval?.decision ?? manualDecision?.decision` = `approved` → `approved`;
   `declined` → `declined` (link decision wins if both exist — server-stamped
   consent is the stronger record)
3. `approval` present (link minted, no decision) → `awaiting`
4. otherwise → `pending`

**Mutability rules:**

- `pending` (never sent): editable, and may be hard-deleted (no paper trail
  exists yet).
- `awaiting`: may be cancelled (`cancelledAt`) or manually decided; not edited.
- `approved`: **immutable** — no edit, cancel, or delete. To reverse, add a
  negative CO (the ledger's void-then-record-new pattern).
- `declined` / `cancelled`: immutable history rows.

**Sync:** the Job blob syncs as JSON (storage-and-sync recipe) — a pure
additive shape change. Server writes into `changeOrders[i].approval` inherit
the same blob-level last-write-wins envelope the estimate approval already
accepted (a device edit racing a customer approval can clobber; rare,
self-healing on re-send). No new race class; no `payments`-style union merge
is added for COs in v1 — documented residual, same as `Job.approval` today.

## 3. Money: jobBillableTotal is the single source of truth

New `utils/changeOrders.ts`:

```ts
approvedChangeOrderTotal(job): number   // Σ amount of approved COs; 0 when absent
jobBillableTotal(job): number           // estimateTotal + approvedChangeOrderTotal
changeOrderStatus(co): "pending" | "awaiting" | "approved" | "declined" | "cancelled"
```

- Legacy jobs (`changeOrders` absent) return `estimateTotal` unchanged — zero
  behavior change, pinned by tests.
- Every surface that displays a job's value moves from `job.estimateTotal` to
  `jobBillableTotal(job)`: JobDetail, Jobs list rows, Today's job cards,
  `utils/businessSnapshot.ts` pipeline value. The exact sweep list is
  enumerated at plan time via `grep estimateTotal` across screens/components/
  utils (display reads only — the pricing engine's internal uses of
  `estimateTotal` stay).
- **`job.estimateTotal` is never mutated.** `computeEstimateBreakdown`'s
  overhead-residual math keys off it; COs are separate lines on top.
- A CO whose amount would push `jobBillableTotal` below $0 is blocked at save.

**Invoice integration (the progress-billing payoff):**

- `CreateInvoiceFromJobScreen` pre-fills `jobBillableTotal(job)` in all three
  modes (create / requestDeposit / finalize). A **finalize** on an early
  deposit invoice therefore automatically picks up COs approved mid-job.
- `buildInvoiceLineItems` (utils/autoInvoice.ts) appends one line per
  approved CO after the labor/materials/overhead lines:
  `{ description: "Change order — <title>", amount, category: "other" }`.
  The overhead residual stays computed against `estimateTotal`, so the lines
  still sum exactly to the billable total.
- The invoice PDF renders `lineItems` already → COs appear with no PDF-template
  work (golden fixtures updated to match).
- The auto-invoice-on-complete path (utils/autoInvoice.ts) bills
  `computeBillableBreakdown` + approved COs the same way.
- Deposits, draws, and balance are unchanged — they operate on the invoice
  ledger, which now just carries the right total. Edge: a finalize amount
  below `amountPaid` flips the invoice paid via the existing
  `reconcilePaidFields` (over-collection refunds are outside app scope, same
  as a manual amount edit today).

## 4. Approval path A — the link (remote e-sign)

Mirrors the shipped estimate loop end to end.

**Backend — two new ACTIONS on the existing `api/estimate/[action].js`
dispatcher** (function count stays 11 of 12), handlers in
`backend/lib/estimate/`:

| Action | Method | Auth | Behavior |
|---|---|---|---|
| `change-view` | GET | token | Sanitized read: the CO's frozen snapshot + context totals (see below) |
| `change-respond` | POST | token | Writes decision into `job.changeOrders[i].approval` — reuses the `nextApproval` merge semantics: terminal lock on `approved`, server-stamped `consentAt`, typed-name `signerName`, IP/UA capture |

- `create-link` (JWT-authed) gains an optional `changeOrderId` parameter: when
  present, it mints the token into that CO's `approval` instead of
  `job.approval`. Same `crypto.randomBytes` token, same `constantTimeEqual`
  comparison, same rate limiter and CORS allowlist.
- `change-respond` additionally refuses with **HTTP 409** ("This change was
  already decided.") when the CO carries a `manualDecision` — the customer
  can't override an on-site decision from a stale link.
- Snapshot is frozen at send (device-built, `EstimateApprovalSnapshot` reused
  verbatim: `lineItems: [{ label: co.title, amount }]`, `total: co.amount`,
  business/customer names) so the customer approves exactly what they saw.
- **Context totals are computed LIVE by `change-view`** from the job row at
  view time, not frozen: "Original" = `jobBillableTotal` excluding this CO
  (i.e. estimateTotal + other already-approved COs), "New total" = that plus
  this CO's amount. The frozen, signed thing is the CO itself; the context is
  informational and stays truthful when other COs are approved in between.
  (The backend gets a small mirrored billable-total helper in
  `backend/lib/estimate/` — backend/ is a separate CommonJS package — kept in
  sync by a parity test, matching the `jobDunningParity.test.js` convention.)
- The pure merge function is exported for unit tests, matching
  `respond.js`'s `nextApproval` convention.

**Customer page — `change.html`** in the tradeready-legal repo, cloned from
`estimate.html`'s structure: same `esc()` XSS discipline, same backend origin
and CORS story, quote-style money formatting (per the 2026-08-05 formatting
fix). Renders: business name, job title, CO title/description, and the
arithmetic — *Original: $2,400 · This change: +$850 · New total: $3,250* —
then Approve (typed name) / Decline. Held unpushed until the backend deploys
(established launch-chain order).

**Send flow:** the CO row's "Send for approval" mints the link then composes
SMS/email via the shared `composeEmail`/`composeSMS` primitives
(`change.html?j=<jobId>&co=<coId>&t=<hex>`), matching estimate-send wording.
Compose-availability failures fall back through the existing messaging Alert
path.

**No device reconciler.** Unlike estimates, a CO decision causes **no job
status transition** — the decision arriving via the normal `pullRemote` poll
IS the feature; JobDetail re-reads on focus. No push notification on approval
in v1 (same accepted gap as webhook payments; a Today insight is a natural
follow-up, out of scope here).

## 5. Approval path B — manual (customer on site)

- CO row actions **"Mark approved"** / **"Mark declined"** → confirm dialog
  with an optional note field → stamps `manualDecision` device-side.
- Available for `pending` and `awaiting` COs. Deciding an `awaiting` CO kills
  the outstanding link (see `change-respond`'s manualDecision refusal above).
- Fully offline-capable (local-first write; syncs like any job edit).

## 6. UI surfaces

- **JobDetail "Change orders" section**: visible when the job has any CO (at
  any job status — history survives through `paid`) or when one can be added.
  **Adding gated to `approved` / `scheduled` / `in_progress` / `complete`**
  (new `canAddChangeOrder(status)` in utils/changeOrders.ts): before approval
  there is no agreed baseline to change (revise the estimate instead — that
  flow exists); after `invoiced` the bill is final (extra work then = manual
  invoice edit or a new job).
- **Add/edit screen**: modal in JobStack (AddCustomer modal pattern). Three
  inputs via the shared `Field` component: title, description (prose field —
  autocorrect on per the Field defaults), amount (numeric, negatives allowed
  with a "descope credit" hint). Uses the standard createStyles theming
  factory.
- **CO rows**: title, `formatQuote(amount)` (proposed money → quote
  formatter), status `Badge` with semantic tokens — pending `muted`, awaiting
  `accent`, approved `success`, declined `danger`, cancelled `muted`. Row
  actions by derived status: Send for approval / Mark approved / Mark
  declined / Cancel / (pending only) Edit, Delete.
- **JobDetail money header** shows the arithmetic explicitly when COs exist:
  *Estimate $2,400 + Changes $850 = $3,250* — teach the number, don't
  silently swap it.
- Customer portal: COs are NOT shown in v1 (portal renders estimates +
  invoices only) — backlog note.
- Telemetry: PostHog events `change_order_created`,
  `change_order_sent`, `change_order_decided` (properties: decision, channel
  link|manual), following the existing event conventions.

## 7. Error handling

- Backend: 400 missing/invalid params, 404 invalid-token (constant-time
  compare, same wording as estimate handlers), 429 rate-limited, 409 on
  manually-decided COs.
- Legacy jobs: every helper treats absent `changeOrders` as empty — zero
  behavior change, pinned by tests.
- Offline: create/edit/manual-decide/cancel all work offline. Only link
  minting needs network; failure surfaces the existing Alert and leaves the
  CO `pending` (retry = tap Send again).
- Amount validation at save: parseable, non-zero, and billable total ≥ $0.

## 8. Testing

- **Unit — `__tests__/changeOrders.test.js`**: status derivation (all five
  states, link-beats-manual precedence), `approvedChangeOrderTotal` /
  `jobBillableTotal` (approved-only inclusion; declined/cancelled/awaiting
  excluded; negatives; absent-array legacy), `canAddChangeOrder` gating.
- **Backend**: pure merge function tests mirroring `nextApproval`'s
  conventions (terminal lock, manualDecision refusal, decline reason
  truncation); dispatcher route registration.
- **Integration**: `buildInvoiceLineItems` with approved COs (line content,
  category, sum equals billable total); CreateInvoiceFromJob finalize
  pre-fill; auto-invoice path.
- **PDF**: invoice golden fixtures regenerated for the CO line case.
- Gate (tsc / tests / lint) green at every commit, per change control.

## 9. Rollout chain (established order — no migration anywhere)

1. Build on a feature branch; gate green; owner review; merge.
2. Deploy backend (`npx vercel deploy --prod --yes` from `backend/` —
   verify branch first, per the 2026-07-30 lesson).
3. Push `change.html` to tradeready-legal (held until step 2 completes).
4. Owner device smoke: create CO → send link → approve on phone browser →
   pull → finalize invoice picks it up; plus manual path offline.
5. JS-only client changes ride the next OTA. Feature may be claimed in the
   listing only after step 4 (claims discipline).

## 10. Accepted residuals (documented, not bugs)

- Blob-level LWW can clobber a server CO decision with a concurrent device
  edit of the same job (same envelope as `Job.approval`; re-send heals).
- No push/local notification when a customer decides via link — surfaced on
  next JobDetail view. Today-insight follow-up is backlog.
- Portal does not show COs in v1.
- No calculator-assisted CO pricing in v1 (owner chose fast entry).
