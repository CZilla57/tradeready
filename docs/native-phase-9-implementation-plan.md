# Phase 9 — Subagent Implementation Plan

**Date:** 2026-09-21

**Status:** Ready for contract characterization; no implementation tasks completed.

**Roadmap goal (Phase 9):** Restore the business reporting and accounting surface.

**Scope source:** [native-ios-migration-roadmap.md](native-ios-migration-roadmap.md)
Phase 9 (Deliverables and Exit criteria) plus the parity rows in
[native-parity-matrix.md](native-parity-matrix.md) section "Money, pricebook,
imports, and exports" (rows: Money overview, Expenses, Mileage log/add trip,
Pricebook, Tax set-aside, CSV import, CSV export, Import data).

## 1. Execution contract

Use one bounded task per subagent session. Read this plan, the roadmap Phase 9
section, the parity rows above, and the listed source/tests before editing.
Existing uncommitted migration/backend files are working inputs, not disposable
scaffolding. Do not commit, deploy, run live migrations, or contact production
accounts unless separately instructed.

`N/` means `native/TradeReadyNative/`. Proposed filenames below do not imply files
already exist. Match the existing host-test runners (`native/run-*.sh`) and Xcode
source inclusion rather than introducing another package/build system.

Every implementation task must:

1. State satisfied dependencies and the requirement IDs it implements.
2. Keep policy in pure Swift modules and services injectable; use canonical
   preservation, the existing owner/environment guards, repository, and mutation
   queue. No reporting or accounting policy in a view.
3. Resolve current IDs, merge only owned fields, check async owner/operation
   identity, and publish success only after the relevant durable/server boundary.
4. Add meaningful fixture/failure tests, run focused checks, and compile when
   touching UI/platform wiring. Report exact commands and actual results.
5. Return files changed, test counts/results, limitations/blockers, and
   next-ready task IDs. A blocked task stays blocked; no placeholder action
   counts as done.

### Requirement IDs

- **M1** Date filters and cash-basis calculation rules.
- **M2** Reporting cards: revenue, receivables, aging, expenses-by-category,
  seasonality, profitability (per-job + aggregate), customer mix, top customers,
  revenue forecast, conversion funnel, average job value, revenue by type.
- **E1** Expense create/edit/delete, job link, categories.
- **E2** Receipt photo attach + OCR review flow.
- **T1** Mileage log, trip add/edit/delete, deduction math.
- **T2** Vehicle deduction method, yearly rates, tax set-aside estimate.
- **P1** Pricebook CRUD.
- **P2** Trade templates.
- **P3** Job-prefill from a pricebook entry.
- **P4** AI pricing suggestions.
- **X1** CSV export (income, expenses, mileage).
- **X2** Deterministic accountant ZIP package.
- **I1** Import mapping, date-format detection, validation, preview.
- **I2** Import commit report and device-local history.
- **I3** Import undo.

### Shared-file ownership

- **Integration lane:** only tasks 9.08–9.13 edit `N/AppStore.swift`,
  `N/MoneyView.swift`, `N/SettingsView.swift`, `N/TodayView.swift`,
  `N/RootView.swift` and navigation/tab state. Run those tasks serially even when
  their policy dependencies are ready.
- **Backend/transport lane:** 9.04 and 9.05 share the AI transport split
  (`backend/api/receipt-extract.js`, `pricebook-suggest.js` and the mirrored
  `backend-workers/src/routes/*`). Run serially; keep changes compatible with the
  current RN requests.
- **Pure/service lane:** 9.01, 9.02, 9.03, 9.06, 9.07 use separate files and can
  run in parallel where dependencies permit. They return integration contracts;
  they do not opportunistically edit shared UI/store files.
- The coordinating agent owns aggregate runner/project membership and document
  updates. A task may propose the exact additions; serialize their application.
  Separate worktrees are preferred for concurrent writers; never merge by
  overwriting another task's shared-file edits.

### Existing code this phase builds on (do not duplicate)

The pure math for most Phase 9 reports already exists and must be reused, not
re-implemented:

- `N/Domain/FinancialDomain.swift`: `PricingEngine`, `PaymentLedger`
  (`LedgerInvoice`, `materializeLegacyLedger`, `collected`, `collectedByPeriod`),
  `TaxEstimateEngine` (`TaxWindowSettings`, IRS periods, `resolveVehicleDeduction`),
  `JobProfitabilityEngine`.
- `N/Domain/CanonicalModels.swift`: `Expense`, `ExpenseDraft`, `Trip`,
  `PricebookEntry`, `Material`, `AIPricingSuggestion`, `Settings` (already carries
  `mileageRate`, `taxIncomeRate`, `vehicleDeductionMethod`).
- `N/Domain/CanonicalSnapshot.swift`: `expenses`, `trips`, `pricebook` arrays.
- `N/Domain/UIModelAdapters.swift`: `expense(from:)`, `edit`, `canonical(from:)`.
- `N/NativeJobProfitability.swift` + `N/NativeJobProfitabilityView.swift`.
- `N/NativePricingCalculator.swift`, `N/NativeTimeTracking.swift`.

Known gaps the integration lane must close (found in source review):

- `N/Models.swift` `BusinessSettings` lacks `taxIncomeRate` and
  `vehicleDeductionMethod`; `UIModelAdapters` only maps `mileageRate`.
- UI `Expense` has no `jobId`, `receiptUri`, or `importBatchId`; there is no UI
  `Trip` or `PricebookEntry` model.
- `N/MoneyView.swift` is a prototype (collected/expenses/net-cash + category
  chart + basic expense CRUD) with no report cards, mileage, pricebook, tax
  set-aside, export, or import.

## 2. Dependency graph and waves

```text
9.00 contract/characterization baseline
 |- 9.01 money report + cash-basis engine ------+
 |- 9.02 tax set-aside + vehicle settings ------+
 |- 9.03 mileage domain ------------------------+-- 9.08 canonical AppStore integration
 |- 9.06 CSV export + ZIP builders -------------+     |- 9.09 money overview + report cards
 |- 9.07 CSV import engine + history -----------+     |- 9.10 expenses UI (+ receipt/OCR)
 |- 9.05 pricebook domain (P1-P4) --------------+     |- 9.11 mileage UI
9.04 receipt OCR transport -- 9.10                    |- 9.12 pricebook UI
9.05 AI suggestions -------- 9.12                     |- 9.13 export/import UI
9.08-9.13 -- 9.14 qualification -- 9.15 closeout
```

The diagram expresses interface dependencies, not a requirement to wait for every
backend transport before useful integration. 9.09 can build the pure-computed
report cards against 9.01 while 9.04/9.05/9.07 are still in flight; it is closed
only after 9.08 is merged. 9.10's manual expense path can proceed before OCR; the
receipt/OCR slice is complete only after 9.04.

Recommended waves:

1. **9.00.** Freeze interfaces and characterize gaps even if a backend contract
   stays open. Start race/parity probes here, not at closeout.
2. **Parallel 9.01 / 9.02 / 9.03 / 9.06 / 9.07** and the transport lane
   **9.04 to 9.05**.
3. **Integration lane 9.08 to 9.09 to 9.10 to 9.11 to 9.12 to 9.13**.
4. **9.14 to 9.15.**

## 3. Task packets

### 9.00 — Freeze contracts and characterize gaps

**Depends on:** none. **Owner:** coordinating agent/backend design subagent.
**Requirements:** all (characterization only).

Read roadmap Phase 9, the parity rows, the RN sources and tests listed per task
below, and the existing Swift domain files. Record current behavior in fixtures
without changing implementation. Create
`docs/native-phase-9-money-exports-contract-decisions.md` with:

- **Cash-basis rules:** the exact window semantics of `paymentsInRange`,
  `collectedInRange`, `collectedByPeriod`, and `materializeLegacyLedger`
  (legacy `legacy_<id>` entry dated `paidAt ?? due`, method blank in exports,
  voided excluded), and how the date range is built in local time
  (`getDateRange`/`getPreviousRange`/`exportDateRange`, `parseLocalDate`).
- **"In scope" definitions:** the three distinct contract predicates —
  payments-in-range, invoice-in-scope (`recoverIssueDate` from the id OR an
  in-range non-voided payment), and job-done membership — and where each applies.
- **Report rounding:** which figures use `Math.round(n*100)/100` (JS
  `javascriptCents`) versus `FinancialDecimal.cents`, so Swift reproduces RN
  byte-for-byte where the oracle does.
- **ZIP determinism contract:** stored (method 0), DOS time/date zeroed, flag bit
  11 set for UTF-8 names, entry order fixed, BOM on CSV entries only, `README.txt`
  and `summary.json` not BOM-prefixed. Specify the exact byte-equivalence target
  and what may differ.
- **Original file provenance:** which RN computation is the byte-exact oracle for
  each export (`buildIncomeCsv`, `buildExpensesCsv`, `buildTripsCsv`,
  `buildInvoicesCsv`, `buildLineItemsCsv`, `buildPaymentActivityCsv`,
  `buildExpensesCsv2`, `buildCustomersCsv`, `buildCategoryMappingCsv`,
  `buildWarningsCsv`, `buildSummary`).
- **AI/OCR transport:** exact request/response for `api/receipt-extract` and
  `api/pricebook-suggest` (client key vs backend fallback, image size cap
  `MAX_RECEIPT_BASE64_CHARS`, media types, the shared parse/clamp table), and the
  contract that OCR/pricebook results are advisory and never auto-save.
- **Settings mapping:** the exact canonical `taxIncomeRate` /
  `vehicleDeductionMethod` wire fields and the native settings write path,
  including "unknown year computes with the latest known base and flags
  `ratesKnown: false`".
