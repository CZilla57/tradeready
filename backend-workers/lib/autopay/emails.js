// Customer emails and owner alerts for card-on-file autopay (Phase 24 spec
// §4.7). Pure, deterministic, template-only (no AI): this mail goes out
// unattended. Reuses the hardened pieces of reminderEmail.js:
//   - sanitizeFromPhrase / sanitizeSubject for every header built from
//     synced data
//   - isAllowedPaymentLink for every link (pay-page links pass only as
//     https://gettradereadyapp.com/pay(.html)); a failing link drops the
//     LINE, never the email
//   - isPlausibleEmail for every recipient: an implausible address returns
//     null (no mail), never throws
// Customer mail: "{Biz} via TradeReady" <invoices@…>, reply_to the owner's
// settings email. Owner alerts: TradeReady <payments@…> to the auth email.

const { isAllowedPaymentLink, sanitizeFromPhrase, sanitizeSubject } = require('../reminderEmail.js');
const { isPlausibleEmail } = require('../selectInvoicesToRemind.js');
const { money, clean } = require('./format.js');
const { customerReasonClause, ownerReasonClause } = require('./reasons.js');

const CUSTOMER_SENDER = 'invoices@gettradereadyapp.com';
const OWNER_SENDER = 'TradeReady <payments@gettradereadyapp.com>';

function biz(settings) {
  return clean(settings && settings.businessName, 120) || 'your contractor';
}

function customerEnvelope({ settings, to, subject, text }) {
  if (!isPlausibleEmail(to)) return null;
  const phrase = sanitizeFromPhrase(settings && settings.businessName);
  const email = {
    from: phrase ? `${phrase} via TradeReady <${CUSTOMER_SENDER}>` : `TradeReady <${CUSTOMER_SENDER}>`,
    to: [to],
    subject: sanitizeSubject(subject),
    text: text.replace(/\n{3,}/g, '\n\n'),
  };
  if (settings && isPlausibleEmail(settings.email)) email.reply_to = settings.email;
  return email;
}

function signature(settings) {
  const s = settings || {};
  return `Best regards,\n${s.contactName || ''}\n${s.businessName || ''}\n${s.phone || ''}`.trimEnd();
}

function safeLink(url) {
  return url && isAllowedPaymentLink(url) ? url : null;
}

function greeting(name) {
  const n = clean(name, 80);
  return n ? `Hi ${n},` : 'Hi,';
}

function planName(description) {
  return clean(description, 200) || 'maintenance';
}

// Payment receipt (pay-page payments) and autopay receipt (spec §4.7).
// `amountCents` is the invoice payment. A pay-page payment with a tip
// (Phase 28, tips spec §4.4) passes `tipCents` and the receipt itemizes
// invoice payment / tip / total charged; without one the text is unchanged.
// Autopay receipts never carry a tip.
function buildReceiptEmail({ settings, to, customerName, invoiceNumber, amountCents, tipCents = 0, card, remainingCents, date, autopay = false, manageUrl }) {
  const number = clean(invoiceNumber, 60);
  const manage = autopay ? safeLink(manageUrl) : null;
  const tip = !autopay && Number.isInteger(tipCents) && tipCents > 0 ? tipCents : 0;
  const lines = [
    greeting(customerName),
    '',
    autopay
      ? `Your invoice from ${biz(settings)} was paid automatically with your saved card. Thank you!`
      : `Thanks for your payment to ${biz(settings)}.`,
    '',
    `Invoice ${number || '(no number)'}`,
    ...(tip
      ? [`Invoice payment: ${money(amountCents)}`, `Tip: ${money(tip)}`, `Total charged: ${money(amountCents + tip)}`]
      : [`Amount paid: ${money(amountCents)}`]),
    ...(card ? [`Card: ${card}`] : []),
    `Date: ${date}`,
    remainingCents > 0 ? `Remaining balance: ${money(remainingCents)}` : 'This invoice is now paid in full.',
    '',
    ...(manage ? [`Manage or turn off automatic payments: ${manage}`, ''] : []),
    `Questions? Just reply to this email or contact ${biz(settings)}.`,
    '',
    signature(settings),
  ];
  return customerEnvelope({
    settings,
    to,
    subject: `${autopay ? 'Automatic payment receipt' : 'Payment receipt'} – Invoice ${number}`,
    text: lines.join('\n'),
  });
}

// "Automatic payments are on" — repeats the authorization (the record of the
// agreement Stripe's off-session checklist asks for) and the manage link.
function buildAutopayOnEmail({ settings, to, customerName, planDescription, card, consentText, consentedAt, manageUrl }) {
  const manage = safeLink(manageUrl);
  const lines = [
    greeting(customerName),
    '',
    `Automatic payments are on for your "${planName(planDescription)}" plan with ${biz(settings)}${card ? `, using your ${card}` : ''}.`,
    'Each invoice under this plan will be charged on its due date, and you will get a receipt every time.',
    '',
    `This is the authorization you gave${consentedAt ? ` on ${String(consentedAt).slice(0, 10)}` : ''}:`,
    '',
    consentText,
    '',
    ...(manage ? [`Manage or turn off automatic payments: ${manage}`, ''] : []),
    `Questions? Just reply to this email or contact ${biz(settings)}.`,
    '',
    signature(settings),
  ];
  return customerEnvelope({
    settings,
    to,
    subject: `Automatic payments are on – ${planName(planDescription)}`,
    text: lines.join('\n'),
  });
}

