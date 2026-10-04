// create-payment-link (W/src/routes/createPaymentLink.js).
//
// The "characterization" block pins the pre-Phase-24 behavior (spec §4.1):
// it ran green against the untouched route before any change. Phase 24
// (§4.3) then changes exactly two things on the legacy path, each pinned
// below: `restrictions.completed_sessions.limit = 1` on the Payment Link and
// the invoice-ownership 404. The pay-page path (PAY_LINK_SIGNING_SECRET set)
// makes no Stripe call at all.
//
// The real Stripe SDK runs over a fake global.fetch, so the exact form
// bodies and the Stripe-Account header sent to api.stripe.com are asserted.

const assert = require('node:assert/strict');
const { before, afterEach, describe, test } = require('node:test');
const { fakeC, installFetch, fakeSupabase, jsonRes } = require('./helpers/fakes.cjs');

const USER = '11111111-2222-4333-8444-555555555555';
const OTHER = '99999999-2222-4333-8444-555555555555';
const ACCOUNT = 'acct_owner1';

let createPaymentLinkHandler;
before(async () => {
  ({ createPaymentLinkHandler } = await import('../src/routes/createPaymentLink.js'));
});

let net;
let db;
let stripeFail = false;
function setup({ accounts = [{ user_id: USER, stripe_account_id: ACCOUNT }], invoices = [], authOk = true } = {}) {
  db = fakeSupabase({ stripe_accounts: accounts, invoices });
  net = installFetch((call) => {
    if (call.u.pathname === '/auth/v1/user') return authOk ? jsonRes({ id: USER }) : jsonRes({ msg: 'bad jwt' }, 401);
    if (call.u.origin === 'https://api.stripe.com') {
      if (stripeFail) return jsonRes({ error: { type: 'invalid_request_error', message: 'nope' } }, 400);
      const p = call.u.pathname;
      if (p === '/v1/products') return jsonRes({ id: 'prod_1', object: 'product' });
      if (p === '/v1/prices') return jsonRes({ id: 'price_1', object: 'price' });
      if (p === '/v1/payment_links') return jsonRes({ id: 'plink_1', object: 'payment_link', url: 'https://buy.stripe.com/test_abc' });
    }
    return db.handle(call);
  });
}
afterEach(() => {
  stripeFail = false;
  if (net) net.restore();
});

function call(body = { amount: 120.5, invoiceNumber: 'INV-1', description: 'Spring tune-up', invoiceId: 'inv_1' }, { env = {}, headers = { authorization: 'Bearer user-jwt' }, method = 'POST' } = {}) {
  return createPaymentLinkHandler(fakeC({ method, body, headers, env }));
}

const stripeCalls = () => net.calls.filter((c) => c.u.origin === 'https://api.stripe.com');

describe('create-payment-link characterization (legacy Payment Link path)', () => {
  test('OPTIONS → 200 with app CORS; GET → 405', async () => {
    setup();
    const pre = await call(undefined, { method: 'OPTIONS' });
    assert.equal(pre.status, 200);
    assert.equal(pre.headers['Access-Control-Allow-Methods'], 'POST, OPTIONS');
    const get = await call(undefined, { method: 'GET' });
    assert.deepEqual([get.status, get.body], [405, { error: 'Method not allowed' }]);
  });

  test('missing server config → 500', async () => {
    setup();
    const res = await call(undefined, { env: { STRIPE_SECRET_KEY: '' } });
    assert.equal(res.status, 500);
  });

  test('no bearer → 401; a rejected JWT → 401', async () => {
    setup();
    assert.equal((await call(undefined, { headers: {} })).status, 401);
    setup({ authOk: false });
    const res = await call();
    assert.deepEqual([res.status, res.body], [401, { error: 'Invalid or expired session. Please sign in again.' }]);
  });

  test('not connected to Stripe → 422', async () => {
    setup({ accounts: [] });
    const res = await call();
    assert.equal(res.status, 422);
    assert.match(res.body.error, /No Stripe account connected/);
  });

  test('amount must be > 0 → 400', async () => {
    setup();
    for (const amount of [0, -5, undefined]) {
      const res = await call({ amount, invoiceId: 'inv_1' });
      assert.deepEqual([res.status, res.body], [400, { error: 'Amount must be greater than 0' }]);
    }
  });

  test('mints Product → Price → Payment Link on the connected account', async () => {
    setup();
    const res = await call();
    assert.deepEqual([res.status, res.body], [200, { url: 'https://buy.stripe.com/test_abc' }]);
    const [prod, price, link] = stripeCalls();
    for (const c of [prod, price, link]) {
      assert.equal(c.method, 'POST');
      assert.equal(c.headers['stripe-account'], ACCOUNT);
      assert.equal(c.headers['stripe-version'], '2023-10-16');
    }
    assert.equal(prod.u.pathname, '/v1/products');
    assert.deepEqual(prod.json, { name: 'Invoice INV-1', description: 'Spring tune-up' });
    assert.equal(price.u.pathname, '/v1/prices');
    assert.deepEqual(price.json, { currency: 'usd', unit_amount: '12050', product: 'prod_1' });
    assert.equal(link.u.pathname, '/v1/payment_links');
    assert.equal(link.json['line_items[0][price]'], 'price_1');
    assert.equal(link.json['line_items[0][quantity]'], '1');
    assert.equal(link.json['after_completion[type]'], 'hosted_confirmation');
    assert.equal(link.json['after_completion[hosted_confirmation][custom_message]'], 'Payment received. Thank you for your business!');
    assert.equal(link.json['metadata[invoiceId]'], 'inv_1');
  });

  test('no invoice number → generic product name; no invoiceId → no metadata', async () => {
    setup();
    await call({ amount: 10 });
    const [prod, , link] = stripeCalls();
    assert.deepEqual(prod.json, { name: 'Invoice Payment' });
    assert.equal(link.json['metadata[invoiceId]'], undefined);
  });

  test('a Stripe error → 500 with the generic message', async () => {
    setup();
    stripeFail = true;
    const res = await call();
    assert.deepEqual([res.status, res.body], [500, { error: 'Could not create payment link. Please try again.' }]);
  });
});

