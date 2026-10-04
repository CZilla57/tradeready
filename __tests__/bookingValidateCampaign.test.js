// __tests__/bookingValidateCampaign.test.js
// Phase 33 (past-customer campaigns, spec §9.1): the optional `campaignCode`
// on the Cloudflare Worker's booking validator. It is the booking page's ?c=
// param, an opaque attribution tag the Worker never looks up, so it is
// format-checked and lowercased, never rejected: no campaignCode input may
// fail an otherwise valid booking, and valid, unknown and malformed codes
// look identical to the person booking.
//
// Targets the Worker copy. The dormant Vercel twin (backend/lib/booking/
// validate.js) is intentionally unchanged (Phase 27 precedent) and stays
// covered by bookingValidate.test.js.

const validate = require("../backend-workers/lib/booking/validate");

const { validateBookingPayload, cleanCampaignCode, CAMPAIGN_CODE_RE } = validate;

const good = {
  name: "  Dana Rivers ", phone: "555-0142", email: "dana@example.com",
  address: "12 Elm St", details: "Water heater is leaking", preferredTiming: "Mornings",
};
const BASE_KEYS = ["address", "details", "email", "name", "phone", "preferredTiming"];
const CODE = "0123456789abcdef";
const KELVIN = "K"; // KELVIN SIGN: "K".toLowerCase() is ASCII "k"

const withCode = (campaignCode) => validateBookingPayload({ ...good, campaignCode });

