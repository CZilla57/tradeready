// Reconciles server-written estimate decisions into the local job pipeline.
// Idempotent and flag-free (modeled on migrateCustomerIdentity): the server
// writes only job.approval.decision; the DEVICE performs the status transition
// through the pipeline. Safe to run on every sign-in and every foreground sync —
// it writes only when something actually changed (a save re-enqueues the whole
// collection, so a no-op run must not write).

import { loadJobs, saveJobs } from "./collections";
import { applyEstimateDecision } from "../jobStatus";
import type { Job } from "../../types/models";

export function applyDecisionsToJobs(jobs: Job[]): { jobs: Job[]; changed: boolean } {
  let changed = false;
  const next = jobs.map((j) => {
    const decision = j.approval?.decision;
    if (decision !== "approved" && decision !== "declined") return j;
    const status = applyEstimateDecision(j.status, decision);
    if (status === j.status) return j;
    changed = true;
    return { ...j, status };
  });
  return { jobs: changed ? next : jobs, changed };
}

export async function applyEstimateDecisions(): Promise<void> {
  const jobs = await loadJobs();
  const { jobs: updated, changed } = applyDecisionsToJobs(jobs);
  if (changed) await saveJobs(updated);
}
