// web/src/ui/materialsDraft.ts
//
// Pure helpers behind the reusable MaterialsEditor (roadmap P3 — line-item
// authoring). Kept out of the .tsx component file so the component module only
// exports a component (react-refresh) and so the parse/seed logic is unit-
// testable without rendering.
//
// The editor is STRING-drafted, matching how the pricing scalar fields are held
// across the portal (useState(String(...)) then parse on save): keeping the raw
// text lets the owner type "1." / "" mid-edit without the value snapping to a
// number, and `parseMaterialDrafts` turns the drafts into stored `Material[]`
// (or an error) only at save time. New ids match the mobile format `m<Date.now()>`
// (screens/PricingCalculatorScreen.tsx), monotonic-guarded for burst uniqueness
// (P1.4), so a portal-authored material is indistinguishable from a phone one.

import type { Material } from '@shared/types/models';

/** A row while it is being edited: quantity/unitCost are raw text, not numbers. */
export interface MaterialDraft {
  id: string;
  name: string;
  quantity: string;
  unitCost: string;
}

let _matLastMs = 0;
function newMaterialId(): string {
  let ms = Date.now();
  if (ms <= _matLastMs) ms = _matLastMs + 1;
  _matLastMs = ms;
  return `m${ms}`;
}

/** A freshly-added row: mobile seeds a new material as qty 1, cost 0. */
export function blankMaterialDraft(): MaterialDraft {
  return { id: newMaterialId(), name: '', quantity: '1', unitCost: '0' };
}

/** Seed editable drafts from a record's stored materials. */
export function materialsToDrafts(
  materials: Material[] | undefined,
): MaterialDraft[] {
  return (materials ?? []).map((m) => ({
    id: m.id,
    name: m.name ?? '',
    quantity: String(m.quantity ?? 0),
    unitCost: String(m.unitCost ?? 0),
  }));
}

function toNumber(s: string): number {
  const n = Number(s.trim());
  return Number.isFinite(n) ? n : NaN;
}

/** A row with no name and no numbers is an abandoned "Add material" — dropped
 *  on save rather than written as an empty material. */
function isAbandoned(d: MaterialDraft): boolean {
  return (
    d.name.trim() === '' &&
    d.quantity.trim() === '' &&
    d.unitCost.trim() === ''
  );
}

export type ParseResult =
  | { ok: true; materials: Material[] }
  | { ok: false; error: string };

/**
 * Parse drafts into stored `Material[]`, or a user-facing error. Abandoned blank
 * rows are dropped; every remaining row needs a name and a non-negative numeric
 * quantity and unit cost.
 */
export function parseMaterialDrafts(drafts: MaterialDraft[]): ParseResult {
  const materials: Material[] = [];
  for (const d of drafts) {
    if (isAbandoned(d)) continue;
    const name = d.name.trim();
    if (!name) return { ok: false, error: 'Every material needs a name.' };
    const quantity = toNumber(d.quantity);
    const unitCost = toNumber(d.unitCost);
    if (!(quantity >= 0) || !(unitCost >= 0)) {
      return {
        ok: false,
        error: 'Material quantity and unit cost must be non-negative numbers.',
      };
    }
    materials.push({ id: d.id, name, quantity, unitCost });
  }
  return { ok: true, materials };
}

/** Live base cost (Σ qty×unitCost) for the current drafts — a running preview;
 *  the priced total additionally applies the material markup. Blanks read as 0. */
export function draftsBaseCost(drafts: MaterialDraft[]): number {
  return drafts.reduce((sum, d) => {
    const q = Number(d.quantity) || 0;
    const u = Number(d.unitCost) || 0;
    return sum + q * u;
  }, 0);
}
