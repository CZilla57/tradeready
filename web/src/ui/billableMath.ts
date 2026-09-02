// web/src/ui/billableMath.ts
//
// A web-side reimplementation of the pure invoice-from-job derivation the
// mobile app keeps in utils/autoInvoice.ts (billableLaborHours,
// computeBillableBreakdown, buildInvoiceLineItems) plus the two helpers it
// leans on that live in RN-tethered modules: computeEstimateBreakdown and
// directCostLabel from utils/pricingEngine.ts (which drags `BadgeColor` from a
// React Native component module — the same reason pricingMath.ts,
// invoiceMath.ts, and changeOrderMath.ts exist).
//
// This is a faithful, behaviour-preserving copy of the PURE functions only.
// Keep it in lockstep with utils/autoInvoice.ts and utils/pricingEngine.ts; it
// is pinned to the mobile modules' own values in billableMath.test.ts.
//
// Tracked-time billing, verbatim from the mobile contract: when the job timer
// was used on a finished job whose estimate priced labor hourly, the labor line
// bills the tracked hours at the job's labor rate and the total shifts by the
// hour delta (a T&M change order at the agreed rate). The full pricing engine is
// deliberately NOT re-run — the quoted materials and residual overhead line stay
// exactly as quoted and only labor moves, so lines always sum to the total.
// Approved change orders are added to the total and appended as `other` lines.

import type {
  DirectCostLine,
  InvoiceLineItem,
  Job,
  JobCostCategory,
  JobStatus,
  TimeSession,
} from '@shared/types/models';
import { roundToCents } from '@shared/utils/invoicePayments';
import { formatQuote } from '@shared/utils/format';
import { computeDirectCosts } from './pricingMath';
import { approvedChangeOrderTotal, changeOrderStatus } from './changeOrderMath';

// The direct-cost category labels from utils/pricingEngine.ts JOB_COST_CATEGORIES,
// copied here (that module can't be imported). Keep in lockstep.
const JOB_COST_CATEGORY_LABELS: Record<JobCostCategory, string> = {
  permit: 'Permit',
  disposal: 'Disposal',
  rental: 'Equipment rental',
  subcontractor: 'Subcontractor',
  delivery: 'Delivery',
  travel: 'Travel',
  other: 'Other cost',
};

/** A direct-cost line's display label: its own trimmed label, else the category. */
export function directCostLabel(line: {
  label?: string;
  category: JobCostCategory;
}): string {
  const own = (line.label || '').trim();
  if (own) return own;
  return JOB_COST_CATEGORY_LABELS[line.category] || 'Cost';
}

/**
 * Web port of pricingEngine.computeEstimateBreakdown. Reads the job's stored
 * fields and TRUSTS the stored `estimateTotal` (a hand-adjusted total must
 * survive); the overhead line is the residual, so labor + materials + visible
 * direct lines + overhead always sum to the total. Hidden direct costs fold
 * into the residual.
 */
export interface JobEstimateBreakdown {
  laborCost: number;
  materialBaseCost: number;
  materialCost: number;
  directCostLines: DirectCostLine[];
  overheadLine: number;
  estimateTotal: number;
  hasMaterials: boolean;
}

export function computeEstimateBreakdown(job: Job): JobEstimateBreakdown {
  const materials = job.materials || [];
  const laborCost = (job.laborHours || 0) * (job.laborRate || 0);
  const materialBaseCost = materials.reduce(
    (sum, m) => sum + m.quantity * m.unitCost,
    0,
  );
  const materialCost = materialBaseCost * (1 + (job.materialMarkup || 0) / 100);
  const estimateTotal = job.estimateTotal || 0;

  const { lines } = computeDirectCosts(job.jobCosts || []);
  const visibleDirectTotal = lines
    .filter((l) => l.customerVisible)
    .reduce((sum, l) => sum + l.amount, 0);
  const overheadLine = estimateTotal - laborCost - materialCost - visibleDirectTotal;

  return {
    laborCost,
    materialBaseCost,
    materialCost,
    directCostLines: lines,
    overheadLine,
    estimateTotal,
    hasMaterials: materials.length > 0,
  };
}

