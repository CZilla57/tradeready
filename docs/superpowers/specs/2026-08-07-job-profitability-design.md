# Estimated-vs-Actual Job Profitability — Design (Phase 13)

**Date:** 2026-08-07 · **Status: AWAITING OWNER APPROVAL — no code written.**
Source: the owner-curated Phase 13 kickoff prompt in
`docs/post-launch-feature-roadmap.md:326-393`. Per that prompt, this document
inventories inputs, defines every figure, gives worked examples, migration
requirements and test vectors, then STOPS. Implementation (pure calculation
layer + tests first, UI after) begins only on approval.

All file:line references verified against HEAD `60da60b` on 2026-08-07.

---

## 1. Scope and non-goals

**Goal:** trustworthy per-job comparison of the original estimate against
actual labor, materials, expenses, change orders, invoicing and cash
collection — computed deterministically from data the app already records,
never invented.

**Non-goals (v1):** processing-fee capture (no code path knows a Stripe fee —
§3.4), refund records (no representation exists anywhere — §3.3), payroll/job
costing for employees (solo-operator app), editing historical records to
"fix" variances.

**What this unblocks:** Phase 15's job-cost insight conditions ("actual cost
above estimate" beyond labor hours) are explicitly BLOCKED on this data layer
(`docs/post-launch-feature-roadmap.md:472-475`). AI may *explain* these
figures (kickoff constraint); it never calculates them.

---

## 2. Input inventory — exists vs missing

Verified figure-by-figure against the kickoff's list:

| # | Figure | Source today | Status |
|---|---|---|---|
| 1 | Estimated revenue | `Job.estimateTotal` (`types/models.ts:170`) — the as-approved baseline, never mutated by change orders (`types/models.ts:126-129`) | ✅ exists |
| 2 | Approved change-order revenue | `approvedChangeOrderTotal(job)` (`utils/changeOrders.ts:46-53`); status derived, declined/cancelled/pending contribute 0 | ✅ exists |
| 3 | Final billable amount | `jobBillableTotal(job)` = estimateTotal + approved COs (`utils/changeOrders.ts:56-58`); tracked-time labor substitution for invoice prefill already in `computeBillableBreakdown` (`utils/autoInvoice.ts:112-141`) | ✅ exists |
| 4 | Invoiced amount | Linked invoices: `Invoice.jobId` (`types/models.ts:426`, set by both CreateInvoiceFromJob paths) + `Job.invoiceId` (`types/models.ts:183`). Manual invoices (AddInvoiceScreen) carry no jobId | ✅ exists (linkage gap on manual invoices → warning, §4.2) |
| 5 | Cash collected | `amountPaid(inv)` — non-voided ledger sum with legacy fallback (`utils/invoicePayments.ts:48`) | ✅ exists |
| 6 | Estimated labor hours | `Job.laborHours` (`types/models.ts:171`) | ✅ exists |
| 7 | Actual tracked labor hours | `Job.timeSessions` + `computeTimeTracking` (`utils/timeTracking.ts:55-92`); closed-session basis already used for billing via `billableLaborHours` (`utils/autoInvoice.ts:80-90`) | ✅ exists |
| 8 | Billable labor rate | `Job.laborRate` (`types/models.ts:172`) | ✅ exists |
| 9 | Owner labor-cost rate | — nothing on `Settings` (`types/models.ts:723-865`) | ⚠️ **missing — new optional field** (§3.2) |
| 10 | Estimated material cost | `computeEstimateBreakdown(job).materialBaseCost` (owner's cost) and `.materialCost` (customer charge incl. markup) (`utils/pricingEngine.ts:174-189`) | ✅ exists |
| 11 | Actual job-linked material expense | — `Expense` has NO job linkage (`types/models.ts:488-507`; confirmed by `utils/importEngine.ts:365-366`) | ⚠️ **missing — new optional field** (§3.1) |
| 12 | Other direct job expenses | same gap as #11 | ⚠️ missing (same field) |
| 13 | Payment-processing fees | — no code path knows a fee: webhook records gross `amount_total` only (`backend/api/stripe/webhook.js:167`); repo-wide grep for `balance_transaction`/fee fields: zero hits | ⚠️ **unknowable today** (§3.4) |
| 14 | Estimated gross profit | derivable from #1 + #10 (+ #9 when set) | ✅ derivable |
| 15 | Actual gross profit | derivable from #3/#5 + #11/#12 (+ #7×#9) | ✅ derivable once #11 exists |
| 16 | Outstanding receivable | `balanceDue(inv)` (`utils/invoicePayments.ts:59`) | ✅ exists |

Overpayments are already explicit: `overpaidAmount(inv)`
(`utils/invoicePayments.ts:83`), rendered in `screens/InvoicesScreen.tsx:450-453`.
Voided payments already stay in history but out of every collected total
(five `voidedAt` filters, e.g. `utils/invoicePayments.ts:53`).

---

## 3. Proposed data-shape changes (ALL additive-optional; each needs owner approval)

### 3.1 `Expense.jobId?: string` — the load-bearing new field

FK to `Job.id`, absent = business overhead exactly as today. Follows the
established additive-optional pattern (`Invoice.jobId`, `importBatchId`).

- **Creation sites** (all four audited; expenses have create+delete only, no
  edit path — `components/money/ExpenseRow.tsx:10-13`):
  - `AddExpenseModal` (`components/money/AddExpenseModal.tsx:229-246`): add an
    optional "Link to job" picker (active jobs, default none). Also accept a
    `defaultJobId` prop so JobDetail can open it pre-linked (Phase C).
  - `hooks/useMoneyData.ts:79-92`: pass-through (draft spread already carries
    new optional fields).
  - CSV import (`utils/importEngine.ts:405-447`): **unchanged** — import
    sources have no job identity; do not guess.
  - Siri/widget replay (`utils/widgetActions.ts:186-222`): **unchanged** v1.
- **Retro-linking:** none in v1 (no expense edit path exists; building one is
  a scope expansion — flagged as an option in §11 D1b).
- **Dangling FK rule:** a `jobId` pointing at a deleted job degrades to
  unlinked (treated as business overhead) — same tolerance as
  `Invoice.customerId`.

### 3.2 `Settings.laborCostRate?: number` — optional owner labor-cost rate

$/hr the owner "pays themselves" for cost purposes; **kept strictly separate
from `laborRate` (billing)** per the kickoff constraint. Absent = unset:
gross-profit figures then EXCLUDE owner labor and are labeled "before paying
yourself" (§4.4). Set on the Settings → Pricing subpage (draft-hook page,
`hooks/useSettingsDraft.tsx` contract). The app never defaults it — an
invented cost rate would fabricate profit numbers.

