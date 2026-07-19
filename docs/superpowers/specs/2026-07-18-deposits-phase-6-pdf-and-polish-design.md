# Deposits & Partial Payments — Phase 6: PDF and polish (design delta)

**Date:** 2026-07-18
**Branch:** `feat/deposits-partial-payments`
**Status:** design approved, implementation not started

**This is a DELTA** on `docs/superpowers/specs/2026-07-18-deposits-partial-payments-design.md`.

## This phase is not polish

The base spec's Phase 6 row reads "PDF balance/history block, a11y labels,
dark-mode pass, final review", which sounds cosmetic. Reading the template
changed that assessment.

`utils/pdfTemplates.ts:207-209` renders:

```
TOTAL DUE    ${formatMoney(invoice.amount)}
```

and line 193 renders a binary `Paid` / `Outstanding` badge. So an invoice PDF
sent to a customer after a $400 deposit tells them **"TOTAL DUE $1,000"** —
inviting them to pay the full amount a second time. That is a wrong number
going to a customer, not a missing nicety.

## Decisions

| Decision | Choice | Rationale |
|---|---|---|
| PDF total block | Three lines when partly paid, with BALANCE DUE taking the large accent styling | The number a customer acts on is what they still owe, so that is the one that should dominate |
| Voided payments on the PDF | Excluded entirely | A void is internal bookkeeping — a mistyped entry, a bounced cheque. "$500 cash — VOIDED" on a customer's document invites disputes about money they may believe they paid |
| Synthesized legacy entry on the PDF | Excluded | Its note reads "Recorded before payment history was itemised" — internal language describing an app migration |
| CustomerDetailScreen | Made to match the Invoices tab | Last known user-visible inconsistency in the feature |
| Dark mode | Does not apply to the PDF | The PDF is a document with hardcoded light-theme CSS, not an app surface |

## The PDF

### Badge

Line 193 is currently binary. It gains a third state, `Partly paid`, with a
new `.badge-partial` CSS class alongside the existing `.badge-paid` /
`.badge-unpaid` at lines 122-123.

### Total block

Becomes three lines **only when `isPartlyPaid(invoice)`**:

```
Invoice total        $1,000.00
Paid to date          −$400.00
BALANCE DUE           $600.00     ← keeps the large accent styling
```

Every other invoice keeps today's single `TOTAL DUE` line untouched. A
fully-paid invoice showing "BALANCE DUE $0.00" would be odd, and an unpaid one
has nothing to subtract.

### Payment history table

Appears when the invoice has at least one payment worth showing, with two
exclusions:

1. **Voided entries are excluded.** The in-app history keeps showing them
   struck through for the tradesperson's audit trail; the customer's copy does
   not need them.
2. **The synthesized `legacy_<id>` entry is excluded.**

### The byte-identical property

Between those two exclusions and the `isPartlyPaid` gate on the total block,
**every invoice created before this feature produces a byte-identical PDF.**

That matters more than usual: these documents get emailed and archived, so a
silent rendering change to historical invoices would be its own problem. It is
also the cheapest thing to test, and the test that proves the change is safe.

An invoice settled by real recorded payments still gets the history table even
though its total block stays single-line — "$400 on 1 Jun, $600 on 20 Jul" is
a useful receipt.

### Not a dark-mode surface

The PDF's CSS hardcodes light-theme colours because it is a document. The
dark-mode pass in this phase applies only to the screen change below. Stating
it because the base spec's row reads as though it covers the whole phase.

## CustomerDetailScreen

Two changes, both making it agree with the Invoices tab.

`invoiceStatus` (line 42) already reads `isFullyPaid` after Phase 4 but knows
only Paid / Overdue / Pending. It gains a **Partly paid** branch, following the
same precedence `getStatus` uses: **overdue still wins when both apply**,
because an invoice with a deposit on it that is past due is still late.

The amount at lines 104 and 112 — **including the `accessibilityLabel` on
104** — goes balance-forward when partly paid: `$600.00 due · $400.00 paid`.
Both must change together; a screen reader announcing "$1,000.00" while the
visible row reads "$600.00 due" is its own defect.

## Testing

The PDF builders are pure string functions, which makes this the most testable
part of the phase.

- **The byte-identical property.** A legacy invoice, an untouched unpaid
  invoice, and a fully-paid one must all still render `TOTAL DUE` and must NOT
  contain `BALANCE DUE`.
- **The partly-paid case** renders all three lines with correct numbers and the
  `Partly paid` badge.
- **Both exclusions** — a voided payment does not appear in the table, and
  neither does a synthesized `legacy_` entry.
- **A fully-paid ledger invoice** gets the history table but keeps the
  single-line total.

`__tests__/estimateDocument.test.js` exists; whether it covers the INVOICE
builder needs checking, and a new suite added if not.

`screens/CustomerDetailScreen.tsx` has no harness, so its proof is review —
the same position the Phase 3 wiring task was in.

## Tasks

| # | Task |
|---|---|
| 1 | PDF: badge, gated total block, history table with both exclusions, plus tests |
| 2 | `CustomerDetailScreen`: partly-paid status, balance-forward amount and accessibility label, dark-mode check |
| 3 | Docs and the whole-branch wrap-up |

Task 3 differs from previous phases' docs tasks. **This is the last phase to be
built**, so it ends with a whole-BRANCH review — five phases read as one
artifact — rather than a phase review, and `docs/deposits-resume-here.md` gets
rewritten to describe a finished feature awaiting deployment rather than work
in progress.

## Out of scope

- **Phase 5** (deposit requests and partial-amount Stripe links) remains
  unbuilt by choice. It is the phase whose value is an end-to-end money path,
  so it needs the backend live to verify rather than merely to ship.
- The estimate PDF (`buildEstimateDocument` and its "Pending Approval" badge at
  line 272) — estimates have no payment ledger.

## Shipping constraint

Unchanged. This may be merged but must NOT ship until the Supabase migration is
applied and the backend deployed. See `docs/deposits-resume-here.md` §4.
