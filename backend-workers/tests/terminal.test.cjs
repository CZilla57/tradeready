// Tap to Pay on iPhone, Worker slice (Phase 18 spec §2, §9): the three
// /api/terminal/* owner routes, the webhook's payment_intent.succeeded branch,
// and the additive connect-status fields. A stubbed Stripe client (no network)
// and the in-memory Supabase world from the Phase 24 tests.

const assert = require('node:assert/strict');
const { before, afterEach, describe, test } = require('node:test');
const { fakeStripe, fakeC, invalidRequest, stripeError, installFetch, jsonRes } = require('./helpers/fakes.cjs');
const W = require('./helpers/autopayWorld.cjs');

const { USER, OTHER_USER, ACCOUNT, ENV } = W;
const AUTH = { authorization: 'Bearer user-jwt' };
const NOW_MS = Date.UTC(2026, 9, 14, 3, 30); // 2026-10-14 03:30 UTC (still 2026-10-13 in Phoenix)
const TODAY = '2026-10-14';
const ADDRESS = { line1: '1 Main St', line2: 'Suite 2', city: 'Phoenix', state: 'AZ', postal_code: '85001', country: 'US' };

let createConnectionTokenHandler;
let createLocationHandler;
let createPaymentIntentHandler;
let createStripeWebhookHandler;
let connectStatusHandler;
let appWorker;
before(async () => {
  ({ createConnectionTokenHandler, createLocationHandler, createPaymentIntentHandler } = await import('../src/routes/terminal.js'));
  ({ createStripeWebhookHandler } = await import('../src/routes/stripe/webhook.js'));
  ({ connectStatusHandler } = await import('../src/routes/stripe/connectStatus.js'));
  ({ default: appWorker } = await import('../src/index.js'));
});

let w;
afterEach(() => w && w.restore());

// fakeStripe has no `terminal` resource; add a logged one.
function stripeWith(handlers = {}) {
  const stripe = fakeStripe({ ...handlers });
  const log = (key, h) => async (...args) => {
    stripe.calls.push({ key, args });
    if (!h) throw new Error(`unexpected stripe call ${key}`);
    return h(...args);
  };
  stripe.terminal = {
    connectionTokens: { create: log('terminal.connectionTokens.create', handlers['terminal.connectionTokens.create']) },
    locations: {
      list: log('terminal.locations.list', handlers['terminal.locations.list']),
      create: log('terminal.locations.create', handlers['terminal.locations.create']),
    },
  };
  return stripe;
}

const post = (handler, body, { headers = AUTH, env = ENV } = {}) => handler(fakeC({ method: 'POST', body, headers, env }));

