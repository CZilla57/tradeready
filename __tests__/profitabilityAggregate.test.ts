// Tests for utils/profitabilityAggregate.ts — trailing completed-job
// profitability history (Phase 13D): the Money tab aggregate card's numbers
// and the PricingCalculator "reality check" warnings.
// Suppression rule: history warnings need >= MIN_HISTORY_JOBS jobs of real
// data per metric — never a lecture built on one job.

import type { Expense, Job } from "../types/models";
import {
  computeProfitabilityHistory,
  getHistoryWarnings,
  MIN_HISTORY_JOBS,
  type ProfitabilityHistory,
} from "../utils/profitabilityAggregate";
import { buildHistorySummaryRows } from "../utils/profitabilityDisplay";
import { formatMoney } from "../utils/format";
import { formatLaborHint } from "../utils/scheduleSmarts";

const NOW = new Date(2026, 7, 7, 12, 0, 0);

function makeJob(overrides: Partial<Job> = {}): Job {
  return {
    id: "j1",
    customerId: "c1",
    customerName: "Dana",
    title: "Job",
    description: "",
    status: "paid",
    scheduledDate: null,
    scheduledStartTime: null,
    scheduledEndTime: null,
    address: "",
    estimateTotal: 1000,
    laborHours: 4,
    laborRate: 85,
    materials: [],
    materialMarkup: 20,
    overhead: 15,
    margin: 20,
    notes: "",
    invoiceId: null,
    createdAt: "2026-08-01",
    ...overrides,
  };
}

/** Closed sessions totalling `hours`, starting 8am UTC. */
function sessions(hours: number) {
  const startMs = Date.parse("2026-08-02T08:00:00.000Z");
  return [
    {
      start: new Date(startMs).toISOString(),
      end: new Date(startMs + hours * 3600000).toISOString(),
    },
  ];
}

/* ------------------------------------------------------------------ */
/* computeProfitabilityHistory                                         */
/* ------------------------------------------------------------------ */

describe("computeProfitabilityHistory", () => {
  // H1: 1000 est, 4h est, 4h actual → hourly 250, overrun 0
  // H2:  800 est, 4h est, 5h actual → hourly 160, overrun +1
  // H3:  600 est, 2h est, 2.5h actual → hourly 240, overrun +0.5
  // H4: in_progress (excluded), H5: done but no data, H6: archived (excluded),
  // H7: done but no estimate (excluded)
  const jobs: Job[] = [
    makeJob({ id: "h1", estimateTotal: 1000, laborHours: 4, timeSessions: sessions(4) }),
    makeJob({ id: "h2", estimateTotal: 800, laborHours: 4, timeSessions: sessions(5) }),
    makeJob({ id: "h3", estimateTotal: 600, laborHours: 2, timeSessions: sessions(2.5) }),
    makeJob({ id: "h4", status: "in_progress", timeSessions: sessions(9) }),
    makeJob({ id: "h5" }),
    makeJob({ id: "h6", archivedAt: "2026-08-01", timeSessions: sessions(9) }),
    makeJob({ id: "h7", estimateTotal: 0, timeSessions: sessions(9) }),
  ];
  const h = computeProfitabilityHistory(jobs, [], [], {}, NOW);

  test("counts: done jobs with estimates, and how many carry data", () => {
    expect(h.doneJobs).toBe(4); // h1, h2, h3, h5
    expect(h.jobsWithData).toBe(3); // h5 has neither hours nor expenses
  });

  test("median effective hourly and labor overrun from jobs with data", () => {
    expect(h.hourlyCount).toBe(3);
    expect(h.medianEffectiveHourly).toBe(240); // median(250, 160, 240)
    expect(h.laborCount).toBe(3);
    expect(h.medianLaborOverrunHours).toBe(0.5); // median(0, 1, 0.5)
  });

  test("materials medians null when no expenses are linked anywhere", () => {
    expect(h.materialsCount).toBe(0);
    expect(h.medianMaterialsOverrunRatio).toBeNull();
    expect(h.medianMaterialsVariance).toBeNull();
  });

  test("even-count median averages the middle pair", () => {
    const jobs2 = [
      makeJob({ id: "a", estimateTotal: 400, laborHours: 2, timeSessions: sessions(2) }), // 200/hr
      makeJob({ id: "b", estimateTotal: 400, laborHours: 4, timeSessions: sessions(4) }), // 100/hr
    ];
    const h2 = computeProfitabilityHistory(jobs2, [], [], {}, NOW);
    expect(h2.medianEffectiveHourly).toBe(150);
  });

  test("materials ratio and variance from linked expenses", () => {
    const withMaterials = [
      makeJob({
        id: "m1",
        estimateTotal: 1000,
        laborHours: 4,
        timeSessions: sessions(4),
        materials: [{ id: "x", name: "Parts", quantity: 1, unitCost: 200 }],
      }),
    ];
    const expenses: Expense[] = [
      {
        id: "e1",
        createdAt: "2026-08-02",
        description: "Parts run",
        amount: 260,
        category: "materials",
        date: "2026-08-02",
        notes: "",
        receiptUri: null,
        jobId: "m1",
      },
    ];
    const h3 = computeProfitabilityHistory(withMaterials, [], expenses, {}, NOW);
    expect(h3.materialsCount).toBe(1);
    expect(h3.medianMaterialsOverrunRatio).toBe(1.3); // 260 / 200
    expect(h3.medianMaterialsVariance).toBe(60);
  });
});

