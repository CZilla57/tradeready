// web/src/ui/jobCostsDraft.ts
//
// Pure helpers behind the reusable JobCostsEditor (roadmap P3 — direct-cost line
// authoring). Direct costs (permits, disposal, subcontractor, …) price through
// the same estimate math as materials — `computeDirectCosts` in pricingMath.ts —
// so the editor and its string-draft helpers live here, parallel to
// materialsDraft.ts.
//
// The editor exposes the four fields that matter for the common workflow —
// label, category, quantity, unitCost — and DERIVES the markup POLICY from the
// category (the guides' standard: permits pass through at cost, everything else
// is priced into the margin). The advanced per-line knobs — handling
// `markupPercent`, the `taxable` flag, the `customerVisible` (hidden-cost) flag,
// and `notes` — are PRESERVED from an existing line (round-tripped, P0.2) and
// default to 0 / false / visible / none on a new line; they are authored on
// mobile. New ids match the mobile format `jc<timestamp>_<counter>` (P1.4).

import type {
  JobCost,
  JobCostCategory,
  JobCostMarkupPolicy,
} from '@shared/types/models';
import { defaultMarkupPolicyForCategory } from './pricingMath';

/** Category id + label for the picker (web copy of pricingEngine's list). */
export const JOB_COST_CATEGORIES: { id: JobCostCategory; label: string }[] = [
  { id: 'permit', label: 'Permit' },
  { id: 'disposal', label: 'Disposal' },
  { id: 'rental', label: 'Equipment rental' },
  { id: 'subcontractor', label: 'Subcontractor' },
  { id: 'delivery', label: 'Delivery' },
  { id: 'travel', label: 'Travel' },
  { id: 'other', label: 'Other cost' },
];

/** Display label for a direct-cost line: the user's label, else the category. */
export function directCostLabel(category: JobCostCategory, label: string): string {
  const own = label.trim();
  if (own) return own;
  return JOB_COST_CATEGORIES.find((c) => c.id === category)?.label || 'Cost';
}

/** A row while it is being edited. quantity/unitCost are raw text; the advanced
 *  pricing knobs (markupPercent/taxable/customerVisible/notes) are carried through
 *  from the source line so an unshown field is never dropped (P0.2). */
export interface JobCostDraft {
  id: string;
  label: string;
  category: JobCostCategory;
  quantity: string;
  unitCost: string;
  markupPolicy: JobCostMarkupPolicy;
  markupPercent: number;
  taxable: boolean;
  customerVisible: boolean;
  notes?: string;
}

let _jcLastMs = 0;
let _jcCounter = 0;
function newJobCostId(): string {
  const ms = Date.now();
  if (ms === _jcLastMs) {
    _jcCounter += 1;
  } else {
    _jcLastMs = ms;
    _jcCounter = 0;
  }
  return `jc${ms}_${_jcCounter}`;
}

/** A freshly-added row: an "Other cost" priced into the margin (its category
 *  default), qty 1, cost 0, no handling markup, taxable off, customer-visible. */
export function blankJobCostDraft(): JobCostDraft {
  const category: JobCostCategory = 'other';
  return {
    id: newJobCostId(),
    label: '',
    category,
    quantity: '1',
    unitCost: '0',
    markupPolicy: defaultMarkupPolicyForCategory(category),
    markupPercent: 0,
    taxable: false,
    customerVisible: true,
  };
}

/** Seed editable drafts from a record's stored direct costs (absent → none). */
export function jobCostsToDrafts(
  jobCosts: JobCost[] | undefined,
): JobCostDraft[] {
  return (jobCosts ?? []).map((c) => ({
    id: c.id,
    label: c.label ?? '',
    category: c.category,
    quantity: String(c.quantity ?? 0),
    unitCost: String(c.unitCost ?? 0),
    markupPolicy: c.markupPolicy,
    markupPercent: c.markupPercent ?? 0,
    taxable: c.taxable ?? false,
    customerVisible: c.customerVisible !== false,
    notes: c.notes,
  }));
}

function toNumber(s: string): number {
  const n = Number(s.trim());
  return Number.isFinite(n) ? n : NaN;
}

/** A row with no label and no numbers is an abandoned "Add cost" — dropped. */
function isAbandoned(d: JobCostDraft): boolean {
  return (
    d.label.trim() === '' &&
    d.quantity.trim() === '' &&
    d.unitCost.trim() === ''
  );
}

export type ParseResult =
  | { ok: true; jobCosts: JobCost[] }
  | { ok: false; error: string };

/**
 * Parse drafts into stored `JobCost[]`, or a user-facing error. Abandoned blank
 * rows are dropped; every remaining row needs a non-negative numeric quantity and
 * unit cost. Label is optional (the category names an unlabeled line). The
 * preserved knobs (markupPercent/taxable/customerVisible/notes) round-trip.
 */
export function parseJobCostDrafts(drafts: JobCostDraft[]): ParseResult {
  const jobCosts: JobCost[] = [];
  for (const d of drafts) {
    if (isAbandoned(d)) continue;
    const quantity = toNumber(d.quantity);
    const unitCost = toNumber(d.unitCost);
    if (!(quantity >= 0) || !(unitCost >= 0)) {
      return {
        ok: false,
        error: 'Cost quantity and unit cost must be non-negative numbers.',
      };
    }
    jobCosts.push({
      id: d.id,
      label: d.label.trim(),
      category: d.category,
      quantity,
      unitCost,
      markupPercent: d.markupPercent,
      markupPolicy: d.markupPolicy,
      taxable: d.taxable,
      customerVisible: d.customerVisible,
      ...(d.notes !== undefined ? { notes: d.notes } : {}),
    });
  }
  return { ok: true, jobCosts };
}
