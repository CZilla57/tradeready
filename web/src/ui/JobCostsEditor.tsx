// web/src/ui/JobCostsEditor.tsx
//
// A reusable direct-cost (job cost) line editor (roadmap P3 — direct-cost
// authoring), parallel to MaterialsEditor. Exposes label, category, quantity,
// and unit cost; the markup POLICY follows the category (permits pass through at
// cost, everything else is priced into the margin) so changing the category
// re-derives it. The advanced per-line knobs are preserved by the draft helpers
// (see jobCostsDraft.ts). Pure helpers live in ./jobCostsDraft so this file only
// exports a component.

import { formatMoney } from '@shared/utils/format';
import { defaultMarkupPolicyForCategory } from './pricingMath';
import {
  JOB_COST_CATEGORIES,
  blankJobCostDraft,
  type JobCostDraft,
} from './jobCostsDraft';
import type { JobCostCategory } from '@shared/types/models';

function lineCost(d: JobCostDraft): number {
  return (Number(d.quantity) || 0) * (Number(d.unitCost) || 0);
}

export function JobCostsEditor({
  drafts,
  onChange,
  disabled = false,
}: {
  drafts: JobCostDraft[];
  onChange: (next: JobCostDraft[]) => void;
  disabled?: boolean;
}) {
  const update = (id: string, patch: Partial<JobCostDraft>) =>
    onChange(drafts.map((d) => (d.id === id ? { ...d, ...patch } : d)));
  const remove = (id: string) => onChange(drafts.filter((d) => d.id !== id));
  const add = () => onChange([...drafts, blankJobCostDraft()]);

  // Changing the category re-derives the markup policy (its category default),
  // matching the guides' standard so the line prices correctly without exposing
  // the policy knob.
  const changeCategory = (id: string, category: JobCostCategory) =>
    update(id, { category, markupPolicy: defaultMarkupPolicyForCategory(category) });

  return (
    <div>
      <div className="section-label" style={{ padding: '4px 0 0' }}>
        Other costs
      </div>
      {drafts.length === 0 ? (
        <div className="meta" style={{ padding: '4px 0' }}>
          No direct costs (permits, disposal, subcontractors…).
        </div>
      ) : (
        <div className="list">
          {drafts.map((d) => (
            <div
              key={d.id}
              style={{ padding: '8px 0', borderTop: '1px solid var(--hairline, #e5e5e5)' }}
            >
              <div className="btn-row" style={{ alignItems: 'flex-end' }}>
                <label className="field" style={{ flex: 2 }}>
                  <span>Description</span>
                  <input
                    className="field-input"
                    type="text"
                    aria-label="Cost description"
                    value={d.label}
                    onChange={(e) => update(d.id, { label: e.target.value })}
                    disabled={disabled}
                  />
                </label>
                <label className="field" style={{ flex: 1 }}>
                  <span>Category</span>
                  <select
                    className="field-input"
                    aria-label="Cost category"
                    value={d.category}
                    onChange={(e) => changeCategory(d.id, e.target.value as JobCostCategory)}
                    disabled={disabled}
                  >
                    {JOB_COST_CATEGORIES.map((c) => (
                      <option key={c.id} value={c.id}>
                        {c.label}
                      </option>
                    ))}
                  </select>
                </label>
              </div>
              <div className="btn-row" style={{ alignItems: 'flex-end' }}>
                <label className="field" style={{ flex: 1 }}>
                  <span>Qty</span>
                  <input
                    className="field-input"
                    type="text"
                    inputMode="decimal"
                    aria-label="Cost quantity"
                    value={d.quantity}
                    onChange={(e) => update(d.id, { quantity: e.target.value })}
                    disabled={disabled}
                  />
                </label>
                <label className="field" style={{ flex: 1 }}>
                  <span>Unit cost ($)</span>
                  <input
                    className="field-input"
                    type="text"
                    inputMode="decimal"
                    aria-label="Cost unit cost"
                    value={d.unitCost}
                    onChange={(e) => update(d.id, { unitCost: e.target.value })}
                    disabled={disabled}
                  />
                </label>
                <span className="meta" style={{ flex: 1 }}>
                  {d.markupPolicy === 'passthrough' ? 'At cost' : 'Priced in'} ·{' '}
                  {formatMoney(lineCost(d))}
                </span>
                <button
                  type="button"
                  className="btn ghost sm"
                  aria-label={`Remove ${d.label.trim() || 'cost'}`}
                  onClick={() => remove(d.id)}
                  disabled={disabled}
                >
                  Remove
                </button>
              </div>
            </div>
          ))}
        </div>
      )}
      <div className="btn-row" style={{ marginTop: 8 }}>
        <button type="button" className="btn ghost sm" onClick={add} disabled={disabled}>
          + Add cost
        </button>
      </div>
    </div>
  );
}
