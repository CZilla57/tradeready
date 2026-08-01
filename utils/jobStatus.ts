// utils/jobStatus.ts
// Job-status transition logic, kept out of the screens so it's unit-tested.
// JOB_STATUSES (pricingEngine) defines the linear pipeline via each status's
// `next` field — lead → estimate_sent → approved → scheduled → in_progress →
// complete → invoiced → paid. The helpers here decide when a transition should
// fire automatically.

import { JOB_STATUSES } from "./pricingEngine";
import type { Job, JobStatus, Invoice } from "../types/models";
import { isFullyPaid } from "./invoicePayments";

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

const DEPOSIT_ELIGIBLE_STATUSES: readonly JobStatus[] = ["approved", "scheduled", "in_progress"];

/**
 * Whether a deposit can be requested for a job at this status — any point
 * after the customer has approved the estimate but before the job is done.
 * Once "complete", invoicing takes over (see invoiceScreenMode).
 */
export function canRequestDeposit(status: JobStatus): boolean {
  return DEPOSIT_ELIGIBLE_STATUSES.includes(status);
}

export type InvoiceScreenMode = "create" | "requestDeposit" | "finalize";

/**
 * Which of CreateInvoiceFromJobScreen's three modes applies for a given job.
 * Returns null for any status/invoiceId combination that should never reach
 * that screen — e.g. a deposit-eligible status that already has an invoice,
 * which JobDetailScreen routes straight to Outreach for instead.
 */
export function invoiceScreenMode(status: JobStatus, hasInvoice: boolean): InvoiceScreenMode | null {
  if (status === "complete") return hasInvoice ? "finalize" : "create";
  if (canRequestDeposit(status) && !hasInvoice) return "requestDeposit";
  return null;
}

/**
 * The Job patch to apply once CreateInvoiceFromJobScreen saves. The core
 * invariant lives here: requesting a deposit early must never advance the job
 * to "invoiced" — only finishing the job (create at complete, or finalize an
 * existing deposit invoice at complete) does that. `invoicePaid` covers the
 * finalize edge where the deposit already settled the whole bill
 * (reconcilePaidFields marks the invoice paid at save time): the job then
 * lands straight on "paid" — invoiced's own `.next` — instead of sitting on
 * an "invoiced" status no code would ever advance.
 */
export function jobChangesAfterInvoiceSave(
  mode: InvoiceScreenMode,
  invoiceId: string,
  invoicePaid: boolean,
): Partial<Job> {
  if (mode === "requestDeposit") return { invoiceId };
  return { status: invoicePaid ? "paid" : "invoiced", invoiceId };
}

/** Screen title + primary-button copy for each CreateInvoiceFromJobScreen mode. */
export function invoiceScreenCopy(mode: InvoiceScreenMode): { title: string; cta: string } {
  switch (mode) {
    case "requestDeposit":
      return { title: "Request Deposit", cta: "Request deposit →" };
    case "finalize":
      return { title: "Finalize Invoice", cta: "Finalize invoice →" };
    case "create":
      return { title: "Create Invoice", cta: "Create invoice →" };
  }
}

const JOB_DONE_STATUSES: readonly JobStatus[] = ["complete", "invoiced", "paid"];

/**
 * Whether a job's own invoice should be eligible for overdue dunning (local
 * notifications in utils/notifications.ts, and the auto-email cron in
 * backend/lib/selectInvoicesToRemind.js — mirrored there since backend/ is a
 * separate CommonJS package; kept in sync by __tests__/jobDunningParity.test.js).
 *
 * A pre-work deposit invoice tied to a job that isn't done yet must never
 * trigger dunning, however overdue its due date looks — the job hasn't
 * started or finished, so "overdue" doesn't mean what it means for a
 * finished job's bill. Invoices with no linked job, or whose job can no
 * longer be found (e.g. deleted), are always eligible: only a job we can
 * positively confirm isn't done yet suppresses dunning.
 */
export function isJobDunningEligible(status: JobStatus | undefined): boolean {
  if (!status) return true;
  return JOB_DONE_STATUSES.includes(status);
}

/**
 * Jobs follow invoice truth: a job is "paid" exactly when the invoice it is
 * linked to (job.invoiceId) is fully paid. Advances ONLY from exactly
 * "invoiced" — a mid-pipeline job whose pre-work DEPOSIT invoice got fully
 * paid must not jump the pipeline (no-skip mirror of
 * advanceStatusForSchedule's no-regress guarantee).
 *
 * Returns the SAME array reference when nothing changed, so callers can skip
 * saveJobs (`result !== jobs`). Idempotent — safe to run as a read-side
 * sweep, which is also how webhook-paid invoices arriving via sync pull get
 * reflected without touching utils/sync.ts, and how jobs stuck at "invoiced"
 * from before this fix (FA-038) self-heal.
 */
export function advanceJobsForPaidInvoices(jobs: Job[], invoices: Invoice[]): Job[] {
  const paidInvoiceIds = new Set(invoices.filter(isFullyPaid).map((inv) => inv.id));
  let changed = false;
  const next = jobs.map((j) => {
    if (j.status === "invoiced" && j.invoiceId && paidInvoiceIds.has(j.invoiceId)) {
      changed = true;
      return { ...j, status: JOB_STATUSES.invoiced.next ?? j.status };
    }
    return j;
  });
  return changed ? next : jobs;
}
