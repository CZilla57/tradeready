# Accountant Package & Bookkeeping Handoff — Design

**Date:** 2026-08-07 · **Branch:** `feat/accountant-package` · **Roadmap:** post-launch Phase 14
**Status:** BUILT on `feat/accountant-package` (Tasks 1–8, 2026-08-07) — gate
green (tsc 0 / all tests / lint 0); owner device smoke pending. Deepens the
shipped CSV export (Phase 7) into a single accountant-ready ZIP while
preserving every existing per-dataset export.

## Goal

Let the tradesperson hand their accountant one file — a dated
`TradeReady-Accounting-<start>-<end>.zip` — containing every number the books
need: invoices, line items, cash-basis payments (active and full activity),
expenses, mileage, customers, a category map, plus separate control files
(warnings + summary + README). Cash-basis income stays payment-level and
partial-payment-accurate. No inferred data, no invented fields. Deterministic
output for identical data and range. Zero new dependencies (Rule 3), no
data-shape changes, JS-only → OTA-eligible.

## Owner decisions (2026-08-07)

| Decision | Choice | Rationale |
|---|---|---|
| ZIP strategy | **Hand-rolled zero-dependency "stored" (uncompressed) ZIP writer** | Honors Rule 3 (no `package.json` change). CSVs are tiny uncompressed; JPEG receipts (deferred) don't compress anyway. Pure + unit-testable, matching `csvExport.ts`. |
| Receipt attachments | **Deferred to a later phase** | Receipts are device-local-only, memory-heavy (base64 in RAM), PII-heavy. `export-warnings.csv` still flags which expenses carry a receipt. Opt-in bundling becomes a follow-up. |
| `summary` format | **`summary.json`** (machine-readable control block); `README.txt` covers humans | — |
| Branch | `feat/accountant-package` off `master` | — |
| Rejected | `vehicles.csv` (no vehicle identity in the models); refund columns (no refund concept — voids only; never invented) | — |

## Column-to-model classification (A/B/C/D)

Legend: **A** available now · **B** derivable without guessing · **C** requires a
new optional field · **D** unavailable for legacy records.

| Proposed file | Class | Notes |
|---|---|---|
| `invoices.csv` | A · issue-date B→D | No `created` field. Issue date recovered from the ms timestamp embedded in `Invoice.id` (the `invoiceIssueDate` rule in `pdfTemplates`); sample/legacy non-timestamp ids → blank + warning. |
| `invoice-line-items.csv` | A where present, D else | `Invoice.lineItems` absent on manually-created invoices → those invoices contribute no rows + a warning. |
| `active-payments.csv` | A | Non-voided payments via the ledger; cash basis. Legacy fallback through `materializeLegacyLedger`. |
| `payment-activity.csv` | voids A · **refunds D** | All payments incl. voided, with `voidedAt`. No refund model exists — refund stays out; overpayment is derivable and surfaced in warnings/summary, not invented as a payment. |
| `expenses.csv` | A (+ `jobId` A / job-name B) | `Expense.jobId` landed in Phase 13. Job name resolved by lookup; unknown/deleted job → blank. |
| `mileage.csv` | A (device-caveat) | `Trip` is local-only/unsynced — a fresh device may have none; a warning notes this. |
| `vehicles.csv` | **omit (C)** | No vehicle identity in the models. Conditional per the prompt — not produced in v1. |
| `customers.csv` | A | id/name/email/phone/address/notes/createdAt/archivedAt. |
| `category-mapping.csv` | A | `EXPENSE_CATEGORIES` id→label only. No tax-line/Schedule-C mapping (would be invented). |
| `export-warnings.csv` | B | Derived taxonomy (below). |
| `summary.json` | B | Control totals + coverage (below). |
| `README.txt` | B | Human-readable manifest. |
| receipt attachments | A local-only / D else | **Deferred.** |

## Package layout

```
TradeReady-Accounting_2026-01-01_2026-12-31.zip
├── invoices.csv
├── invoice-line-items.csv
├── active-payments.csv
├── payment-activity.csv
├── expenses.csv
├── mileage.csv
├── customers.csv
├── category-mapping.csv
├── export-warnings.csv        (control file)
├── summary.json               (control file)
└── README.txt                 (control file)
```

All entries are stored at the archive root (flat), in the fixed order above —
part of the determinism guarantee.

### Per-file schemas

Shared CSV rules (all import CSVs): header row always present; empty range →
header only; rows sorted by date ascending, ties broken by a stable code-unit
key (never `localeCompare` — Hermes ICU variance); amounts as plain `1234.50`
(two decimals, no `$`, no thousands separators); dates `YYYY-MM-DD`;
RFC-4180 escaping via `escapeCsvField`; CRLF line endings; **no totals rows**.
Each CSV entry's bytes are `UTF-8 BOM + text` so a file opened directly out of
the zip is read as UTF-8 by Excel.