/* ------------------------------------------------------------------ */
/* getHistoryWarnings                                                  */
/* ------------------------------------------------------------------ */

function historyStub(overrides: Partial<ProfitabilityHistory> = {}): ProfitabilityHistory {
  return {
    doneJobs: 5,
    jobsWithData: 4,
    hourlyCount: 3,
    medianEffectiveHourly: 240,
    laborCount: 3,
    medianLaborOverrunHours: 0.5,
    materialsCount: 3,
    medianMaterialsOverrunRatio: 1.3,
    medianMaterialsVariance: 60,
    ...overrides,
  };
}

// The §2.1 worked example's forward-math shape: subtotal 700, overhead 105,
// profit 161, materials base 300, effective 151.50/hr, target margin 20.
const EST = {
  effectiveHourlyRate: 300,
  materialBaseCost: 300,
  subtotal: 700,
  overheadCost: 105,
  profit: 161,
  marginPercent: 20,
};

describe("getHistoryWarnings", () => {
  test("hourly reality check fires when history median is below the projection", () => {
    const warnings = getHistoryWarnings(historyStub(), EST);
    const hourly = warnings.find((w) => w.includes(`${formatMoney(240)}/hr`));
    expect(hourly).toBeDefined();
    expect(hourly).toContain(`${formatMoney(300)}/hr`);
  });

  test("hourly warning silent when history is within 5% or above", () => {
    const close = getHistoryWarnings(
      historyStub({ medianEffectiveHourly: 240 }),
      { ...EST, effectiveHourlyRate: 245 },
    );
    expect(close.find((w) => w.includes("/hr"))).toBeUndefined();
    const better = getHistoryWarnings(
      historyStub({ medianEffectiveHourly: 400 }),
      EST,
    );
    expect(better.find((w) => w.includes("/hr"))).toBeUndefined();
  });

  test("materials overrun fires when it would sink margin below target − 3pts", () => {
    // extra = 300 × 0.3 = 90 → implied (161−90)/805 ≈ 8.8% vs target 20
    const warnings = getHistoryWarnings(
      historyStub({ medianEffectiveHourly: null, hourlyCount: 0 }),
      EST,
    );
    expect(warnings).toHaveLength(1);
    expect(warnings[0]).toContain("Materials");
    expect(warnings[0]).toContain(formatMoney(90));
  });

  test("materials warning silent when overrun is small, ratio ≤ 1, or no materials", () => {
    // ratio 1.05 → extra 15 → implied (161−15)/805 ≈ 18.1% > 17 → silent
    expect(
      getHistoryWarnings(
        historyStub({ hourlyCount: 0, medianMaterialsOverrunRatio: 1.05 }),
        EST,
      ),
    ).toHaveLength(0);
    expect(
      getHistoryWarnings(
        historyStub({ hourlyCount: 0, medianMaterialsOverrunRatio: 0.9 }),
        EST,
      ),
    ).toHaveLength(0);
    expect(
      getHistoryWarnings(historyStub({ hourlyCount: 0 }), { ...EST, materialBaseCost: 0 }),
    ).toHaveLength(0);
  });

  test("everything suppressed below MIN_HISTORY_JOBS per metric", () => {
    expect(MIN_HISTORY_JOBS).toBe(3);
    const thin = historyStub({ hourlyCount: 2, materialsCount: 2 });
    expect(getHistoryWarnings(thin, EST)).toHaveLength(0);
  });
});

/* ------------------------------------------------------------------ */
/* buildHistorySummaryRows (Money card strings)                        */
/* ------------------------------------------------------------------ */

describe("buildHistorySummaryRows", () => {
  test("full history renders labor, materials and hourly rows", () => {
    const rows = buildHistorySummaryRows(historyStub());
    expect(rows.map((r) => r.key)).toEqual(["labor", "materials", "hourly"]);
    expect(rows[0].value).toBe(`+${formatLaborHint(0.5)} over`);
    expect(rows[1].value).toBe(`+${formatMoney(60)} over`);
    expect(rows[2].value).toBe(`${formatMoney(240)}/hr`);
  });

  test("under-estimate history reads as under; zero reads on-estimate", () => {
    const rows = buildHistorySummaryRows(
      historyStub({ medianLaborOverrunHours: -0.5, medianMaterialsVariance: 0 }),
    );
    expect(rows[0].value).toBe(`${formatLaborHint(0.5)} under`);
    expect(rows[1].value).toBe("on estimate");
  });

  test("unknown metrics are omitted, not zero-filled", () => {
    const rows = buildHistorySummaryRows(
      historyStub({
        medianLaborOverrunHours: null,
        laborCount: 0,
        medianMaterialsVariance: null,
        materialsCount: 0,
      }),
    );
    expect(rows.map((r) => r.key)).toEqual(["hourly"]);
  });
});
