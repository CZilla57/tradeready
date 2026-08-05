import { computeEstimateBreakdown } from "./pricingEngine";
import { jobBillableTotal } from "./changeOrders";
import type { Job, JobStatus } from "../types/models";

const DONE_STATUSES: Set<JobStatus> = new Set(["complete", "invoiced", "paid"]);

export interface RevenueComponent {
  label: string;
  total: number;
  pct: number;
  color: "accent" | "success" | "warning";
}

export interface RevenueByTypeResult {
  totalRevenue: number;
  jobCount: number;
  components: RevenueComponent[];
}

export function computeRevenueByType(jobs: Job[]): RevenueByTypeResult {
  let laborTotal = 0;
  let materialTotal = 0;
  let overheadTotal = 0;
  let jobCount = 0;

  for (const job of jobs) {
    if (!DONE_STATUSES.has(job.status)) continue;
    const billable = jobBillableTotal(job);
    if (billable <= 0) continue;
    jobCount++;
    // pricingEngine's residual math (overheadLine = estimateTotal − labor −
    // material) stays untouched — pass a billable-total job snapshot instead
    // of mutating the engine, so approved-CO dollars land in the
    // overhead/profit line rather than vanishing from the chart.
    const bd = computeEstimateBreakdown({ ...job, estimateTotal: billable });
    laborTotal += bd.laborCost;
    materialTotal += bd.materialCost;
    overheadTotal += Math.max(0, bd.overheadLine);
  }

  const totalRevenue = laborTotal + materialTotal + overheadTotal;

  const components: RevenueComponent[] = [];
  if (totalRevenue > 0) {
    if (laborTotal > 0) {
      components.push({
        label: "Labor",
        total: laborTotal,
        pct: Math.round((laborTotal / totalRevenue) * 100),
        color: "accent",
      });
    }
    if (materialTotal > 0) {
      components.push({
        label: "Materials",
        total: materialTotal,
        pct: Math.round((materialTotal / totalRevenue) * 100),
        color: "success",
      });
    }
    if (overheadTotal > 0) {
      components.push({
        label: "Overhead & Profit",
        total: overheadTotal,
        pct: Math.round((overheadTotal / totalRevenue) * 100),
        color: "warning",
      });
    }
  }

  return { totalRevenue, jobCount, components };
}
