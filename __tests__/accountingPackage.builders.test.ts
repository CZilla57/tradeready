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

test("invoices.csv includes an unrecoverable-date invoice with an in-range payment, sorted last", () => {
  const partial = inv({ id: "1-seed", number: "INV-0000",
    payments: [{ id: "p1", amount: 200, date: "2026-05-01", method: "cash" }] });
  const dated = inv({ payments: [{ id: "p2", amount: 1000, date: "2026-03-05", method: "cash" }] });
  const lines = buildInvoicesCsv([partial, dated], JAN1, DEC31).trimEnd().split("\r\n");
  expect(lines).toHaveLength(3);
  expect(lines[1]).toContain("INV-0001");
  expect(lines[2]).toContain("INV-0000");
});

test("invoices.csv excludes an unrecoverable-date invoice with no in-range payment", () => {
  const noDate = inv({ id: "1-seed", number: "INV-0000" });
  expect(buildInvoicesCsv([noDate], JAN1, DEC31).trimEnd().split("\r\n")).toHaveLength(1);
});

test("invoices.csv header only for an empty list", () => {
  expect(buildInvoicesCsv([], JAN1, DEC31).trimEnd().split("\r\n")).toHaveLength(1);
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

test("payment-activity header only for an empty list", () => {
  expect(buildPaymentActivityCsv([], JAN1, DEC31).trimEnd().split("\r\n")).toHaveLength(1);
});

test("expenses.csv adds a Job column resolved by id", () => {
  const e: Expense = { id: "e1", createdAt: "2026-03-01", description: "Lumber",
    amount: 250.5, category: "materials", date: "2026-03-01", notes: "",
    receiptUri: "file:///r.jpg", jobId: "j1" };
  const row = buildExpensesCsv2([e], JAN1, DEC31, { j1: "Smith Deck" }).trimEnd().split("\r\n")[1];
  expect(row).toBe("2026-03-01,Lumber,Materials,250.50,,Smith Deck,Yes");
});

test("expenses.csv leaves Job blank when jobId is absent or unresolved", () => {
  const e: Expense = { id: "e1", createdAt: "2026-03-01", description: "Lumber",
    amount: 250.5, category: "materials", date: "2026-03-01", notes: "", receiptUri: null };
  const row = buildExpensesCsv2([e], JAN1, DEC31, {}).trimEnd().split("\r\n")[1];
  expect(row).toBe("2026-03-01,Lumber,Materials,250.50,,,No");
});

test("customers.csv emits contact columns", () => {
  const c: Customer = { id: "c1", name: "Jane Smith", email: "j@x.com",
    phone: "555", address: "1 St", notes: "" };
  const row = buildCustomersCsv([c]).trimEnd().split("\r\n")[1];
  expect(row).toBe("Jane Smith,j@x.com,555,1 St,,,");
});

test("customers.csv escapes fields containing commas", () => {
  const c: Customer = { id: "c1", name: "Smith, Jones & Co", email: "", phone: "",
    address: "1 St, Suite 2", notes: "" };
  const row = buildCustomersCsv([c]).trimEnd().split("\r\n")[1];
  expect(row).toBe('"Smith, Jones & Co",,,"1 St, Suite 2",,,');
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

test("line-items.csv header only when there are no line items", () => {
  const csv = buildLineItemsCsv([inv({ paid: true,
    payments: [{ id: "p1", amount: 1000, date: "2026-03-02", method: "cash" }] })], JAN1, DEC31);
  expect(csv.trimEnd().split("\r\n")).toHaveLength(1);
});
