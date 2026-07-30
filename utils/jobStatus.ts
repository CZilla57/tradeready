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

/**
 * Whether a job should offer a route to SendEstimateScreen (where the customer
 * approval link is minted).
 *
 * `estimate_sent` is included deliberately. The Pricing Calculator's "Email to
 * customer" advances lead → estimate_sent without ever attaching an approval
 * link, and every entry point to SendEstimateScreen used to require
 * status === "lead" — so the most common way to send an estimate permanently
 * locked the job out of the approval flow. Sending again from `estimate_sent`
 * is also just re-sending, which is safe: create-link is idempotent per job and
 * the server freezes the snapshot once a decision exists.
 *
 * Stops at a decision: `approved` needs no link, and `declined` has its own
 * "Revise & re-send" action that resets the approval state first.
 */
export function canSendEstimate(status: JobStatus, estimateTotal: number): boolean {
  if (estimateTotal <= 0) return false;
  return status === "lead" || status === "estimate_sent";
}

/**
 * Apply a customer's estimate decision to a job's status. Only acts before the
 * tradesperson has taken the job forward — never regresses scheduled…paid
 * (mirrors advanceStatusForSchedule's no-regress guarantee). "approved" derives
 * from the pipeline; "declined" is the one sanctioned off-`.next` branch, living
 * here so no screen ever hardcodes it.
 */
export function applyEstimateDecision(
  status: JobStatus,
  decision: "approved" | "declined",
): JobStatus {
  if (status !== "lead" && status !== "estimate_sent") return status;
  if (decision === "approved") return JOB_STATUSES.estimate_sent.next ?? status;
  return "declined";
}
