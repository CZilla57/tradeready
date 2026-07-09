const { computeCustomerMix } = require("../utils/customerMix");

function makeInvoice(overrides) {
  return {
    id: "inv1",
    customer: "Alice",
    number: "INV-001",
    amount: 500,
    due: "2026-07-01",
    email: "",
    phone: "",
    desc: "",
    paid: true,
    paidAt: "2026-07-05",
    ...overrides,
  };
}

const JUL_START = new Date(2026, 6, 1);
const JUL_END = new Date(2026, 6, 31, 23, 59, 59);

describe("computeCustomerMix", () => {
  it("returns zeroes when no invoices", () => {
    const result = computeCustomerMix([], JUL_START, JUL_END);
    expect(result).toEqual({ newCount: 0, newRevenue: 0, returningCount: 0, returningRevenue: 0 });
  });

  it("returns zeroes when no paid invoices in period", () => {
    const invoices = [
      makeInvoice({ paid: false, paidAt: undefined }),
    ];
    const result = computeCustomerMix(invoices, JUL_START, JUL_END);
    expect(result.newCount).toBe(0);
    expect(result.returningCount).toBe(0);
  });

  it("classifies a customer as new when first invoice due date is in period", () => {
    const invoices = [
      makeInvoice({ customer: "Alice", due: "2026-07-01", paidAt: "2026-07-05", amount: 300 }),
    ];
    const result = computeCustomerMix(invoices, JUL_START, JUL_END);
    expect(result.newCount).toBe(1);
    expect(result.newRevenue).toBe(300);
    expect(result.returningCount).toBe(0);
  });

  it("classifies a customer as returning when first invoice is before period", () => {
    const invoices = [
      makeInvoice({ id: "i1", customer: "Alice", due: "2026-03-01", paidAt: "2026-03-05", amount: 200 }),
      makeInvoice({ id: "i2", customer: "Alice", due: "2026-07-10", paidAt: "2026-07-15", amount: 400 }),
    ];
    const result = computeCustomerMix(invoices, JUL_START, JUL_END);
    expect(result.returningCount).toBe(1);
    expect(result.returningRevenue).toBe(400);
    expect(result.newCount).toBe(0);
  });

  it("handles mix of new and returning customers", () => {
    const invoices = [
      makeInvoice({ id: "i1", customer: "Alice", due: "2026-01-01", paidAt: "2026-01-05", amount: 100 }),
      makeInvoice({ id: "i2", customer: "Alice", due: "2026-07-10", paidAt: "2026-07-12", amount: 300 }),
      makeInvoice({ id: "i3", customer: "Bob",   due: "2026-07-05", paidAt: "2026-07-06", amount: 500 }),
    ];
    const result = computeCustomerMix(invoices, JUL_START, JUL_END);
    expect(result.newCount).toBe(1);
    expect(result.newRevenue).toBe(500);
    expect(result.returningCount).toBe(1);
    expect(result.returningRevenue).toBe(300);
  });

  it("normalizes customer names (case-insensitive, trimmed)", () => {
    const invoices = [
      makeInvoice({ id: "i1", customer: " Alice ", due: "2026-01-01", paidAt: "2026-01-05", amount: 100 }),
      makeInvoice({ id: "i2", customer: "alice",   due: "2026-07-10", paidAt: "2026-07-12", amount: 200 }),
    ];
    const result = computeCustomerMix(invoices, JUL_START, JUL_END);
    expect(result.returningCount).toBe(1);
    expect(result.returningRevenue).toBe(200);
    expect(result.newCount).toBe(0);
  });

  it("uses paidAt for period revenue bucketing, due for first-invoice detection", () => {
    const invoices = [
      makeInvoice({ customer: "Alice", due: "2026-06-25", paidAt: "2026-07-02", amount: 800 }),
    ];
    const result = computeCustomerMix(invoices, JUL_START, JUL_END);
    expect(result.returningCount).toBe(1);
    expect(result.returningRevenue).toBe(800);
  });

  it("only counts revenue from paid invoices in range", () => {
    const invoices = [
      makeInvoice({ id: "i1", customer: "Alice", due: "2026-07-01", paidAt: "2026-07-05", amount: 300 }),
      makeInvoice({ id: "i2", customer: "Alice", due: "2026-07-15", paid: false, paidAt: undefined, amount: 700 }),
    ];
    const result = computeCustomerMix(invoices, JUL_START, JUL_END);
    expect(result.newCount).toBe(1);
    expect(result.newRevenue).toBe(300);
  });

  it("handles bare YYYY-MM-DD dates as local time", () => {
    const invoices = [
      makeInvoice({ customer: "Alice", due: "2026-07-01", paidAt: "2026-07-01", amount: 100 }),
    ];
    const result = computeCustomerMix(invoices, JUL_START, JUL_END);
    expect(result.newCount).toBe(1);
  });
});