### 3.3 Refunds — recommend OUT OF SCOPE v1 (owner decision D3)

There is no refund representation anywhere: no field, no negative amounts, no
Stripe `charge.refunded` handling; explicitly excluded by two prior approved
specs (`docs/superpowers/specs/2026-07-18-deposits-partial-payments-design.md:42`,
`2026-08-05-change-orders-design.md:143`). The kickoff's "overpayments and
refunds must be represented explicitly" is satisfied v1 as: overpayment =
explicit figure (exists); refunds = explicitly **unrepresentable**, stated in
the UI copy and docs, never silently netted. Adding refund entries (union-safe
ledger records + webhook handling on both backend twins) is a self-contained
follow-up if wanted.

### 3.4 Processing fees — recommend "unknown" v1 (owner decision D4)

`processingFees` renders as unknown with a warning, never $0 and never
estimated (kickoff: "do not invent processing fees"). No `Payment.feeAmount`
field is added until a writer exists — capturing real fees means fetching
`balance_transaction` in the Stripe webhook on BOTH backend twins (Vercel +
Workers parity), a scoped follow-up.

### 3.5 Aggregate profitability by job type — blocked on a grouping key (owner decision D5)

`Job` has no type/category field (`types/models.ts:154-226`);
`Settings.trade` is one value per user; `RevenueByTypeCard` groups cost
*components*, not job types (`utils/revenueByType.ts:20-72`). Options:
**(a)** add additive-optional `Job.jobType?: string` (picker w/ free text,
prefilled from pricebook entry name on apply) — one more shape change;
**(b)** v1 aggregates overall + per-customer only, defer per-type.
Recommendation: **(b)** — don't dilute this phase; add `jobType` later with
its own capture UX.

---

