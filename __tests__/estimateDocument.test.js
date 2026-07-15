// The estimate document is built deterministically — every number computed by
// the pricing engine and formatted in code. AI contributes only the scope
// paragraph (beta finding: letting the model reconstruct the document produced
// wrong math and cheap formatting on the keyless path).

const {
  buildEstimateDocument,
  sanitizeScope,
  cannedScope,
} = require("../utils/estimateDocument");

const BASE = {
  businessName: "Rector Plumbing",
  contactName: "Chad",
  phone: "(518) 366-8268",
  email: "chad@example.com",
  customerName: "Riverside Bakery",
  customerAddress: "12 Mill St, Phoenix, AZ",
  jobTitle: "Water heater replacement",
  laborHours: 4,
  laborRate: 100,
  materialsCount: 2,
  breakdown: {
    laborCost: 400,
    materialBaseCost: 500,
    materialMarkupAmount: 100,
    materialCost: 600,
    travelCost: 0,
    subtotal: 1000,
    overheadCost: 150,
    profit: 250,
    preTaxTotal: 1400,
    totalBeforeTax: 1400,
    taxAmount: 0,
    total: 1400,
    effectiveHourlyRate: 350,
    hitMinimum: false,
  },
  scope: "Remove and dispose of the existing unit and install the new one.",
  now: new Date(2026, 6, 14),
};

describe("buildEstimateDocument", () => {
  test("assembles the full document with engine-exact numbers", () => {
    const doc = buildEstimateDocument(BASE);
    expect(doc).toContain("ESTIMATE — Water heater replacement");
    expect(doc).toContain("Rector Plumbing");
    expect(doc).toContain("July 14, 2026");
    expect(doc).toContain("Riverside Bakery");
    expect(doc).toContain("12 Mill St, Phoenix, AZ");
    expect(doc).toContain("Remove and dispose of the existing unit");
    expect(doc).toContain("Labor (4 hrs @ $100/hr)");
    expect(doc).toContain("$400");            // labor, from the engine
    expect(doc).toContain("Materials (2 items, incl. markup)");
    expect(doc).toContain("$600");            // materials with markup
    expect(doc).toContain("Overhead & operating costs");
    expect(doc).toContain("$400\n");          // overhead 150 + profit 250
    expect(doc).toContain("TOTAL: $1,400");
    expect(doc).toContain("valid for 30 days");
  });

  test("omits zero lines and never leaks the internal price range", () => {
    const doc = buildEstimateDocument(BASE);
    expect(doc).not.toContain("Travel");      // travelCost 0
    expect(doc).not.toContain("Tax");         // taxAmount 0
    expect(doc).not.toMatch(/range/i);        // internal pricing aid stays internal
  });

  test("shows travel, tax, and the minimum-fee note when applicable", () => {
    const doc = buildEstimateDocument({
      ...BASE,
      breakdown: {
        ...BASE.breakdown,
        travelCost: 50,
        taxAmount: 87.5,
        total: 1537.5,
        hitMinimum: true,
      },
    });
    expect(doc).toContain("Travel: $50");
    expect(doc).toContain("Tax: $87.50");
    expect(doc).toContain("TOTAL: $1,537.50");
    expect(doc).toContain("minimum job fee");
  });

  test("omits the address line when the customer has none", () => {
    const doc = buildEstimateDocument({ ...BASE, customerAddress: "" });
    expect(doc).toContain("Riverside Bakery");
    expect(doc).not.toContain("12 Mill St");
  });
});

describe("sanitizeScope", () => {
  const canned = "Includes all labor and materials listed below.";

  test("passes through clean prose, trimmed", () => {
    expect(sanitizeScope("  Solid workmanship throughout.  ", canned)).toBe(
      "Solid workmanship throughout."
    );
  });

  test("rejects empty or blank output", () => {
    expect(sanitizeScope("", canned)).toBe(canned);
    expect(sanitizeScope("   ", canned)).toBe(canned);
  });

  test("rejects scope that smuggles in prices", () => {
    expect(sanitizeScope("We will do it for $1,200 total.", canned)).toBe(canned);
    expect(sanitizeScope("Costs $ 500", canned)).toBe(canned);
  });

  test("rejects rambling output", () => {
    expect(sanitizeScope("x".repeat(700), canned)).toBe(canned);
  });
});

describe("cannedScope", () => {
  test("uses the job description when present", () => {
    const s = cannedScope({ jobTitle: "Faucet swap", description: "Replace kitchen faucet with customer-supplied Moen unit." });
    expect(s).toContain("Replace kitchen faucet");
    expect(s).toContain("professional standard");
  });

  test("falls back to the title alone", () => {
    const s = cannedScope({ jobTitle: "Faucet swap", description: "" });
    expect(s).toContain("Faucet swap");
    expect(s).toContain("professional standard");
  });
});
