// __tests__/phase10QualificationOracle.test.js
//
// Task 10.14 (Phase 10 cross-client and hosted-contract qualification, fix
// round 1, item 4): a small, permanent, re-runnable RN oracle for the two
// hardcoded probe values `native/Phase10QualificationTests/main.swift` pins
// in `testWeekMonthLabelFA039()` and `testRoundingDivergence()`. Those
// values were originally captured from a scratch probe script that was
// deleted after use; this file replaces that scratch probe so the values
// can be reproduced and re-verified by anyone, at any time, without
// recreating it.
//
// Run with: TZ=America/Phoenix npm test -- --runInBand --runTestsByPath
// __tests__/phase10QualificationOracle.test.js
//
// TZ=America/Phoenix matters for the weekMonthLabel case: it is a
// west-of-UTC zone, which is what exposes the FA-039 UTC-parse defect
// (`new Date("YYYY-MM-DD")` parses as UTC midnight, then local getters read
// the day before). Running this file under UTC or an east-of-UTC zone would
// not reproduce the divergence and is not a valid substitute.

import { getWeekDates, weekMonthLabel } from "../utils/dateHelpers";

describe("Phase 10.14 RN oracle: weekMonthLabel FA-039 fixture", () => {
  test("the all-June week 2026-06-01..2026-06-07 straddles May/Jun under weekMonthLabel's UTC-parse (TZ=America/Phoenix)", () => {
    expect(process.env.TZ).toBe("America/Phoenix");

    const weekDates = getWeekDates("2026-06-01");
    // getWeekDates itself is local-frame (`new Date(y, m-1, d)`), so the
    // week it returns is the correct all-June Mon..Sun window.
    expect(weekDates).toEqual([
      "2026-06-01",
      "2026-06-02",
      "2026-06-03",
      "2026-06-04",
      "2026-06-05",
      "2026-06-06",
      "2026-06-07",
    ]);

    // weekMonthLabel re-parses the boundary strings with `new Date(str)`
    // (UTC-parse) — under a west-of-UTC zone this reads the anchor day as
    // the local day before, so the label straddles May/Jun even though the
    // week is entirely in June. This is the exact value pinned as
    // `rnOracleLabelForThisFixture` in
    // native/Phase10QualificationTests/main.swift's
    // testWeekMonthLabelFA039(), which native intentionally does not
    // reproduce (native's `NativeTodayBriefing.weekStrip` uses local-frame
    // string/component math and correctly returns "Jun 2026").
    expect(weekMonthLabel(weekDates)).toBe("May – Jun 2026");
  });
});

describe("Phase 10.14 RN oracle: Math.round half/negative cases", () => {
  // Math.round is round-half-towards-positive-infinity. These are the exact
  // values pinned in native/Phase10QualificationTests/main.swift's
  // testRoundingDivergence(), which documents that Swift's default
  // `.rounded()` (round-half-away-from-zero) agrees for positive halves and
  // diverges for negative halves.
  test.each([
    [0.5, 1],
    [1.5, 2],
    [2.5, 3],
    [-0.5, -0],
    [-1.5, -1],
    [-2.5, -2],
  ])("Math.round(%s) === %s", (value, expected) => {
    expect(Math.round(value)).toBe(expected);
  });
});
