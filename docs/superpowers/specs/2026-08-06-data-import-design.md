# CSV Data Import — Design

**Date:** 2026-08-06 · **Status:** Design AND spec APPROVED by owner 2026-08-06; implementation NOT started (next step: writing-plans → phase-gated build).
**Owner decisions taken:** generic CSV import (not platform API) · full history scope (customers, jobs + schedule, invoices incl. paid, expenses) · lives as a Settings subpage · Approach A (guided per-entity import with column mapping) · `importBatchId?` additive-optional shape change APPROVED on all four models · paid-row-without-paid-date imports as outstanding + flagged.

## Goal

Let a switcher move their business data out of another platform (Jobber, Housecall
Pro, QuickBooks, or any spreadsheet) and into TradeReady from CSV exports, with
column mapping, validation-before-write, an import report, and one-tap undo.
JS-only, **zero new dependencies** (`expo-document-picker ~14.0.8` is already in
package.json, currently unused), OTA-eligible.

## Non-goals (v1)

- No direct API connectors (Jobber GraphQL etc.) and no AI-assisted column
  mapping — deterministic header heuristics only. Both can layer on later.
- No import of: pricebook entries, recurring rules, receipt images, customer
  portal state, time sessions, change orders.
- No store-listing claim until shipped and device-smoke-tested (claims discipline).

## Entry point & screen

New `SettingsImportScreen`, registered in TodayStack and the Settings hub menu,
following the 11-subpage pattern. **Immediate-action page: uses
`useSettingsTabPop`, does NOT use `useSettingsDraft`** (Booking-page precedent —
nothing draftable; do not add the draft hook).

Four entity slots — Customers, Jobs, Invoices, Expenses — each running the same
pipeline. Recommended import order shown in the UI (customers first), but any
order works because jobs/invoices join customers by name at commit time.

## Pipeline (per file)

1. **Pick** — `expo-document-picker` (`getDocumentAsync`, type text/csv +
   fallback `*/*` since platforms mislabel CSVs), read via
   `expo-file-system` `readAsStringAsync`.
2. **Parse** — new `utils/csvImport.ts`: in-house RFC-4180 parser. Handles
   quoted fields, escaped quotes, commas/newlines inside quotes, CRLF, UTF-8
   BOM strip. Soft row cap (~5,000 rows: warn, continue) to keep the JS thread
   sane.
3. **Detect mapping** — new `utils/importMapping.ts`: header-vocabulary tables
   for Jobber / Housecall Pro / QuickBooks exports plus generic synonyms
   ("First Name"+"Last Name" → `name` join, "Mobile"/"Cell" → `phone`, …).
   Produces a proposed column→field mapping + detected date format.
4. **Map (UI)** — dropdown per TradeReady field; unmapped columns ignored;
   explicit date-format picker whenever detection is ambiguous (US M/D/Y vs
   ISO). Required minimums: Customers = name; Jobs = title + customer name;
   Invoices = customer name + amount; Expenses = amount + date.
5. **Validate (pass 1, no writes)** — new `utils/importEngine.ts` validates
   every row, producing per-row outcomes: ok / skip(reason) / flag(reason).