describe('create-payment-link Phase 24 changes (§4.3)', () => {
  test('legacy path: the Payment Link can be completed only once', async () => {
    setup();
    await call();
    const link = stripeCalls().find((c) => c.u.pathname === '/v1/payment_links');
    assert.equal(link.json['restrictions[completed_sessions][limit]'], '1');
  });

  test("another owner's invoice → 404 and no Stripe call", async () => {
    setup({ invoices: [{ id: 'inv_1', user_id: OTHER, deleted: false, data: { amount: 100 } }] });
    const res = await call();
    assert.deepEqual([res.status, res.body], [404, { error: 'Invoice not found.' }]);
    assert.equal(stripeCalls().length, 0);
  });

  test('an unsynced invoice (no row yet) still mints', async () => {
    setup({ invoices: [] });
    const res = await call();
    assert.equal(res.status, 200);
  });

  test('pay-page path: an HMAC URL, no Stripe call, amount in cents', async () => {
    setup({ invoices: [{ id: 'inv_1', user_id: USER, deleted: false, data: { amount: 241 } }] });
    const secret = 'p'.repeat(40);
    const res = await call({ amount: 120.5, invoiceNumber: 'INV-1', invoiceId: 'inv_1' }, { env: { PAY_LINK_SIGNING_SECRET: secret } });
    assert.equal(res.status, 200);
    assert.deepEqual(Object.keys(res.body), ['url']);
    const url = new URL(res.body.url);
    assert.equal(`${url.origin}${url.pathname}`, 'https://gettradereadyapp.com/pay.html');
    assert.equal(url.hash, '');
    const token = url.searchParams.get('t');
    const { verifyPayToken } = require('../lib/pay/payToken.js');
    const v = verifyPayToken(secret, token, { expectKind: 'p' });
    assert.equal(v.ok, true);
    // A partial ask (a deposit of $120.50 on a $241 balance) binds the
    // mint-time balance too, so it stops asking once any payment lands.
    assert.deepEqual(v.payload, { v: 1, u: USER, i: 'inv_1', a: 12050, b: 24100 });
    assert.equal(stripeCalls().length, 0);
  });

  test('pay-page path: a full-balance link (or an unsynced invoice) carries no mint balance', async () => {
    const { verifyPayToken } = require('../lib/pay/payToken.js');
    const secret = 'p'.repeat(40);
    setup({ invoices: [{ id: 'inv_1', user_id: USER, deleted: false, data: { amount: 120.5 } }] });
    const full = await call({ amount: 120.5, invoiceId: 'inv_1' }, { env: { PAY_LINK_SIGNING_SECRET: secret } });
    assert.deepEqual(verifyPayToken(secret, new URL(full.body.url).searchParams.get('t')).payload, { v: 1, u: USER, i: 'inv_1', a: 12050 });
    net.restore();
    setup({ invoices: [] });
    const unsynced = await call({ amount: 50, invoiceId: 'inv_new' }, { env: { PAY_LINK_SIGNING_SECRET: secret } });
    assert.deepEqual(verifyPayToken(secret, new URL(unsynced.body.url).searchParams.get('t')).payload, { v: 1, u: USER, i: 'inv_new', a: 5000 });
  });

  test('pay-page path honors PAY_PUBLIC_BASE and needs an invoiceId', async () => {
    setup();
    const secret = 'p'.repeat(40);
    const res = await call({ amount: 50, invoiceId: 'inv_9' }, { env: { PAY_LINK_SIGNING_SECRET: secret, PAY_PUBLIC_BASE: 'https://example.test/pay' } });
    assert.match(res.body.url, /^https:\/\/example\.test\/pay\?t=p\./);
    const missing = await call({ amount: 50 }, { env: { PAY_LINK_SIGNING_SECRET: secret } });
    assert.deepEqual([missing.status, missing.body], [400, { error: 'invoiceId is required.' }]);
  });

  test('pay-page path still requires a connected account', async () => {
    setup({ accounts: [] });
    const res = await call(undefined, { env: { PAY_LINK_SIGNING_SECRET: 'p'.repeat(40) } });
    assert.equal(res.status, 422);
  });
});