## 4. Figure definitions (the pure layer: `utils/jobProfitability.ts`)

New born-typed pure module, injected clock, no I/O — the same testability
pattern as `aggregateSnapshot` (`utils/businessSnapshot.ts:64`) and
`computeTimeTracking`. Single entry point:

```ts
computeJobProfitability(
  job: Job,
  invoices: Invoice[],
  expenses: Expense[],
  settings: Pick<Settings, "laborCostRate" | "marginPercent">,
  now: Date,
): JobProfitability
```

Every dollar figure passes through `toAmount` + `roundToCents`
(`utils/invoicePayments.ts:42,259`). Unknown ≠ zero: unknowable figures are
`null` and contribute a machine-readable warning (§4.5).

### 4.1 Revenue figures

| Figure | Formula | Notes |
|---|---|---|
| `estimatedRevenue` | `job.estimateTotal \|\| 0` | as-approved baseline |
| `changeOrderRevenue` | `approvedChangeOrderTotal(job)` | may be negative (descope credit) |
| `finalBillable` | `jobBillableTotal(job)` | contracted amount; NOT what was necessarily invoiced |
| `invoicedAmount` | Σ `inv.amount` over **linked invoices** | may differ from finalBillable (tracked-time billing, manual edits) — that difference is a variance line, not an error |
| `cashCollected` | Σ `amountPaid(inv)` over linked invoices | voids excluded, legacy fallback intact |
| `outstandingReceivable` | Σ `balanceDue(inv)` | clamped ≥ 0 per invoice |
| `overpaidAmount` | Σ `overpaidAmount(inv)` | explicit, never netted |
| `processingFees` | `null` v1 | warning `fees_unknown` when cashCollected > 0 via a `stripe`-method payment |

**Linked invoices** := `invoices.filter(inv => inv.jobId === job.id)` ∪ the
invoice with `inv.id === job.invoiceId`, deduped by id. A job in status
`invoiced`/`paid` with **zero** linked invoices ⇒ warning `invoice_unlinked`
(manual AddInvoiceScreen invoices carry no jobId — `types/models.ts:426`).

**Constraint kept:** invoiced ≠ collected — they are separate figures and the
UI never sums them.

### 4.2 Labor figures

| Figure | Formula | Notes |
|---|---|---|
| `estimatedLaborHours` | `job.laborHours \|\| 0` | |
| `billableLaborRate` | `job.laborRate \|\| 0` | billing rate — never used as a cost |
| `actualLaborHours` | closed sessions only: `computeTimeTracking(sessions, est, now).completedMs / 3.6e6`, rounded 2 dp | `null` when `timeSessions` absent/empty (tracking never used ⇒ unknown, warning `hours_untracked`) — NOT 0. Open-session live time is a UI concern (JobDetail card already shows it); profitability uses the deterministic closed basis, same as billing (`utils/autoInvoice.ts:86`) |
| `laborHoursVariance` | `actualLaborHours - estimatedLaborHours` | `null` when actual is null or estimate ≤ 0 (mirrors `overUnder` — `utils/timeTracking.ts:88`) |
| `estimatedOwnerLaborCost` | `laborCostRate set ? estimatedLaborHours × laborCostRate : null` | |
| `actualOwnerLaborCost` | `laborCostRate set && actualLaborHours != null ? actualLaborHours × laborCostRate : null` | |

### 4.3 Materials & direct-expense figures

| Figure | Formula | Notes |
|---|---|---|
| `estimatedMaterialCost` | `computeEstimateBreakdown(job).materialBaseCost` | the owner's COST (pre-markup). The marked-up `.materialCost` is revenue-side and appears only in variance explanations |
| `actualMaterialExpense` | Σ linked expenses with `category === "materials"` | **`null` when the job has zero linked expenses of any category** (no data ≠ no spend), warning `expenses_unlinked`. When ≥1 linked expense exists, sums are real (0 materials with a linked fuel expense = genuinely $0 materials) |
| `otherDirectExpenses` | Σ linked expenses, all other categories (`labor`=subcontractors, `fuel`, `tools`, …) | same null rule (shared with above) |
| `materialsVariance` | `actualMaterialExpense - estimatedMaterialCost` | `null` unless both known |

