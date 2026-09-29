# Phase 9 — Money, exports, imports, and pricebook contract decisions

**Task:** 9.00 (freeze contracts and characterize gaps) · **Date:** 2026-09-21

**Status:** Code complete. Characterization only — no implementation file was
changed. Selected contracts are marked chosen; open items are marked blocked.

**How this was produced:** the React Native sources, RN tests, backend routes,
and the existing Swift domain/adapter/store files named per section were read in
full and their behavior recorded below. No oracle test was modified, added, or
skipped. Where an RN predicate has two competing implementations (see §2.4) the
disagreement is recorded rather than reconciled, because Phase 9 must reproduce
RN, not repair it.

Requirement IDs: **M1, M2, E1, E2, T1, T2, P1–P4, X1, X2, I1–I3** (all, for
characterization).

---

## 1. Cash-basis rules (M1)

### 1.1 Date-range construction — local time, no UTC

`utils/moneyUtils.ts` is the single home:

- `getDateRange(filterId)` reads the **real clock** (`new Date()`) — no injectable
  `now`. Presets: `this_month` → `[y,m,1] … [y,m+1,0,23:59:59]`; `last_month` →
  `[y,m-1,1] … [y,m,0,23:59:59]`; `this_year` → Jan 1 … Dec 31 23:59:59;
  `all_time` (and any unknown id) → `new Date(0)` … `new Date(9999,11,31)`.
- `getPreviousRange(filterId)` returns the prior window, or `null` for
  `all_time`/unknown. `this_month`→previous month; `last_month`→two months back;
  `this_year`→previous calendar year.
- `exportDateRange(id, now = new Date())` (`utils/csvExport.ts`) is a separate
  implementation with an injectable `now` and two extra presets: `this_quarter`
  (`q = floor(m/3)*3`, `[y,q,1] … [y,q+3,0,23:59:59]`), `last_year`
  (`[y-1,0,1] … [y-1,11,31,23:59:59]`). `this_month`/`this_year`/`all_time` must
  produce the same instants as `getDateRange`.
- Comparison is `isInRange(dateString, start, end)` → `parseLocalDate(s) >= start && <= end`.
  `parseLocalDate` maps a bare `YYYY-MM-DD` to local midnight via
  `new Date(y, m-1, d)`; any string with a time component falls through to the
  platform parser. Date windows are built with the local constructor on both
  sides — never `new Date("YYYY-MM-DD")` (UTC midnight) and never
  `toISOString()` for a stored date.
- All boundaries are inclusive. Month-end `new Date(y, m+1, 0)` (local midnight on
  the last day) still matches date-only payments because comparison is date-only.

Native contract: port `parseLocalDate`, `isInRange`, `getDateRange`,
`getPreviousRange`, `getLast6MonthLabels` with an injectable `now` for the
`getDateRange`/`getPreviousRange` cases (characterization parallelism), and a
separate `exportDateRange(id, now)` list including `this_quarter`/`last_year`.
Dates stay `YYYY-MM-DD` strings; windows are local-calendar `Date`s. No report may
read the wall clock internally.

### 1.2 Payment-window semantics

`utils/invoicePayments.ts` owns the ledger. Amounts are coerced with `toAmount`
(`parseFloat`, non-finite → 0) on every read.

- `materializeLegacyLedger(invoice)`: returns the stored `payments` copy when
  non-empty; otherwise, for a `paid` legacy invoice, synthesizes exactly one entry
  `{ id: "legacy_<invoice.id>", amount: invoice.amount, date: invoice.paidAt ?? invoice.due,
  method: "other", note: "Recorded before payment history was itemised" }`; an
  unpaid legacy invoice yields `[]`.
- `paymentsInRange(invoice, start, end)`:
  `materializeLegacyLedger(...).filter(isInRange(p.date))`. Voided entries are kept
  in the returned array (history UIs render them struck through). Any caller that
  sums must filter `p.voidedAt` itself.
- `collectedInRange(invoices, start, end)`: sums non-voided in-range payments
  across invoices. Buckets by payment date, so a legacy paid invoice income lands
  on `paidAt ?? due`. Raw float sum — no rounding.
- `collectedByPeriod(invoices, ranges)`: walks each ledger once, adds a non-voided
  payment to every matching window (overlaps double-count intentionally). Entry i
  of the result corresponds to `ranges[i]`.
- `amountPaid` (non-voided sum, or `paid ? amount : 0` when ledger absent),
  `balanceDue` = `max(0, amount - amountPaid)`, `isFullyPaid` =
  `balanceDue <= 0.005` (`PAID_EPSILON`), `isPartlyPaid`, `overpaidAmount` =
  `max(0, amountPaid - amount)`.
- Sort order everywhere is code-unit (`a < b`), never `localeCompare` (Hermes ICU
  variance): `comparePayments` sorts by `(date, id)`.
- `withDerivedPaidFields` recomputes `paid`/`paidAt` from a chronologically sorted
  ledger; `paidAt` = date of the payment that crosses `amount - PAID_EPSILON`;
  otherwise `paidAt` is deleted.
- `mergePaymentLedgers` unions by id, void wins, earliest void date wins on a
  double-void tie, incoming wins on an exact tie, and the stored array is sorted by
  `(date, id)`. (`applyPayment` appends; merges sort.)

