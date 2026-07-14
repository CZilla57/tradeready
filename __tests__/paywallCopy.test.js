const { trialCopy, NO_TRIAL_COPY } = require("../utils/paywallCopy");

const pkgWithIntro = (intro) => ({ product: { introPrice: intro } });

describe("trialCopy", () => {
  it("builds copy for a 14-day free trial", () => {
    const copy = trialCopy(
      pkgWithIntro({ price: 0, periodUnit: "DAY", periodNumberOfUnits: 14 })
    );
    expect(copy).toEqual({
      badge: "14-day free trial — no charge until it ends",
      cta: "Start Free Trial",
      sub: "No charge for 14 days. Cancel anytime.",
    });
  });

  it("uses singular wording for a 1-week trial", () => {
    const copy = trialCopy(
      pkgWithIntro({ price: 0, periodUnit: "WEEK", periodNumberOfUnits: 1 })
    );
    expect(copy.badge).toBe("1-week free trial — no charge until it ends");
    expect(copy.sub).toBe("No charge for 1 week. Cancel anytime.");
  });

  it("pluralizes multi-unit periods", () => {
    const copy = trialCopy(
      pkgWithIntro({ price: 0, periodUnit: "MONTH", periodNumberOfUnits: 2 })
    );
    expect(copy.badge).toBe("2-month free trial — no charge until it ends");
    expect(copy.sub).toBe("No charge for 2 months. Cancel anytime.");
  });

  it("returns null for a PAID intro offer (not a free trial)", () => {
    expect(
      trialCopy(pkgWithIntro({ price: 4.99, periodUnit: "MONTH", periodNumberOfUnits: 1 }))
    ).toBeNull();
  });

  it("returns null when the product has no intro offer", () => {
    expect(trialCopy({ product: { introPrice: null } })).toBeNull();
    expect(trialCopy({ product: {} })).toBeNull();
    expect(trialCopy({})).toBeNull();
    expect(trialCopy(null)).toBeNull();
    expect(trialCopy(undefined)).toBeNull();
  });

  it("returns null for an unknown period unit or zero units", () => {
    expect(
      trialCopy(pkgWithIntro({ price: 0, periodUnit: "FORTNIGHT", periodNumberOfUnits: 1 }))
    ).toBeNull();
    expect(
      trialCopy(pkgWithIntro({ price: 0, periodUnit: "DAY", periodNumberOfUnits: 0 }))
    ).toBeNull();
  });
});

describe("NO_TRIAL_COPY", () => {
  it("has no badge and a plain Subscribe CTA", () => {
    expect(NO_TRIAL_COPY.badge).toBe("");
    expect(NO_TRIAL_COPY.cta).toBe("Subscribe");
    expect(NO_TRIAL_COPY.sub).toBe("Renews automatically. Cancel anytime.");
  });
});

describe("offeringsDisplayState", () => {
  const { offeringsDisplayState } = require("../utils/paywallCopy");

  it("reports error whenever a load error is set, regardless of offerings", () => {
    expect(offeringsDisplayState(null, "boom")).toBe("error");
    expect(offeringsDisplayState([], "boom")).toBe("error");
    expect(offeringsDisplayState([{ packageType: "ANNUAL" }], "boom")).toBe("error");
  });

  it("reports loading while offerings have not arrived", () => {
    expect(offeringsDisplayState(null, null)).toBe("loading");
  });

  it("reports empty for a loaded offering with zero packages", () => {
    expect(offeringsDisplayState([], null)).toBe("empty");
  });

  it("reports empty when no package is a monthly or annual plan", () => {
    expect(offeringsDisplayState([{ packageType: "LIFETIME" }], null)).toBe("empty");
    expect(offeringsDisplayState([{}], null)).toBe("empty");
  });

  it("reports plans when a monthly or annual package exists", () => {
    expect(offeringsDisplayState([{ packageType: "MONTHLY" }], null)).toBe("plans");
    expect(offeringsDisplayState([{ packageType: "ANNUAL" }], null)).toBe("plans");
    expect(
      offeringsDisplayState([{ packageType: "ANNUAL" }, { packageType: "MONTHLY" }], null)
    ).toBe("plans");
  });
});