**Double-counting rule (kickoff constraint):** actual costs come ONLY from
linked expenses; estimated materials are never added into actual cost, and an
estimate line item never becomes a cost record. The variance line is where the
two meet. Change orders never contribute cost directly — their real costs
arrive as tracked hours and linked expenses.

### 4.4 Profit figures

Gross profit = revenue − **direct costs** (materials, subcontractors, other
linked direct expenses, owner labor when a cost rate is set). Business
overhead (unlinked expenses) deliberately stays out — that's the Money tab's
business-level P&L (`components/money/SummaryCard.tsx:41`).

| Figure | Formula |
|---|---|
| `estimatedGrossProfit` | `estimatedRevenue − estimatedMaterialCost − (estimatedOwnerLaborCost ?? 0)` |
| `actualGrossProfitBilled` | `finalBillable − knownActualCosts` |
| `actualGrossProfitCash` | `cashCollected − knownActualCosts` |
| `effectiveHourlyActual` | `actualLaborHours > 0 ? (actualGrossProfitBilled + (actualOwnerLaborCost ?? 0)) / actualLaborHours : null` — what the owner actually earned per tracked hour, before paying themselves; mirrors the estimate engine's `effectiveHourlyRate` (`utils/pricingEngine.ts:81-84`) |

`knownActualCosts` = Σ of the non-null cost figures
(`actualMaterialExpense`, `otherDirectExpenses`, `actualOwnerLaborCost`).
When any component is null the profit figure still computes **but carries the
component's warning** and the UI labels it (e.g. "before materials — no
expenses linked"). Rationale: a strict-null cascade would blank the entire
feature for every pre-Phase-13 job forever; explicit warnings satisfy
"unknown values carry a warning" without that. ⚠️ Owner may veto toward
strict-null (decision D6).

`paid`-basis labeling: every profit figure names its revenue basis (billed vs
cash). The two are never averaged or mixed.

### 4.5 Result shape (sketch)

```ts
export type ProfitWarning =
  | "hours_untracked" | "expenses_unlinked" | "invoice_unlinked"
  | "fees_unknown" | "labor_cost_rate_unset" | "legacy_invoice_dates";

export interface JobProfitability {
  // …all figures from §4.1–4.4, number | null as specified…
  warnings: ProfitWarning[];   // deduped, stable order for tests
}
```

`legacy_invoice_dates` fires when a linked invoice has no ledger (its
implied payment date is `paidAt ?? due` — `utils/invoicePayments.ts:105`),
so time-bucketed views are approximate. Totals stay exact.

---

## 5. Kickoff accounting constraints — compliance map

| Constraint | Where satisfied |
|---|---|
| Invoiced ≠ cash collected | separate figures, §4.1; UI never sums |
| No invented fees/costs/dates/methods | fees `null` (§3.4); costs only from linked records; dates only from ledger/`exp.date` |
| Unknown legacy values stay unknown + warn | `null` + `ProfitWarning` (§4.2, §4.3, §4.5) |
| Billing rate ≠ labor cost | `billableLaborRate` never enters cost; `laborCostRate` never enters revenue (§4.2) |
| No materials double-counting | §4.3 rule + test vector T9 |
| COs affect contracted revenue only when approved | `approvedChangeOrderTotal` status gate (`utils/changeOrders.ts:49`) |
| Voided payments: history yes, totals no | existing ledger semantics (`utils/invoicePayments.ts:53,240`) |
| Overpayments/refunds explicit | `overpaidAmount` figure; refunds declared unrepresentable v1 (§3.3) |

---

## 6. Worked examples

### Example A — tracked, change-ordered, fully collected

Job: 4 h @ $85, materials base $300 (+20% markup → $360 charge),
`estimateTotal` $966 (the canonical engine example). Approved CO +$200.
Tracked sessions (all closed): 5.5 h. Linked expenses: materials $340,
fuel $25. Invoice (finalize path) $1,166; payments: $300 deposit (08-01),
`stripe_…` $866 (08-05). `laborCostRate` unset.