Native contract: `PaymentLedger` in `N/Domain/FinancialDomain.swift` already
implements `amountPaid`/`balanceDue`/`isFullyPaid`/`isPartlyPaid`/`overpaidAmount`/
`materializeLegacyLedger`/`collected`/`collectedByPeriod`/`merge` with the same
rules over string-compared `YYYY-MM-DD` dates. Phase 9 reuses it and must not
re-implement ledger math. The only required addition is a
`paymentsInRange(invoice, start, end)` helper (`PaymentLedger.payments(for:from:through:)`
already exists — reuse it) plus `id.hasPrefix("legacy_")` detection for the export
method-blank rule.

### 1.3 Rounding determinism in ledger math

- `roundToCents(n) = Math.round(n*100)/100` (`utils/invoicePayments.ts`); used by
  `resolveDepositAmount`, `settleRemaining` via `balanceDue`, and `jobBillableTotal`.
- `FinancialDecimal.cents` (Swift) = `NSDecimalRound(.plain)` = half away from zero.
- `FinancialDecimal.javascriptCents` = `floor(x*100 + 0.5)/100` = matches JS
  `Math.round` (half toward +∞).
- These agree for every non-negative value and differ only at exact negative
  `….xx5` boundaries. Recommendation: use `javascriptCents` for any figure the RN
  oracle rounds with `Math.round` and that can be negative (e.g. `netProfit`,
  summary-card profit); `cents` is safe for the non-negative ledger amounts.

---

## 2. "In scope" definitions

Three distinct predicates exist; each is recorded with where it applies.

### 2.1 Payments-in-range (income)

`isInRange(payment.date)` over non-voided payments — §1.2. Drives
`collectedInRange`, `collectedByPeriod`, `buildIncomeCsv`,
`buildPaymentActivityCsv`, `TopCustomersCard`, `CustomerMixCard`, and TaxSetAside
income.

### 2.2 Invoice-in-scope (accountant package)

`isInvoiceInScope(i, start, end)` (`utils/accountingPackage.ts`) is true when either:

- `recoverIssueDate(i.id)` is non-null and in range — `recoverIssueDate` strips a
  leading `inv`, requires all-digits, reads the ms as a UTC date, and returns
  `null` unless the UTC year is 2000…2100; it never falls back to the wall clock; or
- the invoice has at least one non-voided in-range payment.

It is the one definition shared by `buildInvoicesCsv`, `buildLineItemsCsv`,
`collectWarnings` (in-scope loop), and `buildSummary.invoices_count`. It is not the
same as payments-in-range, and not the jobs predicate.

### 2.3 Job-done membership

`DONE_STATUSES = {complete, invoiced, paid}`:

- `computeAvgJobValue`: done and `jobBillableTotal(job) > 0` and, when a window is
  passed, `job.createdAt` present and in range (a job with no `createdAt` is
  included in a windowed average).
- `computeRevenueByType`: done and `jobBillableTotal > 0`.
- `computeProfitabilityHistory`: done and `!isArchived(job)` and
  `(job.estimateTotal || 0) > 0`.

`jobBillableTotal(job)` = `roundToCents(estimateTotal + Σ approved change orders)`,
where `changeOrderStatus` = cancelled > approved/declined decision (link decision
beats manual) > awaiting > pending.

`ReceivablesCard` pipeline uses a different list:
`PIPELINE_STATUSES = {lead, estimate_sent, approved, scheduled, in_progress, complete}`
with `jobBillableTotal > 0` (note `declined`/`invoiced`/`paid` are excluded).

### 2.4 Two overdue predicates (record, do not reconcile)

- `invoiceStats.summarizeInvoices` / `invoiceHelpers` `isOverdue`:
  `!isFullyPaid && daysPastDue(due) > 0`, where `daysPastDue` parses `due` as local
  midnight and rounds (DST-safe).
- `ReceivablesCard` "Overdue" list:
  `unpaid.filter(inv => inv.due && new Date(inv.due) < today)` — `new Date("YYYY-MM-DD")`
  is UTC midnight, compared against local-midnight "today".

The plan does not ask native to change either; 9.01/9.09 freeze both as-is so the
card totals match RN byte-for-byte in the timezone the fixtures run in.
Cross-timezone divergence between the two is an RN behavior, not a native bug.

---

## 3. Report rounding and sort contract (M2)

All report functions are pure over canonical arrays; sort order is code-unit
(`a < b`) except where noted; no function mutates input.

