// Tap to Pay on iPhone — server side (Phase 18 spec §2.1). Pure-ish services
// the three /api/terminal/* routes call. Every Stripe call targets the OWNER's
// connected account (direct charges, same model as payment links) through the
// `stripeAccount` option; the account id always comes from stripe_accounts,
// never from the client.
//
// MONEY RULES (spec §2.1, §6)
//   - The request `amount` is DOLLARS (payment-link and ledger parity); it
//     must be an exact whole number of cents. All comparison and the Stripe
//     amount are integer cents.
//   - It is validated against the invoice's live balance (paymentMath
//     balanceDue, legacy fallback included) on the server, and the invoice
//     must belong to the verified user.
//   - Metadata is server-authored; the client never supplies it.

const { balanceDue } = require('../paymentMath.js');

// Stripe's USD ceiling for one charge ($999,999.99) and floor ($0.50). The
// spec's currency assumption is USD only (`currency: 'usd'` below), so one
// floor in cents applies. Checked here so the owner gets a clear
// `below_minimum` instead of Stripe's rejection surfacing as a vague
// `stripe_rejected`.
const MAX_INTENT_CENTS = 99_999_999;
const MIN_INTENT_CENTS = 50;
const LOCATION_TAG = 'default';
const MAX_LOCATION_PAGES = 5;

const OPERATION_ID_RE = /^[A-Za-z0-9_-]{8,64}$/;
const INVOICE_ID_RE = /^[A-Za-z0-9_-]{1,128}$/;
const LOCAL_DATE_RE = /^(\d{4})-(\d{2})-(\d{2})$/;
const STATE_RE = /^[A-Z]{2}$/;
const ZIP_RE = /^\d{5}(-\d{4})?$/;

const fail = (status, code, error, extra = {}) => ({ status, body: { error, code, ...extra } });

// --- connection token ------------------------------------------------------

async function createConnectionToken({ stripe, stripeAccountId }) {
  const token = await stripe.terminal.connectionTokens.create({}, { stripeAccount: stripeAccountId });
  return { status: 200, body: { secret: token.secret } };
}

// --- location --------------------------------------------------------------

function str(v, max) {
  if (typeof v !== 'string') return null;
  const t = v.trim();
  return t && t.length <= max ? t : null;
}

// → { address } (Stripe's shape) or { error }
function validateAddress(raw) {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return { error: 'An address is required.' };
  const line1 = str(raw.line1, 200);
  const city = str(raw.city, 100);
  const state = str(typeof raw.state === 'string' ? raw.state.toUpperCase() : raw.state, 2);
  const postal = str(raw.postal_code, 10);
  if (!line1) return { error: 'Street address is required.' };
  if (!city) return { error: 'City is required.' };
  if (!state || !STATE_RE.test(state)) return { error: 'State must be a two-letter code.' };
  if (!postal || !ZIP_RE.test(postal)) return { error: 'ZIP code must be 5 digits (or ZIP+4).' };
  if (raw.country !== undefined && raw.country !== 'US') return { error: 'Only US addresses are supported.' };
  const address = { line1, city, state, postal_code: postal, country: 'US' };
  if (raw.line2 !== undefined && raw.line2 !== null && raw.line2 !== '') {
    const line2 = str(raw.line2, 200);
    if (!line2) return { error: 'Address line 2 is invalid.' };
    address.line2 = line2;
  }
  return { address };
}

function publicAddress(a) {
  if (!a) return null;
  return {
    line1: a.line1 || null,
    line2: a.line2 || null,
    city: a.city || null,
    state: a.state || null,
    postal_code: a.postal_code || null,
    country: a.country || null,
  };
}

// The connected account's default Location, picked by metadata. Stripe is the
// authority (no table, spec D8).
async function findDefaultLocation(stripe, stripeAccountId) {
  let startingAfter;
  for (let page = 0; page < MAX_LOCATION_PAGES; page += 1) {
    const params = { limit: 100, ...(startingAfter ? { starting_after: startingAfter } : {}) };
    const res = await stripe.terminal.locations.list(params, { stripeAccount: stripeAccountId });
    const list = (res && res.data) || [];
    const hit = list.find((l) => l && l.metadata && l.metadata.tradeready === LOCATION_TAG);
    if (hit) return hit;
    if (!res.has_more || !list.length) return null;
    startingAfter = list[list.length - 1].id;
  }
  return null;
}

async function locationAction({ stripe, stripeAccountId, body }) {
  const action = body && body.action;
  if (action !== 'status' && action !== 'ensure') {
    return fail(400, 'invalid_request', 'action must be "status" or "ensure".');
  }
  const existing = await findDefaultLocation(stripe, stripeAccountId);
  if (existing) {
    return { status: 200, body: { locationId: existing.id, address: publicAddress(existing.address) } };
  }
  if (action === 'status') return { status: 200, body: { locationId: null, address: null } };

  const displayName = str(body.displayName, 100);
  if (!displayName) return fail(400, 'invalid_request', 'displayName is required.');
  const { address, error } = validateAddress(body.address);
  if (error) return fail(400, 'invalid_address', error);

  const created = await stripe.terminal.locations.create(
    { display_name: displayName, address, metadata: { tradeready: LOCATION_TAG } },
    { stripeAccount: stripeAccountId, idempotencyKey: `ttp_loc_${stripeAccountId}` }
  );
  return { status: 200, body: { locationId: created.id, address: publicAddress(created.address || address) } };
}

// --- payment intent --------------------------------------------------------

