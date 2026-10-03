# Good/Better/Best Quote Options (Roadmap Phase 25) — Design Spec

**Date:** 2026-10-02
**Status:** BUILT on local branch `feat/quote-options` (native + Worker) and `tradeready-legal` branch `feat/quote-options` (pages), 2026-10-02. Nothing pushed, deployed or applied; see §12 for the ship steps. (Owner go-ahead 2026-10-02: "scope out each feature first then begin the implementation".)
**Origin:** `docs/post-launch-feature-roadmap.md` Phase 25, build order #1
**Builds on:** estimate approval loop (`2026-07-17-estimate-approval-loop-design.md`), portal completion (`2026-08-07-portal-completion-design.md`), change orders (`2026-08-05-change-orders-design.md`)
**Build target (owner, 2026-10-02):** native SwiftUI app (`native/TradeReadyNative/`), the Worker (`backend-workers/`), and the public pages in the `CZilla57/tradeready-legal` repo. **No React Native changes.** The dormant Vercel twin (`backend/`) and the owner web app (`web/`) are not changed (see §10).

## 0. Preconditions verified against the repo (HEAD `52e9d09`)

- An estimate is a `Job`. Pricing inputs are the calculator-owned fields on `Canonical.Job` (`laborHours`, `laborBreakdown`, `laborRate`, `materials`, `materialMarkup`, `jobCosts`, `overhead`, `margin`); the engine result is stored as `estimateTotal` (`UIModelAdapters.swift` `canonical(from pricing:baseline:)`). There are no stored line items; customer lines are derived.
- Jobs sync as a whole JSON blob in `public.jobs.data`. A new optional job field needs **no migration**.
- The approval object lives in `jobs.data.approval`. The Worker trusts the device snapshot (`createLink.js`), spreads it into the view response (`view.js`), and drops unknown request fields in `respond.js`. `respond` writes with an unconditional upsert.
- Re-sending reuses the token and replaces the snapshot (`planApprovalWrite`), so a customer can approve a snapshot they never saw.
- **Native never applies a customer decision to `job.status`.** `JobLifecycleRules.statusAfterEstimateDecision` has no callers; native only offers the manual "Mark as approved by customer" step. RN's `applyEstimateDecisions` has no native port.
- The customer page `estimate.html` and `portal.html` live in `CZilla57/tradeready-legal` (static HTML + fetch).
- `feat/estimate-conditional-writes` is **not merged**; only `revise-declined` uses `updateJobIfUnchanged`.

## 1. Goal and scope

An estimate can carry **2–3 named tiers** (e.g. "Repair", "Standard unit", "High-efficiency unit") that the customer chooses between, plus **0–10 optional add-ons** the customer can tick. The server records exactly what was accepted inside the approval, and the device rebuilds job, invoice, deposit and profitability figures from that selection.