- **Import lifecycle:** mapping/preview/commit/record/history/undo order, that
  history is device-local and unsynced (`tr_import_history_v1`), the batch-id
  stamping rule (`importBatchId`), the re-import same-file warning via
  `findBatchByFileHash`, and the owner decision that undo strips only the batch's
  own records.
- **Parity oracle index:** the exact `__tests__` files and RN util files that nail
  each requirement, so independent native work can start from frozen fixtures.

**Deliver:** contract decision table (chosen/blocked with reason), fixture index,
and a native interface/type handoff for independent work.

**Done when:** every task has an exact contract or a named blocker; existing
oracle behavior and any proposed intentional difference are distinguished. Tests
expose legacy-ledger income dating, invoice-in-scope, unknown-wage-base, ZIP
determinism, and cross-timezone date-window edges.

### 9.01 — Money report and cash-basis engine

**Depends on:** 9.00 M1/M2 contract freeze. **Requirements:** M1, M2 (pure).

**Read:** `utils/moneyUtils.ts`, `utils/invoicePayments.ts` (`collectedInRange`,
`collectedByPeriod`, `paymentsInRange`, `amountPaid`/`balanceDue`/`overpaidAmount`),
`utils/{invoiceStats,invoiceAging,customerMix,seasonalTrends,expenseTrends,
avgJobValue,conversionFunnel,revenueByType,revenueForecast,profitabilityAggregate,
profitabilityDisplay}.ts`, `utils/jobProfitability.ts`, `utils/changeOrders.ts`
(`jobBillableTotal`); `N/Domain/FinancialDomain.swift`,
`N/NativeJobProfitability.swift`, `N/Domain/UIModelAdapters.swift`.

**Own:** new `N/Domain/NativeMoneyReports.swift`, `N/Domain/NativeCashBasis.swift`;
`native/MoneyReportTests/main.swift` and a focused runner. Do not edit
`FinancialDomain.swift` unless the coordinator extracts the shared predicate
first.

1. Implement the local-time date-range presets (`DATE_FILTERS`, `getDateRange`,
   `getPreviousRange`, `exportDateRange`, `parseLocalDate`, `isInRange`) with an
   injectable `now`.
2. Port each report as a pure function over canonical arrays: `summarizeInvoices`,
   `computeInvoiceAging`, `computeCustomerMix`, `computeSeasonalTrends`,
   `computeExpenseTrends`, `computeAvgJobValue`, `computeConversionFunnel`,
   `computeRevenueByType`, `computeRevenueForecast`,
   `computeProfitabilityHistory`, top customers, and receivables.
3. Preserve RN's rounding, sort order (code-unit, not locale), the aging
   face-value rule (not collected amount), the declined-job funnel treatment, and
   the `winRate === null` propagation into forecast.
4. Emit deterministic fixtures shared with the RN oracle where practical.

**Done when:** default/null/zero/empty, month/quarter/year/all-time/last-year,
previous-range comparison, DST/zone boundary, legacy-paid invoice dating, voided
payment exclusion, partial-payment dual counting, overpayment, missing
`createdAt`, and archived-job exclusion vectors match the RN fixtures exactly.
No mutation occurs merely by computing a report.

### 9.02 — Tax set-aside and vehicle-deduction settings

**Depends on:** 9.00 T2 contract. **Requirements:** T2.

**Read:** `utils/taxEstimate.ts`, `components/money/TaxSetAsideCard.tsx`,
`components/money/TaxSettingsModal.tsx`, `__tests__/taxEstimate.test.js`,
`__tests__/TaxSetAsideCard.test.js`, `__tests__/TaxSettingsModal.test.js`;
`N/Domain/FinancialDomain.swift` (`TaxEstimateEngine` already exists),
`N/Models.swift`, `N/Domain/UIModelAdapters.swift`, `N/SettingsView.swift`.

**Own:** new `N/Domain/NativeTaxSettings.swift`, `N/NativeTaxBreakdown.swift`;
`native/TaxSettingsTests/main.swift` and runner. Settings-UI wiring is a
shared-file edit that must be claimed with the integration lane (see 9.08) —
implement and test the pure mapping here, propose the `SettingsView` diff, and
apply it only through the serialized lane.

1. Add `taxIncomeRate` and `vehicleDeductionMethod` to the UI `BusinessSettings`
   model and to the canonical apply/merge in `UIModelAdapters` (currently absent)
   with exact rounding and optional-semantics preservation.
2. Expose the pure `TaxEstimateEngine.summarize` inputs from canonical
   invoices/expenses/trips plus settings; port the disclaimer text and the
   `ratesKnown` notice; keep the "needs vehicle choice deducts neither"
   safe-failure rule.
3. Model the annual maintenance obligation (`SS_WAGE_BASE`) as a versioned table
   matching RN.

**Done when:** period boundaries (3/2/3/4), weekend-shifted deadlines, unknown
year, mileage-vs-actual election, unset method with vehicle inputs, `incomeRate`
unset (SE tax only), and expense/fuel split fixtures match the RN oracle. Serial
round-trip of the two settings fields preserves unknown/absent values.

### 9.03 — Mileage and trip domain

**Depends on:** 9.00. **Requirements:** T1.

**Read:** `utils/mileageUtils.ts`, `screens/MileageLogScreen.tsx`,
`screens/AddTripScreen.tsx`, `__tests__/mileageUtils.test.js`,
`__tests__/timeAndTrip.test.ts`; `N/Domain/CanonicalModels.swift` (`Trip`),
`N/NativeTimeTracking.swift` (trip/expense canonical commit path).

**Own:** new `N/Domain/NativeMileage.swift`; `native/MileageTests/main.swift` and
runner. Return a trip draft/commit contract; do not edit `AppStore.swift`.

1. Port `computeTripMiles` (end minus start, clamped >= 0, rounded to 0.1),
   `mileageSummary` (window filter, 0.1-rounding, rate-based deduction),
   `formatMiles`, `HOME_LABEL`, `DEFAULT_MILEAGE_RATE`, and `generateTripId`.
2. Define the trip create/edit record projection preserving `fromJobId`/
   `toJobId`/labels/purpose/`createdAt` and unknown fields on edit.
3. Include yearly-rate resolution: `settings.mileageRate` default 0.70 with the
   RN per-tax-year override behavior named in 9.00.

**Done when:** zero/negative/equal/greater odometer readings, 0.1 rounding, empty
window, unknown rate fallback, and edit-preserves-`createdAt`/unknown fixtures
pass. No canonical write occurs in this pure module.

### 9.04 — Receipt OCR transport (owner-key + backend fallback)

**Depends on:** 9.00 AI/OCR contract. **Requirements:** E2 (transport half).

**Read:** `utils/receiptOCR.ts`, `utils/anthropicMessage.ts`,
`utils/photoStorage.ts`, `backend/api/receipt-extract.js`,
`backend-workers/src/routes/receiptExtract.js`, `backend/lib/guards.js`,
`__tests__/receiptOCR.test.js`; `N/NativeEstimateDelivery.swift` and
`N/BuildEnvironment.swift` for the injected-transport/auth-refresh pattern.

**Own:** new `N/NativeReceiptOCR.swift`; `native/ReceiptOCRTests/main.swift` and
runner. Propose (do not silently change) any backend diff; keep it compatible with
the current RN contract.

1. Port `buildReceiptPrompt`, `parseReceiptExtraction`, `splitDataUri`, and the
   independent per-field validation/clamp table (merchant <= 80 chars trimmed,
   amount finite > 0, real ISO date, category in the 8 ids, `confidence` clamped).
2. Implement the injected transport: user Anthropic key path and the
   `/api/receipt-extract` bearer path, with `MAX_RECEIPT_BASE64_CHARS` enforced
   before networking, bounded auth refresh, and the contract that
   `extractReceipt` never throws: every failure returns "no extraction".
3. Return a reviewed-draft type; never return a value that can be committed
   without user confirmation.

**Done when:** oversize image, wrong mime type, no session, network/API error,
unparseable reply, partial JSON (one junk field), rollover date (2026-02-31), and
unknown category fixtures all return null/clamped fields exactly as RN.

### 9.05 — Pricebook domain, templates, job-prefill, and AI suggestions

**Depends on:** 9.00. **Requirements:** P1, P2, P3, P4.

**Read:** `utils/storage/pricebook.ts`, `screens/PricebookScreen.tsx`,
`screens/PricebookEntryScreen.tsx`, `components/PricebookPickerModal.tsx`,
`components/TemplatePickerModal.tsx`, `utils/pricebookAI.ts`,
`utils/tradeTemplates.ts`, `utils/storage/keys.ts`, `utils/sync.ts`
(`pricebook` is a synced collection); `N/Domain/CanonicalModels.swift`
(`PricebookEntry`, `Material`, `AIPricingSuggestion`),
`N/NativePricingCalculator.swift`, `N/Domain/FinancialDomain.swift` (`PricingEngine`).

**Own:** new `N/Domain/NativePricebook.swift`, `N/NativePricebookAI.swift`,
`N/Domain/NativeTradeTemplates.swift`; `native/PricebookTests/main.swift`,
`PricebookAITests/main.swift`, `TradeTemplateTests/main.swift` and runners.

1. Pricebook CRUD record projection: create/edit/delete with `createdAt`/
   `updatedAt` stamping, loss-preserving merge on edit, and the canonical
   `PricebookEntry` field set (labor breakdown, materials, markup, job costs,
   overhead, margin, estimate total).
2. Port the trade templates as structure only — the pinned guardrail is that no
   template contains a rate/quantity/waste/coverage/minimum/legal assertion.
   Applying a template only seeds form state; nothing persists or syncs.
3. Job-prefill: given a pricebook entry, produce the RN job/estimate seeding
   projection without inventing values, for the existing pricing calculator.
