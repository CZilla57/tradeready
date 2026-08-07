# Accountant Package Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an accountant-ready `.zip` export (invoices, line items, payments, expenses, mileage, customers, category map, plus warnings/summary/README control files) on top of the existing per-dataset CSV exports.

**Architecture:** Pure, unit-testable builders in the `csvExport.ts` mold. A zero-dependency stored-ZIP writer (`utils/zipStore.ts`) assembles UTF-8/base64 bytes; `utils/accountingPackage.ts` builds every CSV/JSON/README and the manifest; a `shareZip` tail (in `utils/csvExport.ts`) writes base64 and opens the share sheet; `ExportDataScreen` gains one action.

**Tech Stack:** TypeScript (strict), React Native / Expo 54, `expo-file-system/legacy`, `expo-sharing`, Jest (jest-expo).

**Spec:** `docs/superpowers/specs/2026-08-07-accountant-package-design.md`

## Global Constraints

- **No new dependencies; no `package.json`/SDK/`app.json` plugins change** (tradeready-change-control Rule 3). The ZIP writer is hand-rolled.
- **No persisted data-shape change.** Builders read existing shapes only.
- **Green gate before every commit:** `npm run typecheck` (0 errors) · `npm test` (all pass) · `npm run lint` (`--max-warnings=0`). Run from `C:\dev\tradeready\tradeready`.
- **Phase-gate (Rule 1):** each Task below is a phase. At its end, report Confidence / Missing Context / Recommended Next Step, then **STOP for owner go-ahead**. Commit only when the owner asks and the gate is green.
- **No `@ts-ignore` / `eslint-disable` / `@ts-expect-error`** without a documented compatibility reason.
- **Determinism:** identical data + range → byte-identical archive. No wall-clock (`Date.now()`/`new Date()`) in any builder or payload. Ranges come from the caller.
- **CSV rules:** RFC-4180 escaping via `escapeCsvField`; CRLF; `UTF-8 BOM` prefixed on each CSV entry's bytes; no totals rows; rows sorted by date then a stable code-unit key (never `localeCompare`).
- **Secrets:** builders receive only invoices/expenses/trips/customers — never `Settings`, keys, tokens, or file paths. `receiptUri` surfaces only as a `Yes/No` flag.
- Reuse existing helpers: `escapeCsvField`, `toCsv` (`utils/csvExport.ts`); `paymentsInRange`, `effectivePayments`, `toAmount`, `amountPaid`, `balanceDue`, `overpaidAmount`, `collectedInRange`, `isFullyPaid`, `isPartlyPaid` (`utils/invoicePayments.ts`); `EXPENSE_CATEGORIES`, `isInRange` (`utils/moneyUtils.ts`).

---

### Task 1: `utils/zipStore.ts` — zero-dependency stored-ZIP writer

**Files:**
- Create: `utils/zipStore.ts`
- Test: `__tests__/zipStore.test.ts`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `crc32(bytes: Uint8Array): number`
  - `utf8Encode(s: string): Uint8Array`
  - `base64Encode(bytes: Uint8Array): string`
  - `type ZipEntry = { name: string; bytes: Uint8Array }`
  - `buildZip(entries: ZipEntry[]): Uint8Array`

- [ ] **Step 1: Write the failing tests**

```ts
// __tests__/zipStore.test.ts
import { crc32, utf8Encode, base64Encode, buildZip } from "../utils/zipStore";

describe("crc32", () => {
  test("known vector for empty input", () => {
    expect(crc32(new Uint8Array([]))).toBe(0);
  });
  test('known vector for "123456789"', () => {
    // CRC-32/ISO-HDLC of the ASCII string "123456789" = 0xCBF43926
    expect(crc32(utf8Encode("123456789"))).toBe(0xcbf43926);
  });
});

describe("utf8Encode", () => {
  test("ASCII", () => {
    expect(Array.from(utf8Encode("AB"))).toEqual([0x41, 0x42]);
  });
  test("2-byte (é)", () => {
    expect(Array.from(utf8Encode("\u00e9"))).toEqual([0xc3, 0xa9]);
  });
  test("astral / surrogate pair (😀 U+1F600)", () => {
    expect(Array.from(utf8Encode("\uD83D\uDE00"))).toEqual([0xf0, 0x9f, 0x98, 0x80]);
  });
});

describe("base64Encode", () => {
  test("len % 3 == 0", () => {
    expect(base64Encode(Uint8Array.from([0x4d, 0x61, 0x6e]))).toBe("TWFu");
  });
  test("len % 3 == 1 (one pad)", () => {
    expect(base64Encode(Uint8Array.from([0x4d]))).toBe("TQ==");
  });
  test("len % 3 == 2 (two chars, one pad)", () => {
    expect(base64Encode(Uint8Array.from([0x4d, 0x61]))).toBe("TWE=");
  });
});

describe("buildZip", () => {
  test("emits a valid EOCD with the entry count and is deterministic", () => {
    const entries = [
      { name: "a.txt", bytes: utf8Encode("hello") },
      { name: "b.txt", bytes: utf8Encode("world") },
    ];
    const zip = buildZip(entries);
    // Local file header signature at offset 0.
    expect(Array.from(zip.slice(0, 4))).toEqual([0x50, 0x4b, 0x03, 0x04]);
    // End-of-central-directory signature present.
    const eocdSig = [0x50, 0x4b, 0x05, 0x06];
    let found = -1;
    for (let i = zip.length - 22; i >= 0; i--) {
      if (zip[i] === eocdSig[0] && zip[i + 1] === eocdSig[1] && zip[i + 2] === eocdSig[2] && zip[i + 3] === eocdSig[3]) { found = i; break; }
    }
    expect(found).toBeGreaterThanOrEqual(0);
    // total-entries field (LE u16) at EOCD+10 == 2.
    expect(zip[found + 10] | (zip[found + 11] << 8)).toBe(2);
    // Determinism: a second identical build is byte-for-byte equal.
    expect(Array.from(buildZip(entries))).toEqual(Array.from(zip));
  });

  test("empty archive is a bare EOCD", () => {
    const zip = buildZip([]);
    expect(Array.from(zip.slice(0, 4))).toEqual([0x50, 0x4b, 0x05, 0x06]);
    expect(zip.length).toBe(22);
  });
});
```

- [ ] **Step 2: Run to verify it fails**

Run: `npx jest zipStore -t "known vector" ` (or `npx jest __tests__/zipStore.test.ts`)
Expected: FAIL — module `../utils/zipStore` not found.

- [ ] **Step 3: Implement `utils/zipStore.ts`**

