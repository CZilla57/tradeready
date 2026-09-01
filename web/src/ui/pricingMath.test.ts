import { describe, it, expect } from 'vitest';
import type { EstimateInput } from '@shared/types/models';
import {
  calculateEstimate,
  estimateTotalFromPricing,
  defaultMarkupPolicyForCategory,
} from './pricingMath';

// Parity fixtures mirror utils/pricingEngine.test.js / pricingEngineDirectCosts
// test.js exactly — this web port must produce identical numbers, or a Pricebook
// / recurring-job estimate saved here would diverge from the mobile engine.
const BASE: EstimateInput = {
  laborHours: 0,
  laborRate: 85,
  materials: [],
  materialMarkup: 20,
  overheadPercent: 15,
  marginPercent: 20,
  travelMiles: 0,
  travelFeePerMile: 0,
  isEmergency: false,
  emergencyMultiplier: 1.5,
  minimumJobFee: 0,
  taxPercent: 0,
};

describe('calculateEstimate — labor & margin parity', () => {
  it('labor-only job: true-margin price and profit', () => {
    const r = calculateEstimate({ ...BASE, laborHours: 2, laborRate: 100 });
    expect(r.laborCost).toBe(200);
    expect(r.overheadCost).toBe(30);
    expect(r.profit).toBe(57.5); // 20% of the 287.50 price
    expect(r.total).toBe(287.5);
    expect(r.hitMinimum).toBe(false);
  });

  it('emergency multiplier applies to labor only', () => {
    const r = calculateEstimate({
      ...BASE,
      laborHours: 1,
      laborRate: 100,
      isEmergency: true,
      emergencyMultiplier: 1.5,
    });
    expect(r.laborCost).toBe(150);
  });

  it('caps margin below 100% so the price never diverges', () => {
    const r = calculateEstimate({ ...BASE, laborHours: 1, laborRate: 100, marginPercent: 100 });
    // margin clamped to 99 → cost 115 ÷ 0.01 = 11500
    expect(Number.isFinite(r.total)).toBe(true);
    expect(r.total).toBe(11500);
  });
});

describe('calculateEstimate — materials parity', () => {
  it('marks up materials by the configured percent', () => {
    const r = calculateEstimate({
      ...BASE,
      materials: [
        { name: 'Pipe', quantity: 2, unitCost: 50 },
        { name: 'Fitting', quantity: 4, unitCost: 10 },
      ],
      materialMarkup: 25,
      overheadPercent: 0,
      marginPercent: 0,
    });
    expect(r.materialBaseCost).toBe(140);
    expect(r.materialCost).toBe(175);
    expect(r.materialMarkupAmount).toBe(35);
  });

  it('non-numeric quantity/unitCost defaults to zero', () => {
    const r = calculateEstimate({
      ...BASE,
      materials: [{ name: 'x', quantity: 'abc', unitCost: 'nope' }],
    });
    expect(r.materialBaseCost).toBe(0);
  });
});

describe('calculateEstimate — direct-cost parity', () => {
  it('passthrough permit is added at cost, earning no overhead or margin', () => {
    const r = calculateEstimate({
      ...BASE,
      laborHours: 2,
      laborRate: 100,
      overheadPercent: 0,
      marginPercent: 20,
      jobCosts: [
        { label: 'City permit', category: 'permit', quantity: 1, unitCost: 150, markupPolicy: 'passthrough' },
      ],
    });
    expect(r.directCostPassthrough).toBe(150);
    expect(r.directCostMarginBase).toBe(0);
    expect(r.totalBeforeTax).toBe(400);
    expect(r.profit).toBe(50);
  });

  it('in-margin-base cost enters the subtotal with handling markup', () => {
    const r = calculateEstimate({
      ...BASE,
      overheadPercent: 10,
      marginPercent: 20,
      jobCosts: [
        { label: 'Rental', category: 'rental', quantity: 1, unitCost: 500, markupPercent: 10, markupPolicy: 'in_margin_base' },
      ],
    });
    expect(r.directCostMarginBase).toBe(550);
    expect(r.subtotal).toBe(550);
    expect(r.overheadCost).toBe(55);
    expect(r.totalBeforeTax).toBe(756.25);
  });

  it('a non-taxable permit is excluded from the taxed base', () => {
    const r = calculateEstimate({
      ...BASE,
      laborHours: 1,
      laborRate: 100, // margined 100
      overheadPercent: 0,
      marginPercent: 0,
      taxPercent: 10,
      jobCosts: [
        { label: 'Permit', category: 'permit', quantity: 1, unitCost: 200, taxable: false, markupPolicy: 'passthrough' },
      ],
    });
    expect(r.totalBeforeTax).toBe(300);
    expect(r.taxAmount).toBe(10); // (300 − 200) × 10%
  });

  it('defaultMarkupPolicyForCategory: only permits pass through', () => {
    expect(defaultMarkupPolicyForCategory('permit')).toBe('passthrough');
    expect(defaultMarkupPolicyForCategory('rental')).toBe('in_margin_base');
  });
});

describe('estimateTotalFromPricing', () => {
  it('returns the recomputed total for a saved-service pricing edit', () => {
    const total = estimateTotalFromPricing({
      laborHours: 2,
      laborRate: 100,
      materials: [],
      materialMarkup: 20,
      overheadPercent: 15,
      marginPercent: 20,
      minimumJobFee: 0,
    });
    expect(total).toBe(287.5);
  });
});
