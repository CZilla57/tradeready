# CSV Export (Accounting Export) — Design

**Date:** 2026-07-31 · **Branch:** `feat/csv-export` · **Roadmap:** post-launch item #7
**Status:** owner-approved design (2026-07-31); ships FIRST of the three-branch effort
(CSV → PDF-logo-size → recurring-invoices).

## Goal

Let the tradesperson hand their accountant the year's numbers: export income,
expenses, and mileage as CSV files over a selectable date range, delivered
through the platform share sheet. Low effort, no schema changes, no new
dependencies, JS-only (OTA-eligible).

## Owner decisions (2026-07-31)

| Decision | Choice |
|---|---|
| Scope | Income + expenses + mileage (all three) |
| Delivery | One export screen; one share action per dataset (one CSV per `Sharing.shareAsync` call) |
| Rejected | Combined single CSV with Type column (messy imports); email-only delivery via MailComposer (share sheet reaches email anyway) |

## Design

### 1. Pure builders — `utils/csvExport.ts` (new)

No I/O. Everything unit-testable.

- `escapeCsvField(value: string): string` — RFC-4180: wrap in quotes when the
  value contains `,`, `"`, `\r`, or `\n`; double embedded quotes.
- `buildIncomeCsv(invoices: Invoice[], start: Date, end: Date): string`
- `buildExpensesCsv(expenses: Expense[], start: Date, end: Date): string`
- `buildTripsCsv(trips: Trip[], start: Date, end: Date): string`

Format rules (all three builders):

- Header row always present; an empty range exports headers only (predictable
  for accountants, proves the export "worked").
- Rows sorted by date ascending.
- Amounts as plain `1234.50` (two decimals, no `$`, no thousands separators —
  import-friendly). Dates as `YYYY-MM-DD`.
- CRLF line endings; **no totals rows** (they poison spreadsheet imports).

### 2. Income semantics — payment-level rows

Income rows are **payments, not invoices** — this is what makes deposits and
partial payments export on the date the money actually arrived. Semantics
must match `collectedInRange` (`utils/invoicePayments.ts`) exactly:

- Ledger invoices: one row per non-voided payment whose `date` is in range.
- Legacy invoices (no `payments` array): if `paid`, one implicit row for the
  full amount dated `paidAt ?? due`; if unpaid, nothing. Method column blank.
- Voided payments: excluded entirely (matching every money surface).
- Amount coercion mirrors the ledger's defensive stance (malformed → skip/0).

Columns: `Date, Customer, Invoice #, Invoice Description, Method, Note, Amount`.

**Consistency guarantee (tested):** the sum of exported Amount values for a
range equals `collectedInRange(invoices, start, end)` for that range.

### 3. Expenses and mileage

- Expenses: `Date, Description, Category, Amount, Notes, Has Receipt`.
  Category exports the **label** from `EXPENSE_CATEGORIES`
  (`utils/moneyUtils.ts`), falling back to the same "other" entry
  `ExpenseRow` uses for unknown ids. Has Receipt = `Yes`/`No` (receipt files
  are device-local and cannot leave the app; the flag tells the accountant a
  receipt exists).
- Mileage: `Date, From, To, Purpose, Odometer Start, Odometer End, Miles`.
  Raw miles only — the accountant applies the deduction rate. In-range by
  `trip.date`.

### 4. File write + share — `shareCsv` (new, in `utils/csvExport.ts` or a tiny sibling)

Mirrors `utils/pdfExport.ts`'s contract (alerts + returns; caller does not
branch):

1. Prepend the UTF-8 BOM (`﻿`) so Excel detects UTF-8 (accented
   customer names must survive).
2. `FileSystem.writeAsStringAsync` (**`expo-file-system/legacy`** import — the
   FA-035-safe pattern used by `invoicePdfFile.ts` / `photoStorage.ts`) to
   `${cacheDirectory}<filename>`.
3. `Sharing.isAvailableAsync()` guard → `Sharing.shareAsync(uri, { mimeType:
   "text/csv", dialogTitle: <filename> })`.

Filenames contain no user text (no sanitizer needed):
`tradeready-income_2026-01-01_2026-07-31.csv` (likewise `-expenses`, `-mileage`).

### 5. UI — `ExportDataScreen` (new, Money stack)

- Registered as `ExportData` in `MoneyStack` (currently `MoneyHome` only),
  `presentation: "modal"`. Entry: a `download-outline` Ionicons header-right
  button on `MoneyHome` with `accessibilityLabel="Export data"` — the exact
  pattern JobList uses for Recurring Jobs (App.tsx ~124–134).
- Content: date-range presets (This month / This quarter / This year /
  Last year / All time / Custom), defaulting to **This year** (the tax-time
  use case). Custom shows two date fields via the shared
  `DateTimePickerSheet`. Below: three rows — Income, Expenses, Mileage — each
  with a row count for the selected range and a Share button.
- Blueprint-styled; `createStyles(colors, shadow)` factory; static tokens from
  `utils/theme.ts`.

### 6. Error handling

- Share unavailable / write failure → alert and return (same wording contract
  as `pdfExport.ts`); nothing partial is left behind that matters (cache dir).
- Loading data uses the standard local-first loaders (`loadInvoices`,
  `loadExpenses`, `loadTrips`) — **no network anywhere on this path**.

### 7. Testing

- `escapeCsvField`: commas, quotes, newlines, plain values, empty string.
- `buildIncomeCsv`: ledger rows in/out of range; voided excluded; legacy
  paid/unpaid fallback; **sum-equals-`collectedInRange` property test** over
  several ranges; malformed amounts.
- `buildExpensesCsv` / `buildTripsCsv`: range boundaries, category-label
  mapping incl. unknown id, escaping of notes.
- `shareCsv`: mocked `writeAsStringAsync` / `shareAsync` (mocks already exist
  in `jest.setup.js`); unavailable-share branch.
- Screen-level RNTL test: not required (repo convention — util-level coverage;
  the repo's first screen-level test is still a pending separate task).

## Constraints honored

- No new dependencies (Rule 3 untouched). No data-shape changes. JS-only →
  OTA-eligible.
- Gate green before any commit (tsc 0 / all tests / lint 0), per
  `tradeready-change-control`.

## Out of scope

- QuickBooks-native formats (QBO/IIF) — plain CSV imports fine; revisit on
  user demand.
- Exporting receipt images, PDF exports, scheduled/automatic exports.
- Totals/summary rows.
