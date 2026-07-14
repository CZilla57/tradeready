// Animation-duration policy under the OS "reduce motion" accessibility setting.

const { animationDuration } = require("../utils/motion");

describe("animationDuration", () => {
  test("returns the normal duration when motion is allowed", () => {
    expect(animationDuration(false, 300)).toBe(300);
  });

  test("returns zero when the user prefers reduced motion", () => {
    expect(animationDuration(true, 300)).toBe(0);
  });

  test("respects a custom normal duration", () => {
    expect(animationDuration(false, 150)).toBe(150);
    expect(animationDuration(true, 150)).toBe(0);
  });
});
