# Tax Set-Aside — Design

**Date:** 2026-07-18
**Branch:** `feat/tax-set-aside` (off `feat/deposits-partial-payments` @ 3b0a89d — the
income source is the payment ledger, so this stacks on deposits and cannot merge before it)
**Roadmap:** Phase 4 of `docs/post-launch-feature-roadmap.md`
**Status:** decisions owner-approved in the 2026-07-18 brainstorm; this document
records them plus the one open item resolved below.

## Problem

Solo tradespeople get ambushed by quarterly estimated taxes. The app knows their
collected income, their expenses, and their business miles — everything needed
to say "put $2,100 aside this quarter and have it ready by Sep 15". Today it
says nothing, and the failure mode (under-reserving, then a four-figure IRS
bill) costs real money. Competitors (QuickBooks Self-Employed) treat this as a
headline feature.

## Owner-approved decisions (2026-07-18 brainstorm)

| Decision | Choice | Rationale |
|---|---|---|
| Tax model | Statutory SE tax (15.3%) + a user-set effective income-tax rate | SE tax is law and computable; income tax depends on filing status/state — a single user-set % beats a fake bracket wizard |
| Vehicle deduction | User must CHOOSE standard mileage OR actual (fuel) expenses; unset computes with NEITHER | IRS forbids both. Neither-until-chosen over-reserves — the safe failure direction |
| Income source | `collectedInRange()` over the payment ledger (cash basis) | The deposits branch made per-payment dates real; a deposit collected today is income today |
| Reserve figure | Current payment-period reserve + YTD total + the period's deadline | Answers "how much, by when" without a filing calendar |
| Mileage | Stays local-only; disclose in-card with trip count | Syncing `Trip` is out of scope; a silent device-local input would misattribute missing deductions |
| Surfaces | Money-tab card + AI-coach snapshot; NO dedicated screen, NO Settings entry | Smallest honest surface |
| 0.9% Additional Medicare surtax | NOT modeled | Needs filing status; bites above $200k net — outside the target user. Disclosed instead |
| Payment periods | IRS 3/2/3/4 months (Jan–Mar, Apr–May, Jun–Aug, Sep–Dec), due Apr 15 / Jun 15 / Sep 15 / Jan 15+1yr, weekend-shifted | Encoding even quarters is a silent wrong answer. Federal holidays deliberately not modeled |

**Settings gap — resolved:** rate and method live in a `TaxSettingsModal` opened
from the card (AddExpenseModal pattern), persisting two additive optional
`Settings` fields: `taxIncomeRate?: number` and
`vehicleDeductionMethod?: 'mileage' | 'actual'`. Optional fields need no
migration and no defaults; every read is defensive. Unset rate computes $0
income tax with an in-card prompt to set it (the SE component alone is still
the dominant, statutory piece); unset method deducts neither vehicle input and
prompts when either exists.

## IRS constants (verified against primary sources 2026-07-18)

| Constant | Value |
|---|---|
| Social Security wage base 2026 | $184,500 (2025: $176,100) |
| Social Security rate | 12.4% (capped at wage base) |
| Medicare rate | 2.9% (no cap) |
| Net-earnings factor | 92.35% (Schedule SE line 5a) |
| Half of SE tax deductible before income tax | yes |

The wage base is a versioned `Record<year, number>`. An unknown year computes
with the LATEST known base and flags `ratesKnown: false` — the card shows a
"using 2026 rates" notice instead of going blank, because the base only matters
above $184.5k net profit and the figure stays useful for the target user.
**This feature carries an annual maintenance obligation** — new wage base (and
a check of the SE rates) every January — recorded on
`docs/ops-monthly-checklist.md`.

## Math (per window)

```
netProfit  = collectedIncome − deductibleExpenses − vehicleDeduction
seBase     = max(0, netProfit × 0.9235)
seTax      = min(seBase, SS_WAGE_BASE[year]) × 0.124 + seBase × 0.029
incomeTax  = max(0, netProfit − seTax/2) × (taxIncomeRate/100)
reserve    = seTax + incomeTax
```

- `deductibleExpenses` = all expense categories EXCEPT `fuel`, bucketed by
  `exp.date` via `isInRange`.
- `vehicleDeduction` = method `'mileage'` → business miles × `settings.mileageRate
  ?? DEFAULT_MILEAGE_RATE`; `'actual'` → `fuel`-category expenses; unset → 0.
- Known simplification, documented in code: the SS cap applies per computed
  window rather than annually reconciled across windows. Overstates SE tax only
  above the wage base, where the "assumes net profit under $200k" disclosure
  already applies.
- The card's deadline is the CURRENT period's own due date (not the globally
  next deadline) — in early January the next calendar deadline is last year's
  Q4, which belongs to last year's books, while the card is a running
  set-aside guide for the money being earned now.

## Architecture

- `utils/taxEstimate.ts` — pure, no I/O (mirrors `mileageUtils`/`invoiceStats`):
  constants, `taxPeriodsForYear`, `currentTaxPeriod`, deadline weekend shift,
  `splitDeductibleExpenses`, `resolveVehicleDeduction` (with `needsChoice`
  detection), `estimateTaxReserve`, and `summarizeTaxWindow` — the one
  aggregator the card and the AI snapshot both call.
- `components/money/TaxSetAsideCard.tsx` — MileageCard pattern (React.memo,
  self-loads trips + settings on focus); receives `invoices`/`expenses` as
  props from MoneyScreen's existing data. Shows period reserve, YTD, deadline,
  the choose-your-method prompt, the set-your-rate prompt, the stale-rates
  notice, the persistent disclaimer, and the local-mileage disclosure with trip
  count. Sits in the Tools section next to MileageCard.
- `components/money/TaxSettingsModal.tsx` — AddExpenseModal pattern.
- `utils/businessSnapshot.ts` — optional `tax` block computed in
  `getBusinessSnapshot` via `summarizeTaxWindow`; `ChatScreen.buildSystemPrompt`
  renders it with a constraint: the coach may cite the figures but must decline
  filing/eligibility/entity questions and refer to a tax professional.
- `__tests__/taxEstimate.test.js` + component/snapshot test extensions.

## Copy rules

- Disclaimer is persistent and non-dismissable: "Estimate only — not tax
  advice. Assumes net profit under $200k." (Wording wants a lawyer's eye
  post-launch, like terms.html §5 did.)
- Never call the figure a "tax bill"; it is a set-aside estimate.

## Out of scope

- Syncing trips; auto-posting the reserve as an expense; state tax modeling;
  the 0.9% surtax; filing-status wizards; any new screen.
