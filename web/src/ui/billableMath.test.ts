import { describe, it, expect } from 'vitest';
import type { ChangeOrder, Job } from '@shared/types/models';
import {
  defaultDueDate,
  billableLaborHours,
  computeBillableBreakdown,
  buildInvoiceLineItems,
  computeEstimateBreakdown,
  directCostLabel,
  invoiceFromJobMode,
  jobBillableTotal,
} from './billableMath';

// Pinned to the mobile engine's own values in __tests__/autoInvoice.test.ts, so
// the web port and utils/autoInvoice can never drift. The worked example from
// the trade docs: 4h @ $85 labor ($340), $300 materials +20% ($360),
// estimateTotal $966 → residual overhead $266.
function makeJob(overrides: Partial<Job> = {}): Job {
  return {
    id: 'j1',
    title: 'Water heater swap',
    customerName: 'Jane Smith',
    customerId: 'c1',
    status: 'complete',
    laborHours: 4,
    laborRate: 85,
    materials: [
      { name: 'Heater', quantity: 1, unitCost: 200 },
      { name: 'Fittings', quantity: 2, unitCost: 50 },
    ],
    materialMarkup: 20,
    estimateTotal: 966,
    ...overrides,
  } as Job;
}

/** hours → a closed session of exactly that length. */
function closedSession(hours: number, startIso = '2026-08-01T08:00:00.000Z') {
  const start = new Date(startIso);
  const end = new Date(start.getTime() + hours * 3600000);
  return { start: start.toISOString(), end: end.toISOString() };
}

function co(partial: Partial<ChangeOrder> = {}): ChangeOrder {
  return {
    id: 'co1',
    title: 'Extra work',
    amount: 0,
    createdAt: '2026-08-01',
    ...partial,
  };
}
function approved(): ChangeOrder['approval'] {
  return { decision: 'approved' } as unknown as ChangeOrder['approval'];
}

describe('defaultDueDate', () => {
  it('is 30 days after the given date, YYYY-MM-DD', () => {
    expect(defaultDueDate(new Date('2026-08-03T12:00:00Z'))).toBe('2026-09-02');
  });
});

describe('directCostLabel', () => {
  it('prefers the line label, falls back to the category label', () => {
    expect(directCostLabel({ label: 'City permit', category: 'permit' })).toBe('City permit');
    expect(directCostLabel({ label: '  ', category: 'disposal' })).toBe('Disposal');
    expect(directCostLabel({ category: 'rental' })).toBe('Equipment rental');
  });
});

describe('computeEstimateBreakdown', () => {
  it('trusts the stored total and makes overhead the residual', () => {
    const b = computeEstimateBreakdown(makeJob());
    expect(b).toMatchObject({
      laborCost: 340,
      materialCost: 360,
      overheadLine: 266,
      estimateTotal: 966,
      hasMaterials: true,
    });
  });

  it('a customer-visible direct cost bills as its own line; overhead absorbs the rest', () => {
    const job = makeJob({
      jobCosts: [
        { id: 'k1', label: 'Dumpster', category: 'disposal', quantity: 1, unitCost: 100, markupPolicy: 'passthrough', customerVisible: true },
      ],
      estimateTotal: 1066,
    });
    const b = computeEstimateBreakdown(job);
    expect(b.directCostLines).toHaveLength(1);
    expect(b.directCostLines[0]).toMatchObject({ amount: 100, customerVisible: true });
    // 1066 − 340 − 360 − 100 = 266
    expect(b.overheadLine).toBe(266);
  });
});

describe('billableLaborHours', () => {
  it('no sessions → estimated hours, not tracked', () => {
    expect(billableLaborHours(makeJob())).toEqual({ hours: 4, usedTrackedTime: false });
  });

  it('completed sessions on a done, hourly-priced job → tracked hours', () => {
    expect(billableLaborHours(makeJob({ timeSessions: [closedSession(5.5)] }))).toEqual({
      hours: 5.5,
      usedTrackedTime: true,
    });
  });

  it('multiple sessions accumulate; a still-open session is excluded', () => {
    const job = makeJob({
      timeSessions: [
        closedSession(2),
        closedSession(1.5, '2026-08-01T13:00:00.000Z'),
        { start: '2026-08-01T16:00:00.000Z', end: null },
      ],
    });
    expect(billableLaborHours(job)).toEqual({ hours: 3.5, usedTrackedTime: true });
  });

  it('flat-priced (laborHours 0) or unpriced (rate 0) labor never bills tracked time', () => {
    expect(billableLaborHours(makeJob({ laborHours: 0, timeSessions: [closedSession(3)] }))).toEqual({
      hours: 0,
      usedTrackedTime: false,
    });
    expect(billableLaborHours(makeJob({ laborRate: 0, timeSessions: [closedSession(3)] }))).toEqual({
      hours: 4,
      usedTrackedTime: false,
    });
  });

  it('a pre-complete (deposit) status bills the estimate, not tracked time', () => {
    const job = makeJob({ status: 'in_progress', timeSessions: [closedSession(3)] });
    expect(billableLaborHours(job)).toEqual({ hours: 4, usedTrackedTime: false });
  });

  it('rounds tracked hours to 2 decimals; a sub-rounding total falls back to the estimate', () => {
    expect(billableLaborHours(makeJob({ timeSessions: [closedSession(1.175)] }))).toEqual({
      hours: 1.18,
      usedTrackedTime: true,
    });
    expect(billableLaborHours(makeJob({ timeSessions: [closedSession(10 / 3600)] }))).toEqual({
      hours: 4,
      usedTrackedTime: false,
    });
  });
});

