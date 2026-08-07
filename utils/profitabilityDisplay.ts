// utils/profitabilityDisplay.ts
// Pure view-model layer for the Phase 13C profitability UI: the Job Detail
// "Estimate vs actual" card rows, the collection summary line, the "What
// changed?" drill-down items, the AddExpenseModal job picker selection, and
// the user-facing copy for ProfitWarning markers.
// Design of record: docs/superpowers/specs/2026-08-07-job-profitability-design.md §9.
//
// Presentation only — every dollar/hour figure comes from
// utils/jobProfitability.ts; nothing here re-derives money math. Formatting
// composes the shared primitives (formatMoney / formatQuote /
// formatLaborHint) per the actual-vs-proposed formatter rule: estimate-side
// figures are quotes (formatQuote), actual-side figures are real money
// (formatMoney). Unknown figures render as "—", never $0.

import type { Expense, ExpenseCategoryId, Job, JobStatus } from "../types/models";
import type { JobProfitability, ProfitWarning } from "./jobProfitability";
import { changeOrderStatus } from "./changeOrders";
import { computeEstimateBreakdown } from "./pricingEngine";
import { roundToCents, toAmount } from "./invoicePayments";
import { formatMoney, formatQuote } from "./format";
import { formatLaborHint } from "./scheduleSmarts";
import { EXPENSE_CATEGORIES } from "./moneyUtils";
import { isArchived } from "./archive";

export type VarianceTone = "good" | "bad" | "neutral";

export interface ProfitRowVM {
  key: string;
  label: string;
  /** "—" when the estimate side has no figure. */
  estimate: string;
  /** "—" when the actual is unknown (never a fake $0). */
  actual: string;
  variance: string | null;
  varianceTone: VarianceTone | null;
}

export interface WhatChangedItemVM {
  key: string;
  label: string;
  amount: string;
  tone: VarianceTone;
}

const UNKNOWN = "—";

/** The card is visible from in_progress onward (design §9.1). */
export const PROFITABILITY_STATUSES: ReadonlySet<JobStatus> = new Set([
  "in_progress",
  "complete",
  "invoiced",
  "paid",
]);

/**
 * Card render gate: pipeline position + a built estimate. A job with no
 * estimate has nothing to compare against — hidden is correct (the same
 * philosophy as EstimateCard's hasEstimate branch).
 */
export function shouldShowProfitability(job: Job): boolean {
  return PROFITABILITY_STATUSES.has(job.status) && (job.estimateTotal || 0) > 0;
}

/**
 * Jobs offered by the expense "Link to job" picker: won work that can bear
 * costs (approved onward, paid included — receipts often land after the job
 * closes), never archived, newest first. `alwaysIncludeId` keeps a
 * pre-selected job (JobDetail's pre-linked add) in the list even when the
 * filter would drop it.
 */
const LINKABLE_STATUSES: ReadonlySet<JobStatus> = new Set([
  "approved",
  "scheduled",
  "in_progress",
  "complete",
  "invoiced",
  "paid",
]);

export function selectLinkableJobs(jobs: Job[], alwaysIncludeId?: string): Job[] {
  return jobs
    .filter(
      (j) =>
        j.id === alwaysIncludeId ||
        (!isArchived(j) && LINKABLE_STATUSES.has(j.status)),
    )
    // Code-unit compare, not localeCompare (Hermes ICU — the comparePayments
    // precedent); createdAt strings are date-ordered lexicographically.
    .sort((a, b) =>
      a.createdAt < b.createdAt ? 1 : a.createdAt > b.createdAt ? -1 : 0,
    );
}

const signedMoney = (n: number): string =>
  n > 0 ? `+${formatMoney(n)}` : formatMoney(n);

const signedHours = (h: number): string =>
  h > 0 ? `+${formatLaborHint(h)}` : `-${formatLaborHint(-h)}`;

function categoryLabel(id: ExpenseCategoryId): string {
  return EXPENSE_CATEGORIES.find((c) => c.id === id)?.label ?? "Other";
}