6. **Preview + summary** — first ~5 mapped rows rendered + counts ("214
   customers: 198 new, 16 match existing; 3 rows skipped"). User confirms.
7. **Commit (pass 2)** — build records in memory, then **exactly one `saveX()`
   call per touched collection** (one diff-enqueue each; sync mirrors to
   Supabase automatically). Import report screen afterward, with the skipped/
   flagged row details.

## Identity & linking rules (invariants)

- Customers are created/matched ONLY via `upsertCustomerInList` /
  `getOrCreateCustomer` (`utils/storage/customers.ts`) — normalized-name join,
  blank-field backfill, never clobbers non-blank data. Never push raw objects
  into `saveCustomers`.
- Jobs: `customerId` + denormalized `customerName` stamped from the join.
- Invoices: `customer` (name) + `customerId` stamped; `email`/`phone` snapshot
  filled from the mapped columns or the joined customer record.
- All reads/writes stay local-first: no network on any render path; sync is
  the existing background queue.

## Field mapping targets (verified against types/models.ts 2026-08-06)

- **Customer** (models.ts:383): name, email, phone, address, notes; `createdAt`
  from a mapped date or import day.
- **Job** (models.ts:154): title, description, status (see status map),
  `scheduledDate`/`scheduledStartTime`/`scheduledEndTime`, address, notes,
  `estimateTotal` if mapped. Pricing internals (laborHours/laborRate/materials/
  overhead/margin) default to 0/[] — foreign platforms don't export our
  breakdown; do not fabricate one.
- **Invoice** (models.ts:313): `number` (source's if mapped, else
  `nextInvoiceNumber`), `amount`, `due`, `desc`, paid state (below). Imported
  ids embed the source **issue-date** ms timestamp (creation-path convention)
  so `invoiceIssueDate` recovers the historical issue date in PDFs.
- **Expense** (models.ts:412): description, amount, `date`, notes; `category`
  keyword-mapped to `ExpenseCategoryId` (unmapped → the canonical catch-all id —
  verify against `EXPENSE_CATEGORIES` in moneyUtils at implementation — and
  flagged); `receiptUri: null`.

### Job status mapping

Foreign status text → our pipeline via a default keyword table (e.g.
lead/new/inquiry → `lead`; quote/estimate sent → `estimate_sent`; approved/won →
`approved`; scheduled/booked → `scheduled`; in progress/started →
`in_progress`; complete/done/closed → `complete`; invoiced/billed → `invoiced`;
paid → `paid`; declined/lost/cancelled → `declined`). Unrecognized → `lead`,
flagged in the report. Statuses are assigned directly at creation (historical
records), NOT walked through `JOB_STATUSES.next` — that chain governs
transitions, not backfill; assignment must still typecheck as `JobStatus`.
`stampEstimateSent` is NOT used (no send occurred; `estimateSentAt` stays
absent so no follow-up nudges fire on imported jobs).

### Money semantics (the careful part)

- **Paid invoices:** `paid: true` + `paidAt` from a mapped paid-date column,
  **NO `payments` ledger** — the ledger is deliberately optional and
  `utils/invoicePayments.ts` derives from `paid`/`amount`/`paidAt` when absent
  (models.ts:342 documents this as the supported legacy path). Do not
  fabricate ledger entries.
- **Paid claim without a mappable paid date:** imports as **outstanding**,
  flagged in the report ("never infer missing historical fields" — owner rule).
- Open invoices: `amount` + `due`; overdue derivation is automatic.
- No side effects: no Stripe links, no deposit requests, no dunning, no
  notifications triggered by import.

### Dates

All date parsing lands as local-frame `"YYYY-MM-DD"` strings. **Never route
through `toISOString()`/UTC** (FA-039). Ambiguous numeric formats require the
user's explicit format choice in the mapping UI.

## Undo & idempotence

- **`importBatchId?: string` — additive-optional field on Customer, Job,
  Invoice, Expense (OWNER-APPROVED shape change, this session).** Absent on all
  existing records; JSON-blob sync ⇒ no backend migration. Implementation MUST
  follow the safe-shape-change recipe in `tradeready-storage-and-sync` and add
  the models.ts doc comments in house style.
- **Stamping rule:** `importBatchId` is stamped ONLY on records the batch
  *created*. Merge-matched customers (pre-existing records the upsert joined)
  are never stamped, so **Undo this import** — which deletes all records
  carrying the batch id via the normal delete paths (soft-delete syncs) —
  structurally cannot delete pre-existing data. No separate manifest needed.
- A small non-synced AsyncStorage key stores import history
  ({batchId, fileHash, date, entity, counts}) — powers the same-file
  re-import warning and the report history. Customers are additionally
  idempotent by nature of the upsert join.

## Safety rails

- If sample data is present, offer `clearSampleData` before the first import.
- Row-level failures skip-and-report; validation happens wholly before any
  write; a commit writes each collection at most once.
- Per-file soft row cap with a clear message; parser never throws on malformed
  input (bad rows become skip(reason)).

## Build phases (each phase-gated: report Confidence / Missing Context / Next Step, STOP)

1. **P1 — Parser + mapping engine** (pure TS, TDD): csvImport.ts,
   importMapping.ts, fixtures built from real Jobber/HCP/QB export headers.
2. **P2 — Customers**: importEngine customers path + SettingsImportScreen
   shell (slot UI, mapping UI, preview, report) + `importBatchId` shape change
   (storage-and-sync recipe) + undo for customers.
3. **P3 — Jobs + schedule**: status map, customer join, date/time mapping.
4. **P4 — Invoices**: paid semantics, number continuity, id-timestamp
   embedding.
5. **P5 — Expenses + polish**: category mapping, file-hash re-import warning,
   sample-data offer, full report UX; gate + owner device smoke (real Jobber/
   HCP/QB export files).

Testing: parser fixture suite; mapping-detection suite; money-derivation tests
(paid/paidAt/no-ledger through invoicePayments selectors); join/backfill tests;
undo tests (created-vs-matched); re-import idempotence test.

## Traps for the implementing session

- Never raw `AsyncStorage.setItem` on collection keys (bypasses sync queue).
- One `saveX()` per collection per commit — not per row.
- `getOrCreateCustomer`/`upsertCustomerInList` is the ONLY customer-creation
  path.
- FA-039: local-frame dates everywhere.
- Verify `expo-document-picker` is still in package.json before relying on it
  (it is as of 2026-08-06, unused) — if it's gone, that's a Rule-3 stop.
- `SettingsAccountScreen`-style rules: the new subpage is immediate-action —
  no `useSettingsDraft`.
- Commit only on owner ask; gate green before any commit (change-control).