```ts
// utils/zipStore.ts
// Zero-dependency "stored" (compression method 0) ZIP writer, plus the UTF-8
// and base64 primitives it needs. Pure and deterministic: the only otherwise-
// variable header fields (DOS mod time/date) are fixed to zero, so identical
// entries produce byte-identical archives. Hermes has no guaranteed TextEncoder
// or btoa, so both are hand-rolled here.
// Spec: docs/superpowers/specs/2026-08-07-accountant-package-design.md

let CRC_TABLE: Uint32Array | null = null;
function crcTable(): Uint32Array {
  if (CRC_TABLE) return CRC_TABLE;
  const t = new Uint32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    t[n] = c >>> 0;
  }
  CRC_TABLE = t;
  return t;
}

export function crc32(bytes: Uint8Array): number {
  const t = crcTable();
  let crc = 0xffffffff;
  for (let i = 0; i < bytes.length; i++) crc = t[(crc ^ bytes[i]) & 0xff] ^ (crc >>> 8);
  return (crc ^ 0xffffffff) >>> 0;
}

export function utf8Encode(s: string): Uint8Array {
  const out: number[] = [];
  for (let i = 0; i < s.length; i++) {
    let code = s.charCodeAt(i);
    if (code >= 0xd800 && code <= 0xdbff && i + 1 < s.length) {
      const next = s.charCodeAt(i + 1);
      if (next >= 0xdc00 && next <= 0xdfff) {
        code = 0x10000 + ((code - 0xd800) << 10) + (next - 0xdc00);
        i++;
      }
    }
    if (code < 0x80) out.push(code);
    else if (code < 0x800) out.push(0xc0 | (code >> 6), 0x80 | (code & 0x3f));
    else if (code < 0x10000)
      out.push(0xe0 | (code >> 12), 0x80 | ((code >> 6) & 0x3f), 0x80 | (code & 0x3f));
    else
      out.push(
        0xf0 | (code >> 18),
        0x80 | ((code >> 12) & 0x3f),
        0x80 | ((code >> 6) & 0x3f),
        0x80 | (code & 0x3f),
      );
  }
  return Uint8Array.from(out);
}

const B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
export function base64Encode(bytes: Uint8Array): string {
  let out = "";
  let i = 0;
  for (; i + 2 < bytes.length; i += 3) {
    const n = (bytes[i] << 16) | (bytes[i + 1] << 8) | bytes[i + 2];
    out += B64[(n >> 18) & 63] + B64[(n >> 12) & 63] + B64[(n >> 6) & 63] + B64[n & 63];
  }
  const rem = bytes.length - i;
  if (rem === 1) {
    const n = bytes[i] << 16;
    out += B64[(n >> 18) & 63] + B64[(n >> 12) & 63] + "==";
  } else if (rem === 2) {
    const n = (bytes[i] << 16) | (bytes[i + 1] << 8);
    out += B64[(n >> 18) & 63] + B64[(n >> 12) & 63] + B64[(n >> 6) & 63] + "=";
  }
  return out;
}

export type ZipEntry = { name: string; bytes: Uint8Array };

const u16 = (n: number): number[] => [n & 0xff, (n >>> 8) & 0xff];
const u32 = (n: number): number[] => [n & 0xff, (n >>> 8) & 0xff, (n >>> 16) & 0xff, (n >>> 24) & 0xff];

/**
 * A stored (uncompressed) ZIP. Flag bit 11 (0x0800) marks filenames UTF-8.
 * mod time/date are zeroed for determinism; compressed size == uncompressed size.
 */
export function buildZip(entries: ZipEntry[]): Uint8Array {
  const out: number[] = [];
  const records: { nameBytes: Uint8Array; crc: number; size: number; offset: number }[] = [];

  for (const e of entries) {
    const nameBytes = utf8Encode(e.name);
    const crc = crc32(e.bytes);
    const size = e.bytes.length;
    const offset = out.length;
    out.push(
      ...u32(0x04034b50), ...u16(20), ...u16(0x0800), ...u16(0),
      ...u16(0), ...u16(0), ...u32(crc), ...u32(size), ...u32(size),
      ...u16(nameBytes.length), ...u16(0),
    );
    for (let i = 0; i < nameBytes.length; i++) out.push(nameBytes[i]);
    for (let i = 0; i < e.bytes.length; i++) out.push(e.bytes[i]);
    records.push({ nameBytes, crc, size, offset });
  }

  const centralStart = out.length;
  for (const r of records) {
    out.push(
      ...u32(0x02014b50), ...u16(20), ...u16(20), ...u16(0x0800), ...u16(0),
      ...u16(0), ...u16(0), ...u32(r.crc), ...u32(r.size), ...u32(r.size),
      ...u16(r.nameBytes.length), ...u16(0), ...u16(0), ...u16(0), ...u16(0),
      ...u32(0), ...u32(r.offset),
    );
    for (let i = 0; i < r.nameBytes.length; i++) out.push(r.nameBytes[i]);
  }
  const centralSize = out.length - centralStart;

  out.push(
    ...u32(0x06054b50), ...u16(0), ...u16(0),
    ...u16(records.length), ...u16(records.length),
    ...u32(centralSize), ...u32(centralStart), ...u16(0),
  );

  return Uint8Array.from(out);
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `npx jest __tests__/zipStore.test.ts`
Expected: PASS (all cases).

- [ ] **Step 5: Gate + commit (when owner approves this phase)**

```bash
npm run typecheck && npm test && npm run lint
git add utils/zipStore.ts __tests__/zipStore.test.ts
git commit -m "feat: add zero-dependency stored-ZIP writer for accountant package"
```

---

### Task 2: `utils/accountingPackage.ts` — per-file CSV builders

**Files:**
- Create: `utils/accountingPackage.ts`
- Test: `__tests__/accountingPackage.builders.test.ts`

**Interfaces:**
- Consumes: `escapeCsvField`, `toCsv` (csvExport); `effectivePayments`, `paymentsInRange`, `toAmount`, `amountPaid`, `balanceDue`, `isFullyPaid`, `isPartlyPaid` (invoicePayments); `EXPENSE_CATEGORIES`, `isInRange` (moneyUtils); types from `types/models`.
- Produces (all pure, all `(records, start: Date, end: Date) => string` unless noted):
  - `recoverIssueDate(id: string): string | null` — "YYYY-MM-DD" from the id ms timestamp, or `null` when unrecoverable.
  - `paymentSource(id: string): "device" | "stripe" | "legacy"`
  - `buildInvoicesCsv(invoices, start, end): string`
  - `buildLineItemsCsv(invoices, start, end): string`
  - `buildActivePaymentsCsv(invoices, start, end): string`
  - `buildPaymentActivityCsv(invoices, start, end): string`
  - `buildExpensesCsv2(expenses, start, end, jobNameById: Record<string,string>): string`
  - `buildCustomersCsv(customers: Customer[]): string`
  - `buildCategoryMappingCsv(): string`

**Notes for the implementer:**
- Invoice date-in-range is judged by `recoverIssueDate(id)` when present, else the invoice is still included but flagged later (Task 3). For range filtering in `buildInvoicesCsv`, include an invoice if its recovered issue date is in range OR it has any in-range payment (so partially-paid invoices whose issue date precedes the range still appear). Sort by recovered issue date (nulls last), tie-break by `number` then `id` (code-unit).
- `buildActivePaymentsCsv` mirrors the existing `buildIncomeCsv` exactly (non-voided, legacy method blank) — reuse that shape.
- `buildExpensesCsv2` adds a `Job` column: `jobNameById[expense.jobId]` or `""`.

- [ ] **Step 1: Write the failing tests** (representative; add boundary/escaping cases mirroring `csvExport.test.ts`)

```ts
// __tests__/accountingPackage.builders.test.ts
import {
  recoverIssueDate, paymentSource, buildInvoicesCsv, buildLineItemsCsv,
  buildActivePaymentsCsv, buildPaymentActivityCsv, buildExpensesCsv2,
  buildCustomersCsv, buildCategoryMappingCsv,
} from "../utils/accountingPackage";
import { collectedInRange } from "../utils/invoicePayments";
import type { Invoice, Expense, Customer } from "../types/models";

