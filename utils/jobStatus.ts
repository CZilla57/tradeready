// utils/jobStatus.ts
// Job-status transition logic, kept out of the screens so it's unit-tested.
// JOB_STATUSES (pricingEngine) defines the linear pipeline via each status's
// `next` field — lead → estimate_sent → approved → scheduled → in_progress →
// complete → invoiced → paid. The helpers here decide when a transition should
// fire automatically.

import { JOB_STATUSES } from "./pricingEngine";
import type { JobStatus } from "../types/models";

/**
 * When a job gains a scheduled date, an `approved` job should advance to
 * `scheduled` (its next step). This is the one automatic, schedule-driven
 * transition — every other status is returned unchanged so:
 *   - later statuses (scheduled…paid) never regress, and
 *   - earlier statuses (lead / estimate_sent) don't skip the approval step.
 *
 * Fixes the gap where AddJobScreen.handleSave saved a scheduledDate but left an
 * approved job stuck at "approved" (JobDetail's "Schedule this job" action just
 * routes here to pick the date; nothing else performed the transition).
 */
export function advanceStatusForSchedule(status: JobStatus, hasSchedule: boolean): JobStatus {
  if (hasSchedule && status === "approved") {
    return JOB_STATUSES.approved.next ?? status; // → "scheduled"
  }
  return status;
}
