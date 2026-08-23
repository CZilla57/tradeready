// Tests for utils/profitabilityDisplay.ts — the pure view-model layer behind
// the Job Detail "Estimate vs actual" card, the "What changed?" drill-down,
// and the AddExpenseModal job picker (Phase 13C).
// Expected strings are composed with the real shared formatters (formatMoney /
// formatQuote / formatLaborHint) — these tests pin composition, tones and
// unknown-handling, not the formatters themselves.

import type { ChangeOrder, Expense, Job } from "../types/models";
import { computeJobProfitability } from "../utils/jobProfitability";
import {
  buildCollectionSummary,
  buildProfitabilityRows,
  buildWhatChangedItems,
  PROFITABILITY_STATUSES,
  selectLinkableJobs,
  shouldShowProfitability,
  warningCopy,
} from "../utils/profitabilityDisplay";
import { formatMoney, formatQuote } from "../utils/format";
import { formatLaborHint } from "../utils/scheduleSmarts";

const NOW = new Date(2026, 7, 7, 12, 0, 0);

function makeJob(overrides: Partial<Job> = {}): Job {
  return {
    id: "j1",
    customerId: "c1",
    customerName: "Dana",
    title: "Water heater swap",
    description: "",
    status: "paid",
    scheduledDate: null,
    scheduledStartTime: null,
    scheduledEndTime: null,
    address: "",
    estimateTotal: 966,
    laborHours: 4,
    laborRate: 85,
    materials: [
      { id: "m1", name: "Heater", quantity: 1, unitCost: 200 },
      { id: "m2", name: "Fittings", quantity: 2, unitCost: 50 },
    ],
    materialMarkup: 20,
    overhead: 15,
    margin: 20,
    notes: "",
    invoiceId: null,
    createdAt: "2026-08-01",
    ...overrides,
  };
}

function makeExpense(overrides: Partial<Expense> = {}): Expense {
  return {
    id: "e1",
    createdAt: "2026-08-02",
    description: "Supply-house run",
    amount: 340,
    category: "materials",
    date: "2026-08-02",
    notes: "",
    receiptUri: null,
    ...overrides,
  };
}

const approvedCO: ChangeOrder = {
  id: "co1",
  title: "Extra shutoff valve",
  amount: 200,
  createdAt: "2026-08-02",
  manualDecision: { decision: "approved", decidedAt: "2026-08-02" },
};

function exampleA() {
  const job = makeJob({
    invoiceId: "inv1",
    changeOrders: [approvedCO],
    timeSessions: [
      { start: "2026-08-02T08:00:00.000Z", end: "2026-08-02T11:00:00.000Z" },
      { start: "2026-08-03T08:00:00.000Z", end: "2026-08-03T10:30:00.000Z" },
    ],
  });
  const invoices = [
    {
      id: "inv1",
      customer: "Dana",
      number: "INV-0001",
      amount: 1166,
      due: "2026-08-10",
      email: "",
      phone: "",
      desc: "",
      paid: true,
      paidAt: "2026-08-05",
      jobId: "j1",
      payments: [
        { id: "p1", amount: 300, date: "2026-08-01", method: "check" as const },
        { id: "stripe_cs_1", amount: 866, date: "2026-08-05", method: "stripe" as const },
      ],
    },
  ];
  const expenses = [
    makeExpense({ jobId: "j1" }),
    makeExpense({ id: "e2", jobId: "j1", category: "fuel", amount: 25, description: "Gas" }),
  ];
  const p = computeJobProfitability(job, invoices, expenses, {}, NOW);
  return { job, invoices, expenses, p };
}

/* ------------------------------------------------------------------ */
/* Gates and selection                                                 */
/* ------------------------------------------------------------------ */

describe("shouldShowProfitability", () => {
  test("visible from in_progress onward when an estimate exists", () => {
    for (const status of ["in_progress", "complete", "invoiced", "paid"] as const) {
      expect(PROFITABILITY_STATUSES.has(status)).toBe(true);
      expect(shouldShowProfitability(makeJob({ status }))).toBe(true);
    }
  });

  test("hidden before in_progress and without an estimate", () => {
    for (const status of ["lead", "estimate_sent", "approved", "scheduled", "declined"] as const) {
      expect(shouldShowProfitability(makeJob({ status }))).toBe(false);
    }
    expect(shouldShowProfitability(makeJob({ estimateTotal: 0 }))).toBe(false);
  });
});

