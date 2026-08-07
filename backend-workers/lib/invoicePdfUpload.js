// backend-workers/lib/invoicePdfUpload.js
// Pure validation for the POST /api/invoice-pdf upload (2026-08-06 spec).
// No I/O — the route (src/routes/invoicePdf.js) does auth + R2 put around it.
// Buffer is available under wrangler's nodejs_compat and in Jest (Node).

const INVOICE_ID_RE = /^[A-Za-z0-9_-]{1,64}$/;
const MAX_PDF_BYTES = 5 * 1024 * 1024;

// Decoded byte length from base64 length alone, so a hostile oversized body is
// rejected before it is decoded/allocated.
function base64ByteLength(b64) {
  const len = b64.length;
  if (len === 0) return 0;
  const padding = b64.endsWith("==") ? 2 : b64.endsWith("=") ? 1 : 0;
  return Math.floor((len * 3) / 4) - padding;
}

// %PDF- magic bytes: 0x25 0x50 0x44 0x46 0x2D.
function looksLikePdf(bytes) {
  return (
    bytes.length >= 5 &&
    bytes[0] === 0x25 &&
    bytes[1] === 0x50 &&
    bytes[2] === 0x44 &&
    bytes[3] === 0x46 &&
    bytes[4] === 0x2d
  );
}

function validateUpload({ invoiceId, pdfBase64 }) {
  if (typeof invoiceId !== "string" || !INVOICE_ID_RE.test(invoiceId)) {
    return { ok: false, status: 400, error: "Invalid invoiceId" };
  }
  if (typeof pdfBase64 !== "string" || pdfBase64.length === 0) {
    return { ok: false, status: 400, error: "Missing pdfBase64" };
  }
  if (base64ByteLength(pdfBase64) > MAX_PDF_BYTES) {
    return { ok: false, status: 413, error: "PDF too large" };
  }
  const bytes = Buffer.from(pdfBase64, "base64");
  if (!looksLikePdf(bytes)) {
    return { ok: false, status: 400, error: "Not a PDF" };
  }
  return { ok: true, status: 200, bytes };
}

module.exports = {
  INVOICE_ID_RE,
  MAX_PDF_BYTES,
  base64ByteLength,
  looksLikePdf,
  validateUpload,
};
