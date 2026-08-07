// utils/profitabilityAggregate.ts
// Trailing completed-job profitability history (Phase 13D): the numbers
// behind the Money tab's aggregate card and the PricingCalculator "reality
// check" warnings. Design of record:
// docs/superpowers/specs/2026-08-07-job-profitability-design.md §9.4–9.5.
//
// Medians, not means — one disaster job shouldn't set the narrative. Every
// figure derives from computeJobProfitability per job, so the unknown-means-
// null discipline carries through: jobs with no tracked data contribute
// nothing (they are counted, and the card says so). Warnings are hard-gated
// on MIN_HISTORY_JOBS of real data PER METRIC — the app never lectures the
// owner off one job's numbers. Aggregation is overall-only: per-job-type
// grouping was deliberately deferred (owner decision D5, 2026-08-07).

import type { Expense, Invoice, Job, JobStatus, Settings } from "../types/models";
import { computeJobProfitability } from "./jobProfitability";
import { roundToCents } from "./invoicePayments";
import { formatMoney } from "./format";
import { isArchived } from "./archive";

/** Minimum jobs of real data (per metric) before history speaks up. */
export const MIN_HISTORY_JOBS = 3;

/** Same tolerance the Today Insights low-margin rule uses (3 pts). */
const MARGIN_TOLERANCE_PTS = 3;

const DONE_STATUSES: ReadonlySet<JobStatus> = new Set([
  "complete",
  "invoiced",
  "paid",
]);

export interface ProfitabilityHistory {
  /** Completed-family jobs (complete/invoiced/paid) with an estimate, not archived. */
  doneJobs: number;
  /** Of those, jobs carrying any actual data (tracked hours or linked expenses). */
  jobsWithData: number;
  hourlyCount: number;
  medianEffectiveHourly: number | null;
  laborCount: number;
  medianLaborOverrunHours: number | null;
  materialsCount: number;
  /** actual / estimated materials cost, jobs with an estimated base > 0 only. */
  medianMaterialsOverrunRatio: number | null;
  medianMaterialsVariance: number | null;
}

function median(values: number[]): number | null {
  if (values.length === 0) return null;
  const sorted = [...values].sort((a, b) => a - b);
  const mid = Math.floor(sorted.length / 2);
  return sorted.length % 2 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2;
}

const round2 = (n: number): number => Math.round(n * 100) / 100;

export function computeProfitabilityHistory(
  jobs: Job[],
  invoices: Invoice[],
  expenses: Expense[],
  settings: Pick<Settings, "laborCostRate">,
  now: Date = new Date(),
): ProfitabilityHistory {
  const done = jobs.filter(
    (j) =>
      DONE_STATUSES.has(j.status) && !isArchived(j) && (j.estimateTotal || 0) > 0,
  );

  let jobsWithData = 0;
  const hourly: number[] = [];
  const laborOverruns: number[] = [];
  const materialsRatios: number[] = [];
  const materialsVariances: number[] = [];

  for (const job of done) {
    const p = computeJobProfitability(job, invoices, expenses, settings, now);
    if (p.actualLaborHours !== null || p.actualMaterialExpense !== null) {
      jobsWithData++;
    }
    if (p.effectiveHourlyActual !== null) hourly.push(p.effectiveHourlyActual);
    if (p.laborHoursVariance !== null) laborOverruns.push(p.laborHoursVariance);
    if (p.materialsVariance !== null) {
      materialsVariances.push(p.materialsVariance);
      if (p.actualMaterialExpense !== null && p.estimatedMaterialCost > 0) {
        materialsRatios.push(p.actualMaterialExpense / p.estimatedMaterialCost);
      }
    }
  }

  const medianHourly = median(hourly);
  const medianOverrun = median(laborOverruns);
  const medianVariance = median(materialsVariances);
  return {
    doneJobs: done.length,
    jobsWithData,
    hourlyCount: hourly.length,
    medianEffectiveHourly: medianHourly !== null ? roundToCents(medianHourly) : null,
    laborCount: laborOverruns.length,
    medianLaborOverrunHours: medianOverrun !== null ? round2(medianOverrun) : null,
    materialsCount: materialsVariances.length,
    medianMaterialsOverrunRatio: median(materialsRatios),
    medianMaterialsVariance: medianVariance !== null ? roundToCents(medianVariance) : null,
  };
}

/** The live-calculator figures the warnings compare history against. */
export interface EstimateSnapshotForWarnings {
  effectiveHourlyRate: number;
  materialBaseCost: number;
  subtotal: number;
  overheadCost: number;
  profit: number;
  marginPercent: number;
}

/**
 * getSanityWarnings-style strings for the calculator, built from OBSERVED
 * numbers only. Empty until the per-metric history clears MIN_HISTORY_JOBS;
 * the 5% hourly tolerance and the margin−3pts materials threshold keep
 * ordinary noise silent.
 */
export function getHistoryWarnings(
  history: ProfitabilityHistory,
  est: EstimateSnapshotForWarnings,
): string[] {
  const warnings: string[] = [];

  if (
    history.hourlyCount >= MIN_HISTORY_JOBS &&
    history.medianEffectiveHourly !== null &&
    est.effectiveHourlyRate > 0 &&
    history.medianEffectiveHourly < est.effectiveHourlyRate * 0.95
  ) {
    warnings.push(
      `Reality check: your recent jobs actually earned about ` +
        `${formatMoney(history.medianEffectiveHourly)}/hr — this estimate assumes ` +
        `${formatMoney(est.effectiveHourlyRate)}/hr. Consider more hours or a higher rate.`,
    );
  }

  if (
    history.materialsCount >= MIN_HISTORY_JOBS &&
    history.medianMaterialsOverrunRatio !== null &&
    history.medianMaterialsOverrunRatio > 1 &&
    est.materialBaseCost > 0
  ) {
    const extra = roundToCents(
      est.materialBaseCost * (history.medianMaterialsOverrunRatio - 1),
    );
    const profitBase = est.subtotal + est.overheadCost;
    const impliedPct =
      profitBase > 0 ? ((est.profit - extra) / profitBase) * 100 : 0;
    if (extra > 0 && impliedPct <= est.marginPercent - MARGIN_TOLERANCE_PTS) {
      const overPct = Math.round((history.medianMaterialsOverrunRatio - 1) * 100);
      warnings.push(
        `Materials have run about ${overPct}% over estimate on your recent jobs — ` +
          `that's ~${formatMoney(extra)} extra here, which would drop your margin to ` +
          `~${Math.round(impliedPct)}%.`,
      );
    }
  }

  return warnings;
}