const JAN1 = new Date(2026, 0, 1);
const DEC31 = new Date(2026, 11, 31, 23, 59, 59);
// 2026-03-01T00:00:00Z in ms — a recoverable timestamp id.
const TS = Date.UTC(2026, 2, 1);

const inv = (o: Partial<Invoice> = {}): Invoice => ({
  id: `inv${TS}`, customer: "Jane Smith", number: "INV-0001", amount: 1000,
  due: "2026-06-01", email: "", phone: "", desc: "Maintenance", paid: false, ...o,
});

test("recoverIssueDate returns the id date, or null when unrecoverable", () => {
  expect(recoverIssueDate(`inv${TS}`)).toBe("2026-03-01");
  expect(recoverIssueDate("1-seed")).toBeNull();
  expect(recoverIssueDate("stripe_cs_test")).toBeNull();
});

test("paymentSource classifies by id namespace", () => {
  expect(paymentSource("p123_1")).toBe("device");
  expect(paymentSource("stripe_cs_1")).toBe("stripe");
  expect(paymentSource("legacy_inv1")).toBe("legacy");
});

test("invoices.csv header and a recoverable-date row", () => {
  const csv = buildInvoicesCsv([inv({ paid: true, paidAt: "2026-03-05",
    payments: [{ id: "p1", amount: 1000, date: "2026-03-05", method: "cash" }] })], JAN1, DEC31);
  const lines = csv.trimEnd().split("\r\n");
  expect(lines[0]).toBe(
    "Invoice #,Issue Date,Customer,Email,Phone,Description,Amount,Amount Paid,Balance Due,Status,Due Date,Paid At,Job ID");
  expect(lines[1]).toContain("INV-0001,2026-03-01,Jane Smith");
  expect(lines[1]).toContain(",1000.00,1000.00,0.00,paid,");
});

test("active-payments total equals collectedInRange", () => {
  const invoices = [inv({ payments: [
    { id: "p1", amount: 400, date: "2026-03-01", method: "cash" },
    { id: "p2", amount: 600, date: "2026-07-15", method: "stripe" },
  ]})];
  const lines = buildActivePaymentsCsv(invoices, JAN1, DEC31).trimEnd().split("\r\n").slice(1);
  const sum = lines.reduce((a, l) => a + Number(l.split(",").pop()), 0);
  expect(sum).toBeCloseTo(collectedInRange(invoices, JAN1, DEC31), 2);
});

test("payment-activity includes voided rows with Voided=Yes and Source", () => {
  const csv = buildPaymentActivityCsv([inv({ payments: [
    { id: "stripe_cs_1", amount: 600, date: "2026-04-15", method: "stripe", voidedAt: "2026-04-16" },
  ]})], JAN1, DEC31);
  const row = csv.trimEnd().split("\r\n")[1];
  expect(row).toContain(",Yes,2026-04-16,stripe");
});

test("expenses.csv adds a Job column resolved by id", () => {
  const e: Expense = { id: "e1", createdAt: "2026-03-01", description: "Lumber",
    amount: 250.5, category: "materials", date: "2026-03-01", notes: "",
    receiptUri: "file:///r.jpg", jobId: "j1" };
  const row = buildExpensesCsv2([e], JAN1, DEC31, { j1: "Smith Deck" }).trimEnd().split("\r\n")[1];
  expect(row).toBe("2026-03-01,Lumber,Materials,250.50,,Smith Deck,Yes");
});

test("customers.csv emits contact columns", () => {
  const c: Customer = { id: "c1", name: "Jane Smith", email: "j@x.com",
    phone: "555", address: "1 St", notes: "" };
  const row = buildCustomersCsv([c]).trimEnd().split("\r\n")[1];
  expect(row).toBe("Jane Smith,j@x.com,555,1 St,,,");
});

test("category-mapping.csv lists every category id and label", () => {
  const csv = buildCategoryMappingCsv();
  expect(csv).toContain("materials,Materials");
  expect(csv).toContain("other,Other");
});

test("line-items.csv emits one row per line item keyed by invoice #", () => {
  const csv = buildLineItemsCsv([inv({ paid: true,
    payments: [{ id: "p1", amount: 1000, date: "2026-03-02", method: "cash" }],
    lineItems: [{ description: "Labor", amount: 600, category: "labor" }] })], JAN1, DEC31);
  expect(csv.trimEnd().split("\r\n")[1]).toBe("INV-0001,Labor,labor,600.00");
});
```

- [ ] **Step 2: Run to verify it fails** — Run: `npx jest accountingPackage.builders` → FAIL (module not found).

- [ ] **Step 3: Implement `utils/accountingPackage.ts` (builders section)**

```ts
// utils/accountingPackage.ts
// Pure builders for the accountant-package ZIP. No I/O, no Settings, no secrets.
// Spec: docs/superpowers/specs/2026-08-07-accountant-package-design.md
import type { Customer, Expense, Invoice, Trip } from "../types/models";
import { escapeCsvField, toCsv } from "./csvExport";
import {
  amountPaid, balanceDue, effectivePayments, isFullyPaid, isPartlyPaid,
  paymentsInRange, toAmount,
} from "./invoicePayments";
import { EXPENSE_CATEGORIES, isInRange } from "./moneyUtils";

/** Recover the "YYYY-MM-DD" issue date from an invoice id's ms timestamp, or
 *  null when the id is not a plausible timestamp (sample/legacy rows). Unlike
 *  pdfTemplates.invoiceIssueDate this NEVER falls back to the wall clock — an
 *  accounting export must be deterministic, so unrecoverable stays blank. */
export function recoverIssueDate(id: string): string | null {
  const raw = id.replace(/^inv/, "");
  if (!/^\d+$/.test(raw)) return null;
  const ms = Number(raw);
  const d = new Date(ms);
  const y = d.getUTCFullYear();
  if (!(y >= 2000 && y <= 2100)) return null;
  const pad = (n: number) => String(n).padStart(2, "0");
  return `${y}-${pad(d.getUTCMonth() + 1)}-${pad(d.getUTCDate())}`;
}

export function paymentSource(id: string): "device" | "stripe" | "legacy" {
  if (id.startsWith("stripe_")) return "stripe";
  if (id.startsWith("legacy_")) return "legacy";
  return "device";
}

const byCode = (a: string, b: string) => (a === b ? 0 : a < b ? -1 : 1);
const money = (v: unknown) => toAmount(v).toFixed(2);