describe("selectLinkableJobs", () => {
  test("keeps cost-bearing statuses, drops leads/declined/archived, newest first", () => {
    const jobs = [
      makeJob({ id: "old", status: "approved", createdAt: "2026-07-01" }),
      makeJob({ id: "lead", status: "lead" }),
      makeJob({ id: "declined", status: "declined" }),
      makeJob({ id: "archived", status: "in_progress", archivedAt: "2026-08-01" }),
      makeJob({ id: "new", status: "in_progress", createdAt: "2026-08-05" }),
      makeJob({ id: "paidJob", status: "paid", createdAt: "2026-08-03" }),
    ];
    expect(selectLinkableJobs(jobs).map((j) => j.id)).toEqual(["new", "paidJob", "old"]);
  });

  test("alwaysIncludeId forces a job in even when it would be filtered", () => {
    const jobs = [
      makeJob({ id: "lead", status: "lead", createdAt: "2026-08-06" }),
      makeJob({ id: "ok", status: "approved", createdAt: "2026-08-01" }),
    ];
    expect(selectLinkableJobs(jobs, "lead").map((j) => j.id)).toEqual(["lead", "ok"]);
  });
});

/* ------------------------------------------------------------------ */
/* Rows                                                                */
/* ------------------------------------------------------------------ */

