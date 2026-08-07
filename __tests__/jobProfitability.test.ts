// Tests for utils/jobProfitability.ts — the Phase 13 pure estimated-vs-actual
// profitability layer. Vectors T1–T15 from
// docs/superpowers/specs/2026-08-07-job-profitability-design.md §8.
// Unknown ≠ zero: absent data must surface as null + warning, never 0.

import type {
  ChangeOrder,
  Expense,
  Invoice,
  Job,
  Payment,
} from "../types/models";
import {
  computeJobProfitability,
  linkedExpensesForJob,
  linkedInvoicesForJob,
} from "../utils/jobProfitability";
import { summarizeInvoices } from "../utils/invoiceStats";

// Injected clock — local constructor per test convention (never a UTC string).
const NOW = new Date(2026, 7, 7, 12, 0, 0); // 2026-08-07 noon local

/* ------------------------------------------------------------------ */
/* Fixtures                                                            */
/* ------------------------------------------------------------------ */

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
    ], // base cost 300
    materialMarkup: 20,
    overhead: 15,
    margin: 20,
    notes: "",
    invoiceId: null,
    createdAt: "2026-08-01",
    ...overrides,
  };
}

function makeInvoice(overrides: Partial<Invoice> = {}): Invoice {
  return {
    id: "inv1",
    customer: "Dana",
    number: "INV-0001",
    amount: 1166,
    due: "2026-08-10",
    email: "",
    phone: "",
    desc: "",
    paid: false,
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

// 3h + 2.5h closed sessions = 5.5 tracked hours.
const closedSessions = [
  { start: "2026-08-02T08:00:00.000Z", end: "2026-08-02T11:00:00.000Z" },
  { start: "2026-08-03T08:00:00.000Z", end: "2026-08-03T10:30:00.000Z" },
];

const paymentsA: Payment[] = [
  { id: "p1", amount: 300, date: "2026-08-01", method: "check" },
  {
    id: "stripe_cs_1",
    amount: 866,
    date: "2026-08-05",
    method: "stripe",
    stripeSessionId: "cs_1",
  },
];

/** Example A from the design doc: tracked, change-ordered, fully collected. */
function exampleA() {
  const job = makeJob({
    invoiceId: "inv1",
    changeOrders: [approvedCO],
    timeSessions: closedSessions,
  });
  const invoice = makeInvoice({
    jobId: "j1",
    amount: 1166,
    payments: paymentsA,
    paid: true,
    paidAt: "2026-08-05",
  });
  const expenses = [
    makeExpense({ jobId: "j1" }), // materials 340
    makeExpense({ id: "e2", jobId: "j1", category: "fuel", amount: 25 }),
  ];
  return { job, invoices: [invoice], expenses };
}

const NO_RATE = {}; // laborCostRate unset

/* ------------------------------------------------------------------ */
/* T1 — Example A: every figure                                        */
/* ------------------------------------------------------------------ */

describe("computeJobProfitability — example A (tracked + CO + collected)", () => {
  const { job, invoices, expenses } = exampleA();
  const r = computeJobProfitability(job, invoices, expenses, NO_RATE, NOW);

  test("revenue figures", () => {
    expect(r.estimatedRevenue).toBe(966);
    expect(r.changeOrderRevenue).toBe(200);
    expect(r.finalBillable).toBe(1166);
    expect(r.invoicedAmount).toBe(1166);
    expect(r.cashCollected).toBe(1166);
    expect(r.outstandingReceivable).toBe(0);
    expect(r.overpaidAmount).toBe(0);
  });

  test("labor figures (closed-session basis)", () => {
    expect(r.estimatedLaborHours).toBe(4);
    expect(r.billableLaborRate).toBe(85);
    expect(r.actualLaborHours).toBe(5.5);
    expect(r.laborHoursVariance).toBe(1.5);
    expect(r.estimatedOwnerLaborCost).toBeNull();
    expect(r.actualOwnerLaborCost).toBeNull();
  });

  test("materials and direct expenses", () => {
    expect(r.estimatedMaterialCost).toBe(300);
    expect(r.actualMaterialExpense).toBe(340);
    expect(r.otherDirectExpenses).toBe(25);
    expect(r.materialsVariance).toBe(40);
  });

  test("profit figures", () => {
    expect(r.estimatedGrossProfit).toBe(666); // 966 − 300, before owner labor
    expect(r.actualGrossProfitBilled).toBe(801); // 1166 − 340 − 25
    expect(r.actualGrossProfitCash).toBe(801);
    expect(r.effectiveHourlyActual).toBe(145.64); // 801 / 5.5
  });

  test("fees unknown, never invented; warnings exact", () => {
    expect(r.processingFees).toBeNull();
    expect(r.warnings).toEqual(["fees_unknown", "labor_cost_rate_unset"]);
  });
});

/* ------------------------------------------------------------------ */
/* T2 — Example B: legacy job, everything unknown stays unknown        */
/* ------------------------------------------------------------------ */

test("T2: legacy job — nulls + warnings, profit never fakes 100% margin", () => {
  const job = makeJob({
    estimateTotal: 600,
    laborHours: 3,
    materials: [],
    invoiceId: "legacyInv",
    changeOrders: undefined,
    timeSessions: undefined,
  });
  const invoice = makeInvoice({
    id: "legacyInv",
    amount: 600,
    paid: true, // pre-ledger invoice: no payments array, no paidAt
  });
  const r = computeJobProfitability(job, [invoice], [], NO_RATE, NOW);

  expect(r.invoicedAmount).toBe(600);
  expect(r.cashCollected).toBe(600); // legacy fallback intact
  expect(r.outstandingReceivable).toBe(0);
  expect(r.actualLaborHours).toBeNull();
  expect(r.laborHoursVariance).toBeNull();
  expect(r.actualMaterialExpense).toBeNull();
  expect(r.otherDirectExpenses).toBeNull();
  expect(r.materialsVariance).toBeNull();
  expect(r.effectiveHourlyActual).toBeNull();
  expect(r.estimatedGrossProfit).toBe(600);
  expect(r.actualGrossProfitBilled).toBe(600);
  expect(r.warnings).toEqual([
    "hours_untracked",
    "expenses_unlinked",
    "labor_cost_rate_unset",
    "legacy_invoice_dates",
  ]);
});

/* ------------------------------------------------------------------ */
/* T3 — Example C: voided payment out of totals, overpayment explicit  */
/* ------------------------------------------------------------------ */

test("T3: voided payments excluded, overpayment explicit, outstanding clamped", () => {
  const job = makeJob({ status: "invoiced", timeSessions: closedSessions });
  const invoice = makeInvoice({
    jobId: "j1",
    amount: 500,
    payments: [
      { id: "p1", amount: 200, date: "2026-08-01", method: "cash" },
      {
        id: "p2",
        amount: 200,
        date: "2026-08-02",
        method: "cash",
        voidedAt: "2026-08-03",
      },
      { id: "p3", amount: 350, date: "2026-08-04", method: "check" },
    ],
  });
  const r = computeJobProfitability(job, [invoice], [], NO_RATE, NOW);

  expect(r.cashCollected).toBe(550);
  expect(r.outstandingReceivable).toBe(0);
  expect(r.overpaidAmount).toBe(50);
});

/* ------------------------------------------------------------------ */
/* T4 — change-order status gating                                     */
/* ------------------------------------------------------------------ */

test("T4: only approved COs count; declined/cancelled contribute zero; negatives work", () => {
  const declined: ChangeOrder = {
    id: "co2",
    title: "Declined extra",
    amount: 500,
    createdAt: "2026-08-02",
    manualDecision: { decision: "declined", decidedAt: "2026-08-02" },
  };
  const cancelled: ChangeOrder = {
    id: "co3",
    title: "Cancelled extra",
    amount: 999,
    createdAt: "2026-08-02",
    cancelledAt: "2026-08-03",
  };
  const descope: ChangeOrder = {
    id: "co4",
    title: "Descope credit",
    amount: -150,
    createdAt: "2026-08-02",
    manualDecision: { decision: "approved", decidedAt: "2026-08-02" },
  };
  const job = makeJob({ changeOrders: [declined, cancelled, descope] });
  const r = computeJobProfitability(job, [], [], NO_RATE, NOW);

  expect(r.changeOrderRevenue).toBe(-150);
  expect(r.finalBillable).toBe(816); // 966 − 150
});

/* ------------------------------------------------------------------ */
/* T5 / T6 — session basis                                             */
/* ------------------------------------------------------------------ */

test("T5: open session excluded from actual hours (deterministic closed basis)", () => {
  const job = makeJob({
    timeSessions: [
      { start: "2026-08-02T08:00:00.000Z", end: "2026-08-02T10:00:00.000Z" },
      { start: "2026-08-07T08:00:00.000Z", end: null }, // still clocked in
    ],
  });
  const r = computeJobProfitability(job, [], [], NO_RATE, NOW);
  expect(r.actualLaborHours).toBe(2);
  expect(r.warnings).not.toContain("hours_untracked");
});

test("T6: empty and absent timeSessions both mean unknown hours", () => {
  const empty = computeJobProfitability(
    makeJob({ timeSessions: [] }),
    [],
    [],
    NO_RATE,
    NOW,
  );
  const absent = computeJobProfitability(
    makeJob({ timeSessions: undefined }),
    [],
    [],
    NO_RATE,
    NOW,
  );
  for (const r of [empty, absent]) {
    expect(r.actualLaborHours).toBeNull();
    expect(r.laborHoursVariance).toBeNull();
    expect(r.warnings).toContain("hours_untracked");
  }
});

/* ------------------------------------------------------------------ */
/* T7 / T8 — linked-expense data vs no data                            */
/* ------------------------------------------------------------------ */

test("T7: a linked non-materials expense makes materials a real $0, not unknown", () => {
  const job = makeJob();
  const expenses = [
    makeExpense({ id: "e2", jobId: "j1", category: "fuel", amount: 25 }),
  ];
  const r = computeJobProfitability(job, [], expenses, NO_RATE, NOW);

  expect(r.actualMaterialExpense).toBe(0); // data exists → genuinely $0
  expect(r.otherDirectExpenses).toBe(25);
  expect(r.materialsVariance).toBe(-300); // spent nothing vs $300 estimated
  expect(r.warnings).not.toContain("expenses_unlinked");
});

test("T8: unlinked expenses are invisible — nulls + one warning", () => {
  const job = makeJob();
  const expenses = [makeExpense({})]; // no jobId — business overhead
  const r = computeJobProfitability(job, [], expenses, NO_RATE, NOW);

  expect(r.actualMaterialExpense).toBeNull();
  expect(r.otherDirectExpenses).toBeNull();
  expect(
    r.warnings.filter((w) => w === "expenses_unlinked"),
  ).toHaveLength(1);
});

/* ------------------------------------------------------------------ */
/* T9 — double-counting guard                                          */
/* ------------------------------------------------------------------ */

test("T9: estimated materials never enter actual costs", () => {
  const job = makeJob(); // estimated materials base 300, no COs
  const expenses = [makeExpense({ jobId: "j1" })]; // actual materials 340
  const r = computeJobProfitability(job, [], expenses, NO_RATE, NOW);

  // 966 − 340 (actual only). A double-count would give 966 − 640 = 326.
  expect(r.actualGrossProfitBilled).toBe(626);
});

/* ------------------------------------------------------------------ */
/* T10 — invoice linkage union + dedupe + unlinked warning             */
/* ------------------------------------------------------------------ */

describe("T10: invoice linkage", () => {
  test("union of inv.jobId and job.invoiceId, deduped", () => {
    const job = makeJob({ invoiceId: "invA", status: "invoiced" });
    const invA = makeInvoice({ id: "invA", amount: 400 }); // manual: no jobId
    const invB = makeInvoice({ id: "invB", jobId: "j1", amount: 300 });
    const unrelated = makeInvoice({ id: "invC", amount: 999 });
    const linked = linkedInvoicesForJob(job, [invA, invB, unrelated, invA]);

    expect(linked.map((i) => i.id)).toEqual(["invA", "invB"]);

    const r = computeJobProfitability(
      job,
      [invA, invB, unrelated, invA],
      [],
      NO_RATE,
      NOW,
    );
    expect(r.invoicedAmount).toBe(700); // each counted once
    expect(r.warnings).not.toContain("invoice_unlinked");
  });

  test("invoiced/paid job with zero linked invoices warns", () => {
    const job = makeJob({ status: "invoiced", invoiceId: null });
    const manual = makeInvoice({ id: "manual1" }); // no jobId
    const r = computeJobProfitability(job, [manual], [], NO_RATE, NOW);
    expect(r.invoicedAmount).toBe(0);
    expect(r.warnings).toContain("invoice_unlinked");
  });

  test("pre-invoice statuses do not warn about linkage", () => {
    const job = makeJob({ status: "in_progress", invoiceId: null });
    const r = computeJobProfitability(job, [], [], NO_RATE, NOW);
    expect(r.warnings).not.toContain("invoice_unlinked");
  });
});

/* ------------------------------------------------------------------ */
/* T11 — owner labor-cost rate                                         */
/* ------------------------------------------------------------------ */

describe("T11: laborCostRate", () => {
  test("set rate flows into costs; effective hourly unchanged", () => {
    const { job, invoices, expenses } = exampleA();
    const r = computeJobProfitability(
      job,
      invoices,
      expenses,
      { laborCostRate: 40 },
      NOW,
    );

    expect(r.estimatedOwnerLaborCost).toBe(160); // 4 × 40
    expect(r.actualOwnerLaborCost).toBe(220); // 5.5 × 40
    expect(r.estimatedGrossProfit).toBe(506); // 966 − 300 − 160
    expect(r.actualGrossProfitBilled).toBe(581); // 1166 − 365 − 220
    expect(r.actualGrossProfitCash).toBe(581);
    // Owner pay added back: earnings per tracked hour is rate-independent.
    expect(r.effectiveHourlyActual).toBe(145.64);
    expect(r.warnings).toEqual(["fees_unknown"]);
  });

  test("explicit 0 is set (labor costs nothing), not unset", () => {
    const { job, invoices, expenses } = exampleA();
    const r = computeJobProfitability(
      job,
      invoices,
      expenses,
      { laborCostRate: 0 },
      NOW,
    );
    expect(r.estimatedOwnerLaborCost).toBe(0);
    expect(r.actualOwnerLaborCost).toBe(0);
    expect(r.warnings).not.toContain("labor_cost_rate_unset");
  });
});

/* ------------------------------------------------------------------ */
/* T12 — malformed amounts never poison figures                        */
/* ------------------------------------------------------------------ */

test("T12: NaN/Infinity/string amounts coerce; every figure finite or null", () => {
  const job = makeJob({
    estimateTotal: NaN as unknown as number,
    timeSessions: closedSessions,
  });
  const invoice = makeInvoice({
    jobId: "j1",
    amount: "abc" as unknown as number,
    payments: [
      { id: "p1", amount: NaN, date: "2026-08-01", method: "cash" },
      { id: "p2", amount: 100, date: "2026-08-02", method: "cash" },
    ],
  });
  const expenses = [
    makeExpense({ jobId: "j1", amount: Infinity }),
    makeExpense({ id: "e2", jobId: "j1", category: "fuel", amount: 25 }),
  ];
  const r = computeJobProfitability(job, [invoice], expenses, NO_RATE, NOW);

  for (const [key, value] of Object.entries(r)) {
    if (key === "warnings") continue;
    if (value !== null) {
      expect(Number.isFinite(value as number)).toBe(true);
    }
  }
  expect(r.cashCollected).toBe(100); // NaN payment coerced to 0
  expect(r.actualMaterialExpense).toBe(0); // Infinity coerced to 0
  expect(r.otherDirectExpenses).toBe(25);
});

/* ------------------------------------------------------------------ */
/* T13 — no estimate to compare against                                */
/* ------------------------------------------------------------------ */

test("T13: laborHours 0 estimate — actual known, variance null", () => {
  const job = makeJob({
    laborHours: 0,
    timeSessions: [
      { start: "2026-08-02T08:00:00.000Z", end: "2026-08-02T11:00:00.000Z" },
    ],
  });
  const r = computeJobProfitability(job, [], [], NO_RATE, NOW);
  expect(r.actualLaborHours).toBe(3);
  expect(r.laborHoursVariance).toBeNull();
});

/* ------------------------------------------------------------------ */
/* T14 — cent-rounding epsilon                                         */
/* ------------------------------------------------------------------ */

test("T14: 99.999 paid on 100 rounds to zero outstanding", () => {
  const job = makeJob();
  const invoice = makeInvoice({
    jobId: "j1",
    amount: 100,
    payments: [{ id: "p1", amount: 99.999, date: "2026-08-01", method: "cash" }],
  });
  const r = computeJobProfitability(job, [invoice], [], NO_RATE, NOW);
  expect(r.outstandingReceivable).toBe(0);
  expect(r.cashCollected).toBe(100);
});

/* ------------------------------------------------------------------ */
/* T15 — determinism                                                   */
/* ------------------------------------------------------------------ */

test("T15: same inputs + injected clock ⇒ identical results, stable warning order", () => {
  const { job, invoices, expenses } = exampleA();
  const a = computeJobProfitability(job, invoices, expenses, NO_RATE, NOW);
  const b = computeJobProfitability(job, invoices, expenses, NO_RATE, NOW);
  expect(a).toEqual(b);
  expect(a.warnings).toEqual(b.warnings);
});

/* ------------------------------------------------------------------ */
/* Selectors + legacy equivalence                                      */
/* ------------------------------------------------------------------ */

test("linkedExpensesForJob filters strictly by jobId", () => {
  const job = makeJob();
  const mine = makeExpense({ jobId: "j1" });
  const other = makeExpense({ id: "e2", jobId: "j2" });
  const unlinked = makeExpense({ id: "e3" });
  expect(linkedExpensesForJob(job, [mine, other, unlinked])).toEqual([mine]);
});

test("legacy equivalence: revenue figures match summarizeInvoices on mixed data", () => {
  const job = makeJob({ status: "invoiced", invoiceId: "legacyPaid" });
  const linked: Invoice[] = [
    makeInvoice({
      id: "part",
      jobId: "j1",
      amount: 500,
      payments: [
        { id: "p1", amount: 200, date: "2026-08-01", method: "cash" },
        {
          id: "p2",
          amount: 50,
          date: "2026-08-02",
          method: "cash",
          voidedAt: "2026-08-03",
        },
      ],
    }),
    makeInvoice({ id: "legacyPaid", amount: 600, paid: true }),
    makeInvoice({ id: "legacyOpen", jobId: "j1", amount: 300, paid: false }),
  ];
  const r = computeJobProfitability(job, linked, [], NO_RATE, NOW);
  const s = summarizeInvoices(linkedInvoicesForJob(job, linked));

  expect(r.cashCollected).toBe(s.collected);
  expect(r.outstandingReceivable).toBe(s.outstanding);
  expect(r.cashCollected).toBe(800); // 200 + 600, void excluded
  expect(r.outstandingReceivable).toBe(600); // 300 remaining + 300 open
});
