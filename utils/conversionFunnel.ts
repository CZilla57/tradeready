import { JOB_STATUSES } from "./pricingEngine";
import type { Job, JobStatus } from "../types/models";

const FUNNEL_STAGES: JobStatus[] = [
  "lead",
  "estimate_sent",
  "approved",
  "scheduled",
  "in_progress",
  "complete",
];

const STATUS_ORDINAL: Record<JobStatus, number> = {
  lead: 0,
  estimate_sent: 1,
  approved: 2,
  scheduled: 3,
  in_progress: 4,
  complete: 5,
  invoiced: 6,
  paid: 7,
};

export interface FunnelStage {
  status: JobStatus;
  label: string;
  count: number;
  rate: number | null;
}

export interface ConversionFunnel {
  stages: FunnelStage[];
  totalJobs: number;
  winRate: number | null;
}

export function computeConversionFunnel(jobs: Job[]): ConversionFunnel {
  const reached = new Map<JobStatus, number>();
  for (const stage of FUNNEL_STAGES) reached.set(stage, 0);

  for (const job of jobs) {
    const ord = STATUS_ORDINAL[job.status] ?? -1;
    for (const stage of FUNNEL_STAGES) {
      if (ord >= STATUS_ORDINAL[stage]) {
        reached.set(stage, reached.get(stage)! + 1);
      }
    }
  }

  const stages: FunnelStage[] = FUNNEL_STAGES.map((status, i) => {
    const count = reached.get(status)!;
    const prev = i > 0 ? reached.get(FUNNEL_STAGES[i - 1])! : null;
    return {
      status,
      label: JOB_STATUSES[status].label,
      count,
      rate: prev !== null && prev > 0 ? count / prev : null,
    };
  });

  const estimateSent = reached.get("estimate_sent")!;
  const approved = reached.get("approved")!;

  return {
    stages,
    totalJobs: jobs.length,
    winRate: estimateSent > 0 ? approved / estimateSent : null,
  };
}