describe('POST /api/terminal/connection-token', () => {
  const stripe = () => stripeWith({ 'terminal.connectionTokens.create': async () => ({ secret: 'pst_test_abc', object: 'terminal.connection_token' }) });

  test('mints on the OWNER\'s connected account and returns only { secret }', async () => {
    w = W.world();
    const s = stripe();
    const res = await post(createConnectionTokenHandler({ stripeFactory: () => s }), {});
    assert.deepEqual([res.status, res.body], [200, { secret: 'pst_test_abc' }]);
    assert.deepEqual(s.callsTo('terminal.connectionTokens.create').map((c) => c.args), [[{}, { stripeAccount: ACCOUNT }]]);
  });

  test('a body-supplied account id is ignored', async () => {
    w = W.world();
    const s = stripe();
    await post(createConnectionTokenHandler({ stripeFactory: () => s }), { stripeAccount: 'acct_victim', account: 'acct_victim' });
    assert.equal(s.callsTo('terminal.connectionTokens.create')[0].args[1].stripeAccount, ACCOUNT);
  });

  test('401 without or with a bad JWT; no Stripe call', async () => {
    w = W.world();
    const s = stripe();
    const h = createConnectionTokenHandler({ stripeFactory: () => s });
    const none = await post(h, {}, { headers: {} });
    assert.deepEqual([none.status, none.body.code], [401, 'unauthorized']);
    const bad = await post(h, {}, { headers: { authorization: 'Bearer expired' } });
    assert.deepEqual([bad.status, bad.body.code], [401, 'unauthorized']);
    assert.equal(s.calls.length, 0);
  });

  test('422 no_connected_account when the owner has no stripe_accounts row', async () => {
    w = W.world({ accounts: [] });
    const s = stripe();
    const res = await post(createConnectionTokenHandler({ stripeFactory: () => s }), {});
    assert.deepEqual([res.status, res.body.code], [422, 'no_connected_account']);
    assert.equal(s.calls.length, 0);
  });

  test('another owner\'s account row is never used', async () => {
    w = W.world({ accounts: [{ user_id: OTHER_USER, stripe_account_id: 'acct_other' }] });
    const res = await post(createConnectionTokenHandler({ stripeFactory: () => stripe() }), {});
    assert.equal(res.status, 422);
  });

  test('method and CORS', async () => {
    w = W.world();
    const h = createConnectionTokenHandler({ stripeFactory: () => stripe() });
    const pre = await h(fakeC({ method: 'OPTIONS', env: ENV }));
    assert.deepEqual([pre.status, pre.headers['Access-Control-Allow-Methods'], pre.headers['Access-Control-Allow-Headers']], [200, 'POST, OPTIONS', 'Content-Type, Authorization']);
    const get = await h(fakeC({ method: 'GET', headers: AUTH, env: ENV }));
    assert.deepEqual([get.status, get.body.code], [405, 'method_not_allowed']);
  });

  test('30/min per USER (not per IP: every call here has a new IP); a Stripe failure → 500 without detail', async () => {
    w = W.world();
    const h = createConnectionTokenHandler({ stripeFactory: () => stripe() });
    for (let i = 0; i < 30; i += 1) assert.equal((await post(h, {})).status, 200);
    const limited = await post(h, {});
    assert.deepEqual([limited.status, limited.body.code], [429, 'rate_limited']);

    const boom = stripeWith({ 'terminal.connectionTokens.create': async () => { throw new Error('sk_live_secret exploded'); } });
    const res = await post(createConnectionTokenHandler({ stripeFactory: () => boom }), {});
    assert.deepEqual([res.status, res.body.code], [500, 'server_error']);
    assert.equal(JSON.stringify(res.body).includes('sk_live'), false);
  });
});

