import type { JobStatus, Invoice, Job } from '@shared/types/models';
import { balanceDue, isFullyPaid } from '@shared/utils/invoicePayments';
import { isOverdue } from './invoiceMath';

export type BadgeColor = 'green' | 'amber' | 'red' | 'blue' | 'slate';

const JOB_STATUS: Record<JobStatus, { label: string; color: BadgeColor }> = {
  lead: { label: 'Lead', color: 'slate' },
  estimate_sent: { label: 'Estimate Sent', color: 'blue' },
  approved: { label: 'Approved', color: 'blue' },
  scheduled: { label: 'Scheduled', color: 'blue' },
  in_progress: { label: 'In Progress', color: 'amber' },
  complete: { label: 'Completed', color: 'green' },
  invoiced: { label: 'Invoiced', color: 'amber' },
  paid: { label: 'Paid', color: 'green' },
  declined: { label: 'Declined', color: 'red' },
};

export function jobStatusBadge(status: string): {
  label: string;
  color: BadgeColor;
} {
  return JOB_STATUS[status as JobStatus] ?? { label: status, color: 'slate' };
}

/** The ordered pipeline used to render a job's status timeline. */
export const JOB_PIPELINE: JobStatus[] = [
  'lead',
  'estimate_sent',
  'approved',
  'scheduled',
  'in_progress',
  'complete',
  'invoiced',
  'paid',
];

export function invoiceStatusBadge(inv: Invoice): {
  label: string;
  color: BadgeColor;
} {
  if (isFullyPaid(inv)) return { label: 'Paid', color: 'green' };
  if (isOverdue(inv)) return { label: 'Overdue', color: 'red' };
  if (balanceDue(inv) < inv.amount)
    return { label: 'Partly paid', color: 'amber' };
  return { label: 'Unpaid', color: 'slate' };
}

/** Jobs that live in the estimate stage of the pipeline. */
export const ESTIMATE_JOB_STATUSES: JobStatus[] = [
  'lead',
  'estimate_sent',
  'approved',
  'declined',
];

export function isEstimateJob(job: Job): boolean {
  return (
    ESTIMATE_JOB_STATUSES.includes(job.status) ||
    !!job.approval ||
    ((job.estimateTotal || 0) > 0 && job.status !== 'paid')
  );
}

/**
 * The purely-operational forward status transitions the portal may fire — the
 * subset of the mobile pipeline (canonical: `JOB_STATUSES[status].next` in
 * `utils/pricingEngine.ts`, driven by `utils/jobStatus.ts`) that couples to
 * NOTHING the portal doesn't own: no invoice is created, no customer consent is
 * frozen, no other-screen flow is required.
 *
 *   scheduled   → in_progress   ("Start job")
 *   in_progress → complete      ("Mark complete")
 *
 * Mirrored here as a small map rather than importing `JOB_STATUSES` so the web
 * bundle stays react-native-free (pricingEngine pulls a type from an RN
 * component module, and dragging in its estimate math is exactly what the
 * roadmap defers). Adjacency is asserted against `JOB_PIPELINE` in
 * `status.test.ts`, so this can't silently drift from the canonical pipeline.
 *
 * Everything else is deliberately excluded and belongs to later stages of
 * roadmap P3 3b: `estimate_sent → approved` is the customer-consent step,
 * `complete → invoiced` / `invoiced → paid` create or settle an invoice (the
 * portal reflects those from the invoice ledger, it doesn't drive them), and
 * `lead` / `approved` need the estimate-authoring and scheduling flows.
 */
export const OPERATIONAL_STATUS_ADVANCE: Partial<
  Record<JobStatus, { next: JobStatus; label: string }>
> = {
  scheduled: { next: 'in_progress', label: 'Start job' },
  in_progress: { next: 'complete', label: 'Mark complete' },
};

/** The sanctioned operational advance for a status, or null if none applies. */
export function nextOperationalStatus(
  status: JobStatus,
): { next: JobStatus; label: string } | null {
  return OPERATIONAL_STATUS_ADVANCE[status] ?? null;
}

/** Approval-oriented status for the Estimates surface. */
export function estimateStatusBadge(job: Job): {
  label: string;
  color: BadgeColor;
} {
  const decision = job.approval?.decision;
  if (decision === 'approved' || job.status === 'approved')
    return { label: 'Approved', color: 'green' };
  if (decision === 'declined' || job.status === 'declined')
    return { label: 'Declined', color: 'red' };
  if (job.status === 'estimate_sent' || job.approval || job.estimateSentAt)
    return { label: 'Sent', color: 'blue' };
  return { label: 'Draft', color: 'slate' };
}