// Charge failed or skipped: reason, pay link, manage link (spec §4.6 step 5).
function buildChargeFailedEmail({ settings, to, customerName, invoiceNumber, amountCents, maxAmountCents, reason, payUrl, manageUrl, cardRemoved = false }) {
  const number = clean(invoiceNumber, 60);
  const pay = safeLink(payUrl);
  const manage = cardRemoved ? null : safeLink(manageUrl);
  const above = reason === 'amount_above_authorized';
  const lines = [
    greeting(customerName),
    '',
    above
      ? `We didn't charge your saved card for invoice ${number} because the amount due (${money(amountCents)}) is more than the ${money(maxAmountCents)} you authorized for automatic payments. Nothing was charged.`
      : `We tried to charge your saved card for invoice ${number} (${money(amountCents)}) from ${biz(settings)}, but ${customerReasonClause(reason)}. Nothing was charged.`,
    ...(cardRemoved ? ['', 'That card has been removed from automatic payments.'] : []),
    '',
    pay ? `You can pay securely here: ${pay}` : `Please contact ${biz(settings)} to pay this invoice.`,
    '',
    above
      ? 'When you pay, you can tick "update automatic payments" to approve the new amount for future invoices.'
      : 'When you pay, you can tick "pay future invoices automatically" to save a new card for this plan.',
    '',
    ...(manage ? [`Manage automatic payments: ${manage}`, ''] : []),
    `Questions? Just reply to this email or contact ${biz(settings)}.`,
    '',
    signature(settings),
  ];
  return customerEnvelope({
    settings,
    to,
    subject: `Action needed: invoice ${number} was not paid automatically`,
    text: lines.join('\n'),
  });
}

// "Automatic payments are off" — says who turned it off.
function buildAutopayOffEmail({ settings, to, customerName, planDescription, by }) {
  const plan = planName(planDescription);
  const who = by === 'owner' ? biz(settings) : by === 'customer' ? 'You' : 'We';
  const lines = [
    greeting(customerName),
    '',
    by === 'system'
      ? `Automatic payments for your "${plan}" plan with ${biz(settings)} have been turned off.`
      : `${who} turned off automatic payments for your "${plan}" plan${by === 'owner' ? '' : ` with ${biz(settings)}`}.`,
    'Future invoices will not be charged automatically, and your saved card has been removed.',
    'Each new invoice will be emailed to you as usual with a link to pay.',
    '',
    `Questions? Just reply to this email or contact ${biz(settings)}.`,
    '',
    signature(settings),
  ];
  return customerEnvelope({
    settings,
    to,
    subject: `Automatic payments are off – ${plan}`,
    text: lines.join('\n'),
  });
}

// --- owner alerts (email + push) -----------------------------------------------

function ownerChargeProblemAlert({ customerName, invoiceNumber, amountCents, reason, customerEmailed, cardRemoved }) {
  const who = clean(customerName, 80) || 'A customer';
  const number = clean(invoiceNumber, 60);
  if (reason === 'unknown') {
    return {
      subject: `Check Stripe: automatic payment for invoice ${number} unconfirmed`,
      text: [
        `We couldn't confirm the automatic payment for invoice ${number} (${money(amountCents)}) from ${who}.`,
        'Before collecting again, check your Stripe dashboard for a payment on this invoice.',
        'If you find one, record it in TradeReady; if not, ask the customer to pay with a payment link.',
      ].join('\n'),
      pushTitle: 'Check Stripe for an autopay charge',
      pushBody: `${who} — invoice ${number}`,
    };
  }
  const verb = reason === 'amount_above_authorized' ? 'was not charged automatically' : 'failed';
  return {
    subject: `Autopay ${reason === 'amount_above_authorized' ? 'skipped' : 'failed'}: ${who} – invoice ${number}`,
    text: [
      `The automatic payment for invoice ${number} (${money(amountCents)}) from ${who} ${verb}: ${ownerReasonClause(reason)}.`,
      customerEmailed
        ? 'We emailed them a payment link.'
        : 'We could not email them a payment link (no valid email on file). Please reach out to collect.',
      ...(cardRemoved ? ['Their saved card was removed from automatic payments, so later invoices will not be charged until they save a new card.'] : []),
      '',
      'Open TradeReady to see the invoice.',
    ].join('\n'),
    pushTitle: reason === 'amount_above_authorized' ? 'Autopay skipped' : 'Autopay failed',
    pushBody: `${who} — invoice ${number}: ${ownerReasonClause(reason)}`,
  };
}

function ownerAutopayOffAlert({ customerName, planDescription, by, reason }) {
  const who = clean(customerName, 80) || 'A customer';
  const plan = planName(planDescription);
  if (by === 'customer') {
    return {
      subject: `${who} turned off automatic payments`,
      text: `${who} turned off automatic payments for the "${plan}" plan. Their saved card was removed. New invoices for this plan will go out with a payment link as usual.\n\nOpen TradeReady to see the plan.`,
      pushTitle: 'Autopay turned off',
      pushBody: `${who} — ${plan}`,
    };
  }
  return {
    subject: `Saved card removed: ${who}`,
    text: `${who}'s saved card was removed from automatic payments for the "${plan}" plan: ${ownerReasonClause(reason)}. New invoices for this plan will go out with a payment link as usual.\n\nOpen TradeReady to see the plan.`,
    pushTitle: 'Saved card removed',
    pushBody: `${who} — ${plan}`,
  };
}

function buildOwnerAlertEmail({ to, subject, text }) {
  if (!isPlausibleEmail(to)) return null;
  return { from: OWNER_SENDER, to: [to], subject: sanitizeSubject(subject), text };
}

module.exports = {
  CUSTOMER_SENDER,
  OWNER_SENDER,
  buildReceiptEmail,
  buildAutopayOnEmail,
  buildChargeFailedEmail,
  buildAutopayOffEmail,
  ownerChargeProblemAlert,
  ownerAutopayOffAlert,
  buildOwnerAlertEmail,
};
