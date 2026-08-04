// __tests__/settingsValidation.test.js
// The Settings save path must hard-block malformed values (the old behavior
// warned but saved anyway, letting bad emails/phones/rates reach invoices).

import { validateSettingsInput } from "../utils/settingsValidation";

const valid = { email: "jo@example.com", phone: "(555) 123-4567", laborRate: 85 };

describe("validateSettingsInput", () => {
  test("clean input passes", () => {
    expect(validateSettingsInput(valid)).toEqual([]);
  });

  test("empty email and phone are allowed (optional fields)", () => {
    expect(validateSettingsInput({ ...valid, email: "", phone: "  " })).toEqual([]);
  });

  test("malformed email is rejected", () => {
    expect(validateSettingsInput({ ...valid, email: "not-an-email" })).toHaveLength(1);
    expect(validateSettingsInput({ ...valid, email: "a@b" })).toHaveLength(1);
  });

  test("partial phone number is rejected", () => {
    expect(validateSettingsInput({ ...valid, phone: "(555) 123" })).toHaveLength(1);
  });

  test("formatted 10-digit phone passes", () => {
    expect(validateSettingsInput({ ...valid, phone: "(555) 123-4567" })).toEqual([]);
  });

  test("zero, negative and NaN labor rates are rejected", () => {
    expect(validateSettingsInput({ ...valid, laborRate: 0 })).toHaveLength(1);
    expect(validateSettingsInput({ ...valid, laborRate: -5 })).toHaveLength(1);
    expect(validateSettingsInput({ ...valid, laborRate: NaN })).toHaveLength(1);
  });

  test("multiple problems are all reported", () => {
    const errors = validateSettingsInput({ email: "bad", phone: "12", laborRate: 0 });
    expect(errors).toHaveLength(3);
  });
});
