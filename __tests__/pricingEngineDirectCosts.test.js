// Phase 2 — explicit direct-cost lines (permits, disposal, rental, subcontractor…).
// Covers the two markup policies, break-even/minimum/tax interactions, the
// per-line rendering amounts, backward compatibility, and the saved-job residual.

import {
  calculateEstimate,
  breakEvenPrice,
  computeEstimateBreakdown,
  defaultMarkupPolicyForCategory,
} from "../utils/pricingEngine";

const BASE = {
  laborHours: 0,
  laborRate: 85,
  materials: [],
  materialMarkup: 20,
  jobCosts: [],
  overheadPercent: 15,
  marginPercent: 20,
  travelMiles: 0,
  travelFeePerMile: 0,
  isEmergency: false,
  emergencyMultiplier: 1.5,
  minimumJobFee: 0,
  taxPercent: 0,
};

const permit = (over = {}) => ({
  label: "City permit",
  category: "permit",
  quantity: 1,
  unitCost: 150,
  markupPercent: 0,
  markupPolicy: "passthrough",
  taxable: false,
  customerVisible: true,
  ...over,
});

const sub = (over = {}) => ({
  label: "Licensed subcontractor",
  category: "subcontractor",
  quantity: 1,
  unitCost: 500,
  markupPercent: 0,
  markupPolicy: "in_margin_base",
  taxable: false,
  customerVisible: true,
  ...over,
});

describe("calculateEstimate — passthrough direct costs", () => {
  test("passthrough is added at cost, earning NO overhead or margin", () => {
    const r = calculateEstimate({
      ...BASE,
      laborHours: 2,
      laborRate: 100, // labor 200
      overheadPercent: 0,
      marginPercent: 20,
      jobCosts: [permit({ unitCost: 150 })],
    });
    // margined = 200 ÷ 0.8 = 250; permit adds 150 at cost → 400.
    // (A naive (200+150)/0.8 = 437.50 would be wrong.)
    expect(r.directCostPassthrough).toBe(150);
    expect(r.directCostMarginBase).toBe(0);
    expect(r.totalBeforeTax).toBe(400);
    expect(r.profit).toBe(50); // 250 − 200, permit earns nothing
  });

  test("break-even includes the pass-through cost", () => {
    const be = breakEvenPrice({
      ...BASE,
      laborHours: 2,
      laborRate: 100,
      overheadPercent: 0,
      jobCosts: [permit({ unitCost: 150 })],
    });
    // zero-margin cost = 200 labor + 150 permit
    expect(be).toBe(350);
  });
});

describe("calculateEstimate — in-margin-base direct costs", () => {
  test("enters the subtotal and earns overhead + margin, with handling markup", () => {
    const r = calculateEstimate({
      ...BASE,
      laborHours: 0,
      overheadPercent: 10,
      marginPercent: 20,
      jobCosts: [sub({ unitCost: 500, markupPercent: 10 })],
    });
    // marginBase = 500 × 1.10 = 550; subtotal 550; overhead 55; cost 605;
    // margined = 605 ÷ 0.8 = 756.25
    expect(r.directCostMarginBase).toBe(550);
    expect(r.directCostPassthrough).toBe(0);
    expect(r.subtotal).toBe(550);
    expect(r.overheadCost).toBe(55);
    expect(r.totalBeforeTax).toBe(756.25);
  });
});

describe("calculateEstimate — minimum fee with pass-through (decision 1)", () => {
  test("minimum applies to the margined portion, then pass-through adds on top", () => {
    const r = calculateEstimate({
      ...BASE,
      laborHours: 0.05,
      laborRate: 100, // margined labor = $5
      overheadPercent: 0,
      marginPercent: 0,
      minimumJobFee: 75,
      jobCosts: [permit({ unitCost: 150 })],
    });
    // max(5, 75) + 150 = 225  (NOT max(5+150, 75) = 155)
    expect(r.hitMinimum).toBe(true);
    expect(r.totalBeforeTax).toBe(225);
  });
});

describe("calculateEstimate — tax base excludes non-taxable pass-through (decision 3)", () => {
  test("a non-taxable permit is excluded from the taxed base", () => {
    const r = calculateEstimate({
      ...BASE,
      laborHours: 1,
      laborRate: 100, // margined 100
      overheadPercent: 0,
      marginPercent: 0,
      taxPercent: 10,
      jobCosts: [permit({ unitCost: 200, taxable: false })],
    });
    // totalBeforeTax = 300; taxed base = 300 − 200 = 100; tax = 10
    expect(r.totalBeforeTax).toBe(300);
    expect(r.taxAmount).toBe(10);
    expect(r.total).toBe(310);
  });

  test("a taxable pass-through stays in the taxed base", () => {
    const r = calculateEstimate({
      ...BASE,
      laborHours: 1,
      laborRate: 100,
      overheadPercent: 0,
      marginPercent: 0,
      taxPercent: 10,
      jobCosts: [permit({ unitCost: 200, taxable: true })],
    });
    expect(r.taxAmount).toBe(30);
    expect(r.total).toBe(330);
  });
});