/**
 * Tracked time replaces estimated hours only once the work is finished — a
 * deposit requested mid-job still bills off the estimate (the tracked total
 * isn't final yet).
 */
const BILL_TRACKED_STATUSES: readonly JobStatus[] = ['complete', 'invoiced', 'paid'];

/** Completed-session milliseconds (the auto flow's clock-out is a mobile-only
 *  side effect; the web review path bills COMPLETED sessions only). */
function completedSessionMs(sessions: TimeSession[]): number {
  return sessions.reduce(
    (sum, s) =>
      s.end ? sum + (new Date(s.end).getTime() - new Date(s.start).getTime()) : sum,
    0,
  );
}

export interface BillableLabor {
  /** Hours the labor line should bill. */
  hours: number;
  /** True when tracked timer time replaced the estimate's hours. */
  usedTrackedTime: boolean;
}

/**
 * Hours to bill for a job's labor line. Tracked timer time applies ONLY when the
 * estimate priced labor hourly (laborHours > 0 AND laborRate > 0), the job is
 * done (BILL_TRACKED_STATUSES), and at least one completed session logged time.
 * Tracked hours round to 2 decimals. Verbatim from autoInvoice.billableLaborHours.
 */
export function billableLaborHours(job: Job): BillableLabor {
  const estimated = job.laborHours || 0;
  const rate = job.laborRate || 0;
  if (estimated <= 0 || rate <= 0 || !BILL_TRACKED_STATUSES.includes(job.status)) {
    return { hours: estimated, usedTrackedTime: false };
  }
  const completedMs = completedSessionMs(job.timeSessions || []);
  const tracked = Math.round((completedMs / 3600000) * 100) / 100;
  if (tracked <= 0) return { hours: estimated, usedTrackedTime: false };
  return { hours: tracked, usedTrackedTime: true };
}

export interface BillableBreakdown {
  laborHours: number;
  laborCost: number;
  materialCost: number;
  overheadLine: number;
  hasMaterials: boolean;
  directCostLines: DirectCostLine[];
  usedTrackedTime: boolean;
  /** Σ approved change-order amounts included in `total` (0 when none). */
  changeOrderTotal: number;
  /** The invoice amount: estimateTotal ± (hour delta × labor rate), cents-rounded. */
  total: number;
}

/**
 * The billable version of computeEstimateBreakdown: identical to the quoted
 * breakdown until tracked time applies, at which point only the labor line moves
 * and the total shifts by the same delta. Verbatim from
 * autoInvoice.computeBillableBreakdown.
 */
export function computeBillableBreakdown(job: Job): BillableBreakdown {
  const base = computeEstimateBreakdown(job);
  const { hours, usedTrackedTime } = billableLaborHours(job);
  const changeOrderTotal = approvedChangeOrderTotal(job);

  if (!usedTrackedTime) {
    return {
      laborHours: job.laborHours || 0,
      laborCost: base.laborCost,
      materialCost: base.materialCost,
      overheadLine: base.overheadLine,
      hasMaterials: base.hasMaterials,
      directCostLines: base.directCostLines,
      usedTrackedTime,
      changeOrderTotal,
      total: roundToCents(base.estimateTotal + changeOrderTotal),
    };
  }

  const laborCost = roundToCents(hours * (job.laborRate || 0));
  return {
    laborHours: hours,
    laborCost,
    materialCost: base.materialCost,
    overheadLine: base.overheadLine,
    hasMaterials: base.hasMaterials,
    directCostLines: base.directCostLines,
    usedTrackedTime,
    changeOrderTotal,
    total: roundToCents(base.estimateTotal + laborCost - base.laborCost + changeOrderTotal),
  };
}

