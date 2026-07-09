const { computeSeasonalTrends } = require("../utils/seasonalTrends");

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
    paidAt: "2026-07-01",
    ...overrides,
  };
}

const NOW = new Date(2026, 6, 9); // July 9, 2026

describe("computeSeasonalTrends", () => {
  it("returns 12 months with zeroes when no invoices", () => {
    const result = computeSeasonalTrends([], NOW);
    expect(result.months).toHaveLength(12);
    expect(result.thisYearTotal).toBe(0);
    expect(result.lastYearTotal).toBe(0);
    expect(result.yoyChangePct).toBeNull();
  });

  it("returns 12 months ending at the current month", () => {
    const result = computeSeasonalTrends([], NOW);
    expect(result.months[0].label).toBe("Aug");
    expect(result.months[0].year).toBe(2025);
    expect(result.months[11].label).toBe("Jul");
    expect(result.months[11].year).toBe(2026);
  });

  it("buckets paid invoices into the correct month", () => {
    const invoices = [
      makeInvoice({ id: "i1", paidAt: "2026-07-05", amount: 300 }),
      makeInvoice({ id: "i2", paidAt: "2026-06-15", amount: 200 }),
    ];
    const result = computeSeasonalTrends(invoices, NOW);

    const jul = result.months.find((m) => m.label === "Jul" && m.year === 2026);
    expect(jul.thisYear).toBe(300);

    const jun = result.months.find((m) => m.label === "Jun" && m.year === 2026);
    expect(jun.thisYear).toBe(200);

    expect(result.thisYearTotal).toBe(500);
  });

  it("computes last-year values for the same months", () => {
    const invoices = [
      makeInvoice({ id: "i1", paidAt: "2025-10-10", amount: 400 }),
      makeInvoice({ id: "i2", paidAt: "2026-10-10", amount: 600 }),
    ];
    const result = computeSeasonalTrends(invoices, NOW);

    const oct = result.months.find((m) => m.label === "Oct" && m.year === 2025);
    expect(oct.thisYear).toBe(400);
    expect(oct.lastYear).toBe(0);
  });

  it("uses paidAt over due date for bucketing", () => {
    const invoices = [
      makeInvoice({ due: "2026-01-01", paidAt: "2026-03-15", amount: 100 }),
    ];
    const result = computeSeasonalTrends(invoices, NOW);

    const jan = result.months.find((m) => m.label === "Jan" && m.year === 2026);
    expect(jan.thisYear).toBe(0);

    const mar = result.months.find((m) => m.label === "Mar" && m.year === 2026);
    expect(mar.thisYear).toBe(100);
  });

  it("falls back to due date when paidAt is absent", () => {
    const invoices = [
      makeInvoice({ due: "2026-05-10", paidAt: undefined, amount: 250 }),
    ];
    const result = computeSeasonalTrends(invoices, NOW);

    const may = result.months.find((m) => m.label === "May" && m.year === 2026);
    expect(may.thisYear).toBe(250);
  });

  it("skips unpaid invoices", () => {
    const invoices = [
      makeInvoice({ paid: false, paidAt: undefined, amount: 999 }),
    ];
    const result = computeSeasonalTrends(invoices, NOW);
    expect(result.thisYearTotal).toBe(0);
  });

  it("computes YoY change percentage", () => {
    const invoices = [
      makeInvoice({ id: "i1", paidAt: "2026-03-01", amount: 1000 }),
      makeInvoice({ id: "i2", paidAt: "2025-03-01", amount: 800 }),
    ];
    const result = computeSeasonalTrends(invoices, NOW);
    // Mar 2026 thisYear=1000, lastYear (Mar 2025)=800
    // Mar 2025 is in the window: thisYear=0 (no Mar 2025 paid — wait, i2 is paidAt 2025-03-01)
    // Ah: the window is Aug 2025 - Jul 2026, so Mar 2025 is OUTSIDE the 12-month window.
    // For month Mar in the window, year=2026, so:
    //   thisYear = income in Mar 2026 = 1000
    //   lastYear = income in Mar 2025 = 800
    // thisYearTotal = 1000, lastYearTotal = 800
    expect(result.thisYearTotal).toBe(1000);
    expect(result.lastYearTotal).toBe(800);
    expect(result.yoyChangePct).toBe(25);
  });

  it("returns null yoyChangePct when no last-year data", () => {
    const invoices = [
      makeInvoice({ paidAt: "2026-07-01", amount: 500 }),
    ];
    const result = computeSeasonalTrends(invoices, NOW);
    expect(result.yoyChangePct).toBeNull();
  });
});