function invoiceStatus(i: Invoice): string {
  if (isFullyPaid(i)) return "paid";
  if (isPartlyPaid(i)) return "partly_paid";
  return "unpaid";
}

const INVOICES_HEADER = ["Invoice #", "Issue Date", "Customer", "Email", "Phone",
  "Description", "Amount", "Amount Paid", "Balance Due", "Status", "Due Date", "Paid At", "Job ID"];

export function buildInvoicesCsv(invoices: Invoice[], start: Date, end: Date): string {
  const rows = invoices
    .map((i) => ({ i, issue: recoverIssueDate(i.id) }))
    .filter(({ i, issue }) =>
      (issue !== null && isInRange(issue, start, end)) ||
      paymentsInRange(i, start, end).some((p) => !p.voidedAt))
    .sort((a, b) => {
      if (a.issue === b.issue) return byCode(a.i.number || "", b.i.number || "") || byCode(a.i.id, b.i.id);
      if (a.issue === null) return 1;
      if (b.issue === null) return -1;
      return byCode(a.issue, b.issue);
    })
    .map(({ i, issue }) => [
      i.number || "", issue || "", i.customer || "", i.email || "", i.phone || "",
      i.desc || "", money(i.amount), money(amountPaid(i)), money(balanceDue(i)),
      invoiceStatus(i), i.due || "", i.paidAt || "", i.jobId || "",
    ]);
  return toCsv(INVOICES_HEADER, rows);
}

const LINE_ITEMS_HEADER = ["Invoice #", "Description", "Category", "Amount"];
export function buildLineItemsCsv(invoices: Invoice[], start: Date, end: Date): string {
  const rows: string[][] = [];
  const inScope = invoices
    .map((i) => ({ i, issue: recoverIssueDate(i.id) }))
    .filter(({ i, issue }) =>
      (issue !== null && isInRange(issue, start, end)) ||
      paymentsInRange(i, start, end).some((p) => !p.voidedAt))
    .sort((a, b) => byCode(a.i.number || "", b.i.number || "") || byCode(a.i.id, b.i.id));
  for (const { i } of inScope) {
    for (const li of i.lineItems || []) {
      rows.push([i.number || "", li.description || "", li.category, money(li.amount)]);
    }
  }
  return toCsv(LINE_ITEMS_HEADER, rows);
}

const ACTIVE_PAY_HEADER = ["Date", "Customer", "Invoice #", "Invoice Description", "Method", "Note", "Amount"];
export function buildActivePaymentsCsv(invoices: Invoice[], start: Date, end: Date): string {
  const rows: { date: string; fields: string[] }[] = [];
  for (const invoice of invoices) {
    for (const p of paymentsInRange(invoice, start, end)) {
      if (p.voidedAt) continue;
      const legacy = p.id.startsWith("legacy_");
      rows.push({ date: p.date, fields: [
        p.date, invoice.customer || "", invoice.number || "", invoice.desc || "",
        legacy ? "" : p.method, p.note || "", money(p.amount),
      ]});
    }
  }
  rows.sort((a, b) => byCode(a.date, b.date));
  return toCsv(ACTIVE_PAY_HEADER, rows.map((r) => r.fields));
}

const ACTIVITY_HEADER = ["Date", "Customer", "Invoice #", "Method", "Note", "Amount", "Voided", "Voided At", "Source"];
export function buildPaymentActivityCsv(invoices: Invoice[], start: Date, end: Date): string {
  const rows: { date: string; id: string; fields: string[] }[] = [];
  for (const invoice of invoices) {
    for (const p of paymentsInRange(invoice, start, end)) {
      const legacy = p.id.startsWith("legacy_");
      rows.push({ date: p.date, id: p.id, fields: [
        p.date, invoice.customer || "", invoice.number || "",
        legacy ? "" : p.method, p.note || "", money(p.amount),
        p.voidedAt ? "Yes" : "No", p.voidedAt || "", paymentSource(p.id),
      ]});
    }
  }
  rows.sort((a, b) => byCode(a.date, b.date) || byCode(a.id, b.id));
  return toCsv(ACTIVITY_HEADER, rows.map((r) => r.fields));
}

const EXPENSES2_HEADER = ["Date", "Description", "Category", "Amount", "Notes", "Job", "Has Receipt"];
export function buildExpensesCsv2(
  expenses: Expense[], start: Date, end: Date, jobNameById: Record<string, string>,
): string {
  const rows = expenses
    .filter((e) => isInRange(e.date, start, end))
    .sort((a, b) => byCode(a.date, b.date) || byCode(a.id, b.id))
    .map((e) => {
      const category = EXPENSE_CATEGORIES.find((c) => c.id === e.category) || EXPENSE_CATEGORIES[7];
      const job = e.jobId ? jobNameById[e.jobId] || "" : "";
      return [e.date, e.description || "", category.label, money(e.amount), e.notes || "", job, e.receiptUri ? "Yes" : "No"];
    });
  return toCsv(EXPENSES2_HEADER, rows);
}

const CUSTOMERS_HEADER = ["Name", "Email", "Phone", "Address", "Notes", "Created", "Archived"];
export function buildCustomersCsv(customers: Customer[]): string {
  const rows = [...customers]
    .sort((a, b) => byCode(a.name || "", b.name || "") || byCode(a.id, b.id))
    .map((c) => [c.name || "", c.email || "", c.phone || "", c.address || "", c.notes || "", c.createdAt || "", c.archivedAt || ""]);
  return toCsv(CUSTOMERS_HEADER, rows);
}

const CATEGORY_HEADER = ["Category ID", "Label"];
export function buildCategoryMappingCsv(): string {
  return toCsv(CATEGORY_HEADER, EXPENSE_CATEGORIES.map((c) => [c.id, c.label]));
}
```

Note: `escapeCsvField` is imported for symmetry/reuse but every field already flows through `toCsv` (which escapes). Remove the unused import if lint flags it, or use it — do not leave an unused import (lint is `--max-warnings=0`).

- [ ] **Step 4: Run to verify it passes** — Run: `npx jest accountingPackage.builders` → PASS. Then `npm run lint` to catch unused imports early.

- [ ] **Step 5: Gate + commit (owner-approved)**

```bash
npm run typecheck && npm test && npm run lint
git add utils/accountingPackage.ts __tests__/accountingPackage.builders.test.ts
git commit -m "feat: add per-file CSV builders for accountant package"
```

---

### Task 3: Warnings builder

**Files:**
- Modify: `utils/accountingPackage.ts` (append)
- Test: `__tests__/accountingPackage.warnings.test.ts`

**Interfaces:**
- Consumes: builders from Task 2; `overpaidAmount`, `effectivePayments` (invoicePayments).
- Produces:
  - `type ExportWarning = { code: string; severity: "warn" | "info"; subject: string; detail: string }`
  - `collectWarnings(input: PackageInput, start: Date, end: Date): ExportWarning[]`
  - `buildWarningsCsv(warnings: ExportWarning[]): string`
  - `type PackageInput = { invoices: Invoice[]; expenses: Expense[]; trips: Trip[]; customers: Customer[]; jobNameById: Record<string,string> }`

**Warning codes (exact):** `missing_issue_date` (warn), `missing_line_items` (info), `legacy_invoice_no_ledger` (info), `unknown_expense_category` (warn), `overpayment_present` (warn), `voided_payments_present` (info), `mileage_is_device_local` (info), `no_records_in_range` (info). Only emit a code when its condition is actually present in-range. `no_records_in_range` fires only when every dataset produced zero rows.

- [ ] **Step 1: Write the failing tests**

```ts
// __tests__/accountingPackage.warnings.test.ts
import { collectWarnings, buildWarningsCsv } from "../utils/accountingPackage";
import type { Invoice, Expense } from "../types/models";

