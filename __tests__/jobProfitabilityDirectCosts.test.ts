// Phase 5 — direct costs (Phase 2) in the estimated-vs-actual profitability
// layer. The estimate side must subtract estimated direct costs, or a job with
// a pass-through/subcontractor cost would report that cost as fabricated profit.

import type { Expense, Invoice, Job, JobCost } from "../types/models";
import { computeJobProfitability } from "../utils/jobProfitability";

const NOW = new Date(2026, 7, 7, 12, 0, 0);

function makeJob(overrides: Partial<Job> = {}): Job {
  return {
    id: "j1",
    customerId: "c1",
    customerName: "Dana",
    title: "Panel + permit",
    description: "",
    status: "complete",
    scheduledDate: null,
    scheduledStartTime: null,
    scheduledEndTime: null,
    address: "",
    estimateTotal: 700,
    laborHours: 0,
    laborRate: 0,
    materials: [],
    materialMarkup: 0,
    overhead: 0,
    margin: 0,
    notes: "",
    invoiceId: null,
    createdAt: "2026-08-01",
    ...overrides,
  };
}

// permit $150 passed through at cost + subcontractor $500 with 10% markup.
// Priced total (700) = 550 margin-base (500×1.1) + 150 pass-through.
const jobCosts: JobCost[] = [
  { id: "jc1", label: "Permit", category: "permit", quantity: 1, unitCost: 150, markupPercent: 0, markupPolicy: "passthrough", taxable: false, customerVisible: true },
  { id: "jc2", label: "Sub", category: "subcontractor", quantity: 1, unitCost: 500, markupPercent: 10, markupPolicy: "in_margin_base", taxable: false, customerVisible: true },
];

describe("job profitability — estimated direct costs", () => {
  test("estimatedDirectCost is the raw cost basis (Σ qty × unitCost), markup excluded", () => {
    const job = makeJob({ jobCosts });
    const p = computeJobProfitability(job, [], [], {}, NOW);
    // 150 permit + 500 subcontractor (the $50 markup is margin, not cost)
    expect(p.estimatedDirectCost).toBe(650);
  });

  test("estimated gross profit subtracts estimated direct costs (no fabricated profit)", () => {
    const job = makeJob({ jobCosts });
    const p = computeJobProfitability(job, [], [], {}, NOW);
    // revenue 700 − materials 0 − direct 650 − owner labor 0 = 50 (the markup)
    expect(p.estimatedGrossProfit).toBe(50);
  });

  test("directCostVariance compares actual non-materials expenses to the estimate", () => {
    const job = makeJob({ jobCosts });
    const expenses: Expense[] = [
      { id: "e1", createdAt: "2026-08-05", description: "Sub invoice", amount: 520, category: "labor", date: "2026-08-05", notes: "", receiptUri: null, jobId: "j1" },
    ];
    const p = computeJobProfitability(job, [], expenses, {}, NOW);
    expect(p.otherDirectExpenses).toBe(520);
    // actual 520 − estimate 650 = −130 (came in under)
    expect(p.directCostVariance).toBe(-130);
  });

  test("variance is null when no expenses are linked (unknown ≠ zero)", () => {
    const job = makeJob({ jobCosts });
    const p = computeJobProfitability(job, [], [], {}, NOW);
    expect(p.directCostVariance).toBeNull();
  });
});

describe("job profitability — backward compatibility", () => {
  test("a job with no jobCosts reports zero estimated direct cost and unchanged profit", () => {
    const job = makeJob({ estimateTotal: 300, jobCosts: undefined });
    const p = computeJobProfitability(job, [] as Invoice[], [], {}, NOW);
    expect(p.estimatedDirectCost).toBe(0);
    // revenue 300 − materials 0 − direct 0 − owner labor 0 = 300 (unchanged)
    expect(p.estimatedGrossProfit).toBe(300);
    expect(p.directCostVariance).toBeNull();
  });
});
