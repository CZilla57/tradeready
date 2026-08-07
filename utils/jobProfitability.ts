// utils/jobProfitability.ts
// Pure per-job estimated-vs-actual profitability figures (Phase 13).
// Design of record: docs/superpowers/specs/2026-08-07-job-profitability-design.md
//
// Consumes the existing money/time primitives — change-order totals
// (utils/changeOrders.ts), the payment ledger (utils/invoicePayments.ts),
// closed-session time math (utils/timeTracking.ts) and the estimate
// breakdown (utils/pricingEngine.ts) — and NEVER re-derives their rules.
// No I/O; injected clock (test convention).
//
// Unknown ≠ zero. Figures that cannot be known from recorded data are null
// and contribute a ProfitWarning; profit figures compute over the KNOWN
// components and carry those warnings (owner decision D6, 2026-08-07) so a
// legacy job renders "no cost data", never a fake 100% margin. Processing
// fees are unknowable today (the Stripe webhook records gross amounts only)
// and are never invented; refunds have no representation (out of scope v1,
// owner decision D3) — a mistaken payment is voided, and overpayment is its
// own explicit figure.

import type { Expense, Invoice, Job, Settings } from "../types/models";
import { approvedChangeOrderTotal, jobBillableTotal } from "./changeOrders";
import {
  amountPaid,
  balanceDue,
  overpaidAmount as invoiceOverpaidAmount,
  roundToCents,
  toAmount,
} from "./invoicePayments";
import { computeEstimateBreakdown } from "./pricingEngine";
import { computeTimeTracking } from "./timeTracking";

/** Machine-readable "this figure is incomplete and here is why" markers. */
export type ProfitWarning =
  | "hours_untracked"
  | "expenses_unlinked"
  | "invoice_unlinked"
  | "fees_unknown"
  | "labor_cost_rate_unset"
  | "legacy_invoice_dates";

/** Canonical emission order — pinned by tests so UI copy is stable. */
const WARNING_ORDER: ProfitWarning[] = [
  "hours_untracked",
  "expenses_unlinked",
  "invoice_unlinked",
  "fees_unknown",
  "labor_cost_rate_unset",
  "legacy_invoice_dates",
];

export interface JobProfitability {
  /* Revenue (dollars, cents-rounded) */
  estimatedRevenue: number;
  changeOrderRevenue: number;
  finalBillable: number;
  invoicedAmount: number;
  cashCollected: number;
  outstandingReceivable: number;
  overpaidAmount: number;
  /** Always null in v1 — no code path knows a processor fee. Never invented. */
  processingFees: number | null;

  /* Labor (hours 2-dp; rates/costs cents-rounded) */
  estimatedLaborHours: number;
  billableLaborRate: number;
  actualLaborHours: number | null;
  laborHoursVariance: number | null;
  estimatedOwnerLaborCost: number | null;
  actualOwnerLaborCost: number | null;

  /* Materials & direct expenses */
  estimatedMaterialCost: number;
  actualMaterialExpense: number | null;
  otherDirectExpenses: number | null;
  materialsVariance: number | null;

  /* Profit */
  estimatedGrossProfit: number;
  actualGrossProfitBilled: number;
  actualGrossProfitCash: number;
  effectiveHourlyActual: number | null;

  warnings: ProfitWarning[];
}

/**
 * The invoices attributable to a job: union of `inv.jobId === job.id` and
 * the invoice `job.invoiceId` points at, deduped by id (an invoice matching
 * both counts once). Manual AddInvoiceScreen invoices carry no jobId and are
 * only attributable through job.invoiceId.
 */
export function linkedInvoicesForJob(job: Job, invoices: Invoice[]): Invoice[] {
  const seen = new Set<string>();
  const linked: Invoice[] = [];
  for (const inv of invoices) {
    if (inv.jobId !== job.id && inv.id !== job.invoiceId) continue;
    if (seen.has(inv.id)) continue;
    seen.add(inv.id);
    linked.push(inv);
  }
  return linked;
}

/** The expenses the owner explicitly linked to this job. Absent jobId = business overhead. */
export function linkedExpensesForJob(job: Job, expenses: Expense[]): Expense[] {
  return expenses.filter((e) => e.jobId === job.id);
}

/** Hours round to 2 dp — the billableLaborHours convention (utils/autoInvoice.ts). */
const roundHours = (hours: number): number => Math.round(hours * 100) / 100;

