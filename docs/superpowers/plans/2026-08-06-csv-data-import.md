# CSV Data Import Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a switcher move their business (customers, jobs, invoices incl. paid, expenses) out of Jobber / Housecall Pro / QuickBooks / any spreadsheet into TradeReady from CSV exports — with column mapping, validate-before-write, an import report, and one-tap undo.

**Architecture:** Four pure TS modules do the heavy lifting with zero I/O so they're unit-testable — `utils/csvImport.ts` (RFC-4180 parser), `utils/importMapping.ts` (header-vocabulary detection + date parsing), `utils/importEngine.ts` (per-entity validate + build records), `utils/importHistory.ts` (non-synced batch history in AsyncStorage). A single new immediate-action Settings subpage `screens/SettingsImportScreen.tsx` orchestrates pick → parse → map → validate → preview → commit, writing each collection at most once through the existing `saveX()` sync path. An additive-optional `importBatchId?` field on all four models powers structural undo.

**Tech Stack:** Expo 54 / React Native 0.81 / React 19 / TypeScript (strict), Jest (jest-expo preset) + React Native Testing Library. `expo-document-picker ~14.0.8` (already installed, currently unused) + `expo-file-system/legacy` (`readAsStringAsync`). **Zero new dependencies.**

## Global Constraints

- **Rule 2 (change-control): never land on a red gate.** Before ANY commit run all three from `C:\dev\tradeready\tradeready`: `npm run typecheck` → 0 errors, `npm test` → all pass, `npm run lint` → 0 warnings (`--max-warnings=0`). Current suite-file baseline: **161** `__tests__/*.test.*` files. Run `npm test` to read the live passed-test total (no fresh doc baseline exists — do not cite a stale number in the phase report).
- **Rule 3 (change-control): no dependency or Expo SDK changes.** This feature adds none. Before P1, confirm `expo-document-picker` and `expo-file-system` are still in `package.json` (they are as of 2026-08-06). If either is gone, STOP — that's a Rule-3 conversation, not a workaround.
- **Rule 1 (change-control): phase-gate.** Each phase (P1–P5) ends with a report — Confidence Level / Missing Context / Recommended Next Step — then STOP for owner go-ahead. Do not run into the next phase.
- **Commit only when the owner asks.** The gate being green authorizes a commit; it does not command one. Keep the tree clean between phases.
- **FA-039 — local-frame dates only.** All parsed dates become local `"YYYY-MM-DD"` strings via `toDateString` from `utils/dateHelpers.ts`. **Never** `Date.prototype.toISOString()` / UTC methods anywhere in this feature.
- **One `saveX()` per touched collection per commit** — never per row. Build the full next array in memory, then one save. Never `AsyncStorage.setItem` a collection key directly (bypasses the sync queue).
- **Customer creation ONLY via `upsertCustomerInList` / `getOrCreateCustomer`** (`utils/storage/customers.ts`). Never push raw objects into `saveCustomers`.
- **Immediate-action page: `useSettingsTabPop`, NOT `useSettingsDraft`** (SettingsBookingScreen precedent). Do not add the draft hook.
- **No import side effects:** no Stripe links, no deposit requests, no dunning, no notifications, no `stampEstimateSent`. Imported jobs leave `estimateSentAt` absent so no follow-up nudges fire.
- **Never infer missing historical fields.** A "paid" row with no mappable paid date imports as **outstanding + flagged**, never fabricated.
- **`importBatchId` is stamped ONLY on records the batch _created_** — never on merge-matched (pre-existing) customers — so undo structurally cannot delete pre-existing data.

---

## File Structure

**New files:**
- `utils/csvImport.ts` — RFC-4180 parser + a tiny stable string hash (for re-import detection). Pure, never throws.
- `utils/importMapping.ts` — `ImportEntity`, `FIELD_DEFS`, header-vocabulary tables, `detectMapping`, `detectDateFormat`, `parseImportDate`. Pure.
- `utils/importEngine.ts` — per-entity pure builders: `buildCustomerImport`, `buildJobImport`, `buildInvoiceImport`, `buildExpenseImport`, plus `mapJobStatus`, `mapExpenseCategory`, `stripBatch`. Pure — no I/O.
- `utils/importHistory.ts` — async, non-synced AsyncStorage batch history: `recordImportBatch`, `loadImportHistory`, `newBatchId`. Also the async commit/undo orchestration `runUndoBatch`.
- `screens/SettingsImportScreen.tsx` — the UI. Orchestrates the pipeline; load/save I/O lives here.
- Tests: `__tests__/csvImport.test.ts`, `__tests__/importMapping.test.ts`, `__tests__/importEngine.test.ts`, `__tests__/importEngine.jobs.test.ts`, `__tests__/importEngine.invoices.test.ts`, `__tests__/importEngine.expenses.test.ts`, `__tests__/importHistory.test.ts`.

**Modified files:**
- `types/models.ts` — add `importBatchId?: string` to `Customer`, `Job`, `Invoice`, `Expense` (P2).
- `types/navigation.ts` — add `SettingsImport: undefined;` to `TodayStackParamList` (P2).
- `App.tsx` — import + register `SettingsImportScreen` (P2).
- `screens/SettingsHubScreen.tsx` — add the menu row (P2).

**Ground-truth signatures (verified against the repo 2026-08-06 — build against these, not memory):**
- `saveCustomers(customers: Customer[]): Promise<void>` / `loadCustomers()`, and same shape for `saveJobs`/`loadJobs`, `saveInvoices`/`loadInvoices`, `saveExpenses`/`loadExpenses` — all in `utils/storage/collections.ts`, re-exported from `utils/storage` (barrel). Each `saveX` takes the **full array**, writes AsyncStorage, and `enqueueCollectionChanges("<collection>", old, next)` — so a save that _omits_ records enqueues deletes (this is the undo path).
- `upsertCustomerInList(customers: Customer[], fields?: { name?; email?; phone?; address? }): { customer: Customer | null; customers: Customer[]; changed: boolean }` — pure, backfills only blank fields, matches by trimmed+lowercased name, stamps a fresh id + `createdAt` on new records.
- `toDateString(date: Date): string` and `getTodayDateString(now?: Date): string` — `utils/dateHelpers.ts`.
- `EXPENSE_CATEGORIES: { id: ExpenseCategoryId; label; icon }[]` — `utils/moneyUtils.ts`; ids `materials|tools|fuel|labor|insurance|software|marketing|other`; catch-all is `"other"`.
- `JOB_STATUSES: Record<JobStatus, { label; color; next }>` — `utils/pricingEngine.ts` (NOT `.js`). `JobStatus = lead|estimate_sent|approved|scheduled|in_progress|complete|invoiced|paid|declined`.
- Settings subpage wiring template = `SettingsBookingScreen`: nav param `types/navigation.ts:40`, hub row `SettingsHubScreen.tsx:71`, navigator registration `App.tsx:144` (import `App.tsx:64`).
- File read: `import * as FileSystem from "expo-file-system/legacy";` then `FileSystem.readAsStringAsync(uri, { encoding: FileSystem.EncodingType.UTF8 })`.

---

## PHASE 1 — Parser + Mapping Engine (pure TS, TDD)

**Deliverable:** `utils/csvImport.ts` and `utils/importMapping.ts`, fully unit-tested against fixtures built from real Jobber / HCP / QuickBooks export headers. No app wiring yet.

### Task 1.1: RFC-4180 CSV parser

**Files:**
- Create: `utils/csvImport.ts`
- Test: `__tests__/csvImport.test.ts`

**Interfaces:**
- Produces: `parseCsv(text: string, opts?: { maxRows?: number }): ParsedCsv` where
  `interface ParsedCsv { headers: string[]; rows: string[][]; rowCount: number; truncated: boolean }`.
  `hashCsv(text: string): string` (stable non-crypto hash for re-import detection).

- [ ] **Step 1: Write the failing test**

```ts
// __tests__/csvImport.test.ts
import { parseCsv, hashCsv } from "../utils/csvImport";

describe("parseCsv", () => {
  test("splits a simple comma file into headers + rows", () => {
    const out = parseCsv("Name,Phone\nAda,555-1\nGrace,555-2\n");
    expect(out.headers).toEqual(["Name", "Phone"]);
    expect(out.rows).toEqual([["Ada", "555-1"], ["Grace", "555-2"]]);
    expect(out.rowCount).toBe(2);
    expect(out.truncated).toBe(false);
  });

  test("honours quoted fields with commas, newlines, and escaped quotes", () => {
    const text = 'Name,Notes\n"Smith, Bob","line1\nline2"\n"She said ""hi""",ok\n';
    const out = parseCsv(text);
    expect(out.rows[0]).toEqual(["Smith, Bob", "line1\nline2"]);
    expect(out.rows[1]).toEqual(['She said "hi"', "ok"]);
  });

  test("strips a UTF-8 BOM and handles CRLF line endings", () => {
    const out = parseCsv("\uFEFFName,Phone\r\nAda,555\r\n");
    expect(out.headers).toEqual(["Name", "Phone"]);
    expect(out.rows).toEqual([["Ada", "555"]]);
  });

  test("pads short rows and ignores a trailing blank line", () => {
    const out = parseCsv("A,B,C\n1,2\n\n");
    expect(out.rows).toEqual([["1", "2", ""]]);
  });

  test("never throws on malformed input; returns empty on empty text", () => {
    expect(parseCsv("").headers).toEqual([]);
    expect(() => parseCsv('"unterminated,quote\nrow')).not.toThrow();
  });

  test("soft row cap truncates and flags", () => {
    const body = Array.from({ length: 10 }, (_, i) => `r${i}`).join("\n");
    const out = parseCsv(`H\n${body}\n`, { maxRows: 4 });
    expect(out.rows).toHaveLength(4);
    expect(out.truncated).toBe(true);
  });
});

describe("hashCsv", () => {
  test("is stable and differs for different content", () => {
    expect(hashCsv("A,B\n1,2\n")).toBe(hashCsv("A,B\n1,2\n"));
    expect(hashCsv("A,B\n1,2\n")).not.toBe(hashCsv("A,B\n1,3\n"));
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npx jest csvImport --no-coverage`
Expected: FAIL — "Cannot find module '../utils/csvImport'".

