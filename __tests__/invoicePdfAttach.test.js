const {
  PDF_GRACE_MS,
  attachmentDecision,
  invoicePdfName,
} = require("../backend-workers/lib/invoicePdfAttach");

describe("attachmentDecision", () => {
  test("object present → attach regardless of age", () => {
    expect(attachmentDecision({ hasObject: true, ageMs: 0 })).toBe("attach");
    expect(attachmentDecision({ hasObject: true, ageMs: PDF_GRACE_MS * 5 })).toBe("attach");
  });
  test("absent + young → defer", () => {
    expect(attachmentDecision({ hasObject: false, ageMs: 0 })).toBe("defer");
    expect(attachmentDecision({ hasObject: false, ageMs: PDF_GRACE_MS - 1 })).toBe("defer");
  });
  test("absent + at/after grace → plain", () => {
    expect(attachmentDecision({ hasObject: false, ageMs: PDF_GRACE_MS })).toBe("plain");
    expect(attachmentDecision({ hasObject: false, ageMs: PDF_GRACE_MS + 1 })).toBe("plain");
  });
  test("absent + non-finite age → plain", () => {
    expect(attachmentDecision({ hasObject: false, ageMs: Infinity })).toBe("plain");
    expect(attachmentDecision({ hasObject: false, ageMs: NaN })).toBe("plain");
  });
  test("future-dated (negative age) is treated as young → defer", () => {
    expect(attachmentDecision({ hasObject: false, ageMs: -5000 })).toBe("defer");
  });
});

describe("invoicePdfName", () => {
  test("uses invoice number", () => {
    expect(invoicePdfName({ number: "INV-0001", id: "invA" })).toBe("Invoice-INV-0001.pdf");
  });
  test("falls back to id when number is empty", () => {
    expect(invoicePdfName({ number: "", id: "inv123" })).toBe("Invoice-inv123.pdf");
  });
  test("folds path-hostile characters and collapses dashes", () => {
    expect(invoicePdfName({ number: "INV/01 02", id: "x" })).toBe("Invoice-INV-01-02.pdf");
  });
  test("fully-hostile ref degrades to a safe default", () => {
    expect(invoicePdfName({ number: "///", id: "" })).toBe("Invoice-invoice.pdf");
  });
});
