// Shared ledger writer for every server-recorded Stripe payment (Phase 24
// spec §4.1, D8). Extracted unchanged from the Connect webhook
// (src/routes/stripe/webhook.js, pre-Phase-24 `recordStripePayment`); the
// characterization suite (tests/stripeWebhookCharacterization.test.cjs) pins
// that the webhook's writes did not change. Callers:
//   - the webhook, for Checkout payments: ledgerId `stripe_<session id>`
//     (TH-9 unchanged), extra { stripeSessionId }
//   - the autopay sweep: ledgerId `stripe_<payment intent id>`,
//     extra { stripePaymentIntentId, channel: 'autopay', note }
//   - later, Phase 18 tap-to-pay and Phase 28 tips (`tipAmount`).
//
// The invoice's `payments` array is the source of truth for what's been paid;
// `paid`/`paidAt` are written alongside it as a best-effort CACHE. The
// ledger union trigger (20260718_invoice_payment_merge.sql) makes this write
// additive against concurrent writers. DEPLOY ORDERING: server-side appends
// must not run before that trigger is applied (spec §9 step 1).
//
// A DELETED invoice (review fix 2026-10-04, spec §13.7): money that arrives
// for it (a pay-page session completed after the owner deleted it, a legacy
// link, an autopay create that had already reached Stripe) is still booked,
// so the ledger matches Stripe, but the row stays deleted: the upsert never
// writes `deleted` (it used to write false, silently resurrecting the row and
// reopening it to the reminder and autopay sweeps). The owner is alerted instead (email + push,
// fire-and-forget), and the result carries invoiceDeleted: true.
//
// Returns { outcome, invoice, userId, invoiceDeleted } where outcome is one of
//   'appended'       — the entry was written (send receipts only on this)
//   'duplicate'      — an entry with this ledger id already exists
//   'not_found'      — the invoice hasn't synced yet (retries won't help)
//   'ownership_skip' — the event's connected account isn't the owner's
//   'zero_amount'    — a non-positive amount; nothing written
// A Supabase error throws (the webhook maps that to a 500 so Stripe retries).

const { amountPaid, isFullyPaid, materializeLegacyLedger } = require('../paymentMath.js');
const { verifyConnectedAccountOwnership } = require('./webhookOwnership.js');
const { alertOwner } = require('../ownerAlert.js');

// Optional keys a caller may add to the ledger entry. Anything else is
// dropped, so a caller can never smuggle `voidedAt` or another amount in.
const EXTRA_KEYS = ['stripeSessionId', 'stripePaymentIntentId', 'channel', 'note', 'tipAmount'];

