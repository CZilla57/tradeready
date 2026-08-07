const {
  INVOICE_ID_RE,
  MAX_PDF_BYTES,
  base64ByteLength,
  looksLikePdf,
  validateUpload,
} = require("../backend-workers/lib/invoicePdfUpload");

// "%PDF-1.4\n" as base64
const PDF_B64 = Buffer.from("%PDF-1.4\n").toString("base64");

describe("base64ByteLength", () => {
  test("matches the decoded length for padded and unpadded input", () => {
    for (const s of ["", "aa==", "aaa=", "aaaa", PDF_B64]) {
      expect(base64ByteLength(s)).toBe(Buffer.from(s, "base64").length);
    }
  });
});

describe("looksLikePdf", () => {
  test("true for %PDF- header, false otherwise", () => {
    expect(looksLikePdf(Buffer.from("%PDF-1.7"))).toBe(true);
    expect(looksLikePdf(Buffer.from("PK"))).toBe(false);
    expect(looksLikePdf(Buffer.from("%PD"))).toBe(false);
  });
});

describe("validateUpload", () => {
  test("accepts a well-formed PDF upload", () => {
    const r = validateUpload({ invoiceId: "inv123", pdfBase64: PDF_B64 });
    expect(r.ok).toBe(true);
    expect(r.status).toBe(200);
    expect(Buffer.isBuffer(r.bytes)).toBe(true);
  });
  test("rejects a bad invoiceId", () => {
    for (const bad of ["", "a/b", "../x", "x".repeat(65), 42, null]) {
      const r = validateUpload({ invoiceId: bad, pdfBase64: PDF_B64 });
      expect(r.ok).toBe(false);
      expect(r.status).toBe(400);
    }
    expect(INVOICE_ID_RE.test("inv123")).toBe(true);
  });
  test("rejects missing/empty pdfBase64", () => {
    expect(validateUpload({ invoiceId: "inv1", pdfBase64: "" }).status).toBe(400);
    expect(validateUpload({ invoiceId: "inv1", pdfBase64: undefined }).status).toBe(400);
  });
  test("rejects an over-cap payload before decoding", () => {
    // base64 length that decodes to just over MAX_PDF_BYTES, made of valid chars.
    const overChars = Math.ceil((MAX_PDF_BYTES + 1) * 4 / 3) + 4;
    const big = "A".repeat(overChars);
    const r = validateUpload({ invoiceId: "inv1", pdfBase64: big });
    expect(r.ok).toBe(false);
    expect(r.status).toBe(413);
  });
  test("rejects a non-PDF body", () => {
    const notPdf = Buffer.from("hello world, not a pdf").toString("base64");
    const r = validateUpload({ invoiceId: "inv1", pdfBase64: notPdf });
    expect(r.ok).toBe(false);
    expect(r.status).toBe(400);
  });
});
