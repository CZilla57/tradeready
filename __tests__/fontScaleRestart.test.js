// When iOS changes the text-size (fontScale) under a running app, RN repaints
// at the new scale without re-measuring layout — chopped headers, unscaled
// siblings (beta finding; restart renders fine). We detect the change and
// offer a restart. This tests the decision logic.

const { fontScaleChanged } = require("../utils/fontScaleRestart");

describe("fontScaleChanged", () => {
  test("false while the scale matches the launch value", () => {
    expect(fontScaleChanged(1.0, 1.0)).toBe(false);
    expect(fontScaleChanged(3.1, 3.1)).toBe(false);
  });

  test("true when the scale genuinely moves", () => {
    expect(fontScaleChanged(1.0, 3.1)).toBe(true);
    expect(fontScaleChanged(3.1, 1.0)).toBe(true);
    expect(fontScaleChanged(1.0, 1.2)).toBe(true);
  });

  test("tolerates float noise", () => {
    expect(fontScaleChanged(1.0, 1.0000001)).toBe(false);
  });

  test("ignores missing values", () => {
    expect(fontScaleChanged(undefined, 1.2)).toBe(false);
    expect(fontScaleChanged(1.0, undefined)).toBe(false);
  });
});
