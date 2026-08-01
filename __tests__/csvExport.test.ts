import { buildIncomeCsv, buildExpensesCsv, buildTripsCsv, escapeCsvField, toCsv } from "../utils/csvExport";
import { collectedInRange } from "../utils/invoicePayments";
import type { Invoice, Expense, Trip } from "../types/models";

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
