# Deposits & Partial Payments — Phase 3: Recording UI (design delta)

**Date:** 2026-07-18
**Branch:** `feat/deposits-partial-payments`
**Status:** design approved, implementation not started

**This is a DELTA.** The base design is
`docs/superpowers/specs/2026-07-18-deposits-partial-payments-design.md`. Only
what changes is recorded here; everything not mentioned there still stands.

## Why a delta was needed

The base spec's Phase 3 row says *"payment history with confirm-guarded
delete."* That was written before Phase 2b replaced deletion with irreversible
voiding
(`docs/superpowers/specs/2026-07-18-server-side-ledger-merge-design.md`). Three
things the original never considered:

1. The action is **Void**, not Delete. It is irreversible and the entry stays
   visible.
2. Every legacy paid invoice now has a **synthesized history row**
   (`legacy_<id>`, note "Recorded before payment history was itemised") that the
   user never created.
3. A single `invoice_paid` analytics event no longer describes what happens.

## Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Legacy history row | Show it, plainly labelled | Honest, totals visibly add up, and it keeps a correction path for a wrongly-marked-paid legacy invoice |
| Void interaction | Long-press → confirm | Deliberately hard to hit, matching the destructive-action pattern already used in this codebase |
| Analytics | Keep `invoice_paid` for settlement; add `payment_recorded` and `payment_voided` | Preserves continuity of the existing PostHog series while giving visibility into deposits and partials |
| Manual card payments | `method: 'card'`, never `'stripe'` | `stripe` is reserved for webhook-created entries so the two are distinguishable |
| Over-balance amounts | Allowed, with a non-blocking hint | Customers overpay and tip; `balanceDue` already clamps at zero |

## Recording a payment

A bottom sheet reached from a **"Record payment"** action in two places: the
invoice row and the detail modal.

Fields, all built on existing shared primitives (`components/Field.tsx`,
`components/DateTimePickerSheet.tsx` — do not write new copies):

