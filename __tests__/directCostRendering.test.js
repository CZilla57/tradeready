// Phase 2 — direct costs on the customer-facing render surfaces.
// Locks the invariant that visible direct costs print as their own line and the
// printed parts still sum to the trusted total, while hidden costs are absorbed.

import { calculateEstimate } from "../utils/pricingEngine";
import { buildEstimateDocument } from "../utils/estimateDocument";
import { buildEstimateSnapshot } from "../utils/estimateSnapshot";
import { buildInvoiceLineItems } from "../utils/autoInvoice";
import { estimateHtml } from "../utils/pdfTemplates";

const permitVisible = {
  id: "jc1",
  label: "City permit",
  category: "permit",
  quantity: 1,
  unitCost: 150,
  markupPercent: 0,
  markupPolicy: "passthrough",
  taxable: false,
  customerVisible: true,
};

const subHidden = {
  id: "jc2",
  label: "Subcontractor",
  category: "subcontractor",
  quantity: 1,
  unitCost: 200,
  markupPercent: 0,
  markupPolicy: "in_margin_base",
  taxable: false,
  customerVisible: false,
};

// A saved job whose estimateTotal matches the engine so the residual is exact.
function savedJob() {
  const est = calculateEstimate({
    laborHours: 2,
    laborRate: 100,
    materials: [],
    materialMarkup: 0,
    jobCosts: [permitVisible, subHidden],
    overheadPercent: 0,
    marginPercent: 0,
    travelMiles: 0,
    travelFeePerMile: 0,
    minimumJobFee: 0,
    taxPercent: 0,
  });
  // labor 200 + sub 200 (margin base) + permit 150 passthrough = 550
  return {
    id: "j1",
    title: "Panel swap",
    customerName: "Pat",
    laborHours: 2,
    laborRate: 100,
    materials: [],
    materialMarkup: 0,
    jobCosts: [permitVisible, subHidden],
    estimateTotal: est.total,
  };
}

describe("estimate document — direct costs", () => {
  test("visible permit prints as its own line; hidden sub folds into operating; sums to total", () => {
    const breakdown = calculateEstimate({
      laborHours: 2,
      laborRate: 100,
      materials: [],
      materialMarkup: 0,
      jobCosts: [permitVisible, subHidden],
      overheadPercent: 0,
      marginPercent: 0,
      travelMiles: 0,
      travelFeePerMile: 0,
      minimumJobFee: 0,
      taxPercent: 0,
    });
    const doc = buildEstimateDocument({
      businessName: "Acme",
      contactName: "Sam",
      customerName: "Pat",
      jobTitle: "Panel swap",
      laborHours: 2,
      laborRate: 100,
      materialsCount: 0,
      breakdown,
      scope: "Work.",
    });
    expect(doc).toContain("City permit: $150");
    expect(doc).not.toContain("Subcontractor"); // hidden
    // Operating line absorbs the hidden $200 (overhead 0 + profit 0 + 200)
    expect(doc).toContain("Overhead & operating costs: $200");
    expect(doc).toContain("TOTAL: $550");
  });
});

describe("estimate snapshot — direct costs", () => {
  test("visible line appears and the line items sum to the frozen total", () => {
    const snap = buildEstimateSnapshot(savedJob(), { name: "Pat" }, { businessName: "Acme" });
    const labels = snap.lineItems.map((l) => l.label);
    expect(labels).toContain("City permit");
    expect(labels).not.toContain("Subcontractor");
    const sum = snap.lineItems.reduce((s, l) => s + l.amount, 0);
    expect(sum).toBeCloseTo(snap.total, 5);
    expect(snap.total).toBe(550);
  });
});

describe("estimate PDF — direct costs", () => {
  test("visible permit row is rendered", () => {
    const html = estimateHtml(savedJob(), { name: "Pat" }, { businessName: "Acme" });
    expect(html).toContain("City permit");
    expect(html).not.toContain("Subcontractor");
  });
});

describe("invoice line items — direct costs", () => {
  test("visible cost becomes a categorized line; hidden cost is absorbed into overhead", () => {
    const items = buildInvoiceLineItems(savedJob());
    const permit = items.find((i) => i.description === "City permit");
    expect(permit).toMatchObject({ amount: 150, category: "permit" });
    expect(items.find((i) => i.description === "Subcontractor")).toBeUndefined();
    // Lines sum to the estimate total (residual overhead carries the hidden 200)
    const sum = items.reduce((s, i) => s + i.amount, 0);
    expect(sum).toBeCloseTo(550, 5);
  });
});
