// utils/jobStatusDisplay.ts
// The Today-tab style of job-status badge: a label + a color from the dedicated
// status palette (theme.colors.statusX). Extracted from TodayScreen (roadmap
// #7) so the mapping is complete and unit-tested.
//
// This is deliberately SEPARATE from JOB_STATUSES in pricingEngine.ts, which
// carries semantic color *tokens* ("accent"/"success"/…) that the Badge
// component maps to a smaller palette on the Jobs list / Job detail. Today uses
// the richer per-status colors; the two visual systems are intentional.
//
// The keys are the real JobStatus values from pricingEngine.JOB_STATUSES — the
// previous inline copy keyed "completed" (the status is "complete") and omitted
// approved/invoiced/paid, so those badges silently fell back to grey.

import { colors } from "./theme";
import type { JobStatus } from "../types/models";

export interface JobStatusDisplay {
  label: string;
  color: string;
}

const JOB_STATUS_DISPLAY: Record<JobStatus, JobStatusDisplay> = {
  lead:          { label: "Lead",          color: colors.statusLead },
  estimate_sent: { label: "Estimate Sent", color: colors.statusEstimate },
  approved:      { label: "Approved",      color: colors.statusApproved },
  scheduled:     { label: "Scheduled",     color: colors.statusScheduled },
  in_progress:   { label: "In Progress",   color: colors.statusInProgress },
  complete:      { label: "Completed",     color: colors.statusComplete },
  invoiced:      { label: "Invoiced",      color: colors.statusInvoiced },
  paid:          { label: "Paid",          color: colors.statusPaid },
  declined:      { label: "Declined",      color: colors.statusDeclined },
};

// Falls back to a grey pill labelled with the raw status for any value outside
// the known pipeline, mirroring the original screen behavior.
export function getJobStatusDisplay(status: string): JobStatusDisplay {
  return JOB_STATUS_DISPLAY[status as JobStatus] ?? { label: status, color: colors.statusLead };
}
