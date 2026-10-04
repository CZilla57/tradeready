// Characterization of the Stripe Connect webhook (W/src/routes/stripe/webhook.js)
// as it behaved BEFORE Phase 24 (spec §4.1, §8): written first and run
// against the untouched handler, then kept green through the behavior-neutral
// plumbing refactor. Uses the real Stripe SDK for signature verification
// (generateTestHeaderString + constructEventAsync, no network) and a fake
// Supabase behind global.fetch.

const assert = require('node:assert/strict');
const { before, beforeEach, afterEach, describe, test } = require('node:test');
const Stripe = require('stripe');
const { fakeC, installFetch, fakeSupabase, jsonRes } = require('./helpers/fakes.cjs');

const SECRET = 'whsec_characterization';
const ACCOUNT = 'acct_owner1';
const USER = '11111111-2222-4333-8444-555555555555';
const TODAY = new Date().toISOString().split('T')[0];

let stripeWebhookHandler;
before(async () => {
  ({ stripeWebhookHandler } = await import('../src/routes/stripe/webhook.js'));
});

const signer = new Stripe('sk_test_signer', { apiVersion: '2023-10-16' });

function eventBody({ type = 'checkout.session.completed', account = ACCOUNT, session = {} } = {}) {
  return JSON.stringify({
    id: 'evt_1',
    object: 'event',
    type,
    account,
    data: {
      object: {
        id: 'cs_test_1',
        object: 'checkout.session',
        mode: 'payment',
        payment_status: 'paid',
        status: 'complete',
        amount_total: 12050,
        metadata: { invoiceId: 'inv_1' },
        ...session,
      },
    },
  });
}

function signedC(payload, { secret = SECRET } = {}) {
  const header = signer.webhooks.generateTestHeaderString({ payload, secret });
  return fakeC({
    method: 'POST',
    rawBody: payload,
    headers: { 'stripe-signature': header },
    env: { STRIPE_CONNECT_WEBHOOK_SECRET: SECRET },
  });
}

function invoiceRow(data = {}) {
  return { id: 'inv_1', user_id: USER, deleted: false, data: { number: 'INV-1', amount: 120.5, customer: 'Pat', ...data } };
}

let net;
let db;
function setup({ invoices = [invoiceRow()], accounts = [{ user_id: USER, stripe_account_id: ACCOUNT }], failOn } = {}) {
  db = fakeSupabase({ invoices, stripe_accounts: accounts }, { failOn });
  net = installFetch((call) => db.handle(call) || null);
}
afterEach(() => net && net.restore());

const upserts = () => net.calls.filter((c) => c.method === 'POST' && c.u.pathname === '/rest/v1/invoices');