describe("buildProfitabilityRows", () => {
  test("example A: full est/actual/variance rows with tones", () => {
    const { job, p } = exampleA();
    const rows = buildProfitabilityRows(job, p);
    expect(rows.map((r) => r.key)).toEqual([
      "revenue",
      "hours",
      "materials",
      "otherExpenses",
      "profit",
      "hourly",
    ]);

    const byKey = Object.fromEntries(rows.map((r) => [r.key, r]));
    expect(byKey.revenue).toMatchObject({
      estimate: formatQuote(966),
      actual: formatMoney(1166),
      variance: `+${formatMoney(200)}`,
      varianceTone: "good",
    });
    expect(byKey.hours).toMatchObject({
      estimate: formatLaborHint(4),
      actual: formatLaborHint(5.5),
      variance: `+${formatLaborHint(1.5)}`,
      varianceTone: "bad",
    });
    expect(byKey.materials).toMatchObject({
      estimate: formatQuote(300),
      actual: formatMoney(340),
      variance: `+${formatMoney(40)}`,
      varianceTone: "bad",
    });
    expect(byKey.otherExpenses).toMatchObject({
      estimate: "—",
      actual: formatMoney(25),
      variance: null,
      varianceTone: null,
    });
    expect(byKey.profit).toMatchObject({
      estimate: formatQuote(666),
      actual: formatMoney(801),
      variance: `+${formatMoney(135)}`,
      varianceTone: "good",
    });
    expect(byKey.hourly).toMatchObject({
      estimate: `${formatMoney(151.5)}/hr`, // (966 − 360 charged materials) / 4
      actual: `${formatMoney(145.64)}/hr`,
      variance: null,
      varianceTone: null,
    });
  });

  test("legacy job: unknown actuals render as em-dash, no variance chips", () => {
    const job = makeJob({ materials: [], estimateTotal: 600, laborHours: 3, invoiceId: "leg" });
    const invoices = [
      {
        id: "leg",
        customer: "Dana",
        number: "INV-0002",
        amount: 600,
        due: "2026-07-01",
        email: "",
        phone: "",
        desc: "",
        paid: true,
      },
    ];
    const p = computeJobProfitability(job, invoices, [], {}, NOW);
    const byKey = Object.fromEntries(buildProfitabilityRows(job, p).map((r) => [r.key, r]));

    expect(byKey.hours.actual).toBe("—");
    expect(byKey.hours.variance).toBeNull();
    expect(byKey.materials.actual).toBe("—");
    expect(byKey.materials.variance).toBeNull();
    expect(byKey.otherExpenses).toBeUndefined(); // unknown → row omitted
    expect(byKey.profit.variance).toBeNull(); // 600 vs 600, no fake delta
    expect(byKey.hourly.actual).toBe("—");
  });

  test("direct costs (Phase 2/5): planned direct costs show an estimate side and variance", () => {
    const job = makeJob({
      materials: [],
      estimateTotal: 700,
      laborHours: 0,
      laborRate: 0,
      jobCosts: [
        { id: "jc1", label: "Permit", category: "permit", quantity: 1, unitCost: 150, markupPercent: 0, markupPolicy: "passthrough", taxable: false, customerVisible: true },
        { id: "jc2", label: "Sub", category: "subcontractor", quantity: 1, unitCost: 500, markupPercent: 10, markupPolicy: "in_margin_base", taxable: false, customerVisible: true },
      ],
    });
    const expenses = [makeExpense({ id: "e9", jobId: "j1", category: "labor", amount: 520, description: "Sub invoice" })];
    const p = computeJobProfitability(job, [], expenses, {}, NOW);
    const byKey = Object.fromEntries(buildProfitabilityRows(job, p).map((r) => [r.key, r]));

    // estimated direct cost basis = 150 + 500 = 650; actual 520 → came in under.
    expect(byKey.otherExpenses).toMatchObject({
      label: "Direct costs",
      estimate: formatQuote(650),
      actual: formatMoney(520),
      variance: formatMoney(-130),
      varianceTone: "good",
    });
    // Estimated gross profit is honest: 700 − 650 direct = 50 (the markup).
    expect(byKey.profit.estimate).toBe(formatQuote(50));
  });

  test("under-estimate hours and materials tone good; descope credit tone neutral", () => {
    const descope: ChangeOrder = {
      id: "co4",
      title: "Descope",
      amount: -150,
      createdAt: "2026-08-02",
      manualDecision: { decision: "approved", decidedAt: "2026-08-02" },
    };
    const job = makeJob({
      changeOrders: [descope],
      timeSessions: [
        { start: "2026-08-02T08:00:00.000Z", end: "2026-08-02T10:00:00.000Z" },
      ], // 2h vs 4h estimated
    });
    const expenses = [makeExpense({ jobId: "j1", amount: 250 })]; // under 300 est
    const p = computeJobProfitability(job, [], expenses, {}, NOW);
    const byKey = Object.fromEntries(buildProfitabilityRows(job, p).map((r) => [r.key, r]));

    expect(byKey.revenue.variance).toBe(formatMoney(-150));
    expect(byKey.revenue.varianceTone).toBe("neutral");
    expect(byKey.hours.variance).toBe(`-${formatLaborHint(2)}`);
    expect(byKey.hours.varianceTone).toBe("good");
    expect(byKey.materials.variance).toBe(formatMoney(-50));
    expect(byKey.materials.varianceTone).toBe("good");
  });
});

/* ------------------------------------------------------------------ */
/* Collection summary                                                  */
/* ------------------------------------------------------------------ */

describe("buildCollectionSummary", () => {
  test("fully collected", () => {
    const { p } = exampleA();
    expect(buildCollectionSummary(p)).toBe(
      `Collected ${formatMoney(1166)} of ${formatMoney(1166)} invoiced`,
    );
  });

  test("partial adds outstanding; overpayment is explicit", () => {
    const job = makeJob({ status: "invoiced" });
    const partial = computeJobProfitability(
      job,
      [
        {
          id: "inv1",
          customer: "Dana",
          number: "1",
          amount: 500,
          due: "2026-08-10",
          email: "",
          phone: "",
          desc: "",
          paid: false,
          jobId: "j1",
          payments: [{ id: "p1", amount: 200, date: "2026-08-01", method: "cash" as const }],
        },
      ],
      [],
      {},
      NOW,
    );
    expect(buildCollectionSummary(partial)).toBe(
      `Collected ${formatMoney(200)} of ${formatMoney(500)} invoiced · ${formatMoney(300)} outstanding`,
    );

    const over = computeJobProfitability(
      job,
      [
        {
          id: "inv1",
          customer: "Dana",
          number: "1",
          amount: 500,
          due: "2026-08-10",
          email: "",
          phone: "",
          desc: "",
          paid: true,
          jobId: "j1",
          payments: [{ id: "p1", amount: 550, date: "2026-08-01", method: "cash" as const }],
        },
      ],
      [],
      {},
      NOW,
    );
    expect(buildCollectionSummary(over)).toBe(
      `Collected ${formatMoney(550)} of ${formatMoney(500)} invoiced · overpaid ${formatMoney(50)}`,
    );
  });

  test("null when nothing invoiced or collected", () => {
    const p = computeJobProfitability(makeJob({ status: "in_progress" }), [], [], {}, NOW);
    expect(buildCollectionSummary(p)).toBeNull();
  });
});

