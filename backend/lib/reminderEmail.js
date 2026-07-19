// backend/lib/reminderEmail.js
// Pure. Builds the Resend payload for one overdue invoice. Template-only —
// deterministic, no AI (unattended mail the user never previews). No I/O.

const { daysPastDue, formatMoney } = require("./overdue");
const { balanceDue, amountPaid, PAID_EPSILON } = require("./paymentMath");

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
  // Include the cached payment link ONLY when it was minted for the balance
  // this email quotes. A link cached before a partial payment — or minted for
  // a deposit — charges a different amount than the text asks for, and this
  // mail goes out unattended: nobody is there to catch the customer being
  // overcharged. Mirrors cachedLinkMatches in utils/invoiceHelpers.ts.
  // An unparseable/absent paymentLinkAmount fails the match and omits the
  // link — the honest degradation, since we can't verify what it charges.
  const linkAmount = typeof invoice.paymentLinkAmount === "number"
    ? invoice.paymentLinkAmount
    : parseFloat(String(invoice.paymentLinkAmount));
  const linkCurrent =
    invoice.paymentLinkUrl &&
    Number.isFinite(linkAmount) &&
    Math.abs(linkAmount - balance) <= PAID_EPSILON;
  const linkLine = linkCurrent
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
