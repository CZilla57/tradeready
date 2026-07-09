const { computeRevenueByType } = require("../utils/revenueByType");

function makeJob(overrides) {
  return {
    id: "j1",
    customerId: "c1",
    customerName: "Test",
    title: "Job",
    description: "",
    status: "complete",
    scheduledDate: null,
    scheduledStartTime: null,
    scheduledEndTime: null,
    address: "",
    estimateTotal: 1000,
    laborHours: 4,
    laborRate: 100,
    materials: [],
    materialMarkup: 0,
    overhead: 15,
    margin: 20,
    notes: "",
    invoiceId: null,
    createdAt: "2026-07-01",
    ...overrides,
  };
}

describe("computeRevenueByType", () => {
  it("returns zero when no jobs", () => {
    const result = computeRevenueByType([]);
    expect(result).toEqual({ totalRevenue: 0, jobCount: 0, components: [] });
  });

  it("skips non-done jobs", () => {
    const result = computeRevenueByType([
      makeJob({ status: "lead" }),
      makeJob({ id: "j2", status: "in_progress" }),
    ]);
    expect(result.jobCount).toBe(0);
  });

  it("skips jobs with zero estimateTotal", () => {
    const result = computeRevenueByType([
      makeJob({ estimateTotal: 0 }),
    ]);
    expect(result.jobCount).toBe(0);
  });

  it("breaks down labor-only job", () => {
    // laborCost = 4h * $100 = $400, materials = 0, overhead = 1000 - 400 = 600
    const result = computeRevenueByType([makeJob()]);
    expect(result.jobCount).toBe(1);
    expect(result.totalRevenue).toBe(1000);

    const labor = result.components.find((c) => c.label === "Labor");
    expect(labor.total).toBe(400);
    expect(labor.pct).toBe(40);

    const overhead = result.components.find((c) => c.label === "Overhead & Profit");
    expect(overhead.total).toBe(600);
    expect(overhead.pct).toBe(60);

    expect(result.components.find((c) => c.label === "Materials")).toBeUndefined();
  });

  it("includes materials when present", () => {
    const job = makeJob({
      estimateTotal: 1000,
      laborHours: 2,
      laborRate: 100,
      materials: [{ id: "m1", name: "Wood", quantity: 10, unitCost: 20 }],
      materialMarkup: 50,
    });
    // labor = 200, materialBase = 200, materialCost = 200 * 1.5 = 300
    // overhead = 1000 - 200 - 300 = 500
    const result = computeRevenueByType([job]);
    expect(result.totalRevenue).toBe(1000);

    const labor = result.components.find((c) => c.label === "Labor");
    expect(labor.total).toBe(200);

    const materials = result.components.find((c) => c.label === "Materials");
    expect(materials.total).toBe(300);

    const overhead = result.components.find((c) => c.label === "Overhead & Profit");
    expect(overhead.total).toBe(500);
  });

  it("aggregates across multiple done-status jobs", () => {
    const jobs = [
      makeJob({ id: "j1", status: "complete", estimateTotal: 500, laborHours: 2, laborRate: 100 }),
      makeJob({ id: "j2", status: "invoiced", estimateTotal: 800, laborHours: 4, laborRate: 100 }),
      makeJob({ id: "j3", status: "paid", estimateTotal: 300, laborHours: 1, laborRate: 100 }),
    ];
    // labor: 200 + 400 + 100 = 700
    // overhead: 300 + 400 + 200 = 900
    const result = computeRevenueByType(jobs);
    expect(result.jobCount).toBe(3);
    expect(result.totalRevenue).toBe(1600);

    const labor = result.components.find((c) => c.label === "Labor");
    expect(labor.total).toBe(700);
  });

  it("clamps negative overhead to zero", () => {
    // If laborCost > estimateTotal, overheadLine goes negative
    const job = makeJob({ estimateTotal: 100, laborHours: 10, laborRate: 100 });
    // labor = 1000, overhead = 100 - 1000 = -900 → clamped to 0
    const result = computeRevenueByType([job]);
    expect(result.totalRevenue).toBe(1000);

    const overhead = result.components.find((c) => c.label === "Overhead & Profit");
    expect(overhead).toBeUndefined();
  });

  it("omits components with zero total", () => {
    // No labor, no materials → only overhead
    const job = makeJob({ laborHours: 0, laborRate: 0, materials: [] });
    const result = computeRevenueByType([job]);
    expect(result.components).toHaveLength(1);
    expect(result.components[0].label).toBe("Overhead & Profit");
  });
});
