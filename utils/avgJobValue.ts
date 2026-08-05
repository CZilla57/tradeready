import type { Job, JobStatus } from "../types/models";
import { isInRange } from "./moneyUtils";
import { jobBillableTotal } from "./changeOrders";

const DONE_STATUSES: Set<JobStatus> = new Set(["complete", "invoiced", "paid"]);

export interface AvgJobValueResult {
  avgValue: number;
  count: number;
  totalValue: number;
}

export function computeAvgJobValue(
  jobs: Job[],
  start?: Date,
  end?: Date,
): AvgJobValueResult {
  let totalValue = 0;
  let count = 0;

  for (const job of jobs) {
    if (!DONE_STATUSES.has(job.status)) continue;
    if (jobBillableTotal(job) <= 0) continue;
    if (start && end && job.createdAt && !isInRange(job.createdAt, start, end)) continue;
    totalValue += jobBillableTotal(job);
    count++;
  }

  return {
    avgValue: count > 0 ? totalValue / count : 0,
    count,
    totalValue,
  };
}
