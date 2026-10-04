// Pure display helpers shared by the pay view, the portal, the autopay
// emails and the owner status route (Phase 24). No I/O.

const { formatMoney } = require('../overdue.js');

const BRAND_NAMES = {
  visa: 'Visa',
  mastercard: 'Mastercard',
  amex: 'American Express',
  american_express: 'American Express',
  discover: 'Discover',
  diners: 'Diners Club',
  jcb: 'JCB',
  unionpay: 'UnionPay',
  cartes_bancaires: 'Cartes Bancaires',
  eftpos_au: 'eftpos',
  interac: 'Interac',
};

function brandName(brand) {
  const key = String(brand || '').toLowerCase();
  return BRAND_NAMES[key] || 'Card';
}

const LAST4_RE = /^\d{4}$/;

// "Visa ending 4242" (customer-facing), or null without a usable last 4.
function cardLabel(brand, last4) {
  if (!LAST4_RE.test(String(last4 || ''))) return null;
  return `${brandName(brand)} ending ${last4}`;
}

// "Visa ending 4242 (exp 08/27)" for the manage page (spec §2.5).
function cardLabelWithExpiry(brand, last4, expMonth, expYear) {
  const base = cardLabel(brand, last4);
  if (!base) return null;
  const m = Number(expMonth);
  const y = Number(expYear);
  if (!Number.isInteger(m) || m < 1 || m > 12 || !Number.isInteger(y) || y < 2000) return base;
  return `${base} (exp ${String(m).padStart(2, '0')}/${String(y % 100).padStart(2, '0')})`;
}

// Ledger note for an autopay payment (spec §3.3): "Autopay · Visa •••• 4242".
function autopayLedgerNote(brand, last4) {
  return LAST4_RE.test(String(last4 || '')) ? `Autopay · ${brandName(brand)} •••• ${last4}` : 'Autopay';
}

function centsToDollars(cents) {
  return Math.round(Number(cents) || 0) / 100;
}

// Dollars → integer cents, rounding half away from zero at the cent the way
// the device's Decimal amounts do. Non-finite → 0.
function dollarsToCents(dollars) {
  const n = typeof dollars === 'number' ? dollars : parseFloat(String(dollars));
  if (!Number.isFinite(n)) return 0;
  return Math.round(n * 100);
}

function money(cents) {
  return formatMoney(centsToDollars(cents));
}

// Display-safe free text from synced data: collapse whitespace (incl. CR/LF)
// and cap. Never used in a header without the header sanitizers.
function clean(value, max) {
  return String(value == null ? '' : value).replace(/\s+/g, ' ').trim().slice(0, max);
}

module.exports = {
  brandName,
  cardLabel,
  cardLabelWithExpiry,
  autopayLedgerNote,
  centsToDollars,
  dollarsToCents,
  money,
  clean,
};