// Whole-cent conversion of a client dollar amount; null when not exact.
function dollarsToCents(amount) {
  if (typeof amount !== 'number' || !Number.isFinite(amount)) return null;
  const cents = Math.round(amount * 100);
  if (Math.abs(amount * 100 - cents) > 1e-6) return null;
  return cents;
}

// The device's local day must be a real date within one day of the server's
// UTC date (covers every timezone, rejects arbitrary backdating).
function localDateOk(localDate, nowMs) {
  const m = typeof localDate === 'string' ? LOCAL_DATE_RE.exec(localDate) : null;
  if (!m) return false;
  const [y, mo, d] = [Number(m[1]), Number(m[2]), Number(m[3])];
  const ms = Date.UTC(y, mo - 1, d);
  const back = new Date(ms);
  if (back.getUTCFullYear() !== y || back.getUTCMonth() !== mo - 1 || back.getUTCDate() !== d) return false;
  const now = new Date(nowMs);
  const todayMs = Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate());
  return Math.abs(ms - todayMs) <= 86_400_000;
}

// By id AND user_id (spec §2.1 step 1): another owner's invoice and a missing
// one are the same empty result, so the route cannot be used to probe which
// (guessable) invoice ids exist.
async function fetchInvoiceRow(env, invoiceId, userId) {
  const res = await fetch(
    `${env.SUPABASE_URL}/rest/v1/invoices?id=eq.${encodeURIComponent(invoiceId)}&user_id=eq.${encodeURIComponent(userId)}&select=user_id,deleted,data`,
    { headers: { Authorization: `Bearer ${env.SUPABASE_SERVICE_ROLE_KEY}`, apikey: env.SUPABASE_SERVICE_ROLE_KEY } }
  );
  if (!res.ok) throw new Error(`Supabase invoice lookup ${res.status}`);
  const rows = await res.json();
  return rows.length ? rows[0] : null;
}

// A short single-line label only (it lands in the owner's own Stripe
// description). Anything else is ignored rather than rejected.
function cleanInvoiceNumber(value) {
  if (typeof value !== 'string') return null;
  const t = value.trim();
  // eslint-disable-next-line no-control-regex
  return t && t.length <= 64 && !/[\u0000-\u001f\u007f]/.test(t) ? t : null;
}

async function createTerminalPaymentIntent(env, { stripe, userId, stripeAccountId, body, nowMs = Date.now() }) {
  const { invoiceId, amount, localDate, operationId, invoiceNumber } = body || {};
  if (typeof invoiceId !== 'string' || !INVOICE_ID_RE.test(invoiceId)) return fail(400, 'invalid_request', 'Invalid invoiceId.');
  if (typeof operationId !== 'string' || !OPERATION_ID_RE.test(operationId)) return fail(400, 'invalid_request', 'Invalid operationId.');
  const cents = dollarsToCents(amount);
  if (cents === null) return fail(400, 'invalid_amount', 'Amount must be a dollar amount in whole cents.');
  if (cents <= 0) return fail(400, 'invalid_amount', 'Amount must be greater than 0.');
  if (cents > MAX_INTENT_CENTS) return fail(400, 'invalid_amount', 'Amount is too large.');
  if (cents < MIN_INTENT_CENTS) {
    return fail(400, 'below_minimum', 'That amount is too small to take by card.', { minimum: MIN_INTENT_CENTS / 100 });
  }
  if (!localDateOk(localDate, nowMs)) return fail(400, 'invalid_date', 'localDate must be today\'s date (YYYY-MM-DD).');

  const row = await fetchInvoiceRow(env, invoiceId, userId);
  // Missing and not-yours are the same answer (the query filtered by owner).
  if (!row) {
    return fail(422, 'not_synced', 'This invoice hasn\'t synced yet. Open the app while online, wait for it to sync, and try again.');
  }
  // The caller's OWN deleted invoice: nothing to leak, so say so plainly.
  if (row.deleted) return fail(404, 'not_found', 'Invoice not found.');

  const invoice = { ...row.data, id: invoiceId };
  const balanceCents = Math.round(balanceDue(invoice) * 100);
  if (cents > balanceCents) {
    return fail(400, 'amount_exceeds_balance', 'Amount is more than the invoice balance.', { balance: balanceCents / 100 });
  }

  // The description is part of Stripe's idempotency parameters, so it must be
  // identical on every retry of one operation. The device freezes the invoice
  // number it shows with the operation and sends it back each time (an edit to
  // the number between retries would otherwise 409 every retry). Absent or
  // unusable: fall back to the server's copy.
  const number = cleanInvoiceNumber(invoiceNumber) || invoice.number;
  const intent = await stripe.paymentIntents.create(
    {
      amount: cents,
      currency: 'usd',
      payment_method_types: ['card_present'],
      capture_method: 'automatic',
      description: number ? `Invoice ${number}` : 'Invoice payment',
      metadata: { invoiceId, userId, localDate, source: 'tap_to_pay' },
    },
    { stripeAccount: stripeAccountId, idempotencyKey: `ttp_${operationId}` }
  );
  return {
    status: 200,
    body: { paymentIntentId: intent.id, clientSecret: intent.client_secret, amount: intent.amount / 100, amountCents: intent.amount },
  };
}

module.exports = {
  createConnectionToken,
  locationAction,
  createTerminalPaymentIntent,
  validateAddress,
  dollarsToCents,
  localDateOk,
  MAX_INTENT_CENTS,
  MIN_INTENT_CENTS,
};