describe('computeBillableBreakdown', () => {
  it('without tracked time, mirrors the quoted breakdown', () => {
    expect(computeBillableBreakdown(makeJob())).toMatchObject({
      laborHours: 4,
      laborCost: 340,
      materialCost: 360,
      overheadLine: 266,
      usedTrackedTime: false,
      changeOrderTotal: 0,
      total: 966,
    });
  });

  it('tracked over estimate: total rises by the hour delta at the labor rate', () => {
    const b = computeBillableBreakdown(makeJob({ timeSessions: [closedSession(5.5)] }));
    expect(b.laborHours).toBe(5.5);
    expect(b.laborCost).toBe(467.5);
    expect(b.total).toBe(1093.5); // 966 + 1.5h × $85
    expect(b.laborCost + b.materialCost + b.overheadLine).toBeCloseTo(b.total, 2);
  });

  it('tracked under estimate: total drops by the hour delta', () => {
    const b = computeBillableBreakdown(makeJob({ timeSessions: [closedSession(2)] }));
    expect(b.laborCost).toBe(170);
    expect(b.total).toBe(796); // 966 − 2h × $85
    expect(b.laborCost + b.materialCost + b.overheadLine).toBeCloseTo(b.total, 2);
  });

  it('adds approved change orders to the total', () => {
    const b = computeBillableBreakdown(makeJob({ changeOrders: [co({ amount: 150, approval: approved() })] }));
    expect(b.changeOrderTotal).toBe(150);
    expect(b.total).toBe(1116); // 966 + 150
  });

  it('ignores an unapproved change order', () => {
    const b = computeBillableBreakdown(makeJob({ changeOrders: [co({ amount: 150 })] }));
    expect(b.changeOrderTotal).toBe(0);
    expect(b.total).toBe(966);
  });
});

describe('buildInvoiceLineItems', () => {
  it('bills tracked hours and the lines sum to the billable total', () => {
    const job = makeJob({ timeSessions: [closedSession(5.5)] });
    const items = buildInvoiceLineItems(job);
    expect(items).toHaveLength(3);
    expect(items[0]).toEqual({ description: 'Labor — 5.5 hrs @ $85/hr', amount: 467.5, category: 'labor' });
    expect(items[1]).toMatchObject({ amount: 360, category: 'materials' });
    expect(items[2]).toMatchObject({ amount: 266, category: 'overhead' });
    const sum = items.reduce((s, i) => s + i.amount, 0);
    expect(sum).toBeCloseTo(computeBillableBreakdown(job).total, 2);
  });

  it('without tracked time, matches the estimated-hours labor line', () => {
    expect(buildInvoiceLineItems(makeJob())[0]).toEqual({
      description: 'Labor — 4 hrs @ $85/hr',
      amount: 340,
      category: 'labor',
    });
  });

  it('appends each approved change order as an `other` line', () => {
    const job = makeJob({
      changeOrders: [
        co({ id: 'coA', title: 'Add shutoff valve', amount: 90, approval: approved() }),
        co({ id: 'coB', title: 'Pending extra', amount: 40 }),
      ],
    });
    const items = buildInvoiceLineItems(job);
    const other = items.filter((i) => i.category === 'other');
    expect(other).toEqual([{ description: 'Change order — Add shutoff valve', amount: 90, category: 'other' }]);
  });

  it('names a single material by its name and multiples by count', () => {
    expect(buildInvoiceLineItems(makeJob())[1].description).toBe('Materials (2 items)');
    const single = makeJob({ materials: [{ name: 'Heater', quantity: 1, unitCost: 300 }] });
    expect(buildInvoiceLineItems(single)[1].description).toBe('Heater');
  });
});

describe('invoiceFromJobMode', () => {
  it('maps a completed job with no invoice to "create"', () => {
    expect(invoiceFromJobMode('complete', false)).toBe('create');
  });
  it('maps a completed job that already has an invoice to "finalize"', () => {
    expect(invoiceFromJobMode('complete', true)).toBe('finalize');
  });
  it('maps deposit-eligible statuses with no invoice to "requestDeposit"', () => {
    for (const s of ['approved', 'scheduled', 'in_progress'] as const) {
      expect(invoiceFromJobMode(s, false)).toBe('requestDeposit');
    }
  });
  it('returns null when the estimate is unapproved or the job is not billable', () => {
    expect(invoiceFromJobMode('lead', false)).toBeNull();
    expect(invoiceFromJobMode('quoted', false)).toBeNull();
    // A deposit-eligible status that already has an invoice can't create another.
    expect(invoiceFromJobMode('scheduled', true)).toBeNull();
  });
});

describe('jobBillableTotal', () => {
  it('is estimateTotal plus approved change orders', () => {
    expect(jobBillableTotal(makeJob())).toBe(966);
    expect(jobBillableTotal(makeJob({ changeOrders: [co({ amount: 50, approval: approved() })] }))).toBe(1016);
  });
});