describe('POST /api/terminal/location', () => {
  const loc = (id, tag, over = {}) => ({ id, display_name: id, address: ADDRESS, metadata: tag ? { tradeready: tag } : {}, ...over });
  const handler = (s, limit = 1000) => createLocationHandler({ stripeFactory: () => s, limit });

  test('status: picks the Location tagged metadata.tradeready=default, ignoring the rest', async () => {
    w = W.world();
    const s = stripeWith({ 'terminal.locations.list': async () => ({ data: [loc('tml_other', null), loc('tml_x', 'other'), loc('tml_default', 'default')], has_more: false }) });
    const res = await post(handler(s), { action: 'status' });
    assert.deepEqual([res.status, res.body], [200, { locationId: 'tml_default', address: ADDRESS }]);
    assert.deepEqual(s.callsTo('terminal.locations.list')[0].args[1], { stripeAccount: ACCOUNT });
    assert.equal(s.callsTo('terminal.locations.create').length, 0);
  });

  test('status with none → { locationId: null, address: null }; nothing created', async () => {
    w = W.world();
    const s = stripeWith({ 'terminal.locations.list': async () => ({ data: [loc('tml_other', null)], has_more: false }) });
    const res = await post(handler(s), { action: 'status' });
    assert.deepEqual([res.status, res.body], [200, { locationId: null, address: null }]);
    assert.equal(s.callsTo('terminal.locations.create').length, 0);
  });

  test('finds the Location on a later page', async () => {
    w = W.world();
    const s = stripeWith({
      'terminal.locations.list': async (params) => (params.starting_after
        ? { data: [loc('tml_default', 'default')], has_more: false }
        : { data: [loc('tml_a', null)], has_more: true }),
    });
    const res = await post(handler(s), { action: 'status' });
    assert.equal(res.body.locationId, 'tml_default');
    assert.equal(s.callsTo('terminal.locations.list')[1].args[0].starting_after, 'tml_a');
  });

  test('ensure creates it ONCE, with the exact params, on the connected account', async () => {
    w = W.world();
    const created = [];
    const s = stripeWith({
      'terminal.locations.list': async () => ({ data: created.slice(), has_more: false }),
      'terminal.locations.create': async (params) => { const l = { id: 'tml_new', ...params }; created.push(l); return l; },
    });
    const h = handler(s);
    const first = await post(h, { action: 'ensure', displayName: 'Rector HVAC', address: ADDRESS });
    assert.deepEqual([first.status, first.body], [200, { locationId: 'tml_new', address: ADDRESS }]);
    assert.deepEqual(s.callsTo('terminal.locations.create')[0].args, [
      { display_name: 'Rector HVAC', address: ADDRESS, metadata: { tradeready: 'default' } },
      { stripeAccount: ACCOUNT, idempotencyKey: `ttp_loc_${ACCOUNT}` },
    ]);
    const second = await post(h, { action: 'ensure', displayName: 'Rector HVAC', address: { ...ADDRESS, line1: 'ignored' } });
    assert.equal(second.body.locationId, 'tml_new');
    assert.equal(s.callsTo('terminal.locations.create').length, 1);
  });

  test('ensure normalizes state case and defaults country to US', async () => {
    w = W.world();
    const s = stripeWith({
      'terminal.locations.list': async () => ({ data: [], has_more: false }),
      'terminal.locations.create': async (params) => ({ id: 'tml_new', ...params }),
    });
    await post(handler(s), { action: 'ensure', displayName: 'R', address: { line1: '1 Main', city: 'Mesa', state: 'az', postal_code: '85201-1234' } });
    assert.deepEqual(s.callsTo('terminal.locations.create')[0].args[0].address, { line1: '1 Main', city: 'Mesa', state: 'AZ', postal_code: '85201-1234', country: 'US' });
  });

  test('address and displayName validation → 400, nothing created', async () => {
    w = W.world();
    const s = stripeWith({ 'terminal.locations.list': async () => ({ data: [], has_more: false }) });
    const h = handler(s);
    const bad = [
      [{ action: 'ensure', address: ADDRESS }, 'invalid_request'],
      [{ action: 'ensure', displayName: 'R' }, 'invalid_address'],
      [{ action: 'ensure', displayName: 'R', address: 'nope' }, 'invalid_address'],
      [{ action: 'ensure', displayName: 'R', address: { ...ADDRESS, line1: '' } }, 'invalid_address'],
      [{ action: 'ensure', displayName: 'R', address: { ...ADDRESS, city: ' ' } }, 'invalid_address'],
      [{ action: 'ensure', displayName: 'R', address: { ...ADDRESS, state: 'Arizona' } }, 'invalid_address'],
      [{ action: 'ensure', displayName: 'R', address: { ...ADDRESS, postal_code: '8500' } }, 'invalid_address'],
      [{ action: 'ensure', displayName: 'R', address: { ...ADDRESS, country: 'CA' } }, 'invalid_address'],
      [{ action: 'ensure', displayName: 'R', address: { ...ADDRESS, line2: 5 } }, 'invalid_address'],
      [{ action: 'nuke' }, 'invalid_request'],
      [{}, 'invalid_request'],
      [null, 'invalid_request'],
    ];
    for (const [body, code] of bad) {
      const res = await post(h, body);
      assert.deepEqual([res.status, res.body.code], [400, code], JSON.stringify(body));
    }
    assert.equal(s.callsTo('terminal.locations.create').length, 0);
  });

  test('401 and 422 mirror the other terminal routes; 10/min per user', async () => {
    w = W.world();
    const s = stripeWith({ 'terminal.locations.list': async () => ({ data: [], has_more: false }) });
    const h = handler(s, 10);
    assert.equal((await post(h, { action: 'status' }, { headers: {} })).status, 401);
    for (let i = 0; i < 10; i += 1) assert.equal((await post(h, { action: 'status' })).status, 200);
    assert.equal((await post(h, { action: 'status' })).status, 429);
    w.restore();
    w = W.world({ accounts: [] });
    assert.equal((await post(handler(s), { action: 'status' })).status, 422);
  });
});