| Report (oracle file) | Rounding | Null / empty rule | Sort |
|---|---|---|---|
| `summarizeInvoices` (invoiceStats) | none (raw sums) | `collected`/`outstanding` raw; `overdueCount` via local `isOverdue` | n/a |
| `computeInvoiceAging` (invoiceAging) | `Math.round` on `avgDays` (overall + per customer); `totalAmount += Number(amount)||0` raw face value | skip unless fully paid and `paidAt` and `due`; customer `""` → `"Unknown"` | customers `b.avgDays - a.avgDays` |
| `computeCustomerMix` (customerMix) | none (raw) | customer trimmed+lowercased; empty name skipped; `collected === 0` skipped; first-invoice date from `due` | Map iteration order |
| `computeSeasonalTrends` (seasonalTrends) | `Math.round` on `yoyChangePct` | `yoyChangePct = null` when `lastYearTotal <= 0` | 12 months, oldest→newest |
| `computeExpenseTrends` (expenseTrends) | `Math.round` on `avgMonthly`, `momChangePct`, `overallTrend` | `momChangePct` null when prior ≤ 0; `overallTrend` null when oldest ≤ 0 | 12 months, oldest→newest |
| `computeAvgJobValue` (avgJobValue) | none (`totalValue/count`) | `count = 0` → `avgValue = 0` | n/a |
| `computeConversionFunnel` (conversionFunnel) | none (rates are fractions) | `rate` null when previous stage ≤ 0; `winRate` null when `estimateSent = 0` | fixed stage order |
| `computeRevenueByType` (revenueByType) | `Math.round` on each `pct`; totals raw from `computeEstimateBreakdown` | components only for positive components; `totalRevenue = 0` → empty | labor, materials, overhead |
| `computeRevenueForecast` (revenueForecast) | none | `projectedValue = winRate === null ? 0 : speculative*winRate` | n/a |
| `computeProfitabilityHistory` (profitabilityAggregate) | `roundToCents` on median hourly + median materials variance; `round2` on median labor overrun hours; medians, not means | `null` median when a metric has no data; `MIN_HISTORY_JOBS = 3` gates warnings | numeric value sort |
| `TopCustomersCard` | none | `collected === 0` skipped; top 5 by amount desc | amount desc |
| `SummaryCard` | `Math.round` on each `changePct` | `changePct` null when prev null/0; change label hidden when null or 0 | n/a |
| `MonthlyChart` | none | 6 months; expense filter parses `parseLocalDate(exp.date)` | n/a |
| `ReceivablesCard` | none (raw sums) | hidden when outstanding and pipeline both 0; UTC `overdue` rule (§2.4) | n/a |

Inherited rules to preserve: aging uses the invoice face value, not collected; the
declined-job funnel treatment sets `STATUS_ORDINAL.declined = 1` so a declined job
counts in `lead` and `estimate_sent` and lowers `winRate`; partial payments
contribute to both collected and outstanding in `summarizeInvoices`; overpayment
is surfaced via `overpaidAmount`, never folded into `balanceDue`.

Report card composition and scope (`screens/MoneyScreen.tsx`, drives 9.09):
default filter `this_month`; Overview/Expenses segmented control; sections in order
Cash flow (MonthlyChart, SeasonalTrends, Expenses-by-Category, ExpenseTrends),
Customers & invoices (TopCustomers, CustomerMix, InvoiceAging), Job pipeline
(Receivables, ConversionFunnel, RevenueForecast, AvgJobValue, RevenueByType,
JobProfitability), Tools (Mileage, TaxSetAside, Pricebook), collapsible via
`MoneySection`. `SummaryCard` gets the active filter label and the
`getPreviousRange` comparison. `TaxSetAsideCard` receives only invoices/expenses
(no start/end) → it is deliberately independent of the screen filter. `MileageCard`
receives `start/end`. AvgJobValue receives the previous window. Per-job
profitability is a separate destination (`N/NativeJobProfitabilityView.swift`
already exists).

---

## 4. ZIP determinism contract (X2)

`utils/zipStore.ts` — stored (method 0) only, hand-rolled, zero dependencies.

- `crc32`: standard `0xEDB88320` table, init `0xFFFFFFFF`, final `^ 0xFFFFFFFF`, unsigned.
- `utf8Encode`: manual UTF-8 including surrogate-pair (astral) handling.
- `base64Encode`: standard alphabet, `=` padding, no line breaks.
- `buildZip(entries)`:
  - local header: sig `0x04034B50`, version 20, flags `0x0800` (bit 11 set =
    UTF-8 names), method 0, mod time 0, mod date 0 (zeroed for determinism),
    crc32, compressed = uncompressed = size, name length, extra length 0.
  - central directory: sig `0x02014B50`, version-made-by 20, version-needed 20,
    flags `0x0800`, method 0, time 0, date 0, crc/sizes, name length, extra 0,
    comment 0, disk 0, internal attrs 0, external attrs 0, local offset.
  - EOCD: sig `0x06054B50`, disk 0, disk 0, count, count, central size, central
    offset, comment length 0.
  - Entry order is the caller's order (fixed in `buildAccountingPackage`).
- Byte-equivalence target: for identical `ZipEntry[]` input, `buildZip` returns
  byte-identical `Uint8Array`s across runs and platforms. No difference versus RN
  is permitted in the archive itself; differences are allowed only in the share
  tail (cache path, share sheet).
- BOM placement: CSV entries are `utf8Encode("\uFEFF" + body)`; `summary.json` and
  `README.txt` are written without a BOM. `shareCsv` writes `"\uFEFF" + csv` for the
  standalone CSV share. The pure builders return no BOM.

`buildAccountingPackage` entry order (fixed): `invoices.csv`,
`invoice-line-items.csv`, `active-payments.csv`, `payment-activity.csv`,
`expenses.csv`, `mileage.csv`, `customers.csv`, `category-mapping.csv`,
`export-warnings.csv` (BOM), `summary.json`, `README.txt` (no BOM).
`allTime = start.getTime() === 0`; filename `TradeReady-Accounting_all-time.zip`
or `TradeReady-Accounting_<start>_<end>.zip` (local `ymd`).

---

## 5. Original-file provenance (byte-exact oracles)