const JAN1 = new Date(2026, 0, 1), DEC31 = new Date(2026, 11, 31, 23, 59, 59);
const TS = Date.UTC(2026, 2, 1);
const base = { expenses: [] as Expense[], trips: [], customers: [], jobNameById: {} };

test("missing_issue_date fires for a non-timestamp id that has an in-range payment", () => {
  const invoices: Invoice[] = [{ id: "1-seed", customer: "A", number: "INV-1", amount: 100,
    due: "2026-03-01", email: "", phone: "", desc: "", paid: true, paidAt: "2026-03-02" }];
  const codes = collectWarnings({ ...base, invoices }, JAN1, DEC31).map((w) => w.code);
  expect(codes).toContain("missing_issue_date");
});

test("unknown_expense_category fires", () => {
  const expenses: Expense[] = [{ id: "e1", createdAt: "2026-03-01", description: "x",
    amount: 1, category: "bogus" as Expense["category"], date: "2026-03-01", notes: "", receiptUri: null }];
  const codes = collectWarnings({ ...base, invoices: [], expenses }, JAN1, DEC31).map((w) => w.code);
  expect(codes).toContain("unknown_expense_category");
});

test("no_records_in_range fires only when everything is empty", () => {
  const codes = collectWarnings({ ...base, invoices: [] }, JAN1, DEC31).map((w) => w.code);
  expect(codes).toEqual(["no_records_in_range"]);
});

test("warnings CSV has the fixed header", () => {
  expect(buildWarningsCsv([]).split("\r\n")[0]).toBe("Code,Severity,Subject,Detail");
});
```

- [ ] **Step 2: Run to verify it fails** — `npx jest accountingPackage.warnings` → FAIL.

- [ ] **Step 3: Implement (append to `utils/accountingPackage.ts`)**

```ts
import { overpaidAmount } from "./invoicePayments";

export type ExportWarning = { code: string; severity: "warn" | "info"; subject: string; detail: string };
export type PackageInput = {
  invoices: Invoice[]; expenses: Expense[]; trips: Trip[];
  customers: Customer[]; jobNameById: Record<string, string>;
};

export function collectWarnings(input: PackageInput, start: Date, end: Date): ExportWarning[] {
  const w: ExportWarning[] = [];
  const push = (code: string, severity: "warn" | "info", subject: string, detail: string) =>
    w.push({ code, severity, subject, detail });

  const inScopeInvoices = input.invoices.filter((i) => {
    const issue = recoverIssueDate(i.id);
    return (issue !== null && isInRange(issue, start, end)) ||
      paymentsInRange(i, start, end).some((p) => !p.voidedAt);
  });

  const activeRows = buildActivePaymentsCsv(input.invoices, start, end).trim().split("\r\n").length - 1;
  const expenseRows = input.expenses.filter((e) => isInRange(e.date, start, end)).length;
  const tripRows = input.trips.filter((t) => isInRange(t.date, start, end)).length;

  for (const i of inScopeInvoices) {
    if (recoverIssueDate(i.id) === null)
      push("missing_issue_date", "warn", i.number || i.id, "Issue date could not be recovered; left blank.");
    if (!i.lineItems || i.lineItems.length === 0)
      push("missing_line_items", "info", i.number || i.id, "Invoice has no itemised breakdown.");
    if ((!i.payments || i.payments.length === 0) && i.paid)
      push("legacy_invoice_no_ledger", "info", i.number || i.id, "Paid before payment history existed; derived from the paid flag.");
    if (overpaidAmount(i) > 0)
      push("overpayment_present", "warn", i.number || i.id, `Overpaid by ${overpaidAmount(i).toFixed(2)}.`);
    if (paymentsInRange(i, start, end).some((p) => p.voidedAt))
      push("voided_payments_present", "info", i.number || i.id, "Contains voided payments (see payment-activity.csv).");
  }

  for (const e of input.expenses) {
    if (isInRange(e.date, start, end) && !EXPENSE_CATEGORIES.some((c) => c.id === e.category))
      push("unknown_expense_category", "warn", e.description || e.id, `Unknown category "${e.category}"; mapped to Other.`);
  }

  if (tripRows > 0)
    push("mileage_is_device_local", "info", "mileage.csv", "Trips are stored on this device only; another device may hold others.");

  if (activeRows === 0 && expenseRows === 0 && tripRows === 0 && inScopeInvoices.length === 0 && input.customers.length === 0)
    push("no_records_in_range", "info", "range", "No records fell in the selected date range.");

  return w;
}

const WARNINGS_HEADER = ["Code", "Severity", "Subject", "Detail"];
export function buildWarningsCsv(warnings: ExportWarning[]): string {
  return toCsv(WARNINGS_HEADER, warnings.map((x) => [x.code, x.severity, x.subject, x.detail]));
}
```

- [ ] **Step 4: Run to verify it passes** — `npx jest accountingPackage.warnings` → PASS.

- [ ] **Step 5: Gate + commit (owner-approved)**

```bash
npm run typecheck && npm test && npm run lint
git add utils/accountingPackage.ts __tests__/accountingPackage.warnings.test.ts
git commit -m "feat: add export-warnings builder for accountant package"
```

---

### Task 4: `summary.json` builder + control equations

**Files:**
- Modify: `utils/accountingPackage.ts` (append)
- Test: `__tests__/accountingPackage.summary.test.ts`

**Interfaces:**
- Consumes: `collectedInRange` (invoicePayments); builders + `collectWarnings` from Tasks 2–3.
- Produces:
  - `type PackageSummary = { range_start: string; range_end: string; cash_collected: number; voided_amount: number; expenses_total: number; net_cash: number; net_cash_basis: string; invoices_count: number; customers_count: number; mileage_trips_count: number; mileage_miles_total: number; warnings_count: number }`
  - `buildSummary(input: PackageInput, start: Date, end: Date): PackageSummary`
  - `buildSummaryJson(summary: PackageSummary): string` — `JSON.stringify(summary, null, 2)` (stable key order = declaration order; **no BOM**, no wall-clock).
  - `ymdLocalRange(start: Date, end: Date): { start: string; end: string }` helper for `range_start`/`range_end`.

**Control equations (tested):** `cash_collected === collectedInRange(invoices, start, end)`; `net_cash === cash_collected − expenses_total`; voided excluded from `cash_collected` but summed into `voided_amount`.

- [ ] **Step 1: Write the failing tests**

```ts
// __tests__/accountingPackage.summary.test.ts
import { buildSummary, buildSummaryJson } from "../utils/accountingPackage";
import { collectedInRange } from "../utils/invoicePayments";
import type { Invoice, Expense } from "../types/models";

