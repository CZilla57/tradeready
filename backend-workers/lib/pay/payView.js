// Pure assembly of GET /api/pay/view responses (Phase 24 spec §4.4). The
// shapes here are the security boundary for an anonymous caller holding a
// token: every object is built key-by-key (no spreads of stored rows), and
// none ever carries the customer's name, email or address, Stripe ids, or
// any other invoice. Exact keys are pinned by tests/payView.test.cjs.

const { centsToDollars, clean, cardLabel, cardLabelWithExpiry, brandName } = require('../autopay/format.js');
const { cadencePhrase, renderConsent, CONSENT_VERSION } = require('../autopay/consentText.js');

const DATE_RE = /^\d{4}-\d{2}-\d{2}$/;

function dateOrNull(v) {
  return typeof v === 'string' && DATE_RE.test(v) ? v : null;
}

// Most recent live payment date, for invoices whose cached paidAt is absent.
function lastPaymentDate(invoice) {
  const dates = (Array.isArray(invoice.payments) ? invoice.payments : [])
    .filter((p) => p && !p.voidedAt && DATE_RE.test(String(p.date || '')))
    .map((p) => p.date)
    .sort();
  return dates.length ? dates[dates.length - 1] : null;
}

function offerBlock({ businessName, planRow, offer }) {
  if (!offer) return null;
  const consent = renderConsent({
    businessName,
    planDescription: planRow.data.description,
    amountCents: offer.amountCents,
    cadence: planRow.data.cadence,
    isUpdate: offer.isUpdate,
  });
  return {
    planDescription: clean(planRow.data.description, 200),
    amount: centsToDollars(offer.amountCents),
    cadence: cadencePhrase(planRow.data.cadence) || '',
    consentText: consent.text,
    consentVersion: CONSENT_VERSION,
    isUpdate: !!offer.isUpdate,
  };
}

function activeBlock(enrollment) {
  if (!enrollment) return null;
  return { card: cardLabel(enrollment.card_brand, enrollment.card_last4) || 'Saved card' };
}

// `receipt` comes from receiptFromSession below (null without a matching
// session).
function invoiceView({ businessName, invoice, paid, balanceCents, depositCents, planRow, offer, activeEnrollment, receipt }) {
  const autopayOffer = paid ? null : offerBlock({ businessName, planRow, offer });
  const active = activeBlock(activeEnrollment);
  return {
    kind: 'invoice',
    businessName: clean(businessName, 120),
    invoiceNumber: clean(invoice.number, 60),
    description: clean(invoice.desc, 300),
    amountDue: paid ? 0 : centsToDollars(balanceCents),
    depositRequested: !paid && depositCents ? centsToDollars(depositCents) : null,
    due: dateOrNull(invoice.due),
    paid: !!paid,
    paidAt: paid ? dateOrNull(invoice.paidAt) || lastPaymentDate(invoice) : null,
    autopay: autopayOffer || active ? { offer: autopayOffer, active } : null,
    receipt: receipt || null,
  };
}

// Checkout Session → receipt block, ONLY when the session belongs to this
// invoice (metadata match); anything else is null so a session id from
// another invoice reveals nothing.
function receiptFromSession(session, invoiceId) {
  if (!session || !session.metadata || session.metadata.invoiceId !== invoiceId || session.mode !== 'payment') return null;
  if (session.status !== 'complete') return null;
  const charge = session.payment_intent && typeof session.payment_intent === 'object' ? session.payment_intent.latest_charge : null;
  const card = charge && typeof charge === 'object' && charge.payment_method_details ? charge.payment_method_details.card : null;
  const total = centsToDollars(session.amount_total);
  return {
    status: session.payment_status === 'paid' ? 'paid' : 'processing',
    amountPaid: total,
    total,
    cardBrand: card ? brandName(card.brand) : null,
    last4: card && /^\d{4}$/.test(String(card.last4 || '')) ? card.last4 : null,
    autopay: !!session.metadata.tr_enrollment,
  };
}

function setupView({ businessName, planRow, amountCents, isUpdate }) {
  const consent = renderConsent({
    businessName,
    planDescription: planRow.data.description,
    amountCents,
    cadence: planRow.data.cadence,
    isUpdate,
  });
  return {
    kind: 'setup',
    businessName: clean(businessName, 120),
    planDescription: clean(planRow.data.description, 200),
    amount: centsToDollars(amountCents),
    cadence: cadencePhrase(planRow.data.cadence) || '',
    consentText: consent.text,
    consentVersion: CONSENT_VERSION,
  };
}

const MANAGE_STATUS = { active: 'on', pending: 'pending', revoked: 'off', replaced: 'off' };

function manageView({ businessName, planRow, enrollment, setupUrl }) {
  const status = MANAGE_STATUS[enrollment.status] || 'off';
  return {
    kind: 'manage',
    businessName: clean(businessName, 120),
    planDescription: clean(planRow && planRow.data ? planRow.data.description : '', 200),
    status,
    card: status === 'off' ? null : cardLabelWithExpiry(enrollment.card_brand, enrollment.card_last4, enrollment.card_exp_month, enrollment.card_exp_year),
    canTurnOff: status === 'on',
    setupUrl: setupUrl || null,
  };
}

module.exports = { invoiceView, receiptFromSession, setupView, manageView, lastPaymentDate };
