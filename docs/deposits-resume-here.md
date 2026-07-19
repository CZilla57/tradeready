# Deposits & Partial Payments — Resume Here

**Status as of 2026-07-18:** Phases 1, 2, 2b, 3 and 4 are built and green on branch
`feat/deposits-partial-payments` (37 commits off `master` @ `78383e3`).
**Nothing is merged, nothing is pushed, the Supabase migration is NOT applied,
and the backend is NOT deployed.**

Gate at last check: **1014 tests / 61 suites, tsc 0 errors, lint 0 warnings.**

This document exists because the detailed working notes live in
`.superpowers/sdd/progress.md`, which is git-ignored scratch — a `git clean -fdx`
destroys it. Everything below is the part you cannot afford to lose.

---

## 1. Read this before shipping ANY build off this branch

**The client half of this work is already live code.** `mergeRemoteRecord` is
wired into `pullRemote` (`utils/sync.ts:162`). On every pull of a changed
invoice that has a local copy, `mergePaymentLedgers` returns
`withDerivedPaidFields(remote, merged)` — which writes a `payments` array onto
the record. A legacy paid invoice gains `[legacy_<id>]`; an unpaid one gains
`[]`. That shape then propagates to the cloud on the next save.

The results are numerically identical to today (verified: the legacy entry is
dated `paidAt || due`, which is exactly the bucketing every money surface
already used). But it is a silent data-shape rewrite shipping to users for a
feature that does not exist yet.

**So: do not ship a build or OTA off this branch until you are actually
building the recording UI.** Merging for tidiness is fine; shipping is the
thing to hold.

## 2. What is actually built

| Phase | What it did | State |
|---|---|---|
| 1 | Payment ledger model + `utils/invoicePayments.ts` (all payment math) + legacy-equivalence tests | Complete, inert (no UI) |
| 2 | `pullRemote` unions invoice ledgers instead of replacing (`utils/syncMerge.ts`) | Complete, **live on pull** |
| 2b | Void-not-delete, Postgres union trigger, webhook ledger append, ledger-aware cron, backend math mirror | Complete, **not applied / not deployed** |

Design decisions that are load-bearing and non-obvious:

- **Deletion is a one-way `voidedAt` flag, never removal.** A server-side union
  cannot distinguish "a payment I don't know about" from "one I deleted", so
  deletion has to be data. Void is irreversible — that is what makes the union
  commutative. To correct a void, record a new payment.
- **`paidAt` is derived in chronological order**, not insertion order. A
  backdated payment must not report an invoice settled before all the money
  arrived.
- **The Postgres trigger is deliberately dumb** — it unions the payments array
  and nothing else. No `paid`, no `paidAt`, no epsilon. Those rules live in
  `utils/invoicePayments.ts` and its mirror `backend/lib/paymentMath.js`,
  pinned together by `__tests__/paymentMathParity.test.js`. Do not reproduce
  money rules in SQL.
- **Legacy invoices must derive identically.** No data migration was needed
  because `amountPaid` falls back to `paid`/`amount` whenever the ledger is
  empty. Nothing may stamp `payments: []` onto rows that lack the key.

## 3. Defects gating the recording UI (Phase 3)

### 3a. `updated_at: item.ts` hiding saved payments — FIXED 2026-07-18 (`e386b7d`)

`pushQueue` stamped the **save** time rather than the push time, while
`pullRemote` filters `gt('updated_at', since)`.

Sequence that broke: user saves at 10:00 (item stamped 10:00) → that push fails
→ a later pull advances `lastSynced` to 11:00 → the Stripe webhook appends a
payment at 11:30 → the queued item retries at 12:00. The union trigger
preserves the money, but the row lands stamped **backwards to 10:00**, so every
subsequent pull skips it and the device never learns about the payment.

Fixed at all four `pushQueue` sites (settings, customer_notes, the collection
tables, and the soft-delete) by stamping a `pushedAt` computed once per item.
`item.ts` still records when the user saved; only the `updated_at` COLUMN
changed. Note this made `pushQueue` consistent with `pushAllLocalToCloud`,
which already used push time.

The bug was not invoice-specific — a backdated stamp could make ANY table's
late push invisible to a second device's pull, permanently.

### 3b. `markPaid` writing a bare `paid: true` — FIXED 2026-07-18 (Phase 3)

```js
const updated = invoices.map((i) => (i.id === id ? { ...i, paid: true, paidAt: today } : i));
```

This is the same defect class the webhook had, on the device. Once an invoice
has any recorded payment, `materializeLegacyLedger` stops synthesizing, so the
next sync's merge derives `paid: false` and **silently reverts the tap** — and
the ledger-derived cron then dunns a customer the tradesperson just marked as
paid in cash.

**Fix:** `applyPayment(invoice, { id: newPaymentId(), amount: balanceDue(invoice), date: today, method: 'other' })`.
Put this on Phase 3's task list.