describe("calculateEstimate — per-line rendering amounts", () => {
  test("directCostLines carry the customer-facing amount and visibility", () => {
    const r = calculateEstimate({
      ...BASE,
      laborHours: 1,
      laborRate: 100,
      overheadPercent: 0,
      marginPercent: 0,
      jobCosts: [
        permit({ unitCost: 150, customerVisible: true }),
        sub({ unitCost: 500, markupPercent: 0, customerVisible: false }),
      ],
    });
    expect(r.directCostLines).toHaveLength(2);
    const [p, s] = r.directCostLines;
    expect(p).toMatchObject({ category: "permit", amount: 150, customerVisible: true, markupPolicy: "passthrough" });
    expect(s).toMatchObject({ category: "subcontractor", amount: 500, customerVisible: false, markupPolicy: "in_margin_base" });
  });

  test("effective hourly rate excludes direct costs (they aren't labor earnings)", () => {
    const r = calculateEstimate({
      ...BASE,
      laborHours: 2,
      laborRate: 100, // labor 200
      overheadPercent: 0,
      marginPercent: 0,
      jobCosts: [permit({ unitCost: 100 })],
    });
    // total 300; (300 − 0 materials − 0 travel − 100 direct) / 2 = 100
    expect(r.effectiveHourlyRate).toBe(100);
  });
});

describe("calculateEstimate — backward compatibility", () => {
  test("no jobCosts reproduces the pre-Phase-2 result exactly", () => {
    const params = { ...BASE, laborHours: 2, laborRate: 100 };
    const withEmpty = calculateEstimate(params);
    const withUndefined = calculateEstimate({ ...params, jobCosts: undefined });
    expect(withEmpty.total).toBe(withUndefined.total);
    expect(withEmpty.directCostLines).toEqual([]);
    expect(withEmpty.directCostMarginBase).toBe(0);
    expect(withEmpty.directCostPassthrough).toBe(0);
    // 200 labor + 30 overhead = 230 cost; ÷0.8 = 287.50 (matches legacy test)
    expect(withEmpty.total).toBe(287.5);
  });

  test("string quantity/unitCost/markup parse defensively like materials", () => {
    const r = calculateEstimate({
      ...BASE,
      overheadPercent: 0,
      marginPercent: 0,
      jobCosts: [sub({ quantity: "2", unitCost: "50", markupPercent: "10" })],
    });
    // 2 × 50 × 1.10 = 110
    expect(r.directCostMarginBase).toBe(110);
  });
});

describe("defaultMarkupPolicyForCategory", () => {
  test("permit passes through at cost by default", () => {
    expect(defaultMarkupPolicyForCategory("permit")).toBe("passthrough");
  });
  test.each(["disposal", "rental", "subcontractor", "delivery", "travel", "other"])(
    "%s defaults into the margin base",
    (cat) => {
      expect(defaultMarkupPolicyForCategory(cat)).toBe("in_margin_base");
    }
  );
});

describe("computeEstimateBreakdown — saved-job residual with direct costs", () => {
  const job = {
    laborHours: 2,
    laborRate: 85, // labor 170
    materials: [],
    materialMarkup: 0,
    estimateTotal: 600,
    jobCosts: [
      { id: "jc1", label: "Permit", category: "permit", quantity: 1, unitCost: 100, markupPercent: 0, markupPolicy: "passthrough", taxable: false, customerVisible: true },
      { id: "jc2", label: "Sub", category: "subcontractor", quantity: 1, unitCost: 200, markupPercent: 0, markupPolicy: "in_margin_base", taxable: false, customerVisible: false },
    ],
  };

  test("visible direct costs are their own lines; overhead is the residual after them", () => {
    const b = computeEstimateBreakdown(job);
    expect(b.laborCost).toBe(170);
    expect(b.directCostLines).toHaveLength(2);
    // overhead = 600 − 170 labor − 0 materials − 100 visible permit = 330
    expect(b.overheadLine).toBe(330);
  });

  test("labor + materials + visible direct lines + overhead ≡ estimateTotal", () => {
    const b = computeEstimateBreakdown(job);
    const visible = b.directCostLines.filter((l) => l.customerVisible).reduce((s, l) => s + l.amount, 0);
    expect(b.laborCost + b.materialCost + visible + b.overheadLine).toBeCloseTo(b.estimateTotal, 5);
  });

  test("a job with no jobCosts is unchanged (empty lines, legacy residual)", () => {
    const legacy = { laborHours: 2, laborRate: 85, materials: [], materialMarkup: 0, estimateTotal: 340 };
    const b = computeEstimateBreakdown(legacy);
    expect(b.directCostLines).toEqual([]);
    expect(b.overheadLine).toBe(170); // 340 − 170 − 0
  });
});
