# Phase 9 Device Runsheet (scheduled for Phase 12)

Per the 2026-09-16 deferral decision, the physical-device, live-endpoint, and
share/document-picker rows below are **scheduled work for Phase 12
TestFlight/beta**, not per-phase gates. Host evidence (focused suites, the
aggregate suite, the unsigned Release build, and the signed Release build) gates
code-complete; the rows here gate `Verified`.

Scope: Phase 9 (business reporting and accounting surface) — see
[native-phase-9-implementation-plan.md](native-phase-9-implementation-plan.md)
for per-task evidence and
[native-phase-9-money-exports-contract-decisions.md](native-phase-9-money-exports-contract-decisions.md)
for the frozen contracts.

Conventions: `[ ]` open, `[x]` passed with evidence link/date. Record device
model, iOS version, account type, and build ID per row. Use synthetic data in a
staging/TestFlight account; never production customer data.

## Money overview (device)

- [ ] Period chips (This Month / Last Month / This Year / All Time) change every card consistently on device
- [ ] Cash-basis summary, margin block, and previous-window deltas render with large Dynamic Type and in dark mode
- [ ] Six-month chart, expenses-by-category, expense trends, top customers, customer mix, and invoice aging cards render without truncation
- [ ] Receivables, conversion funnel, revenue forecast, average job value, revenue-by-type, and profitability cards hide exactly when RN hides them
- [ ] True-empty state appears only when invoices, expenses, and jobs are all empty
- [ ] Pull-to-refresh against staging; a failed refresh keeps cached figures visible
- [ ] Tax set-aside card states its own IRS window and deadline; the vehicle-choice prompt appears for an unset election

## Expenses + receipt OCR (device)

- [ ] Create an expense with category, optional job link, and notes; the row then shows the receipt glyph and the job label
- [ ] Edit an existing expense; `createdAt` and any server-side concurrent change behave per policy (stale copy refuses, draft retained)
- [ ] Delete via swipe and via the editor, each behind its confirmation
- [ ] Attach a receipt from the camera and from the photo library; the photo previews after attaching
- [ ] Gallery permission denied → the flow states the problem and manual entry still saves
- [ ] Camera unavailable → only the library option is offered
- [ ] Oversize/unreadable image → "That image couldn't be used for a receipt." and the form is unchanged
- [ ] Receipt scan with a client Anthropic key → fields pre-fill for review only; Save is still required
- [ ] Receipt scan with no client key → backend bearer path (signed in) fills or fails truthfully
- [ ] Airplane mode / backend down → "Couldn't read the receipt — enter the details manually"; manual save works
- [ ] Scan never clobbers a field already typed; removing the photo clears the banner
- [ ] Receipt bytes survive app relaunch (stored under the app's media root)

## Mileage log + trip editor (device)

- [ ] Period chips filter the log; the summary card matches the trip rows in view
- [ ] "+ Add trip" saves with from/to chips (base + jobs) and shows the live distance line
- [ ] End reading below the start blocks save with the RN copy; equal readings save
- [ ] Edit preserves `createdAt`; delete works from the row and the editor
- [ ] Mileage rate edits round-trip to Settings and change the deduction on both the log card and the Money card
- [ ] A trip with a `0` start reading reopens with `0` (not blank) and saves unchanged

## Pricebook (device)

- [ ] List: search, category grouping with Uncategorized last, quoted totals, delete confirmation
- [ ] Create a service; the editor's Estimated Total tracks labor, materials, markup, overhead, and margin
- [ ] Materials and direct costs add/edit/delete; a passthrough direct cost ignores markup
- [ ] Template picker seeds empty lines and the scope checklist; typing first is never overwritten
- [ ] "Use in a job" prefill lands in the chosen job's pricing calculator and saves only on that screen
- [ ] AI panel: request with a client key and via the backend; Apply is per row; a malformed/error reply shows "AI pricing is unavailable right now"
- [ ] Edit preserves unknown fields and `createdAt`

## Export / accountant package (device)

- [ ] Range chips: This Month / This Quarter / This Year / Last Year / All Time change the row counts
- [ ] Custom range with From > To blocks with "Check your dates"
- [ ] Share income CSV, expenses CSV, and mileage CSV; each opens correctly in Numbers/Files
- [ ] Share the accountant package; the ZIP opens and contains the 11 documented entries
- [ ] Shared CSVs open in Excel/Numbers/Google Sheets with correct accents (UTF-8 BOM)
- [ ] Cancelling the share sheet leaves no partial file behind in the user's view

## Import (device)

- [ ] Pick a CSV via the document picker; unreadable/empty files report truthfully
- [ ] Header mapping auto-detects and is overridable per column; Ignore is available
- [ ] Date-format selector appears only when a date column is mapped; Auto matches the file
- [ ] "Preview import" refuses with "Still need: …" until required columns are mapped
- [ ] "Import now" writes once and reports exact counts (ok/created/matched/skipped/flagged)
- [ ] Re-importing the same file asks "Already imported?" and imports only on confirmation
- [ ] A file over 5,000 rows warns and imports the first 5,000
- [ ] Undo removes only that batch's records; a previously existing record is untouched
- [ ] Import history is visible after relaunch, and is gone after an account switch on the same device
- [ ] Imported records sync to a second device and appear in Money/Jobs/Invoices

## Cross-client equivalence (device + staging)

- [ ] RN and native show identical figures for the same account on one date (screenshot pair)
- [ ] Exporting the same range from RN and from native yields identical CSV bytes (diff)
- [ ] Importing one CSV on native and the same CSV on RN produces identical records
- [ ] A native export re-imported on RN (and vice versa) round-trips the same counts

## Exit checklist for Phase 12

- [ ] Every row above has device/staging evidence or an explicit, recorded waiver
- [ ] Any row that fails is recorded as a defect with the build ID, not silently waived
- [ ] The parity matrix is updated from `In progress` to `Verified` only after the rows above pass
