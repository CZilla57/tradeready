// Plan detection for the RevenueCat subscription webhook. The store products
// were created as "Monthly" / "Annual" (capitalized, immutable in App Store
// Connect), so matching must be case-insensitive.

const { resolvePlan } = require("../backend/lib/plan");

describe("resolvePlan", () => {
  test("maps the actual configured App Store product ids", () => {
    expect(resolvePlan("Annual")).toBe("annual");
    expect(resolvePlan("Monthly")).toBe("monthly");
  });

  test("matches the plan word anywhere in the id, any case", () => {
    expect(resolvePlan("tradeready_annual_2026")).toBe("annual");
    expect(resolvePlan("com.gettradereadyapp.MONTHLY")).toBe("monthly");
  });

  test("returns null for unknown or missing product ids", () => {
    expect(resolvePlan("lifetime")).toBeNull();
    expect(resolvePlan("")).toBeNull();
    expect(resolvePlan(null)).toBeNull();
    expect(resolvePlan(undefined)).toBeNull();
  });

  test("prefers annual when an id somehow contains both words", () => {
    expect(resolvePlan("annual_billed_monthly")).toBe("annual");
  });
});
