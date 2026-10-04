// __tests__/bookingValidateReferralWorkers.test.js
// Phase 34 (referral program): the optional `referralCode` on the Cloudflare
// Worker's booking validator. It is the booking page's ?r= param, an opaque
// attribution tag the Worker never looks up, so it is format-checked and
// lowercased, never rejected: no referralCode input may fail an otherwise
// valid booking, and valid, unknown and malformed codes look identical to
// the person booking.
//
// Targets the Worker copy. The dormant Vercel twin (backend/lib/booking/
// validate.js) is intentionally unchanged (spec §3, Phase 27 precedent).
// The shared code vectors live in native/ReferralTests/Fixtures/.

const fs = require("fs");
const path = require("path");
const { validateBookingPayload } = require("../backend-workers/lib/booking/validate");

const fixture = JSON.parse(
  fs.readFileSync(path.join(__dirname, "../native/ReferralTests/Fixtures/referral-code-vectors.json"), "utf8")
);

const good = {
  name: "  Dana Rivers ", phone: "555-0142", email: "dana@example.com",
  address: "12 Elm St", details: "Water heater is leaking", preferredTiming: "Mornings",
};
const BASE_KEYS = ["address", "details", "email", "name", "phone", "preferredTiming"];
const CODE = "0123456789abcdef";

const withCode = (referralCode) => validateBookingPayload({ ...good, referralCode });

describe("validateBookingPayload referralCode (Worker copy)", () => {
  it("leaves no referralCode key when the field is absent, and the key set is unchanged", () => {
    const out = validateBookingPayload(good);
    expect(out.ok).toBe(true);
    expect("referralCode" in out.value).toBe(false);
    expect(Object.keys(out.value).sort()).toEqual(BASE_KEYS);
  });

  it("keeps a valid code", () => {
    const out = withCode(CODE);
    expect(out.ok).toBe(true);
    expect(out.value.referralCode).toBe(CODE);
    expect(Object.keys(out.value).sort()).toEqual([...BASE_KEYS, "referralCode"].sort());
  });

  it("lowercases uppercase and mixed case", () => {
    expect(withCode("0123456789ABCDEF").value.referralCode).toBe(CODE);
    expect(withCode("GhJkMnPqRsTvWxYz").value.referralCode).toBe("ghjkmnpqrstvwxyz");
  });

  it("trims surrounding whitespace", () => {
    expect(withCode("  0123456789abcdef  ").value.referralCode).toBe(CODE);
    expect(withCode("\t0123456789abcdef\r\n").value.referralCode).toBe(CODE);
  });

  it.each([
    ["15 characters", "0123456789abcde"],
    ["17 characters", "0123456789abcdef0"],
    ["contains i", "0123456789abcdei"],
    ["contains l", "0123456789abcdel"],
    ["contains o", "0123456789abcdeo"],
    ["contains u", "0123456789abcdeu"],
    ["contains uppercase I/L/O/U", "ILOU456789abcdef"],
    ["punctuation", "0123456789abcde!"],
    ["hyphen groups", "0123-4567-89ab-cdef"],
    ["internal space", "0123456 89abcdef"],
    ["markup", "<b>0123456789</b>"],
    ["Kelvin sign that lowercases to k", "K123456789abcdef"],
    ["empty", ""],
    ["spaces only", "   "],
    ["very long", "0".repeat(5000)],
  ])("drops %s while the booking still validates", (_label, bad) => {
    const out = withCode(bad);
    expect(out.ok).toBe(true);
    expect("referralCode" in out.value).toBe(false);
    expect(Object.keys(out.value).sort()).toEqual(BASE_KEYS);
  });

  it.each([
    ["number", 1234567890123456],
    ["zero", 0],
    ["object", { code: CODE }],
    ["array", [CODE]],
    ["true", true],
    ["false", false],
    ["null", null],
    ["undefined", undefined],
  ])("drops a non-string (%s) silently and the booking still validates", (_label, bad) => {
    const out = withCode(bad);
    expect(out.ok).toBe(true);
    expect("referralCode" in out.value).toBe(false);
  });

  it("coexists with leadSource", () => {
    const out = validateBookingPayload({ ...good, leadSource: "nextdoor", referralCode: "VTPVXVR024H36H2N" });
    expect(out.ok).toBe(true);
    expect(out.value.leadSource).toBe("nextdoor");
    expect(out.value.referralCode).toBe("vtpvxvr024h36h2n");
    const { leadSource, referralCode, ...rest } = out.value;
    expect(rest).toEqual(validateBookingPayload(good).value);
  });

  it("a bad code next to a good leadSource drops only the code", () => {
    const out = validateBookingPayload({ ...good, leadSource: "nextdoor", referralCode: "nope" });
    expect(out.value.leadSource).toBe("nextdoor");
    expect("referralCode" in out.value).toBe(false);
  });

  it("still enforces every existing rule when a code is present", () => {
    const ref = { referralCode: CODE };
    expect(validateBookingPayload({ ...good, ...ref, name: "  " }).ok).toBe(false);
    expect(validateBookingPayload({ ...good, ...ref, details: "" }).ok).toBe(false);
    expect(validateBookingPayload({ ...good, ...ref, phone: " ", email: "" }).error).toMatch(/phone or email/i);
    expect(validateBookingPayload({ ...good, ...ref, email: "not-an-email" }).ok).toBe(false);
    expect(validateBookingPayload({ ...good, ...ref, name: "x".repeat(101) }).ok).toBe(false);
  });

  it("does not let a bad code mask or replace an existing-field error", () => {
    const out = validateBookingPayload({ ...good, referralCode: 42, name: "" });
    expect(out.ok).toBe(false);
    expect(out.error).toMatch(/your name/i);
  });

  it("never returns an error for any referralCode input", () => {
    const weird = ["x".repeat(5000), "\u0000".repeat(16), { $gt: "" }, [], NaN, Symbol.iterator, () => 1];
    for (const input of weird) {
      const out = withCode(input);
      expect(out.ok).toBe(true);
      expect("referralCode" in out.value).toBe(false);
    }
  });

  describe("shared fixture vectors", () => {
    it.each(fixture.normalize.map((v) => [v.name, v]))("%s", (_name, vector) => {
      const out = withCode(vector.input);
      expect(out.ok).toBe(true);
      if (vector.expect === null) expect("referralCode" in out.value).toBe(false);
      else expect(out.value.referralCode).toBe(vector.expect);
    });

    it("every code the device can encode passes unchanged", () => {
      for (const vector of fixture.encode.filter((v) => v.expect !== null)) {
        expect(withCode(vector.expect).value.referralCode).toBe(vector.expect);
      }
    });
  });
});
