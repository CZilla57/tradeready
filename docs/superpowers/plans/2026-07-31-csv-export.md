# CSV Export Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Export income (payment-level), expenses, and mileage as CSV files over a selectable date range, shared via the platform share sheet from a Money-tab modal.

**Architecture:** Pure CSV builders in a new `utils/csvExport.ts` (no I/O, fully unit-tested), a thin `shareCsv` file-write+share tail mirroring `utils/pdfExport.ts`, and one new modal screen (`ExportDataScreen`) in the Money stack reached by a header icon on MoneyHome. Income rows derive from the payment ledger via the existing `paymentsInRange`, guaranteeing sum-equivalence with `collectedInRange`.

**Tech Stack:** React Native (Expo 54) + TypeScript strict; expo-file-system/legacy + expo-sharing (both already dependencies, both already mocked in jest.setup.js); Jest.

**Spec:** `docs/superpowers/specs/2026-07-31-csv-export-design.md` (owner-approved 2026-07-31).

## Global Constraints

- Branch: `feat/csv-export`, cut from master (master tip at plan time: `70b9094`).
- Run everything from `C:\Users\Chadr\OneDrive\Documents\TraderPro App\tradeready\` (path has a space — always quote it).
- Gate before EVERY commit, all green, no exceptions: `npm run typecheck` (0 errors), `npm test` (all pass; baseline 1391 tests / 89 suites), `npm run lint` (0 warnings). Never commit on red (tradeready-change-control Rule 2).
- NO new dependencies, NO package.json/app.json changes, NO persisted data-shape changes (this feature needs none).
- No `eslint-disable` / `@ts-ignore` / `@ts-expect-error`.
- New source files are born-typed strict TS. New test file is TS (`__tests__/csvExport.test.ts` — precedent: `recurringJobs.test.ts`).
- Never use `localeCompare` for sorting (Hermes ICU variance — see comparePayments in utils/invoicePayments.ts). Compare `"YYYY-MM-DD"` strings with `<`/`>`.
- Themed components use the `createStyles(colors, shadow)` + `useMemo` factory pattern; static tokens (`spacing`, `radius`, `fontSize`, `fonts`) imported directly from `utils/theme`.
- CSV format rules (spec §1): header always present; rows sorted by date ascending; money amounts as plain `1234.50`; dates `YYYY-MM-DD`; CRLF line endings; trailing newline; NO totals rows.

---

### Task 0: Branch setup

**Files:** none (git only)

- [ ] **Step 1: Create the branch from master**

```bash
cd "/c/Users/Chadr/OneDrive/Documents/TraderPro App/tradeready" && git checkout master && git pull --ff-only 2>/dev/null; git checkout -b feat/csv-export && git log -1 --oneline
```

Expected: `Switched to a new branch 'feat/csv-export'`, HEAD at `70b9094` (or later master tip; `git pull` may fail offline — that's fine, proceed from local master).

---

### Task 1: CSV core — `escapeCsvField` + `toCsv`

**Files:**
- Create: `utils/csvExport.ts`
- Create: `__tests__/csvExport.test.ts`

**Interfaces:**
- Consumes: nothing (pure strings)
- Produces: `escapeCsvField(value: string): string` (exported); `toCsv(header: string[], rows: string[][]): string` (exported — builders in Tasks 2–3 and their tests use it)

- [ ] **Step 1: Write the failing tests**

Create `__tests__/csvExport.test.ts`:

```ts
import { escapeCsvField, toCsv } from "../utils/csvExport";

describe("escapeCsvField", () => {
  test("plain value passes through unquoted", () => {
    expect(escapeCsvField("Deck repair")).toBe("Deck repair");
  });

  test("empty string passes through", () => {
    expect(escapeCsvField("")).toBe("");
  });

  test("comma triggers quoting", () => {
    expect(escapeCsvField("Smith, Jones & Co")).toBe('"Smith, Jones & Co"');
  });

  test("embedded quotes are doubled and the field quoted", () => {
    expect(escapeCsvField('the "big" job')).toBe('"the ""big"" job"');
  });

  test("newline triggers quoting", () => {
    expect(escapeCsvField("line one\nline two")).toBe('"line one\nline two"');
  });

  test("carriage return triggers quoting", () => {
    expect(escapeCsvField("a\rb")).toBe('"a\rb"');
  });

  test("accented characters pass through untouched", () => {
    expect(escapeCsvField("José Núñez")).toBe("José Núñez");
  });
});

