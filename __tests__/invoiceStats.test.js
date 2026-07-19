// __tests__/invoiceStats.test.js
// Roadmap #7 (7.5): Invoices-screen summary + filter logic. Notably pins the
// fixed behavior where the Overdue stat now agrees with the per-row badges — a
// due-today invoice is NOT overdue (getStatus labels it "Due today").

import { summarizeInvoices, filterInvoices, isOverdue } from "../utils/invoiceStats";

// Pin "today" to local midnight, matching daysPastDue's reference point.
const MOCK_TODAY = new Date(2026, 6, 4); // 6 = July

beforeAll(() => {
  jest.useFakeTimers();
  jest.setSystemTime(MOCK_TODAY);
});

afterAll(() => {
  jest.useRealTimers();
});

// NOTE: a non-zero default amount is load-bearing. Under the ledger, a $0
// invoice owes nothing, so isFullyPaid returns true and it is never overdue.
// These tests are about DATE logic, so they need an invoice that actually
// owes something.
const inv = (over) => ({ customer: "Acme", number: "INV-1", desc: "", amount: 500, ...over });

describe("isOverdue", () => {
  test("unpaid and several days past due", () => {
    expect(isOverdue(inv({ paid: false, due: "2026-06-20" }))).toBe(true);
  });
  test("due today is NOT overdue (matches the 'Due today' badge)", () => {
    expect(isOverdue(inv({ paid: false, due: "2026-07-04" }))).toBe(false);
  });
  test("future due date is not overdue", () => {
    expect(isOverdue(inv({ paid: false, due: "2026-08-01" }))).toBe(false);
  });
  test("a paid invoice is never overdue, even if past due", () => {
    expect(isOverdue(inv({ paid: true, due: "2020-01-01" }))).toBe(false);
  });
  test("a $0 invoice is never overdue — there is nothing owed", () => {
    // Deliberate change from the pre-ledger behaviour, where a $0 unpaid
    // invoice past due counted as overdue. Nothing is owed, so nothing is
    // late. Not reachable in-app: both invoice-creation screens reject
    // amount <= 0.
    expect(isOverdue(inv({ amount: 0, paid: false, due: "2026-06-20" }))).toBe(false);
  });
});

describe("summarizeInvoices", () => {
  const invoices = [
    inv({ id: "1", paid: false, amount: 100, due: "2026-06-01" }), // unpaid, overdue
    inv({ id: "2", paid: false, amount: 250, due: "2026-08-01" }), // unpaid, not overdue
    inv({ id: "3", paid: false, amount: 50, due: "2026-07-04" }),  // unpaid, due today (not overdue)
    inv({ id: "4", paid: true, amount: 400, due: "2026-05-01" }),  // paid
    inv({ id: "5", paid: true, amount: 75, due: "2026-06-10" }),   // paid
  ];

  test("outstanding sums unpaid amounts", () => {
    expect(summarizeInvoices(invoices).outstanding).toBe(400); // 100 + 250 + 50
  });
  test("collected sums paid amounts", () => {
    expect(summarizeInvoices(invoices).collected).toBe(475); // 400 + 75
  });
  test("overdueCount counts only unpaid past-due (excludes due-today)", () => {
    expect(summarizeInvoices(invoices).overdueCount).toBe(1); // only invoice 1
  });
  test("empty list is all zeroes", () => {
    expect(summarizeInvoices([])).toEqual({ outstanding: 0, overdueCount: 0, collected: 0 });
  });
});

describe("filterInvoices", () => {
  const invoices = [
    inv({ id: "1", customer: "Riverside Bakery", number: "INV-0038" }),
    inv({ id: "2", customer: "Tom Nguyen", number: "INV-0041" }),
  ];

  test("empty query returns everything", () => {
    expect(filterInvoices(invoices, "")).toHaveLength(2);
  });
  test("matches on customer name, case-insensitively", () => {
    const r = filterInvoices(invoices, "river");
    expect(r).toHaveLength(1);
    expect(r[0].id).toBe("1");
  });
  test("matches on invoice number", () => {
    const r = filterInvoices(invoices, "0041");
    expect(r).toHaveLength(1);
    expect(r[0].id).toBe("2");
  });
  test("no match returns empty", () => {
    expect(filterInvoices(invoices, "zzz")).toHaveLength(0);
  });
});

describe("partial payments", () => {
  test("outstanding counts only the balance, collected counts what arrived", () => {
    const invoices = [
      inv({ id: "1", amount: 1000, paid: false, due: "2026-08-01",
            payments: [{ id: "p1", amount: 400, date: "2026-07-01", method: "cash" }] }),
    ];
    const { outstanding, collected } = summarizeInvoices(invoices);
    expect(outstanding).toBe(600);
    expect(collected).toBe(400);
  });

  test("a fully-paid ledger invoice is all collected, nothing outstanding", () => {
    const invoices = [
      inv({ id: "1", amount: 1000, paid: true, due: "2026-08-01",
            payments: [{ id: "p1", amount: 1000, date: "2026-07-01", method: "cash" }] }),
    ];
    const { outstanding, collected } = summarizeInvoices(invoices);
    expect(outstanding).toBe(0);
    expect(collected).toBe(1000);
  });

  test("a voided payment returns the money to outstanding", () => {
    const invoices = [
      inv({ id: "1", amount: 1000, paid: false, due: "2026-08-01",
            payments: [{ id: "p1", amount: 400, date: "2026-07-01", method: "cash", voidedAt: "2026-07-22" }] }),
    ];
    const { outstanding, collected } = summarizeInvoices(invoices);
    expect(outstanding).toBe(1000);
    expect(collected).toBe(0);
  });

  test("a partly-paid invoice past due is still overdue", () => {
    const i = inv({ amount: 1000, paid: false, due: "2026-06-01",
                    payments: [{ id: "p1", amount: 400, date: "2026-07-01", method: "cash" }] });
    expect(isOverdue(i)).toBe(true);
  });
});
