// backend-workers/lib/invoiceEmail.js
// Pure. Builds the Resend payload for one auto-emailed invoice (2026-08-06
// spec). Template-only — deterministic, no AI (unattended mail the user never
// previews). No I/O. Sibling of reminderEmail.js, reusing its hardened
// pieces: sanitizeFromPhrase for the From header, and the pay-link rule
// (amount matches the balance this email quotes + allowlisted https host —
// see reminderEmail.js for the phishing rationale). A failing link check
// drops the LINE, never the email.

const { formatMoney } = require("./overdue");
const { balanceDue, amountPaid, PAID_EPSILON } = require("./paymentMath");
const { isAllowedPaymentLink, sanitizeFromPhrase } = require("./reminderEmail");

const SENDER = "invoices@gettradereadyapp.com";

// The subject is a mail header built from user-synced data — strip CR/LF
// (header smuggling), collapse whitespace, cap the length.
function sanitizeSubject(value) {
  return String(value || "")
    .replace(/[\r\n]+/g, " ")
    .replace(/\s+/g, " ")
    .trim()
    .slice(0, 120);
}

function buildInvoiceEmail({ invoice, settings }) {
  const paid = amountPaid(invoice);
  const balance = balanceDue(invoice);
  // A partly-paid invoice (e.g. a deposit) names both numbers so the customer
  // sees their payment credited — same phrasing family as reminderEmail.js.
  const amount = paid > 0 && balance > 0
    ? `${formatMoney(balance)} of ${formatMoney(invoice.amount)} after payments received`
    : formatMoney(balance);
  const biz = settings.businessName || "your contractor";

  // Breakdown from the client-built lineItems (labor / materials / overhead /
  // approved change orders). Absent or empty → no breakdown block; the email
  // never fabricates one.
  const items = Array.isArray(invoice.lineItems) ? invoice.lineItems : [];
  const breakdown = items.length
    ? "\n" +
      items
        .filter(Boolean)
        .map((li) => `  - ${String(li.description || "Item")}: ${formatMoney(li.amount)}`)
        .join("\n") +
      "\n"
    : "";

  // Cached pay link only when minted for the balance this email quotes AND on
  // an allowlisted https host (rule shared with reminderEmail.js). An absent
  // or unparseable paymentLinkAmount fails the match — honest degradation.
  const linkAmount = typeof invoice.paymentLinkAmount === "number"
    ? invoice.paymentLinkAmount
    : parseFloat(String(invoice.paymentLinkAmount));
  const linkCurrent =
    invoice.paymentLinkUrl &&
    isAllowedPaymentLink(invoice.paymentLinkUrl) &&
    Number.isFinite(linkAmount) &&
    Math.abs(linkAmount - balance) <= PAID_EPSILON;
  const linkLine = linkCurrent
    ? `\nYou can pay securely here: ${invoice.paymentLinkUrl}\n`
    : "";
  const notes = settings.paymentNotes ? `\n${settings.paymentNotes}\n` : "";
  const forWork = invoice.desc ? ` for ${invoice.desc}` : "";

  const text = `Hi ${invoice.customer},

Thanks for your business! Here's your invoice${forWork}.

Invoice ${invoice.number} — ${amount}, due ${invoice.due}.
${breakdown}${linkLine}
Questions about this invoice? Just reply to this email or contact ${biz}.
${notes}
Best regards,
${settings.contactName || ""}
${settings.businessName || ""}
${settings.phone || ""}`.replace(/\n{3,}/g, "\n\n");

  // Header-safe From phrase; a name that sanitizes away to nothing degrades
  // to the neutral bare sender rather than an empty display name.
  const fromPhrase = sanitizeFromPhrase(settings.businessName);
  const email = {
    from: fromPhrase ? `${fromPhrase} via TradeReady <${SENDER}>` : `TradeReady <${SENDER}>`,
    to: [invoice.email],
    subject: sanitizeSubject(`Invoice ${invoice.number} from ${fromPhrase || "TradeReady"}`),
    text,
  };
  if (settings.email) email.reply_to = settings.email;
  return email;
}

module.exports = { buildInvoiceEmail, SENDER };
