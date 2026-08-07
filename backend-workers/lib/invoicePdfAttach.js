// backend-workers/lib/invoicePdfAttach.js
// Pure send-side helpers for the auto-invoice PDF attachment (2026-08-06 spec).
// No I/O. Shared by sendInvoiceEmails.js and unit-tested directly.

// Grace window: the client uploads the PDF within seconds of completing the
// job, so 24h is a generous margin for a device that was offline at
// completion. Past it, billing must not stall on a missing PDF — send plain.
const PDF_GRACE_MS = 24 * 60 * 60 * 1000;

// Decide what the sweep does with one invoice given whether its PDF is in R2
// and how old the auto-email request is.
//   attach → the object exists, attach it
//   defer  → not there yet but still young; skip this run, retry next sweep
//   plain  → give up waiting (or age is unknowable); send without the PDF
function attachmentDecision({ hasObject, ageMs, graceMs = PDF_GRACE_MS }) {
  if (hasObject) return "attach";
  if (Number.isFinite(ageMs) && ageMs < graceMs) return "defer";
  return "plain";
}

// Customer-facing attachment name. The file's real identity is the R2 key;
// this only needs the invoice number, so it deliberately does NOT import the
// RN app's invoicePdfFilename (which pulls in expo-*). Blocklist matches
// utils/invoicePdfFile.ts: filesystem-reserved + URI-significant + whitespace.
const UNSAFE_IN_FILENAME = /[\\/:*?"<>|#%\s]+/g;
function invoicePdfName(invoice) {
  const ref = String((invoice && (invoice.number || invoice.id)) || "invoice")
    .replace(UNSAFE_IN_FILENAME, "-")
    .replace(/-{2,}/g, "-")
    .replace(/^-+|-+$/g, "");
  return `Invoice-${ref || "invoice"}.pdf`;
}

module.exports = { PDF_GRACE_MS, attachmentDecision, invoicePdfName };