- **invoices.csv** — `Invoice #, Issue Date, Customer, Email, Phone, Description, Amount, Amount Paid, Balance Due, Status, Due Date, Paid At, Job ID`
  - `Issue Date` from the id-timestamp rule; blank + warning when unrecoverable.
  - `Amount Paid`/`Balance Due` via `amountPaid`/`balanceDue`. `Status` ∈ `paid|partly_paid|unpaid`.
- **invoice-line-items.csv** — `Invoice #, Description, Category, Amount`
  - One row per `InvoiceLineItem`; parent `Invoice #` is the join key.
- **active-payments.csv** — `Date, Customer, Invoice #, Invoice Description, Method, Note, Amount`
  - Exactly today's income CSV semantics (non-voided, legacy method blank).
- **payment-activity.csv** — `Date, Customer, Invoice #, Method, Note, Amount, Voided, Voided At, Source`
  - Every payment incl. voided. `Voided` = `Yes/No`; `Source` ∈ `device|stripe|legacy` derived from the id namespace (`p…`/`stripe_…`/`legacy_…`).
- **expenses.csv** — `Date, Description, Category, Amount, Notes, Job, Has Receipt`
  - `Category` = label (unknown id → `Other`). `Job` = linked job name or blank. `Has Receipt` = `Yes/No` (presence of `receiptUri`, not file existence — receipts are deferred).
- **mileage.csv** — `Date, From, To, Purpose, Odometer Start, Odometer End, Miles`
  - Raw miles (accountant applies the rate), unchanged from today's trips CSV.
- **customers.csv** — `Name, Email, Phone, Address, Notes, Created, Archived`
- **category-mapping.csv** — `Category ID, Label`

### Control files

- **export-warnings.csv** — `Code, Severity, Subject, Detail` — one row per detected condition (taxonomy below). Empty range still emits a `no_records_in_range` info row so a blank export is self-explaining.
- **summary.json** — a control block (see equations). Plain UTF-8, **no BOM** (strict JSON parsers reject a leading BOM).
- **README.txt** — plain UTF-8, plain-English description of every file, the cash-basis convention, the "no invented data" stance, and the mileage/receipt device-local caveats.

## Control equations (asserted by tests)

Let `range = [start, end]`.

- `summary.cash_collected` == Σ `active-payments.csv` Amount == `collectedInRange(invoices, start, end)` (extends the existing sum-equivalence property test).
- `payment-activity` rows = active ∪ voided. `summary.voided_amount` = Σ voided amounts; excluded from `cash_collected`, retained as history.
- `summary.expenses_total` == Σ `expenses.csv` Amount.
- `summary.net_cash` = `cash_collected − expenses_total`, labeled **cash basis; before owner labor** (never called "profit"; owner labor cost is not a cash outflow).
- Coverage counts: `invoices_count`, `customers_count`, `mileage_trips_count`, `mileage_miles_total`, `warnings_count`, plus `range_start`/`range_end`.

`summary.json` carries **no wall-clock generation timestamp** — that would break
determinism for identical data+range. The range is data (from the picker); the
current clock is not.

## Warning taxonomy (`export-warnings.csv`, all pure/derived)

| Code | Severity | Fires when |
|---|---|---|
| `missing_issue_date` | warn | Invoice id is not a recoverable ms timestamp. |
| `missing_line_items` | info | Invoice has no `lineItems` (manual invoice). |
| `legacy_invoice_no_ledger` | info | Paid invoice with no `payments` array (legacy fallback used). |
| `unknown_expense_category` | warn | Expense `category` not in `EXPENSE_CATEGORIES`. |
| `overpayment_present` | warn | `overpaidAmount(invoice) > 0`. |
| `voided_payments_present` | info | Range contains voided payments (see payment-activity). |
| `mileage_is_device_local` | info | Trips are not cloud-synced; a different device may hold others. |
| `no_records_in_range` | info | The range produced zero data rows across all datasets. |

## ZIP strategy — `utils/zipStore.ts` (new, pure)

A minimal **stored** (compression method 0) ZIP writer, no dependency:

- `crc32(bytes: Uint8Array): number` — standard table-based CRC-32.
- `utf8Encode(s: string): Uint8Array` and `base64Encode(bytes: Uint8Array): string` — hand-rolled, pure, unit-tested (Hermes lacks a guaranteed `TextEncoder`/`btoa`).
- `buildZip(entries: { name: string; bytes: Uint8Array }[]): Uint8Array` — emits, per entry, a Local File Header (method 0, **DOS date/time zeroed** for determinism, CRC-32, size = compressed size) + data; then the Central Directory; then the End-of-Central-Directory record. Little-endian throughout.

Determinism: identical entries (same order, same bytes) → identical archive
bytes, because the only otherwise-variable fields (timestamps) are fixed to
zero.

