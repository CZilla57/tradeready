import {
  calculateEstimate,
  calculatePriceRange,
  breakEvenPrice,
  getTradeNickname,
  formatCurrency,
} from "../utils/pricingEngine";

// Shared base params — override specific fields per test
const BASE = {
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

describe("calculateEstimate — labor", () => {
  test("labor-only job computes correctly end-to-end", () => {
    const r = calculateEstimate({ ...BASE, laborHours: 2, laborRate: 100 });
    // labor = 2 × 100 = 200
    expect(r.laborCost).toBe(200);
    // overhead = 200 × 0.15 = 30
    expect(r.overheadCost).toBe(30);
    // profit base = 200 + 30 = 230; profit = 230 × 0.20 = 46
    expect(r.profit).toBe(46);
    // total = 230 + 46 = 276
    expect(r.total).toBe(276);
    expect(r.hitMinimum).toBe(false);
  });

  test("emergency call applies multiplier to labor only", () => {
    const normal = calculateEstimate({ ...BASE, laborHours: 1, laborRate: 100 });
    const emergency = calculateEstimate({
      ...BASE,
      laborHours: 1,
      laborRate: 100,
      isEmergency: true,
      emergencyMultiplier: 1.5,
    });
    expect(emergency.laborCost).toBe(150);
    expect(normal.laborCost).toBe(100);
  });

  test("zero hours produces zero labor cost", () => {
    const r = calculateEstimate({ ...BASE, laborHours: 0, laborRate: 100 });
    expect(r.laborCost).toBe(0);
  });
});

describe("calculateEstimate — materials", () => {
  test("marks up materials by the configured percent", () => {
    const r = calculateEstimate({
      ...BASE,
      materials: [
        { name: "Pipe", quantity: 2, unitCost: 50 },
        { name: "Fitting", quantity: 4, unitCost: 10 },
      ],
      materialMarkup: 25,
      overheadPercent: 0,
      marginPercent: 0,
    });
    // base = 2×50 + 4×10 = 140; with 25% markup = 175
    expect(r.materialBaseCost).toBe(140);
    expect(r.materialCost).toBe(175);
    expect(r.materialMarkupAmount).toBe(35);
  });

  test("materials with zero markup pass through unchanged", () => {
    const r = calculateEstimate({
      ...BASE,
      materials: [{ name: "Wire", quantity: 10, unitCost: 3 }],
      materialMarkup: 0,
      overheadPercent: 0,
      marginPercent: 0,
    });
    expect(r.materialCost).toBe(30);
    expect(r.materialMarkupAmount).toBe(0);
  });

  test("non-numeric quantity/unitCost defaults to zero", () => {
    const r = calculateEstimate({
      ...BASE,
      materials: [{ name: "Widget", quantity: "", unitCost: "abc" }],
      overheadPercent: 0,
      marginPercent: 0,
    });
    expect(r.materialBaseCost).toBe(0);
  });
});

describe("calculateEstimate — travel", () => {
  test("travel cost added to subtotal", () => {
    const r = calculateEstimate({
      ...BASE,
      travelMiles: 40,
      travelFeePerMile: 0.67,
      overheadPercent: 0,
      marginPercent: 0,
    });
    expect(r.travelCost).toBe(26.8);
    expect(r.subtotal).toBe(26.8);
  });

  test("zero travel fee produces zero travel cost", () => {
    const r = calculateEstimate({ ...BASE, travelMiles: 100, travelFeePerMile: 0 });
    expect(r.travelCost).toBe(0);
  });
});

describe("calculateEstimate — minimum job fee", () => {
  test("hits minimum when calculated total is below floor", () => {
    const r = calculateEstimate({
      ...BASE,
      laborHours: 0.1,
      laborRate: 10,
      minimumJobFee: 75,
      overheadPercent: 0,
      marginPercent: 0,
    });
    expect(r.totalBeforeTax).toBe(75);
    expect(r.hitMinimum).toBe(true);
  });

  test("does not hit minimum when total exceeds floor", () => {
    const r = calculateEstimate({
      ...BASE,
      laborHours: 5,
      laborRate: 100,
      minimumJobFee: 75,
      overheadPercent: 0,
      marginPercent: 0,
    });
    expect(r.hitMinimum).toBe(false);
    expect(r.totalBeforeTax).toBe(500);
  });
});

describe("calculateEstimate — tax", () => {
  test("tax applied on top of pre-tax total", () => {
    const r = calculateEstimate({
      ...BASE,
      laborHours: 1,
      laborRate: 100,
      overheadPercent: 0,
      marginPercent: 0,
      taxPercent: 10,
    });
    expect(r.totalBeforeTax).toBe(100);
    expect(r.taxAmount).toBe(10);
    expect(r.total).toBe(110);
  });

  test("zero tax produces no tax amount", () => {
    const r = calculateEstimate({ ...BASE, laborHours: 1, laborRate: 100, taxPercent: 0 });
    expect(r.taxAmount).toBe(0);
  });
});

describe("calculateEstimate — emergency multiplier isolation", () => {
  test("emergency multiplier raises labor cost but leaves material cost unchanged", () => {
    const materials = [{ name: "Pipe", quantity: 1, unitCost: 100 }];
    const normal = calculateEstimate({
      ...BASE,
      laborHours: 1, laborRate: 100,
      materials, materialMarkup: 0,
      overheadPercent: 0, marginPercent: 0,
    });
    const emergency = calculateEstimate({
      ...BASE,
      laborHours: 1, laborRate: 100,
      materials, materialMarkup: 0,
      overheadPercent: 0, marginPercent: 0,
      isEmergency: true, emergencyMultiplier: 2,
    });

    // Labor doubles; materials stay flat
    expect(emergency.laborCost).toBe(200);
    expect(emergency.materialCost).toBe(100);
    expect(normal.materialCost).toBe(100);
    // Net difference is exactly the extra labor
    expect(emergency.total - normal.total).toBe(100);
  });
});

describe("calculateEstimate — minimum fee interaction with tax", () => {
  test("tax is applied on the minimum fee amount, not the pre-minimum calculated total", () => {
    // $5 labor (0.05 hrs × $100) < $75 minimum → totalBeforeTax must be $75
    // Tax is then 10% of $75 = $7.50, not 10% of $5
    const r = calculateEstimate({
      ...BASE,
      laborHours: 0.05, laborRate: 100,
      overheadPercent: 0, marginPercent: 0,
      minimumJobFee: 75,
      taxPercent: 10,
    });

    expect(r.hitMinimum).toBe(true);
    expect(r.totalBeforeTax).toBe(75);
    expect(r.taxAmount).toBe(7.5);
    expect(r.total).toBe(82.5);
  });

  test("when total exceeds minimum, tax applies on the real total, not the minimum", () => {
    const r = calculateEstimate({
      ...BASE,
      laborHours: 5, laborRate: 100,
      overheadPercent: 0, marginPercent: 0,
      minimumJobFee: 75,
      taxPercent: 10,
    });

    expect(r.hitMinimum).toBe(false);
    expect(r.totalBeforeTax).toBe(500);
    expect(r.taxAmount).toBe(50);
    expect(r.total).toBe(550);
  });
});

describe("calculateEstimate — all factors combined", () => {
  test("labor + materials + markup + overhead + margin + emergency + tax all compose correctly", () => {
    // Verify each intermediate and the final total in one end-to-end case.
    // labor: 2h × $100 × 1.5 (emergency) = $300
    // materialBase: 2 × $50 = $100; with 25% markup → $125
    // subtotal: $300 + $125 = $425
    // overhead: $425 × 10% = $42.50
    // profitBase: $425 + $42.50 = $467.50; margin 20% → $93.50
    // preTaxTotal: $467.50 + $93.50 = $561   (> minimum $50 → no floor)
    // tax: $561 × 8% = $44.88
    // total: $561 + $44.88 = $605.88
    const r = calculateEstimate({
      laborHours: 2,
      laborRate: 100,
      materials: [{ name: "Part", quantity: 2, unitCost: 50 }],
      materialMarkup: 25,
      overheadPercent: 10,
      marginPercent: 20,
      travelMiles: 0,
      travelFeePerMile: 0,
      isEmergency: true,
      emergencyMultiplier: 1.5,
      minimumJobFee: 50,
      taxPercent: 8,
    });

    expect(r.laborCost).toBe(300);
    expect(r.materialBaseCost).toBe(100);
    expect(r.materialCost).toBe(125);
    expect(r.subtotal).toBe(425);
    expect(r.overheadCost).toBe(42.5);
    expect(r.profit).toBe(93.5);
    expect(r.preTaxTotal).toBe(561);
    expect(r.hitMinimum).toBe(false);
    expect(r.totalBeforeTax).toBe(561);
    expect(r.taxAmount).toBe(44.88);
    expect(r.total).toBe(605.88);
  });
});

describe("calculatePriceRange", () => {
  const params = { ...BASE, laborHours: 2, laborRate: 100, minimumJobFee: 75 };

  test("low < recommended < high", () => {
    const range = calculatePriceRange(params);
    expect(range.low).toBeLessThan(range.recommended);
    expect(range.recommended).toBeLessThan(range.high);
  });

  test("includes a breakdown object", () => {
    const range = calculatePriceRange(params);
    expect(range.breakdown).toBeDefined();
    expect(range.breakdown.total).toBeGreaterThan(0);
  });
});

describe("breakEvenPrice", () => {
  test("break-even is always less than total with margin", () => {
    const params = { ...BASE, laborHours: 3, laborRate: 85, marginPercent: 20 };
    const estimate = calculateEstimate(params);
    const breakEven = breakEvenPrice(params);
    expect(breakEven).toBeLessThan(estimate.total);
  });

  test("break-even with zero overhead is just subtotal", () => {
    const params = {
      ...BASE,
      laborHours: 2,
      laborRate: 50,
      overheadPercent: 0,
      marginPercent: 0,
    };
    const breakEven = breakEvenPrice(params);
    expect(breakEven).toBe(100);
  });
});

describe("getTradeNickname", () => {
  test.each([
    ["plumbing", "Dunny"],
    ["electrical", "Sparky"],
    ["hvac", "Fridgie"],
    ["carpenter", "Chippy"],
    ["bricklayer", "Brickie"],
    ["plasterer", "Sheetie"],
  ])("%s → %s", (trade, expected) => {
    expect(getTradeNickname(trade)).toBe(expected);
  });

  test("unknown trade returns Tradie", () => {
    expect(getTradeNickname("roofing")).toBe("Tradie");
  });

  test("undefined returns Tradie", () => {
    expect(getTradeNickname(undefined)).toBe("Tradie");
  });
});

describe("formatCurrency", () => {
  test("formats whole dollars with $ prefix", () => {
    expect(formatCurrency(500)).toMatch(/^\$500/);
  });

  test("formats zero", () => {
    expect(formatCurrency(0)).toMatch(/^\$0/);
  });

  test("formats cents", () => {
    expect(formatCurrency(9.99)).toContain("9.99");
  });

  test("formats large numbers with commas", () => {
    expect(formatCurrency(1234)).toMatch(/1,234/);
  });
});