- [ ] **Step 3: Write minimal implementation**

```ts
// utils/csvImport.ts
// In-house RFC-4180 CSV parser + a stable non-crypto content hash.
// Pure and total: never throws on malformed input — a broken quote just ends
// the field where the data ends. Zero dependencies (parser hand-rolled so the
// import feature needs no new package). All higher-level meaning (which column
// is what, how a date reads) lives in importMapping.ts, not here.

const DEFAULT_MAX_ROWS = 5000;

export interface ParsedCsv {
  headers: string[];
  rows: string[][];
  rowCount: number;
  /** True when the soft row cap dropped trailing rows. */
  truncated: boolean;
}

/** Tokenise a full CSV document into rows of raw string cells (RFC-4180). */
function tokenize(text: string): string[][] {
  const records: string[][] = [];
  let field = "";
  let row: string[] = [];
  let inQuotes = false;
  let i = 0;
  const n = text.length;

  const endField = () => { row.push(field); field = ""; };
  const endRow = () => { endField(); records.push(row); row = []; };

  while (i < n) {
    const ch = text[i];
    if (inQuotes) {
      if (ch === '"') {
        if (text[i + 1] === '"') { field += '"'; i += 2; continue; }
        inQuotes = false; i += 1; continue;
      }
      field += ch; i += 1; continue;
    }
    if (ch === '"') { inQuotes = true; i += 1; continue; }
    if (ch === ",") { endField(); i += 1; continue; }
    if (ch === "\r") { i += 1; continue; }          // swallow CR (CRLF/lone CR)
    if (ch === "\n") { endRow(); i += 1; continue; }
    field += ch; i += 1;
  }
  // Flush the final field/row unless the file ended on a clean newline.
  if (field.length > 0 || row.length > 0) endRow();
  return records;
}

export function parseCsv(text: string, opts: { maxRows?: number } = {}): ParsedCsv {
  const maxRows = opts.maxRows ?? DEFAULT_MAX_ROWS;
  if (!text) return { headers: [], rows: [], rowCount: 0, truncated: false };

  const clean = text.charCodeAt(0) === 0xfeff ? text.slice(1) : text; // strip BOM
  const records = tokenize(clean);
  if (records.length === 0) return { headers: [], rows: [], rowCount: 0, truncated: false };

  const headers = records[0].map((h) => h.trim());
  const width = headers.length;
  const dataRecords = records.slice(1).filter((r) => !(r.length === 1 && r[0] === ""));

  const truncated = dataRecords.length > maxRows;
  const kept = truncated ? dataRecords.slice(0, maxRows) : dataRecords;
  const rows = kept.map((r) => {
    const padded = r.slice(0, width);
    while (padded.length < width) padded.push("");
    return padded;
  });

  return { headers, rows, rowCount: rows.length, truncated };
}

/** Stable FNV-1a-ish hash of the file text (re-import warning only, not security). */
export function hashCsv(text: string): string {
  let h = 0x811c9dc5;
  for (let i = 0; i < text.length; i += 1) {
    h ^= text.charCodeAt(i);
    h = Math.imul(h, 0x01000193);
  }
  return (h >>> 0).toString(16);
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `npx jest csvImport --no-coverage`
Expected: PASS (all 7 tests).

- [ ] **Step 5: Commit** (only if the owner has asked to commit this phase; otherwise leave staged for the phase report)

```bash
git add utils/csvImport.ts __tests__/csvImport.test.ts
git commit -m "feat: add RFC-4180 CSV parser for data import"
```

### Task 1.2: Field definitions + header-vocabulary mapping detection

**Files:**
- Create: `utils/importMapping.ts`
- Test: `__tests__/importMapping.test.ts`

**Interfaces:**
- Produces:
  - `type ImportEntity = "customers" | "jobs" | "invoices" | "expenses"`
  - `interface FieldDef { key: string; label: string; required: boolean }`
  - `const FIELD_DEFS: Record<ImportEntity, FieldDef[]>`
  - `type DateFormat = "MDY" | "DMY" | "YMD"`
  - `interface DetectedMapping { mapping: Array<string | null>; dateFormat: DateFormat | null }` — `mapping[i]` is the TradeReady field key for header `i`, or `null` if unmapped. Multiple headers MAY map to the same key (e.g. First Name + Last Name → `name`).
  - `detectMapping(entity: ImportEntity, headers: string[]): DetectedMapping`
  - `detectDateFormat(samples: string[]): DateFormat | null`
  - `parseImportDate(raw: string, format: DateFormat | null): string | null` — returns local `"YYYY-MM-DD"` or `null`.
- Consumes: `toDateString` from `utils/dateHelpers.ts`.

- [ ] **Step 1: Write the failing test**

```ts
// __tests__/importMapping.test.ts
import {
  FIELD_DEFS,
  detectMapping,
  detectDateFormat,
  parseImportDate,
} from "../utils/importMapping";

describe("FIELD_DEFS", () => {
  test("declares required minimums per entity", () => {
    const req = (e: "customers" | "jobs" | "invoices" | "expenses") =>
      FIELD_DEFS[e].filter((f) => f.required).map((f) => f.key).sort();
    expect(req("customers")).toEqual(["name"]);
    expect(req("jobs")).toEqual(["customerName", "title"]);
    expect(req("invoices")).toEqual(["amount", "customer"]);
    expect(req("expenses")).toEqual(["amount", "date"]);
  });
});

describe("detectMapping", () => {
  test("maps a Jobber-style customer export by synonyms", () => {
    const { mapping } = detectMapping("customers", ["Full Name", "Email Address", "Mobile", "Street Address"]);
    expect(mapping).toEqual(["name", "email", "phone", "address"]);
  });

  test("joins First Name + Last Name into name", () => {
    const { mapping } = detectMapping("customers", ["First Name", "Last Name", "Cell"]);
    expect(mapping).toEqual(["name", "name", "phone"]);
  });

  test("leaves unrecognised headers unmapped", () => {
    const { mapping } = detectMapping("customers", ["Name", "Loyalty Tier"]);
    expect(mapping).toEqual(["name", null]);
  });

  test("maps an invoice export (customer + amount + due + number)", () => {
    const { mapping } = detectMapping("invoices", ["Client", "Total", "Due Date", "Invoice #", "Paid On"]);
    expect(mapping).toEqual(["customer", "amount", "due", "number", "paidAt"]);
  });
});

describe("detectDateFormat", () => {
  test("recognises ISO", () => {
    expect(detectDateFormat(["2026-01-05", "2026-11-30"])).toBe("YMD");
  });
  test("disambiguates DMY when a value exceeds 12 in the first slot", () => {
    expect(detectDateFormat(["13/02/2026", "01/03/2026"])).toBe("DMY");
  });
  test("defaults ambiguous slash dates to MDY (US)", () => {
    expect(detectDateFormat(["01/02/2026", "03/04/2026"])).toBe("MDY");
  });
  test("returns null when nothing looks like a date", () => {
    expect(detectDateFormat(["hello", ""])).toBeNull();
  });
});

