import { describe, it, expect } from 'vitest';
import {
  blankMaterialDraft,
  materialsToDrafts,
  parseMaterialDrafts,
  draftsBaseCost,
  type MaterialDraft,
} from './materialsDraft';

function draft(over: Partial<MaterialDraft> = {}): MaterialDraft {
  return { id: 'm1', name: 'Pipe', quantity: '2', unitCost: '5', ...over };
}

describe('materialsDraft helpers', () => {
  it('blankMaterialDraft seeds qty 1 / cost 0 with a mobile-format id', () => {
    const d = blankMaterialDraft();
    expect(d).toMatchObject({ name: '', quantity: '1', unitCost: '0' });
    expect(d.id).toMatch(/^m\d+$/);
    expect(blankMaterialDraft().id).not.toBe(d.id); // unique within a burst
  });

  it('materialsToDrafts stringifies stored numbers for editing', () => {
    expect(
      materialsToDrafts([{ id: 'm9', name: 'Wire', quantity: 3, unitCost: 1.5 }]),
    ).toEqual([{ id: 'm9', name: 'Wire', quantity: '3', unitCost: '1.5' }]);
    expect(materialsToDrafts(undefined)).toEqual([]);
  });

  it('parseMaterialDrafts converts valid drafts to stored numeric materials', () => {
    const res = parseMaterialDrafts([draft({ quantity: '2', unitCost: '5.25' })]);
    expect(res).toEqual({
      ok: true,
      materials: [{ id: 'm1', name: 'Pipe', quantity: 2, unitCost: 5.25 }],
    });
  });

  it('drops an abandoned blank row (name + numbers all empty)', () => {
    const res = parseMaterialDrafts([
      draft(),
      { id: 'm2', name: '', quantity: '', unitCost: '' },
    ]);
    expect(res.ok).toBe(true);
    if (res.ok) expect(res.materials).toHaveLength(1);
  });

  it('rejects a row with numbers but no name', () => {
    const res = parseMaterialDrafts([{ id: 'm2', name: '  ', quantity: '1', unitCost: '2' }]);
    expect(res).toMatchObject({ ok: false });
    if (!res.ok) expect(res.error).toMatch(/name/i);
  });

  it('rejects a negative or non-numeric quantity/cost', () => {
    expect(parseMaterialDrafts([draft({ quantity: '-1' })]).ok).toBe(false);
    expect(parseMaterialDrafts([draft({ unitCost: 'abc' })]).ok).toBe(false);
  });

  it('draftsBaseCost sums qty×unitCost, treating blanks as 0', () => {
    expect(
      draftsBaseCost([
        draft({ quantity: '2', unitCost: '5' }), // 10
        draft({ id: 'm2', quantity: '', unitCost: '9' }), // 0
        draft({ id: 'm3', quantity: '3', unitCost: '4' }), // 12
      ]),
    ).toBe(22);
  });
});
