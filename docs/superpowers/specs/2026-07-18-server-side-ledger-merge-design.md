# Server-Side Ledger Merge + Webhook Append — Design

**Date:** 2026-07-18
**Branch:** `feat/deposits-partial-payments`
**Status:** design approved, implementation not started
**Supersedes part of:** `2026-07-18-deposits-partial-payments-design.md` §"Sync and webhook", which prescribed only a pull-side fix

## Problem

Phase 2 made `pullRemote` union invoice payment ledgers, protecting the DEVICE copy. The final phase review found that fixes half the problem, and left two ways money still disappears.

**C1 — the push path still clobbers.** `enqueueCollectionChanges` (`utils/sync.ts:48`) queues an upsert for EVERY invoice whenever any invoice is saved, each carrying a frozen full blob. `pushQueue` (`utils/sync.ts:102`) does a blind `data: item.payload` upsert stamped `updated_at: item.ts` — the save time. So a payment the Stripe webhook wrote to the cloud is destroyed when the device later saves any invoice, and because `updated_at` predates the webhook write, the `gt('updated_at', since)` filter can skip the row so the corruption is never pulled back. The window is not "two devices edit the same invoice" — it is "the device saves anything after the webhook fires."

**C2 — the webhook erases Stripe payments once a ledger exists.** `mergePaymentLedgers` recomputes `paid` from the ledger and discards the remote scalar. Today's webhook writes `{...data, paid: true, paidAt}` with no ledger entry. With no ledger this happens to work — `materializeLegacyLedger` synthesizes the full amount. But once an invoice has even one recorded payment, that synthesis short-circuits: the customer pays the balance by Stripe link, the webhook sets `paid: true`, the device pulls, and the merge derives `paid: false` and deletes `paidAt`. The Stripe payment is erased and a false receivable appears.

C2 makes this work a hard prerequisite for Phase 3 (the recording UI), which is what first makes a ledger exist.

## Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Deletion | Void, never remove | A server-side union cannot distinguish "unknown to me" from "deleted by me". Making deletion *data* rather than *absence* removes the ambiguity entirely |
| Void reversibility | Irreversible | Makes the union a join-semilattice, so merge is commutative regardless of arrival order. To correct a void, record a new payment |
| Union enforcement | Postgres trigger on `invoices` | Covers the device's generic `pushQueue` upsert automatically; cannot be forgotten or bypassed by a caller |
| Trigger scope | Union only — no `paid`/`paidAt`/epsilon | Keeps the money rules in one place. The trigger's only job is "no write may shrink the ledger" |
| Server paid-ness | Shared JS module in `backend/lib/`, pinned by parity vectors | Follows the existing `backend/lib` pattern, already tested from the main Jest suite |
| Cron source of truth | Derive from the ledger, not stored `paid` | The trigger can union entries the webhook never saw, so stored `paid` can go stale |

## Void semantics

`Payment` gains `voidedAt?: DateString`. `amountPaid` skips entries carrying it.

Void being one-way is load-bearing, not a UI simplification. The union rule is "if either side has `voidedAt`, the voided entry wins." Because void only ever moves in one direction, that rule is deterministic no matter which side arrives first — the merge becomes commutative, associative and idempotent. If void could be undone there would be no ordering to appeal to, and two devices could converge to different states.

`voidPayment(invoice, paymentId, date)` replaces `removePayment`. Nothing consumes `removePayment` yet — no UI ships before Phase 3 — so it is a clean replacement, and its Phase 1 tests are rewritten to the new semantics. Voiding the payment that closed an invoice still un-pays it.

## The trigger

`supabase/migrations/20260718_invoice_payment_merge.sql` — `BEFORE INSERT OR UPDATE ON invoices`, unioning `NEW.data->'payments'` with `OLD.data->'payments'` by payment id, void-wins on collision.

Three constraints, each deliberate:

1. **Dumb by design.** It unions the array and nothing else. No `paid`, no `paidAt`, no `PAID_EPSILON`. Every money rule stays in the shared module.
2. **No-ops when neither side has a `payments` key.** Legacy invoices must remain byte-identical so Phase 1's legacy fallback keeps engaging. The trigger must never stamp `payments: []` onto rows that don't have it.
3. **Idempotent to re-run.** `CREATE OR REPLACE FUNCTION`, then `DROP TRIGGER IF EXISTS` before `CREATE TRIGGER`.