4. AI suggestions: same client-key/backend split and JSON clamp as 9.04, against
   `api/pricebook-suggest`/`backend-workers/src/routes/pricebookSuggest.js`.
   Results are advisory and never auto-save.

**Done when:** CRUD round-trip preserves unknown/nested fields; template guardrail
test enforces the no-numbers rule; job-prefill fixtures match RN; AI malformed/
partial/oversize/error fixtures return "no suggestion"; no suggestion writes
canonical state.

### 9.06 — CSV export and deterministic accountant ZIP builders

**Depends on:** 9.00 X1/X2 contract. **Requirements:** X1, X2 (pure).

**Read:** `utils/csvExport.ts`, `utils/accountingPackage.ts`, `utils/zipStore.ts`,
`__tests__/csvExport.test.ts`, `__tests__/accountingPackage.*.test.ts`,
`docs/superpowers/specs/2026-07-31-csv-export-design.md`,
`docs/superpowers/specs/2026-08-07-accountant-package-design.md`;
`N/Domain/FinancialDomain.swift` (`PaymentLedger`).

**Own:** new `N/Domain/NativeCSVExport.swift`, `N/Domain/NativeZipArchive.swift`,
`N/Domain/NativeAccountingPackage.swift`; `native/CSVExportTests/main.swift`,
`ZipArchiveTests/main.swift`, `AccountingPackageTests/main.swift` and runners.

1. Port RFC-4180 escaping (`escapeCsvField`), `toCsv` (CRLF + trailing newline),
   and every builder with exact headers, ordering, and rounding as frozen in 9.00:
   income (payments, legacy method blank), expenses, trips (raw miles), invoices,
   line items, payment activity, expenses-with-job, customers, category mapping,
   warnings, summary.
2. Port `crc32`, `utf8Encode`, `base64Encode`, and `buildZip` (stored, zeroed DOS
   time/date, UTF-8 flag bit 11, deterministic entry order).
3. Port `collectWarnings`, `buildSummary`/`buildSummaryJson`, `buildReadme`,
   `packageFilename`, `csvFilename`, `csvRowCount`, and the range presets.
4. Do I/O in a thin share tail (cache write + share sheet) separate from the pure
   builders, mirroring RN's `shareCsv`/`shareZip` ownership of its alerts; the
   pure builders stay string/byte-in, string/byte-out.

**Done when:** byte-level fixtures match RN for income/expenses/mileage/package
CSVs, and a released package unzips to identical entry names, sizes, and CRCs;
determinism holds across runs (zeroed timestamps); BOM placement is exactly as
specified; `csvRowCount` matches. No screen or store edits here.

### 9.07 — CSV import engine and device-local history

**Depends on:** 9.00 import-lifecycle contract. **Requirements:** I1, I2, I3.

**Read:** `utils/csvImport.ts`, `utils/importMapping.ts`, `utils/importEngine.ts`,
`utils/importHistory.ts`, `screens/SettingsImportScreen.tsx`,
`__tests__/csvImport.test.ts`, `__tests__/importMapping.test.ts`,
`__tests__/importEngine.*.test.ts`, `__tests__/importHistory.test.ts`;
`N/Domain/CanonicalModels.swift` (`importBatchId` on jobs/invoices/expenses/
customers).

**Own:** new `N/Domain/NativeCSVImport.swift` (parser + hash),
`N/Domain/NativeImportMapping.swift`, `N/Domain/NativeImportEngine.swift`,
`N/NativeImportHistory.swift`; `native/CSVImportTests/main.swift`,
`ImportMappingTests/main.swift`, `ImportEngineTests/main.swift`,
`ImportHistoryTests/main.swift` and runners. Return an explicit canonical mutation
plan per entity; do not edit `AppStore.swift` or `SettingsView.swift`.

1. Port the total RFC-4180 tokenizer (`parseCsv`, BOM strip, padded rows, soft
   5000-row cap + `truncated`) and `hashCsv` (FNV-1a-style, non-crypto).
2. Port `FIELD_DEFS`, `SYNONYMS`, `detectMapping` (longest-first),
   `detectDateFormat`, `parseImportDate` (local-frame, never `toISOString`), and
   `toDateString`.
3. Port `buildCustomerImport`, `buildJobImport` (+`mapJobStatus`),
   `buildInvoiceImport`, `buildExpenseImport` (+`mapExpenseCategory`),
   `stripBatch`, `ImportCounts`, `RowOutcome`, and `uniqueImportInvoiceId`.
4. Port the device-local, unsynced history (`newBatchId`, `loadImportHistory`,
   `recordImportBatch`, `findBatchByFileHash`) as its own store with deterministic
   batch ids and crash-safe local persistence.

**Done when:** quote/CRLF/BOM/ragged/truncated parsing; Jobber/Housecall/QuickBooks
header vocabularies; MDY/DMY/YMD detection incl. ambiguous and 4-digit-first;
invalid/rollover dates; unrecognized status-to-lead-flagged; unmatched customer;
duplicate invoice id; matched-vs-created counts; `stripBatch` per-entity;
same-file hash re-import warning; and undo-only-own-records fixtures pass.

### 9.08 — Canonical AppStore integration

**Depends on:** 9.01, 9.02, 9.03, 9.05, 9.07 (local slices may start earlier).
**Requirements:** E1, T1, T2, P1, P3, I2, I3 (commit half).

**Own:** serialized edits to `N/AppStore.swift`, minimal adapters/queue/sync hooks
(`N/Domain/UIModelAdapters.swift`, `N/Domain/CanonicalSnapshot.swift`),
`N/Models.swift` (`BusinessSettings` fields + `Expense`/`Trip`/`PricebookEntry`
UI projection if not added by 9.02/9.03/9.05), and
`native/StoreIntegrationTests/main.swift`.

1. Typed, ID-scoped entry points for: expense upsert/delete with `jobId` and
   `receiptUri`, trip upsert/delete, pricebook upsert/delete, settings
   `taxIncomeRate`/`vehicleDeductionMethod` commit, and import commit/undo.
2. Route every write through the existing canonical draft/merge + durable-commit
   + queue path so unknown/concurrent fields survive. Import commit stamps
   `importBatchId` on created records only and reports exact counts; undo removes
   only the batch's own records and preserves newer mutations.
3. Persist import history locally (unsynced) and scrub owner-bound pending work at
   the account boundary, consistent with existing account-scrub behavior.
4. Receipt-photo attach must survive an unavailable/large/failed pick and never
   block the manual expense save.

**Done when:** injected snapshot/queue failure at each boundary, relaunch, no-op,
concurrent refresh, unrelated-edit preservation, expense-with-shot, trip
edit-preserves-`createdAt`, pricebook edit-preserves-nested, import
commit-then-undo, re-import same file, and account-switch scrubbing pass. Do not
publish a whole stale collection to repair one owned record.

### 9.09 — Money overview and report cards UI

**Depends on:** 9.01 and 9.02; integration-lane availability (normally after 9.08).
**Requirements:** M1, M2, T2 (display).

**Own:** rewrite `N/MoneyView.swift` into Overview/Expenses tabs with the money
section grouping; new `N/NativeMoneyCards.swift` (or per-card views) and the
export hand-off to 9.13.

1. Port the date-filter chips (this_month/last_month/this_year/all_time) and the
   Overview/Expenses segmented control; keep the exact cash-basis semantics from
   9.01.
2. Render every production card from 9.01/9.02 output: Summary (income/expenses +
   previous-period comparison), monthly chart, seasonality, expenses-by-category,
   expense trends, top customers, customer mix, aging, receivables, conversion
   funnel, revenue forecast, average job value (with previous window), revenue by
   type, job-profitability aggregate, mileage card (to 9.11), tax set-aside card
   (own period + disclaimer + vehicle-choice prompt), and pricebook card (to 9.12).
3. Preserve the collapsible `MoneySection` grouping and the tax card's
   independence from the screen filter. Cached data stays usable through refresh
   errors; loading/empty/error states are explicit.

**Done when:** the true-empty state and the filtered-empty state match RN; each
card matches its RN fixture for identical input; the previous-period comparison,
tax disclaimer, and vehicle-choice prompt are present; no placeholder cards. UI
compiles; device layout proof stays deferred.

### 9.10 — Expenses UI with receipt photo and OCR review

**Depends on:** 9.04, 9.08, 9.09 (shared-file serialization).
**Requirements:** E1, E2.

**Own:** new `N/NativeExpenseEditor.swift` (create/edit/delete with job link,
categories, receipt attach) and the receipt-review sheet; replace the prototype
`ExpenseEditor`/expense list wiring in `N/MoneyView.swift` through the integration
lane. Reuse `N/NativeJobPhotosView.swift` photo-picker patterns.

1. Add/edit/delete with the canonical `ExpenseDraft` field set, category picker
   (8 categories), and optional job link resolved by exact ID.
2. Receipt attach: pick/capture, persist bytes to a deterministic native path,
   downscale to the OCR contract, then run 9.04. OCR pre-fills the form for review
   only; it never saves. Every field is user-editable and independently clearable;
   an OCR failure leaves manual entry intact.
3. Delete uses the reviewed/undo-safe path; the row shows receipt presence and the
   job label.

**Done when:** OCR-prefill requires an explicit Save; dismissing/canceling the
review writes nothing; manual save works with OCR unavailable;
oversize/unsupported image and OCR error states are truthful; delete and job-link
edge cases pass. UI compiles; device camera/library proof stays deferred.

### 9.11 — Mileage UI and rates

**Depends on:** 9.03, 9.08, 9.10 (shared-file serialization). **Requirements:** T1, T2 (rates).

**Own:** new `N/NativeMileageLogView.swift`, `N/NativeTripEditor.swift`; Money
Mileage-card destination wiring in the integration lane.