describe('POST /api/terminal/payment-intent', () => {
  const OP = 'op_0123456789abcdef';
  const intentStripe = (over = {}) => stripeWith({
    'paymentIntents.create': async (params) => ({ id: 'pi_test_1', client_secret: 'pi_test_1_secret_x', amount: params.amount, ...over }),
  });
  const handler = (s, limit = 1000) => createPaymentIntentHandler({ stripeFactory: () => s, now: () => NOW_MS, limit });
  const good = (over = {}) => ({ invoiceId: 'inv1', amount: 120, localDate: TODAY, operationId: OP, ...over });

  test('creates a card_present PaymentIntent on the connected account with exact params and server-authored metadata', async () => {
    w = W.world();
    const s = intentStripe();
    const res = await post(handler(s), good({ userId: 'attacker', stripeAccount: 'acct_victim', metadata: { source: 'x' }, application_fee_amount: 9999 }));
    assert.deepEqual([res.status, res.body], [200, { paymentIntentId: 'pi_test_1', clientSecret: 'pi_test_1_secret_x', amount: 120, amountCents: 12000 }]);
    assert.deepEqual(s.callsTo('paymentIntents.create').map((c) => c.args), [[
      {
        amount: 12000,
        currency: 'usd',
        payment_method_types: ['card_present'],
        capture_method: 'automatic',
        description: 'Invoice INV-0042',
        metadata: { invoiceId: 'inv1', userId: USER, localDate: TODAY, source: 'tap_to_pay' },
      },
      { stripeAccount: ACCOUNT, idempotencyKey: `ttp_${OP}` },
    ]]);
  });

  test('amounts are integer cents: 19.99 → 1999, float noise rounds to the cent, a sub-cent amount is refused', async () => {
    w = W.world({ invoices: [W.invoiceRow({ amount: 412.5 })] });
    const s = intentStripe();
    const h = handler(s);
    assert.equal((await post(h, good({ amount: 19.99 }))).body.amountCents, 1999);
    assert.equal((await post(h, good({ amount: 0.7 + 0.1 }))).body.amountCents, 80); // 0.7999999999999999
    assert.equal((await post(h, good({ amount: 10.005 }))).status, 400);
    assert.equal((await post(h, good({ amount: 412.5 }))).body.amountCents, 41250);
    assert.deepEqual(s.callsTo('paymentIntents.create').map((c) => c.args[0].amount), [1999, 80, 41250]);
  });

  test('amount must be a positive finite number ≤ the balance; the response carries the balance', async () => {
    w = W.world({ invoices: [W.invoiceRow({ payments: [{ id: 'p1', amount: 20, date: '2026-10-02', method: 'cash' }] })] });
    const s = intentStripe();
    const h = handler(s);
    const over = await post(h, good({ amount: 100.01 }));
    assert.deepEqual([over.status, over.body.code, over.body.balance], [400, 'amount_exceeds_balance', 100]);
    assert.equal((await post(h, good({ amount: 100 }))).status, 200); // exactly the balance
    for (const amount of [0, -5, -0.01, NaN, Infinity, '50', null, undefined, [50], {}, true]) {
      const res = await post(h, good({ amount }));
      assert.deepEqual([res.status, res.body.code], [400, 'invalid_amount'], String(amount));
    }
    assert.equal(s.callsTo('paymentIntents.create').length, 1);
  });

  test('voided payments do not reduce the balance; a partial payment does', async () => {
    w = W.world({ invoices: [W.invoiceRow({ payments: [
      { id: 'p1', amount: 50, date: '2026-10-02', method: 'cash', voidedAt: '2026-10-03T00:00:00Z' },
      { id: 'p2', amount: 30, date: '2026-10-02', method: 'cash' },
    ] })] });
    const s = intentStripe();
    assert.equal((await post(handler(s), good({ amount: 90 }))).status, 200);
    const over = await post(handler(s), good({ amount: 90.01, operationId: 'op_second_attempt' }));
    assert.deepEqual([over.status, over.body.balance], [400, 90]);
  });

  test('legacy fallback: a legacy paid:true invoice has no balance; a legacy unpaid invoice has the full amount', async () => {
    w = W.world({ invoices: [W.invoiceRow({ paid: true }), W.invoiceRow({ paid: false }, { id: 'inv2' })] });
    const s = intentStripe();
    const paid = await post(handler(s), good());
    assert.deepEqual([paid.status, paid.body.code, paid.body.balance], [400, 'amount_exceeds_balance', 0]);
    assert.equal((await post(handler(s), good({ invoiceId: 'inv2', amount: 120 }))).status, 200);
    assert.equal(s.callsTo('paymentIntents.create').length, 1);
  });

  test('another owner\'s invoice and a missing one are IDENTICAL (422 not_synced, same body); the lookup filters by id AND user_id', async () => {
    w = W.world({ invoices: [
      W.invoiceRow({ number: 'SECRET-1' }, { id: 'theirs', user_id: OTHER_USER }),
      W.invoiceRow({}, { id: 'gone', deleted: true }),
    ] });
    const s = intentStripe();
    const h = handler(s);
    const theirs = await post(h, good({ invoiceId: 'theirs' }));
    const missing = await post(h, good({ invoiceId: 'nope' }));
    assert.deepEqual([theirs.status, theirs.body.code], [422, 'not_synced']);
    assert.deepEqual([missing.status, missing.body], [theirs.status, theirs.body], 'not mine and not there must be indistinguishable');
    assert.match(missing.body.error, /Open the app while online/);
    assert.equal(JSON.stringify(theirs.body).includes('SECRET'), false);
    // The caller's own deleted invoice is not a leak: a plain 404.
    const gone = await post(h, good({ invoiceId: 'gone' }));
    assert.deepEqual([gone.status, gone.body.code], [404, 'not_found']);
    assert.equal(s.calls.length, 0);
  });

  test('the invoice query is scoped to the verified user in the URL itself', async () => {
    w = W.world();
    const seen = [];
    const inner = global.fetch;
    global.fetch = async (url, ...rest) => { seen.push(String(url)); return inner(url, ...rest); };
    try { await post(handler(intentStripe()), good()); } finally { global.fetch = inner; }
    const lookup = seen.find((u) => u.includes('/rest/v1/invoices?'));
    assert.ok(lookup && lookup.includes('id=eq.inv1') && lookup.includes(`user_id=eq.${USER}`), lookup);
  });

  test('below the $0.50 floor → 400 below_minimum (not Stripe\'s stripe_rejected); $0.50 itself passes; no Stripe call below', async () => {
    w = W.world({ invoices: [W.invoiceRow({ amount: 0.3 }), W.invoiceRow({ amount: 0.3 }, { id: 'inv2' })] });
    const s = intentStripe();
    const h = handler(s);
    const small = await post(h, good({ amount: 0.3 }));
    assert.deepEqual([small.status, small.body.code, small.body.minimum], [400, 'below_minimum', 0.5]);
    assert.match(small.body.error, /too small to take by card/);
    const penny = await post(h, good({ amount: 0.49 }));
    assert.equal(penny.body.code, 'below_minimum');
    assert.equal(s.callsTo('paymentIntents.create').length, 0);
    w.restore();
    w = W.world({ invoices: [W.invoiceRow({ amount: 0.5 })] });
    const exact = await post(handler(s), good({ amount: 0.5 }));
    assert.deepEqual([exact.status, exact.body.amountCents], [200, 50]);
  });

  test('the description uses the invoice number the device froze with the operation, so a number edited between retries does not change it', async () => {
    w = W.world();
    const s = intentStripe();
    await post(handler(s), good({ invoiceNumber: 'INV-0042' }));
    w.restore();
    w = W.world({ invoices: [W.invoiceRow({ number: 'INV-0042-EDITED' })] });
    await post(handler(s), good({ invoiceNumber: 'INV-0042' }));
    assert.deepEqual(s.callsTo('paymentIntents.create').map((c) => c.args[0].description), ['Invoice INV-0042', 'Invoice INV-0042']);
    // Absent, blank, multi-line or oversized: the server's own number.
    for (const bad of [undefined, '  ', 'a\nb', 'x'.repeat(65), 7]) {
      await post(handler(s), good({ invoiceNumber: bad }));
    }
    assert.deepEqual(s.callsTo('paymentIntents.create').slice(2).map((c) => c.args[0].description), Array(5).fill('Invoice INV-0042-EDITED'));
  });

  test('idempotency: the Stripe key is ttp_<operationId>; a retry sends the same key', async () => {
    w = W.world();
    const s = intentStripe();
    await post(handler(s), good());
    await post(handler(s), good());
    assert.deepEqual(s.callsTo('paymentIntents.create').map((c) => c.args[1].idempotencyKey), [`ttp_${OP}`, `ttp_${OP}`]);
  });

  test('operationId and invoiceId are required and well-formed', async () => {
    w = W.world();
    const s = intentStripe();
    const h = handler(s);
    for (const body of [good({ operationId: undefined }), good({ operationId: 'short' }), good({ operationId: 'has spaces in it!' }), good({ operationId: 'x'.repeat(65) }), good({ invoiceId: undefined }), good({ invoiceId: 'a/b' }), good({ invoiceId: 42 })]) {
      const res = await post(h, body);
      assert.deepEqual([res.status, res.body.code], [400, 'invalid_request'], JSON.stringify(body));
    }
    assert.equal(s.calls.length, 0);
  });

  test('localDate: today and ±1 UTC day pass; further out, wrong shape and impossible dates fail', async () => {
    w = W.world();
    const s = intentStripe();
    const h = handler(s);
    for (const d of ['2026-10-13', TODAY, '2026-10-15']) assert.equal((await post(h, good({ localDate: d }))).status, 200, d);
    for (const d of ['2026-10-12', '2026-10-16', '2025-10-14', '2026-10-14T00:00:00Z', '10/14/2026', '2026-02-30', '2026-13-01', 20261014, null, undefined]) {
      const res = await post(h, good({ localDate: d }));
      assert.deepEqual([res.status, res.body.code], [400, 'invalid_date'], String(d));
    }
    assert.equal(s.callsTo('paymentIntents.create').length, 3);
  });

  test('401, 422 and rate limit (10/min per user)', async () => {
    w = W.world();
    const s = intentStripe();
    const h = handler(s, 10);
    assert.equal((await post(h, good(), { headers: {} })).status, 401);
    for (let i = 0; i < 10; i += 1) assert.equal((await post(h, good())).status, 200);
    assert.equal((await post(h, good())).status, 429);
    w.restore();
    w = W.world({ accounts: [] });
    assert.equal((await post(handler(s), good())).status, 422);
  });

  test('Stripe errors: invalid request → 422 stripe_rejected, idempotency conflict → 409, other → 500; no Stripe text leaks', async () => {
    w = W.world();
    const mk = (err) => stripeWith({ 'paymentIntents.create': async () => { throw err; } });
    const rejected = await post(handler(mk(invalidRequest('Amount must be at least $0.50 usd'))), good());
    assert.deepEqual([rejected.status, rejected.body.code], [422, 'stripe_rejected']);
    assert.equal(JSON.stringify(rejected.body).includes('$0.50'), false);
    const conflict = await post(handler(mk(stripeError('StripeIdempotencyError', { message: 'Keys for idempotent requests can only be used with the same parameters' }))), good());
    assert.deepEqual([conflict.status, conflict.body.code], [409, 'operation_conflict']);
    const down = await post(handler(mk(new Error('sk_live boom'))), good());
    assert.deepEqual([down.status, down.body.code], [500, 'server_error']);
  });

  test('a Supabase error reading the invoice → 500', async () => {
    w = W.world({ failOn: { 'GET invoices': 500 } });
    const res = await post(handler(intentStripe()), good());
    assert.deepEqual([res.status, res.body.code], [500, 'server_error']);
  });
});

