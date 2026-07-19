// backend/lib/reminderEmail.js
// Pure. Builds the Resend payload for one overdue invoice. Template-only —
// deterministic, no AI (unattended mail the user never previews). No I/O.

const { daysPastDue, formatMoney } = require("./overdue");
const { balanceDue, amountPaid } = require("./paymentMath");

const SENDER = "reminders@gettradereadyapp.com";

function buildReminderEmail({ invoice, settings, today = new Date() }) {
  // Mirrors describeAmountOwed in utils/invoiceHelpers.ts. A partly-paid
  // invoice names both numbers so the customer sees their deposit credited.
  // backend/ is a separate package and cannot import the TS util.
  const paid = amountPaid(invoice);
  const balance = balanceDue(invoice);
  const amount = paid > 0 && balance > 0
    ? `${formatMoney(balance)} of ${formatMoney(invoice.amount)} still outstanding`
    : formatMoney(balance);
  const days = daysPastDue(invoice.due, today);
  const biz = settings.businessName || "your contractor";
  const linkLine = invoice.paymentLinkUrl
    ? `\nYou can pay securely here: ${invoice.paymentLinkUrl}\n`
    : "";
  const notes = settings.paymentNotes ? `\n${settings.paymentNotes}\n` : "";

  const text = `Hi ${invoice.customer},

Invoice ${invoice.number} — ${amount}, now ${days} days overdue.
${linkLine}
If you've already sent payment, thank you — please disregard this note. Questions, or want to stop these reminders? Just reply to this email or contact ${biz}.
${notes}
Best regards,
${settings.contactName || ""}
${settings.businessName || ""}
${settings.phone || ""}`.replace(/\n{3,}/g, "\n\n");

  const email = {
    from: `${biz} via TradeReady <${SENDER}>`,
    to: [invoice.email],
    subject: `Payment reminder – ${invoice.number}`,
    text,
  };
  if (settings.email) email.reply_to = settings.email;
  return email;
}

module.exports = { buildReminderEmail };