const JAN1 = new Date(2026, 0, 1), DEC31 = new Date(2026, 11, 31, 23, 59, 59);
const inv = (o: Partial<Invoice> = {}): Invoice => ({ id: "inv1", customer: "A", number: "INV-1",
  amount: 1000, due: "2026-06-01", email: "", phone: "", desc: "", paid: false, ...o });

test("cash_collected equals collectedInRange and net_cash subtracts expenses", () => {
  const invoices = [inv({ payments: [
    { id: "p1", amount: 400, date: "2026-03-01", method: "cash" },
    { id: "p2", amount: 100, date: "2026-04-01", method: "card", voidedAt: "2026-04-02" },
  ]})];
  const expenses: Expense[] = [{ id: "e1", createdAt: "2026-03-01", description: "x", amount: 150,
    category: "materials", date: "2026-03-01", notes: "", receiptUri: null }];
  const s = buildSummary({ invoices, expenses, trips: [], customers: [], jobNameById: {} }, JAN1, DEC31);
  expect(s.cash_collected).toBeCloseTo(collectedInRange(invoices, JAN1, DEC31), 2);
  expect(s.cash_collected).toBeCloseTo(400, 2);
  expect(s.voided_amount).toBeCloseTo(100, 2);
  expect(s.net_cash).toBeCloseTo(250, 2);
});

test("summary JSON is pretty-printed and BOM-free and deterministic", () => {
  const s = buildSummary({ invoices: [], expenses: [], trips: [], customers: [], jobNameById: {} }, JAN1, DEC31);
  const json = buildSummaryJson(s);
  expect(json.charCodeAt(0)).not.toBe(0xfeff);
  expect(JSON.parse(json).range_start).toBe("2026-01-01");
  expect(buildSummaryJson(s)).toBe(json);
});
```

- [ ] **Step 2: Run to verify it fails** — `npx jest accountingPackage.summary` → FAIL.

- [ ] **Step 3: Implement (append)**

```ts
import { collectedInRange } from "./invoicePayments";

function ymdLocal(d: Date): string {
  const pad = (n: number) => String(n).padStart(2, "0");
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
}
export function ymdLocalRange(start: Date, end: Date) {
  return { start: ymdLocal(start), end: ymdLocal(end) };
}

export type PackageSummary = {
  range_start: string; range_end: string;
  cash_collected: number; voided_amount: number; expenses_total: number;
  net_cash: number; net_cash_basis: string;
  invoices_count: number; customers_count: number;
  mileage_trips_count: number; mileage_miles_total: number; warnings_count: number;
};

export function buildSummary(input: PackageInput, start: Date, end: Date): PackageSummary {
  const cash = collectedInRange(input.invoices, start, end);
  let voided = 0;
  for (const i of input.invoices)
    for (const p of paymentsInRange(i, start, end)) if (p.voidedAt) voided += toAmount(p.amount);
  const expensesTotal = input.expenses
    .filter((e) => isInRange(e.date, start, end))
    .reduce((s, e) => s + toAmount(e.amount), 0);
  const inScopeInvoices = input.invoices.filter((i) => {
    const issue = recoverIssueDate(i.id);
    return (issue !== null && isInRange(issue, start, end)) ||
      paymentsInRange(i, start, end).some((p) => !p.voidedAt);
  });
  const trips = input.trips.filter((t) => isInRange(t.date, start, end));
  const r = ymdLocalRange(start, end);
  return {
    range_start: r.start, range_end: r.end,
    cash_collected: round2(cash), voided_amount: round2(voided), expenses_total: round2(expensesTotal),
    net_cash: round2(cash - expensesTotal), net_cash_basis: "cash basis; before owner labor",
    invoices_count: inScopeInvoices.length, customers_count: input.customers.length,
    mileage_trips_count: trips.length, mileage_miles_total: round2(trips.reduce((s, t) => s + toAmount(t.miles), 0)),
    warnings_count: collectWarnings(input, start, end).length,
  };
}
const round2 = (n: number) => Math.round(n * 100) / 100;

export function buildSummaryJson(summary: PackageSummary): string {
  return JSON.stringify(summary, null, 2);
}
```

- [ ] **Step 4: Run to verify it passes** — `npx jest accountingPackage.summary` → PASS.

- [ ] **Step 5: Gate + commit (owner-approved)**

```bash
npm run typecheck && npm test && npm run lint
git add utils/accountingPackage.ts __tests__/accountingPackage.summary.test.ts
git commit -m "feat: add summary.json control totals for accountant package"
```

---

### Task 5: `README.txt` builder

**Files:**
- Modify: `utils/accountingPackage.ts` (append)
- Test: `__tests__/accountingPackage.readme.test.ts`

**Interfaces:**
- Produces: `buildReadme(summary: PackageSummary): string` — plain UTF-8 text (no BOM), deterministic, lists every file and the cash-basis / device-local / no-invented-data conventions. May interpolate `summary.range_start`/`range_end` (data, not clock).

- [ ] **Step 1: Write the failing test**

```ts
// __tests__/accountingPackage.readme.test.ts
import { buildReadme, buildSummary } from "../utils/accountingPackage";
const s = buildSummary({ invoices: [], expenses: [], trips: [], customers: [], jobNameById: {} },
  new Date(2026, 0, 1), new Date(2026, 11, 31, 23, 59, 59));