async function recordStripePayment(env, { invoiceId, connectedAccountId, ledgerId, amount, date, extra = {} }) {
  const supabaseHeaders = {
    Authorization: `Bearer ${env.SUPABASE_SERVICE_ROLE_KEY}`,
    apikey: env.SUPABASE_SERVICE_ROLE_KEY,
  };

  const fetchRes = await fetch(
    `${env.SUPABASE_URL}/rest/v1/invoices?id=eq.${encodeURIComponent(invoiceId)}&select=user_id,data,deleted`,
    { headers: supabaseHeaders }
  );

  if (!fetchRes.ok) {
    throw new Error(`Supabase fetch ${fetchRes.status}: ${await fetchRes.text()}`);
  }

  const rows = await fetchRes.json();
  if (!rows.length) {
    // Invoice hasn't synced to Supabase yet (device was offline when the link
    // was generated). Log and return — retries won't help until it syncs.
    console.warn(`[stripe/record-payment] invoice ${invoiceId} not found in Supabase — skipping`);
    return { outcome: 'not_found', invoice: null, userId: null };
  }

  const { user_id, data } = rows[0];
  const invoiceDeleted = rows[0].deleted === true;

  // Ownership check: the invoice id a Stripe object carries may name an
  // invoice the paying connected account does NOT own (legacy links stamp
  // whatever the app sent). Require the connected account to be the account
  // on record for this invoice's owner, or a payment into an attacker's own
  // account could settle a victim's invoice. A mismatch or missing
  // stripe_accounts row is deliberate, not transient — skip rather than
  // throw. A Supabase error in the lookup still throws → 500 → retry.
  const ownership = await verifyConnectedAccountOwnership({
    supabaseUrl: env.SUPABASE_URL,
    headers: supabaseHeaders,
    userId: user_id,
    eventAccount: connectedAccountId,
  });
  if (!ownership.ok) {
    console.warn(
      `[stripe/record-payment] invoice ${invoiceId}: account ${connectedAccountId} does not match ` +
      `owner's connected account ${ownership.expectedAccountId} (${ownership.reason}) — skipping`
    );
    return { outcome: 'ownership_skip', invoice: null, userId: user_id };
  }

  // Materialize the legacy implied payment (if any) BEFORE appending.
  // Skipping this would silently erase the invoice's originally-recorded
  // amount the moment `payments` goes from absent to non-empty — see the
  // CRITICAL rule on materializeLegacyLedger in utils/invoicePayments.ts. The
  // stored blob is not guaranteed to carry its own `id`, so the id this row
  // was fetched by is used, matching the device's synthesized `legacy_<id>`.
  const existing = materializeLegacyLedger({ ...data, id: invoiceId });

  // Idempotency: a repeated delivery must not append twice. The union
  // trigger would collapse the duplicate id anyway; checking here keeps the
  // write itself clean.
  if (existing.some((p) => p && p.id === ledgerId)) {
    return { outcome: 'duplicate', invoice: { ...data, id: invoiceId }, userId: user_id };
  }

  // Guard: a zero (or missing) amount adds no money but WOULD still flip
  // `payments` from absent to non-empty, which is exactly what kills the
  // legacy fallback for a paid invoice. Refuse to write rather than risk that.
  if (!(amount > 0)) {
    console.warn(`[stripe/record-payment] invoice ${invoiceId}: ${ledgerId} has non-positive amount (${amount}) — skipping write`);
    return { outcome: 'zero_amount', invoice: { ...data, id: invoiceId }, userId: user_id };
  }

  // method 'stripe' is RESERVED for server-created entries (types/models.ts
  // PaymentMethod; the RecordPaymentSheet chips deliberately omit it), so the
  // history UI can tell an auto-reconciled Stripe payment from a card payment
  // the tradesperson keyed in by hand.
  // NOTE: dated from UTC by default. The device records local dates; the
  // server doesn't know the owner's zone. Accepted limitation (spec §10).
  const payment = {
    id: ledgerId,
    amount,
    date: date || new Date().toISOString().split('T')[0],
    method: 'stripe',
  };
  for (const key of EXTRA_KEYS) {
    if (extra[key] !== undefined && extra[key] !== null) payment[key] = extra[key];
  }

  const payments = [...existing, payment];
  const nextData = { ...data, payments };

  // paid/paidAt are a best-effort CACHE, not the source of truth: the trigger
  // may union in entries this function never saw. The device re-derives both
  // on sync, and the reminder cron derives from the ledger.
  const settled = isFullyPaid(nextData);
  nextData.paid = settled;
  if (settled) {
    nextData.paidAt = payment.date;
  } else {
    delete nextData.paidAt;
  }

  console.log(
    `[stripe/record-payment] invoice ${invoiceId}: +$${payment.amount} (${ledgerId}), ` +
    `paid ${amountPaid(nextData)} of ${nextData.amount}`
  );

  const upsertRes = await fetch(`${env.SUPABASE_URL}/rest/v1/invoices`, {
    method: 'POST',
    headers: {
      ...supabaseHeaders,
      'Content-Type': 'application/json',
      Prefer: 'resolution=merge-duplicates',
    },
    body: JSON.stringify({
      id: invoiceId,
      user_id,
      data: nextData,
      updated_at: new Date().toISOString(),
      // No `deleted` key: merge-duplicates updates only the columns sent, so
      // a booking can never flip the flag either way (it used to write
      // false, resurrecting deleted invoices, and a delete landing between
      // the read above and this write was undone).
    }),
  });

  if (!upsertRes.ok) {
    throw new Error(`Supabase upsert ${upsertRes.status}: ${await upsertRes.text()}`);
  }

  if (invoiceDeleted) await alertPaymentOnDeletedInvoice(env, { userId: user_id, invoiceId, data, payment });
  return { outcome: 'appended', invoice: { ...nextData, id: invoiceId }, userId: user_id, invoiceDeleted };
}

// Fire-and-forget: never throws (alertOwner swallows its own failures).
async function alertPaymentOnDeletedInvoice(env, { userId, invoiceId, data, payment }) {
  console.warn(`[stripe/record-payment] invoice ${invoiceId} is deleted; ${payment.id} booked on it and the owner alerted`);
  try {
    const settingsRes = await fetch(
      `${env.SUPABASE_URL}/rest/v1/settings?user_id=eq.${encodeURIComponent(userId)}&select=data`,
      { headers: { Authorization: `Bearer ${env.SUPABASE_SERVICE_ROLE_KEY}`, apikey: env.SUPABASE_SERVICE_ROLE_KEY } }
    );
    const settingsRows = settingsRes.ok ? await settingsRes.json() : [];
    const settings = (settingsRows[0] && settingsRows[0].data) || {};
    const number = String((data && data.number) || invoiceId).replace(/\s+/g, ' ').trim().slice(0, 60);
    const amount = `$${Number(payment.amount).toFixed(2)}`;
    await alertOwner(env, {
      userId,
      settings,
      alert: {
        subject: `Payment received for deleted invoice ${number}`,
        text:
          `A Stripe payment of ${amount} (${payment.id.replace(/^stripe_/, '')}) arrived for invoice ${number}, which was deleted in TradeReady. ` +
          'It has been recorded on the deleted invoice so nothing is lost, but the invoice stays deleted and will not appear in the app. ' +
          'If the payment was not owed, refund it in Stripe; if the invoice should not have been deleted, recreate it and record the payment.',
        pushTitle: 'Payment for a deleted invoice',
        pushBody: `Invoice ${number}: ${amount}`,
      },
      data: { invoiceId },
    });
  } catch (err) {
    console.error(`[stripe/record-payment] deleted-invoice alert for ${invoiceId} failed:`, err.message);
  }
}

module.exports = { recordStripePayment, EXTRA_KEYS };
