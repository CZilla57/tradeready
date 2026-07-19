// backend/lib/selectInvoicesToRemind.js
// Pure. Given ONE user's invoices + settings + the ids already auto-reminded,
// returns the invoices to email now. No I/O.

const { daysPastDue } = require("./overdue");
const { isFullyPaid } = require("./paymentMath");

/**
 * Coerce the way paymentMath does before testing: Number.isFinite("1000")
 * is false, but the math handles a string amount fine. Testing the raw
 * value would silently stop chasing an invoice whose amount round-tripped
 * through JSON as a string — which is exactly why toAmount exists.
 */
function isChaseableAmount(value) {
  const n = typeof value === "number" ? value : parseFloat(String(value));
  return Number.isFinite(n) && n > 0;
}

function selectInvoicesToRemind({ invoices, settings, alreadySentInvoiceIds, today = new Date() }) {
  if (!settings || !settings.autoSendEmailEnabled) return [];
  const rules = Array.isArray(settings.rules) ? settings.rules : [];
  if (rules.length === 0) return [];
  // r?.days (not r.days) so a null/malformed rule entry yields NaN and is
  // rejected by the isFinite guard below, rather than throwing and aborting the
  // whole cron run for every user.
  const earliest = Math.min(...rules.map((r) => Number(r?.days)));
  if (!Number.isFinite(earliest)) return [];

  const sent = new Set(alreadySentInvoiceIds || []);
  return (invoices || []).filter(
    (invoice) =>
      invoice &&
      // A non-finite amount (missing, NaN, etc.) makes balanceDue -> NaN, and
      // `NaN <= PAID_EPSILON` is false, so isFullyPaid would read a malformed
      // invoice as NOT fully paid and dun it — a regression versus the old
      // `!invoice.paid` check, which at least defaulted closed on `paid: true`.
      // Fail CLOSED here instead: if we cannot determine the balance, do not
      // send a reminder email over it.
      isChaseableAmount(invoice.amount) &&
      // Derive from the ledger rather than trusting the stored flag: the
      // Postgres trigger can union in payments the webhook never saw, so
      // `paid` may be stale. A voided payment correctly re-opens the invoice.
      !isFullyPaid(invoice) &&
      typeof invoice.email === "string" &&
      invoice.email.trim() !== "" &&
      invoice.due &&
      daysPastDue(invoice.due, today) >= earliest &&
      !sent.has(invoice.id)
  );
}

module.exports = { selectInvoicesToRemind };