test("README names the control files and states the cash-basis convention", () => {
  const txt = buildReadme(s);
  expect(txt).toContain("active-payments.csv");
  expect(txt).toContain("payment-activity.csv");
  expect(txt).toContain("cash basis");
  expect(txt).toContain("2026-01-01");
  expect(buildReadme(s)).toBe(txt); // deterministic
});
```

- [ ] **Step 2: Run to verify it fails** — `npx jest accountingPackage.readme` → FAIL.

- [ ] **Step 3: Implement (append)** — a template literal listing each file with a one-line description, the cash-basis note, the "no inferred values" note, and the mileage/receipt device-local caveats, interpolating `${summary.range_start}`/`${summary.range_end}`. Use `\n` line endings; no wall-clock.

```ts
export function buildReadme(summary: PackageSummary): string {
  return [
    `TradeReady accounting export`,
    `Date range: ${summary.range_start} to ${summary.range_end}`,
    ``,
    `Income is reported on a CASH BASIS: a payment appears on the date the money`,
    `was actually received, so deposits and partial payments land in the right period.`,
    ``,
    `Files:`,
    `  invoices.csv            One row per invoice (issue date, amount, paid, balance, status).`,
    `  invoice-line-items.csv  Itemised breakdown; absent for manually-created invoices.`,
    `  active-payments.csv     Money received (voided payments excluded). Cash-basis income.`,
    `  payment-activity.csv    Every payment including voided ones, with void dates.`,
    `  expenses.csv            Business expenses; Job column links to a job when set.`,
    `  mileage.csv             Logged drives (raw miles; apply your own rate).`,
    `  customers.csv           Customer contact details.`,
    `  category-mapping.csv    Expense category id -> label reference.`,
    `  export-warnings.csv     Anything the export could not fully determine.`,
    `  summary.json            Control totals for reconciliation.`,
    ``,
    `Notes:`,
    `  - No values are inferred. Unknown fields are left blank and flagged in export-warnings.csv.`,
    `  - There is no refund concept in the app; only voids are recorded.`,
    `  - Mileage and receipts are stored on the device only and may differ between devices.`,
    `  - net_cash in summary.json is cash collected minus expenses (before paying yourself).`,
    ``,
  ].join("\n");
}
```

- [ ] **Step 4: Run to verify it passes** — `npx jest accountingPackage.readme` → PASS.

- [ ] **Step 5: Gate + commit (owner-approved)**

```bash
npm run typecheck && npm test && npm run lint
git add utils/accountingPackage.ts __tests__/accountingPackage.readme.test.ts
git commit -m "feat: add README.txt builder for accountant package"
```

---

### Task 6: `buildAccountingPackage` assembler

**Files:**
- Modify: `utils/accountingPackage.ts` (append)
- Test: `__tests__/accountingPackage.assemble.test.ts`

**Interfaces:**
- Consumes: all Task 2–5 builders; `buildZip`, `utf8Encode` (zipStore).
- Produces:
  - `buildAccountingPackage(input: PackageInput, start: Date, end: Date): { filename: string; bytes: Uint8Array }`
  - `packageFilename(start: Date, end: Date, allTime: boolean): string`
- Fixed entry order (spec): invoices, invoice-line-items, active-payments, payment-activity, expenses, mileage, customers, category-mapping, export-warnings, summary.json, README.txt.
- Each **CSV** entry's bytes = `utf8Encode("\uFEFF" + csv)` (BOM). `summary.json` and `README.txt` = `utf8Encode(text)` (no BOM).
- `mileage.csv` reuses the existing `buildTripsCsv` from `utils/csvExport.ts`.

- [ ] **Step 1: Write the failing tests**

```ts
// __tests__/accountingPackage.assemble.test.ts
import { buildAccountingPackage, packageFilename } from "../utils/accountingPackage";
import type { Invoice } from "../types/models";

const JAN1 = new Date(2026, 0, 1), DEC31 = new Date(2026, 11, 31, 23, 59, 59);
const input = { invoices: [] as Invoice[], expenses: [], trips: [], customers: [], jobNameById: {} };

test("filename uses local dates, or all-time", () => {
  expect(packageFilename(JAN1, DEC31, false)).toBe("TradeReady-Accounting_2026-01-01_2026-12-31.zip");
  expect(packageFilename(JAN1, DEC31, true)).toBe("TradeReady-Accounting_all-time.zip");
});

test("assembles a deterministic non-empty zip beginning with a local file header", () => {
  const a = buildAccountingPackage(input, JAN1, DEC31);
  expect(a.filename).toContain(".zip");
  expect(Array.from(a.bytes.slice(0, 4))).toEqual([0x50, 0x4b, 0x03, 0x04]);
  const b = buildAccountingPackage(input, JAN1, DEC31);
  expect(Array.from(b.bytes)).toEqual(Array.from(a.bytes));
});
```

- [ ] **Step 2: Run to verify it fails** — `npx jest accountingPackage.assemble` → FAIL.

- [ ] **Step 3: Implement (append)**

```ts
import { buildZip, utf8Encode, type ZipEntry } from "./zipStore";
import { buildTripsCsv } from "./csvExport";

export function packageFilename(start: Date, end: Date, allTime: boolean): string {
  if (allTime) return "TradeReady-Accounting_all-time.zip";
  const r = ymdLocalRange(start, end);
  return `TradeReady-Accounting_${r.start}_${r.end}.zip`;
}

export function buildAccountingPackage(
  input: PackageInput, start: Date, end: Date,
): { filename: string; bytes: Uint8Array } {
  const summary = buildSummary(input, start, end);
  const warnings = collectWarnings(input, start, end);
  const csv = (name: string, body: string): ZipEntry => ({ name, bytes: utf8Encode("\uFEFF" + body) });
  const text = (name: string, body: string): ZipEntry => ({ name, bytes: utf8Encode(body) });

  const entries: ZipEntry[] = [
    csv("invoices.csv", buildInvoicesCsv(input.invoices, start, end)),
    csv("invoice-line-items.csv", buildLineItemsCsv(input.invoices, start, end)),
    csv("active-payments.csv", buildActivePaymentsCsv(input.invoices, start, end)),
    csv("payment-activity.csv", buildPaymentActivityCsv(input.invoices, start, end)),
    csv("expenses.csv", buildExpensesCsv2(input.expenses, start, end, input.jobNameById)),
    csv("mileage.csv", buildTripsCsv(input.trips, start, end)),
    csv("customers.csv", buildCustomersCsv(input.customers)),
    csv("category-mapping.csv", buildCategoryMappingCsv()),
    csv("export-warnings.csv", buildWarningsCsv(warnings)),
    text("summary.json", buildSummaryJson(summary)),
    text("README.txt", buildReadme(summary)),
  ];
  const allTime = start.getTime() === 0;
  return { filename: packageFilename(start, end, allTime), bytes: buildZip(entries) };
}
```

- [ ] **Step 4: Run to verify it passes** — `npx jest accountingPackage.assemble` → PASS. Optional manual check: write bytes to a `.zip` and confirm a desktop unzip tool opens it (validates CRC/offsets end-to-end).

- [ ] **Step 5: Gate + commit (owner-approved)**

```bash
npm run typecheck && npm test && npm run lint
git add utils/accountingPackage.ts __tests__/accountingPackage.assemble.test.ts
git commit -m "feat: assemble accountant-package zip from builders"
```

---

### Task 7: `shareZip` delivery tail

**Files:**
- Modify: `utils/csvExport.ts` (append `shareZip`)
- Test: `__tests__/csvExport.test.ts` (append a `describe("shareZip")`)

**Interfaces:**
- Consumes: `base64Encode` (zipStore); `expo-file-system/legacy`, `expo-sharing`.
- Produces: `shareZip(bytes: Uint8Array, filename: string): Promise<void>` — writes base64 to `${cacheDirectory}<filename>` with `EncodingType.Base64`, guards `Sharing.isAvailableAsync()`, `shareAsync({ mimeType: "application/zip", dialogTitle: filename })`; owns its alerts exactly like `shareCsv`.

- [ ] **Step 1: Write the failing tests**

```ts
// append to __tests__/csvExport.test.ts
import { shareZip } from "../utils/csvExport";

