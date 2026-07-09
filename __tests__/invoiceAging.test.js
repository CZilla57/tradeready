const { computeInvoiceAging } = require("../utils/invoiceAging");

function makeInvoice(overrides) {
  return {
    id: "inv1",
    customer: "Alice",
    number: "INV-001",
    amount: 500,
    due: "2026-06-01",
    email: "",
    phone: "",
    desc: "",
    paid: true,
    paidAt: "2026-06-11",
    ...overrides,
  };
}

describe("computeInvoiceAging", () => {
  it("returns zero when no invoices", () => {
    const result = computeInvoiceAging([]);
    expect(result).toEqual({ avgDays: 0, paidCount: 0, customers: [] });
  });

  it("skips unpaid invoices", () => {
    const result = computeInvoiceAging([
      makeInvoice({ paid: false, paidAt: undefined }),
    ]);
    expect(result.paidCount).toBe(0);
  });

  it("skips paid invoices without paidAt", () => {
    const result = computeInvoiceAging([
      makeInvoice({ paid: true, paidAt: undefined }),
    ]);
    expect(result.paidCount).toBe(0);
  });

  it("computes days from due to paidAt", () => {
    const result = computeInvoiceAging([
      makeInvoice({ due: "2026-06-01", paidAt: "2026-06-11" }),
    ]);
    expect(result.avgDays).toBe(10);
    expect(result.paidCount).toBe(1);
  });

  it("handles early payment (negative days)", () => {
    const result = computeInvoiceAging([
      makeInvoice({ due: "2026-06-15", paidAt: "2026-06-10" }),
    ]);
    expect(result.avgDays).toBe(-5);
  });

  it("handles same-day payment", () => {
    const result = computeInvoiceAging([
      makeInvoice({ due: "2026-06-01", paidAt: "2026-06-01" }),
    ]);
    expect(result.avgDays).toBe(0);
  });

  it("averages across multiple invoices", () => {
    const invoices = [
      makeInvoice({ id: "i1", due: "2026-06-01", paidAt: "2026-06-11" }), // 10d
      makeInvoice({ id: "i2", due: "2026-06-01", paidAt: "2026-06-21" }), // 20d
    ];
    const result = computeInvoiceAging(invoices);
    expect(result.avgDays).toBe(15);
    expect(result.paidCount).toBe(2);
  });

  it("groups by customer and sorts slowest first", () => {
    const invoices = [
      makeInvoice({ id: "i1", customer: "Alice", due: "2026-06-01", paidAt: "2026-06-06", amount: 100 }), // 5d
      makeInvoice({ id: "i2", customer: "Bob",   due: "2026-06-01", paidAt: "2026-06-21", amount: 200 }), // 20d
      makeInvoice({ id: "i3", customer: "Alice", due: "2026-06-10", paidAt: "2026-06-25", amount: 300 }), // 15d
    ];
    const result = computeInvoiceAging(invoices);

    expect(result.customers).toHaveLength(2);
    expect(result.customers[0].name).toBe("Bob");
    expect(result.customers[0].avgDays).toBe(20);
    expect(result.customers[0].invoiceCount).toBe(1);
    expect(result.customers[0].totalAmount).toBe(200);

    expect(result.customers[1].name).toBe("Alice");
    expect(result.customers[1].avgDays).toBe(10); // (5+15)/2
    expect(result.customers[1].invoiceCount).toBe(2);
    expect(result.customers[1].totalAmount).toBe(400);
  });

  it("handles bare YYYY-MM-DD as local time", () => {
    const result = computeInvoiceAging([
      makeInvoice({ due: "2026-07-01", paidAt: "2026-07-01" }),
    ]);
    expect(result.avgDays).toBe(0);
  });

  it("skips invoices with missing due date", () => {
    const result = computeInvoiceAging([
      makeInvoice({ due: "", paidAt: "2026-06-11" }),
    ]);
    expect(result.paidCount).toBe(0);
  });
});