## 4. Owner actions before applying — order matters

**Never deploy the backend before applying the migration.** That direction is
strictly worse than doing nothing: the webhook would write real ledger arrays
into unprotected rows while the fielded app has no `payments` awareness at all.

1. **Confirm the schema.** Run `\d public.invoices` and check the `id` column
   type and the primary-key conflict target. This is **inferred, not
   confirmed** — the six collection tables predate `supabase/migrations/`, so
   no `CREATE TABLE` exists in the repo. The migration does not depend on it;
   the verification script does (it uses literal text ids and
   `on conflict (id)`).
2. **Apply** `supabase/migrations/20260718_invoice_payment_merge.sql`. It is
   idempotent and no-ops on every existing row (nothing in production carries a
   `payments` key).
3. **Verify:** `psql -v ON_ERROR_STOP=1 "$DATABASE_URL" -f supabase/migrations/verify/20260718_invoice_payment_merge_verify.sql`
   - `ON_ERROR_STOP=1` is not optional — without it psql exits 0 even when a
     check raises, so a failure reads as a pass.
   - **psql only.** Do not paste into the Supabase SQL editor; per-statement
     autocommit may leave the seeded `verify_trigger_*` rows in production
     despite the trailing `rollback`.
4. **Deploy the backend** (webhook + cron).
5. **Flip the README** "Ledger union (PENDING)" block from future to present
   tense and drop its "does NOT yet exist" note.

**Rollback** is documented at the end of the migration file. Note it is not a
full undo: rows the trigger already processed keep their written `payments`
key. That is benign — the client keys the legacy fallback off ledger *length*,
not key presence — but "roll back" does not mean "return to the prior state".

## 5. Known scope boundaries (not bugs — do not "fix" without thinking)

- **The union protects recorded ledger entries, not a legacy invoice's implied
  payment.** That payment is not data; it is the absence of a ledger plus
  `paid: true`. Two legacy copies still resolve last-write-wins, and legacy
  invoices are ~100% of production data today. Structurally unfixable by a dumb
  union.
- **The trigger emits id-ordered arrays; the client canonicalises to
  `(date, id)`.** Traced and benign — the client re-sorts on every pull and
  `paidAt` derivation is order-independent. Do not "fix" the SQL sort to match;
  that would imply the two orderings are pinned together when they are not.
- **`paymentsInRange` deliberately RETURNS voided payments** (a history UI needs
  to render them struck through) while `collectedInRange` skips them. The
  asymmetry is intentional.
- **The webhook dates payments in UTC** while the device uses local dates. Near
  midnight at a large offset a payment can land in the adjacent day, which can
  shift a month boundary. The server does not know the user's timezone.
- **`pullRemote`'s `remote.deleted` branch still drops local payments outright**
  (carried finding M7). Usually masked by push-before-pull resurrecting the row.
- **`pullRemote` writes merged records straight to AsyncStorage**, bypassing the
  sync queue, so a successful union is never re-enqueued (carried finding I5).
  The cloud converges only when the user next saves. Design this together with
  any further sync work, not before.

## 6. Branch and merge status

Three unmerged branches sit off `master` @ `78383e3`:

| Branch | PR | Overlap with this branch |
|---|---|---|
| `feat/deposits-partial-payments` | none | — |
| `feat/appointment-reminders` | #3 | `types/models.ts` only |
| `feat/estimate-approval-loop` | #4 | `types/models.ts`, `README.md`, `ARCHITECTURE.md` |

Conflict risk is **low**. All three touch different regions of `models.ts`:
appointment at the `Settings` interface (~329), estimate at the `JobStatus`
union (~23) and after `TimeSession` (~78), this branch just before `Invoice`
(~158). The tightest gap is `README.md`, where estimate-approval adds at ~327
and this branch rewrote the conflict-resolution paragraph at ~307–311 — about
16 lines apart, so likely clean.

The longer three branches sit off one base, the more that changes.

## 7. Where the detail lives

`.superpowers/sdd/progress.md` (**git-ignored scratch — not durable**) carries
the full per-task record: every review finding, every mutation check and its
output, what was rejected and why. If it is gone, `git log` on this branch is
the fallback — the commit messages were written to carry their own reasoning.

Specs and plans, which ARE committed:
- `docs/superpowers/specs/2026-07-18-deposits-partial-payments-design.md`
- `docs/superpowers/plans/2026-07-18-deposits-phase-1-model-and-derivations.md`
- `docs/superpowers/plans/2026-07-18-deposits-phase-2-sync-merge.md`
- `docs/superpowers/specs/2026-07-18-server-side-ledger-merge-design.md`
- `docs/superpowers/plans/2026-07-18-server-side-ledger-merge.md`

Remaining roadmap phases (3–6 of the original plan): the recording UI, the
Money-tab analytics sweep (~12 call sites), deposit requests with partial Stripe
links, and the PDF. See the phase table in the Phase-1 plan.