describe("validateBookingPayload campaignCode (Worker copy)", () => {
  it("pins the spec §9.1 pattern", () => {
    expect(CAMPAIGN_CODE_RE.source).toBe("^[0-9a-hjkmnp-tv-z]{16}$");
    expect(CAMPAIGN_CODE_RE.flags).toBe("");
  });

  it("leaves no campaignCode key when the field is absent, and the key set is unchanged", () => {
    const out = validateBookingPayload(good);
    expect(out.ok).toBe(true);
    expect("campaignCode" in out.value).toBe(false);
    expect(Object.keys(out.value).sort()).toEqual(BASE_KEYS);
  });

  it("keeps a valid code", () => {
    const out = withCode(CODE);
    expect(out.ok).toBe(true);
    expect(out.value.campaignCode).toBe(CODE);
    expect(Object.keys(out.value).sort()).toEqual([...BASE_KEYS, "campaignCode"].sort());
  });

  it("keeps every character of the alphabet", () => {
    expect(withCode("ghjkmnpqrstvwxyz").value.campaignCode).toBe("ghjkmnpqrstvwxyz");
    expect(withCode("0123456789abcdef").value.campaignCode).toBe("0123456789abcdef");
  });

  it("lowercases uppercase and mixed case", () => {
    expect(withCode("0123456789ABCDEF").value.campaignCode).toBe(CODE);
    expect(withCode("GhJkMnPqRsTvWxYz").value.campaignCode).toBe("ghjkmnpqrstvwxyz");
  });

  it("trims surrounding whitespace", () => {
    expect(withCode("  0123456789abcdef  ").value.campaignCode).toBe(CODE);
    expect(withCode("\t0123456789abcdef\r\n").value.campaignCode).toBe(CODE);
    expect(withCode(" 0123456789ABCDEF ").value.campaignCode).toBe(CODE);
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
    ["a zero-width space inside", "01234567​89abcdef"],
    ["markup", "<b>0123456789</b>"],
    ["a CRLF header-injection attempt", "0123456789abcdef\r\nBcc: x@y.z"],
    ["Kelvin sign that lowercases to k", `${KELVIN}123456789abcdef`],
    ["full-width digits", "０１２３456789abcdef"],
    ["an accented letter", "0123456789abcdéf"],
    ["empty", ""],
    ["spaces only", "   "],
    ["very long", "0".repeat(5000)],
  ])("drops %s while the booking still validates", (_label, bad) => {
    const out = withCode(bad);
    expect(out.ok).toBe(true);
    expect("campaignCode" in out.value).toBe(false);
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
    expect("campaignCode" in out.value).toBe(false);
  });

  it("never returns an error for any campaignCode input", () => {
    const weird = ["x".repeat(5000), "\u0000".repeat(16), { $gt: "" }, [], NaN, Symbol.iterator, () => 1];
    for (const input of weird) {
      const out = withCode(input);
      expect(out.ok).toBe(true);
      expect("campaignCode" in out.value).toBe(false);
    }
  });

  it("reads only the campaignCode key (no c alias); the page maps ?c= to campaignCode", () => {
    const out = validateBookingPayload({ ...good, c: CODE, campaign: CODE, campaignId: "cmp_1" });
    expect(out.ok).toBe(true);
    expect(Object.keys(out.value).sort()).toEqual(BASE_KEYS);
  });

  it("coexists with leadSource", () => {
    const out = validateBookingPayload({ ...good, leadSource: "nextdoor", campaignCode: "VTPVXVR024H36H2N" });
    expect(out.ok).toBe(true);
    expect(out.value.leadSource).toBe("nextdoor");
    expect(out.value.campaignCode).toBe("vtpvxvr024h36h2n");
    const { leadSource, campaignCode, ...rest } = out.value;
    expect(rest).toEqual(validateBookingPayload(good).value);
  });

  it("a bad code next to a good leadSource drops only the code", () => {
    const out = validateBookingPayload({ ...good, leadSource: "nextdoor", campaignCode: "nope" });
    expect(out.value.leadSource).toBe("nextdoor");
    expect("campaignCode" in out.value).toBe(false);
  });

  // Phase 34 (referrals, feat/referrals) adds cleanReferralCode to this same
  // validator. The two codes are cleaned independently: neither one's
  // presence or validity changes the other, and the owner's app decides
  // "referral beats campaign" for the customer's lead source. Before that
  // merge the validator has no referralCode whitelist entry, so the key is
  // dropped; after it, the referral code is kept beside the campaign code.
  describe("independence from a referral code", () => {
    const hasReferral = typeof validate.cleanReferralCode === "function";
    const REF = "vtpvxvr024h36h2n";

    it.each([
      ["a valid referral code", REF],
      ["an uppercase referral code", REF.toUpperCase()],
      ["a garbage referral code", "not-a-code"],
      ["a non-string referral code", 42],
    ])("%s never changes the campaign code", (_label, referralCode) => {
      const out = validateBookingPayload({ ...good, campaignCode: ` ${CODE.toUpperCase()} `, referralCode });
      expect(out.ok).toBe(true);
      expect(out.value.campaignCode).toBe(CODE);
    });

    it("a garbage campaign code never changes the referral code", () => {
      const both = validateBookingPayload({ ...good, campaignCode: "nope", referralCode: REF });
      const refOnly = validateBookingPayload({ ...good, referralCode: REF });
      expect(both).toEqual(refOnly);
      expect("campaignCode" in both.value).toBe(false);
    });

    it(hasReferral ? "keeps both codes (Phase 34 merged)" : "drops the referral key (Phase 34 not merged yet)", () => {
      const out = validateBookingPayload({ ...good, leadSource: "nextdoor", campaignCode: CODE, referralCode: REF });
      expect(out.value.campaignCode).toBe(CODE);
      expect(out.value.leadSource).toBe("nextdoor");
      if (hasReferral) expect(out.value.referralCode).toBe(REF);
      else expect("referralCode" in out.value).toBe(false);
    });
  });

  it("still enforces every existing rule when a code is present", () => {
    const camp = { campaignCode: CODE };
    expect(validateBookingPayload({ ...good, ...camp, name: "  " }).ok).toBe(false);
    expect(validateBookingPayload({ ...good, ...camp, details: "" }).ok).toBe(false);
    expect(validateBookingPayload({ ...good, ...camp, phone: " ", email: "" }).error).toMatch(/phone or email/i);
    expect(validateBookingPayload({ ...good, ...camp, email: "not-an-email" }).ok).toBe(false);
    expect(validateBookingPayload({ ...good, ...camp, name: "x".repeat(101) }).ok).toBe(false);
  });

  it("does not let a bad code mask or replace an existing-field error", () => {
    const out = validateBookingPayload({ ...good, campaignCode: 42, name: "" });
    expect(out.ok).toBe(false);
    expect(out.error).toMatch(/your name/i);
    expect(validateBookingPayload({ ...good, campaignCode: CODE, name: "" })).toEqual(out);
  });
});

describe("cleanCampaignCode", () => {
  it("returns '' for anything unusable and the canonical code otherwise", () => {
    expect(cleanCampaignCode(undefined)).toBe("");
    expect(cleanCampaignCode(`${KELVIN}123456789abcdef`)).toBe("");
    expect(cleanCampaignCode(" 0123456789ABCDEF ")).toBe(CODE);
  });

  it("accepts exactly the 32-character lowercase alphabet, in either ASCII case", () => {
    const alphabet = "0123456789abcdefghjkmnpqrstvwxyz";
    for (let cp = 0x20; cp <= 0x7e; cp += 1) {
      const ch = String.fromCharCode(cp);
      const accepted = cleanCampaignCode(ch.repeat(16)) !== "";
      expect([ch, accepted]).toEqual([ch, alphabet.includes(ch.toLowerCase())]);
    }
  });

  it("every accepted value matches the stored-format pattern", () => {
    for (const input of [CODE, CODE.toUpperCase(), " ghjkmnpqrstvwxyz\n"]) {
      expect(CAMPAIGN_CODE_RE.test(cleanCampaignCode(input))).toBe(true);
    }
  });
});