describe("toCsv", () => {
  test("header only when there are no rows, with trailing CRLF", () => {
    expect(toCsv(["A", "B"], [])).toBe("A,B\r\n");
  });

  test("joins fields with commas and lines with CRLF", () => {
    expect(toCsv(["A", "B"], [["1", "2"], ["3", "4"]])).toBe(
      "A,B\r\n1,2\r\n3,4\r\n"
    );
  });

  test("escapes every field including headers", () => {
    expect(toCsv(["Name, full"], [['say "hi"']])).toBe(
      '"Name, full"\r\n"say ""hi"""\r\n'
    );
  });
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `npm test -- csvExport`
Expected: FAIL — `Cannot find module '../utils/csvExport'`

- [ ] **Step 3: Write the implementation**

Create `utils/csvExport.ts`:

```ts
// utils/csvExport.ts
// The accounting export (roadmap #7): pure CSV builders + the share tail.
// Builders do NO I/O — everything above shareCsv is unit-testable strings.
// Spec: docs/superpowers/specs/2026-07-31-csv-export-design.md

/**
 * RFC-4180 field escaping: quote when the value contains a comma, quote,
 * or line break; double embedded quotes. Everything else passes through
 * so accented customer names stay readable in the file.
 */
export function escapeCsvField(value: string): string {
  if (/[",\r\n]/.test(value)) {
    return '"' + value.replace(/"/g, '""') + '"';
  }
  return value;
}

/**
 * Assemble a CSV document: header + rows, CRLF line endings (Excel's
 * expectation), trailing newline. No totals rows — they poison imports.
 */
export function toCsv(header: string[], rows: string[][]): string {
  const lines = [header, ...rows].map((fields) =>
    fields.map(escapeCsvField).join(",")
  );
  return lines.join("\r\n") + "\r\n";
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `npm test -- csvExport`
Expected: PASS (10 tests)

- [ ] **Step 5: Full gate, then commit**

Run: `npm run typecheck && npm test && npm run lint`
Expected: 0 errors / all pass (1391 + 10 new) / 0 warnings

```bash
git add utils/csvExport.ts __tests__/csvExport.test.ts
git commit -m "feat: add CSV core (RFC-4180 escaping + document assembly)"
```

---

### Task 2: `buildIncomeCsv` — payment-level income rows

**Files:**
- Modify: `utils/invoicePayments.ts:39` (export the existing private `toAmount`)
- Modify: `utils/csvExport.ts` (append)
- Modify: `__tests__/csvExport.test.ts` (append)

**Interfaces:**
- Consumes: `paymentsInRange(invoice, start, end): Payment[]` and `toAmount(value: unknown): number` from `utils/invoicePayments`; `toCsv`/`escapeCsvField` from Task 1
- Produces: `buildIncomeCsv(invoices: Invoice[], start: Date, end: Date): string`

- [ ] **Step 1: Export `toAmount` from invoicePayments**

In `utils/invoicePayments.ts`, change the declaration on line 39 from:

```ts
function toAmount(value: unknown): number {
```

to:

```ts
export function toAmount(value: unknown): number {
```

And append one line to the end of its doc comment (after the INVARIANT paragraph):

```ts
 * Exported for utils/csvExport.ts, whose income rows must coerce amounts
 * identically or the export's sum-equivalence with collectedInRange breaks.
```

No other change. This module's tests must stay green untouched.

- [ ] **Step 2: Write the failing tests**

Append to `__tests__/csvExport.test.ts`:

```ts
import { buildIncomeCsv } from "../utils/csvExport";
import { collectedInRange } from "../utils/invoicePayments";
import type { Invoice } from "../types/models";

// Minimal valid invoice; override what each test needs.
const inv = (over: Partial<Invoice> = {}): Invoice => ({
  id: "inv1753900000000",
  customer: "Jane Smith",
  number: "INV-0001",
  amount: 1000,
  due: "2026-06-01",
  email: "",
  phone: "",
  desc: "Maintenance",
  paid: false,
  ...over,
});

const JAN1 = new Date(2026, 0, 1);
const DEC31 = new Date(2026, 11, 31, 23, 59, 59);

describe("buildIncomeCsv", () => {
  const HEADER =
    "Date,Customer,Invoice #,Invoice Description,Method,Note,Amount";

  test("empty invoice list exports header only", () => {
    expect(buildIncomeCsv([], JAN1, DEC31)).toBe(HEADER + "\r\n");
  });

  test("one row per non-voided ledger payment in range", () => {
    const invoice = inv({
      payments: [
        { id: "p1", amount: 400, date: "2026-03-01", method: "cash" },
        { id: "p2", amount: 600, date: "2026-04-15", method: "stripe" },
      ],
    });
    const csv = buildIncomeCsv([invoice], JAN1, DEC31);
    const lines = csv.trimEnd().split("\r\n");
    expect(lines).toHaveLength(3);
    expect(lines[1]).toBe("2026-03-01,Jane Smith,INV-0001,Maintenance,cash,,400.00");
    expect(lines[2]).toBe("2026-04-15,Jane Smith,INV-0001,Maintenance,stripe,,600.00");
  });

  test("voided payments are excluded", () => {
    const invoice = inv({
      payments: [
        { id: "p1", amount: 400, date: "2026-03-01", method: "cash" },
        { id: "p2", amount: 600, date: "2026-04-15", method: "card", voidedAt: "2026-04-16" },
      ],
    });
    const csv = buildIncomeCsv([invoice], JAN1, DEC31);
    expect(csv).toContain("400.00");
    expect(csv).not.toContain("600.00");
  });

  test("payments outside the range are excluded", () => {
    const invoice = inv({
      payments: [
        { id: "p1", amount: 400, date: "2025-12-31", method: "cash" },
        { id: "p2", amount: 600, date: "2026-04-15", method: "cash" },
      ],
    });
    const lines = buildIncomeCsv([invoice], JAN1, DEC31).trimEnd().split("\r\n");
    expect(lines).toHaveLength(2);
    expect(lines[1]).toContain("2026-04-15");
  });

  test("legacy paid invoice emits one implicit row dated paidAt, method blank", () => {
    const invoice = inv({ paid: true, paidAt: "2026-05-20" });
    const lines = buildIncomeCsv([invoice], JAN1, DEC31).trimEnd().split("\r\n");
    expect(lines).toHaveLength(2);
    // Method column blank; the materialized legacy note is kept.
    expect(lines[1]).toBe(
      "2026-05-20,Jane Smith,INV-0001,Maintenance,,Recorded before payment history was itemised,1000.00"
    );
  });

  test("legacy paid invoice without paidAt buckets on due", () => {
    const invoice = inv({ paid: true, due: "2026-02-10" });
    const csv = buildIncomeCsv([invoice], JAN1, DEC31);
    expect(csv).toContain("2026-02-10");
  });

  test("legacy unpaid invoice emits nothing", () => {
    const invoice = inv({ paid: false });
    expect(buildIncomeCsv([invoice], JAN1, DEC31)).toBe(HEADER + "\r\n");
  });

  test("rows across invoices are sorted by date ascending", () => {
    const a = inv({ id: "invA", number: "INV-0002",
      payments: [{ id: "p1", amount: 100, date: "2026-06-01", method: "cash" }] });
    const b = inv({ id: "invB", number: "INV-0003",
      payments: [{ id: "p2", amount: 200, date: "2026-02-01", method: "cash" }] });
    const lines = buildIncomeCsv([a, b], JAN1, DEC31).trimEnd().split("\r\n");
    expect(lines[1]).toContain("2026-02-01");
    expect(lines[2]).toContain("2026-06-01");
  });

  test("fields with commas are escaped", () => {
    const invoice = inv({
      customer: "Smith, Jones & Co",
      payments: [{ id: "p1", amount: 100, date: "2026-03-01", method: "check", note: "lobby, phase 1" }],
    });
    const csv = buildIncomeCsv([invoice], JAN1, DEC31);
    expect(csv).toContain('"Smith, Jones & Co"');
    expect(csv).toContain('"lobby, phase 1"');
  });

  test("malformed amount contributes 0.00, not NaN", () => {
    const invoice = inv({
      payments: [{ id: "p1", amount: "oops" as unknown as number, date: "2026-03-01", method: "cash" }],
    });
    const csv = buildIncomeCsv([invoice], JAN1, DEC31);
    expect(csv).toContain("0.00");
    expect(csv).not.toContain("NaN");
  });

  test("SUM-EQUIVALENCE: exported amounts total exactly collectedInRange, over several ranges", () => {
    const invoices = [
      inv({ id: "invA", payments: [
        { id: "p1", amount: 400.10, date: "2026-03-01", method: "cash" },
        { id: "p2", amount: 599.90, date: "2026-07-15", method: "stripe" },
        { id: "p3", amount: 50, date: "2026-07-16", method: "card", voidedAt: "2026-07-17" },
      ]}),
      inv({ id: "invB", number: "INV-0002", paid: true, paidAt: "2026-04-02", amount: 250 }),
      inv({ id: "invC", number: "INV-0003", paid: false }),
    ];
    const ranges: [Date, Date][] = [
      [JAN1, DEC31],
      [new Date(2026, 2, 1), new Date(2026, 3, 30, 23, 59, 59)],
      [new Date(2026, 6, 1), new Date(2026, 6, 31, 23, 59, 59)],
      [new Date(2027, 0, 1), new Date(2027, 11, 31)],
    ];
    for (const [start, end] of ranges) {
      const lines = buildIncomeCsv(invoices, start, end).trimEnd().split("\r\n").slice(1);
      const sum = lines.reduce((acc, line) => {
        const last = line.split(",").pop() as string;
        return acc + Number(last);
      }, 0);
      expect(sum).toBeCloseTo(collectedInRange(invoices, start, end), 2);
    }
  });
});
```

Note: the sum-equivalence fixtures deliberately avoid commas in the Amount-adjacent
fields so `line.split(",").pop()` is sound there; the escaping test covers commas.

- [ ] **Step 3: Run tests to verify they fail**

Run: `npm test -- csvExport`
Expected: FAIL — `buildIncomeCsv` is not exported

- [ ] **Step 4: Write the implementation**

Append to `utils/csvExport.ts`:

```ts
import type { Expense, Invoice, Trip } from "../types/models";
import { paymentsInRange, toAmount } from "./invoicePayments";

const INCOME_HEADER = [
  "Date",
  "Customer",
  "Invoice #",
  "Invoice Description",
  "Method",
  "Note",
  "Amount",
];

/**
 * Income rows are PAYMENTS, not invoices — deposits and partials export on
 * the date the money actually arrived. Semantics match collectedInRange
 * exactly (there is a sum-equivalence test): voided entries excluded, legacy
 * paid invoices contribute their one implicit entry (dated paidAt ?? due via
 * materializeLegacyLedger), amounts coerced through the same toAmount.
 *
 * The implicit legacy entry carries the deterministic id `legacy_<id>` and
 * method "other" — the export blanks the method for those rows (spec §2):
 * "other" would misreport how money arrived when all we know is that it did.
 */
export function buildIncomeCsv(invoices: Invoice[], start: Date, end: Date): string {
  const rows: { date: string; fields: string[] }[] = [];
  for (const invoice of invoices) {
    for (const p of paymentsInRange(invoice, start, end)) {
      if (p.voidedAt) continue;
      const legacy = p.id.startsWith("legacy_");
      rows.push({
        date: p.date,
        fields: [
          p.date,
          invoice.customer || "",
          invoice.number || "",
          invoice.desc || "",
          legacy ? "" : p.method,
          p.note || "",
          toAmount(p.amount).toFixed(2),
        ],
      });
    }
  }
  // Code-unit comparison, NOT localeCompare (Hermes ICU variance — see
  // comparePayments in invoicePayments.ts). "YYYY-MM-DD" sorts chronologically.
  rows.sort((a, b) => (a.date === b.date ? 0 : a.date < b.date ? -1 : 1));
  return toCsv(INCOME_HEADER, rows.map((r) => r.fields));
}
```

Move the two `import` lines to the TOP of the file (imports first, then the
existing Task-1 code). `Expense` and `Trip` are used by Task 3 — if the linter
flags them as unused at this point, import only `Invoice` now and add
`Expense, Trip` in Task 3.

- [ ] **Step 5: Run tests to verify they pass**

Run: `npm test -- csvExport`
Expected: PASS (all Task 1 + Task 2 tests)

- [ ] **Step 6: Full gate, then commit**

Run: `npm run typecheck && npm test && npm run lint`
Expected: green across the board (invoicePayments suites untouched and passing)

```bash
git add utils/csvExport.ts utils/invoicePayments.ts __tests__/csvExport.test.ts
git commit -m "feat: add payment-level income CSV builder (sum-equivalent to collectedInRange)"
```

---

### Task 3: `buildExpensesCsv` + `buildTripsCsv`

**Files:**
- Modify: `utils/csvExport.ts` (append)
- Modify: `__tests__/csvExport.test.ts` (append)

**Interfaces:**
- Consumes: `isInRange(dateString, start, end): boolean` and `EXPENSE_CATEGORIES` from `utils/moneyUtils`; `toAmount` from `utils/invoicePayments`; `toCsv` from Task 1
- Produces: `buildExpensesCsv(expenses: Expense[], start: Date, end: Date): string`; `buildTripsCsv(trips: Trip[], start: Date, end: Date): string`

- [ ] **Step 1: Write the failing tests**

Append to `__tests__/csvExport.test.ts`:

```ts
import { buildExpensesCsv, buildTripsCsv } from "../utils/csvExport";
import type { Expense, Trip } from "../types/models";

const expense = (over: Partial<Expense> = {}): Expense => ({
  id: "e1",
  createdAt: "2026-03-01",
  description: "Lumber",
  amount: 250.5,
  category: "materials",
  date: "2026-03-01",
  notes: "",
  receiptUri: null,
  ...over,
});

const trip = (over: Partial<Trip> = {}): Trip => ({
  id: "t1",
  date: "2026-03-02",
  odometerStart: 10000,
  odometerEnd: 10024,
  miles: 24,
  fromJobId: null,
  fromLabel: "Home / Shop",
  toJobId: "j1",
  toLabel: "Smith deck job",
  purpose: "Site visit",
  createdAt: "2026-03-02",
  ...over,
});

describe("buildExpensesCsv", () => {
  const HEADER = "Date,Description,Category,Amount,Notes,Has Receipt";

  test("header only for empty range", () => {
    expect(buildExpensesCsv([], JAN1, DEC31)).toBe(HEADER + "\r\n");
  });

  test("emits label from EXPENSE_CATEGORIES and receipt flag", () => {
    const rows = buildExpensesCsv(
      [expense({ receiptUri: "file:///r.jpg" })],
      JAN1,
      DEC31
    ).trimEnd().split("\r\n");
    expect(rows[1]).toBe("2026-03-01,Lumber,Materials,250.50,,Yes");
  });

  test("unknown category id falls back to Other (ExpenseRow's rule)", () => {
    const rows = buildExpensesCsv(
      [expense({ category: "bogus" as Expense["category"] })],
      JAN1,
      DEC31
    ).trimEnd().split("\r\n");
    expect(rows[1]).toContain(",Other,");
  });

  test("out-of-range expenses excluded; rows sorted by date", () => {
    const rows = buildExpensesCsv(
      [
        expense({ id: "e2", date: "2026-06-01", description: "Blades" }),
        expense({ id: "e3", date: "2026-01-15", description: "Fuel" }),
        expense({ id: "e4", date: "2025-11-01", description: "OldStuff" }),
      ],
      JAN1,
      DEC31
    ).trimEnd().split("\r\n");
    expect(rows).toHaveLength(3);
    expect(rows[1]).toContain("Fuel");
    expect(rows[2]).toContain("Blades");
  });

  test("notes with newlines are escaped", () => {
    const csv = buildExpensesCsv(
      [expense({ notes: "line1\nline2" })],
      JAN1,
      DEC31
    );
    expect(csv).toContain('"line1\nline2"');
  });
});

describe("buildTripsCsv", () => {
  const HEADER = "Date,From,To,Purpose,Odometer Start,Odometer End,Miles";

  test("header only for empty range", () => {
    expect(buildTripsCsv([], JAN1, DEC31)).toBe(HEADER + "\r\n");
  });

  test("emits raw trip values (miles not money-formatted)", () => {
    const rows = buildTripsCsv([trip()], JAN1, DEC31).trimEnd().split("\r\n");
    expect(rows[1]).toBe(
      "2026-03-02,Home / Shop,Smith deck job,Site visit,10000,10024,24"
    );
  });

  test("fractional miles survive as-is", () => {
    const csv = buildTripsCsv([trip({ miles: 12.4 })], JAN1, DEC31);
    expect(csv).toContain(",12.4");
  });

  test("out-of-range trips excluded; rows sorted by date", () => {
    const rows = buildTripsCsv(
      [
        trip({ id: "t2", date: "2026-08-01", purpose: "Later" }),
        trip({ id: "t3", date: "2026-02-01", purpose: "Earlier" }),
        trip({ id: "t4", date: "2027-01-01", purpose: "NextYear" }),
      ],
      JAN1,
      DEC31
    ).trimEnd().split("\r\n");
    expect(rows).toHaveLength(3);
    expect(rows[1]).toContain("Earlier");
    expect(rows[2]).toContain("Later");
  });
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `npm test -- csvExport`
Expected: FAIL — `buildExpensesCsv` is not exported

- [ ] **Step 3: Write the implementation**

Append to `utils/csvExport.ts` (and ensure `Expense, Trip` are in the models
type import and `EXPENSE_CATEGORIES, isInRange` are imported from
`./moneyUtils` at the top of the file):

```ts
import { EXPENSE_CATEGORIES, isInRange } from "./moneyUtils";

const EXPENSE_HEADER = ["Date", "Description", "Category", "Amount", "Notes", "Has Receipt"];

/** Category exports the LABEL; unknown ids fall back to Other exactly like ExpenseRow. */
export function buildExpensesCsv(expenses: Expense[], start: Date, end: Date): string {
  const rows = expenses
    .filter((e) => isInRange(e.date, start, end))
    .sort((a, b) => (a.date === b.date ? 0 : a.date < b.date ? -1 : 1))
    .map((e) => {
      const category =
        EXPENSE_CATEGORIES.find((c) => c.id === e.category) || EXPENSE_CATEGORIES[7];
      return [
        e.date,
        e.description || "",
        category.label,
        toAmount(e.amount).toFixed(2),
        e.notes || "",
        e.receiptUri ? "Yes" : "No",
      ];
    });
  return toCsv(EXPENSE_HEADER, rows);
}

const TRIP_HEADER = ["Date", "From", "To", "Purpose", "Odometer Start", "Odometer End", "Miles"];

/** Raw trip data; miles are not money, so no decimal padding — the accountant applies the rate. */
export function buildTripsCsv(trips: Trip[], start: Date, end: Date): string {
  const rows = trips
    .filter((t) => isInRange(t.date, start, end))
    .sort((a, b) => (a.date === b.date ? 0 : a.date < b.date ? -1 : 1))
    .map((t) => [
      t.date,
      t.fromLabel || "",
      t.toLabel || "",
      t.purpose || "",
      String(t.odometerStart),
      String(t.odometerEnd),
      String(t.miles),
    ]);
  return toCsv(TRIP_HEADER, rows);
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `npm test -- csvExport`
Expected: PASS

- [ ] **Step 5: Full gate, then commit**

Run: `npm run typecheck && npm test && npm run lint`

```bash
git add utils/csvExport.ts __tests__/csvExport.test.ts
git commit -m "feat: add expense and mileage CSV builders"
```

---

### Task 4: Range presets, filenames, row counts

**Files:**
- Modify: `utils/csvExport.ts` (append)
- Modify: `__tests__/csvExport.test.ts` (append)

**Interfaces:**
- Consumes: `DateRange` type from `utils/moneyUtils`
- Produces:
  - `type ExportRangeId = "this_month" | "this_quarter" | "this_year" | "last_year" | "all_time"`
  - `exportDateRange(id: ExportRangeId, now?: Date): DateRange`
  - `csvFilename(dataset: "income" | "expenses" | "mileage", range: DateRange, rangeId: ExportRangeId | "custom"): string`
  - `csvRowCount(csv: string): number`

- [ ] **Step 1: Write the failing tests**

Append to `__tests__/csvExport.test.ts`:

```ts
import { exportDateRange, csvFilename, csvRowCount } from "../utils/csvExport";

describe("exportDateRange", () => {
  // Fixed 'now' → deterministic regardless of machine clock/timezone.
  const NOW = new Date(2026, 7, 15, 12, 0, 0); // Aug 15 2026

  test("this_month spans the calendar month", () => {
    const r = exportDateRange("this_month", NOW);
    expect(r.start).toEqual(new Date(2026, 7, 1));
    expect(r.end).toEqual(new Date(2026, 8, 0, 23, 59, 59));
  });

  test("this_quarter spans Jul-Sep for an August now", () => {
    const r = exportDateRange("this_quarter", NOW);
    expect(r.start).toEqual(new Date(2026, 6, 1));
    expect(r.end).toEqual(new Date(2026, 9, 0, 23, 59, 59));
  });

  test("this_quarter first month of a quarter", () => {
    const r = exportDateRange("this_quarter", new Date(2026, 0, 3));
    expect(r.start).toEqual(new Date(2026, 0, 1));
    expect(r.end).toEqual(new Date(2026, 3, 0, 23, 59, 59));
  });

  test("this_year and last_year", () => {
    expect(exportDateRange("this_year", NOW).start).toEqual(new Date(2026, 0, 1));
    expect(exportDateRange("last_year", NOW).start).toEqual(new Date(2025, 0, 1));
    expect(exportDateRange("last_year", NOW).end).toEqual(new Date(2025, 11, 31, 23, 59, 59));
  });

  test("all_time is unbounded for practical purposes", () => {
    const r = exportDateRange("all_time", NOW);
    expect(r.start.getTime()).toBe(0);
    expect(r.end.getFullYear()).toBe(9999);
  });
});

describe("csvFilename", () => {
  const range = { start: new Date(2026, 0, 1), end: new Date(2026, 11, 31) };

  test("dated filename from local dates", () => {
    expect(csvFilename("income", range, "this_year")).toBe(
      "tradeready-income_2026-01-01_2026-12-31.csv"
    );
  });

  test("all_time avoids the epoch date", () => {
    expect(csvFilename("mileage", range, "all_time")).toBe(
      "tradeready-mileage_all-time.csv"
    );
  });
});

describe("csvRowCount", () => {
  test("header-only file has zero rows", () => {
    expect(csvRowCount("A,B\r\n")).toBe(0);
  });

  test("counts data rows", () => {
    expect(csvRowCount("A,B\r\n1,2\r\n3,4\r\n")).toBe(2);
  });
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `npm test -- csvExport`
Expected: FAIL — `exportDateRange` is not exported

- [ ] **Step 3: Write the implementation**

Append to `utils/csvExport.ts` (add `import type { DateRange } from "./moneyUtils";` — merge into the existing moneyUtils import):

```ts
export type ExportRangeId =
  | "this_month"
  | "this_quarter"
  | "this_year"
  | "last_year"
  | "all_time";

/**
 * Export presets. Same local-time construction as moneyUtils.getDateRange —
 * implemented here rather than delegated because the export needs an
 * injectable `now` for deterministic tests (getDateRange reads the real
 * clock) and two presets (quarter, last year) getDateRange doesn't have.
 */
export function exportDateRange(id: ExportRangeId, now: Date = new Date()): DateRange {
  const y = now.getFullYear();
  const m = now.getMonth();
  switch (id) {
    case "this_month":
      return { start: new Date(y, m, 1), end: new Date(y, m + 1, 0, 23, 59, 59) };
    case "this_quarter": {
      const q = Math.floor(m / 3) * 3;
      return { start: new Date(y, q, 1), end: new Date(y, q + 3, 0, 23, 59, 59) };
    }
    case "this_year":
      return { start: new Date(y, 0, 1), end: new Date(y, 11, 31, 23, 59, 59) };
    case "last_year":
      return { start: new Date(y - 1, 0, 1), end: new Date(y - 1, 11, 31, 23, 59, 59) };
    case "all_time":
      return { start: new Date(0), end: new Date(9999, 11, 31) };
  }
}

// LOCAL date for filenames — toISOString would UTC-shift west-of-UTC users
// onto the previous day (same trap parseLocalDate exists for).
function ymdLocal(d: Date): string {
  const pad = (n: number) => String(n).padStart(2, "0");
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
}

/** No user text in filenames, so no sanitizer needed (unlike invoicePdfFilename). */
export function csvFilename(
  dataset: "income" | "expenses" | "mileage",
  range: DateRange,
  rangeId: ExportRangeId | "custom"
): string {
  if (rangeId === "all_time") return `tradeready-${dataset}_all-time.csv`;
  return `tradeready-${dataset}_${ymdLocal(range.start)}_${ymdLocal(range.end)}.csv`;
}

/** Data rows in a built CSV (excludes the header) — drives the screen's counts. */
export function csvRowCount(csv: string): number {
  return csv.split("\r\n").filter((line) => line.length > 0).length - 1;
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `npm test -- csvExport`
Expected: PASS

- [ ] **Step 5: Full gate, then commit**

Run: `npm run typecheck && npm test && npm run lint`

```bash
git add utils/csvExport.ts __tests__/csvExport.test.ts
git commit -m "feat: add export range presets, CSV filenames, row counts"
```

---

### Task 5: `shareCsv` — write + share tail

**Files:**
- Modify: `utils/csvExport.ts` (append)
- Modify: `__tests__/csvExport.test.ts` (append)

**Interfaces:**
- Consumes: `expo-file-system/legacy` (`cacheDirectory`, `writeAsStringAsync`), `expo-sharing` (`isAvailableAsync`, `shareAsync`), `react-native` `Alert` — all already mocked in `jest.setup.js`
- Produces: `shareCsv(csv: string, filename: string): Promise<void>` — alerts on failure and returns; callers never branch (the `utils/pdfExport.ts` contract)

- [ ] **Step 1: Write the failing tests**

Append to `__tests__/csvExport.test.ts`:

```ts
import { Alert } from "react-native";
import * as FileSystem from "expo-file-system/legacy";
import * as Sharing from "expo-sharing";
import { shareCsv } from "../utils/csvExport";

describe("shareCsv", () => {
  beforeEach(() => {
    jest.clearAllMocks();
    jest.spyOn(Alert, "alert").mockImplementation(() => {});
  });

  test("writes BOM-prefixed CSV to the cache dir and shares it", async () => {
    await shareCsv("A,B\r\n1,2\r\n", "tradeready-income_all-time.csv");
    expect(FileSystem.writeAsStringAsync).toHaveBeenCalledWith(
      "file:///mock/cache/tradeready-income_all-time.csv",
      "\uFEFF" + "A,B\r\n1,2\r\n"
    );
    expect(Sharing.shareAsync).toHaveBeenCalledWith(
      "file:///mock/cache/tradeready-income_all-time.csv",
      expect.objectContaining({ mimeType: "text/csv" })
    );
    expect(Alert.alert).not.toHaveBeenCalled();
  });

  test("alerts and skips the write when sharing is unavailable", async () => {
    (Sharing.isAvailableAsync as jest.Mock).mockResolvedValueOnce(false);
    await shareCsv("A\r\n", "x.csv");
    expect(FileSystem.writeAsStringAsync).not.toHaveBeenCalled();
    expect(Sharing.shareAsync).not.toHaveBeenCalled();
    expect(Alert.alert).toHaveBeenCalledWith(
      "Sharing not available",
      "This device cannot share files."
    );
  });

  test("alerts on write failure instead of throwing", async () => {
    (FileSystem.writeAsStringAsync as jest.Mock).mockRejectedValueOnce(new Error("disk"));
    await expect(shareCsv("A\r\n", "x.csv")).resolves.toBeUndefined();
    expect(Alert.alert).toHaveBeenCalledWith(
      "Export error",
      "Could not create the CSV file. Please try again."
    );
  });
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `npm test -- csvExport`
Expected: FAIL — `shareCsv` is not exported

- [ ] **Step 3: Write the implementation**

Add to the imports at the top of `utils/csvExport.ts`:

```ts
import { Alert } from "react-native";
import * as FileSystem from "expo-file-system/legacy";
import * as Sharing from "expo-sharing";
```

Append:

```ts
/**
 * Write the CSV to the cache directory and open the share sheet.
 * Mirrors utils/pdfExport.ts: owns its alerts, callers never branch.
 * The \uFEFF BOM makes Excel read the file as UTF-8 (accented names).
 */
export async function shareCsv(csv: string, filename: string): Promise<void> {
  try {
    const available = await Sharing.isAvailableAsync();
    if (!available) {
      Alert.alert("Sharing not available", "This device cannot share files.");
      return;
    }
    const uri = `${FileSystem.cacheDirectory}${filename}`;
    await FileSystem.writeAsStringAsync(uri, "\uFEFF" + csv);
    await Sharing.shareAsync(uri, { mimeType: "text/csv", dialogTitle: filename });
  } catch {
    Alert.alert("Export error", "Could not create the CSV file. Please try again.");
  }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `npm test -- csvExport`
Expected: PASS

- [ ] **Step 5: Full gate, then commit**

Run: `npm run typecheck && npm test && npm run lint`

```bash
git add utils/csvExport.ts __tests__/csvExport.test.ts
git commit -m "feat: add shareCsv write-and-share tail (BOM, cache dir, share sheet)"
```

---

### Task 6: `ExportDataScreen` + navigation wiring

**Files:**
- Create: `screens/ExportDataScreen.tsx`
- Modify: `types/navigation.ts:69-75` (MoneyStackParamList)
- Modify: `App.tsx` (import; MoneyHome headerRight; register ExportData — MoneyTab is ~lines 194–211)

**Interfaces:**
- Consumes: everything exported from `utils/csvExport` (Tasks 1–5), `loadInvoices`/`loadExpenses`/`loadTrips` from `utils/storage`, `Button`/`Card` from `components/UI`, `DateTimePickerSheet` (`{ visible, mode, value, title, onChange, onClose }`), theme factory pattern
- Produces: route `ExportData: undefined` on the Money stack; a `download-outline` header button on MoneyHome

No screen-level RNTL test (spec §7: repo convention is util-level coverage).
Correctness here is typecheck + lint + the manual smoke checklist in Task 7.

- [ ] **Step 1: Add the route type**

In `types/navigation.ts`, change `MoneyStackParamList` to:

```ts
export type MoneyStackParamList = {
  MoneyHome: undefined;
  MileageLog: { initialFilter?: string };
  AddTrip: { tripId?: string };
  Pricebook: undefined;
  PricebookEntry: { entryId?: string };
  ExportData: undefined;
};
```

- [ ] **Step 2: Create the screen**

Create `screens/ExportDataScreen.tsx`:

```tsx
// screens/ExportDataScreen.tsx
// Accounting export (roadmap #7): pick a date range, share income /
// expenses / mileage as CSVs. All math lives in utils/csvExport — this
// screen just holds range state and hands strings to the share sheet.

import React, { useCallback, useMemo, useState } from "react";
import { Alert, ScrollView, StyleSheet, Text, TouchableOpacity, View } from "react-native";
import { SafeAreaView } from "react-native-safe-area-context";
import { useFocusEffect } from "@react-navigation/native";
import { loadInvoices, loadExpenses, loadTrips } from "../utils/storage";
import { Button, Card } from "../components/UI";
import { DateTimePickerSheet } from "../components/DateTimePickerSheet";
import { spacing, radius, fontSize, fonts } from "../utils/theme";
import type { ColorScheme, ShadowScheme } from "../utils/theme";
import { useTheme } from "../hooks/useTheme";
import {
  buildExpensesCsv,
  buildIncomeCsv,
  buildTripsCsv,
  csvFilename,
  csvRowCount,
  exportDateRange,
  shareCsv,
  type ExportRangeId,
} from "../utils/csvExport";
import type { DateRange } from "../utils/moneyUtils";
import type { Expense, Invoice, Trip } from "../types/models";

type RangeChoice = ExportRangeId | "custom";

const RANGE_OPTIONS: { id: RangeChoice; label: string }[] = [
  { id: "this_month", label: "This Month" },
  { id: "this_quarter", label: "This Quarter" },
  { id: "this_year", label: "This Year" },
  { id: "last_year", label: "Last Year" },
  { id: "all_time", label: "All Time" },
  { id: "custom", label: "Custom" },
];

function startOfDay(d: Date): Date {
  return new Date(d.getFullYear(), d.getMonth(), d.getDate());
}

function endOfDay(d: Date): Date {
  return new Date(d.getFullYear(), d.getMonth(), d.getDate(), 23, 59, 59);
}

function ymd(d: Date): string {
  const pad = (n: number) => String(n).padStart(2, "0");
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
}

export default function ExportDataScreen() {
  const { colors, shadow } = useTheme();
  const styles = useMemo(() => createStyles(colors, shadow), [colors, shadow]);

  const [invoices, setInvoices] = useState<Invoice[]>([]);
  const [expenses, setExpenses] = useState<Expense[]>([]);
  const [trips, setTrips] = useState<Trip[]>([]);

  const [choice, setChoice] = useState<RangeChoice>("this_year");
  const [customStart, setCustomStart] = useState<Date>(() => new Date(new Date().getFullYear(), 0, 1));
  const [customEnd, setCustomEnd] = useState<Date>(() => new Date());
  const [pickerFor, setPickerFor] = useState<"start" | "end" | null>(null);

  useFocusEffect(
    useCallback(() => {
      loadInvoices().then(setInvoices);
      loadExpenses().then(setExpenses);
      loadTrips().then(setTrips);
    }, [])
  );

  const range: DateRange = useMemo(() => {
    if (choice === "custom") {
      return { start: startOfDay(customStart), end: endOfDay(customEnd) };
    }
    return exportDateRange(choice);
  }, [choice, customStart, customEnd]);

  const csvs = useMemo(
    () => ({
      income: buildIncomeCsv(invoices, range.start, range.end),
      expenses: buildExpensesCsv(expenses, range.start, range.end),
      mileage: buildTripsCsv(trips, range.start, range.end),
    }),
    [invoices, expenses, trips, range]
  );

  function handleShare(dataset: "income" | "expenses" | "mileage") {
    if (choice === "custom" && startOfDay(customStart) > endOfDay(customEnd)) {
      Alert.alert("Check your dates", "The start date is after the end date.");
      return;
    }
    shareCsv(csvs[dataset], csvFilename(dataset, range, choice));
  }

  const datasets: { key: "income" | "expenses" | "mileage"; label: string; hint: string }[] = [
    { key: "income", label: "Income", hint: "One row per payment received" },
    { key: "expenses", label: "Expenses", hint: "One row per expense" },
    { key: "mileage", label: "Mileage", hint: "One row per logged trip" },
  ];

  return (
    <SafeAreaView style={styles.container} edges={["bottom"]}>
      <ScrollView contentContainerStyle={styles.scroll}>
        <Text style={styles.heading}>Date range</Text>
        <View style={styles.chipRow}>
          {RANGE_OPTIONS.map((opt) => {
            const active = choice === opt.id;
            return (
              <TouchableOpacity
                key={opt.id}
                style={[styles.chip, active && { backgroundColor: colors.accent }]}
                onPress={() => setChoice(opt.id)}
                accessibilityRole="button"
                accessibilityState={{ selected: active }}
                accessibilityLabel={`Range: ${opt.label}`}
              >
                <Text style={[styles.chipText, active && styles.chipTextActive]}>
                  {opt.label}
                </Text>
              </TouchableOpacity>
            );
          })}
        </View>

        {choice === "custom" ? (
          <View style={styles.customRow}>
            <TouchableOpacity
              style={styles.dateField}
              onPress={() => setPickerFor("start")}
              accessibilityRole="button"
              accessibilityLabel="Start date"
            >
              <Text style={styles.dateLabel}>From</Text>
              <Text style={styles.dateValue}>{ymd(customStart)}</Text>
            </TouchableOpacity>
            <TouchableOpacity
              style={styles.dateField}
              onPress={() => setPickerFor("end")}
              accessibilityRole="button"
              accessibilityLabel="End date"
            >
              <Text style={styles.dateLabel}>To</Text>
              <Text style={styles.dateValue}>{ymd(customEnd)}</Text>
            </TouchableOpacity>
          </View>
        ) : null}

        <Text style={styles.heading}>Export</Text>
        {datasets.map((d) => (
          <Card key={d.key} style={styles.rowCard}>
            <View style={styles.rowLeft}>
              <Text style={styles.rowLabel}>{d.label}</Text>
              <Text style={styles.rowHint}>
                {csvRowCount(csvs[d.key])} rows · {d.hint}
              </Text>
            </View>
            <Button label="Share" onPress={() => handleShare(d.key)} style={styles.shareBtn} />
          </Card>
        ))}
        <Text style={styles.footnote}>
          CSV files open in Excel, Numbers, Google Sheets, and import into
          accounting software. Amounts are plain numbers; income is listed by
          payment received.
        </Text>
      </ScrollView>

      <DateTimePickerSheet
        visible={pickerFor !== null}
        mode="date"
        value={pickerFor === "start" ? customStart : customEnd}
        title={pickerFor === "start" ? "Start date" : "End date"}
        onChange={(d) => (pickerFor === "start" ? setCustomStart(d) : setCustomEnd(d))}
        onClose={() => setPickerFor(null)}
      />
    </SafeAreaView>
  );
}

function createStyles(colors: ColorScheme, shadow: ShadowScheme) {
  return StyleSheet.create({
    container: { flex: 1, backgroundColor: colors.background },
    scroll: { padding: spacing.md, paddingBottom: 120 },
    heading: {
      fontFamily: fonts.mono,
      fontSize: fontSize.sm,
      color: colors.textSecondary,
      marginTop: spacing.md,
      marginBottom: spacing.sm,
      textTransform: "uppercase",
      letterSpacing: 0.5,
    },
    chipRow: { flexDirection: "row", flexWrap: "wrap", gap: spacing.sm },
    chip: {
      paddingHorizontal: spacing.md,
      paddingVertical: spacing.sm,
      borderRadius: radius.md,
      backgroundColor: colors.surface,
      ...shadow.card,
    },
    chipText: { color: colors.textPrimary, fontSize: fontSize.sm, fontFamily: fonts.bodyMedium },
    chipTextActive: { color: colors.textOnAccent, fontWeight: "600" },
    customRow: { flexDirection: "row", gap: spacing.sm, marginTop: spacing.sm },
    dateField: {
      flex: 1,
      backgroundColor: colors.surface,
      borderRadius: radius.md,
      padding: spacing.md,
      ...shadow.card,
    },
    dateLabel: { color: colors.textMuted, fontSize: fontSize.xs, marginBottom: 2 },
    dateValue: { color: colors.textPrimary, fontSize: fontSize.md, fontFamily: fonts.mono },
    rowCard: {
      flexDirection: "row",
      alignItems: "center",
      justifyContent: "space-between",
      marginBottom: spacing.sm,
    },
    rowLeft: { flex: 1, paddingRight: spacing.md },
    rowLabel: { color: colors.textPrimary, fontSize: fontSize.lg, fontFamily: fonts.bodySemiBold },
    rowHint: { color: colors.textMuted, fontSize: fontSize.xs, marginTop: 2 },
    shareBtn: { minWidth: 92 },
    footnote: {
      color: colors.textMuted,
      fontSize: fontSize.xs,
      marginTop: spacing.md,
      lineHeight: 18,
    },
  });
}
```

**Theme tokens verified against utils/theme.ts (2026-07-31):**
`fonts.mono`, `fonts.bodyMedium`, `fonts.bodySemiBold` (there is NO
`fonts.heading`/`fonts.body` — do not invent tokens), `colors.textOnAccent`,
and all `spacing`/`radius`/`fontSize` keys used above exist. tsc enforces
this — if it errors on a token, use the theme's actual member, never add one.

- [ ] **Step 3: Wire navigation in App.tsx**

Add the import beside the other screen imports (~line 52):

```tsx
import ExportDataScreen           from "./screens/ExportDataScreen";
```

In `MoneyTab` (~lines 194–211), replace the MoneyHome registration line with
the header-button form (this is the exact JobList pattern from ~lines 119–136,
including the `paddingLeft: 8` header-button convention):

```tsx
      <MoneyStack.Screen
        name="MoneyHome"
        component={MoneyScreen}
        options={({ navigation }) => ({
          title: "Money",
          headerRight: () => (
            <TouchableOpacity
              onPress={() => navigation.navigate("ExportData")}
              hitSlop={{ top: 8, bottom: 8, left: 8, right: 8 }}
              style={{ paddingLeft: 8 }}
              accessibilityRole="button"
              accessibilityLabel="Export data"
            >
              <Ionicons name="download-outline" size={22} color={colors.accent} />
            </TouchableOpacity>
          ),
        })}
      />
```

And register the new screen before the closing `</MoneyStack.Navigator>`:

```tsx
      <MoneyStack.Screen
        name="ExportData"
        component={ExportDataScreen}
        options={{ presentation: "modal", title: "Export Data" }}
      />
```

(`TouchableOpacity` and `Ionicons` are already imported in App.tsx — verify,
don't re-import.)

- [ ] **Step 4: Full gate**

Run: `npm run typecheck && npm test && npm run lint`
Expected: green. Typecheck is the real reviewer here (route types, theme
tokens, component props).

- [ ] **Step 5: Commit**

```bash
git add screens/ExportDataScreen.tsx types/navigation.ts App.tsx
git commit -m "feat: add Export Data screen behind a Money header button"
```

---

### Task 7: Docs, final gate, handoff

**Files:**
- Modify: `docs/post-launch-feature-roadmap.md` (Phase 7 STATUS block + ship-order table row)
- Modify: `docs/superpowers/specs/2026-07-31-csv-export-design.md:90` (factual correction)

- [ ] **Step 1: Update the roadmap doc**

In `docs/post-launch-feature-roadmap.md`: in the ship-order table change
item 7's Status cell from `backlog` to `**BUILT** — on feat/csv-export`, and
insert a STATUS block under the `## Phase 7 — Accounting / CSV export`
heading, matching the house pattern of Phases 1–5:

```markdown
> **STATUS: BUILT 2026-07-31** on `feat/csv-export`. As designed in
> `docs/superpowers/specs/2026-07-31-csv-export-design.md`: income/expenses/
> mileage CSVs from a Money-tab Export Data modal (header download icon),
> range presets + custom, share-sheet delivery. Income rows are payment-level
> and sum-equivalent to `collectedInRange` (tested). No new dependencies; no
> schema changes; JS-only → OTA-eligible. **To go live:** merge + device
> smoke test.
```

- [ ] **Step 2: Correct the spec's stack description**

In `docs/superpowers/specs/2026-07-31-csv-export-design.md` §5, the line
"Registered as `ExportData` in `MoneyStack` (currently `MoneyHome` only)" is
factually stale — the Money stack also holds MileageLog, AddTrip, Pricebook,
PricebookEntry. Change that parenthetical to "(joining MoneyHome, MileageLog,
AddTrip, Pricebook, PricebookEntry)".

- [ ] **Step 3: Final full gate**

Run: `npm run typecheck && npm test && npm run lint`
Expected: 0 / all pass / 0.

- [ ] **Step 4: Commit**

```bash
git add docs/post-launch-feature-roadmap.md docs/superpowers/specs/2026-07-31-csv-export-design.md
git commit -m "docs: mark roadmap item 7 (CSV export) built; correct Money-stack note in spec"
```

- [ ] **Step 5: STOP — owner checkpoint (do not merge)**

Report per tradeready-change-control Rule 1 (Confidence / Missing Context /
Recommended Next Step). The branch stays unmerged until the owner smoke-tests
via Expo Go. Suggested smoke checklist for the owner:

1. Money tab → download icon opens Export Data (light + dark theme).
2. Default range is This Year; counts look plausible against the Money tab.
3. Share Income → share sheet → mail/AirDrop to a computer → opens in a
   spreadsheet: header row, payment-level rows, amounts match Money tab's
   collected figure for the same range; a deposit-paid invoice shows its
   partial payments on their dates.
4. Share Expenses and Mileage; check an expense with a comma/newline in notes.
5. Custom range: From after To → friendly alert; valid range exports.
6. Airplane mode: everything above still works (local-first).
