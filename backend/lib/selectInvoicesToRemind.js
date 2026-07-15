// backend/lib/selectInvoicesToRemind.js
// Pure. Given ONE user's invoices + settings + the ids already auto-reminded,
// returns the invoices to email now. No I/O.

const { daysPastDue } = require("./overdue");

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
      !invoice.paid &&
      typeof invoice.email === "string" &&
      invoice.email.trim() !== "" &&
      invoice.due &&
      daysPastDue(invoice.due, today) >= earliest &&
      !sent.has(invoice.id)
  );
}

module.exports = { selectInvoicesToRemind };
