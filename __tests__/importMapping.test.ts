// __tests__/importMapping.test.ts
import {
  FIELD_DEFS,
  detectMapping,
  detectDateFormat,
  parseImportDate,
} from "../utils/importMapping";

describe("FIELD_DEFS", () => {
  test("declares required minimums per entity", () => {
    const req = (e: "customers" | "jobs" | "invoices" | "expenses") =>
      FIELD_DEFS[e].filter((f) => f.required).map((f) => f.key).sort();
    expect(req("customers")).toEqual(["name"]);
    expect(req("jobs")).toEqual(["customerName", "title"]);
    expect(req("invoices")).toEqual(["amount", "customer"]);
    expect(req("expenses")).toEqual(["amount", "date"]);
  });
});

describe("detectMapping", () => {
  test("maps a Jobber-style customer export by synonyms", () => {
    const { mapping } = detectMapping("customers", ["Full Name", "Email Address", "Mobile", "Street Address"]);
    expect(mapping).toEqual(["name", "email", "phone", "address"]);
  });

  test("joins First Name + Last Name into name", () => {
    const { mapping } = detectMapping("customers", ["First Name", "Last Name", "Cell"]);
    expect(mapping).toEqual(["name", "name", "phone"]);
  });

  test("leaves unrecognised headers unmapped", () => {
    const { mapping } = detectMapping("customers", ["Name", "Loyalty Tier"]);
    expect(mapping).toEqual(["name", null]);
  });

  test("maps an invoice export (customer + amount + due + number)", () => {
    const { mapping } = detectMapping("invoices", ["Client", "Total", "Due Date", "Invoice #", "Paid On"]);
    expect(mapping).toEqual(["customer", "amount", "due", "number", "paidAt"]);
  });
});

describe("detectDateFormat", () => {
  test("recognises ISO", () => {
    expect(detectDateFormat(["2026-01-05", "2026-11-30"])).toBe("YMD");
  });
  test("disambiguates DMY when a value exceeds 12 in the first slot", () => {
    expect(detectDateFormat(["13/02/2026", "01/03/2026"])).toBe("DMY");
  });
  test("defaults ambiguous slash dates to MDY (US)", () => {
    expect(detectDateFormat(["01/02/2026", "03/04/2026"])).toBe("MDY");
  });
  test("returns null when nothing looks like a date", () => {
    expect(detectDateFormat(["hello", ""])).toBeNull();
  });
});

describe("parseImportDate", () => {
  test("parses ISO to local YYYY-MM-DD", () => {
    expect(parseImportDate("2026-07-04", "YMD")).toBe("2026-07-04");
  });
  test("parses US M/D/Y without a UTC shift", () => {
    expect(parseImportDate("7/4/2026", "MDY")).toBe("2026-07-04");
  });
  test("parses D/M/Y", () => {
    expect(parseImportDate("4/7/2026", "DMY")).toBe("2026-07-04");
  });
  test("returns null on garbage or impossible dates", () => {
    expect(parseImportDate("not a date", "MDY")).toBeNull();
    expect(parseImportDate("13/13/2026", "MDY")).toBeNull();
  });
});
