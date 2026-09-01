import { describe, it, expect } from 'vitest';
import {
  blankJobCostDraft,
  jobCostsToDrafts,
  parseJobCostDrafts,
  directCostLabel,
  type JobCostDraft,
} from './jobCostsDraft';
import type { JobCost } from '@shared/types/models';

function draft(over: Partial<JobCostDraft> = {}): JobCostDraft {
  return {
    id: 'jc1',
    label: 'Permit fee',
    category: 'permit',
    quantity: '1',
    unitCost: '120',
    markupPolicy: 'passthrough',
    markupPercent: 0,
    taxable: false,
    customerVisible: true,
    ...over,
  };
}

describe('jobCostsDraft helpers', () => {
  it('blankJobCostDraft seeds an "other" priced-in line with a mobile-format id', () => {
    const d = blankJobCostDraft();
    expect(d).toMatchObject({
      label: '',
      category: 'other',
      quantity: '1',
      unitCost: '0',
      markupPolicy: 'in_margin_base',
      customerVisible: true,
    });
    expect(d.id).toMatch(/^jc\d+_\d+$/);
    expect(blankJobCostDraft().id).not.toBe(d.id);
  });

  it('directCostLabel falls back to the category label when unlabeled', () => {
    expect(directCostLabel('permit', '')).toBe('Permit');
    expect(directCostLabel('permit', ' City permit ')).toBe('City permit');
  });

  it('jobCostsToDrafts stringifies numbers and carries the advanced knobs', () => {
    const cost: JobCost = {
      id: 'jc9',
      label: 'Sub',
      category: 'subcontractor',
      quantity: 2,
      unitCost: 300,
      markupPercent: 15,
      markupPolicy: 'in_margin_base',
      taxable: true,
      customerVisible: false,
      notes: 'electrician',
    };
    expect(jobCostsToDrafts([cost])).toEqual([
      {
        id: 'jc9',
        label: 'Sub',
        category: 'subcontractor',
        quantity: '2',
        unitCost: '300',
        markupPolicy: 'in_margin_base',
        markupPercent: 15,
        taxable: true,
        customerVisible: false,
        notes: 'electrician',
      },
    ]);
    expect(jobCostsToDrafts(undefined)).toEqual([]);
  });

  it('parseJobCostDrafts converts valid drafts, preserving the advanced knobs', () => {
    const res = parseJobCostDrafts([
      draft({ markupPercent: 10, taxable: true, customerVisible: false, notes: 'x' }),
    ]);
    expect(res).toEqual({
      ok: true,
      jobCosts: [
        {
          id: 'jc1',
          label: 'Permit fee',
          category: 'permit',
          quantity: 1,
          unitCost: 120,
          markupPercent: 10,
          markupPolicy: 'passthrough',
          taxable: true,
          customerVisible: false,
          notes: 'x',
        },
      ],
    });
  });

  it('keeps an unlabeled line (the category names it) but drops a fully-blank one', () => {
    const res = parseJobCostDrafts([
      draft({ label: '' }), // unlabeled but has a cost → kept
      { ...draft({ id: 'jc2' }), label: '', quantity: '', unitCost: '' }, // abandoned → dropped
    ]);
    expect(res.ok).toBe(true);
    if (res.ok) {
      expect(res.jobCosts).toHaveLength(1);
      expect(res.jobCosts[0].label).toBe('');
    }
  });

  it('rejects a negative or non-numeric quantity/cost', () => {
    expect(parseJobCostDrafts([draft({ unitCost: '-5' })]).ok).toBe(false);
    expect(parseJobCostDrafts([draft({ quantity: 'abc' })]).ok).toBe(false);
  });
});