/**
 * The invoice line items for a job. Verbatim from autoInvoice.buildInvoiceLineItems:
 * labor (when > 0), materials (single name or item count), each customer-visible
 * direct-cost line, the residual overhead line (only when > 1, to swallow rounding
 * dust), and each approved change order as an `other` line.
 */
export function buildInvoiceLineItems(job: Job): InvoiceLineItem[] {
  const b = computeBillableBreakdown(job);
  const items: InvoiceLineItem[] = [];
  if (b.laborCost > 0) {
    items.push({
      description: `Labor — ${b.laborHours} hrs @ ${formatQuote(job.laborRate || 0)}/hr`,
      amount: b.laborCost,
      category: 'labor',
    });
  }
  if (b.hasMaterials) {
    const materials = job.materials || [];
    const label =
      materials.length === 1
        ? materials[0].name || 'Materials'
        : `Materials (${materials.length} items)`;
    items.push({ description: label, amount: b.materialCost, category: 'materials' });
  }
  for (const dc of b.directCostLines) {
    if (!dc.customerVisible) continue; // hidden costs live inside the overhead residual
    items.push({ description: directCostLabel(dc), amount: dc.amount, category: dc.category });
  }
  if (b.overheadLine > 1) {
    items.push({
      description: 'Overhead & operating costs',
      amount: b.overheadLine,
      category: 'overhead',
    });
  }
  for (const co of job.changeOrders ?? []) {
    if (changeOrderStatus(co) !== 'approved') continue;
    items.push({ description: `Change order — ${co.title}`, amount: co.amount, category: 'other' });
  }
  return items;
}

/** Default payment terms: 30 days out, `YYYY-MM-DD`. Verbatim from
 *  autoInvoice.defaultDueDate. */
export function defaultDueDate(now: Date = new Date()): string {
  const d = new Date(now);
  d.setDate(d.getDate() + 30);
  return d.toISOString().split('T')[0];
}

// ── Which jobs can be invoiced, and how ──────────────────────────────────────
// Port of utils/jobStatus.ts invoiceScreenMode / canRequestDeposit, minus the
// "finalize" arm: the web portal creates NEW invoices from a job here. Editing
// an existing deposit invoice in place (finalize) is a distinct edit-existing
// flow and stays out of this creation module.

const DEPOSIT_ELIGIBLE_STATUSES: readonly JobStatus[] = [
  'approved',
  'scheduled',
  'in_progress',
];

export type InvoiceFromJobMode = 'create' | 'requestDeposit' | 'finalize';

/**
 * The invoice-from-job mode for a job, or null when it can't be invoiced yet
 * (still a lead/quoted, or its estimate is unapproved). Mirrors
 * jobStatus.invoiceScreenMode exactly:
 *   complete + no invoice          → "create"   (final bill; job → invoiced)
 *   complete + has invoice         → "finalize" (a deposit is already open)
 *   approved/scheduled/in_progress → "requestDeposit" (bill up front, status held)
 */
export function invoiceFromJobMode(
  status: JobStatus,
  hasInvoice: boolean,
): InvoiceFromJobMode | null {
  if (status === 'complete') return hasInvoice ? 'finalize' : 'create';
  if (DEPOSIT_ELIGIBLE_STATUSES.includes(status) && !hasInvoice) return 'requestDeposit';
  return null;
}

/** Human copy for the create action, keyed by mode. */
export function invoiceFromJobCopy(mode: 'create' | 'requestDeposit'): {
  title: string;
  cta: string;
} {
  return mode === 'requestDeposit'
    ? { title: 'Request deposit', cta: 'Request deposit' }
    : { title: 'Create invoice', cta: 'Create invoice' };
}

/** estimateTotal + approved change orders — the up-front (non-tracked) figure a
 *  requestDeposit bills, and what create bills before tracked time applies. */
export function jobBillableTotal(job: Job): number {
  return roundToCents((job.estimateTotal || 0) + approvedChangeOrderTotal(job));
}
