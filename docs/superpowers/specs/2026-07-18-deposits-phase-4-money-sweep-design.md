# Deposits & Partial Payments — Phase 4: Money-tab ledger sweep (design delta)

**Date:** 2026-07-18
**Branch:** `feat/deposits-partial-payments`
**Status:** design approved, implementation not started

**This is a DELTA** on `docs/superpowers/specs/2026-07-18-deposits-partial-payments-design.md`.
Only what that spec left open or got wrong is recorded here.

## Why this phase is now load-bearing

The base spec deferred the analytics sweep on the argument that `isOverdue`
already agrees with the ledger. That argument is correct for `isOverdue` and
**silent about `outstanding` and `collected`, which do not agree.**

Since Phase 3 shipped the recording UI, the Money tab's header StatCards
visibly contradict the invoice rows beneath them: a $1,000 invoice with a $400
deposit contributes **$1,000 to Outstanding and $0 to Collected**, while the
row eight pixels below reads "$600.00 due · $400.00 paid" with a "Partly paid"
badge. This phase closes that.

## Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Scope | Convert all three semantic classes, including booleans that are no-ops today | Phase 3's review found the Invoices screen carrying two definitions of "paid" that diverged on reachable data. Leaving nine sites on the raw flag preserves that bug class |
| Amount coercion | The derivations guarantee a finite number; drop the defensive `parseFloat` at call sites | One rule in one place instead of six scattered wrappers and nine sites without one |
| Bucketed charts | Add `collectedByPeriod` | O(invoices) instead of O(invoices × buckets), and both call sites get simpler |
| `invoiceAging` | Keeps reading `paidAt`; only its gate changes | "How long did this take to get paid" is answered by the settling payment's date, which is what `paidAt` holds |

## The three classes

### Revenue — stop asking "was it paid and when", start asking "what money arrived"

`screens/MoneyScreen.tsx:100-102` currently:

```ts
.filter((inv) => inv.paid === true && isInRange(inv.paidAt || inv.due, start, end))
.reduce((sum, inv) => sum + (inv.amount || 0), 0)
```

becomes `collectedInRange(invoices, start, end)`. This is the change that makes
a June deposit count in June and its July balance count in July, rather than
both landing wherever `paidAt` happened to fall.

Same conversion for `MoneyScreen`'s previous-period figure (`:139`),
`components/money/TopCustomersCard.tsx:21`, `components/money/MonthlyChart.tsx:24-25`,
`utils/customerMix.ts:43-44`, `utils/seasonalTrends.ts:24-25`, and
`utils/businessSnapshot.ts:67-68` — the last of which feeds the AI coach, so
its revenue figure is wrong for partials today too.

### Outstanding — stop summing whole invoice amounts

`utils/invoiceStats.ts:34` becomes `outstanding += balanceDue(inv)` and
`collected += amountPaid(inv)`.

`components/money/ReceivablesCard.tsx:23` needs care beyond the totals: its
`unpaid` array is **rendered as a list**, not only reduced. It becomes
"invoices with a balance" (`!isFullyPaid`), and both `totalOutstanding` and
`totalOverdue` sum `balanceDue`.

`utils/customerList.ts:77-78` gains the most: `totalSpent` becomes
`amountPaid(inv)` and `totalOwed` becomes `balanceDue(inv)`, so a part-paid
customer stops appearing to owe everything and have paid nothing.

### Boolean — one-line swaps to `isFullyPaid`, no behaviour change today

`utils/invoiceStats.ts:26`, `utils/notifications.ts:53`,
`utils/storage/dailyOps.ts:53`, `screens/OutreachScreen.tsx:168,223,251,269`,
`screens/CustomerDetailScreen.tsx:42`, `utils/pdfTemplates.ts:146`.

These produce identical results today because `paid` is maintained. They are in
scope because two definitions of "settled" is precisely what bit us in Phase 3.

### The one site that is not a mechanical swap

`utils/invoiceAging.ts:36-37` measures days between `due` and `paidAt` — how
long an invoice took to get paid. With partials the honest answer is the date
the *settling* payment arrived, which is exactly what `paidAt` still holds. So
it keeps reading `paidAt` and only its gate changes to `isFullyPaid`.
Partly-paid invoices stay excluded: they have not finished aging.

## The coercion contract

