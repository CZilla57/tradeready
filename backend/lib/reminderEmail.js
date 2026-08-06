// backend/lib/reminderEmail.js
// Pure. Builds the Resend payload for one overdue invoice. Template-only —
// deterministic, no AI (unattended mail the user never previews). No I/O.

const { daysPastDue, formatMoney } = require("./overdue");
const { balanceDue, amountPaid, PAID_EPSILON } = require("./paymentMath");

const SENDER = "reminders@gettradereadyapp.com";

// Hosts a cached payment link is allowed to point at. The URL is user-synced
// data mailed unattended from the verified domain — an arbitrary link here
// would let any signed-up account send phishing mail signed by
// gettradereadyapp.com. squareup.com is deliberately ABSENT: pre-2026-08
// builds cached squareup.com/pay/<Square access token> links (the client-side
// mirror of this exclusion is cachedLinkMatches in utils/invoiceHelpers.ts).
const ALLOWED_LINK_HOSTS = new Set([
  "buy.stripe.com",
  "checkout.stripe.com",
  "paypal.me",
  "venmo.com",
  "square.link",
  "checkout.square.site",
]);

// True only for an https URL whose host (case-insensitive, with or without a
// leading www.) is on the allowlist. Anything unparseable fails closed.
function isAllowedPaymentLink(url) {
  let parsed;
  try {
    parsed = new URL(String(url));
  } catch {
    return false;
  }
  if (parsed.protocol !== "https:") return false;
  const host = parsed.hostname.toLowerCase().replace(/^www\./, "");
  return ALLOWED_LINK_HOSTS.has(host);
}

// The From display name is attacker-influenceable synced data landing in a
// mail header. Strip the characters that could close the phrase or smuggle a
// second header (quotes, angle brackets, CR/LF), collapse whitespace, and cap
// the length. Returns "" when nothing survives — the caller then drops the
// "via" phrase entirely rather than sending an empty display name.
function sanitizeFromPhrase(name) {
  return String(name || "")
    .replace(/["<>\r\n]/g, "")
    .replace(/\s+/g, " ")
    .trim()
    .slice(0, 80);
}

// The subject is a mail header built from user-synced data — strip CR/LF
// (header smuggling), collapse whitespace, cap the length.
function sanitizeSubject(value) {
  return String(value || "")
    .replace(/[\r\n]+/g, " ")
    .replace(/\s+/g, " ")
    .trim()
    .slice(0, 120);
}

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
  // ...and only when the link points at a known payment host over https
  // (isAllowedPaymentLink above). A disallowed link drops the LINE, never the
  // email — the reminder text stands on its own.
  const linkCurrent =
    invoice.paymentLinkUrl &&
    isAllowedPaymentLink(invoice.paymentLinkUrl) &&
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

  // Header-safe From phrase; a name that sanitizes away to nothing degrades to
  // the neutral bare sender rather than an empty display name.
  const fromPhrase = sanitizeFromPhrase(settings.businessName);
  const email = {
    from: fromPhrase ? `${fromPhrase} via TradeReady <${SENDER}>` : `TradeReady <${SENDER}>`,
    to: [invoice.email],
    subject: sanitizeSubject(`Payment reminder – ${invoice.number}`),
    text,
  };
  if (settings.email) email.reply_to = settings.email;
  return email;
}

module.exports = { buildReminderEmail, isAllowedPaymentLink, sanitizeFromPhrase, sanitizeSubject };
