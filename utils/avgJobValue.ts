import type { Job, JobStatus } from "../types/models";

const DONE_STATUSES: Set<JobStatus> = new Set(["complete", "invoiced", "paid"]);

export interface AvgJobValueResult {
  avgValue: number;
  count: number;
  totalValue: number;
}

function parseLocalDate(dateString: string): Date {
  const dateOnly = /^(\d{4})-(\d{2})-(\d{2})$/.exec(dateString);
  if (dateOnly) {
    return new Date(Number(dateOnly[1]), Number(dateOnly[2]) - 1, Number(dateOnly[3]));
  }
  return new Date(dateString);
}

function isInRange(dateString: string, start: Date, end: Date): boolean {
  const d = parseLocalDate(dateString);
  return d >= start && d <= end;
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
    if (job.estimateTotal <= 0) continue;
    if (start && end && job.createdAt && !isInRange(job.createdAt, start, end)) continue;
    totalValue += job.estimateTotal;
    count++;
  }

  return {
    avgValue: count > 0 ? totalValue / count : 0,
    count,
    totalValue,
  };
}
