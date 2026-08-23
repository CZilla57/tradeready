// Phase 3 — labor-time breakdown + travel double-counting warnings.

import { sumLaborBreakdown, getTimeAndTripWarnings } from "../utils/pricingEngine";

describe("sumLaborBreakdown", () => {
  test("sums the four billable buckets, ignoring the non-billable note", () => {
    const hours = sumLaborBreakdown({
      onSiteHours: 2,
      driveHours: 0.5,
      supplyRunHours: 0.25,
      setupCleanupHours: 0.5,
      nonBillableNote: "48h cure before grout",
    });
    expect(hours).toBe(3.25);
  });

  test("missing/blank buckets degrade to 0, not NaN", () => {
    // @ts-expect-error intentionally partial to prove defensive parsing
    expect(sumLaborBreakdown({ onSiteHours: 1 })).toBe(1);
    expect(sumLaborBreakdown({ onSiteHours: 0, driveHours: 0, supplyRunHours: 0, setupCleanupHours: 0 })).toBe(0);
  });
});

describe("getTimeAndTripWarnings", () => {
  test("no conflict → no warnings", () => {
    expect(getTimeAndTripWarnings({ driveHours: 0, travelMiles: 0, jobCosts: [] })).toEqual([]);
    expect(getTimeAndTripWarnings({ driveHours: 2, travelMiles: 0, jobCosts: [] })).toEqual([]);
  });

  test("drive time billed as labor AND a per-mile fee warns once", () => {
    const w = getTimeAndTripWarnings({ driveHours: 1, travelMiles: 20, jobCosts: [] });
    expect(w).toHaveLength(1);
    expect(w[0]).toMatch(/drive time/i);
    expect(w[0]).toMatch(/mile/i);
  });

  test("drive time billed as labor AND a travel/delivery cost line warns", () => {
    const w = getTimeAndTripWarnings({
      driveHours: 1,
      travelMiles: 0,
      jobCosts: [{ category: "travel" }],
    });
    expect(w).toHaveLength(1);
    expect(w[0]).toMatch(/travel/i);
  });

  test("per-mile fee AND a travel cost line (no drive hours) still warns", () => {
    const w = getTimeAndTripWarnings({
      driveHours: 0,
      travelMiles: 15,
      jobCosts: [{ category: "delivery" }],
    });
    expect(w).toHaveLength(1);
  });

  test("a non-travel cost line does not trigger a travel warning", () => {
    expect(
      getTimeAndTripWarnings({ driveHours: 1, travelMiles: 0, jobCosts: [{ category: "permit" }] }),
    ).toEqual([]);
  });
});
