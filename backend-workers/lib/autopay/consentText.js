// The customer's autopay authorization (Phase 24 spec §2.3; wording approved
// by the owner as decision 24-Q4 on 2026-10-03). Pure.
//
// The Worker renders this text; the pay page shows it verbatim; on submit
// the server renders it AGAIN from the live plan and stores exactly that in
// autopay_enrollments.consent_text, with CONSENT_VERSION. Any wording change
// must bump the version, so a page holding the old text gets a 409 "please
// reload" instead of a record of text the customer never saw.

const { money, clean } = require('./format.js');

const CONSENT_VERSION = 'autopay-consent-v1';

const CADENCE_PHRASES = {
  daily: 'every day',
  weekly: 'every week',
  monthly: 'every month',
  quarterly: 'every 3 months',
  annually: 'every year',
};

function cadencePhrase(cadence) {
  return CADENCE_PHRASES[cadence] || null;
}

function displayBusiness(businessName) {
  return clean(businessName, 120) || 'the business';
}

function displayPlan(description) {
  return clean(description, 200) || 'maintenance';
}

const TITLE = 'Pay future invoices for this plan automatically with this card';

// → { title, body, text } where text = title + "\n\n" + body is what is shown
// and stored. `isUpdate` (an active authorization below the plan's current
// amount, spec §2.2) changes only the title.
function renderConsent({ businessName, planDescription, amountCents, cadence, isUpdate = false }) {
  const biz = displayBusiness(businessName);
  const plan = displayPlan(planDescription);
  const amount = money(amountCents);
  const every = cadencePhrase(cadence) || 'per invoice';
  const title = isUpdate ? `Update automatic payments to ${amount}` : TITLE;
  const body =
    `I authorize ${biz} to save this card and charge it automatically, without asking me each time, ` +
    `for invoices under my "${plan}" plan (${amount} ${every}). ` +
    `Each charge is made on the invoice's due date, including any unpaid invoice under this plan that comes due after today, ` +
    `and is never more than ${amount} unless I approve a new amount. ` +
    `I'll get an email receipt for every charge. ` +
    `I can turn off automatic payments at any time using the link in any receipt, from my customer portal, or by contacting ${biz}. ` +
    `Turning it off stops future charges. ` +
    `My card details are stored by Stripe, ${biz}'s payment processor; ${biz} sees only the card brand, last four digits and expiry date.`;
  return { title, body, text: `${title}\n\n${body}` };
}

// Stripe Checkout custom_text.submit.message (≤ 1,200 chars, Markdown link
// allowed). Repeats the key terms; Stripe's own reuse-agreement notice stays.
function checkoutSubmitMessage({ businessName, planDescription, amountCents, manageUrl }) {
  const biz = displayBusiness(businessName);
  const plan = displayPlan(planDescription);
  const msg =
    `By paying, you also authorize ${biz} to charge this card for future ${plan} invoices on their due dates ` +
    `(up to ${money(amountCents)} each) until you turn automatic payments off. ` +
    `[Manage automatic payments](${manageUrl})`;
  return msg.slice(0, 1200);
}

// Setup-mode Checkout has no payment, so "By paying" would be wrong there.
function checkoutSetupMessage({ businessName, planDescription, amountCents, manageUrl }) {
  const biz = displayBusiness(businessName);
  const plan = displayPlan(planDescription);
  const msg =
    `By saving this card, you authorize ${biz} to charge it for future ${plan} invoices on their due dates ` +
    `(up to ${money(amountCents)} each) until you turn automatic payments off. ` +
    `[Manage automatic payments](${manageUrl})`;
  return msg.slice(0, 1200);
}

module.exports = {
  CONSENT_VERSION,
  CADENCE_PHRASES,
  cadencePhrase,
  renderConsent,
  checkoutSubmitMessage,
  checkoutSetupMessage,
  TITLE,
};