An RPC was considered and rejected: `pushQueue` writes all five collection tables through one generic branch, so anything requiring callers to opt in is a bypass waiting to happen.

## Webhook and cron

**Webhook** (`backend/api/stripe/webhook.js`) appends
`{id: 'stripe_<session_id>', amount: session.amount_total / 100, date, method: 'card'}`
to `data.payments`, then recomputes `paid`/`paidAt` via the shared module as a best-effort cache. Idempotency checks the ledger for that `stripeSessionId`; the trigger's union is a second layer, since a duplicate delivery collapses to one entry by id regardless.

**Cron** (`backend/lib/selectInvoicesToRemind.js`) stops reading `!invoice.paid` and derives paid-ness from the ledger via the shared module. The trigger may union in entries the webhook never saw, so stored `paid` can be stale; without this change a fully-paid invoice could still receive dunning emails.

**Accepted limitation:** the webhook stamps `date` from UTC while the device records local dates. Near midnight at a large offset a payment can land in the adjacent day, which — now that each payment is individually revenue-bucketed — can shift a month boundary. The server does not know the user's timezone. Documented, not solved.

## Client changes

- `types/models.ts` — `Payment.voidedAt?: DateString`.
- `amountPaid` skips voided entries. It is the only derivation that changes; the others flow from it.
- `voidPayment` replaces `removePayment`.
- `mergePaymentLedgers` id-collision rule becomes void-wins, else remote-wins as today.
- `materializeLegacyLedger` unchanged — a synthetic legacy entry is never voided.

Phase 3 note: the history UI shows voided entries struck through with their void date rather than hiding them, and the action reads "Void", not "Delete".

## Anti-drift strategy

The risk in porting money math to `backend/lib/paymentMath.js` is not writing it — it is the two copies drifting later. The port therefore ships with the mechanism that prevents that:

- `__tests__/fixtures/paymentVectors.js` — one array of cases (`label`, `invoice`, `expectedAmountPaid`, `expectedBalance`, `expectedFullyPaid`) covering legacy invoices, ledgers, partials, voided entries and the epsilon boundary.
- `__tests__/paymentMathParity.test.js` — runs BOTH the TypeScript module and the CommonJS module over every vector, asserting they agree with each other and with the expected values.

A change to one implementation that is not mirrored in the other fails the gate immediately.

## Verifying the trigger

Jest cannot execute plpgsql, and pgTAP is not worth a new dependency for one trigger. Verification is a committed, self-checking SQL script — `supabase/migrations/verify/20260718_invoice_payment_merge_verify.sql` — wrapped in `BEGIN … ROLLBACK` so it touches no real data:

1. Insert an invoice with a two-payment ledger.
2. Simulate a stale device push: update with a blob containing only the first payment. Assert both survive.
3. Simulate a void: push a blob where payment 1 carries `voidedAt`. Assert the void sticks and is not reverted by the union.
4. Assert a legacy invoice with no `payments` key passes through completely untouched.

Each assertion `RAISE EXCEPTION` on failure. Run once manually against the project after applying the migration.

## Rollout

Client changes and the shared module can land at any time. The trigger must be applied before Phase 3 ships; the webhook change goes out with or after the trigger.

Applying the trigger to live data is safe for the current TestFlight build (iOS 1.0.0(5)): no invoice in it carries a `payments` array, so the trigger no-ops on every existing row. There is no data migration.

**Owner-gated, per `tradeready-change-control` — neither happens without explicit approval:**
- Applying the Supabase migration to the live project
- Deploying the backend to Vercel

All code and tests land green on the branch before either.

## Out of scope

- **I5 (carried):** `pullRemote` writes merged records with a raw `AsyncStorage.setItem`, bypassing the sync queue, so a successful union is never re-enqueued. The cloud converges only when the user next saves. Worth solving, but it interacts with the trigger and should be designed after it exists.
- **M7 (carried):** the `remote.deleted` branch still drops local payments outright. Usually masked by push-before-pull resurrecting the row.
- Partial-amount payment links, the deposit request UI, and the Money-tab sweep — Phases 3–5 as originally planned.