Non-goals: per-line customer editing, quantities on add-ons, tier-specific add-ons, a drag-and-drop tier builder, tax on add-ons (the add-on price is all-in), and changing tiers after approval (that's a change order).

## 2. Data model (additive-optional; absent = today's single-total estimate)

### 2.1 On the job: `quoteOptions`

```ts
// Job.quoteOptions?: QuoteOptions   — absent means a single-total estimate
interface QuoteOptions {
  tiers: QuoteTier[];            // 2..3, unique ids
  addOns: QuoteAddOn[];          // 0..10, unique ids
  recommendedTierId: string;     // must name a tier; the job's top-level pricing mirrors it until acceptance
  acceptance?: QuoteAcceptance;  // set once, when the customer's (or owner-recorded) choice is applied
}
interface QuoteTier {
  id: string;                    // "qt_<uuid>"
  name: string;                  // 1..60 chars, customer-facing
  description?: string;          // 0..300 chars, customer-facing
  // Calculator-owned pricing, same field names/types as Job:
  laborHours: number; laborBreakdown?: LaborTimeBreakdown; laborRate: number;
  materials: Material[]; materialMarkup: number; jobCosts?: JobCost[];
  overhead: number; margin: number;
  estimateTotal: number;         // PricingEngine.calculate(...).total for THIS tier — the tier's source of truth
}
interface QuoteAddOn {
  id: string;                    // "qa_<uuid>"
  label: string;                 // 1..80 chars
  description?: string;          // 0..200 chars
  price: number;                 // > 0, <= 1_000_000, cents precision; flat, not taxed separately
  cost?: number;                 // owner's internal cost for profitability; never sent to the customer
}
interface QuoteAcceptance {
  tierId: string;
  addOnIds: string[];
  total: number;                 // tier.estimateTotal(at send) + Σ add-on price, cents
  acceptedAt: string;            // ISO; approval.consentAt for link acceptance
  source: 'link' | 'owner';      // customer link vs owner recorded "they said yes on the phone"
}
```

**Invariant M1.** Before acceptance, the job's top-level calculator fields and `estimateTotal` equal the recommended tier. Every existing consumer (job list, insights, follow-up, profitability preview) keeps working and shows the recommended tier.

**Invariant M2.** After acceptance, the top-level calculator fields equal the accepted tier and `estimateTotal = acceptance.total`. That is the tier total plus the accepted add-ons, so change-order math (`estimateTotal + approved COs`, server `billableContext` too), invoice prefill and deposits all see the accepted price.

**Invariant M3.** `acceptance` is written once. A later re-application is a no-op. Options are read-only in the UI once `acceptance` exists or `approval.decision == "approved"`.

Duplicating a job copies `quoteOptions` without `acceptance` (added to the `duplicateJob` whitelist).

### 2.2 In the frozen snapshot: `snapshot.options`

```ts
// EstimateApprovalSnapshot.options?: SnapshotOptions
interface SnapshotOptions {
  tiers: { id: string; name: string; description?: string;
           lineItems: { label: string; amount: number }[]; total: number }[];
  addOns: { id: string; label: string; description?: string; amount: number }[];
  recommendedTierId: string;
}
```

- Each tier's `lineItems` use exactly today's derivation (`estimateApprovalSnapshot`): labor, materials, customer-visible direct costs, and a residual "Overhead & operating costs" line. The derivation runs on that tier's pricing, so internal cost policy stays hidden.
- **Compatibility:** top-level `lineItems`/`total` are the recommended tier's. Old readers (portal list, web owner app, the current `estimate.html`) see a coherent single estimate.
- Add-on `cost` is never in the snapshot.

### 2.3 In the approval: `approval.selection` (server-written only)

```ts
interface EstimateSelection {
  tierId: string; tierName: string;
  addOnIds: string[];                          // order follows snapshot.options.addOns
  addOns: { id: string; label: string; amount: number }[];
  lineItems: { label: string; amount: number }[];   // tier lines + one line per add-on
  total: number;                               // cents-rounded tier.total + Σ add-on amounts
}
```

Written by `respond` on approve, only for snapshots with `options`. It sits under the existing terminal lock: once `decision == "approved"`, nothing changes.

## 3. Shared arithmetic (parity contract)

`selectionTotal = round2( cents(tier.total) + Σ cents(addOn.amount) ) / 100`, computed in integer cents on both sides. Validation rules (both sides):

| Rule | Error |
|---|---|
| snapshot has `options` and decision is approve, but `tierId` is missing or unknown | 400 `Please choose an option.` |
| `addOnIds` not an array of strings, > 10, or contains an unknown id | 400 `Invalid add-on selection.` |
| duplicate add-on ids | de-duplicated silently |

The vectors live in **one shared fixture** that both test suites load: `native/QuoteOptionsTests/Fixtures/quote-selection-vectors.json`, read by the Swift suite and by `backend-workers/tests/quoteOptions.test.cjs`.

## 4. Worker changes (`backend-workers/`)

New pure module `lib/estimate/quoteOptions.js` (CommonJS like `estimateStore.js`):
- `validateSnapshotOptions(snapshot)` checks the shape and limits from §2.2. It returns `null` or an error string. 2–3 tiers with unique ids, finite non-negative totals and line amounts, string length caps, ≤10 add-ons with unique ids and amounts > 0, and `recommendedTierId` must name a tier.
- `snapshotDigest(snapshot)` is the SHA-256 hex of a canonical (recursively key-sorted) JSON encoding. It uses `node:crypto`, which the Worker already uses for `randomBytes`.
- `resolveSelection(snapshot, input)` returns `{ selection }` or `{ error }`, per §3.

Route changes:
1. **`create-link`**: if `snapshot.options` is present, run `validateSnapshotOptions`; return 400 on failure. Legacy snapshots are unchanged.
2. **`view`**: add `snapshotDigest` and, when approved, the stored `selection` to the response. The existing spread is unchanged.
3. **`respond`**: the body gains `selection: { tierId, addOnIds }` and `snapshotDigest`.
   - If the snapshot has `options`, `snapshotDigest` is **required** and must match. On mismatch it returns 409 `This estimate was just updated. Please reload the page to see the latest version.`
   - For legacy snapshots the digest is checked only when sent.
   - On approve with options, `nextApproval` also stores `selection`. `nextApproval` keeps its signature and stays usable by `change-respond`; `selection` is only written when passed.
   - **The write becomes conditional:** `updateJobIfUnchanged` on the read `updated_at`, with up to 3 read-validate-merge-write attempts. If all three conflict, it returns 409 `Please try again in a moment.` This removes the lost-update window where a concurrent device push and a customer approval race on the same blob.
4. **Portal** (`lib/estimate/portalAssemble.js` `buildEstimates`) adds `hasOptions` (boolean). `total` becomes `selection.total` when an accepted selection exists; otherwise, for option snapshots, the **lowest** tier total (the page shows "From $X"). Legacy behavior is unchanged. The allowlist test is updated for the new key.

## 5. Public pages (`tradeready-legal`)

- **`estimate.html`**
  - When `options` is present, it renders tier cards as a radio group. The recommended tier is pre-selected and badged "Recommended". Each card shows its name, description, lines and total.
  - Add-ons are checkboxes with label, description and price.
  - A live "Your total" is computed with the same cents math as the server.
  - Approve posts `selection` and `snapshotDigest`. On 409 it shows a reload banner.
  - The approved banner names the chosen option and total from `view.selection`.
  - The legacy single-total rendering is unchanged.
- **`portal.html`** shows "From $X · N options" when `hasOptions` and the estimate is undecided.

## 6. Native changes (`native/TradeReadyNative/`)

**6.1 Canonical models.**
- `Canonical.QuoteOptions`, `QuoteTier`, `QuoteAddOn` and `QuoteAcceptance` follow the `ObjectReader`/`ObjectWriter` preservation pattern.
- `Canonical.Job.quoteOptions`.
- `EstimateApprovalSnapshot.options` (typed) and `EstimateApproval.selection` (typed).
- `estimateApprovalSnapshotsMatch` and `estimateApprovalsMatch` compare the new typed fields.
- Fixtures: `canonical-rich.json` gains a job with options and an approved selection.

**6.2 Pure domain (`Domain/NativeQuoteOptions.swift`).**
- Start options from the current pricing: tier 1 is the job's pricing ("Good"), tier 2 is a duplicate ("Better").
- Duplicate a tier (max 3), delete a tier (min 2; removing down to one is "remove options", which keeps that tier's pricing as the job's), rename and describe a tier, and set the recommended tier. Setting the recommended tier also mirrors its pricing into the job, per M1.
- Add-on create, edit and delete with §2.1 validation.
- `tierPricingSaved(job, tierId, draft)`:
  - Writes the tier's calculator fields and `estimateTotal = PricingEngine.calculate(draft.input).total`.
  - If the tier is recommended (pre-acceptance) or accepted (post-acceptance), it also mirrors the fields into the job.
  - Post-acceptance, `estimateTotal = tier total + accepted add-ons`.
- `snapshotOptions(job)` builds §2.2 from the tiers.
- `selectionTotal(...)` implements §3.
- `applyAcceptance(job, tierId, addOnIds, acceptedAt, source, consentedTotal?)` implements M2. For a link acceptance the consented total is `approval.selection.total`. It is the price the customer agreed to, even if the tier was edited after sending.
- Invoice add-on lines and profitability add-on cost (see 6.4).

**6.3 Decision reconciler (closes the parity gap).** It runs after every successful pull. For each non-deleted job with `approval.decision`:
- **Status:**
  - From `lead` or `estimate_sent`, an approval moves the job to `statusAfterEstimateDecision` (approved), and a decline moves it to declined.
  - It never moves a job backwards, and it does nothing in any other status.
- **Selection:** if the decision is approved, `approval.selection` exists, `quoteOptions` exists and `acceptance` is absent, it runs `applyAcceptance(source: link, consentedTotal: selection.total)`. If the tier id no longer exists on the job, it still sets `estimateTotal = selection.total` and records the acceptance. The pricing fields stay as they are, and the consented price wins.
- It is idempotent and saves and queues an upsert only when something changed.
- **Rebase graft:** when a pulled job and a pending local job share the same `approval.token` and the server copy has a `decision` the local copy lacks, the server's `approval` (and any longer `approvalHistory`) is grafted onto the local pending record before it is pushed. Server-only fields are never device-authored, so the graft is always safe, and it stops a queued local edit from erasing a customer's decision.

**6.4 Consumers.**
- **Snapshot builder** (`estimateApprovalSnapshot`):
  - With options and no acceptance, it adds `options`, and the top level is the recommended tier.
  - With acceptance, it produces a single estimate of the accepted tier plus one line per accepted add-on. Accepted add-ons are subtracted before the residual line.
- **Review sheet, PDF, message drafting:**
  - Before acceptance they show every tier (name, description, lines, total) and the add-ons.
  - The text message says "View your options and approve" with a link. Without a link it says "Reply with the option you'd like".
  - After acceptance they show only the chosen option.
- **Invoice from job:** `computeBillableBreakdown` takes accepted add-on lines. They are subtracted before the residual overhead line and appended as their own invoice lines.
- **Profitability:** the estimated direct cost includes Σ accepted add-on `cost` (when set).
- **Manual approval:** "Mark as approved by customer" on a job with options opens a picker for the tier and add-ons. It records `acceptance(source: owner)` and advances status in one commit.
- **Estimate follow-up copy:** for undecided options the text reads "your quote options (from $X)".

**6.5 Owner UX.**
- **Entry point:** job detail, pricing section, a "Good / better / best options" row. It is shown for `lead` and `estimate_sent` while undecided, and read-only afterwards.
- **`NativeQuoteOptionsView`:**
  - Tier rows: name and description fields, total, a Recommended toggle, "Edit pricing" (opens the existing `NativePricingCalculatorView` in tier mode, saved through `store.saveQuoteTierPricing`), Duplicate, and Delete.
  - An add-on list with a sheet editor.
  - "Remove options".
- The fast path is the kickoff's "duplicate this estimate as a tier": start options, then edit tier 2's pricing.

## 7. Interactions

| Situation | Behavior |
|---|---|
| Owner edits options after sending, then re-sends | New snapshot and the same token. The page's digest goes stale, so respond returns 409 and the customer reloads. |
| Owner edits options after sending without re-sending | The customer accepts the sent snapshot. The device applies `selection.total` as the consented price, and the residual line absorbs any drift. |
| Declined, then revised | `revise-declined` archives the approval and the options stay on the job for revision. Re-send is blocked until the snapshot changes (existing rule). |
| Change orders | Allowed only after approval (existing rule). The baseline is `estimateTotal`, which includes accepted add-ons. |
| Deposits | Requested on the invoice created from the job, so they follow the accepted total. |
| Recurring jobs | Copy `estimateTotal` only, not `quoteOptions`. |
| Old native build reading a new job | `quoteOptions`, `snapshot.options` and `approval.selection` round-trip as preserved unknown fields. |

## 8. Testing

- **Swift `QuoteOptionsTests`** (new runner `native/run-quote-options-tests.sh`, registered in `run-all-domain-tests.sh`):
  - Per-tier engine goldens: three tiers with distinct inputs, each with a hand-computed total.
  - Invariants M1–M3.
  - Snapshot options shape (no `cost` leak, recommended tier at the top level).
  - Selection vectors from the shared fixture.
  - `applyAcceptance`, including tier drift and a missing tier.
  - The reconciler: status forward-only, idempotent, selection applied once.
  - Invoice add-on lines and the residual line.
  - Profitability add-on cost.
  - Duplicate whitelist.
- **Existing suites updated:** canonical fixtures and round-trip, adapter snapshot match, estimate PDF, message drafting, store integration.
- **Worker `node:test`** (`backend-workers/tests/quoteOptions.test.cjs`): validation, digest stability (key order independent), `resolveSelection` against the shared vectors, the `nextApproval` selection merge and lock, and the respond handler's conditional-write retry and 409 paths with a stubbed `fetch`.
- **Root Jest Worker tests** (`__tests__/portalAssembleWorkers.test.js`): the allowlist is updated for `hasOptions`, plus the accepted and from-total cases.
- **Gates:** `sh native/run-all-domain-tests.sh`, `cd backend-workers && npm test && npm run check`, the targeted Jest Worker tests, the Release `xcodebuild` compile, and `sh native/run-doc-reference-check.sh`.

## 9. Rollout order

1. Worker deploy. It is backward compatible: no option snapshots exist yet and legacy flows are unchanged.
2. `tradeready-legal` pages.
3. The native build.

Deploys are the owner's. Nothing here is deployed or pushed.

## 10. Accepted residuals

- **Vercel twin (`backend/lib/estimate/*`)** is not updated. A rollback to Vercel would accept approvals without recording a selection. The device would then still advance the status but would not apply a tier, and the job keeps the recommended tier.
- **Owner web app (`web/`)** keeps rendering the top-level (recommended) lines. It is not changed in this phase.
- **Pre-existing:** the calculator does not persist `travelMiles`, `isEmergency` or `taxPercent`, so their effect survives only inside a stored total. That's true for tiers exactly as it is for single estimates today.
- **The device push stays a whole-blob LWW upsert, and sync pushes before it pulls.** The rebase graft (6.3) alone can't stop a queued edit from erasing a decision.
  - The server-side guard is a new `jobs` trigger in `supabase/migrations/20261002_job_approval_preserve.sql`, modeled on the invoice-payment merge.
  - When the approval token is unchanged, it keeps the server-owned decision fields: decision, consentAt, signer, decline reason, ip/UA and selection, plus the frozen snapshot once approved. This applies to estimates and change orders.
  - It is verified on a throwaway local Postgres (`supabase/verify/`). **The owner applies it before shipping the native build.**
  - General conditional device writes remain the unmerged `feat/estimate-conditional-writes` work.

## 11. Owner decisions recorded

| # | Decision | Choice |
|---|---|---|
| D1 | New synced field `Job.quoteOptions` | Additive JSON-blob field, no migration |
| D2 | Add-on pricing | Flat, all-in (not taxed separately); optional internal cost |
| D3 | Limits | 2–3 tiers, ≤10 add-ons |
| D4 | `respond` write | Conditional (`updateJobIfUnchanged`) with bounded retry |
| D5 | Stale-page protection | Snapshot digest required for option estimates |
| D6 | Native decision reconciler | Built here (closes the RN parity gap) |
| D7 | Server-side approval preservation | New `jobs` trigger migration (file only; owner applies) |

## 12. Build record (2026-10-02)

**Built (native, `feat/quote-options`):**
- Canonical types, the pure domain (`Domain/NativeQuoteOptions.swift`) and the consumers in §6.4: snapshot builder, invoice add-on lines, profitability add-on cost, duplicate whitelist, recurring copy.
- `AppStore` wiring:
  - Option edits all go through `mutateQuoteOptions`, which refuses unless `NativeQuoteOptions.isEditable` holds (lead or sent estimate, not read-only).
  - `saveQuoteTierPricing` saves a tier's calculator draft.
  - `recordOwnerQuoteAcceptance` records `source: owner` and approves the job in one commit.
  - `reconcileEstimateDecisions` runs after every committed delta pull, after the initial sync, at a returning-user launch and after a refused job change is discarded. It is gated like recurring generation and skips refused records.
  - The rebase graft runs inside the pull commit for jobs whose change is still queued. It also rewrites that queued upsert (keeping its guard), so the push carries the decision even when the reconciler has nothing to change.
- SwiftUI:
  - `NativeQuoteOptionsView.swift`: the options sheet, the add-on editor and the owner-choice picker.
  - The calculator gains a tier mode (`NativePricingCalculatorView(draft:tierID:tierName:)`).
  - Job detail gains the options row, and "Mark as approved by customer" opens the picker when options are open.
- Customer documents: the review sheet, PDF, message drafts and follow-up copy, per §6.4.
- Tests:
  - `native/run-quote-options-tests.sh` covers the pure domain.
  - `native/run-quote-options-store-tests.sh` covers the store over the in-memory Supabase server: edits and refusals, the owner choice, the reconciler through a real pull, and both halves of the graft (each verified to fail when its half is disabled).
  - The estimate PDF, message-draft and follow-up suites gained option cases.

**Built (Worker):** §4, with `backend-workers/tests/quoteOptions.test.cjs` and the root Jest portal test.

**Built (`tradeready-legal`, branch `feat/quote-options`):** `estimate.html` and `portal.html` per §5. They were checked headlessly (jsdom, stubbed API):
- tier and add-on totals use the server's cent math
- the respond body is `{…, snapshotDigest, selection: {tierId, addOnIds}}`
- 409 shows the reload banner
- decline sends the digest and no selection
- the approved view names the option
- markup in names is escaped

**Ship steps (owner; order matters):**
1. Run `sh supabase/verify/job_approval_preserve.sh`, then apply `supabase/migrations/20261002_job_approval_preserve.sql`. This is the release-checklist blocker.
2. Deploy the Worker.
3. Publish the `tradeready-legal` pages. **Before any native build that can send options:** the old `estimate.html` posts no `selection`, so the Worker refuses an approval of an options estimate with 400 "Please choose an option."
4. Ship the native build.

**Residuals found while building:**
- If the owner records a choice on the phone while the customer approves a *different* option through the link before the phone has pulled, the first acceptance stays (M3). The owner's pick is kept and the customer's `approval.selection` is still preserved and shown in history. That is the narrow race the manual-approval path has always had. The picker refuses once the customer's approval is on the device.
- A job approved through the link while it sat in `declined` (the page lets a customer approve after declining) keeps its `declined` status. The reconciler only moves `lead`/`estimate_sent` forward (`JobLifecycleRules.statusAfterEstimateDecision`), so the owner sees the decision in the estimate history and revises from there. This is unchanged from the pre-existing rule.

