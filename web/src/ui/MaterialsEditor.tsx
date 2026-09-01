// web/src/ui/MaterialsEditor.tsx
//
// A reusable materials / line-item editor (roadmap P3 — line-item authoring).
// A saved service, a job estimate, and a recurring-job rule all price the same
// `Material[]` (id, name, quantity, unitCost) through the shared estimate math
// (Σ qty×unitCost × (1 + markup%)), so the row editor lives here once and every
// pricing surface renders it. The pure draft/parse helpers live in
// `./materialsDraft` (kept separate so this file only exports a component).

import { formatMoney } from '@shared/utils/format';
import {
  blankMaterialDraft,
  draftsBaseCost,
  type MaterialDraft,
} from './materialsDraft';

export function MaterialsEditor({
  drafts,
  onChange,
  disabled = false,
}: {
  drafts: MaterialDraft[];
  onChange: (next: MaterialDraft[]) => void;
  disabled?: boolean;
}) {
  const update = (id: string, patch: Partial<MaterialDraft>) =>
    onChange(drafts.map((d) => (d.id === id ? { ...d, ...patch } : d)));
  const remove = (id: string) => onChange(drafts.filter((d) => d.id !== id));
  const add = () => onChange([...drafts, blankMaterialDraft()]);

  return (
    <div>
      <div className="section-label" style={{ padding: '4px 0 0' }}>
        Materials
      </div>
      {drafts.length === 0 ? (
        <div className="meta" style={{ padding: '4px 0' }}>
          No materials.
        </div>
      ) : (
        <div className="list">
          {drafts.map((d) => (
            <div key={d.id} className="btn-row" style={{ alignItems: 'flex-end' }}>
              <label className="field" style={{ flex: 2 }}>
                <span>Material</span>
                <input
                  className="field-input"
                  type="text"
                  aria-label="Material name"
                  value={d.name}
                  onChange={(e) => update(d.id, { name: e.target.value })}
                  disabled={disabled}
                />
              </label>
              <label className="field" style={{ flex: 1 }}>
                <span>Qty</span>
                <input
                  className="field-input"
                  type="text"
                  inputMode="decimal"
                  aria-label="Material quantity"
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
                  aria-label="Material unit cost"
                  value={d.unitCost}
                  onChange={(e) => update(d.id, { unitCost: e.target.value })}
                  disabled={disabled}
                />
              </label>
              <button
                type="button"
                className="btn ghost sm"
                aria-label={`Remove ${d.name.trim() || 'material'}`}
                onClick={() => remove(d.id)}
                disabled={disabled}
              >
                Remove
              </button>
            </div>
          ))}
        </div>
      )}
      <div
        className="btn-row"
        style={{ justifyContent: 'space-between', alignItems: 'center', marginTop: 8 }}
      >
        <button type="button" className="btn ghost sm" onClick={add} disabled={disabled}>
          + Add material
        </button>
        <span className="meta">
          Materials cost: {formatMoney(draftsBaseCost(drafts))}
        </span>
      </div>
    </div>
  );
}