| Export | Oracle function | Notes |
|---|---|---|
| income.csv | `buildIncomeCsv` | payments rows; legacy `legacy_` method blank; sorted by `date` (stable); amount `toFixed(2)` |
| expenses.csv | `buildExpensesCsv` (3-col base) / `buildExpensesCsv2` (package, + Job column) | category label; unknown id → `EXPENSE_CATEGORIES[7]` ("Other") |
| mileage.csv | `buildTripsCsv` | raw odometer + miles strings (no decimal padding) |
| invoices.csv | `buildInvoicesCsv` | in-scope filter; sort by issue (nulls last) then number then id |
| invoice-line-items.csv | `buildLineItemsCsv` | sort by number then id; items in stored order |
| payment-activity.csv | `buildPaymentActivityCsv` | includes voided; `Source` ∈ device/stripe/legacy; sorted by (date,id) |
| expenses-with-job | `buildExpensesCsv2` | job name via `jobNameById[jobId]` or "" |
| customers.csv | `buildCustomersCsv` | all customers; sort by name then id |
| category-mapping.csv | `buildCategoryMappingCsv` | the 8 `EXPENSE_CATEGORIES` in order |
| export-warnings.csv | `collectWarnings` + `buildWarningsCsv` | warning push order; codes below |
| summary.json | `buildSummary` + `buildSummaryJson` (`JSON.stringify(_, null, 2)`) | key order = object literal order |
| README.txt | `buildReadme` | exact literal text |

Shared primitives: `escapeCsvField` (quote when `/[",\r\n]/`, double embedded
quotes); `toCsv` (header + rows, CRLF, trailing `\r\n`, no totals row);
`csvRowCount(csv) = (split("\r\n").filter(nonEmpty).length - 1)`.

Warning codes: `missing_issue_date` (warn), `missing_line_items` (info),
`legacy_invoice_no_ledger` (info), `overpayment_present` (warn),
`voided_payments_present` (info), `unknown_expense_category` (warn),
`mileage_is_device_local` (info, when trips in range), `no_records_in_range`
(info). `buildSummary` fields/rounding: `cash_collected=round2(...)`,
`voided_amount=round2(...)`, `expenses_total=round2(...)`,
`net_cash=round2(cashCollected - expensesTotalRounded)`,
`net_cash_basis="cash basis; before owner labor"`,
`mileage_miles_total=round2(Σmiles)`, `warnings_count=collectWarnings(...).length`.

Standalone share filenames (`csvFilename`): `tradeready-<dataset>_all-time.csv` for
all-time, else `tradeready-<dataset>_<start>_<end>.csv` (local dates) for dataset ∈
{income, expenses, mileage}.

---

## 6. AI / OCR transport contract (E2, P4)

### 6.1 Receipt OCR (`utils/receiptOCR.ts`)

- `MAX_RECEIPT_BASE64_CHARS = 5_000_000` (≈3.7 MB decoded), enforced before any
  networking; the backend enforces the same cap independently
  (`backend/lib/guards.js` `MAX_RECEIPT_IMAGE_CHARS`).
- Media types: `image/jpeg`, `image/png` only.
- `splitDataUri`: `/^data:(image\/jpeg|image\/png);base64,(.+)$/s`; anything else → null.
- Transport split: user `settings.anthropicKey` → Anthropic Messages
  (`claude-sonnet-4-6`, `anthropic-version: 2023-06-01`, `max_tokens: 300`, image
  block first then text); else `POST <backendUrl>/api/receipt-extract` with
  `Authorization: Bearer <supabase access_token>` and body
  `{ imageBase64, mediaType }`.
- `extractReceipt` never throws. Oversize, bad mime, no session (token null),
  network/API error, unparseable reply, or "no useful fields" all return `null`.
- `parseReceiptExtraction` clamps per field independently: `merchant` trimmed then
  `slice(0, 80)` (non-empty string only); `amount` finite `> 0`; `date` real
  `YYYY-MM-DD` (rejects rollovers such as 2026-02-31 via
  `toISOString().slice(0,10) === value || localIsoDate(parsed) === value`);
  `category` must be one of the 8 ids; `confidence` `"high"` else `"low"`; returns
  null only when merchant, amount, and date are all null.
- The backend relays the model's JSON object and applies no field clamp; the client
  is the single validation home (the backend also parses the first `{...}` JSON
  object and 502s otherwise). The backend provider is Groq vision
  (`qwen/qwen3.6-27b`), not Anthropic, despite the routes' header prose; native
  treats the endpoint as opaque JSON. `backend/api/receipt-extract.js` and
  `backend-workers/src/routes/receiptExtract.js` must stay behaviorally identical.
- The result type is advisory: `ReceiptScanResult { extraction, route }`; never
  auto-saves. `ReceiptExtraction` is reviewed prefill only.

### 6.2 Pricebook AI suggestions (`utils/pricebookAI.ts`)

- Same client-key/backend split; backend `POST /api/pricebook-suggest` with
  `{ serviceName, description, category, materials, laborHours, laborRate, trade, region }`.
- Limits (guards): `serviceName` required; string fields ≤ 1000 chars; `materials`
  ≤ 50 items, names ≤ 1000; rate limiter 10/min; daily cap.
- No JS-side clamp is applied to the suggestion object; the client extracts the
  first `{...}` JSON and returns it, or `null` on any failure. Native must
  type/validate defensively and treat the result as advisory (never auto-save).
- `AIPricingSuggestion` canonical shape: `laborHours`/`laborRate`
  `{suggested,reasoning}`, `materials[] {name, suggestedUnitCost, reasoning}`,
  `overallRange {low,mid,high,reasoning}`.

---

## 7. Settings mapping (T2)

Wire fields (`types/models.ts` `Settings`, `N/Domain/CanonicalModels.swift` `Settings`):

