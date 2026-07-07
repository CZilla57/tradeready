// __tests__/numberInput.test.js
// Roadmap #7 (7.6): parseNumberInput + buildEstimateInput. Pins the fix for the
// `parseFloat(x) || default` bug where a legitimately-entered 0 (0% overhead /
// margin / markup, or a $0 "no minimum" fee) was replaced by the default.

import { parseNumberInput } from "../utils/numberInput";
import { buildEstimateInput } from "../utils/pricingEngine";

describe("parseNumberInput", () => {
  test("parses a numeric string", () => {
    expect(parseNumberInput("20", 15)).toBe(20);
    expect(parseNumberInput("3.5", 0)).toBe(3.5);
  });
  test("keeps a legit 0 instead of falling back", () => {
    expect(parseNumberInput("0", 15)).toBe(0);
    expect(parseNumberInput(0, 15)).toBe(0);
  });
  test("falls back only when absent or unparseable", () => {
    expect(parseNumberInput("", 15)).toBe(15);
    expect(parseNumberInput("   ", 15)).toBe(15);
    expect(parseNumberInput("abc", 15)).toBe(15);
    expect(parseNumberInput(null, 15)).toBe(15);
    expect(parseNumberInput(undefined, 15)).toBe(15);
  });
  test("accepts a number value directly", () => {
    expect(parseNumberInput(42, 0)).toBe(42);
  });
  test("parses a leading-numeric string like parseFloat", () => {
    expect(parseNumberInput("12px", 0)).toBe(12);
  });
});

describe("buildEstimateInput", () => {
  const baseForm = {
    laborHours: "2",
    laborRate: "85",
    materials: [],
    materialMarkup: "20",
    overheadPercent: "15",
    marginPercent: "20",
    travelMiles: "0",
    isEmergency: false,
    taxPercent: "0",
  };

  test("a user-entered 0% overhead/margin/markup is respected (the bug)", () => {
    const params = buildEstimateInput(
      { ...baseForm, overheadPercent: "0", marginPercent: "0", materialMarkup: "0" },
      null,
    );
    expect(params.overheadPercent).toBe(0);
    expect(params.marginPercent).toBe(0);
    expect(params.materialMarkup).toBe(0);
  });

  test("blank fields fall back to sensible defaults", () => {
    const params = buildEstimateInput(
      { ...baseForm, overheadPercent: "", marginPercent: "", laborRate: "" },
      null,
    );
    expect(params.overheadPercent).toBe(15);
    expect(params.marginPercent).toBe(20);
    expect(params.laborRate).toBe(85);
  });

  test("pulls travel/emergency/minimum from settings, respecting a 0 minimum", () => {
    const settings = { travelFeePerMile: 2, emergencyMultiplier: 2, minimumJobFee: 0 };
    const params = buildEstimateInput(baseForm, settings);
    expect(params.travelFeePerMile).toBe(2);
    expect(params.emergencyMultiplier).toBe(2);
    expect(params.minimumJobFee).toBe(0); // "no minimum", not the 75 default
  });

  test("null settings uses the built-in defaults", () => {
    const params = buildEstimateInput(baseForm, null);
    expect(params.travelFeePerMile).toBe(0);
    expect(params.emergencyMultiplier).toBe(1.5);
    expect(params.minimumJobFee).toBe(75);
  });

  test("passes materials and isEmergency through unchanged", () => {
    const materials = [{ id: "m1", name: "Pipe", quantity: 2, unitCost: 5 }];
    const params = buildEstimateInput({ ...baseForm, materials, isEmergency: true }, null);
    expect(params.materials).toBe(materials);
    expect(params.isEmergency).toBe(true);
  });
});