describe("shareZip", () => {
  beforeEach(() => { jest.clearAllMocks(); jest.spyOn(Alert, "alert").mockImplementation(() => {}); });

  test("writes base64 zip to cache and shares with application/zip", async () => {
    await shareZip(Uint8Array.from([0x50, 0x4b, 0x05, 0x06]), "TradeReady-Accounting_all-time.zip");
    expect(FileSystem.writeAsStringAsync).toHaveBeenCalledWith(
      "file:///mock/cache/TradeReady-Accounting_all-time.zip",
      expect.any(String),
      expect.objectContaining({ encoding: FileSystem.EncodingType.Base64 }),
    );
    expect(Sharing.shareAsync).toHaveBeenCalledWith(
      "file:///mock/cache/TradeReady-Accounting_all-time.zip",
      expect.objectContaining({ mimeType: "application/zip" }),
    );
  });

  test("alerts and skips write when sharing unavailable", async () => {
    (Sharing.isAvailableAsync as jest.Mock).mockResolvedValueOnce(false);
    await shareZip(Uint8Array.from([0]), "x.zip");
    expect(FileSystem.writeAsStringAsync).not.toHaveBeenCalled();
    expect(Alert.alert).toHaveBeenCalledWith("Sharing not available", "This device cannot share files.");
  });
});
```

Confirm `jest.setup.js` mocks `FileSystem.EncodingType.Base64` — if not, add it in this task.

- [ ] **Step 2: Run to verify it fails** — `npx jest csvExport -t shareZip` → FAIL.

- [ ] **Step 3: Implement (append to `utils/csvExport.ts`)**

```ts
import { base64Encode } from "./zipStore";

/** Write a ZIP (as base64) to the cache directory and open the share sheet.
 *  Same alert/return contract as shareCsv — callers never branch. */
export async function shareZip(bytes: Uint8Array, filename: string): Promise<void> {
  try {
    const available = await Sharing.isAvailableAsync();
    if (!available) {
      Alert.alert("Sharing not available", "This device cannot share files.");
      return;
    }
    const uri = `${FileSystem.cacheDirectory}${filename}`;
    await FileSystem.writeAsStringAsync(uri, base64Encode(bytes), {
      encoding: FileSystem.EncodingType.Base64,
    });
    await Sharing.shareAsync(uri, { mimeType: "application/zip", dialogTitle: filename });
  } catch {
    Alert.alert("Export error", "Could not create the export file. Please try again.");
  }
}
```

- [ ] **Step 4: Run to verify it passes** — `npx jest csvExport` → PASS.

- [ ] **Step 5: Gate + commit (owner-approved)**

```bash
npm run typecheck && npm test && npm run lint
git add utils/csvExport.ts __tests__/csvExport.test.ts jest.setup.js
git commit -m "feat: add shareZip delivery tail for accountant package"
```

---

### Task 8: `ExportDataScreen` wiring

**Files:**
- Modify: `screens/ExportDataScreen.tsx`
- (Optional) Test: none required — repo convention is util-level coverage; the builders and tail are already tested.

**Interfaces:**
- Consumes: `buildAccountingPackage` (accountingPackage), `shareZip` (csvExport), `loadCustomers` (`utils/storage`), existing `loadInvoices`/`loadExpenses`/`loadTrips`, existing `Job` loader for `jobNameById`.

- [ ] **Step 1: Load customers + a jobId→name map**

Add `loadCustomers` and the jobs loader to the `useFocusEffect` block; build `jobNameById` from loaded jobs (`{ [job.id]: job.title }` or `job.customerName` — use the job title). Store `customers` and `jobNameById` in state.

- [ ] **Step 2: Add the accountant-package action**

Above the three dataset cards, add a primary `Card` + `Button` labeled **"Accountant package (.zip)"** with hint "Everything your accountant needs, in one file". Its `onPress`:

```ts
function handlePackage() {
  if (choice === "custom" && startOfDay(customStart) > endOfDay(customEnd)) {
    Alert.alert("Check your dates", "The start date is after the end date.");
    return;
  }
  const pkg = buildAccountingPackage(
    { invoices, expenses, trips, customers, jobNameById },
    range.start, range.end,
  );
  shareZip(pkg.bytes, pkg.filename);
}
```

- [ ] **Step 3: Verify in the preview / device** — build is JS-only; confirm the screen renders and the share sheet opens a `.zip`. (Owner device-smoke in Task 10.)

- [ ] **Step 4: Gate + commit (owner-approved)**

```bash
npm run typecheck && npm test && npm run lint
git add screens/ExportDataScreen.tsx
git commit -m "feat: add accountant-package action to ExportDataScreen"
```

---

### Task 9: Docs sweep

**Files:**
- Modify: `README.md`, `ARCHITECTURE.md`, `docs/superpowers/specs/2026-08-07-accountant-package-design.md` (status → shipped-pending-smoke), `docs/post-launch-feature-roadmap.md` (Phase 14 STATUS block).

- [ ] **Step 1:** Add the accountant package to the feature list in `README.md` and the export/util map in `ARCHITECTURE.md` (mention `utils/zipStore.ts` + `utils/accountingPackage.ts`, receipts deferred).
- [ ] **Step 2:** Mark the spec status and the roadmap Phase 14 row (BUILT on `feat/accountant-package`; receipts + vehicles + refunds explicitly out; device-smoke pending).
- [ ] **Step 3: Gate (docs-only, still run) + commit (owner-approved)**

```bash
npm run typecheck && npm test && npm run lint
git add README.md ARCHITECTURE.md docs/
git commit -m "docs: Phase 14 accountant package — README/ARCHITECTURE/roadmap sweep"
```

---

### Task 10: Gate, device-smoke handoff, phase report

- [ ] **Step 1:** Full gate on the merged-to-be tree: `npm run typecheck && npm test && npm run lint` — record the exact line ("Verified: tsc 0, N tests / M suites, lint 0").
- [ ] **Step 2:** Owner device-smoke script: pick This Year → tap Accountant package → confirm a `.zip` shares; open it on desktop and verify all 11 files present, `active-payments` total matches the Money tab's collected figure, `summary.json` reconciles, `export-warnings.csv` reads sensibly.
- [ ] **Step 3:** Phase report: Confidence / Missing Context / Recommended Next Step (merge + next OTA). Then STOP. This client feature reaches users only on the next OTA (standing owner call).

---

## Self-Review

**Spec coverage:** invoices ✓(T2) line-items ✓(T2) active-payments ✓(T2) payment-activity+voids ✓(T2) expenses+jobId ✓(T2) mileage ✓(T6 via existing builder) customers ✓(T2) category-mapping ✓(T2) warnings ✓(T3) summary.json ✓(T4) README ✓(T5) zip+determinism ✓(T1,T6) BOM/CRLF/RFC-4180 ✓(reused toCsv + T6) secrets-excluded ✓(PackageInput shape) share ✓(T7) UI ✓(T8) docs ✓(T9) gate/smoke ✓(T10). Dropped (vehicles/refunds/receipts) documented in spec Out-of-scope.

**Placeholder scan:** none — every code step carries full code; T8/T9 are mechanical wiring/docs with explicit targets.

**Type consistency:** `PackageInput` (T3) used verbatim in T4/T6; `PackageSummary` (T4) consumed by T5/T6; `ZipEntry`/`buildZip`/`utf8Encode`/`base64Encode` (T1) consumed by T6/T7; builder names stable across tasks. `buildExpensesCsv2` deliberately named to avoid colliding with the existing `buildExpensesCsv` in `csvExport.ts`.
