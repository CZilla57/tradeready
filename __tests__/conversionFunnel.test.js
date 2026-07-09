import { computeConversionFunnel } from "../utils/conversionFunnel";

const job = (status, overrides) => ({
  id: `j${Math.random()}`,
  status,
  customerName: "Test",
  customerId: "",
  estimateTotal: 0,
  createdAt: "2026-01-01",
  ...overrides,
});

describe("computeConversionFunnel", () => {
  test("empty jobs array returns zero counts and null winRate", () => {
    const result = computeConversionFunnel([]);
    expect(result.totalJobs).toBe(0);
    expect(result.winRate).toBeNull();
    expect(result.stages).toHaveLength(6);
    result.stages.forEach((s) => {
      expect(s.count).toBe(0);
      expect(s.rate).toBeNull();
    });
  });

  test("single lead job counts only in lead stage", () => {
    const result = computeConversionFunnel([job("lead")]);
    expect(result.stages[0].count).toBe(1); // lead
    expect(result.stages[1].count).toBe(0); // estimate_sent
    expect(result.totalJobs).toBe(1);
    expect(result.winRate).toBeNull();
  });

  test("cumulative counting — a complete job counts in all 6 stages", () => {
    const result = computeConversionFunnel([job("complete")]);
    result.stages.forEach((s) => {
      expect(s.count).toBe(1);
    });
  });

  test("invoiced/paid jobs (beyond displayed stages) still count in all 6", () => {
    const result = computeConversionFunnel([job("invoiced"), job("paid")]);
    result.stages.forEach((s) => {
      expect(s.count).toBe(2);
    });
    expect(result.totalJobs).toBe(2);
  });

  test("conversion rates are computed correctly", () => {
    const jobs = [
      job("lead"),
      job("lead"),
      job("estimate_sent"),
      job("estimate_sent"),
      job("approved"),
    ];
    // Reached counts: lead=5, estimate_sent=3, approved=1, scheduled=0, ...
    const result = computeConversionFunnel(jobs);
    expect(result.stages[0].count).toBe(5); // lead
    expect(result.stages[0].rate).toBeNull(); // first stage has no rate
    expect(result.stages[1].count).toBe(3); // estimate_sent
    expect(result.stages[1].rate).toBeCloseTo(3 / 5);
    expect(result.stages[2].count).toBe(1); // approved
    expect(result.stages[2].rate).toBeCloseTo(1 / 3);
    expect(result.stages[3].count).toBe(0); // scheduled
    expect(result.stages[3].rate).toBeCloseTo(0); // 0/1 = 0
  });

  test("rate is null when previous stage count is zero", () => {
    // Edge case: no jobs reached estimate_sent, so approved rate is null
    const result = computeConversionFunnel([job("lead")]);
    expect(result.stages[2].rate).toBeNull(); // approved: 0/0
  });

  test("winRate = approved / estimate_sent", () => {
    const jobs = [
      job("estimate_sent"),
      job("estimate_sent"),
      job("approved"),
      job("approved"),
      job("complete"),
    ];
    // estimate_sent reached = 5 (all), approved reached = 3
    const result = computeConversionFunnel(jobs);
    expect(result.winRate).toBeCloseTo(3 / 5);
  });

  test("stages carry correct labels from JOB_STATUSES", () => {
    const result = computeConversionFunnel([]);
    const labels = result.stages.map((s) => s.label);
    expect(labels).toEqual([
      "Lead",
      "Estimate sent",
      "Approved",
      "Scheduled",
      "In Progress",
      "Complete",
    ]);
  });

  test("mixed pipeline produces descending funnel shape", () => {
    const jobs = [
      job("lead"),
      job("lead"),
      job("lead"),
      job("estimate_sent"),
      job("estimate_sent"),
      job("approved"),
      job("scheduled"),
      job("in_progress"),
      job("complete"),
      job("paid"),
    ];
    const counts = computeConversionFunnel(jobs).stages.map((s) => s.count);
    // Each stage count should be >= the next
    for (let i = 0; i < counts.length - 1; i++) {
      expect(counts[i]).toBeGreaterThanOrEqual(counts[i + 1]);
    }
  });
});
