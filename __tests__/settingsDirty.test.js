// Structural equality used for Settings dirty-detection (unsaved-edits guard).

const { settingsEqual } = require("../utils/settingsDirty");

describe("settingsEqual", () => {
  test("primitives compare by value", () => {
    expect(settingsEqual("a", "a")).toBe(true);
    expect(settingsEqual("a", "b")).toBe(false);
    expect(settingsEqual(85, 85)).toBe(true);
    expect(settingsEqual(85, 90)).toBe(false);
    expect(settingsEqual(true, true)).toBe(true);
    expect(settingsEqual(null, null)).toBe(true);
    expect(settingsEqual(null, "")).toBe(false);
  });

  test("equal settings-shaped objects match", () => {
    const a = {
      businessName: "Acme Plumbing",
      laborRate: 85,
      rules: [{ days: 7 }, { days: 14 }],
      providerKeys: { paypal: "johndoe" },
    };
    const b = {
      businessName: "Acme Plumbing",
      laborRate: 85,
      rules: [{ days: 7 }, { days: 14 }],
      providerKeys: { paypal: "johndoe" },
    };
    expect(settingsEqual(a, b)).toBe(true);
  });

  test("a changed nested field is detected", () => {
    const a = { rules: [{ days: 7 }, { days: 14 }] };
    const b = { rules: [{ days: 7 }, { days: 30 }] };
    expect(settingsEqual(a, b)).toBe(false);
  });

  test("array order matters", () => {
    expect(settingsEqual({ rules: [{ days: 7 }, { days: 14 }] }, { rules: [{ days: 14 }, { days: 7 }] })).toBe(false);
  });

  test("array length changes are detected", () => {
    expect(settingsEqual({ rules: [{ days: 7 }] }, { rules: [{ days: 7 }, { days: 14 }] })).toBe(false);
  });

  test("an added or removed key is detected", () => {
    expect(settingsEqual({ providerKeys: { paypal: "a" } }, { providerKeys: { paypal: "a", venmo: "b" } })).toBe(false);
    expect(settingsEqual({ a: 1, b: 2 }, { a: 1 })).toBe(false);
  });

  test("keys explicitly set to undefined count as absent", () => {
    expect(settingsEqual({ region: undefined }, {})).toBe(true);
    expect(settingsEqual({}, { region: undefined })).toBe(true);
    expect(settingsEqual({ region: undefined }, { region: "US" })).toBe(false);
  });

  test("mismatched shapes never match", () => {
    expect(settingsEqual([], {})).toBe(false);
    expect(settingsEqual({ a: 1 }, "a")).toBe(false);
    expect(settingsEqual([1], [1, 2])).toBe(false);
  });
});