/** The est/actual/variance rows for the Job Detail card, in render order. */
export function buildProfitabilityRows(
  job: Job,
  p: JobProfitability,
): ProfitRowVM[] {
  const rows: ProfitRowVM[] = [];

  rows.push({
    key: "revenue",
    label: "Revenue",
    estimate: formatQuote(p.estimatedRevenue),
    actual: formatMoney(p.finalBillable),
    variance: p.changeOrderRevenue !== 0 ? signedMoney(p.changeOrderRevenue) : null,
    // A won change order grows the job; a descope credit is a recorded
    // agreement, not a failure — neutral, not bad.
    varianceTone:
      p.changeOrderRevenue > 0 ? "good" : p.changeOrderRevenue < 0 ? "neutral" : null,
  });

  rows.push({
    key: "hours",
    label: "Labor hours",
    estimate: p.estimatedLaborHours > 0 ? formatLaborHint(p.estimatedLaborHours) : UNKNOWN,
    actual: p.actualLaborHours !== null ? formatLaborHint(p.actualLaborHours) : UNKNOWN,
    variance:
      p.laborHoursVariance !== null && p.laborHoursVariance !== 0
        ? signedHours(p.laborHoursVariance)
        : null,
    varianceTone:
      p.laborHoursVariance !== null && p.laborHoursVariance !== 0
        ? p.laborHoursVariance > 0
          ? "bad"
          : "good"
        : null,
  });

  rows.push({
    key: "materials",
    label: "Materials cost",
    estimate: formatQuote(p.estimatedMaterialCost),
    actual:
      p.actualMaterialExpense !== null ? formatMoney(p.actualMaterialExpense) : UNKNOWN,
    variance:
      p.materialsVariance !== null && p.materialsVariance !== 0
        ? signedMoney(p.materialsVariance)
        : null,
    varianceTone:
      p.materialsVariance !== null && p.materialsVariance !== 0
        ? p.materialsVariance > 0
          ? "bad"
          : "good"
        : null,
  });

  // Only when known AND non-zero — an unknown renders nothing rather than a
  // row of dashes, and a known $0 adds no information.
  if (p.otherDirectExpenses !== null && p.otherDirectExpenses > 0) {
    rows.push({
      key: "otherExpenses",
      label: "Other job expenses",
      estimate: UNKNOWN,
      actual: formatMoney(p.otherDirectExpenses),
      variance: null,
      varianceTone: null,
    });
  }

  const profitDelta = roundToCents(p.actualGrossProfitBilled - p.estimatedGrossProfit);
  rows.push({
    key: "profit",
    label: "Gross profit",
    estimate: formatQuote(p.estimatedGrossProfit),
    actual: formatMoney(p.actualGrossProfitBilled),
    variance: profitDelta !== 0 ? signedMoney(profitDelta) : null,
    varianceTone: profitDelta > 0 ? "good" : profitDelta < 0 ? "bad" : null,
  });

  // Estimate-side effective hourly mirrors the pricing engine's definition:
  // (total − charged materials) / hours, on the saved-job breakdown.
  const estBreakdown = computeEstimateBreakdown(job);
  const estimatedHourly =
    p.estimatedLaborHours > 0
      ? roundToCents((p.estimatedRevenue - estBreakdown.materialCost) / p.estimatedLaborHours)
      : null;
  rows.push({
    key: "hourly",
    label: "Earned per hour",
    estimate: estimatedHourly !== null ? `${formatMoney(estimatedHourly)}/hr` : UNKNOWN,
    actual:
      p.effectiveHourlyActual !== null
        ? `${formatMoney(p.effectiveHourlyActual)}/hr`
        : UNKNOWN,
    variance: null,
    varianceTone: null,
  });

  return rows;
}

/**
 * One-line invoicing/cash summary under the card. Null when the job has no
 * invoiced or collected money at all (nothing to summarise). Invoiced and
 * collected are never summed — they are stated side by side.
 */
export function buildCollectionSummary(p: JobProfitability): string | null {
  if (p.invoicedAmount <= 0 && p.cashCollected <= 0) return null;
  let line = `Collected ${formatMoney(p.cashCollected)} of ${formatMoney(p.invoicedAmount)} invoiced`;
  if (p.outstandingReceivable > 0) {
    line += ` · ${formatMoney(p.outstandingReceivable)} outstanding`;
  }
  if (p.overpaidAmount > 0) {
    line += ` · overpaid ${formatMoney(p.overpaidAmount)}`;
  }
  return line;
}

/**
 * The "What changed?" contributors, in stable order: approved change orders,
 * the labor delta, each linked expense, then money not yet collected. Pure
 * presentation of already-computed figures — no new math beyond signs.
 */
export function buildWhatChangedItems(
  job: Job,
  p: JobProfitability,
  linkedExpenses: Expense[],
): WhatChangedItemVM[] {
  const items: WhatChangedItemVM[] = [];

  for (const co of job.changeOrders ?? []) {
    if (changeOrderStatus(co) !== "approved") continue;
    items.push({
      key: `co:${co.id}`,
      label: `Change order — ${co.title}`,
      amount: signedMoney(toAmount(co.amount)),
      tone: co.amount > 0 ? "good" : "neutral",
    });
  }

  if (p.laborHoursVariance !== null && p.laborHoursVariance !== 0) {
    const over = p.laborHoursVariance > 0;
    items.push({
      key: "hours",
      label: over ? "Labor over estimate" : "Labor under estimate",
      amount: signedHours(p.laborHoursVariance),
      tone: over ? "bad" : "good",
    });
  }

  for (const e of linkedExpenses) {
    items.push({
      key: `exp:${e.id}`,
      label: `${e.description} (${categoryLabel(e.category)})`,
      amount: formatMoney(toAmount(e.amount)),
      tone: "neutral",
    });
  }

  if (p.outstandingReceivable > 0) {
    items.push({
      key: "outstanding",
      label: "Not yet collected",
      amount: formatMoney(p.outstandingReceivable),
      tone: "bad",
    });
  }

  return items;
}

/**
 * User copy for each ProfitWarning. Honest about what is unknown and why —
 * never spins missing data as zero (docs house style).
 */
const WARNING_COPY: Record<ProfitWarning, string> = {
  hours_untracked: "No hours tracked on this job — labor actuals are unknown.",
  expenses_unlinked:
    "No expenses linked to this job — material and cost actuals are unknown.",
  invoice_unlinked: "No invoice is linked to this job yet.",
  fees_unknown:
    "Card-processing fees aren't recorded — collected amounts are gross.",
  labor_cost_rate_unset:
    "Profit is before paying yourself — add an owner labor cost rate to include it.",
  legacy_invoice_dates:
    "Some payments predate itemised history, so their dates are approximate.",
};

export function warningCopy(w: ProfitWarning): string {
  return WARNING_COPY[w];
}
