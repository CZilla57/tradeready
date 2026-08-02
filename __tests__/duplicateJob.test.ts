// __tests__/duplicateJob.test.ts
// Pins the "Duplicate job" carry rules (utils/duplicateJob.ts): descriptive
// fields and pricing carry to the new job; schedule, pipeline status, invoice
// link, estimate/approval stamps, photos, and time sessions do NOT.

import { buildDuplicatePrefill, buildDuplicatePricing } from '../utils/duplicateJob';
import type { Job } from '../types/models';

function job(overrides: Partial<Job> = {}): Job {
  return {
    id: 'j1',
    customerId: 'c1',
    customerName: 'Dana Fixture',
    title: 'Replace water heater',
    description: '50-gal gas unit',
    status: 'paid',
    scheduledDate: '2026-07-01',
    scheduledStartTime: '08:00',
    scheduledEndTime: '12:00',
    address: '12 Main St',
    estimateTotal: 1450,
    laborHours: 4,
    laborRate: 95,
    materials: [{ id: 'm1', name: 'Heater', quantity: 1, unitCost: 600 }],
    materialMarkup: 25,
    overhead: 15,
    margin: 20,
    notes: 'Gate code 4411',
    invoiceId: 'inv_9',
    createdAt: '2026-06-28',
    photos: ['file:///p.jpg'],
    timeSessions: [{ start: '2026-07-01T08:00:00Z', end: '2026-07-01T12:00:00Z' }],
    estimateSentAt: '2026-06-29',
    ...overrides,
  } as Job;
}

describe('buildDuplicatePrefill', () => {
  test('carries customer, title, description, address, notes', () => {
    expect(buildDuplicatePrefill(job())).toEqual({
      customerId: 'c1',
      customerName: 'Dana Fixture',
      title: 'Replace water heater',
      description: '50-gal gas unit',
      address: '12 Main St',
      notes: 'Gate code 4411',
    });
  });

  test('does not expose schedule, status, or lifecycle fields', () => {
    const prefill = buildDuplicatePrefill(job()) as Record<string, unknown>;
    for (const key of [
      'scheduledDate', 'scheduledStartTime', 'scheduledEndTime',
      'status', 'invoiceId', 'estimateSentAt', 'approval', 'photos', 'timeSessions',
    ]) {
      expect(prefill).not.toHaveProperty(key);
    }
  });

  test('blank-tolerant on legacy jobs missing fields', () => {
    const legacy = job({
      customerId: undefined, notes: undefined, address: undefined,
    } as unknown as Partial<Job>);
    expect(buildDuplicatePrefill(legacy)).toEqual({
      customerId: '',
      customerName: 'Dana Fixture',
      title: 'Replace water heater',
      description: '50-gal gas unit',
      address: '',
      notes: '',
    });
  });
});

describe('buildDuplicatePricing', () => {
  test('carries the full pricing block', () => {
    expect(buildDuplicatePricing(job())).toEqual({
      estimateTotal: 1450,
      laborHours: 4,
      laborRate: 95,
      materials: [{ id: 'm1', name: 'Heater', quantity: 1, unitCost: 600 }],
      materialMarkup: 25,
      overhead: 15,
      margin: 20,
    });
  });

  test('deep-copies materials so the duplicate cannot mutate the original', () => {
    const source = job();
    const pricing = buildDuplicatePricing(source);
    expect(pricing.materials).not.toBe(source.materials);
    expect(pricing.materials[0]).not.toBe(source.materials[0]);
    pricing.materials[0].unitCost = 999;
    expect(source.materials[0].unitCost).toBe(600);
  });

  test('zero-defaults on legacy jobs missing pricing fields', () => {
    const legacy = job({
      estimateTotal: undefined, laborHours: undefined, laborRate: undefined,
      materials: undefined, materialMarkup: undefined, overhead: undefined, margin: undefined,
    } as unknown as Partial<Job>);
    expect(buildDuplicatePricing(legacy)).toEqual({
      estimateTotal: 0,
      laborHours: 0,
      laborRate: 0,
      materials: [],
      materialMarkup: 0,
      overhead: 0,
      margin: 0,
    });
  });
});
