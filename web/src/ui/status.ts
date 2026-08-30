import type { JobStatus, Invoice } from '@shared/types/models';
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