1. Log screen: period filters, summary card (deduction, miles, trip count, rate),
   ordered trip rows with purpose, empty state, and a working "+ Add trip".
2. Trip editor: date, from/to endpoint chips (Home/Shop + jobs by exact ID),
   odometer start/end with live distance preview and the "end less than start"
   invalidation, purpose, save, and delete-with-confirm. Preserve `createdAt` on
   edit.
3. Rates: expose the per-year mileage rate override (via 9.02 settings), default
   0.70, with the local-only disclosure.

**Done when:** no empty buttons; invalid readings block save; edit/delete work;
rates round-trip; cached data survives refresh errors; filters match RN. UI
compiles; device proof deferred.

### 9.12 — Pricebook UI

**Depends on:** 9.05, 9.08, 9.11 (shared-file serialization).
**Requirements:** P1, P2, P3, P4.

**Own:** new `N/NativePricebookView.swift`, `N/NativePricebookEntryView.swift`,
`N/NativeTemplatePickerView.swift`; Money Pricebook-card destination wiring.

1. List CRUD with create/edit/delete and search/sort matching RN.
2. Entry editor over the pricing calculator's shared pricing model: labor
   breakdown, materials, material markup, job costs, overhead, margin, computed
   estimate total, with unknown/nested preservation on edit.
3. Template picker (structure-only seeds) and "apply to job" prefill.
4. AI suggestions panel: request, review, explicit apply/dismiss; never
   auto-applies; malformed/error maps to a typed "no suggestion".

**Done when:** CRUD round-trip; template guardrail respected in UI; prefill hits
the intended job; AI apply is explicit and reversible; no suggestion edits
canonical state. UI compiles; device proof deferred.

### 9.13 — Export and import UI

**Depends on:** 9.06, 9.07, 9.08, 9.12 (shared-file serialization).
**Requirements:** X1, X2, I1, I2, I3.