describe('Connect webhook — payment_intent.succeeded', () => {
  const PI = (over = {}, metaOver = {}) => ({
    id: 'pi_tap_1', object: 'payment_intent', status: 'succeeded', amount: 12000, amount_received: 12000, currency: 'usd',
    metadata: { invoiceId: 'inv1', userId: USER, localDate: '2026-10-13', source: 'tap_to_pay', ...metaOver },
    ...over,
  });
  const event = (pi = PI(), over = {}) => ({ id: 'evt_pi', type: 'payment_intent.succeeded', account: ACCOUNT, data: { object: pi }, ...over });
  const deliver = (ev) => createStripeWebhookHandler({ stripeFactory: () => fakeStripe() })(
    fakeC({ method: 'POST', rawBody: JSON.stringify(ev), headers: { 'stripe-signature': 'valid' }, env: ENV })
  );
  const payments = () => w.db.rows('invoices')[0].data.payments;
  const writes = () => w.db.writes.filter((x) => x.table === 'invoices');

  test('a tap_to_pay PI is booked once with the exact entry shape, dated by the device\'s local day, and the invoice marked paid', async () => {
    w = W.world();
    const res = await deliver(event());
    assert.deepEqual([res.status, res.body], [200, { received: true }]);
    assert.deepEqual(payments(), [
      { id: 'stripe_pi_tap_1', amount: 120, date: '2026-10-13', method: 'stripe', stripePaymentIntentId: 'pi_tap_1', channel: 'card_present' },
    ]);
    assert.deepEqual(Object.keys(payments()[0]), ['id', 'amount', 'date', 'method', 'stripePaymentIntentId', 'channel']);
    const inv = w.db.rows('invoices')[0].data;
    assert.deepEqual([inv.paid, inv.paidAt], [true, '2026-10-13']);
  });

  test('the date comes from metadata, not the server clock (local day behind UTC)', async () => {
    w = W.world();
    await deliver(event(PI({}, { localDate: '2020-01-02' })));
    assert.equal(payments()[0].date, '2020-01-02');
  });

  test('amount is amount_received in whole cents → dollars (a partial payment leaves paid false)', async () => {
    w = W.world();
    await deliver(event(PI({ amount: 4125, amount_received: 4125 })));
    assert.equal(payments()[0].amount, 41.25);
    assert.equal(w.db.rows('invoices')[0].data.paid, false);
  });

  test('redelivery is a no-op', async () => {
    w = W.world();
    await deliver(event());
    const before = writes().length;
    const res = await deliver(event());
    assert.deepEqual([res.status, res.body], [200, { received: true }]);
    assert.equal(payments().length, 1);
    assert.equal(writes().length, before);
  });

  test('device-first: an identical entry already on the invoice → no write', async () => {
    const entry = { id: 'stripe_pi_tap_1', amount: 120, date: '2026-10-13', method: 'stripe', stripePaymentIntentId: 'pi_tap_1', channel: 'card_present' };
    w = W.world({ invoices: [W.invoiceRow({ payments: [entry], paid: true, paidAt: '2026-10-13' })] });
    const res = await deliver(event());
    assert.deepEqual([res.status, res.body], [200, { received: true }]);
    assert.equal(writes().length, 0);
    assert.deepEqual(payments(), [entry]);
  });

  test('a PaymentIntent WITHOUT source=tap_to_pay (payment link / pay page) is skipped — no read, no write', async () => {
    w = W.world();
    for (const meta of [{ source: undefined }, { source: 'pay_page' }, { source: 'autopay' }, { source: 'tap_to_pay ' }]) {
      const res = await deliver(event(PI({}, meta)));
      assert.deepEqual([res.status, res.body], [200, { received: true, skipped: true }], JSON.stringify(meta));
    }
    const link = await deliver(event(PI({ metadata: { invoiceId: 'inv1' } })));
    assert.deepEqual([link.status, link.body], [200, { received: true, skipped: true }]);
    assert.equal(writes().length, 0);
    assert.equal(w.net.calls.filter((c) => c.u.pathname.startsWith('/rest/')).length, 0);
  });

  test('a tap_to_pay PI with no invoiceId, and other payment_intent.* events, are skipped', async () => {
    w = W.world();
    const noInvoice = await deliver(event(PI({}, { invoiceId: undefined })));
    assert.deepEqual([noInvoice.status, noInvoice.body], [200, { received: true, skipped: true }]);
    for (const type of ['payment_intent.created', 'payment_intent.payment_failed', 'payment_intent.canceled', 'payment_intent.processing', 'payment_intent.amount_capturable_updated', 'charge.succeeded']) {
      const res = await deliver(event(PI(), { type }));
      assert.deepEqual([res.status, res.body], [200, { received: true, skipped: true }], type);
    }
    assert.equal(writes().length, 0);
  });

  test('an event.account mismatch is skipped even with forged metadata', async () => {
    w = W.world();
    const res = await deliver(event(PI(), { account: 'acct_attacker' }));
    assert.deepEqual([res.status, res.body], [200, { received: true, skipped: true }]);
    assert.equal(writes().length, 0);
    const platform = await deliver(event(PI(), { account: undefined }));
    assert.deepEqual([platform.status, platform.body], [200, { received: true, skipped: true }]);
    assert.equal(writes().length, 0);
  });

  test('a zero or missing amount_received writes nothing', async () => {
    w = W.world();
    for (const pi of [PI({ amount_received: 0 }), PI({ amount_received: undefined })]) {
      const res = await deliver(event(pi));
      assert.deepEqual([res.status, res.body], [200, { received: true, skipped: true }]);
    }
    assert.equal(writes().length, 0);
  });

  test('an unsynced invoice is acknowledged without a write', async () => {
    w = W.world({ invoices: [] });
    const res = await deliver(event());
    assert.deepEqual([res.status, res.body], [200, { received: true }]);
    assert.equal(writes().length, 0);
  });

  test('a legacy paid invoice is materialized before the append', async () => {
    w = W.world({ invoices: [W.invoiceRow({ amount: 200, paid: true, paidAt: '2026-09-01' })] });
    await deliver(event(PI({ amount: 5000, amount_received: 5000 })));
    assert.deepEqual(payments().map((p) => [p.id, p.amount]), [['legacy_inv1', 200], ['stripe_pi_tap_1', 50]]);
  });

  test('a Supabase error → 500 so Stripe retries', async () => {
    w = W.world({ failOn: { 'POST invoices': 500 } });
    const res = await deliver(event());
    assert.deepEqual([res.status, res.body], [500, { error: 'Database error' }]);
  });

  test('a bad signature still → 400 (the branch sits after verification)', async () => {
    w = W.world();
    const res = await createStripeWebhookHandler({ stripeFactory: () => fakeStripe() })(
      fakeC({ method: 'POST', rawBody: JSON.stringify(event()), headers: { 'stripe-signature': 'forged' }, env: ENV })
    );
    assert.equal(res.status, 400);
    assert.equal(writes().length, 0);
  });
});