describe("parseImportDate", () => {
  test("parses ISO to local YYYY-MM-DD", () => {
    expect(parseImportDate("2026-07-04", "YMD")).toBe("2026-07-04");
  });
  test("parses US M/D/Y without a UTC shift", () => {
    expect(parseImportDate("7/4/2026", "MDY")).toBe("2026-07-04");
  });
  test("parses D/M/Y", () => {
    expect(parseImportDate("4/7/2026", "DMY")).toBe("2026-07-04");
  });
  test("returns null on garbage or impossible dates", () => {
    expect(parseImportDate("not a date", "MDY")).toBeNull();
    expect(parseImportDate("13/13/2026", "MDY")).toBeNull();
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npx jest importMapping --no-coverage`
Expected: FAIL — "Cannot find module '../utils/importMapping'".

- [ ] **Step 3: Write minimal implementation**

```ts
// utils/importMapping.ts
// Deterministic column→field mapping for CSV import. Header-vocabulary tables
// (Jobber / Housecall Pro / QuickBooks + generic synonyms) propose a mapping;
// the UI lets the user override. NO AI, NO network. Date parsing lands local
// "YYYY-MM-DD" strings (FA-039) via dateHelpers.toDateString — never toISOString.

import { toDateString } from "./dateHelpers";

export type ImportEntity = "customers" | "jobs" | "invoices" | "expenses";

export interface FieldDef {
  key: string;
  label: string;
  required: boolean;
}

export const FIELD_DEFS: Record<ImportEntity, FieldDef[]> = {
  customers: [
    { key: "name", label: "Name", required: true },
    { key: "email", label: "Email", required: false },
    { key: "phone", label: "Phone", required: false },
    { key: "address", label: "Address", required: false },
    { key: "notes", label: "Notes", required: false },
  ],
  jobs: [
    { key: "title", label: "Job title", required: true },
    { key: "customerName", label: "Customer name", required: true },
    { key: "status", label: "Status", required: false },
    { key: "scheduledDate", label: "Scheduled date", required: false },
    { key: "address", label: "Address", required: false },
    { key: "description", label: "Description", required: false },
    { key: "estimateTotal", label: "Estimate total", required: false },
    { key: "notes", label: "Notes", required: false },
  ],
  invoices: [
    { key: "customer", label: "Customer name", required: true },
    { key: "amount", label: "Amount", required: true },
    { key: "number", label: "Invoice number", required: false },
    { key: "due", label: "Due date", required: false },
    { key: "paidAt", label: "Paid date", required: false },
    { key: "desc", label: "Description", required: false },
    { key: "email", label: "Email", required: false },
    { key: "phone", label: "Phone", required: false },
  ],
  expenses: [
    { key: "amount", label: "Amount", required: true },
    { key: "date", label: "Date", required: true },
    { key: "description", label: "Description", required: false },
    { key: "category", label: "Category", required: false },
    { key: "notes", label: "Notes", required: false },
  ],
};

// Synonym tables: field key → lowercase header phrases that should map to it.
// Order within an entity matters only for readability; matching is longest-first
// so "estimate total" wins over "total".
const SYNONYMS: Record<ImportEntity, Record<string, string[]>> = {
  customers: {
    name: ["name", "full name", "customer", "client", "contact", "customer name", "first name", "last name"],
    email: ["email", "email address", "e-mail"],
    phone: ["phone", "phone number", "mobile", "cell", "telephone", "mobile phone"],
    address: ["address", "street address", "billing address", "street", "location"],
    notes: ["notes", "note", "comments", "description"],
  },
  jobs: {
    title: ["title", "job title", "job name", "service", "job"],
    customerName: ["customer", "customer name", "client", "client name", "contact"],
    status: ["status", "stage", "job status"],
    scheduledDate: ["scheduled date", "date", "start date", "appointment date", "scheduled"],
    address: ["address", "job address", "service address", "location", "street address"],
    description: ["description", "details", "scope"],
    estimateTotal: ["estimate total", "estimate", "quote", "quoted", "total"],
    notes: ["notes", "note", "comments"],
  },
  invoices: {
    customer: ["customer", "customer name", "client", "client name", "bill to", "contact"],
    amount: ["amount", "total", "invoice total", "amount due", "balance"],
    number: ["number", "invoice #", "invoice number", "invoice no", "inv #", "doc number"],
    due: ["due", "due date", "date due"],
    paidAt: ["paid on", "paid date", "date paid", "payment date"],
    desc: ["description", "memo", "details", "line item", "notes"],
    email: ["email", "email address"],
    phone: ["phone", "mobile", "cell", "telephone"],
  },
  expenses: {
    amount: ["amount", "total", "cost", "price", "debit"],
    date: ["date", "transaction date", "posted date", "purchase date"],
    description: ["description", "memo", "payee", "vendor", "merchant", "details"],
    category: ["category", "type", "account", "expense category"],
    notes: ["notes", "note", "comments"],
  },
};

function normHeader(h: string): string {
  return h.trim().toLowerCase().replace(/[_\-]+/g, " ").replace(/\s+/g, " ");
}

export interface DetectedMapping {
  mapping: Array<string | null>;
  dateFormat: DateFormat | null;
}

export function detectMapping(entity: ImportEntity, headers: string[]): DetectedMapping {
  const table = SYNONYMS[entity];
  // Build a longest-first lookup so multi-word synonyms beat single words.
  const entries: Array<{ phrase: string; key: string }> = [];
  for (const key of Object.keys(table)) {
    for (const phrase of table[key]) entries.push({ phrase, key });
  }
  entries.sort((a, b) => b.phrase.length - a.phrase.length);

  const mapping = headers.map((h) => {
    const nh = normHeader(h);
    const exact = entries.find((e) => e.phrase === nh);
    if (exact) return exact.key;
    const partial = entries.find((e) => nh.includes(e.phrase));
    return partial ? partial.key : null;
  });

  // Detected date format is filled in later by the engine/screen from sample
  // cells of whichever column mapped to a date field; default null here.
  return { mapping, dateFormat: null };
}

export type DateFormat = "MDY" | "DMY" | "YMD";

const ISO_RE = /^(\d{4})-(\d{1,2})-(\d{1,2})$/;
const NUM_RE = /^(\d{1,4})[/\-.](\d{1,2})[/\-.](\d{1,4})$/;

export function detectDateFormat(samples: string[]): DateFormat | null {
  let sawNumeric = false;
  let firstSlotOver12 = false;
  let secondSlotOver12 = false;
  for (const raw of samples) {
    const s = (raw || "").trim();
    if (!s) continue;
    if (ISO_RE.test(s)) return "YMD";
    const m = NUM_RE.exec(s);
    if (!m) continue;
    sawNumeric = true;
    const a = Number(m[1]);
    const b = Number(m[2]);
    if (m[1].length === 4) return "YMD";
    if (a > 12) firstSlotOver12 = true;
    if (b > 12) secondSlotOver12 = true;
  }
  if (!sawNumeric) return null;
  if (firstSlotOver12 && !secondSlotOver12) return "DMY";
  return "MDY"; // US default when ambiguous
}

export function parseImportDate(raw: string, format: DateFormat | null): string | null {
  const s = (raw || "").trim();
  if (!s) return null;

  let y: number, mo: number, d: number;
  const iso = ISO_RE.exec(s);
  if (iso) {
    y = Number(iso[1]); mo = Number(iso[2]); d = Number(iso[3]);
  } else {
    const m = NUM_RE.exec(s);
    if (!m) return null;
    const p1 = Number(m[1]), p2 = Number(m[2]), p3 = Number(m[3]);
    const fmt = format ?? "MDY";
    if (fmt === "YMD" || m[1].length === 4) { y = p1; mo = p2; d = p3; }
    else if (fmt === "DMY") { d = p1; mo = p2; y = p3; }
    else { mo = p1; d = p2; y = p3; }
    if (y < 100) y += 2000;
  }

  if (mo < 1 || mo > 12 || d < 1 || d > 31) return null;
  const dt = new Date(y, mo - 1, d);                 // local-frame construction
  if (dt.getFullYear() !== y || dt.getMonth() !== mo - 1 || dt.getDate() !== d) return null;
  return toDateString(dt);                            // FA-039-safe formatting
}
```

- [ ] **Step 2 (re-run): verify the date-format detection test intent** — note `detectMapping` returns `dateFormat: null`; the engine/screen calls `detectDateFormat` on the sampled date column. This is intentional separation, matching the test (which exercises `detectDateFormat` directly).

- [ ] **Step 4: Run tests to verify they pass**

Run: `npx jest importMapping --no-coverage`
Expected: PASS (all cases). If "First Name"/"Last Name" both map to `name` fails, confirm both phrases live under `customers.name` in SYNONYMS (they do above).

- [ ] **Step 5: Full gate + commit**

Run: `npm run typecheck && npm test && npm run lint`
Expected: 0 tsc errors, all suites pass (baseline + 2 new suites), 0 lint warnings.

```bash
git add utils/importMapping.ts __tests__/importMapping.test.ts
git commit -m "feat: add CSV header-mapping detection and date parsing for import"
```

**END OF PHASE 1 — write the phase report (Confidence / Missing Context / Recommended Next Step) and STOP for owner go-ahead.**

Missing-context prompts to raise in the P1 report: (a) confirm the synonym tables cover the owner's actual export headers — ideally get one real Jobber/HCP/QB export header row to widen fixtures in a follow-up; (b) confirm MDY-as-ambiguous-default matches the owner's locale.

---

## PHASE 2 — Customers path + screen shell + `importBatchId` shape change + undo

**Deliverable:** `importBatchId` added to all four models; `utils/importEngine.ts` customers builder; `utils/importHistory.ts`; `SettingsImportScreen` end-to-end for the Customers slot (pick → map → preview → commit → report), plus working undo for a customer batch. Registered in the Settings hub + navigator.

### Task 2.1: Add `importBatchId?` to the four models (persisted-shape change)

**Files:**
- Modify: `types/models.ts` — `Customer`, `Job`, `Invoice`, `Expense` interfaces.

**Shape-change safety (per `tradeready-storage-and-sync` recipe):** additive-optional field, absent on all existing records, JSON-blob sync ⇒ no backend migration. No reader requires it. Follows the house doc-comment convention ("OPTIONAL and additive — absent means X").

- [ ] **Step 1: Add the field to `Customer`** (after `archivedAt?`, before the closing brace of the interface):

```ts
  /**
   * FK to the CSV import batch that created this record (2026-08 CSV-import
   * spec). OPTIONAL and additive — absent on every record created by any other
   * path (manual entry, booking conversion, sync pull). Stamped ONLY on records
   * a batch created (never on merge-matched existing customers), so "Undo import"
   * — which deletes every record carrying the batch id — cannot remove
   * pre-existing data. JSON-blob sync ⇒ no backend migration.
   */
  importBatchId?: string;
```

- [ ] **Step 2: Add the identical field** (same comment) to `Job`, `Invoice`, and `Expense` interfaces in `types/models.ts`.

- [ ] **Step 3: Verify typecheck**

Run: `npm run typecheck`
Expected: 0 errors (purely additive-optional; nothing else changes).

- [ ] **Step 4: Commit**

```bash
git add types/models.ts
git commit -m "feat: add additive-optional importBatchId to Customer/Job/Invoice/Expense"
```

### Task 2.2: Import history (non-synced) + batch id

**Files:**
- Create: `utils/importHistory.ts`
- Test: `__tests__/importHistory.test.ts`

**Interfaces:**
- Produces:
  - `newBatchId(): string`
  - `interface ImportBatchRecord { batchId: string; entity: ImportEntity; fileHash: string; date: string; counts: ImportCounts }`
  - `recordImportBatch(rec: ImportBatchRecord): Promise<void>`
  - `loadImportHistory(): Promise<ImportBatchRecord[]>`
  - `findBatchByFileHash(entity: ImportEntity, fileHash: string): Promise<ImportBatchRecord | null>`
- Consumes: `ImportEntity` (importMapping), `ImportCounts` (importEngine — Task 2.3). To avoid a cycle, define `ImportCounts` in importEngine and import the type here.

- [ ] **Step 1: Write the failing test**

```ts
// __tests__/importHistory.test.ts
import AsyncStorage from "@react-native-async-storage/async-storage";
import {
  newBatchId,
  recordImportBatch,
  loadImportHistory,
  findBatchByFileHash,
} from "../utils/importHistory";

beforeEach(async () => { await AsyncStorage.clear(); });

test("newBatchId returns unique ids", () => {
  expect(newBatchId()).not.toBe(newBatchId());
});

test("records and reads back batch history (newest first)", async () => {
  await recordImportBatch({ batchId: "b1", entity: "customers", fileHash: "h1", date: "2026-08-06", counts: { ok: 2, skip: 0, flag: 0, created: 2, matched: 0 } });
  await recordImportBatch({ batchId: "b2", entity: "jobs", fileHash: "h2", date: "2026-08-06", counts: { ok: 1, skip: 1, flag: 0, created: 1, matched: 0 } });
  const hist = await loadImportHistory();
  expect(hist.map((h) => h.batchId)).toEqual(["b2", "b1"]);
});

test("finds a prior batch by entity + file hash", async () => {
  await recordImportBatch({ batchId: "b1", entity: "customers", fileHash: "hAAA", date: "2026-08-06", counts: { ok: 2, skip: 0, flag: 0, created: 2, matched: 0 } });
  expect((await findBatchByFileHash("customers", "hAAA"))?.batchId).toBe("b1");
  expect(await findBatchByFileHash("jobs", "hAAA")).toBeNull();
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npx jest importHistory --no-coverage`
Expected: FAIL — module not found.

- [ ] **Step 3: Write minimal implementation**

```ts
// utils/importHistory.ts
// Non-synced, device-local record of CSV import batches. Powers the same-file
// re-import warning and the report history. Deliberately NOT a synced collection
// (it's per-device operational metadata, not business data) — plain AsyncStorage.

import AsyncStorage from "@react-native-async-storage/async-storage";
import type { ImportEntity } from "./importMapping";
import type { ImportCounts } from "./importEngine";

const KEY = "tr_import_history_v1";

let _batchCounter = 0;
export function newBatchId(): string {
  _batchCounter += 1;
  return `imp_${Date.now()}_${_batchCounter}`;
}

export interface ImportBatchRecord {
  batchId: string;
  entity: ImportEntity;
  fileHash: string;
  date: string;
  counts: ImportCounts;
}

export async function loadImportHistory(): Promise<ImportBatchRecord[]> {
  try {
    const raw = await AsyncStorage.getItem(KEY);
    return raw ? (JSON.parse(raw) as ImportBatchRecord[]) : [];
  } catch {
    return [];
  }
}

export async function recordImportBatch(rec: ImportBatchRecord): Promise<void> {
  const hist = await loadImportHistory();
  await AsyncStorage.setItem(KEY, JSON.stringify([rec, ...hist]));
}

export async function findBatchByFileHash(
  entity: ImportEntity,
  fileHash: string,
): Promise<ImportBatchRecord | null> {
  const hist = await loadImportHistory();
  return hist.find((h) => h.entity === entity && h.fileHash === fileHash) ?? null;
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `npx jest importHistory --no-coverage`
Expected: PASS. (AsyncStorage is mocked by jest-expo/jest.setup — confirm no "AsyncStorage.clear is not a function"; the project already mocks it, other suites use it.)

- [ ] **Step 5: Commit**

```bash
git add utils/importHistory.ts __tests__/importHistory.test.ts
git commit -m "feat: add non-synced CSV import batch history"
```

### Task 2.3: Customer import builder (pure) + `stripBatch` undo helper

**Files:**
- Create: `utils/importEngine.ts`
- Test: `__tests__/importEngine.test.ts`

**Interfaces:**
- Produces:
  - `interface RowOutcome { rowIndex: number; status: "ok" | "skip" | "flag"; reason?: string }`
  - `interface ImportCounts { ok: number; skip: number; flag: number; created: number; matched: number }`
  - `interface CustomerImportResult { records: Customer[]; outcomes: RowOutcome[]; counts: ImportCounts }`
  - `buildCustomerImport(rows: string[][], mapping: Array<string | null>, existing: Customer[], batchId: string): CustomerImportResult`
  - `stripBatch<T extends { importBatchId?: string }>(records: T[], batchId: string): T[]`
- Consumes: `upsertCustomerInList` (customers.ts), `Customer` (models).

- [ ] **Step 1: Write the failing test**

```ts
// __tests__/importEngine.test.ts
import { buildCustomerImport, stripBatch } from "../utils/importEngine";
import type { Customer } from "../types/models";

const cols = (m: Array<string | null>) => m;

describe("buildCustomerImport", () => {
  test("creates new customers and stamps importBatchId only on created records", () => {
    const existing: Customer[] = [
      { id: "c1", name: "Ada Lovelace", email: "ada@x.com", phone: "", address: "", notes: "" },
    ];
    const rows = [
      ["Ada Lovelace", "", "555-9"],   // matches existing -> backfill phone, NOT stamped
      ["Grace Hopper", "grace@x.com", "555-2"], // new -> stamped
    ];
    const res = buildCustomerImport(rows, cols(["name", "email", "phone"]), existing, "batch1");

    const ada = res.records.find((c) => c.name === "Ada Lovelace")!;
    const grace = res.records.find((c) => c.name === "Grace Hopper")!;
    expect(ada.phone).toBe("555-9");            // blank field backfilled
    expect(ada.importBatchId).toBeUndefined();  // pre-existing: never stamped
    expect(grace.importBatchId).toBe("batch1"); // created: stamped
    expect(res.counts).toMatchObject({ created: 1, matched: 1, skip: 0 });
  });

  test("skips rows with no usable name", () => {
    const res = buildCustomerImport([["", "x@y.com"]], cols(["name", "email"]), [], "b");
    expect(res.counts.skip).toBe(1);
    expect(res.records).toHaveLength(0);
  });

  test("joins multiple headers mapped to name", () => {
    const res = buildCustomerImport([["Grace", "Hopper"]], cols(["name", "name"]), [], "b");
    expect(res.records[0].name).toBe("Grace Hopper");
  });
});

describe("stripBatch", () => {
  test("removes only records carrying the batch id", () => {
    const recs = [
      { id: "1", importBatchId: "b" },
      { id: "2" },
      { id: "3", importBatchId: "b" },
      { id: "4", importBatchId: "other" },
    ];
    expect(stripBatch(recs, "b").map((r) => r.id)).toEqual(["2", "4"]);
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npx jest importEngine.test --no-coverage`
Expected: FAIL — module not found.

- [ ] **Step 3: Write minimal implementation**

```ts
// utils/importEngine.ts
// Pure per-entity builders for CSV import. Given parsed rows + a column→field
// mapping + the current collection, each builder returns the FULL next array to
// save plus per-row outcomes and counts. NO I/O, NO network — the screen does
// load/save. Customers are created ONLY through upsertCustomerInList so the
// normalized-name join + blank-field backfill rules are never bypassed.

import { upsertCustomerInList } from "./storage/customers";
import type { Customer } from "../types/models";

export interface RowOutcome {
  rowIndex: number;
  status: "ok" | "skip" | "flag";
  reason?: string;
}

export interface ImportCounts {
  ok: number;
  skip: number;
  flag: number;
  created: number;
  matched: number;
}

/** Pull the first non-empty cell whose column maps to `key`, joining `name`. */
function fieldValue(row: string[], mapping: Array<string | null>, key: string): string {
  const parts: string[] = [];
  for (let i = 0; i < mapping.length; i += 1) {
    if (mapping[i] === key) {
      const v = (row[i] ?? "").trim();
      if (v) parts.push(v);
    }
  }
  return parts.join(" ");
}

const normName = (s: string) => s.trim().toLowerCase();

export interface CustomerImportResult {
  records: Customer[];
  outcomes: RowOutcome[];
  counts: ImportCounts;
}

export function buildCustomerImport(
  rows: string[][],
  mapping: Array<string | null>,
  existing: Customer[],
  batchId: string,
): CustomerImportResult {
  let acc = existing;
  const outcomes: RowOutcome[] = [];
  const counts: ImportCounts = { ok: 0, skip: 0, flag: 0, created: 0, matched: 0 };

  rows.forEach((row, rowIndex) => {
    const name = fieldValue(row, mapping, "name");
    if (!name) {
      outcomes.push({ rowIndex, status: "skip", reason: "No customer name" });
      counts.skip += 1;
      return;
    }
    const existedBefore = acc.some((c) => normName(c.name) === normName(name));
    const { customer, customers: next, changed } = upsertCustomerInList(acc, {
      name,
      email: fieldValue(row, mapping, "email"),
      phone: fieldValue(row, mapping, "phone"),
      address: fieldValue(row, mapping, "address"),
    });
    if (!customer) {
      outcomes.push({ rowIndex, status: "skip", reason: "No customer name" });
      counts.skip += 1;
      return;
    }
    if (existedBefore) {
      acc = next;                       // backfill applied (if changed); never stamped
      counts.matched += 1;
    } else {
      // Newly created — stamp importBatchId on that record only.
      acc = next.map((c) => (c.id === customer.id ? { ...c, importBatchId: batchId } : c));
      counts.created += 1;
    }
    outcomes.push({ rowIndex, status: "ok" });
    counts.ok += 1;
    void changed;
  });

  return { records: acc, outcomes, counts };
}

/** Undo helper: drop every record created by a batch (pure; screen saves result). */
export function stripBatch<T extends { importBatchId?: string }>(records: T[], batchId: string): T[] {
  return records.filter((r) => r.importBatchId !== batchId);
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `npx jest importEngine.test --no-coverage`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add utils/importEngine.ts __tests__/importEngine.test.ts
git commit -m "feat: add pure customer-import builder and undo strip helper"
```

### Task 2.4: `SettingsImportScreen` shell + Customers slot + nav wiring

**Files:**
- Create: `screens/SettingsImportScreen.tsx`
- Modify: `types/navigation.ts` (add `SettingsImport: undefined;`), `App.tsx` (import + register), `screens/SettingsHubScreen.tsx` (menu row).

**Interfaces:**
- Consumes: `parseCsv`/`hashCsv` (csvImport), `detectMapping`/`detectDateFormat`/`FIELD_DEFS`/`ImportEntity` (importMapping), `buildCustomerImport`/`stripBatch` (importEngine), `newBatchId`/`recordImportBatch`/`findBatchByFileHash` (importHistory), `loadCustomers`/`saveCustomers` (storage), `useSettingsTabPop` (hooks/useSettingsDraft), `useTheme`, theme tokens, `TodayStackScreenProps<'SettingsImport'>`.

This task is UI orchestration; it's validated by manual smoke (Expo) rather than a heavy RNTL suite — the pure logic it calls is already unit-covered. Keep the screen thin: it wires the pipeline, it holds no business rules.

- [ ] **Step 1: Add the nav param** — `types/navigation.ts`, inside `TodayStackParamList` (after `SettingsAccount: undefined;`):

```ts
  SettingsImport: undefined;
```

- [ ] **Step 2: Create the screen** with the immediate-action pattern (mirrors `SettingsBookingScreen` — `useSettingsTabPop`, no `useSettingsDraft`). Minimum viable Customers slot:

```tsx
// screens/SettingsImportScreen.tsx
// Data import is an IMMEDIATE-action page: it reads a CSV the user picks, maps
// columns, validates, previews, then commits with ONE saveX per collection. No
// draft state (SettingsBookingScreen precedent) — do not add useSettingsDraft.
// All parse/map/validate logic lives in the pure utils/* modules; this screen is
// just orchestration + I/O.

import React, { useState } from "react";
import { View, Text, ScrollView, StyleSheet, TouchableOpacity, Alert } from "react-native";
import * as DocumentPicker from "expo-document-picker";
import * as FileSystem from "expo-file-system/legacy";
import { Button } from "../components/UI";
import { useSettingsTabPop } from "../hooks/useSettingsDraft";
import { useTheme } from "../hooks/useTheme";
import { spacing, radius, fontSize, fonts, type ColorScheme } from "../utils/theme";
import { parseCsv, hashCsv } from "../utils/csvImport";
import { detectMapping, FIELD_DEFS, type ImportEntity } from "../utils/importMapping";
import { buildCustomerImport, stripBatch, type ImportCounts } from "../utils/importEngine";
import { newBatchId, recordImportBatch, findBatchByFileHash } from "../utils/importHistory";
import { loadCustomers, saveCustomers } from "../utils/storage";
import { reportError } from "../utils/analytics";
import { getTodayDateString } from "../utils/dateHelpers";
import type { TodayStackScreenProps } from "../types/navigation";

type Stage = "idle" | "mapping" | "preview" | "report";

export default function SettingsImportScreen({ navigation }: TodayStackScreenProps<"SettingsImport">) {
  const { colors } = useTheme();
  const styles = createStyles(colors);
  useSettingsTabPop(navigation);

  const [entity] = useState<ImportEntity>("customers"); // P2: customers only; P3-P5 add slots
  const [stage, setStage] = useState<Stage>("idle");
  const [headers, setHeaders] = useState<string[]>([]);
  const [rows, setRows] = useState<string[][]>([]);
  const [mapping, setMapping] = useState<Array<string | null>>([]);
  const [fileHash, setFileHash] = useState("");
  const [counts, setCounts] = useState<ImportCounts | null>(null);
  const [lastBatchId, setLastBatchId] = useState<string | null>(null);

  async function pickFile() {
    try {
      const res = await DocumentPicker.getDocumentAsync({
        type: ["text/csv", "text/comma-separated-values", "*/*"],
        copyToCacheDirectory: true,
      });
      if (res.canceled || !res.assets?.[0]) return;
      const text = await FileSystem.readAsStringAsync(res.assets[0].uri, {
        encoding: FileSystem.EncodingType.UTF8,
      });
      const parsed = parseCsv(text);
      if (parsed.headers.length === 0) {
        Alert.alert("Empty file", "That file has no readable rows.");
        return;
      }
      const hash = hashCsv(text);
      const prior = await findBatchByFileHash(entity, hash);
      const proceed = () => {
        setHeaders(parsed.headers);
        setRows(parsed.rows);
        setMapping(detectMapping(entity, parsed.headers).mapping);
        setFileHash(hash);
        setStage("mapping");
        if (parsed.truncated) {
          Alert.alert("Large file", "Only the first 5,000 rows were read.");
        }
      };
      if (prior) {
        Alert.alert("Already imported?", "This exact file looks imported already. Import again?",
          [{ text: "Cancel", style: "cancel" }, { text: "Import again", onPress: proceed }]);
      } else {
        proceed();
      }
    } catch (e) {
      reportError(e, { context: "csvImport.pickFile" });
      Alert.alert("Could not read file", "Please try a different CSV export.");
    }
  }

  function validateAndPreview() {
    const required = FIELD_DEFS[entity].filter((f) => f.required).map((f) => f.key);
    const missing = required.filter((k) => !mapping.includes(k));
    if (missing.length > 0) {
      Alert.alert("Map required columns", `Still need: ${missing.join(", ")}`);
      return;
    }
    setStage("preview");
  }

  async function commit() {
    try {
      const batchId = newBatchId();
      const existing = await loadCustomers();
      const res = buildCustomerImport(rows, mapping, existing, batchId);
      await saveCustomers(res.records);       // ONE save for the whole collection
      await recordImportBatch({ batchId, entity, fileHash, date: getTodayDateString(), counts: res.counts });
      setCounts(res.counts);
      setLastBatchId(batchId);
      setStage("report");
    } catch (e) {
      reportError(e, { context: "csvImport.commit" });
      Alert.alert("Import failed", "Nothing was changed. Please try again.");
    }
  }

  async function undo() {
    if (!lastBatchId) return;
    try {
      const existing = await loadCustomers();
      await saveCustomers(stripBatch(existing, lastBatchId));
      Alert.alert("Import undone", "The imported customers were removed.");
      setLastBatchId(null);
      setStage("idle");
    } catch (e) {
      reportError(e, { context: "csvImport.undo" });
      Alert.alert("Undo failed", "Please try again.");
    }
  }

  return (
    <ScrollView style={styles.screen} contentContainerStyle={styles.content}>
      <Text style={styles.h1}>Import data</Text>
      <Text style={styles.sub}>Bring customers in from a Jobber, Housecall Pro, QuickBooks, or spreadsheet CSV export.</Text>

      {stage === "idle" && <Button title="Choose a CSV file" onPress={pickFile} />}

      {stage === "mapping" && (
        <View>
          <Text style={styles.h2}>Match columns</Text>
          {headers.map((h, i) => (
            <View key={i} style={styles.rowMap}>
              <Text style={styles.headerCell}>{h}</Text>
              <Text style={styles.arrow}>→</Text>
              <ScrollView horizontal showsHorizontalScrollIndicator={false}>
                {[{ key: null as string | null, label: "Ignore" }, ...FIELD_DEFS[entity]].map((f) => (
                  <TouchableOpacity
                    key={String(f.key)}
                    style={[styles.chip, mapping[i] === f.key && styles.chipOn]}
                    onPress={() => setMapping((m) => m.map((v, j) => (j === i ? f.key : v)))}
                  >
                    <Text style={[styles.chipText, mapping[i] === f.key && styles.chipTextOn]}>{f.label}</Text>
                  </TouchableOpacity>
                ))}
              </ScrollView>
            </View>
          ))}
          <Button title="Preview import" onPress={validateAndPreview} />
        </View>
      )}

      {stage === "preview" && (
        <View>
          <Text style={styles.h2}>Preview</Text>
          {rows.slice(0, 5).map((r, i) => (
            <Text key={i} style={styles.previewRow}>{r.join(" · ")}</Text>
          ))}
          <Text style={styles.sub}>{rows.length} row(s) ready to import.</Text>
          <Button title="Import now" onPress={commit} />
        </View>
      )}

      {stage === "report" && counts && (
        <View>
          <Text style={styles.h2}>Import complete</Text>
          <Text style={styles.sub}>
            {counts.created} new · {counts.matched} matched existing · {counts.skip} skipped
          </Text>
          <Button title="Undo this import" variant="secondary" onPress={undo} />
          <TouchableOpacity onPress={() => setStage("idle")}><Text style={styles.link}>Import another file</Text></TouchableOpacity>
        </View>
      )}
    </ScrollView>
  );
}

function createStyles(colors: ColorScheme) {
  return StyleSheet.create({
    screen: { flex: 1, backgroundColor: colors.background },
    content: { padding: spacing.lg, gap: spacing.md },
    h1: { fontSize: fontSize.xl, fontFamily: fonts.heading, color: colors.text },
    h2: { fontSize: fontSize.lg, fontFamily: fonts.heading, color: colors.text, marginTop: spacing.md },
    sub: { fontSize: fontSize.sm, fontFamily: fonts.body, color: colors.textMuted },
    rowMap: { flexDirection: "row", alignItems: "center", gap: spacing.sm, marginVertical: spacing.xs },
    headerCell: { width: 110, fontFamily: fonts.mono, fontSize: fontSize.sm, color: colors.text },
    arrow: { color: colors.textMuted },
    chip: { paddingHorizontal: spacing.sm, paddingVertical: spacing.xs, borderRadius: radius.pill, borderWidth: 1, borderColor: colors.border, marginRight: spacing.xs },
    chipOn: { backgroundColor: colors.accent, borderColor: colors.accent },
    chipText: { fontSize: fontSize.sm, color: colors.text },
    chipTextOn: { color: colors.onAccent ?? "#fff" },
    previewRow: { fontFamily: fonts.mono, fontSize: fontSize.sm, color: colors.text },
    link: { color: colors.accent, marginTop: spacing.md },
  });
}
```

> **Verify at implementation:** the exact theme token names (`colors.background`, `colors.text`, `colors.textMuted`, `colors.accent`, `colors.onAccent`, `colors.border`, `fonts.heading/body/mono`, `fontSize.xl/lg/sm`, `radius.pill`, `spacing.*`) and the `Button` `variant` prop against `components/UI` and `utils/theme.ts` before running the gate. Match whatever those files actually export — do not invent tokens. If `colors.onAccent` doesn't exist, use the accent-contrast token the other Settings screens use.

- [ ] **Step 3: Register in the navigator** — `App.tsx`: add near the other Settings imports (~line 64):

```tsx
import SettingsImportScreen from "./screens/SettingsImportScreen";
```

and inside the `TodayStack.Navigator` block near line 144:

```tsx
<TodayStack.Screen name="SettingsImport" component={SettingsImportScreen} options={{ title: "Import data" }} />
```

- [ ] **Step 4: Add the hub menu row** — `screens/SettingsHubScreen.tsx` (~line 71, in the menu-item list; place it in a sensible group, e.g. near account/data rows):

```tsx
{ icon: "cloud-upload-outline", label: "Import data", onPress: () => navigation.navigate("SettingsImport") },
```

- [ ] **Step 5: Run the full gate**

Run: `npm run typecheck && npm test && npm run lint`
Expected: 0 tsc errors, all suites pass, 0 lint warnings. Fix any token/prop mismatches surfaced by tsc.

- [ ] **Step 6: Manual smoke (Expo, owner or dev device)** — pick a small customers CSV, map, preview, import, verify customers appear in the Customers tab, then Undo and verify they're gone and pre-existing customers remain. (Web preview can't verify this UI — see memory; device smoke.)

- [ ] **Step 7: Commit**

```bash
git add screens/SettingsImportScreen.tsx App.tsx types/navigation.ts screens/SettingsHubScreen.tsx
git commit -m "feat: add Data Import settings screen with CSV customer import + undo"
```

**END OF PHASE 2 — phase report + STOP.** Report must include the manual-smoke result (undo verified non-destructive to pre-existing customers) and flag `screens/SettingsImportScreen.tsx` as intentionally light on RNTL coverage (pure logic is unit-tested; screen is smoke-verified).

---

## PHASE 3 — Jobs + schedule

**Deliverable:** `buildJobImport` (pure) with status keyword mapping, customer join, date/time mapping; a "Jobs" slot in `SettingsImportScreen`.

### Task 3.1: Job status keyword map + job import builder

**Files:**
- Modify: `utils/importEngine.ts` (add `mapJobStatus`, `buildJobImport`, `JobImportResult`)
- Test: `__tests__/importEngine.jobs.test.ts`

**Interfaces:**
- Produces:
  - `mapJobStatus(raw: string): { status: JobStatus; recognized: boolean }`
  - `interface JobImportResult { customers: Customer[]; jobs: Job[]; outcomes: RowOutcome[]; counts: ImportCounts }`
  - `buildJobImport(rows, mapping, existingCustomers, existingJobs, batchId, dateFormat): JobImportResult`
- Consumes: `JobStatus` (models), `upsertCustomerInList`, `parseImportDate` (importMapping).

**Design notes locked by spec:** status assigned DIRECTLY (not via `JOB_STATUSES.next`), unrecognized → `lead` + flag; `estimateSentAt` stays absent (no nudges); pricing internals default to 0/[]; jobs join a customer by name via `upsertCustomerInList` (creating + stamping new customers into the SAME batch), then stamp `customerId`+`customerName`. `buildJobImport` returns BOTH next-customers and next-jobs so the screen saves each collection once.

- [ ] **Step 1: Write the failing test**

```ts
// __tests__/importEngine.jobs.test.ts
import { buildJobImport, mapJobStatus } from "../utils/importEngine";
import type { Customer, Job } from "../types/models";

describe("mapJobStatus", () => {
  test("maps common foreign statuses", () => {
    expect(mapJobStatus("Lead").status).toBe("lead");
    expect(mapJobStatus("Estimate Sent").status).toBe("estimate_sent");
    expect(mapJobStatus("In Progress").status).toBe("in_progress");
    expect(mapJobStatus("Completed").status).toBe("complete");
    expect(mapJobStatus("Paid").status).toBe("paid");
    expect(mapJobStatus("Cancelled").status).toBe("declined");
  });
  test("flags unrecognised status as lead", () => {
    const r = mapJobStatus("Zorp");
    expect(r.status).toBe("lead");
    expect(r.recognized).toBe(false);
  });
});

describe("buildJobImport", () => {
  const mapping = ["title", "customerName", "status", "scheduledDate"];
  test("creates a job, joins/creates the customer, assigns status directly", () => {
    const existingCustomers: Customer[] = [];
    const existingJobs: Job[] = [];
    const rows = [["Fix sink", "Grace Hopper", "Completed", "07/04/2026"]];
    const res = buildJobImport(rows, mapping, existingCustomers, existingJobs, "b1", "MDY");

    expect(res.jobs).toHaveLength(1);
    const job = res.jobs[0];
    expect(job.title).toBe("Fix sink");
    expect(job.status).toBe("complete");
    expect(job.scheduledDate).toBe("2026-07-04");
    expect(job.estimateSentAt).toBeUndefined();     // no nudges on imports
    expect(job.materials).toEqual([]);
    expect(job.importBatchId).toBe("b1");

    const cust = res.customers.find((c) => c.name === "Grace Hopper")!;
    expect(cust).toBeTruthy();
    expect(cust.importBatchId).toBe("b1");          // created in this batch
    expect(job.customerId).toBe(cust.id);           // linked
    expect(job.customerName).toBe("Grace Hopper");
  });

  test("skips a row missing title or customer", () => {
    const res = buildJobImport([["", "X"]], mapping, [], [], "b", "MDY");
    expect(res.counts.skip).toBe(1);
    expect(res.jobs).toHaveLength(0);
  });

  test("flags an unrecognised status but still imports", () => {
    const res = buildJobImport([["Job A", "Cust", "Zorp", ""]], mapping, [], [], "b", "MDY");
    expect(res.jobs[0].status).toBe("lead");
    expect(res.counts.flag).toBe(1);
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npx jest importEngine.jobs --no-coverage`
Expected: FAIL — `buildJobImport` / `mapJobStatus` not exported.

- [ ] **Step 3: Add the implementation** to `utils/importEngine.ts`:

```ts
import type { Customer, Job, JobStatus } from "../types/models";
import { parseImportDate, type DateFormat } from "./importMapping";

const STATUS_KEYWORDS: Array<{ status: JobStatus; words: string[] }> = [
  { status: "estimate_sent", words: ["estimate sent", "quote sent", "quoted", "estimate", "quote"] },
  { status: "in_progress", words: ["in progress", "started", "working", "active"] },
  { status: "declined", words: ["declined", "lost", "cancelled", "canceled", "rejected"] },
  { status: "scheduled", words: ["scheduled", "booked", "upcoming"] },
  { status: "approved", words: ["approved", "won", "accepted"] },
  { status: "complete", words: ["complete", "completed", "done", "closed", "finished"] },
  { status: "invoiced", words: ["invoiced", "billed"] },
  { status: "paid", words: ["paid"] },
  { status: "lead", words: ["lead", "new", "inquiry", "enquiry", "prospect"] },
];

export function mapJobStatus(raw: string): { status: JobStatus; recognized: boolean } {
  const s = (raw || "").trim().toLowerCase();
  if (!s) return { status: "lead", recognized: false };
  for (const entry of STATUS_KEYWORDS) {
    if (entry.words.some((w) => s.includes(w))) return { status: entry.status, recognized: true };
  }
  return { status: "lead", recognized: false };
}

export interface JobImportResult {
  customers: Customer[];
  jobs: Job[];
  outcomes: RowOutcome[];
  counts: ImportCounts;
}

let _jobSeq = 0;
function newJobId(): string { _jobSeq += 1; return `j${Date.now()}_${_jobSeq}`; }

export function buildJobImport(
  rows: string[][],
  mapping: Array<string | null>,
  existingCustomers: Customer[],
  existingJobs: Job[],
  batchId: string,
  dateFormat: DateFormat | null,
): JobImportResult {
  let customers = existingCustomers;
  const jobs: Job[] = [...existingJobs];
  const outcomes: RowOutcome[] = [];
  const counts: ImportCounts = { ok: 0, skip: 0, flag: 0, created: 0, matched: 0 };

  rows.forEach((row, rowIndex) => {
    const title = fieldValue(row, mapping, "title");
    const customerName = fieldValue(row, mapping, "customerName");
    if (!title || !customerName) {
      outcomes.push({ rowIndex, status: "skip", reason: "Missing job title or customer" });
      counts.skip += 1;
      return;
    }

    // Join or create the customer within this same batch.
    const existedBefore = customers.some((c) => c.name.trim().toLowerCase() === customerName.trim().toLowerCase());
    const up = upsertCustomerInList(customers, { name: customerName });
    const customer = up.customer!;
    customers = existedBefore
      ? up.customers
      : up.customers.map((c) => (c.id === customer.id ? { ...c, importBatchId: batchId } : c));

    const statusRaw = fieldValue(row, mapping, "status");
    const { status, recognized } = mapJobStatus(statusRaw);
    const scheduledDate = parseImportDate(fieldValue(row, mapping, "scheduledDate"), dateFormat);
    const estimateTotal = Number(fieldValue(row, mapping, "estimateTotal").replace(/[^0-9.\-]/g, "")) || 0;

    const job: Job = {
      id: newJobId(),
      customerId: customer.id,
      customerName: customer.name,
      title,
      description: fieldValue(row, mapping, "description"),
      status,
      scheduledDate,
      scheduledStartTime: null,
      scheduledEndTime: null,
      address: fieldValue(row, mapping, "address"),
      estimateTotal,
      laborHours: 0,
      laborRate: 0,
      materials: [],
      materialMarkup: 0,
      overhead: 0,
      margin: 0,
      notes: fieldValue(row, mapping, "notes"),
      invoiceId: null,
      createdAt: getTodayDateString(),
      importBatchId: batchId,
      // estimateSentAt deliberately absent → no follow-up nudge on imports.
    };
    jobs.push(job);

    if (statusRaw && !recognized) {
      outcomes.push({ rowIndex, status: "flag", reason: `Unknown status "${statusRaw}" → lead` });
      counts.flag += 1;
    } else {
      outcomes.push({ rowIndex, status: "ok" });
      counts.ok += 1;
    }
  });

  return { customers, jobs, outcomes, counts };
}
```

Add `import { getTodayDateString } from "./dateHelpers";` to the top of `utils/importEngine.ts` (used by the job builder's `createdAt`).

- [ ] **Step 4: Run test to verify it passes**

Run: `npx jest importEngine.jobs --no-coverage`
Expected: PASS.

- [ ] **Step 5: Wire the Jobs slot into `SettingsImportScreen`** — add an entity selector (Customers / Jobs / Invoices / Expenses tabs), detect the date format from the mapped date column's sample cells (`detectDateFormat(rows.map((r) => r[dateColIndex]))`), and branch `commit()` on `entity`: for `jobs`, call `buildJobImport`, then `await saveCustomers(res.customers)` and `await saveJobs(res.jobs)` — each collection saved exactly once.

> Full screen edit shown at implementation time — the shape is: a `switch (entity)` in `commit()`, and the same `switch` in `undo()` (jobs undo strips both jobs and, optionally, batch-created customers — decide per the P3 report whether undo also removes batch-created customers or leaves them; recommend leaving customers since later job/invoice imports may reference them — flag this as an owner decision).

- [ ] **Step 6: Gate + manual smoke (jobs CSV) + commit**

```bash
git add utils/importEngine.ts __tests__/importEngine.jobs.test.ts screens/SettingsImportScreen.tsx
git commit -m "feat: add job + schedule CSV import with status mapping and customer join"
```

**END OF PHASE 3 — phase report + STOP.** Raise the undo-scope decision (does undoing a jobs batch also remove customers it created?) as a Missing-Context item.

---

## PHASE 4 — Invoices (paid semantics, number continuity, id-timestamp embedding)

**Deliverable:** `buildInvoiceImport` (pure) honoring the money rules; Invoices slot in the screen.

### Task 4.1: Invoice import builder

**Files:**
- Modify: `utils/importEngine.ts` (add `buildInvoiceImport`, `InvoiceImportResult`)
- Test: `__tests__/importEngine.invoices.test.ts`

**Interfaces:**
- Produces:
  - `interface InvoiceImportResult { customers: Customer[]; invoices: Invoice[]; outcomes: RowOutcome[]; counts: ImportCounts }`
  - `buildInvoiceImport(rows, mapping, existingCustomers, existingInvoices, batchId, dateFormat, nextNumberStart): InvoiceImportResult`
- Consumes: `Invoice`, `Customer`, `upsertCustomerInList`, `parseImportDate`.

**Money rules locked by spec:**
- `paid: true` + `paidAt` from a mapped paid-date column, **NO `payments` ledger** (legacy derivation in `utils/invoicePayments.ts` handles it via `paid`/`amount`/`paidAt`).
- **Paid claim with NO mappable paid date → import as OUTSTANDING (`paid: false`) + FLAG.** Never fabricate a paid date.
- Invoice **id embeds the source issue-date ms** so `invoiceIssueDate` recovers the historical date in PDFs. Derive the ms from the mapped issue/paid/due date (prefer an issue date if present, else `due`, else today). Build id as `String(issueMs)` (matching the creation-path convention that the PDF template reads).
- `number`: use the source's if mapped, else continue from `nextInvoiceNumber` (the screen passes the current next-number; the builder increments locally for unmapped rows).
- No side effects (no Stripe links, deposits, dunning).

- [ ] **Step 1: Write the failing test**

```ts
// __tests__/importEngine.invoices.test.ts
import { buildInvoiceImport } from "../utils/importEngine";
import { amountPaid, balanceDue } from "../utils/invoicePayments";
import type { Customer, Invoice } from "../types/models";

const mapping = ["customer", "amount", "number", "due", "paidAt"];

test("imports a paid invoice with paidAt and NO ledger; selectors derive paid", () => {
  const rows = [["Ada", "500", "INV-1", "06/01/2026", "06/15/2026"]];
  const res = buildInvoiceImport(rows, mapping, [], [], "b1", "MDY", 100);
  const inv = res.invoices[0];
  expect(inv.paid).toBe(true);
  expect(inv.paidAt).toBe("2026-06-15");
  expect(inv.payments).toBeUndefined();       // no fabricated ledger
  expect(amountPaid(inv)).toBe(500);          // legacy derivation still works
  expect(balanceDue(inv)).toBe(0);
  expect(inv.importBatchId).toBe("b1");
});

test("a paid claim with no paid date imports outstanding + flagged", () => {
  const rows = [["Ada", "500", "INV-2", "06/01/2026", ""]]; // paidAt blank
  // caller marks intent via a 'paid' text column OR we treat missing paidAt as unpaid.
  const res = buildInvoiceImport(rows, mapping, [], [], "b", "MDY", 100);
  const inv = res.invoices[0];
  expect(inv.paid).toBe(false);
  expect(balanceDue(inv)).toBe(500);
});

test("continues invoice numbering when number is unmapped", () => {
  const res = buildInvoiceImport(
    [["Ada", "100", "", "", ""], ["Bo", "200", "", "", ""]],
    mapping, [], [], "b", "MDY", 100,
  );
  expect(res.invoices.map((i) => i.number)).toEqual(["100", "101"]);
});

test("skips rows missing customer or amount", () => {
  const res = buildInvoiceImport([["", "100", "", "", ""]], mapping, [], [], "b", "MDY", 1);
  expect(res.counts.skip).toBe(1);
});

test("embeds the source date ms in the invoice id", () => {
  const res = buildInvoiceImport([["Ada", "100", "", "06/15/2026", ""]], mapping, [], [], "b", "MDY", 1);
  const ms = Number(res.invoices[0].id);
  expect(Number.isFinite(ms)).toBe(true);
  expect(new Date(ms).getFullYear()).toBe(2026);
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npx jest importEngine.invoices --no-coverage`
Expected: FAIL — `buildInvoiceImport` not exported.

- [ ] **Step 3: Implement** in `utils/importEngine.ts` (key logic — full version at implementation):

```ts
export interface InvoiceImportResult {
  customers: Customer[];
  invoices: Invoice[];
  outcomes: RowOutcome[];
  counts: ImportCounts;
}

function parseMoney(raw: string): number | null {
  const cleaned = (raw || "").replace(/[^0-9.\-]/g, "");
  if (!cleaned) return null;
  const n = Number(cleaned);
  return Number.isFinite(n) ? n : null;
}

function issueMsFromDate(dateStr: string | null): number {
  if (!dateStr) return Date.now();
  const [y, m, d] = dateStr.split("-").map(Number);
  return new Date(y, m - 1, d, 12, 0, 0).getTime();  // local noon; FA-039-safe
}

export function buildInvoiceImport(
  rows: string[][],
  mapping: Array<string | null>,
  existingCustomers: Customer[],
  existingInvoices: Invoice[],
  batchId: string,
  dateFormat: DateFormat | null,
  nextNumberStart: number,
): InvoiceImportResult {
  let customers = existingCustomers;
  const invoices: Invoice[] = [...existingInvoices];
  const outcomes: RowOutcome[] = [];
  const counts: ImportCounts = { ok: 0, skip: 0, flag: 0, created: 0, matched: 0 };
  let nextNumber = nextNumberStart;

  rows.forEach((row, rowIndex) => {
    const customerName = fieldValue(row, mapping, "customer");
    const amount = parseMoney(fieldValue(row, mapping, "amount"));
    if (!customerName || amount == null) {
      outcomes.push({ rowIndex, status: "skip", reason: "Missing customer or amount" });
      counts.skip += 1;
      return;
    }

    const existedBefore = customers.some((c) => c.name.trim().toLowerCase() === customerName.trim().toLowerCase());
    const up = upsertCustomerInList(customers, {
      name: customerName,
      email: fieldValue(row, mapping, "email"),
      phone: fieldValue(row, mapping, "phone"),
    });
    const customer = up.customer!;
    customers = existedBefore ? up.customers
      : up.customers.map((c) => (c.id === customer.id ? { ...c, importBatchId: batchId } : c));

    const due = parseImportDate(fieldValue(row, mapping, "due"), dateFormat);
    const paidAt = parseImportDate(fieldValue(row, mapping, "paidAt"), dateFormat);
    const paid = !!paidAt;                     // paid ONLY if a real paid date exists
    const claimedPaid = /paid|yes|true/i.test(fieldValue(row, mapping, "paidAt")) && !paidAt;

    const number = fieldValue(row, mapping, "number") || String(nextNumber++);
    const issueMs = issueMsFromDate(due ?? paidAt);

    const inv: Invoice = {
      id: String(issueMs),                     // PDF issue-date recovery
      customer: customer.name,
      customerId: customer.id,
      number,
      amount,
      due: due ?? getTodayDateString(),
      email: fieldValue(row, mapping, "email"),
      phone: fieldValue(row, mapping, "phone"),
      desc: fieldValue(row, mapping, "desc"),
      paid,
      ...(paid ? { paidAt: paidAt! } : {}),
      importBatchId: batchId,
    };
    invoices.push(inv);

    if (claimedPaid) {
      outcomes.push({ rowIndex, status: "flag", reason: "Marked paid but no paid date → imported outstanding" });
      counts.flag += 1;
    } else {
      outcomes.push({ rowIndex, status: "ok" });
      counts.ok += 1;
    }
  });

  return { customers, invoices, outcomes, counts };
}
```

> **Verify at implementation:** the invoice creation-path id convention (is `id` the raw ms `String(ms)`, or a prefixed form?) against `invoiceIssueDate` in `utils/pdfTemplates` and how `AddInvoiceScreen` builds ids (`String(Date.now())`). Match it exactly so `invoiceIssueDate` recovers the date. Also confirm how the screen obtains `nextNumberStart` (`Settings.nextInvoiceNumber` via `loadSettings`) — the builder must NOT itself write settings; whether/how to advance `nextInvoiceNumber` after import is an owner decision to raise in the P4 report.

- [ ] **Step 4: Run test to verify it passes**

Run: `npx jest importEngine.invoices --no-coverage`
Expected: PASS.

- [ ] **Step 5: Wire Invoices slot** into the screen `commit()`/`undo()` switch; saves `saveCustomers` + `saveInvoices` once each.

- [ ] **Step 6: Gate + manual smoke (invoices CSV, incl. a paid row and a paid-without-date row) + commit**

```bash
git add utils/importEngine.ts __tests__/importEngine.invoices.test.ts screens/SettingsImportScreen.tsx
git commit -m "feat: add invoice CSV import with legacy paid semantics and issue-date ids"
```

**END OF PHASE 4 — phase report + STOP.** Missing-context items: invoice id convention confirmation; `nextInvoiceNumber` advancement decision.

---

## PHASE 5 — Expenses + polish

**Deliverable:** `buildExpenseImport` with category keyword mapping; Expenses slot; file-hash re-import warning (already built in 2.2/2.4 — verify wired for all entities); sample-data offer; full report UX (skipped/flagged detail list); owner device smoke on real Jobber/HCP/QB exports.

### Task 5.1: Expense category map + expense import builder

**Files:**
- Modify: `utils/importEngine.ts` (`mapExpenseCategory`, `buildExpenseImport`, `ExpenseImportResult`)
- Test: `__tests__/importEngine.expenses.test.ts`

**Interfaces:**
- Produces:
  - `mapExpenseCategory(raw: string): { id: ExpenseCategoryId; recognized: boolean }`
  - `interface ExpenseImportResult { expenses: Expense[]; outcomes: RowOutcome[]; counts: ImportCounts }`
  - `buildExpenseImport(rows, mapping, existingExpenses, batchId, dateFormat): ExpenseImportResult`
- Consumes: `Expense`, `ExpenseCategoryId`, `EXPENSE_CATEGORIES` (moneyUtils), `parseImportDate`.

**Rules:** unmapped/unrecognized category → `"other"` (verified catch-all id) + flag; `receiptUri: null`; date required (skip if unparseable); amount required.

- [ ] **Step 1: Write the failing test**

```ts
// __tests__/importEngine.expenses.test.ts
import { buildExpenseImport, mapExpenseCategory } from "../utils/importEngine";

const mapping = ["amount", "date", "description", "category"];

describe("mapExpenseCategory", () => {
  test("maps by keyword to a real category id", () => {
    expect(mapExpenseCategory("Materials").id).toBe("materials");
    expect(mapExpenseCategory("Fuel").id).toBe("fuel");
    expect(mapExpenseCategory("Software & Apps").id).toBe("software");
  });
  test("unrecognised → other, flagged", () => {
    const r = mapExpenseCategory("Misc Widget");
    expect(r.id).toBe("other");
    expect(r.recognized).toBe(false);
  });
});

describe("buildExpenseImport", () => {
  test("imports an expense with parsed local date and category", () => {
    const res = buildExpenseImport([["49.99", "07/04/2026", "Home Depot", "Materials"]], mapping, [], "b1", "MDY");
    const e = res.expenses[0];
    expect(e.amount).toBe(49.99);
    expect(e.date).toBe("2026-07-04");
    expect(e.category).toBe("materials");
    expect(e.receiptUri).toBeNull();
    expect(e.importBatchId).toBe("b1");
  });
  test("skips a row with an unparseable date", () => {
    const res = buildExpenseImport([["10", "garbage", "x", ""]], mapping, [], "b", "MDY");
    expect(res.counts.skip).toBe(1);
  });
  test("flags an unknown category but imports as other", () => {
    const res = buildExpenseImport([["10", "07/04/2026", "x", "Zorp"]], mapping, [], "b", "MDY");
    expect(res.expenses[0].category).toBe("other");
    expect(res.counts.flag).toBe(1);
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npx jest importEngine.expenses --no-coverage`
Expected: FAIL.

- [ ] **Step 3: Implement** in `utils/importEngine.ts`:

```ts
import type { Expense } from "../types/models";
import type { ExpenseCategoryId } from "../types/models";
import { EXPENSE_CATEGORIES } from "./moneyUtils";

export function mapExpenseCategory(raw: string): { id: ExpenseCategoryId; recognized: boolean } {
  const s = (raw || "").trim().toLowerCase();
  if (!s) return { id: "other", recognized: false };
  // Match against the canonical labels/ids first.
  for (const c of EXPENSE_CATEGORIES) {
    if (c.id === s || c.label.toLowerCase() === s || s.includes(c.id)) {
      return { id: c.id, recognized: true };
    }
  }
  const extra: Array<{ id: ExpenseCategoryId; words: string[] }> = [
    { id: "fuel", words: ["gas", "fuel", "mileage", "transport"] },
    { id: "tools", words: ["tool", "equipment", "rental"] },
    { id: "labor", words: ["subcontractor", "sub", "labour", "labor", "crew"] },
    { id: "marketing", words: ["ad", "advertis", "marketing"] },
    { id: "software", words: ["software", "subscription", "app"] },
    { id: "insurance", words: ["insurance"] },
    { id: "materials", words: ["material", "supply", "supplies", "lumber"] },
  ];
  for (const e of extra) if (e.words.some((w) => s.includes(w))) return { id: e.id, recognized: true };
  return { id: "other", recognized: false };
}

export interface ExpenseImportResult {
  expenses: Expense[];
  outcomes: RowOutcome[];
  counts: ImportCounts;
}

let _expSeq = 0;
function newExpenseId(): string { _expSeq += 1; return `e${Date.now()}_${_expSeq}`; }

export function buildExpenseImport(
  rows: string[][],
  mapping: Array<string | null>,
  existingExpenses: Expense[],
  batchId: string,
  dateFormat: DateFormat | null,
): ExpenseImportResult {
  const expenses: Expense[] = [...existingExpenses];
  const outcomes: RowOutcome[] = [];
  const counts: ImportCounts = { ok: 0, skip: 0, flag: 0, created: 0, matched: 0 };

  rows.forEach((row, rowIndex) => {
    const amount = parseMoney(fieldValue(row, mapping, "amount"));
    const date = parseImportDate(fieldValue(row, mapping, "date"), dateFormat);
    if (amount == null || !date) {
      outcomes.push({ rowIndex, status: "skip", reason: amount == null ? "Missing amount" : "Unparseable date" });
      counts.skip += 1;
      return;
    }
    const catRaw = fieldValue(row, mapping, "category");
    const { id: category, recognized } = mapExpenseCategory(catRaw);
    expenses.push({
      id: newExpenseId(),
      createdAt: getTodayDateString(),
      description: fieldValue(row, mapping, "description"),
      amount,
      category,
      date,
      notes: fieldValue(row, mapping, "notes"),
      receiptUri: null,
      importBatchId: batchId,
    });
    if (catRaw && !recognized) {
      outcomes.push({ rowIndex, status: "flag", reason: `Unknown category "${catRaw}" → Other` });
      counts.flag += 1;
    } else {
      outcomes.push({ rowIndex, status: "ok" });
      counts.ok += 1;
    }
  });

  return { expenses, outcomes, counts };
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `npx jest importEngine.expenses --no-coverage`
Expected: PASS.

### Task 5.2: Screen polish — Expenses slot, flagged-row report list, sample-data offer

**Files:**
- Modify: `screens/SettingsImportScreen.tsx`

- [ ] **Step 1: Wire the Expenses slot** — `commit()`/`undo()` switch calls `buildExpenseImport` + one `saveExpenses`.
- [ ] **Step 2: Report detail** — render the skip/flag `outcomes` (row index + reason) in the report stage, not just counts.
- [ ] **Step 3: Sample-data offer** — before the first import, if sample data is present, offer `clearSampleData` (verify the exact export name/location before wiring; search `clearSampleData` in `utils/`). If it doesn't exist under that name, raise it in the report rather than inventing one.
- [ ] **Step 4: Re-import warning** — confirm `findBatchByFileHash` is consulted for every entity (already in `pickFile`), and `recordImportBatch` runs on every successful commit for every entity.
- [ ] **Step 5: Full gate**

Run: `npm run typecheck && npm test && npm run lint`
Expected: 0 / all pass / 0.

- [ ] **Step 6: Owner device smoke** — real Jobber, Housecall Pro, and QuickBooks exports through all four slots; verify counts, a paid invoice, a paid-without-date flag, an unknown status/category flag, and undo of each entity. This is the gate for any store-listing claim (claims discipline: not claimable until shipped + smoked).

- [ ] **Step 7: Commit**

```bash
git add utils/importEngine.ts __tests__/importEngine.expenses.test.ts screens/SettingsImportScreen.tsx
git commit -m "feat: add expense CSV import, import report detail, and re-import warning"
```

**END OF PHASE 5 — final phase report + STOP.** Report: full gate numbers, device-smoke results per platform, and the docs the change touches (flag `ARCHITECTURE.md` file map + `README` feature list for a docs pass per `tradeready-docs-and-writing`; note the `types/models.ts` shape change for `tradeready-storage-and-sync` and the new Settings subpage for `tradeready-config-and-flags`).

---

## Self-Review (against the spec)

**Spec coverage:**
- Generic CSV, column mapping, no API/AI → P1 `importMapping` (deterministic synonyms) ✓
- Settings subpage, immediate-action, `useSettingsTabPop` not `useSettingsDraft` → Task 2.4 ✓
- Full history scope (customers, jobs+schedule, invoices incl. paid, expenses) → P2–P5 ✓
- Pipeline: pick / parse / detect / map / validate(no writes) / preview / commit(one saveX each) → P1 parser + 2.4 screen stages + per-entity builders ✓
- Identity via `upsertCustomerInList`/`getOrCreateCustomer` only → all builders use `upsertCustomerInList` ✓
- `importBatchId` additive-optional on 4 models, stamped only on created records, structural undo → Task 2.1 + `created`-vs-`matched` stamping + `stripBatch` ✓
- Paid semantics: `paidAt` + no ledger; paid-without-date → outstanding+flag → Task 4.1 + `invoicePayments` derivation test ✓
- Invoice id embeds issue-date ms → Task 4.1 `issueMsFromDate` (with an implementation-time verify against `invoiceIssueDate`) ✓
- Job status assigned directly, unknown→lead+flag, `estimateSentAt` absent → Task 3.1 ✓
- Expense category keyword map, unmapped→`other`+flag, `receiptUri: null` → Task 5.1 ✓
- FA-039 local dates everywhere → `parseImportDate` via `toDateString`; `issueMsFromDate` uses local constructor ✓
- Non-synced import history + file-hash re-import warning → Task 2.2 + screen wiring ✓
- Soft row cap, never-throw parser, validate-before-write, one save per collection → P1 parser + builders return full arrays ✓
- Zero new deps → `expo-document-picker`/`expo-file-system` already present (Rule-3 check in Global Constraints) ✓

**Open verification flags carried into implementation (each surfaced in the relevant phase report, not silently assumed):**
1. Invoice `id` convention exact match vs `invoiceIssueDate` (P4).
2. `nextInvoiceNumber` advancement after import — owner decision (P4).
3. Jobs-batch undo: also remove batch-created customers? — owner decision (P3).
4. `clearSampleData` exact export (P5).
5. Theme token / `Button` variant names in the screen (P2, verify against `components/UI` + `utils/theme.ts`).

---

## Execution options

After owner go-ahead on the plan, per superpowers:writing-plans handoff:

1. **Subagent-Driven (recommended)** — fresh subagent per task, two-stage review between tasks. Good fit: the pure builders are cleanly testable in isolation.
2. **Inline Execution** — execute tasks in this session with checkpoints.

Either way, the phase boundaries (P1–P5) remain hard STOP points for owner review, independent of task-level execution style.
