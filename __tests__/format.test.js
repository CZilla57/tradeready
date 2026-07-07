import { formatMoney, formatQuote } from "../utils/format";

// formatMoney — actual amounts (invoices, expenses, totals). Always 2 decimals.
describe("formatMoney", () => {
  test("whole dollars still show cents", () => {
    expect(formatMoney(2400)).toBe("$2,400.00");
  });

  test("cents preserved — never rounds a $9.99 to $10", () => {
    expect(formatMoney(9.99)).toBe("$9.99");
  });

  test("zero", () => {
    expect(formatMoney(0)).toBe("$0.00");
  });

  test("thousands separator", () => {
    expect(formatMoney(1234.56)).toBe("$1,234.56");
  });

  test("negatives use Intl sign placement (-$X.00, not the old $-X)", () => {
    expect(formatMoney(-500)).toBe("-$500.00");
  });

  test("non-numeric input degrades to $0.00", () => {
    expect(formatMoney(NaN)).toBe("$0.00");
    expect(formatMoney(undefined)).toBe("$0.00");
  });
});

// formatQuote — estimate / pricing headlines. Whole dollars, cents only when needed.
describe("formatQuote", () => {
  test("round amounts have no trailing cents", () => {
    expect(formatQuote(2400)).toBe("$2,400");
  });

  test("cents revealed only when present", () => {
    expect(formatQuote(9.99)).toBe("$9.99");
    expect(formatQuote(1234.56)).toBe("$1,234.56");
  });

  test("zero", () => {
    expect(formatQuote(0)).toBe("$0");
  });

  test("negatives use Intl sign placement", () => {
    expect(formatQuote(-500)).toBe("-$500");
  });

  test("non-numeric input degrades to $0", () => {
    expect(formatQuote(NaN)).toBe("$0");
  });
});