describe('GET /api/stripe/connect-status — additive Phase 18 fields', () => {
  function statusWorld(account) {
    const world = W.world();
    world.restore();
    const net = installFetch((call) => {
      if (call.u.pathname === '/auth/v1/user') return jsonRes({ id: USER });
      if (call.u.pathname === '/rest/v1/stripe_accounts') return jsonRes([{ stripe_account_id: ACCOUNT }]);
      if (call.u.origin === 'https://api.stripe.com' && call.u.pathname === `/v1/accounts/${ACCOUNT}`) return jsonRes({ id: ACCOUNT, ...account });
      throw new Error(`unrouted ${call.method} ${call.url}`);
    });
    return { restore: () => net.restore() };
  }
  const get = () => connectStatusHandler(fakeC({ method: 'GET', headers: AUTH, env: ENV }));

  test('the three existing keys are unchanged; charges_enabled and card_payments_capability are added', async () => {
    w = statusWorld({ details_submitted: true, charges_enabled: true, capabilities: { card_payments: 'active', transfers: 'active' }, business_profile: { name: 'Rector HVAC' } });
    const res = await get();
    assert.deepEqual([res.status, res.body], [200, {
      connected: true, details_submitted: true, display_name: 'Rector HVAC', charges_enabled: true, card_payments_capability: 'active',
    }]);
  });

  test('a restricted account reports false and its capability status; a missing capability is null', async () => {
    w = statusWorld({ details_submitted: false, charges_enabled: false, capabilities: { card_payments: 'inactive' } });
    assert.deepEqual([(await get()).body.charges_enabled, (await get()).body.card_payments_capability], [false, 'inactive']);
    w.restore();
    w = statusWorld({ details_submitted: true });
    const res = await get();
    assert.deepEqual([res.body.charges_enabled, res.body.card_payments_capability], [false, null]);
  });
});

describe('route registration', () => {
  test('the three routes are mounted on the app; an unknown /api/terminal/* is a JSON 404', async () => {
    w = W.world();
    const env = { ...ENV };
    const res = (path, init = {}) => appWorker.fetch(new Request(`https://x.test${path}`, { method: 'POST', ...init }), env);
    for (const p of ['connection-token', 'location', 'payment-intent']) {
      const r = await res(`/api/terminal/${p}`);
      assert.equal(r.status, 401, p); // reached the handler, which wants a JWT
      assert.equal((await r.json()).code, 'unauthorized');
    }
    const nf = await res('/api/terminal/refund');
    assert.deepEqual([nf.status, await nf.json()], [404, { error: 'Not found' }]);
  });
});