- **Amount** — pre-filled with `balanceDue(invoice)`. Must be greater than zero.
  If it exceeds the balance, show a non-blocking hint ("More than the $600
  balance") rather than rejecting.
- **Date** — defaults to today, via `DateTimePickerSheet`.
- **Method** — chips: Cash / Check / Card / Other. `stripe` is deliberately
  absent from the picker.
- **Note** — optional.

On save: `applyPayment(invoice, { id: newPaymentId(), amount, date, method,
note })`, then `saveInvoices`. All the math already exists and is tested; the
sheet is pure UI over it.

## Payment history and voiding

The list renders the invoice's effective ledger. That accessor is currently
named `materializeLegacyLedger`, which reads badly at a call site meaning "this
invoice's payments" — this phase adds an **`effectivePayments` alias export**
(the M5 carry-forward from the Phase 1 review). No behaviour change.

Each row shows `date · method · amount`. A voided entry renders struck through
with "voided 22 Jul" — it stays visible, which is the entire point of voiding
rather than deleting.

The legacy row renders plainly labelled:
`$1,000 · 15 Jun · recorded before itemised history`. It is voidable like any
other entry, which is what gives a wrongly-marked-paid legacy invoice a
correction path.

**Long-press → confirm → `voidPayment`.** The confirm names the consequence in
money rather than jargon:

> **Void this payment?**
> This can't be undone. Invoice INV-042 will go back to $600 due.
> To correct a mistake, record a new payment.
> [Cancel] [Void payment]

## `markPaid` rewire and row display

`markPaid` (`screens/InvoicesScreen.tsx`) currently writes a bare
`{ ...i, paid: true, paidAt: today }` with no ledger entry. That is the same
defect class the webhook had: once an invoice carries any recorded payment,
`materializeLegacyLedger` stops synthesizing, the next sync's merge derives
`paid: false`, and the tap is **silently reverted** — after which the
ledger-derived reminder cron dunns a customer who was just marked as having
paid in cash.

It keeps its existing confirm Alert and its one-tap meaning, but its body
becomes a call to a new pure helper:

```ts
settleRemaining(invoice, today) // => applyPayment(invoice, {
                                //      id: newPaymentId(),
                                //      amount: balanceDue(invoice),
                                //      date: today,
                                //      method: 'other',
                                //    })
```

The label becomes balance-aware: **"Mark paid"** on an untouched invoice,
**"Mark rest paid"** when partly paid, so the user knows they are settling $600
rather than $1,000.

Invoice rows go balance-forward when partly paid: `$500 due · $500 paid`, with
a "Partly paid" badge. `getStatus` gains its partly-paid branch as specified in
the base design (after the paid check, before the not-yet-due branch, gated on
`days <= 0` so an overdue invoice keeps its overdue label).

**`invoiceStats.isOverdue` does NOT change in this phase.** It reads
`!inv.paid`, and `paid` is maintained by `withDerivedPaidFields`, so it already
agrees with `!isFullyPaid()` in every case. The analytics sweep stays entirely
in Phase 4.

## Analytics

`track()` takes a plain string, so there is no event union to extend.

| Event | When | Properties |
|---|---|---|
| `invoice_paid` | Balance reaches zero. **Unchanged meaning** — preserves the existing PostHog series | `amount` |
| `payment_recorded` | Every recorded payment, including partials | `amount`, `method`, `balanceRemaining` |
| `payment_voided` | A payment is voided | `amount`, `method` |

`invoice_paid` now fires wherever settlement occurs — the record sheet or
`markPaid` — rather than only from the button.

**Accepted gap:** webhook-created payments arrive via sync rather than through
the app, so they emit no `payment_recorded`. Server-side Stripe payments are
already visible in Stripe's own dashboard, and inventing a sync-time event that
fires on data the user did not just create would be worse than the gap.

## Testing

This repo has thin screen-test coverage (`Field`, `UI`, `SyncBanner` are
components, not screens). Rather than fight that with heavy `InvoicesScreen`
tests, the design keeps the testable parts pure:

- **`settleRemaining(invoice, today)`** — pure, unit-tested. The screen does
  Alert plus save; the logic is not in the screen.
- **`RecordPaymentSheet`** — RNTL tests: pre-fills the balance, rejects zero or
  negative, shows the over-balance hint without blocking, calls `onSave` with
  the exact payment shape.
- **`PaymentHistoryList`** — RNTL tests: a voided entry renders struck through
  with its date, the legacy row renders with its label, long-press fires the
  void confirm.

All money math is already covered by Phases 1–2b. Phase 3 tests only the UI
contract over it.

## Task breakdown

| # | Task | Contents |
|---|---|---|
| 1 | Derivations | `effectivePayments` alias, `getStatus` partly-paid branch, `settleRemaining` helper. Pure, no UI. |
| 2 | `RecordPaymentSheet` | New component + tests. Not wired in. |
| 3 | `PaymentHistoryList` | New component incl. voided and legacy rendering + tests. Not wired in. |
| 4 | Wire into `InvoicesScreen` | Row action, detail modal, balance-forward display, `markPaid` rewire. |
| 5 | Analytics | The three events. |
| 6 | Polish | a11y labels, dark-mode pass, doc touch-ups. |

Tasks 2 and 3 build components in isolation before task 4 wires them, so each
is reviewable alone and a wiring failure cannot be mistaken for a component
failure.

## Out of scope

- Deposit requests and partial-amount Stripe links — Phase 5.
- The Money-tab analytics sweep (~12 call sites) — Phase 4.
- PDF balance and history block — Phase 6.
- Unchanged: `utils/invoiceStats.ts`, every analytics card, everything under
  `backend/`.

## Shipping constraint

Phase 3 may be built and merged. It **must not ship to users** until the
Supabase migration is applied and the backend deployed. The currently-deployed
webhook still writes a bare `paid: true` with no ledger entry; once an invoice
carries any recorded payment, the ledger merge discards that write and a real
Stripe payment is erased. See `docs/deposits-resume-here.md` §4 for the
owner-gated sequence.