| Figure | Value |
|---|---|
| estimatedRevenue / changeOrderRevenue / finalBillable | 966.00 / 200.00 / 1,166.00 |
| invoicedAmount / cashCollected / outstanding / overpaid | 1,166.00 / 1,166.00 / 0.00 / 0.00 |
| estimatedLaborHours / actualLaborHours / variance | 4 / 5.5 / **+1.5 h** |
| estimatedMaterialCost / actualMaterialExpense / variance | 300.00 / 340.00 / **+40.00** |
| otherDirectExpenses | 25.00 |
| estimatedGrossProfit | 966 − 300 = **666.00** (labeled "before paying yourself") |
| actualGrossProfitBilled | 1,166 − 340 − 25 = **801.00** |
| actualGrossProfitCash | **801.00** (fully collected) |
| effectiveHourlyActual | 801 / 5.5 = **145.64/h** (estimate promised (966−360)/4 = 151.50/h) |
| warnings | `fees_unknown` (stripe payment present), `labor_cost_rate_unset` |

"What changed" narrative the drill-down can derive: +$200 scope, +1.5 h labor,
+$40 materials ⇒ profit up $135 vs estimate but $5.86/h below the estimated
effective rate.

### Example B — legacy job (pre-Phase-13 data)

Status `paid`, no `timeSessions`, `job.invoiceId` → legacy invoice $600
(`paid:true`, no ledger), zero linked expenses.

cashCollected 600.00 (legacy fallback), outstanding 0. actualLaborHours
`null`, actualMaterialExpense `null`, otherDirectExpenses `null`.
actualGrossProfitBilled 600.00 **with warnings**
`hours_untracked, expenses_unlinked, legacy_invoice_dates,
labor_cost_rate_unset` — UI renders "no cost data recorded for this job",
not a fake 100%-margin brag.

### Example C — partial, voided, overpaid

Invoice $500 linked to the job. Ledger: $200 valid, $200 **voided**, $350 valid.

cashCollected 550.00 (void excluded), outstanding 0 (clamped),
overpaidAmount **50.00** (explicit), history still shows all three entries
(`paymentsInRange` keeps voids — `utils/invoicePayments.ts:240`).

---

## 7. Migration requirements

**None. Zero data migration, zero backend migration, zero backfill.**

- Both new fields are additive-optional on JSON-blob-synced shapes
  (`Expense` syncs via the `expenses` table; `Settings` via `settings`) — the
  storage-and-sync recipe's cheap case. No Supabase DDL.
- No idempotent sign-in migration is needed: absent means unknown, which is
  the truthful state for every historical record. Backfilling links would
  invent data (kickoff forbids it).
- `laborCostRate` is a plain Settings number, NOT a SECURE_FIELD.
- Sync merge: `expenses` is a replace-table (only `invoices`/`jobs` merge —
  `utils/syncMerge.ts:47-63`); an optional field rides through untouched.
  `clearAllUserData`/`clearSampleData` unaffected.
- CSV export: `expenses.csv` gains a `jobId` column only if the owner wants it
  (Phase 14 territory — flagged, not done here).

---

## 8. Test vectors (Phase B acceptance set, `__tests__/jobProfitability.test.ts`)

| # | Setup | Expected |
|---|---|---|
| T1 | Example A fixtures | every figure exactly as §6A, incl. both warnings |
| T2 | Example B fixtures | nulls + 4 warnings; profit 600.00; never NaN |
| T3 | Example C fixtures | collected 550, overpaid 50, outstanding 0 |
| T4 | CO declined + CO cancelled + CO approved −$150 | changeOrderRevenue −150; finalBillable = estimateTotal − 150 |
| T5 | Open session (no `end`) + one closed 2 h session | actualLaborHours = 2.00 exactly (open excluded, unlike the live JobDetail card) |
| T6 | `timeSessions: []` vs absent | both ⇒ actualLaborHours null + `hours_untracked` |
| T7 | Linked fuel expense only, job has estimated materials | actualMaterialExpense **0.00** (data exists), otherDirect 25; NO `expenses_unlinked` |
| T8 | Zero linked expenses | materials + other both null, single `expenses_unlinked` |
| T9 | Double-count guard: estimated materials $300 + linked materials expense $340 | knownActualCosts contains 340 only, never 640 |
| T10 | Manual invoice (no `jobId`) matching `job.invoiceId` + second linked invoice | deduped union; sums count each invoice once; job with neither ⇒ `invoice_unlinked` when status ≥ invoiced |
| T11 | `laborCostRate: 40`, actual 5.5 h | actualOwnerLaborCost 220.00; profits drop by 220; `labor_cost_rate_unset` absent; effectiveHourlyActual unchanged (cost added back) |
| T12 | Malformed amounts (`"abc"`, NaN, Infinity in ledger/expense) | `toAmount` coercion ⇒ figures finite, never NaN-poisoned (mirrors `invoicePayments.test.js:806`) |
| T13 | `laborHours: 0` estimate, tracked 3 h | laborHoursVariance null (no estimate to compare), actualLaborHours 3.00 |
| T14 | Epsilon: invoice 100, paid 99.999 | outstanding 0 by `PAID_EPSILON` semantics (delegated to `balanceDue`) |
| T15 | Determinism: same inputs, two calls, injected `now` | deep-equal results; warnings order stable |