- `mileageRate: number` — canonical default `0.70`; RN `DEFAULT_MILEAGE_RATE = 0.70`.
- `taxIncomeRate?: number` — optional; absent/null means "unset".
- `vehicleDeductionMethod?: "mileage" | "actual"` — optional; absent means "no
  election" (and the estimator deducts neither).

Estimator (`utils/taxEstimate.ts`, mirrored by `TaxEstimateEngine`):

- Constants: `SE_NET_EARNINGS_FACTOR=0.9235`, `SOCIAL_SECURITY_RATE=0.124`,
  `MEDICARE_RATE=0.029`; `SS_WAGE_BASE = {2025:176100, 2026:184500}` (versioned;
  maintenance on `docs/ops-monthly-checklist.md`).
- Periods are 3/2/3/4 months, weekend-shifted to the next Monday; holidays are
  deliberately not modeled. Q4's deadline is `Jan 15` of `year+1`, formatted with
  the year only when it differs.
- `resolveVehicleDeduction`: `mileage` → `round2(miles*rate)`; `actual` → fuel
  expenses; unset → deduction 0 with `needsChoice = miles > 0 || fuelExpenses > 0`
  (safe failure: deducts neither).
- `estimateTaxReserve`: `netProfit = collected − deductible − vehicleDeduction`;
  `seBase = max(0, netProfit*0.9235)`;
  `seTax = min(seBase, wageBase)*0.124 + seBase*0.029`;
  `incomeTax = max(0, netProfit − seTax/2) * (rate/100)`; all four outputs `round2`
  (`javascriptCents` in Swift). `incomeRatePercent` is clamped `>= 0`.
- Unknown year: compute with `max(SS_WAGE_BASE.keys)` and set `ratesKnown = false`
  (never blank).
- `summarizeTaxWindow`: `current` = current period; `ytd` = `Jan 1 … today`; income
  via `collectedInRange` (cash basis); expenses via `splitDeductibleExpenses` (fuel
  separated); mileage via `mileageSummary`; `incomeRateSet = taxIncomeRate !== undefined
  && !== null`; `needsVehicleChoice` from the YTD window.

Native write/read gap (from source, must be closed by 9.02 + 9.08):
`N/Models.swift` `BusinessSettings` has neither `taxIncomeRate` nor
`vehicleDeductionMethod`. `CanonicalUIAdapters.settings(from:)` (≈ line 763) maps
only `mileageRate`/`laborCostRate`, and `canonical(from: BusinessSettings)` (≈ line
485) emits only `mileageRate`. The edit path
`canonical(from edit: CanonicalUIEdit<BusinessSettings, Canonical.Settings>)`
(≈ line 645) starts from `object(edit.baseline)`, so it currently preserves the two
canonical fields by accident, but the full-write path (`canonical(from: settings)`
in `AppStore.mergeSettingsAndSave` / `commitOnboarding`) would drop them. So the
canonical fields round-trip only partially today. 9.02 (pure mapping + proposed
`SettingsView` diff) and 9.08 (store write path) must add both fields to
`BusinessSettings`, map them on read/write, and keep absent/unknown semantics
(never coerce absent to a value).

---

## 8. Import lifecycle (I1–I3)

Order: pick → parse → detect mapping → date-format detect → validate/preview →
explicit commit → per-row report → record history → undo.

- Parser `parseCsv` (`utils/csvImport.ts`): total RFC-4180 tokenizer, never throws;
  strips a leading BOM; `headers = records[0].map(trim)`; drops single-empty-cell
  rows; pads/truncates to header width; soft cap `DEFAULT_MAX_ROWS = 5000` sets
  `truncated = true` and keeps the first 5000.
- `hashCsv`: FNV-1a-style (`h=0x811c9dc5`, `h=Math.imul(h,0x01000193)`, `>>>0`,
  base16) — non-crypto, re-import warning only.
- `detectMapping` (`utils/importMapping.ts`): `FIELD_DEFS` per entity; `SYNONYMS`
  normalized (`trim().toLowerCase()`, `[_\-]+ → space`, collapse spaces); matching
  is longest-phrase-first, exact then `includes`; unmatched → null.
- `detectDateFormat`: ISO → `YMD`; 4-digit-first numeric → `YMD`; first slot > 12 →
  `DMY`; else `MDY` (US default); `null` when no numeric samples.
- `parseImportDate`: local-frame construction (`new Date(y, mo-1, d)`), rejects
  out-of-range / rollover, returns `toDateString` `YYYY-MM-DD` (never `toISOString`);
  `y < 100` → `+2000`.
- Builders return the full next array + `outcomes: RowOutcome[]` + `counts:
  ImportCounts {ok,skip,flag,created,matched}`; pure, no I/O: `buildCustomerImport`,
  `buildJobImport` (+`mapJobStatus`: recognized → status, else `lead` + flag;
  historical statuses assigned directly, never walked through `next`),
  `buildInvoiceImport` (+`uniqueImportInvoiceId`), `buildExpenseImport`
  (+`mapExpenseCategory`).
- `importBatchId` is stamped only on newly created records, never on matched/
  pre-existing ones. Customers are created only via `upsertCustomerInList` (blank-
  field backfill; no `importBatchId` on match).
- Invoice paid semantics: `paid` only if a real paid date parses; a paid claim that
  is unparseable ("Yes"/"Paid"/"True") flags the row and imports it as outstanding.
  `due` falls back to today; missing invoice number falls back to
  `nextInvoiceNumber`.
