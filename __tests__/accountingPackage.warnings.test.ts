import { collectWarnings, buildWarningsCsv } from "../utils/accountingPackage";
import type { Invoice, Expense } from "../types/models";

const JAN1 = new Date(2026, 0, 1), DEC31 = new Date(2026, 11, 31, 23, 59, 59);
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

test("missing_line_items fires for an in-scope invoice with no line items", () => {
  const invoices: Invoice[] = [{ id: "inv1772323200000", customer: "A", number: "INV-1", amount: 100,
    due: "2026-03-01", email: "", phone: "", desc: "", paid: false }];
  const codes = collectWarnings({ ...base, invoices }, JAN1, DEC31).map((w) => w.code);
  expect(codes).toContain("missing_line_items");
});

test("legacy_invoice_no_ledger fires for a paid invoice with no payment history", () => {
  const invoices: Invoice[] = [{ id: "inv1700000000000", customer: "A", number: "INV-1", amount: 100,
    due: "2026-03-01", email: "", phone: "", desc: "", paid: true }];
  const codes = collectWarnings({ ...base, invoices }, JAN1, DEC31).map((w) => w.code);
  expect(codes).toContain("legacy_invoice_no_ledger");
});

test("overpayment_present fires when payments exceed the invoice amount", () => {
  const invoices: Invoice[] = [{ id: "inv1700000000000", customer: "A", number: "INV-1", amount: 100,
    due: "2026-03-01", email: "", phone: "", desc: "", paid: false,
    payments: [{ id: "p1", amount: 150, date: "2026-03-01", method: "cash" }] }];
  const codes = collectWarnings({ ...base, invoices }, JAN1, DEC31).map((w) => w.code);
  expect(codes).toContain("overpayment_present");
});

test("voided_payments_present fires for an in-scope invoice with a voided in-range payment", () => {
  const invoices: Invoice[] = [{ id: "inv1700000000000", customer: "A", number: "INV-1", amount: 100,
    due: "2026-03-01", email: "", phone: "", desc: "", paid: false,
    payments: [{ id: "p1", amount: 50, date: "2026-03-01", method: "cash", voidedAt: "2026-03-02" },
      { id: "p2", amount: 25, date: "2026-03-03", method: "cash" }] }];
  const codes = collectWarnings({ ...base, invoices }, JAN1, DEC31).map((w) => w.code);
  expect(codes).toContain("voided_payments_present");
});

test("mileage_is_device_local fires when trips fall in range", () => {
  const codes = collectWarnings({ ...base, invoices: [],
    trips: [{ id: "t1", date: "2026-03-01", miles: 10, purpose: "" } as any] },
    JAN1, DEC31).map((w) => w.code);
  expect(codes).toContain("mileage_is_device_local");
});

// Regression for the fix: an invoice with a non-timestamp id (so it is not
// in-scope via issue date) whose ONLY in-range payment is voided, with no
// other data in the range at all. payment-activity.csv will still have a
// row and summary.voided_amount will be non-zero, so this must NOT be
// reported as an empty range, and the voided payment must still surface.
test("voided-only invoice with unrecoverable issue date: voided_payments_present fires, no_records_in_range does not", () => {
  const invoices: Invoice[] = [{ id: "1-seed", customer: "A", number: "INV-1", amount: 100,
    due: "2026-03-01", email: "", phone: "", desc: "", paid: false,
    payments: [{ id: "p1", amount: 50, date: "2026-03-01", method: "cash", voidedAt: "2026-03-02" }] }];
  const codes = collectWarnings({ ...base, invoices }, JAN1, DEC31).map((w) => w.code);
  expect(codes).toContain("voided_payments_present");
  expect(codes).not.toContain("no_records_in_range");
});