## Assembler & delivery

- `utils/accountingPackage.ts` (new): the per-file builders + `buildAccountingPackage(data, start, end): { filename: string; bytes: Uint8Array }`, where `data = { invoices, expenses, trips, customers }`. Pure — no I/O, no `Settings`, no secrets, no file paths.
- `utils/csvExport.ts` (extend): add `shareZip(bytes, filename)` mirroring `shareCsv` — write base64 to `${cacheDirectory}<filename>` via `expo-file-system/legacy` `writeAsStringAsync` with `EncodingType.Base64`, guard `Sharing.isAvailableAsync()`, `shareAsync({ mimeType: "application/zip" })`, own its alerts. Reuse `escapeCsvField`/`toCsv`.
- Package filename: `TradeReady-Accounting_<start>_<end>.zip` (local `YYYY-MM-DD`; `all_time` → `TradeReady-Accounting_all-time.zip`), same local-date rule as `csvFilename`. Underscore separators (not the prompt's literal `-`) so the ISO date hyphens stay unambiguous and the name matches the app's existing `csvFilename` convention.

## UI — `ExportDataScreen` (extend)

Add an **"Accountant package (.zip)"** primary action above the three existing
per-dataset rows, using the same selected range. A short hint ("Everything your
accountant needs, in one file"). It builds the package for the current range and
hands the bytes to `shareZip`. The existing income/expenses/mileage single-file
shares stay exactly as they are. Blueprint-styled; `createStyles(colors, shadow)`
factory; static tokens from `utils/theme.ts`.

## Determinism, secrets, safeguards

- **Deterministic** for identical data + range: zeroed zip timestamps, fixed
  entry order, stable row ordering, no wall-clock in any payload.
- **Secrets:** builders never receive `Settings`, keys, tokens, or local file
  paths. `receiptUri` is reported only as a `Yes/No` presence flag, never as a
  path.
- **Memory/battery:** with receipts deferred the archive is KB-scale; in-memory
  assembly is trivial and synchronous-cheap. The heavy path (receipt bytes) is
  explicitly out of v1, so no streaming/chunking is needed yet. Data loads via
  the standard local-first loaders (`loadInvoices`/`loadExpenses`/`loadTrips`/
  `loadCustomers`) — no network anywhere.

## Testing

- `zipStore`: crc32 known vectors; utf8 round-trip incl. accents/multibyte;
  base64 round-trip incl. lengths ≡ 0/1/2 mod 3; `buildZip` header/offset
  correctness and byte-for-byte determinism across two identical builds.
- Per-file builders: range boundaries, escaping, legacy/absent fields, unknown
  category, id-namespace `Source`, issue-date recovery + blank fallback.
- Control: `cash_collected` == `collectedInRange` (property test over several
  ranges); active ⊆ activity; net_cash equation; voided excluded from cash.
- Warnings: each code fires exactly on its condition; empty range → single
  `no_records_in_range`.
- `buildAccountingPackage`: entry set + fixed order; empty-range archive still
  valid (headers-only CSVs); determinism (two builds equal).
- `shareZip`: mocked `writeAsStringAsync` (Base64) / `shareAsync`;
  unavailable-share and write-failure branches (same contract as `shareCsv`).

## Ten-phase implementation plan

Each phase ends with a green gate (tsc 0 / tests / lint 0) and a STOP for owner
go-ahead.

1. `utils/zipStore.ts` — crc32 / utf8Encode / base64Encode / buildZip + tests.
2. Per-file CSV builders (invoices, line-items, active-payments, payment-activity, customers, category-mapping) in `utils/accountingPackage.ts` + tests.
3. Warnings builder + tests.
4. `summary.json` builder + control-equation tests.
5. `README.txt` builder.
6. `buildAccountingPackage` assembler (manifest → deterministic zip bytes) + tests.
7. `shareZip` impure tail (`utils/csvExport.ts`) + mocked tests.
8. `ExportDataScreen` wiring (accountant-package action).
9. Docs sweep — README / ARCHITECTURE, this spec's status, roadmap Phase 14 status.
10. Gate + device-smoke handoff + phase report.

## Constraints honored

- No new dependencies (Rule 3 untouched). No data-shape changes. JS-only →
  OTA-eligible. Existing per-dataset exports preserved verbatim.
- Gate green before any commit (tsc 0 / all tests / lint 0), per
  `tradeready-change-control`.

## Out of scope (v1)

- Receipt image attachments (deferred — opt-in bundling with a size/count cap
  becomes a follow-up phase).
- `vehicles.csv` (no vehicle identity in the models).
- Refund representation (no refund concept exists; never invented).
- QuickBooks-native profiles (QBO/IIF) and any claim of direct QuickBooks
  compatibility until an actual import profile is tested.
- Real (deflate) compression — stored ZIP is sufficient at this data scale.
