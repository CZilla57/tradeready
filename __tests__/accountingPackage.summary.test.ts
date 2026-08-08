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
