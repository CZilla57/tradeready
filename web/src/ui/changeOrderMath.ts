import type { ChangeOrder, Job } from '@shared/types/models';

// Web-side reimplementation of the pure change-order roll-ups from
// utils/changeOrders.ts. That module can't be imported here: it pulls
// `escapeHtml` from utils/pdfTemplates.ts, which imports react-native-only
// modules. These match the app's logic exactly (same statuses, same rounding).

export type ChangeOrderStatus =
  | 'pending'
  | 'awaiting'
  | 'approved'
  | 'declined'
  | 'cancelled';

function roundToCents(n: number): number {
  return Math.round((Number(n) || 0) * 100) / 100;
}

export function changeOrderStatus(co: ChangeOrder): ChangeOrderStatus {
  if (co.cancelledAt) return 'cancelled';
  const decision = co.approval?.decision ?? co.manualDecision?.decision;
  if (decision === 'approved') return 'approved';
  if (decision === 'declined') return 'declined';
  if (co.approval) return 'awaiting';
  return 'pending';
}

export function approvedChangeOrderTotal(job: Pick<Job, 'changeOrders'>): number {
  return roundToCents(
    (job.changeOrders ?? []).reduce(
      (sum, co) =>
        changeOrderStatus(co) === 'approved' ? sum + (co.amount || 0) : sum,
      0,
    ),
  );
}

/** estimateTotal + approved change orders — the billable figure. */
export function jobBillableTotal(
  job: Pick<Job, 'estimateTotal' | 'changeOrders'>,
): number {
  return roundToCents((job.estimateTotal || 0) + approvedChangeOrderTotal(job));
}
