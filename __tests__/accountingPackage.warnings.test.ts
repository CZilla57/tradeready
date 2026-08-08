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
