// backend-workers/lib/selectInvoicesToAutoEmail.js
// Pure. Given ONE user's invoices + settings + the invoice ids already
// claimed in auto_invoice_email_log, returns the invoices whose auto-email
// should send now (2026-08-06 spec). No I/O.
//
// Only invoices the CLIENT stamped (autoEmailRequestedAt, written by
// utils/autoInvoice.ts createAutoInvoiceForJob when the owner opted in and
// the customer had an email) are ever considered — a manually created
// invoice, or the pre-existing backlog on first opt-in, can never be emailed
// by this sweep.

const { isFullyPaid } = require("./paymentMath");
const { isPlausibleEmail } = require("./selectInvoicesToRemind");

// A stamped invoice that reaches the sweep later than this never sends: a
// long-offline device syncing up weeks-old invoices must not blast stale
// email at customers. Stale ones are simply excluded on every run (no log
// row) — cheap at this scale, and it keeps the log's status enum identical
// to auto_reminder_log's.
const MAX_REQUEST_AGE_DAYS = 7;

function selectInvoicesToAutoEmail({ invoices, settings, alreadyHandledInvoiceIds, today = new Date() }) {
  // Checked at SEND time, not stamp time: turning the toggle off halts
  // anything still pending.
  if (!settings || !settings.autoEmailInvoiceOnComplete) return [];
  const handled = new Set(alreadyHandledInvoiceIds || []);
  const now = today.getTime();
  const maxAgeMs = MAX_REQUEST_AGE_DAYS * 86400000;

  return (invoices || []).filter((invoice) => {
    if (!invoice || !invoice.autoEmailRequestedAt) return false;
    const stamped = Date.parse(invoice.autoEmailRequestedAt);
    // Unparseable → fail closed. Future-dated (clock skew) counts as fresh.
    if (!Number.isFinite(stamped) || now - stamped > maxAgeMs) return false;
    // Derive from the ledger, not the stored flag (same rationale as the
    // reminder selector): a customer who paid on the spot before the sweep
    // must not be emailed a bill — and a malformed amount balances to zero,
    // which correctly fails closed here.
    if (isFullyPaid(invoice)) return false;
    if (!isPlausibleEmail(invoice.email)) return false;
    return !handled.has(invoice.id);
  });
}

module.exports = { selectInvoicesToAutoEmail, MAX_REQUEST_AGE_DAYS };