describe('webhook characterization (pre-Phase-24 behavior)', () => {
  test('non-POST → 405', async () => {
    setup();
    const res = await stripeWebhookHandler(fakeC({ method: 'GET' }));
    assert.deepEqual([res.status, res.body], [405, { error: 'Method not allowed' }]);
  });

  test('a bad signature → 400 and nothing is read or written', async () => {
    setup();
    const payload = eventBody();
    const res = await stripeWebhookHandler(signedC(payload, { secret: 'whsec_wrong' }));
    assert.deepEqual([res.status, res.body], [400, { error: 'Webhook signature verification failed.' }]);
    assert.equal(net.calls.length, 0);
  });

  test('other event types are acknowledged and skipped', async () => {
    setup();
    const res = await stripeWebhookHandler(signedC(eventBody({ type: 'payment_intent.succeeded' })));
    assert.deepEqual([res.status, res.body], [200, { received: true, skipped: true }]);
    assert.equal(net.calls.length, 0);
  });

  test('an unpaid session is skipped', async () => {
    setup();
    const res = await stripeWebhookHandler(signedC(eventBody({ session: { payment_status: 'unpaid' } })));
    assert.deepEqual([res.status, res.body], [200, { received: true, skipped: true }]);
    assert.equal(net.calls.length, 0);
  });

  test('a session without metadata.invoiceId is skipped', async () => {
    setup();
    const res = await stripeWebhookHandler(signedC(eventBody({ session: { metadata: {} } })));
    assert.deepEqual([res.status, res.body], [200, { received: true, skipped: true }]);
    assert.equal(net.calls.length, 0);
  });

  test('an unsynced invoice is acknowledged without a write', async () => {
    setup({ invoices: [] });
    const res = await stripeWebhookHandler(signedC(eventBody()));
    assert.deepEqual([res.status, res.body], [200, { received: true }]);
    assert.equal(upserts().length, 0);
  });

  test('ownership: a different connected account is skipped with a 200', async () => {
    setup({ accounts: [{ user_id: USER, stripe_account_id: 'acct_someone_else' }] });
    const res = await stripeWebhookHandler(signedC(eventBody()));
    assert.deepEqual([res.status, res.body], [200, { received: true, skipped: true }]);
    assert.equal(upserts().length, 0);
  });

  test('ownership: an owner with no stripe_accounts row is skipped', async () => {
    setup({ accounts: [] });
    const res = await stripeWebhookHandler(signedC(eventBody()));
    assert.deepEqual([res.status, res.body], [200, { received: true, skipped: true }]);
    assert.equal(upserts().length, 0);
  });

  test('a full payment appends one stripe_<session> entry and marks paid', async () => {
    setup();
    const res = await stripeWebhookHandler(signedC(eventBody()));
    assert.deepEqual([res.status, res.body], [200, { received: true }]);
    const [up] = upserts();
    assert.equal(up.headers.prefer, 'resolution=merge-duplicates');
    assert.deepEqual(Object.keys(up.json).sort(), ['data', 'deleted', 'id', 'updated_at', 'user_id']);
    assert.equal(up.json.id, 'inv_1');
    assert.equal(up.json.user_id, USER);
    assert.equal(up.json.deleted, false);
    assert.deepEqual(up.json.data.payments, [
      { id: 'stripe_cs_test_1', amount: 120.5, date: TODAY, method: 'stripe', stripeSessionId: 'cs_test_1' },
    ]);
    assert.equal(up.json.data.paid, true);
    assert.equal(up.json.data.paidAt, TODAY);
    assert.equal(up.json.data.number, 'INV-1');
  });

  test('a partial payment leaves paid false and drops a stale paidAt', async () => {
    setup({ invoices: [invoiceRow({ amount: 500, paidAt: '2026-01-01' })] });
    await stripeWebhookHandler(signedC(eventBody()));
    const [up] = upserts();
    assert.equal(up.json.data.paid, false);
    assert.equal('paidAt' in up.json.data, false);
  });

  test('a redelivery with the same session id does not append twice', async () => {
    setup({
      invoices: [invoiceRow({ payments: [{ id: 'stripe_cs_test_1', amount: 120.5, date: '2026-10-01', method: 'stripe', stripeSessionId: 'cs_test_1' }] })],
    });
    const res = await stripeWebhookHandler(signedC(eventBody()));
    assert.deepEqual([res.status, res.body], [200, { received: true }]);
    assert.equal(upserts().length, 0);
  });

  test('a legacy paid invoice is materialized before the append', async () => {
    setup({ invoices: [invoiceRow({ amount: 300, paid: true, paidAt: '2026-09-01' })] });
    await stripeWebhookHandler(signedC(eventBody()));
    const [up] = upserts();
    assert.deepEqual(up.json.data.payments.map((p) => p.id), ['legacy_inv_1', 'stripe_cs_test_1']);
    assert.deepEqual(up.json.data.payments[0], {
      id: 'legacy_inv_1', amount: 300, date: '2026-09-01', method: 'other', note: 'Recorded before payment history was itemised',
    });
  });

  test('a zero amount_total writes nothing', async () => {
    setup();
    const res = await stripeWebhookHandler(signedC(eventBody({ session: { amount_total: 0 } })));
    assert.deepEqual([res.status, res.body], [200, { received: true }]);
    assert.equal(upserts().length, 0);
  });

  test('a Supabase read error → 500 so Stripe retries', async () => {
    setup({ failOn: { 'GET invoices': 503 } });
    const res = await stripeWebhookHandler(signedC(eventBody()));
    assert.deepEqual([res.status, res.body], [500, { error: 'Database error' }]);
  });

  test('a Supabase upsert error → 500 so Stripe retries', async () => {
    setup({ failOn: { 'POST invoices': 500 } });
    const res = await stripeWebhookHandler(signedC(eventBody()));
    assert.deepEqual([res.status, res.body], [500, { error: 'Database error' }]);
  });
});
