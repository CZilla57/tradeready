// Deriving the onboarding "region" prefill from the business address.

const { regionFromAddress } = require("../utils/regionFromAddress");

describe("regionFromAddress", () => {
  test("parses the classic three-segment format", () => {
    expect(regionFromAddress("123 Main St, Dallas, TX 75201")).toBe("Dallas, TX");
    expect(regionFromAddress("9 Elm Ave, Portland, OR")).toBe("Portland, OR");
  });

  test("parses city and state joined in one segment (the real device case)", () => {
    expect(regionFromAddress("2531 W Lucia Dr, Phoenix Az 85085")).toBe("Phoenix, AZ");
    expect(regionFromAddress("10 Oak Ln, Salt Lake City UT 84101")).toBe("Salt Lake City, UT");
  });

  test("handles zip+4 and uppercases the state", () => {
    expect(regionFromAddress("1 Way, Austin tx 78701-1234")).toBe("Austin, TX");
  });

  test("falls back to the city segment when no 2-letter state is present", () => {
    expect(regionFromAddress("123 Main St, Springfield")).toBe("Springfield");
  });

  test("returns empty when it cannot infer anything safely", () => {
    expect(regionFromAddress("")).toBe("");
    expect(regionFromAddress("   ")).toBe("");
    expect(regionFromAddress("123 Main St")).toBe("");
  });

  test("ignores empty segments from stray commas", () => {
    expect(regionFromAddress("123 Main St,, Dallas, TX 75201,")).toBe("Dallas, TX");
  });
});
