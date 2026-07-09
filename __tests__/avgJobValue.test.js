const { computeAvgJobValue } = require("../utils/avgJobValue");

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
    laborHours: 2,
    laborRate: 50,
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

describe("computeAvgJobValue", () => {
  it("returns zero when no jobs", () => {
    const result = computeAvgJobValue([]);
    expect(result).toEqual({ avgValue: 0, count: 0, totalValue: 0 });
  });

  it("returns zero when no done-status jobs", () => {
    const jobs = [
      makeJob({ status: "lead", estimateTotal: 500 }),
      makeJob({ id: "j2", status: "in_progress", estimateTotal: 800 }),
    ];
    const result = computeAvgJobValue(jobs);
    expect(result.count).toBe(0);
    expect(result.avgValue).toBe(0);
  });

  it("skips jobs with estimateTotal <= 0", () => {
    const jobs = [
      makeJob({ estimateTotal: 0 }),
      makeJob({ id: "j2", estimateTotal: 600 }),
    ];
    const result = computeAvgJobValue(jobs);
    expect(result.count).toBe(1);
    expect(result.avgValue).toBe(600);
  });

  it("averages across complete, invoiced, and paid statuses", () => {
    const jobs = [
      makeJob({ id: "j1", status: "complete", estimateTotal: 300 }),
      makeJob({ id: "j2", status: "invoiced", estimateTotal: 600 }),
      makeJob({ id: "j3", status: "paid", estimateTotal: 900 }),
    ];
    const result = computeAvgJobValue(jobs);
    expect(result.count).toBe(3);
    expect(result.totalValue).toBe(1800);
    expect(result.avgValue).toBe(600);
  });

  it("filters by date range when start/end provided", () => {
    const jobs = [
      makeJob({ id: "j1", createdAt: "2026-06-15", estimateTotal: 400 }),
      makeJob({ id: "j2", createdAt: "2026-07-05", estimateTotal: 800 }),
      makeJob({ id: "j3", createdAt: "2026-07-20", estimateTotal: 1200 }),
    ];
    const start = new Date(2026, 6, 1);
    const end = new Date(2026, 6, 31, 23, 59, 59);

    const result = computeAvgJobValue(jobs, start, end);
    expect(result.count).toBe(2);
    expect(result.totalValue).toBe(2000);
    expect(result.avgValue).toBe(1000);
  });

  it("returns all done jobs when no date range", () => {
    const jobs = [
      makeJob({ id: "j1", createdAt: "2025-01-01", estimateTotal: 500 }),
      makeJob({ id: "j2", createdAt: "2026-07-01", estimateTotal: 1500 }),
      makeJob({ id: "j3", status: "lead", estimateTotal: 999 }),
    ];
    const result = computeAvgJobValue(jobs);
    expect(result.count).toBe(2);
    expect(result.avgValue).toBe(1000);
  });

  it("handles bare YYYY-MM-DD dates as local time", () => {
    const jobs = [
      makeJob({ createdAt: "2026-07-01", estimateTotal: 500 }),
    ];
    const start = new Date(2026, 6, 1);
    const end = new Date(2026, 6, 1, 23, 59, 59);

    const result = computeAvgJobValue(jobs, start, end);
    expect(result.count).toBe(1);
  });
});