**Own:** new `N/NativeExportDataView.swift`, `N/NativeImportView.swift`; the Money
header export destination (replace `MoneyView`'s export icon target) and the
Settings "Import data" destination in `N/SettingsView.swift`.

1. Export: date-range chips (this month/quarter/year, last year, all time, custom
   with start/end pickers), the accountant-package row, the three CSV rows with
   live row counts, the footnote, and the share tail from 9.06. Custom range with
   start greater than end blocks with the RN "Check your dates" behavior.
2. Import: file pick, header mapping UI with detected/overridable columns, date
   format selection, validation and preview, explicit commit, per-row commit
   report (ok/created/matched/skipped with reasons), device-local history display,
   same-file re-import warning, and "Undo this import".
3. Never auto-commit; commit and undo report exact counts and preserve unrelated
   records.

**Done when:** every range preset and the custom guards behave like RN; package
and CSV shares produce the 9.06 bytes; import preview/commit/report/history/undo
work end-to-end against the store; no empty buttons. UI compiles; device
share-sheet/document-picker proof deferred.

### 9.14 — Cross-client and hosted-contract qualification

**Depends on:** 9.01–9.13. **Requirements:** all.

**Own:** focused integration fixtures/tests and evidence appended to
`docs/native-phase-9-money-exports-contract-decisions.md`; no opportunistic UI
rewrite.

Exercise RN-to-Swift and Swift-to-RN equivalence for: every report card, tax
set-aside, mileage deduction, pricebook CRUD/prefill, CSV bytes, the full ZIP
package, and the import commit/report/undo lifecycle. Run the real RN oracles
listed in section 4 after any compatibility change. Add a deterministic package
byte-comparison and an import round-trip (export a package, re-import a CSV,
verify counts and undo).

**Done when:** host/model tests pass, every source-discovered gap has implemented
coverage or a named blocker, and remaining device/AI-live/hosted proof is
explicitly deferred to Phase 12. An unavailable live AI endpoint is a dependency,
not a passing test.

### 9.15 — Aggregate verification and evidence closeout

**Depends on:** 9.14.

Register new focused runners in `native/run-all-domain-tests.sh`, verify Xcode
target membership, run the aggregate suite and a signed generic-iPhone Release
build, and record results. Create `docs/native-phase-9-device-runsheet.md` from
the parity rows; link it into the consolidated Phase 12 checklist. Update the
roadmap and parity matrix with completed code versus deferred evidence, never a
blanket "Verified". Record signed and unsigned build results separately and
preserve any unresolved implementation gate.

**Done when:** each requirement has code/test/evidence references; every card,
button, and share action is real; no dependency is silently waived; device/staging
rows have steps, expected result, environment/build, and evidence placeholders. No
deployment or App Store cutover is part of this task.

## 4. Verification commands

Run from repository root. The following RN oracle commands exist today; new
focused Swift runners must be created by their task before being invoked. Use only
relevant oracles per task; run the full aggregate at integration closeout.

```sh
# Date filters, cash basis, and core reports
npm test -- --runInBand --runTestsByPath __tests__/moneyUtils.test.js __tests__/invoiceStats.test.js __tests__/invoiceAging.test.js __tests__/customerMix.test.js __tests__/seasonalTrends.test.js __tests__/expenseTrends.test.js __tests__/avgJobValue.test.js __tests__/conversionFunnel.test.js __tests__/revenueByType.test.js __tests__/revenueForecast.test.js __tests__/profitabilityAggregate.test.ts __tests__/profitabilityDisplay.test.ts __tests__/jobProfitability.test.ts __tests__/jobProfitabilityDirectCosts.test.ts

# Tax set-aside / vehicle deduction
npm test -- --runInBand --runTestsByPath __tests__/taxEstimate.test.js __tests__/TaxSetAsideCard.test.js __tests__/TaxSettingsModal.test.js

# Expenses, mileage, pricebook, receipts
npm test -- --runInBand --runTestsByPath __tests__/AddExpenseModal.test.js __tests__/mileageUtils.test.js __tests__/timeAndTrip.test.ts __tests__/pricebook-storage.test.js __tests__/receiptOCR.test.js

# Export / import
npm test -- --runInBand --runTestsByPath __tests__/csvExport.test.ts __tests__/accountingPackage.assemble.test.ts __tests__/accountingPackage.builders.test.ts __tests__/accountingPackage.readme.test.ts __tests__/accountingPackage.summary.test.ts __tests__/accountingPackage.warnings.test.ts __tests__/csvImport.test.ts __tests__/importMapping.test.ts __tests__/importEngine.test.ts __tests__/importEngine.jobs.test.ts __tests__/importEngine.invoices.test.ts __tests__/importEngine.expenses.test.ts __tests__/importHistory.test.ts

# Existing native foundations
sh native/run-canonical-tests.sh
sh native/run-job-profitability-tests.sh
sh native/run-time-tracking-tests.sh
sh native/run-store-integration-tests.sh

# Integration closeout
sh native/run-all-domain-tests.sh
xcodebuild -project native/TradeReadyNative.xcodeproj -scheme TradeReadyNative -configuration Release -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

For RN edits, run `npm run typecheck` plus the affected screen tests. Backend
tasks must run the existing `backend-workers` test/build commands appropriate to
the AI routes; do not invoke a deploy command to validate a build.

## 5. Reusable subagent prompt

> Implement **task 9.XX only** from `docs/native-phase-9-implementation-plan.md`.
> Read its dependency results,
> `docs/native-phase-9-money-exports-contract-decisions.md`, and the listed
> source/tests first. Report missing prerequisites before touching dependent code;
> independent work may continue. Respect the task file ownership and any existing
> uncommitted work. Reuse the existing pure engines in
> `N/Domain/FinancialDomain.swift` (PricingEngine, PaymentLedger,
> TaxEstimateEngine, JobProfitabilityEngine) rather than re-implementing business
> rules. Use canonical data and field-scoped current-ID mutations; preserve
> unknown/concurrent fields. Reuse owner/environment, persistence, sync,
> photo-picker, and share-sheet boundaries. No reporting, accounting, or pricing
> policy in views. OCR and AI results are advisory and must never auto-save. Add
> meaningful oracle/failure tests and run focused verification, compiling
> UI/platform changes. Record actual commands/results, not expected passes. Return
> requirement IDs covered, files changed, interface handoff, evidence, unresolved
> blockers, and next-ready tasks. Do not edit another task's shared files, invent
> backend guarantees, weaken determinism tests, commit, or deploy.

## 6. Initial execution ledger

All tasks **9.00–9.15 are pending**. The source review used to write this plan is
not test execution or an implementation completion. When work starts, maintain one
row per task: status, owner/session, dependency evidence, files, commands, actual
results, blockers, and handoff. Separate **implementation blocked** from **code
complete / Phase 12 evidence deferred**.

| Task | Requirement IDs | Status | Depends on | Deliverable |
|---|---|---|---|---|
| 9.00 | all | **Code complete** | — | Contract decisions + fixture index |
| 9.01 | M1, M2 | **Code complete** | 9.00 | NativeMoneyReports, NativeCashBasis |
| 9.02 | T2 | **Code complete** | 9.00 | NativeTaxSettings, NativeTaxBreakdown |
| 9.03 | T1 | **Code complete** | 9.00 | NativeMileage |
| 9.04 | E2 | **Code complete** | 9.00 | NativeReceiptOCR |
| 9.05 | P1-P4 | **Code complete** | 9.00 | NativePricebook (+AI, +Templates) |
| 9.06 | X1, X2 | **Code complete** | 9.00 | CSV + ZIP + package builders |
| 9.07 | I1-I3 | **Code complete** | 9.00 | Import engine + history |
| 9.08 | E1, T1, T2, P1, P3, I2, I3 | **Code complete** | 9.01-9.03, 9.05, 9.07 | AppStore integration |
| 9.09 | M1, M2, T2 | **Code complete** | 9.01, 9.02, 9.08 | Money overview + cards |
| 9.10 | E1, E2 | **Code complete** | 9.04, 9.08, 9.09 | Expenses + receipt/OCR UI |
| 9.11 | T1, T2 | **Code complete** | 9.03, 9.08, 9.10 | Mileage log + trip UI |
| 9.12 | P1-P4 | **Code complete** | 9.05, 9.08, 9.11 | Pricebook UI |
| 9.13 | X1, X2, I1-I3 | **Code complete** | 9.06, 9.07, 9.08, 9.12 | Export + import UI |
| 9.14 | all | **Code complete** | 9.01-9.13 | Cross-client qualification |
| 9.15 | all | **Code complete** | 9.14 | Aggregate verification + closeout |

Exit criteria traceability (roadmap Phase 9):

- "Every report matches the React Native fixtures for identical input data" -
  9.01, 9.02, 9.03, 9.09, confirmed by 9.14.
- "Accounting packages are structurally and semantically equivalent" - 9.06
  (byte-level) and 9.13, confirmed by 9.14.
- "OCR never saves extracted values without user review" - 9.04 (never
  auto-commits) and 9.10 (explicit Save required).

---

## 7. Execution log

### 9.00 — Freeze contracts and characterize gaps

- Status: **Code complete / Phase 12 evidence deferred.**
- Files: `docs/native-phase-9-money-exports-contract-decisions.md` (new, 14
  sections: cash-basis rules, three in-scope predicates, rounding, ZIP
  determinism, export provenance, AI/OCR transport, settings mapping, import
  lifecycle, parity oracle index, decision table, interface handoff, gaps,
  evidence). No implementation file changed.
- Commands / results: four RN oracle groups run from the repo root —
  export/package/ZIP (7 suites, 86 tests), money/cash-basis/reports (16 suites,
  541 tests), tax/mileage/pricebook/receipt (8 suites, 80 tests), import
  (7 suites, 51 tests). 38 suites / 758 tests, all passing.
- Blockers (named, non-blocking for the pure lane): native `BusinessSettings`
  write-path gap (closes in 9.02 + 9.08); live AI endpoints and physical-device
  share/picker/camera proof deferred to Phase 12.

### 9.01 — Money report and cash-basis engine

- Status: **Code complete / Phase 12 evidence deferred.**
- Files: `native/TradeReadyNative/Domain/NativeCashBasis.swift`,
  `.../NativeMoneyReports.swift`, `.../NativeMoneyReportsJobs.swift`,
  `.../NativeMoneyReportsReadModels.swift`, `native/MoneyReportTests/main.swift`,
  `native/run-money-report-tests.sh`. `FinancialDomain.swift` was **not** edited;
  `PaymentLedger`/`JobProfitabilityEngine`/`NativeChangeOrders.billableTotal` are
  reused rather than re-derived.
- Interface handoff: `NativeCashBasis` (date presets + `isInRange` + canonical→
  `LedgerInvoice` bridge + `paymentsInRange`/`collected`/`collectedByPeriod`);
  `NativeMoneyReports` (`summarizeInvoices`, `computeInvoiceAging`,
  `computeCustomerMix`, `computeSeasonalTrends`, `computeExpenseTrends`,
  `computeAvgJobValue`, `computeConversionFunnel`, `computeRevenueByType`,
  `computeRevenueForecast`, `computeProfitabilityHistory`, `topCustomers`,
  `receivables`). 9.09 consumes these; 9.14 ports the rest of the oracle fixtures.
- Commands / results: `sh native/run-money-report-tests.sh` — all checks passed.
  Cross-checked the same fixtures against the live RN oracle with a scratch Jest
  probe (since removed): identical output for `summarizeInvoices`
  (1450/300/1), `computeInvoiceAging` (8 days, 2 paid, face value 1500),
  `computeCustomerMix` (1 new/200, 1 returning/300), `computeSeasonalTrends`
  (500/250/100), `computeExpenseTrends` (350/29/null), windowed
  `computeAvgJobValue` (2 jobs/1000, approved CO 1000, pending CO 900),
  `computeConversionFunnel` (5/4/2/1/1/1, winRate 0.5), `computeRevenueByType`
  (1000 with 400/300/300), `computeRevenueForecast` (1000/400/0.5/200/1200),
  legacy-ledger dating (400 on `paidAt`, 400 on `due`), and voided-payment
  exclusion (300 collected, 300 paid, 2 ledger entries).
- Notes: 9.01 only ports the report functions; the remaining M1/M2 oracle vectors
  (full month/quarter/year/all-time matrix, DST/zone sweeps, every card fixture)
  are consolidated in 9.14. New files are auto-included by the Xcode
  file-system-synchronized group; the signed Release build stays in 9.15.

### 9.02 — Tax set-aside and vehicle-deduction settings

- Status: **Code complete / Phase 12 evidence deferred.**
- Files: `.../Domain/NativeTaxSettings.swift`, `.../NativeTaxBreakdown.swift`,
  `native/TaxSettingsTests/main.swift`, `native/run-tax-settings-tests.sh`.
- Interface handoff: `NativeTaxSettingsValues` (canonical read), `NativeTaxSettings.parseRateInput`
  / `draft` (0…60 sheet validation), `applying(_:to:)` + `canonicalFields(_:)`
  (absent stays absent — never coerced to a value or an explicit null),
  `NativeTaxBreakdown.make(summary:values:)` with the exact card copy.
- Commands / results: `sh native/run-tax-settings-tests.sh` — all checks passed.
  Oracle cross-check (scratch Jest probe, since removed) matched every figure:
  Q3 net 630 / YTD 1795 / actual 500 / unset 700, `needsVehicleChoice`,
  `incomeRateSet`, YTD reserve 268.46, "Jun 1 – Aug 31", "Sep 15",
  Q3-2030 "Sep 16", Q4-2030 "Sep 1 – Dec 31"/"Jan 15, 2031".
- Remaining: the two `BusinessSettings` stored fields + `SettingsView` panel are a
  shared-file edit owned by the serialized lane (9.08); the pure mapping is done
  and tested here.

### 9.03 — Mileage and trip domain

- Status: **Code complete / Phase 12 evidence deferred.**
- Files: `.../Domain/NativeMileage.swift`, `native/MileageTests/main.swift`,
  `native/run-mileage-tests.sh`.
- Interface handoff: `computeTripMiles`, `summary(trips:start:end:rate:)`,
  `formatMiles`, `effectiveRate`, `NativeTripDraft` + `validationError`,
  `projectedFields(draft:existing:tripID:createdAt:)`.
- Commands / results: `sh native/run-mileage-tests.sh` — all checks passed
  (30/0/0 miles vectors, 0.1 rounding, empty window, unknown-rate fallback,
  invalid/missing/end-before-start validation, createdAt preservation on edit,
  owned-fields-only projection).
- Note (deliberate): RN replaces the whole trip record on edit and would drop
  unknown fields; native projects owned fields only, so an edit preserves
  unknown/forward-compatible fields. RN also accepts any `Date`-parseable date
  string; native refuses to persist a non-ISO date. Both are recorded as
  intentional, canonical-safety differences.

### 9.04 — Receipt OCR transport

- Status: **Code complete / Phase 12 evidence deferred** (live AI endpoint and
  camera/library proof deferred).
- Files: `.../NativeReceiptOCR.swift`, `native/ReceiptOCRTests/main.swift`,
  `native/run-receipt-ocr-tests.sh`. No backend diff was needed; the routes stay
  untouched and behaviorally identical.
- Interface handoff: `splitDataUri`, `parseReceiptExtraction` (independent
  per-field clamp table), `extractReceipt(dataUri:anthropicKey:transport:)` over
  an injected `NativeReceiptOCRTransport`, plus an explicitly review-only
  `NativeReceiptScanResult`.
- Commands / results: `sh native/run-receipt-ocr-tests.sh` — all checks passed
  (mime/session/network/unparseable failures, 5 MB pre-network cap, junk field
  isolation, 2026-02-31 rollover rejection, unknown category, 80-char merchant
  cap, confidence clamp, `0`/negative/string amounts dropped).

### 9.05 — Pricebook domain, templates, job-prefill, AI suggestions

- Status: **Code complete / Phase 12 evidence deferred.**
- Files: `.../Domain/NativePricebook.swift`,
  `.../Domain/NativeTradeTemplates.swift`, `.../NativePricebookAI.swift`,
  `native/PricebookTests/main.swift`, `native/TradeTemplateTests/main.swift`,
  `native/PricebookAITests/main.swift`, and the three runners.
- Interface handoff: `createFields`/`appliedFields`/`delete`/`search`/`sortedByName`/
  `jobPrefill`, the 7-template catalog with `containsBakedFigures` guardrail and
  `applyTemplate` seeds, and `NativePricebookAI.suggestion(...)` over an injected
  transport with a typed, defensive parse.
- Commands / results: all three runners pass. The engine-derived `estimateTotal`
  round-trips through the canonical record; edits preserve `createdAt` and a
  planted unknown nested field; templates carry no digit/`$`/`%`; AI replies that
  are malformed, partial, oversized, or transport-failed return a typed
  "no suggestion" and never write canonical state.

### 9.06 — CSV export and deterministic accountant ZIP

- Status: **Code complete / Phase 12 evidence deferred.**
- Files: `.../Domain/NativeCSVExport.swift`, `.../Domain/NativeZipArchive.swift`,
  `.../Domain/NativeAccountingPackage.swift`, `native/CSVExportTests/main.swift`,
  `native/ZipArchiveTests/main.swift`, `native/AccountingPackageTests/main.swift`,
  and the three runners.
- Commands / results: all three runners pass. **Byte-level parity achieved:** for
  the shared fixture the assembled package is 3931 bytes with whole-archive
  CRC-32 `555132606` and the empty package 3626 bytes with CRC-32 `117099229` —
  identical to the live RN oracle; the summary JSON string matches
  `JSON.stringify(_, null, 2)` exactly; stored-ZIP round-trip verifies entry
  names, sizes, CRCs, UTF-8 flag bit 11, zeroed DOS time/date, and BOM placement
  (CSVs only).
- Note: the share tail is intentionally thin (`sharePayload`) and the pure
  builders stay string/byte-in, string/byte-out, mirroring RN ownership.

### 9.07 — CSV import engine and device-local history

- Status: **Code complete / Phase 12 evidence deferred.**
- Files: `.../Domain/NativeCSVImport.swift`, `.../Domain/NativeImportMapping.swift`,
  `.../Domain/NativeImportEngine.swift`, `.../NativeImportHistory.swift`,
  `native/CSVImportTests/main.swift`, `native/ImportMappingTests/main.swift`,
  `native/ImportEngineTests/main.swift`, `native/ImportHistoryTests/main.swift`,
  `native/run-import-tests-common.sh` + the four runners.
- Interface handoff: `parseCsv`/`hashCsv`; `detectMapping`/`detectDateFormat`/
  `parseImportDate`; `buildCustomerImport`/`buildJobImport`/`buildInvoiceImport`/
  `buildExpenseImport` with `NativeImportCounts`/`NativeRowOutcome`,
  `mapJobStatus`, `mapExpenseCategory`, `nextInvoiceNumber`,
  `uniqueImportInvoiceID`, `stripBatch`; `NativeImportHistory` (atomic file
  store at key `tr_import_history_v1`, per-entity `findBatch`, crash-safe
  degradation).
- Commands / results: all four runners pass. Oracle cross-check (scratch probe,
  since removed) matched counts and values exactly: customers
  `{ok 2, skip 1, created 1, matched 1}`; jobs `{ok 1, skip 1, flag 1}` with
  statuses `approved|lead`; invoices `{ok 1, skip 1, flag 1, created 1, matched 1}`
  with `INV-9/1250.5/true/2026-04-10` and fallback `INV-0010`; expenses
  `{ok 1, skip 2, flag 1}` with categories `materials|other`.
- Fix found by the tests: Swift treats a CRLF pair as ONE Character, so the parser
  now scans Unicode scalars; the date regexes needed explicit capture groups.

### 9.08 — Canonical AppStore integration

- Status: **Code complete / Phase 12 evidence deferred.**
- Files: `native/TradeReadyNative/AppStore.swift` (new "Phase 9 money records"
  section: typed expense/trip/pricebook commit + delete, tax settings commit,
  import commit/undo/history, published `trips`/`pricebookEntries`,
  `NativeMoneyRecordRefusal`, import-history scrub at the account boundary),
  `native/TradeReadyNative/Models.swift` (`BusinessSettings.taxIncomeRate` /
  `vehicleDeductionMethod`; `Expense.jobId` / `receiptUri` / `importBatchId`),
  `native/TradeReadyNative/Domain/UIModelAdapters.swift` (read/write/edit mappings
  for the two settings fields and the three expense fields, plus
  `updateOptionalNumber`), `native/StoreIntegrationTests/main.swift`,
  `native/run-store-integration-tests.sh` (source list only).
- Interface handoff: `commitExpenseEdit(id:opened:draft:)`,
  `deleteExpenseRecord(id:)`, `commitTripEdit(id:opened:draft:)`,
  `deleteTripRecord(id:)`, `commitPricebookEdit(id:opened:draft:)`,
  `deletePricebookEntry(id:)`, `commitTaxSettings(_:)` / `taxSettingsValues`,
  `commitImport(entity:rows:mapping:dateFormat:fileHash:truncated:environment:)`
  → `NativeImportCommitReport`, `undoImport(batchID:)`, `importHistory`,
  `importBatch(entity:fileHash:)`. 9.09-9.13 consume these; 9.10-9.12 own the UI.
- Commands / results: `sh native/run-store-integration-tests.sh` — PASS
  (the existing 8.08 suites plus 64 new Phase 9 assertions). Regression set:
  `run-adapter`, `run-money-report`, `run-tax-settings`, `run-mileage`,
  `run-pricebook`, `run-pricebook-ai`, `run-trade-template`, `run-csv-export`,
  `run-zip-archive`, `run-accounting-package`, `run-csv-import`,
  `run-import-mapping`, `run-import-engine`, `run-import-history`,
  `run-time-tracking`, `run-job-profitability`, `run-canonical` — all pass.
  `xcodebuild -project native/TradeReadyNative.xcodeproj -scheme
  TradeReadyNative -configuration Release -destination 'generic/platform=iOS'
  CODE_SIGNING_ALLOWED=NO build` — **BUILD SUCCEEDED** (unsigned; signed
  device evidence stays deferred to 9.15/Phase 12).
- Notes (deliberate, canonical-safety): an *unset* tax draft is a true no-op
  (RN re-writes the whole settings blob); the tax settings and expense edits keep
  absent optional fields absent rather than emitting an explicit null; a trip
  edit applies its owned fields over the baseline field bag, so unknown fields
  survive; import history is device-local and is scrubbed at the account
  boundary; a queue failure never rolls back or hides a durable local write.
  `importBatchId` is import provenance and is never editor-writable.
  Undo reproduces RN `stripBatch` exactly (it strips only the imported entity's
  own batch-stamped records); a batch record that was later hand-edited still
  carries the batch marker and is therefore stripped, matching the oracle.
- UI projection decision: `Expense` gained the three canonical fields the list
  and editor need. A parallel UI `Trip`/`PricebookEntry` was **not** added —
  mileage and pricebook screens read the published canonical
  `trips`/`pricebookEntries` arrays and edit through `NativeTripDraft` /
  `NativePricebookEntryDraft`, so 9.11/9.12 do not have to keep a second
  duplicate field set in sync.

### 9.09 — Money overview and report cards UI

- Status: **Code complete / Phase 12 evidence deferred** (device layout proof and
  the signed build stay with 9.15/Phase 12).
- Files: `native/TradeReadyNative/Domain/NativeMoneyCardModels.swift` (new, pure
  presentation layer: `formatMoney`, change/percentage math, visibility gates,
  sort/slice limits, singular/plural copy, semantic tones, and the
  `NativeMoneyOverview` composer), `native/TradeReadyNative/NativeMoneyCards.swift`
  (new SwiftUI cards + `NativeMoneySectionView` collapsible grouping),
  `native/TradeReadyNative/MoneyView.swift` (rewritten from the 70-line prototype
  into chips → segmented control → Overview/Expenses),
  `native/TradeReadyNative/AppStore.swift` (`canonicalInvoices`/`Jobs`/`Expenses`/
  `Customers`/`Trips`/`Pricebook` reads, `moneyOverview(filter:)`,
  `moneyExpenseRows(filter:)`), `native/MoneyCardsTests/main.swift` +
  `native/run-money-card-tests.sh` (new runner), and
  `native/run-store-integration-tests.sh` (source list).
- Interface handoff: 9.10 replaces the minimal manual editor with the full one
  (the screen already commits through `commitExpenseEdit`); 9.11 passes
  `onOpen` to `NativeMoneyMileageCardView`; 9.12 does the same for
  `NativeMoneyPricebookCardView`; 9.13 adds the header export destination that
  replaces `NativeMoneyScreen`'s (currently absent) export icon.
- Commands / results: `TZ=America/Phoenix sh native/run-money-card-tests.sh` —
  all checks passed (20 groups / 196 assertions: formatting, chips/tabs, summary + previous-window
  deltas + margin, six-month chart, expenses-by-category, top customers,
  customer mix, days-to-pay labels/tones/slow payers, receivables, funnel
  connectors + 6% floor + win rate, forecast breakdown, avg job value with
  all-time fallback, revenue breakdown, profitability rows, mileage, tax card
  copy, pricebook copy, expense rows, and the overview composition). Regression
  set: `sh native/run-store-integration-tests.sh` — PASS; `run-money-report`,
  `run-tax-settings`, `run-mileage`, `run-pricebook`, `run-csv-export`,
  `run-accounting-package`, `run-adapter`, `run-canonical`,
  `run-time-tracking`, `run-job-profitability` — all pass. RN oracle re-run:
  14 suites / 288 tests pass. `xcodebuild … Release … CODE_SIGNING_ALLOWED=NO
  build` — **BUILD SUCCEEDED**.
- Cross-check: a scratch Jest probe (since deleted) printed the RN card figures
  for the same fixtures, and the Swift expectations were pinned to that output —
  `changePct` `[50,-50,null,null,50,-67]`, margin `80`, aging `avgDays 1` with
  slow payer Alice `2d`/`$1,250.00`, funnel `[4,3,2,1,1,1]` with connectors
  `↓75%`/`↓67%` and `67% win rate`, forecast `2000/800 → 2533.33` (`likely 78.9%`),
  revenue breakdown `Labor 40% / Overhead & Profit 60%`, profitability rows
  `+2h over` / `$50.00 under` / `$85.50/hr`, mileage `12.4 mi · 2 trips ·
  $0.70/mi`, tax period `Q4-2026` with `needsVehicleChoice`.
- Deliberate differences (recorded, not reproduced): RN's `ExpenseRow` renders
  `new Date("YYYY-MM-DD")` (UTC midnight) through `toLocaleDateString`, so a
  date-only expense shows the **previous day** west of UTC (the probe printed
  "Mar 9" for a Mar 10 expense in Phoenix); native renders the stored local day.
  RN's "(no win rate)" forecast branch is unreachable (`winRate` is
  `approved / estimateSent`, so any non-zero forecast has one); it is ported as
  a guard only.
- Deferred by plan (not placeholders): the header export destination (9.13), the
  mileage-log destination (9.11), the pricebook destination (9.12 — the RN
  "· Tap to manage" tail renders only once wired), and the receipt/OCR expense
  editor (9.10).
- Loading/empty/error surfaces reuse the shared boundaries rather than inventing
  screen-local ones: the canonical snapshot always renders (cached data stays
  usable through a refresh failure), failures surface through the app-wide
  `NativeSyncBanner`, the true-empty overview and the filtered-empty Expenses tab
  use `NativeContentStateView`, and every card hides itself exactly when RN hides
  it (no placeholder or zero-filled cards).

### 9.10 — Expenses UI with receipt photo and OCR review

- Status: **Code complete / Phase 12 evidence deferred** (device camera/library +
  live AI endpoint proof stay with Phase 12).
- Files: `native/TradeReadyNative/NativeExpenseEditor.swift` (new: create/edit +
  delete sheet, 8-category chips, job-link chips, receipt capture with the
  reviewed OCR banner), `.../Domain/NativeExpenseComposer.swift` (new, pure
  policy: `linkableJobs`, `jobTitle`, `amountValue`/`amountText`,
  `validation`/`isoDay`, `applyingScan`, `scanBanner`),
  `.../Domain/NativeReceiptMedia.swift` (new: `r<millis>_<base36>` ids, the
  deterministic `<media-root>/receipts/<id>.jpg` path, atomic install with
  local-bytes-win, JPEG normalization under the OCR cap),
  `.../NativeAITransport.swift` (new: the live client-key + backend-bearer
  transport implementing both advisory protocols), `.../MoneyView.swift`
  (prototype `NativeMoneyExpenseDraft`/`NativeMoneyExpenseEditor` deleted; rows
  now open the editor and show the linked job), `.../AppStore.swift`
  (`persistReceipt`, `receiptDataUri`, `advisoryAnthropicKey`, `scanReceipt`,
  `expenseRecord`, injected `advisoryAITransport`), `.../NativeJobPhotosView.swift`
  (`NativeJobCamera` made module-internal for reuse),
  `.../Domain/NativeMoneyCardModels.swift` (expense row `jobTitle`),
  `native/ExpenseEditorTests/main.swift` + `native/run-expense-editor-tests.sh`
  (new), `native/MoneyCardsTests/main.swift`, `native/StoreIntegrationTests/main.swift`,
  `native/run-money-card-tests.sh`, `native/run-store-integration-tests.sh`.
- Interface handoff: 9.13 reuses `NativeAITransport` for the pricebook AI panel;
  9.11/9.12 keep passing their own destinations into the Money cards.
- Commands / results: `sh native/run-expense-editor-tests.sh` — all checks passed
  (job-link filter/order/always-include, `parseFloat` amount guard, the
  `isInteger ? String(n) : toFixed(2)` amount text, save-guard order and copy,
  untouched-field scan application with independent fields, rollover-date
  rejection, the five banner strings, receipt-id shape/path/traversal rejection,
  local-bytes-win install, and the ImageIO downscale contract: a 3200x2400
  capture normalizes to a complete JPEG under the cap with a bounded long side,
  an unreachable cap and undecodable bytes both return nil).
  `sh native/run-store-integration-tests.sh` — PASS (9.08 suites + 12 new 9.10
  assertions: deterministic path, bytes on disk, undecodable refusal, data-URI
  round-trip, editor baseline, stub-transport scan returns a review-only result,
  unreadable receipt scans to nil, and a scan enqueues nothing).
  Regression set (all pass): `run-canonical`, `run-adapter`, `run-money-report`,
  `run-tax-settings`, `run-mileage`, `run-pricebook`, `run-pricebook-ai`,
  `run-trade-template`, `run-csv-export`, `run-zip-archive`,
  `run-accounting-package`, `run-csv-import`, `run-import-mapping`,
  `run-import-engine`, `run-import-history`, `run-time-tracking`,
  `run-job-profitability`, `run-money-card`, `run-receipt-ocr`.
  RN oracle re-run: `npx jest --runInBand --runTestsByPath
  __tests__/AddExpenseModal.test.js __tests__/receiptOCR.test.js
  __tests__/mileageUtils.test.js __tests__/timeAndTrip.test.ts` — 4 suites / 41
  tests pass. `xcodebuild -project native/TradeReadyNative.xcodeproj -scheme
  TradeReadyNative -configuration Release -destination 'generic/platform=iOS'
  CODE_SIGNING_ALLOWED=NO build` — **BUILD SUCCEEDED** (unsigned; signed device
  evidence stays deferred to 9.15/Phase 12).
- Notes (deliberate): the editor seeds a new expense with today's **local** day
  while RN uses the UTC day (`toISOString().split("T")[0]`) — the same recorded
  difference as the 9.09 expense rows, and the stored value stays a local day
  either way. A receipt scan never auto-saves: it writes draft text only, and
  every field stays independently editable/clearable. `Remove photo` clears the
  reference but leaves the file on disk, matching RN (no orphan-file reclamation
  exists in the oracle). An unknown persisted category id is projected as
  "Other" for display but is never rewritten, because the 9.08 edit path writes
  only changed fields. Receipt bytes are bounded by `NativeReceiptMedia`
  (longest side ≤ 2048, quality 0.7, `MAX_RECEIPT_BASE64_CHARS`) so the OCR cap
  is a property of what is stored rather than of whatever the camera produced.
  `importBatchId` remains non-editable. Native adds an expense **edit** path and
  a row job label that RN does not have (RN's `ExpenseRow` is add/delete only).
- Deferred by plan (not placeholders): device camera/library permission proof,
  the live Anthropic/backend endpoint, and live share-sheet evidence are Phase 12
  items; 9.11 (mileage log destination), 9.12 (pricebook destination), and 9.13
  (export destination) remain unwired cards until their screens exist.

### 9.11 — Mileage UI and rates

- Status: **Code complete / Phase 12 evidence deferred** (device layout + the
  signed build stay with 9.15/Phase 12).
- Files: `native/TradeReadyNative/NativeMileageLogView.swift` (new: period chips,
  "Estimated deduction" card, rate row, newest-first trip rows with swipe
  delete, empty state, "+ Add trip"), `.../NativeTripEditor.swift` (new: date,
  from/to endpoint chips, odometer readings with the live distance line, purpose,
  save, delete-with-confirm), `.../Domain/NativeMileageLog.swift` (new, pure
  presentation: `rows`, `summaryCard`, `endpointChips`, `validationAlert`,
  `distanceText`, `draft(from:)`, `newDraft`, `readingText`),
  `.../MoneyView.swift` (`NativeMoneyDestination` + `navigationDestination(item:)`,
  the mileage card now opens the log seeded with the active filter),
  `.../AppStore.swift` (`effectiveMileageRate`),
  `native/MileageLogTests/main.swift` + `native/run-mileage-log-tests.sh` (new).
- Interface handoff: 9.12/9.13 add their own `NativeMoneyDestination` cases and
  card closures; 9.13's export screen reuses the same period-chip pattern.
- Commands / results: `sh native/run-mileage-log-tests.sh` — all checks passed
  (in-range filtering and newest-first ordering by date string, route/date/miles
  copy, the row accessibility label, `$8.68` for 12.4 mi at $0.70, singular vs
  plural trip copy, zeroed empty-window copy, base-first endpoint chips with
  `customerName → title → Job` labels and archived jobs still offered, the three
  RN alert title/copy pairs in RN's check order, "Trip distance: 12.4 mi" vs
  "End reading is less than start", equal readings allowed, and draft seeding
  including a kept `0` reading).
  Regression set (all pass): the full focused list from 9.10 plus
  `run-mileage-log`. `sh native/run-store-integration-tests.sh` — PASS. RN oracle:
  `npx jest --runInBand --runTestsByPath __tests__/mileageUtils.test.js
  __tests__/timeAndTrip.test.ts` — pass (in the 9.10 oracle run).
  `xcodebuild … Release … CODE_SIGNING_ALLOWED=NO build` — **BUILD SUCCEEDED**.
- Notes (deliberate): the editor keeps a `0` odometer reading (`String(0)`),
  where RN's `String(t.odometerStart || '')` blanks it and then refuses to save
  without both readings — a lossy RN quirk that is not reproduced. The log screen
  exposes the stored `settings.mileageRate` (9.02's canonical field, default
  0.70) inline with the honest disclosure that it is saved with settings; RN's
  TaxSetAsideCard line "Mileage from this device's trip log … not synced" is
  **not** reused here because `trips` is a synced canonical collection in this
  app (`NativeSupabasePush` table list + initial sync both carry it). That RN
  string is still shipped verbatim by 9.09's tax card for parity and is flagged
  for reconciliation at 9.14/9.15.
- Deferred by plan (not placeholders): device proof and the pricebook/export
  destinations (9.12/9.13).

### 9.12 — Pricebook UI

- Status: **Code complete / Phase 12 evidence deferred** (device layout + the
  live AI endpoint stay with 9.14/9.15/Phase 12).
- Files: `native/TradeReadyNative/NativePricebookView.swift` (new: search,
  category-grouped sections with Uncategorized last, quoted totals, delete with
  confirmation, empty state, "+ Add Service"),
  `.../NativePricebookEntryView.swift` (new: the editor, the scope checklist, the
  AI panel, save/delete, "Use in a job"),
  `.../NativeTemplatePickerView.swift` (new: the template sheet **and**
  `NativePricebookJobPickerView`), `.../Domain/NativePricebookPresentation.swift`
  (new, pure: list grouping/search, the editor's text layer, the direct-cost
  catalog, template seeding, suggestion rows/apply, `NativePricebookPrefill`),
  `.../MoneyView.swift` (`NativeMoneyDestination.pricebook`, the pricebook card
  now opens the screen and renders RN's "· Tap to manage" tail),
  `.../AppStore.swift` (`pricebookSuggestion(_:)`, `minimumJobFee`),
  `.../Domain/NativeMoneyCardModels.swift` (`NativeMoneyFormat.quote`),
  `native/PricebookUITests/main.swift` + `native/run-pricebook-ui-tests.sh` (new).
- Interface handoff: 9.13 renders the export/import screens; the pricebook picker
  and `NativePricebookPrefill` are reusable if a later phase adds a pricebook
  entry point inside the job flow.
- Commands / results: `TZ=America/Phoenix sh native/run-pricebook-ui-tests.sh` —
  all checks passed (section grouping/order, name-only list search, whole-dollar
  vs cent totals, category suggestions, `parseFloat || 0` parsing, text
  round-trip through the canonical record, blank-optional-to-absent, the live
  engine total incl. the minimum-fee floor, the direct-cost catalog/defaults/
  passthrough math, template seeding rules and the no-figures guardrail, the AI
  row copy/order/apply semantics incl. case-insensitive material matching and the
  display-only range, and the job prefill moving only the entry's pricing fields
  while keeping the job's travel/emergency/minimum/tax).
  Regression set (all pass): the 9.11 list plus `run-pricebook-ui`;
  `sh native/run-store-integration-tests.sh` — PASS. `xcodebuild … Release …
  CODE_SIGNING_ALLOWED=NO build` — **BUILD SUCCEEDED**.
- Notes (deliberate): the list search matches the **name only**, exactly like
  `PricebookScreen` (9.05's `search` also matches category and stays available
  for the pickers). Section ordering uses a localized case-insensitive compare to
  stand in for RN's `localeCompare` (a code-unit compare would put "Electrical"
  before "Plumbing" here too, but the oracle is locale-aware). The estimate total
  is the pricing engine's own number with the configured minimum fee, so a
  half-filled form prices at that floor rather than at zero — matching RN, which
  passes the same `minimumJobFee`. A blank direct-cost label round-trips raw
  (the UI shows the category name in its place). "Use in a job" performs a real
  P3 prefill: it loads the service's pricing into the chosen job's calculator for
  review, and nothing is written until the job is saved.
- Deferred by plan (not placeholders): the live AI endpoint, device proof, and
  9.13's export/import screens.

### 9.13 — Export and import UI

- Status: **Code complete / Phase 12 evidence deferred** (document-picker,
  share-sheet, and live-endpoint proof stay with Phase 12).
- Files: `native/TradeReadyNative/NativeExportDataView.swift` (new: range chips +
  custom pickers, the accountant-package row, the three CSV rows with live counts,
  the footnote, and the share tail over `NativeShareSheet`),
  `.../NativeImportView.swift` (new: entity chips, `.fileImporter` pick, mapping
  with per-column pickers, date-format selector, preview, explicit commit,
  capped per-row report, undo, and device-local history),
  `.../Domain/NativeExportImportPresentation.swift` (new, pure: range choices +
  guard, export rows, `NativeExportShare`, the import lifecycle copy/validation/
  report/history projection), `.../MoneyView.swift` (header export action +
  `NativeMoneyDestination.exportData`), `.../SettingsView.swift` (the placeholder
  "Choose a CSV file" button in `ImportSettings` — a dead affordance — replaced by
  a real `NavigationLink` to `NativeImportView`),
  `native/ExportImportUITests/main.swift` + `native/run-export-import-ui-tests.sh`
  (new).
- Interface handoff: phase 9's integration lane is now closed; 9.14 consumes these
  screens' contracts for qualification, and 9.15 registers both new runners.
- Commands / results: `TZ=America/Phoenix sh native/run-export-import-ui-tests.sh`
  — all checks passed (the six range chips and ids, every preset against
  `exportDateRange`, custom whole-day spans with the inclusive local end of day,
  the reversed-custom guard and its copy, the live row counts per dataset, dated
  vs all-time filenames, the footnote, the BOM-prefixed CSV payload and untouched
  ZIP payload, the share-file write/replace, per-entity required columns and the
  "Still need:" copy, the date-column gate and auto-detection samples, the four
  per-entity report lines, the 1-based outcome copy, the 50-row report cap with
  its overflow count, the undo copy per entity, the same-file/large-file/failure
  copy, the history line, and the engine seam proving the screen's summary line
  matches `buildCustomerImport`).
  Regression set (all pass): the 9.12 list plus `run-export-import-ui`;
  `sh native/run-store-integration-tests.sh` — PASS. `xcodebuild … Release …
  CODE_SIGNING_ALLOWED=NO build` — **BUILD SUCCEEDED**.
- Notes (deliberate): the export screen shares through `UIActivityViewController`
  with the file written to the temporary directory (RN's `expo-sharing` cache
  equivalent); re-sharing replaces the same filename rather than accumulating
  copies. The import screen adds a **device-local history** section — RN records
  `tr_import_history_v1` but never renders it — and reuses the report's own counts
  line, so the two readings cannot drift. The re-import warning is a question
  ("Import again?"), never a block. `NativeImportCopy` keeps every user-facing
  string from the RN screen (including "0 skipped" phrasing) so the report is
  byte-for-byte comparable.
- Deferred by plan (not placeholders): document-picker and share-sheet proof on a
  device, the live AI endpoint, and any hosted-contract checks — all Phase 12.

### 9.14 — Cross-client and hosted-contract qualification

- Status: **Code complete / Phase 12 evidence deferred** (device, share sheet,
  document picker, and live AI endpoints).
- Files: `native/Phase9QualificationTests/main.swift` +
  `native/run-phase9-qualification-tests.sh` (new),
  `docs/native-phase-9-money-exports-contract-decisions.md` (new section 15).
  No UI was rewritten.
- Commands / results: `TZ=America/Phoenix sh native/run-phase9-qualification-tests.sh`
  — **pass** (fixture pushed through reports + cards, tax set-aside, mileage,
  pricebook CRUD/prefill, all three CSV exports, the deterministic package, and
  the import round trip; see contract-doc section 15.2 for the itemized
  assertions). RN oracles re-run after the integration lane closed, reproducing
  the section 14 freeze exactly: export/package **7 suites / 86 tests**, money
  **16 / 541**, tax-mileage-pricebook-receipt **8 / 80**, import **7 / 51** —
  **38 suites / 758 tests, all passing**.
- Notes: byte-level RN parity for the package remains pinned by
  `AccountingPackageTests` (3931 bytes / CRC-32 555132606), and 9.14 adds
  cross-build determinism plus a stable whole-archive CRC over the qualification
  fixture. The round trip proves the app's own export is re-importable with the
  counts the screen reports, and that undo strips only the batch it created.
- Blocker (named, non-blocking): a live AI endpoint is a Phase 12 dependency, not
  a passing test — both advisory transports are implemented and stubbed in tests.

### 9.15 — Aggregate verification and evidence closeout

- Status: **Code complete** (Phase 12 device/staging rows remain open by design).
- Files: `native/run-all-domain-tests.sh` (the six Phase 9 runners registered
  ahead of the legacy-import runner), `docs/native-phase-9-device-runsheet.md`
  (new), `docs/native-phase-12-implementation-plan.md` (consumes the new
  runsheet), `docs/native-parity-matrix.md` (the money/pricebook/import/export
  rows moved off `Prototype`/`Not started` with their runner references),
  `docs/native-ios-migration-roadmap.md` (Phase 9 status header).
- Commands / results:
  - `TZ=America/Phoenix sh native/run-all-domain-tests.sh` — **exit 0**; the log
    shows the six new Phase 9 runners passing in sequence
    (`Expense editor`, `Mileage log`, `Pricebook UI`, `Export/import UI`,
    `Phase 9 qualification`, `PASS: canonical AppStore integration`) alongside
    the pre-existing native suites and the backend-worker jest run.
  - `xcodebuild … -configuration Release -destination 'generic/platform=iOS'
    CODE_SIGNING_ALLOWED=NO build` — **BUILD SUCCEEDED** (unsigned).
  - `xcodebuild … -configuration Release -destination 'generic/platform=iOS'
    build` (signing allowed) — **BUILD SUCCEEDED** with
    `Signing Identity: "Apple Development: Chad Rector (9HBXYALFY3)"`.
  - Xcode target membership: every new file is picked up by the project's
    file-system-synchronized group — proven by the two builds above, which
    compile the new screens and would fail on an unresolved reference otherwise.
- Notes: the aggregate runner previously held the Phase 9 runners back by design
  (9.15 owns registration); it now runs them. `run-all-domain-tests.sh` needs a
  writable clang module cache, so it is run outside the sandbox in this
  environment. The runsheet is linked from the Phase 12 plan's absorbed-runsheet
  list, and each parity row names the runners that back it so a reviewer can
  reproduce the claim.
- No deployment, TestFlight submission, store metadata change, or live migration
  was performed.

### Remaining in Phase 9

**Nothing is pending implementation.** 9.00 through 9.15 are code complete:
contracts frozen, the pure engines ported, the canonical store integrated, all
five feature screens (Money + cards, expenses/OCR, mileage, pricebook, export +
import) wired with real destinations, qualification run against the RN oracles,
the runners registered in `native/run-all-domain-tests.sh`, and the roadmap,
parity matrix, and device runsheet updated.

What stays open is **evidence, not code**, and it is scheduled in
[native-phase-9-device-runsheet.md](native-phase-9-device-runsheet.md) for Phase
12: physical-device runs (camera/library capture, share sheet, document picker,
layout), live Anthropic/backend endpoint checks for receipt OCR and pricebook
suggestions, and a TestFlight build. The parity-matrix rows read `In progress`
rather than `Verified` until those runs pass. No deployment, TestFlight
submission, store-metadata change, live migration, or production account contact
happened in this phase.