/* ------------------------------------------------------------------ */
/* What changed                                                        */
/* ------------------------------------------------------------------ */

describe("buildWhatChangedItems", () => {
  test("example A: CO, labor over, each linked expense — in that order", () => {
    const { job, expenses, p } = exampleA();
    const items = buildWhatChangedItems(job, p, expenses);

    expect(items.map((i) => i.key)).toEqual(["co:co1", "hours", "exp:e1", "exp:e2"]);
    expect(items[0]).toMatchObject({
      label: "Change order — Extra shutoff valve",
      amount: `+${formatMoney(200)}`,
      tone: "good",
    });
    expect(items[1]).toMatchObject({
      label: "Labor over estimate",
      amount: `+${formatLaborHint(1.5)}`,
      tone: "bad",
    });
    expect(items[2]).toMatchObject({
      label: "Supply-house run (Materials)",
      amount: formatMoney(340),
      tone: "neutral",
    });
    expect(items[3]).toMatchObject({
      label: "Gas (Fuel & Transport)",
      amount: formatMoney(25),
      tone: "neutral",
    });
  });

  test("outstanding money shows as its own item; empty history is empty", () => {
    const job = makeJob({ status: "invoiced" });
    const p = computeJobProfitability(
      job,
      [
        {
          id: "inv1",
          customer: "Dana",
          number: "1",
          amount: 500,
          due: "2026-08-10",
          email: "",
          phone: "",
          desc: "",
          paid: false,
          jobId: "j1",
          payments: [{ id: "p1", amount: 200, date: "2026-08-01", method: "cash" as const }],
        },
      ],
      [],
      {},
      NOW,
    );
    const items = buildWhatChangedItems(job, p, []);
    expect(items).toEqual([
      { key: "outstanding", label: "Not yet collected", amount: formatMoney(300), tone: "bad" },
    ]);

    const legacy = computeJobProfitability(makeJob(), [], [], {}, NOW);
    expect(buildWhatChangedItems(makeJob(), legacy, [])).toEqual([]);
  });

  test("declined and cancelled change orders never appear", () => {
    const declined: ChangeOrder = {
      id: "co2",
      title: "Declined",
      amount: 500,
      createdAt: "2026-08-02",
      manualDecision: { decision: "declined", decidedAt: "2026-08-02" },
    };
    const cancelled: ChangeOrder = {
      id: "co3",
      title: "Cancelled",
      amount: 999,
      createdAt: "2026-08-02",
      cancelledAt: "2026-08-03",
    };
    const job = makeJob({ changeOrders: [declined, cancelled] });
    const p = computeJobProfitability(job, [], [], {}, NOW);
    expect(buildWhatChangedItems(job, p, [])).toEqual([]);
  });
});

/* ------------------------------------------------------------------ */
/* Warning copy                                                        */
/* ------------------------------------------------------------------ */

test("warningCopy: every warning has distinct, non-empty user copy", () => {
  const all = [
    "hours_untracked",
    "expenses_unlinked",
    "invoice_unlinked",
    "fees_unknown",
    "labor_cost_rate_unset",
    "legacy_invoice_dates",
  ] as const;
  const texts = all.map((w) => warningCopy(w));
  for (const t of texts) {
    expect(typeof t).toBe("string");
    expect(t.length).toBeGreaterThan(10);
  }
  expect(new Set(texts).size).toBe(all.length);
});