Plus a legacy-equivalence sweep: for jobs/invoices from
`__fixtures__`-style legacy shapes, revenue figures must equal what
`summarizeInvoices`/`collectedInRange` already report (the
`invoicePaymentsLegacyEquivalence.test.js` pattern).

---

## 9. UX plan (Phases C–D detail to be specced per-phase; summary for approval)

1. **Job Detail — "Estimate vs actual" card** (below the existing breakdown):
   two-column est/actual rows (revenue, hours, materials, profit) + variance
   chips; unknowns render as "—" with the warning text, never $0. Visible from
   `in_progress` onward.
2. **"What changed?" drill-down:** modal listing variance contributors
   (approved COs by title/amount, hours delta × rate, each linked expense) —
   pure presentation of §4 figures, no new math.
3. **Completion-time review:** when a job advances to `complete` (JobDetail
   advance + auto-invoice path), the card surfaces once as a summary moment.
4. **Money tab — aggregate card:** median/mean actual-vs-estimate variance
   across completed jobs **with data** (jobs that are all-warnings excluded,
   count shown); per-type grouping deferred per §3.5 recommendation.
5. **Pricing warning (kickoff UX item 6):** in PricingCalculator, when trailing
   completed-job history shows the owner's median effective hourly BELOW the
   new estimate's projected rate, or median materials overrun would push the
   new job under target margin, show a `getSanityWarnings`-style line
   (`utils/pricingEngine.ts:214`) with the observed numbers. Deterministic,
   suppressed entirely until ≥3 jobs have non-warning data.
6. **AI:** contextual insights consuming these figures are Phase 15 scope; the
   snapshot/prompt additions here are limited to nothing until the pure layer
   ships (AI explains, never calculates — kickoff constraint).

---

## 10. Implementation phases (after approval, each phase-gated)

| Phase | Contents | Gate |
|---|---|---|
| **13B** | `types/models.ts` fields (§3.1, §3.2) + `utils/jobProfitability.ts` pure layer + full test-vector suite (T1–T15 + legacy equivalence). NO UI. | tsc 0 / all tests / lint 0 |
| **13C** | Expense job-linking UI (AddExpenseModal picker + JobDetail pre-linked add), Job Detail card + drill-down + completion review | same |
| **13D** | Money aggregate card + PricingCalculator historical warning + Settings → Pricing `laborCostRate` field | same |
| **13E** | Docs: README (file map, test table, Known limitations: fees/refunds unknown-by-design), ARCHITECTURE.md current-state, models.ts comments; roadmap STATUS block | same |

---

## 11. Open owner decisions (blocking 13B start)

| # | Decision | Recommendation |
|---|---|---|
| D1 | Approve `Expense.jobId?` (persisted-shape change) | **Yes** — the phase is impossible without it |
| D1b | Also build a retro-link/edit affordance for existing expenses? | Defer — expenses have no edit path today; scope creep |
| D2 | Approve `Settings.laborCostRate?` | **Yes** — optional, never defaulted |
| D3 | Refunds v1 | **Out of scope**, stated plainly in UI/docs (matches two prior specs) |
| D4 | Fees v1 | **Unknown + warning**; webhook `balance_transaction` capture as separate follow-up if wanted |
| D5 | Aggregate by job type | **Defer** (`Job.jobType?` as its own later change); v1 aggregates overall |
| D6 | Partial-data profit figures | **Compute + warn** (§4.4 rationale) vs strict-null cascade |