`amountPaid` and `balanceDue` coerce internally and always return a finite
number — a private `toAmount(v)` returning `Number.isFinite(n) ? n : 0`,
applied to `invoice.amount` and to each payment's `amount`. The six
`parseFloat(String(inv.amount)) || 0` wrappers then come out of the call sites.

Two consequences, both load-bearing:

**It must land in `backend/lib/paymentMath.js` identically**, or
`__tests__/paymentMathParity.test.js` fails. That is the gate doing its job:
the drift becomes impossible to forget rather than something to remember.

**It must NOT go into the legacy-equivalence fixture.**
`__tests__/invoicePaymentsLegacyEquivalence.test.js` asserts the new
derivations exactly equal the OLD formulas, and those return `inv.amount` raw —
a string `"1000"` would have produced the string while the new code produces
the number. Non-finite cases belong in `__fixtures__/paymentVectors.js` (the
TS-vs-JS parity fixture) only. Putting them in the equivalence fixture would
break the suite that exists to be the safety net, and would look like the sweep
broke equivalence.

## The grouped helper

```ts
collectedByPeriod(invoices: Invoice[], ranges: { start: Date; end: Date }[]): number[]
```

Walks each invoice's ledger once and bins every payment into whichever ranges
contain it, returning totals aligned to the input array. `MonthlyChart` (6
buckets) and `seasonalTrends` (12) both consume it, and both call sites get
simpler — they stop filtering and reducing and just read an array.

A payment falling in two overlapping ranges counts in both; that is the
caller's business, and neither current caller overlaps.

## Proving nothing drifted

`__tests__/invoicePaymentsLegacyEquivalence.test.js` (60 generated legacy
invoice shapes pinning the old formulas) must keep passing **completely
unchanged**. If a task needs to touch it, something has gone wrong — that is
the signal, not a chore.

Per-site proof has two parts:

1. **Legacy equivalence at the call site.** Every converted site with an
   existing suite must pass its current tests untouched. Those suites are built
   on legacy fixtures, so a correct conversion is invisible to them. A test
   that needs editing means the conversion changed legacy behaviour.
2. **New partial-payment cases**, one per converted site, asserting what was
   previously wrong. E.g. `summarizeInvoices` on a $1,000 invoice with $400
   recorded yields `outstanding: 600, collected: 400` instead of
   `outstanding: 1000, collected: 0`.

These sites have existing suites: `businessSnapshot`, `customerList`,
`customerMix`, `invoiceAging`, `invoiceStats`, `notifications`,
`seasonalTrends`.

These have none, so review is the gate — the same position Phase 3's wiring
task was in: `screens/MoneyScreen.tsx`, `components/money/ReceivablesCard.tsx`,
`components/money/TopCustomersCard.tsx`, `components/money/MonthlyChart.tsx`,
`utils/storage/dailyOps.ts`, `screens/CustomerDetailScreen.tsx`,
`screens/OutreachScreen.tsx`, `utils/pdfTemplates.ts`.

## Tasks

| # | Task | Why grouped this way |
|---|---|---|
| 1 | Coercion contract in both implementations + parity vectors | Touches the tested core; lands alone so a failure is unambiguous |
| 2 | `collectedByPeriod` helper + tests | Pure, self-contained, consumed by task 5 |
| 3 | Tested pure utils — `customerMix`, `seasonalTrends`, `businessSnapshot`, `customerList`, `invoiceAging` | All have suites; their legacy tests must pass untouched |
| 4 | `invoiceStats` + the outstanding math | The numbers users stare at most |
| 5 | Untested components/screens — `MoneyScreen`, `ReceivablesCard`, `TopCustomersCard`, `MonthlyChart` | No harness; review is the gate |
| 6 | The nine boolean one-liners | Mechanically identical, no behaviour change |
| 7 | Docs and carried manual-QA notes | |

## Out of scope

- `utils/pdfTemplates.ts`' balance and history block — Phase 6. Only its
  boolean converts here.
- Deposit requests and partial-amount Stripe links — Phase 5.
- `utils/sync.ts`, `utils/syncMerge.ts`, and everything else under `backend/`
  except the `paymentMath.js` mirror required by the coercion contract.

## Shipping constraint

Unchanged: this work may be built and merged but must NOT ship to users until
the Supabase migration is applied and the backend deployed. The deployed
webhook still writes a bare `paid: true`, which the ledger merge discards. See
`docs/deposits-resume-here.md` §4.