- `stripBatch(records, batchId) = records.filter(r => r.importBatchId !== batchId)`
  (undo removes only the batch's own created records).
- History (`utils/importHistory.ts`): device-local, unsynced AsyncStorage key
  `tr_import_history_v1`; `newBatchId = imp_<Date.now()>_<counter>`;
  `recordImportBatch` prepends; `findBatchByFileHash(entity, fileHash)` finds a
  prior batch for the same-file re-import warning. `ImportBatchRecord = { batchId,
  entity, fileHash, date, counts }`.

Native contract: `CanonicalModels` already carries `importBatchId` on
Job/Invoice/Expense/Customer; `Canonical.Expense`/`ExpenseDraft` carry `jobId` +
`receiptUri`. Native must reproduce the exact `ImportCounts`/`RowOutcome` semantics,
the deterministic batch id, and crash-safe local history. Import commit/undo land
in `AppStore` via 9.08 (canonical, field-scoped, preserving unrelated records).

---

## 9. Parity oracle index (frozen fixtures)

RN test files are the behavior oracle. All files below exist; these are the exact
targets for the Swift runners, and the feature must not "fix" any of them.

| Requirement | Oracle test(s) | Oracle source(s) |
|---|---|---|
| M1 date windows / cash basis | `__tests__/moneyUtils.test.js`, `__tests__/invoicePayments.test.js`, `__tests__/invoicePaymentsLegacyEquivalence.test.js` | `utils/moneyUtils.ts`, `utils/invoicePayments.ts` |
| M2 reports | `invoiceStats`, `invoiceAging`, `customerMix`, `seasonalTrends`, `expenseTrends`, `avgJobValue`, `conversionFunnel`, `revenueByType`, `revenueForecast`, `profitabilityAggregate`, `profitabilityDisplay`, `jobProfitability`, `jobProfitabilityDirectCosts` | matching `utils/*.ts`, `utils/changeOrders.ts`, `utils/pricingEngine.ts` |
| T2 tax/vehicle | `__tests__/taxEstimate.test.js`, `__tests__/TaxSetAsideCard.test.js`, `__tests__/TaxSettingsModal.test.js` | `utils/taxEstimate.ts` |
| T1 mileage | `__tests__/mileageUtils.test.js`, `__tests__/timeAndTrip.test.ts` | `utils/mileageUtils.ts` |
| E1/E2 expenses/OCR | `__tests__/AddExpenseModal.test.js`, `__tests__/receiptOCR.test.js` | `utils/receiptOCR.ts`, `utils/anthropicMessage.ts` |
| P1–P4 pricebook | `__tests__/pricebook-storage.test.js` (+ pricebook/template/AI screen tests) | `utils/storage/pricebook.ts`, `utils/pricebookAI.ts`, `utils/tradeTemplates.ts` |
| X1 CSV | `__tests__/csvExport.test.ts` | `utils/csvExport.ts` |
| X2 package/ZIP | `accountingPackage.assemble/builders/readme/summary/warnings.test.ts`, `__tests__/zipStore.test.ts` | `utils/accountingPackage.ts`, `utils/zipStore.ts` |
| I1–I3 import | `csvImport`, `importMapping`, `importEngine`, `importEngine.jobs/invoices/expenses`, `importHistory` tests | `utils/csvImport.ts`, `utils/importMapping.ts`, `utils/importEngine.ts`, `utils/importHistory.ts` |

The "tests expose" vectors named in the plan are already covered by the existing RN
suite and must be reproduced, not rewritten: legacy-ledger income dating
(`invoicePaymentsLegacyEquivalence.test.js`, `csvExport.test.ts`); invoice-in-scope
(`accountingPackage.builders.test.ts` — `recoverIssueDate`, `paymentSource`);
unknown-wage-base (`taxEstimate.test.js` — "an unknown year computes with the latest
known base and flags it", plus 2025/2026 base assertions); ZIP determinism
(`zipStore.test.ts` "… is deterministic"; `accountingPackage.assemble.test.ts`
byte-equal across runs + local file header signature); cross-timezone date-window
edges (`moneyUtils.test.js` date-only boundary cases the old UTC parse got wrong).

---

## 10. Contract decision table

| # | Contract | Decision | Basis |
|---|---|---|---|
| 1 | Local-time date windows, date-only `YYYY-MM-DD` | Chosen | `moneyUtils.ts`; no wall-clock reads inside reports |
| 2 | Ledger math reuses `PaymentLedger` in `FinancialDomain.swift` | Chosen | already present and rules-identical |
| 3 | Three distinct in-scope predicates (§2) | Chosen | `csvExport.ts`, `accountingPackage.ts`, `avgJobValue.ts` |
| 4 | Two overdue predicates kept as-is | Chosen (intentional RN parity) | `invoiceStats` vs `ReceivablesCard` |
| 5 | Code-unit sort everywhere; stable ties | Chosen | `comparePayments` doc + builder comparators |
| 6 | `javascriptCents` for `Math.round` figures that can be negative | Chosen | `FinancialDecimal.javascriptCents` |
| 7 | ZIP stored-only, zeroed DOS time/date, flag bit 11, fixed entry order | Chosen | `zipStore.ts`, `accountingPackage.ts` |
| 8 | CSV BOM on CSV entries only; builders BOM-free | Chosen | `csvExport.ts`, `accountingPackage.ts` |
| 9 | OCR/AI results advisory; never auto-save; client is the single clamp home | Chosen | `receiptOCR.ts`, `pricebookAI.ts` |
| 10 | OCR/pricebook backend provider is Groq (client path is Anthropic) | Chosen (recorded) | backend route headers vs code |
| 11 | Import history device-local at `tr_import_history_v1`, unsynced | Chosen | `importHistory.ts`, `keys.ts` |
| 12 | `importBatchId` stamped on created records only; undo strips only own batch | Chosen | `importEngine.ts` |
| 13 | `taxIncomeRate`/`vehicleDeductionMethod` canonical fields exist but UI drops them | Blocked on 9.02 + 9.08 | `CanonicalModels.swift`, `UIModelAdapters.swift` |
| 14 | Live AI endpoints (Groq/Anthropic) as a runtime dependency | Blocked (Phase 12 evidence) | no live key in-repo; tests use injected transports |
| 15 | Physical-device share sheet / document picker / camera proof | Blocked (Phase 12 evidence) | host tests cannot establish it |

No task is left without a contract or a named blocker.

---

## 11. Native interface / type handoff for independent tasks

Pure-service lane (no shared-file edits):

- 9.01 `N/Domain/NativeCashBasis.swift` (date presets + `isInRange` + payments/
  collected wrappers), `N/Domain/NativeMoneyReports.swift` (per-report pure
  functions). Consumes `PaymentLedger`, `PricingEngine`, `JobProfitabilityEngine`.
- 9.02 `N/Domain/NativeTaxSettings.swift` (canonical `taxIncomeRate`/
  `vehicleDeductionMethod` mapping + `TaxWindowSettings` projection),
  `N/NativeTaxBreakdown.swift`. Proposes the `SettingsView` diff only.
- 9.03 `N/Domain/NativeMileage.swift` (trip math + draft/commit projection).
- 9.04 `N/NativeReceiptOCR.swift` (injected transport; returns reviewed draft).
- 9.05 `N/Domain/NativePricebook.swift`, `N/NativePricebookAI.swift`,
  `N/Domain/NativeTradeTemplates.swift`.
- 9.06 `N/Domain/NativeCSVExport.swift`, `N/Domain/NativeZipArchive.swift`,
  `N/Domain/NativeAccountingPackage.swift`.
- 9.07 `N/Domain/NativeCSVImport.swift`, `N/Domain/NativeImportMapping.swift`,
  `N/Domain/NativeImportEngine.swift`, `N/NativeImportHistory.swift`.

Integration lane (serialized, shared files): 9.08 (`AppStore.swift` +
adapters/`Models.swift`), then 9.09–9.13 (UI). Proposed UI model additions owned by
the lane: `Expense.jobId/receiptUri/importBatchId`, a UI `Trip`, a UI
`PricebookEntry`, and `BusinessSettings.taxIncomeRate/vehicleDeductionMethod`.

Existing code reused, not duplicated: `PaymentLedger`, `TaxEstimateEngine`,
`PricingEngine`, `JobProfitabilityEngine` (`FinancialDomain.swift`);
`Canonical.Expense/ExpenseDraft/Trip/PricebookEntry/Material/AIPricingSuggestion/
Settings`; `CanonicalSnapshot.expenses/trips/pricebook`;
`NativeJobProfitability(.View)`; `NativePricingCalculator`; `NativeTimeTracking`.

---

## 12. Source-discovered gaps (confirming the plan's list)

1. Settings: `BusinessSettings` lacks `taxIncomeRate` and `vehicleDeductionMethod`;
   the read mapping emits neither; the full-write path drops them (§7). Confirmed.
2. Expense UI projection: UI `Expense` (`Models.swift`) has no `jobId`, `receiptUri`,
   or `importBatchId`; `CanonicalUIAdapters.expense(from:)` maps only
   `id/merchant/amount/date/category/notes` and `canonical(from:)` stamps a fresh
   `createdAt` and emits no `receiptUri`/`jobId`. Confirmed.
3. No UI `Trip` or `PricebookEntry` model under `N/` outside the canonical types.
   Confirmed.
4. `MoneyView.swift` is a prototype (70 lines: collected/expenses/net-cash,
   category bar chart, basic expense CRUD) — no report cards, mileage, pricebook,
   tax set-aside, export, or import. Confirmed.
5. Receipt-photo native path must reuse `NativeJobPhotosView` picker patterns; the
   RN `photoStorage` data-URI + downscale contract is the OCR input shape (§6.1).

---

## 13. 9.00 execution ledger update

| Field | Value |
|---|---|
| Status | Code complete / Phase 12 evidence deferred |
| Requirement IDs | all (characterization) |
| Depends on | — |
| Files | `docs/native-phase-9-money-exports-contract-decisions.md` (new) |
| Implementation files changed | none |
| Commands | read-only source/test inspection, then the RN oracle groups in §14 |
| Blockers | §10 rows 13–15 (native settings write-path gap; live-AI and device evidence) |
| Handoff | §9 fixture index, §10 decisions, §11 interface/type handoff |
| Next ready | 9.01, 9.02, 9.03, 9.04, 9.05, 9.06, 9.07 (pure/service lane) |

---

## 14. Oracle verification evidence (actual results)

Run from repository root with `npx jest --runInBand --runTestsByPath ...` to
confirm the contracts above still hold at freeze time:

| Group | Suites | Tests | Result |
|---|---|---|---|
| Export / package / ZIP | 7 (csvExport, accountingPackage.assemble/builders/readme/summary/warnings, zipStore) | 86 | pass |
| Money / cash basis / reports | 16 (moneyUtils, invoicePayments, invoicePaymentsLegacyEquivalence, invoiceStats, invoiceAging, customerMix, seasonalTrends, expenseTrends, avgJobValue, conversionFunnel, revenueByType, revenueForecast, profitabilityAggregate, profitabilityDisplay, jobProfitability, jobProfitabilityDirectCosts) | 541 | pass |
| Tax / vehicle, mileage, pricebook, receipt/expenses | 8 (taxEstimate, TaxSetAsideCard, TaxSettingsModal, mileageUtils, timeAndTrip, pricebook-storage, receiptOCR, AddExpenseModal) | 80 | pass |
| Import | 7 (csvImport, importMapping, importEngine, importEngine.jobs/invoices/expenses, importHistory) | 51 | pass |

Total: 38 suites, 758 tests, all passing. The `TaxSetAsideCard`/`AddExpenseModal`
suites log pre-existing React `act()` overlap warnings but pass; they are not
regressions introduced here.

## 15. 9.14 cross-client qualification evidence

Run on 2026-09-22 from the repository root, after the integration lane closed
(9.08–9.13 implemented). Nothing in the React Native client changed during Phase
9 implementation, so the oracle groups below are expected to reproduce the
section 14 freeze exactly — they do.

### 15.1 The real React Native oracles, re-run

| Group | Suites | Tests | Result |
|---|---|---|---|
| Export / package / ZIP | 7 | 86 | pass |
| Money / cash basis / reports | 16 | 541 | pass |
| Tax / vehicle, mileage, pricebook, receipt/expenses | 8 | 80 | pass |
| Import | 7 | 51 | pass |

Total: **38 suites / 758 tests, all passing** — byte-identical suite and test
counts to section 14, so no oracle drifted while the native port was built.

Command shapes (all `npx jest --runInBand --runTestsByPath <paths>`):

- `__tests__/csvExport.test.ts`, `accountingPackage.assemble/builders/readme/summary/warnings.test.ts`, `zipStore.test.ts`
- `moneyUtils`, `invoicePayments`, `invoicePaymentsLegacyEquivalence`, `invoiceStats`, `invoiceAging`, `customerMix`, `seasonalTrends`, `expenseTrends`, `avgJobValue`, `conversionFunnel`, `revenueByType`, `revenueForecast`, `profitabilityAggregate`, `profitabilityDisplay`, `jobProfitability`, `jobProfitabilityDirectCosts`
- `taxEstimate`, `TaxSetAsideCard`, `TaxSettingsModal`, `mileageUtils`, `timeAndTrip`, `pricebook-storage`, `receiptOCR`, `AddExpenseModal`
- `csvImport`, `importMapping`, `importEngine`, `importEngine.jobs/invoices/expenses`, `importHistory`

### 15.2 The native qualification suite

`sh native/run-phase9-qualification-tests.sh` — **pass** (one fixture pushed
through every Phase 9 surface, so the seams are exercised together rather than
per task):

1. **Reports / tax / mileage.** Cash basis on the fixture collects the paid
   invoice only (1000); the overview's summary card and the mileage log card
   return identical deduction and subtitle strings (`$8.68`, `12.4 mi · 1 trip ·
   $0.70/mi`); the tax card clears the vehicle prompt for an elected method and
   reports the income rate as set.
2. **Pricebook.** The card count reads the same collection the export screen
   reads; create stamps `createdAt` and stores the engine's total (200 for 2h @
   $100); an edit preserves both `createdAt` and a planted unknown field; the job
   prefill moves labor, materials, and direct costs while keeping the job's own
   minimum fee.
3. **CSV bytes.** Income excludes the unpaid invoice and includes the paid one;
   expenses and mileage carry their rows; every export is CRLF-terminated,
   has no blank line, and rebuilds byte-identically; the export screen's live row
   counts equal the CRLF-derived counts.
4. **Deterministic package.** The full ZIP is byte-identical across two builds
   with a stable whole-archive CRC-32; a different window changes the bytes; the
   summary JSON the package carries matches the card figures for the window
   (`net_cash: 749.5`, `range_start: 2026-01-01`). Byte-level parity against the
   RN oracle for the shared fixture remains pinned in `AccountingPackageTests`
   (3931 bytes / CRC-32 555132606; empty package 3626 bytes / CRC-32 117099229).
5. **Import round trip.** The app's own expenses CSV re-imports: the exported
   headers satisfy the required expense columns, the engine reports exactly one
   imported row with the amount (250.5), category (materials), date, and
   description intact and no receipt reference, the pre-existing unrelated
   expense keeps its id, position, and its own `importBatchId`, a deliberate
   second import adds its own row (which is what the same-file warning asks
   about), and `stripBatch` removes only the batch's own record.

The suite is registered with 9.15. Together with the per-task runners it covers
every Phase 9 requirement: M1/M2 (report math + card presentation), E1/E2
(expense CRUD, receipt capture, OCR review), T1/T2 (mileage, rates, tax
set-aside), P1–P4 (pricebook CRUD, templates, prefill, advisory suggestions),
X1/X2 (CSV + deterministic ZIP), and I1–I3 (mapping, commit report, history,
undo).

### 15.3 Remaining deferred evidence (Phase 12, not implemented here)

- Physical-device runs: camera/library capture, the share sheet, the document
  picker, large-file behavior, and layout across sizes.
- The live Anthropic client-key path and the backend bearer path for receipt OCR
  and pricebook suggestions (the transports are implemented; no live endpoint is
  contacted from a host test).
- A signed Release build and any App Store/TestFlight cutover.