export function computeJobProfitability(
  job: Job,
  invoices: Invoice[],
  expenses: Expense[],
  settings: Pick<Settings, "laborCostRate">,
  now: Date = new Date(),
): JobProfitability {
  const warnings = new Set<ProfitWarning>();

  /* Revenue --------------------------------------------------------- */
  const estimatedRevenue = roundToCents(toAmount(job.estimateTotal));
  const changeOrderRevenue = approvedChangeOrderTotal(job);
  const finalBillable = jobBillableTotal(job);

  const linked = linkedInvoicesForJob(job, invoices);
  let invoicedAmount = 0;
  let cashCollected = 0;
  let outstandingReceivable = 0;
  let overpaid = 0;
  for (const inv of linked) {
    invoicedAmount += toAmount(inv.amount);
    const collected = amountPaid(inv);
    cashCollected += collected;
    outstandingReceivable += balanceDue(inv);
    overpaid += invoiceOverpaidAmount(inv);

    const ledger = Array.isArray(inv.payments) ? inv.payments : [];
    // Legacy invoice: money collected but no itemised ledger — the implied
    // payment date is paidAt ?? due, so time-bucketed views are approximate.
    if (ledger.length === 0 && collected > 0) {
      warnings.add("legacy_invoice_dates");
    }
    for (const p of ledger) {
      // A real Stripe payment means a processor fee exists that we cannot
      // know (webhook records the gross amount only) — flag, never estimate.
      if (!p.voidedAt && p.method === "stripe" && toAmount(p.amount) > 0) {
        warnings.add("fees_unknown");
      }
    }
  }
  if (linked.length === 0 && (job.status === "invoiced" || job.status === "paid")) {
    warnings.add("invoice_unlinked");
  }

  /* Labor ------------------------------------------------------------ */
  const estimatedLaborHours = toAmount(job.laborHours);
  const billableLaborRate = roundToCents(toAmount(job.laborRate));

  // Closed sessions only — the same deterministic basis billing uses
  // (utils/autoInvoice.ts billableLaborHours); a running session is a live-UI
  // concern, not a profitability input. No sessions at all = unknown, not 0.
  let actualLaborHours: number | null = null;
  if (job.timeSessions && job.timeSessions.length > 0) {
    const t = computeTimeTracking(job.timeSessions, estimatedLaborHours, now.getTime());
    actualLaborHours = roundHours(t.completedMs / 3600000);
  } else {
    warnings.add("hours_untracked");
  }
  const laborHoursVariance =
    actualLaborHours !== null && estimatedLaborHours > 0
      ? roundHours(actualLaborHours - estimatedLaborHours)
      : null;

  // Owner labor-cost rate: 0 is a valid explicit value (labor costs
  // nothing); absent/invalid means unset — never defaulted.
  const rawRate = settings.laborCostRate;
  const ownerRate =
    typeof rawRate === "number" && Number.isFinite(rawRate) && rawRate >= 0
      ? rawRate
      : null;
  if (ownerRate === null) warnings.add("labor_cost_rate_unset");
  const estimatedOwnerLaborCost =
    ownerRate !== null ? roundToCents(estimatedLaborHours * ownerRate) : null;
  const actualOwnerLaborCost =
    ownerRate !== null && actualLaborHours !== null
      ? roundToCents(actualLaborHours * ownerRate)
      : null;

  /* Materials & direct expenses -------------------------------------- */
  // The owner's estimated materials COST is the pre-markup base; the marked-up
  // figure is revenue-side and never enters cost math.
  const estimatedMaterialCost = roundToCents(
    computeEstimateBreakdown(job).materialBaseCost,
  );

  const linkedExp = linkedExpensesForJob(job, expenses);
  let actualMaterialExpense: number | null = null;
  let otherDirectExpenses: number | null = null;
  if (linkedExp.length === 0) {
    warnings.add("expenses_unlinked");
  } else {
    let materials = 0;
    let other = 0;
    for (const e of linkedExp) {
      const amt = toAmount(e.amount);
      if (e.category === "materials") materials += amt;
      else other += amt;
    }
    actualMaterialExpense = roundToCents(materials);
    otherDirectExpenses = roundToCents(other);
  }
  const materialsVariance =
    actualMaterialExpense !== null
      ? roundToCents(actualMaterialExpense - estimatedMaterialCost)
      : null;

  /* Profit ------------------------------------------------------------ */
  // Gross profit = revenue − DIRECT costs. Actual costs come ONLY from
  // linked expenses (+ owner labor when costed) — estimated materials never
  // enter actuals (the double-counting rule); business overhead (unlinked
  // expenses) stays in the Money tab's P&L, not here.
  const estimatedGrossProfit = roundToCents(
    estimatedRevenue - estimatedMaterialCost - (estimatedOwnerLaborCost ?? 0),
  );
  const knownActualCosts =
    (actualMaterialExpense ?? 0) +
    (otherDirectExpenses ?? 0) +
    (actualOwnerLaborCost ?? 0);
  const actualGrossProfitBilled = roundToCents(finalBillable - knownActualCosts);
  const actualGrossProfitCash = roundToCents(
    roundToCents(cashCollected) - knownActualCosts,
  );
  // What the owner actually earned per tracked hour, before paying
  // themselves (owner labor cost added back so the figure is rate-independent).
  const effectiveHourlyActual =
    actualLaborHours !== null && actualLaborHours > 0
      ? roundToCents(
          (actualGrossProfitBilled + (actualOwnerLaborCost ?? 0)) /
            actualLaborHours,
        )
      : null;

  return {
    estimatedRevenue,
    changeOrderRevenue,
    finalBillable,
    invoicedAmount: roundToCents(invoicedAmount),
    cashCollected: roundToCents(cashCollected),
    outstandingReceivable: roundToCents(outstandingReceivable),
    overpaidAmount: roundToCents(overpaid),
    processingFees: null,
    estimatedLaborHours,
    billableLaborRate,
    actualLaborHours,
    laborHoursVariance,
    estimatedOwnerLaborCost,
    actualOwnerLaborCost,
    estimatedMaterialCost,
    actualMaterialExpense,
    otherDirectExpenses,
    materialsVariance,
    estimatedGrossProfit,
    actualGrossProfitBilled,
    actualGrossProfitCash,
    effectiveHourlyActual,
    warnings: WARNING_ORDER.filter((w) => warnings.has(w)),
  };
}
