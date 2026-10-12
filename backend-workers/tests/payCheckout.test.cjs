// POST /api/pay/checkout (Phase 24 spec §4.4): min(requested, live
// balance), refusal while an autopay charge is claimed, other open sessions
// expired (an expire failure → 409), Stripe Customer reuse, the pending
// enrollment's exact consent record, stale consent → 409, idempotent
// double-clicks, and setup mode. Fake Stripe + fake Supabase; no network.

const assert = require('node:assert/strict');
const { before, afterEach, describe, test } = require('node:test');
const { fakeStripe, fakeCheckoutSessions, fakeC, invalidRequest, stripeError } = require('./helpers/fakes.cjs');
const W = require('./helpers/autopayWorld.cjs');
const { checkout } = require('../lib/pay/payService.js');
const { mintInvoicePayToken, mintSetupToken, verifyPayToken } = require('../lib/pay/payToken.js');
const { renderConsent, CONSENT_VERSION } = require('../lib/autopay/consentText.js');

const { USER, SECRET, ENV, ACCOUNT } = W;
const NOW_MS = Date.UTC(2026, 9, 3, 18, 4, 30);
const BUCKET = Math.floor(NOW_MS / 600000);

let w;
afterEach(() => w && w.restore());

const pTok = (over = {}) => mintInvoicePayToken(SECRET, { userId: USER, invoiceId: 'inv1', ...over });

function stripeWith(over = {}) {
  let n = 0;
  return fakeStripe({
    'checkout.sessions.list': async () => ({ data: [], has_more: false }),
    'checkout.sessions.expire': async (id) => ({ id, status: 'expired' }),
    'checkout.sessions.retrieve': async (id) => ({ id, status: 'open' }),
    'checkout.sessions.create': async () => {
      n += 1;
      return { id: `cs_test_${n}`, status: 'open', url: `https://checkout.stripe.com/c/pay/cs_test_${n}#fidabc` };
    },
    'customers.create': async () => ({ id: 'cus_new' }),
    ...over,
  });
}

const call = (body, { stripe = stripeWith(), nowMs = NOW_MS } = {}) =>
  checkout(ENV, { stripe, body, ip: '203.0.113.9', userAgent: 'Mozilla/5.0 test', nowMs }).then((r) => ({ ...r, stripe }));

const optIn = (amount = 120) => ({ consentVersion: CONSENT_VERSION, amount });

describe('pay checkout — amounts and refusals', () => {
  test('a plain payment: exact session parameters, card only, live balance', async () => {
    w = W.world();
    const { status, body, stripe } = await call({ t: pTok() });
    assert.deepEqual([status, body], [200, { url: 'https://checkout.stripe.com/c/pay/cs_test_1#fidabc' }]);
    const [create] = stripe.callsTo('checkout.sessions.create');
    const [params, opts] = create.args;
    const idem = `tr-co:inv1:12000:n:${BUCKET}`;
    assert.deepEqual(opts, { stripeAccount: ACCOUNT, idempotencyKey: idem });
    const t = encodeURIComponent(pTok());
    assert.deepEqual(params, {
      mode: 'payment',
      payment_method_types: ['card'],
      line_items: [{ price_data: { currency: 'usd', unit_amount: 12000, product_data: { name: 'Invoice INV-0042' } }, quantity: 1 }],
      metadata: { invoiceId: 'inv1', tr_kind: 'invoice', tr_invoice_cents: '12000', tr_idem: idem },
      payment_intent_data: { metadata: { invoiceId: 'inv1', source: 'pay_page' }, description: 'Invoice INV-0042' },
      expires_at: params.expires_at,
      success_url: `https://gettradereadyapp.com/pay.html?t=${t}&session_id={CHECKOUT_SESSION_ID}`,
      cancel_url: `https://gettradereadyapp.com/pay.html?t=${t}`,
    });
    const ahead = params.expires_at - Math.floor(NOW_MS / 1000);
    assert.ok(ahead >= 30 * 60 && ahead <= 41 * 60, `expires ${ahead}s ahead`);
    assert.equal(w.db.rows('autopay_enrollments').length, 0);
  });

  test('charges min(requested, balance): a deposit ask, and a stale larger ask', async () => {
    w = W.world({ invoices: [W.invoiceRow({ payments: [{ id: 'p1', amount: 20, date: '2026-10-02', method: 'cash' }] })] });
    const deposit = await call({ t: pTok({ cents: 5000 }) });
    assert.equal(deposit.stripe.callsTo('checkout.sessions.create')[0].args[0].line_items[0].price_data.unit_amount, 5000);
    const stale = await call({ t: pTok({ cents: 12000 }) });
    assert.equal(stale.stripe.callsTo('checkout.sessions.create')[0].args[0].line_items[0].price_data.unit_amount, 10000);
  });

  test('a paid-off deposit link charges the live balance, never a second deposit', async () => {
    w = W.world({ invoices: [W.invoiceRow({ amount: 300, payments: [{ id: 'p1', amount: 100, date: '2026-10-02', method: 'stripe' }] })] });
    const { stripe } = await call({ t: pTok({ cents: 10000, balanceCents: 30000 }) });
    assert.equal(stripe.callsTo('checkout.sessions.create')[0].args[0].line_items[0].price_data.unit_amount, 20000);
  });

  test('client-supplied amounts are ignored', async () => {
    w = W.world();
    const { stripe } = await call({ t: pTok(), amount: 1, cents: 1, unit_amount: 1 });
    assert.equal(stripe.callsTo('checkout.sessions.create')[0].args[0].line_items[0].price_data.unit_amount, 12000);
  });

  test('paid / unsynced / deleted / disconnected are refused before any Stripe call', async () => {
    const cases = [
      [{ invoices: [W.invoiceRow({ paid: true })] }, 409, 'paid'],
      [{ invoices: [W.invoiceRow({ payments: [{ id: 'p', amount: 120, date: '2026-10-01', method: 'cash' }] })] }, 409, 'paid'],
      [{ invoices: [] }, 409, 'not_ready'],
      [{ invoices: [W.invoiceRow({}, { deleted: true })] }, 410, 'gone'],
      [{ accounts: [] }, 410, 'unavailable'],
    ];
    for (const [opts, status, code] of cases) {
      w = W.world(opts);
      const res = await call({ t: pTok() });
      assert.deepEqual([res.status, res.body.code], [status, code], code);
      assert.equal(res.stripe.calls.length, 0);
      w.restore();
      w = null;
    }
  });

  test('refused while an autopay charge for the invoice is in flight', async () => {
    w = W.world({ charges: [{ id: 'ch1', user_id: USER, invoice_id: 'inv1', enrollment_id: 'e', attempt: 1, amount_cents: 12000, status: 'claimed', created_at: '2026-10-03T18:00:00.000Z' }] });
    const res = await call({ t: pTok() });
    assert.deepEqual([res.status, res.body.code], [409, 'in_flight']);
    assert.equal(res.stripe.calls.length, 0);
  });

  test('bad tokens and bodies', async () => {
    w = W.world();
    assert.equal((await call({ t: 'nope' })).status, 404);
    assert.equal((await call({})).status, 400);
    assert.equal((await call(null)).status, 400);
    assert.equal((await checkout({ ...ENV, PAY_LINK_SIGNING_SECRET: '' }, { body: { t: pTok() } })).status, 404);
  });
});

describe('pay checkout — one open session per invoice', () => {
  test("expires this invoice's other open sessions (incl. legacy link sessions), not others", async () => {
    w = W.world();
    const idem = `tr-co:inv1:12000:n:${BUCKET}`;
    const stripe = stripeWith({
      'checkout.sessions.list': async () => ({
        data: [
          { id: 'cs_old_page', metadata: { invoiceId: 'inv1', tr_idem: 'tr-co:inv1:12000:a:1' } },
          { id: 'cs_legacy_link', metadata: { invoiceId: 'inv1' } },
          { id: 'cs_other_invoice', metadata: { invoiceId: 'inv2' } },
          { id: 'cs_my_double_click', metadata: { invoiceId: 'inv1', tr_idem: idem } },
        ],
        has_more: false,
      }),
    });
    const res = await call({ t: pTok() }, { stripe });
    assert.equal(res.status, 200);
    assert.deepEqual(stripe.callsTo('checkout.sessions.expire').map((c) => c.args[0]), ['cs_old_page', 'cs_legacy_link']);
    const [list] = stripe.callsTo('checkout.sessions.list');
    assert.deepEqual(list.args[0], { status: 'open', created: { gte: Math.floor(NOW_MS / 1000) - 86400 }, limit: 100 });
    assert.deepEqual(list.args[1], { stripeAccount: ACCOUNT });
  });

  test('pages through the open-session list', async () => {
    w = W.world();
    const pages = [
      { data: [{ id: 'cs_a', metadata: { invoiceId: 'inv1' } }], has_more: true },
      { data: [{ id: 'cs_b', metadata: { invoiceId: 'inv1' } }], has_more: false },
    ];
    const stripe = stripeWith({ 'checkout.sessions.list': async () => pages.shift() });
    await call({ t: pTok() }, { stripe });
    assert.deepEqual(stripe.callsTo('checkout.sessions.expire').map((c) => c.args[0]), ['cs_a', 'cs_b']);
    assert.equal(stripe.callsTo('checkout.sessions.list')[1].args[0].starting_after, 'cs_a');
  });

  test('an expire failure (the session just completed) → 409 maybe_paid, no new session', async () => {
    w = W.world();
    const stripe = stripeWith({
      'checkout.sessions.list': async () => ({ data: [{ id: 'cs_old', metadata: { invoiceId: 'inv1' } }], has_more: false }),
      'checkout.sessions.expire': async () => { throw invalidRequest('Only Checkout Sessions with a status of open can be expired.'); },
    });
    const res = await call({ t: pTok() }, { stripe });
    assert.deepEqual([res.status, res.body.code], [409, 'maybe_paid']);
    assert.equal(stripe.callsTo('checkout.sessions.create').length, 0);
  });

  test('a replayed session another tab expired meanwhile is re-minted once', async () => {
    w = W.world();
    let n = 0;
    const stripe = stripeWith({
      'checkout.sessions.create': async (params, opts) => {
        n += 1;
        return n === 1 ? { id: 'cs_old', status: 'expired', url: 'x' } : { id: 'cs_new', status: 'open', url: 'https://checkout.stripe.com/c/pay/cs_new' };
      },
    });
    const res = await call({ t: pTok() }, { stripe });
    assert.equal(res.body.url, 'https://checkout.stripe.com/c/pay/cs_new');
    const [, second] = stripe.callsTo('checkout.sessions.create');
    assert.equal(second.args[1].idempotencyKey, `tr-co:inv1:12000:n:${BUCKET}:rcs_old`);
    assert.equal(second.args[0].metadata.tr_idem, `tr-co:inv1:12000:n:${BUCKET}:rcs_old`);
  });

  test('a replayed session that already completed → 409 maybe_paid', async () => {
    w = W.world();
    const stripe = stripeWith({ 'checkout.sessions.create': async () => ({ id: 'cs_done', status: 'complete', url: 'x' }) });
    assert.equal((await call({ t: pTok() }, { stripe })).body.code, 'maybe_paid');
  });
});

describe('pay checkout — autopay opt-in', () => {
  test('creates the Customer, the pending consent record and a saving session', async () => {
    w = W.world();
    const { status, stripe } = await call({ t: pTok(), autopay: optIn() });
    assert.equal(status, 200);

    const [cus] = stripe.callsTo('customers.create');
    assert.deepEqual(cus.args, [
      { name: 'Pat Lee', email: 'pat@example.com', metadata: { tr_user: USER, tr_customer: 'c1' } },
      { stripeAccount: ACCOUNT, idempotencyKey: `tr-cus:${USER}:c1:${BUCKET}` },
    ]);

    const [e] = w.db.rows('autopay_enrollments');
    const expectedText = renderConsent({ businessName: 'Rector HVAC', planDescription: 'Quarterly HVAC maintenance', amountCents: 12000, cadence: 'monthly' }).text;
    assert.equal(e.status, 'pending');
    assert.equal(e.user_id, USER);
    assert.equal(e.stripe_account_id, ACCOUNT);
    assert.equal(e.customer_id, 'c1');
    assert.equal(e.recurring_invoice_id, 'ri1');
    assert.equal(e.stripe_customer_id, 'cus_new');
    assert.equal(e.max_amount_cents, 12000);
    assert.equal(e.consent_version, 'autopay-consent-v1');
    assert.equal(e.consent_text, expectedText);
    assert.equal(e.consent_ip, '203.0.113.9');
    assert.equal(e.consent_user_agent, 'Mozilla/5.0 test');
    assert.ok(e.consented_at);
    assert.equal(e.payment_method_id, undefined);
    assert.equal(e.checkout_session_id, 'cs_test_1');

    const [create] = stripe.callsTo('checkout.sessions.create');
    const params = create.args[0];
    assert.equal(params.customer, 'cus_new');
    assert.equal(params.payment_intent_data.setup_future_usage, 'off_session');
    assert.equal(params.metadata.tr_enrollment, e.id);
    assert.equal(create.args[1].idempotencyKey, `tr-co:inv1:12000:a:${BUCKET}`);
    const msg = params.custom_text.submit.message;
    assert.ok(msg.length <= 1200);
    assert.match(msg, /^By paying, you also authorize Rector HVAC to charge this card for future Quarterly HVAC maintenance invoices on their due dates \(up to \$120\.00 each\) until you turn automatic payments off\. \[Manage automatic payments\]\(https:\/\/gettradereadyapp\.com\/pay\.html\?m=m\./);
    const m = /\?m=([^)]+)\)/.exec(msg)[1];
    assert.equal(verifyPayToken(SECRET, decodeURIComponent(m), { expectKind: 'm' }).payload.e, e.id);
  });

  test("reuses the customer's existing Stripe Customer on this account", async () => {
    w = W.world({ enrollments: [W.enrollmentRow({ status: 'revoked', stripe_customer_id: 'cus_old' })] });
    const { stripe } = await call({ t: pTok(), autopay: optIn() });
    assert.equal(stripe.callsTo('customers.create').length, 0);
    assert.equal(stripe.callsTo('checkout.sessions.create')[0].args[0].customer, 'cus_old');
  });

  test('a Customer from a previous Stripe account is not reused', async () => {
    w = W.world({ enrollments: [W.enrollmentRow({ status: 'revoked', stripe_account_id: 'acct_previous', stripe_customer_id: 'cus_elsewhere' })] });
    const { stripe } = await call({ t: pTok(), autopay: optIn() });
    assert.equal(stripe.callsTo('customers.create').length, 1);
  });

  test('a double-click in the same 10 minutes replays: one consent row, identical parameters', async () => {
    w = W.world();
    const stripe = stripeWith();
    await call({ t: pTok(), autopay: optIn() }, { stripe });
    await call({ t: pTok(), autopay: optIn() }, { stripe, nowMs: NOW_MS + 60_000 });
    assert.equal(w.db.rows('autopay_enrollments').length, 1);
    const [a, b] = stripe.callsTo('checkout.sessions.create');
    assert.deepEqual(b.args, a.args);
  });

  test('stale consent version, changed amount, deposit or non-offering plan → 409 changed', async () => {
    const cases = [
      [{}, { t: pTok(), autopay: { consentVersion: 'autopay-consent-v0', amount: 120 } }],
      [{ plans: [W.planRow({ amount: 130 })] }, { t: pTok(), autopay: optIn(120) }],
      [{}, { t: pTok({ cents: 6000 }), autopay: optIn() }],
      [{ plans: [W.planRow({ autopayEnabled: false })] }, { t: pTok(), autopay: optIn() }],
      [{ enrollments: [W.enrollmentRow({ max_amount_cents: 12000 })] }, { t: pTok(), autopay: optIn() }],
    ];
    for (const [opts, body] of cases) {
      w = W.world(opts);
      const res = await call(body);
      assert.deepEqual([res.status, res.body.code], [409, 'changed'], JSON.stringify(body.autopay));
      assert.equal(res.stripe.calls.length, 0);
      assert.equal(w.db.rows('autopay_enrollments').filter((e) => e.status === 'pending').length, 0);
      w.restore();
      w = null;
    }
  });

  test('an update offer records the "Update automatic payments" text and the new ceiling', async () => {
    w = W.world({ plans: [W.planRow({ amount: 150 })], invoices: [W.invoiceRow({ amount: 150 })], enrollments: [W.enrollmentRow({ max_amount_cents: 12000 })] });
    const res = await call({ t: pTok(), autopay: optIn(150) });
    assert.equal(res.status, 200);
    const pending = w.db.rows('autopay_enrollments').find((e) => e.status === 'pending');
    assert.equal(pending.max_amount_cents, 15000);
    assert.match(pending.consent_text, /^Update automatic payments to \$150\.00\n\n/);
  });
});

describe('pay checkout — setup mode (s)', () => {
  const sTok = (over = {}) => mintSetupToken(SECRET, { userId: USER, planId: 'ri1', customerId: 'c1', nowSec: Math.floor(NOW_MS / 1000), ...over });

  test('setup-mode session with the same consent record; success lands on the manage page', async () => {
    w = W.world();
    const s = sTok();
    const { status, stripe } = await call({ s, consentVersion: CONSENT_VERSION, amount: 120 });
    assert.equal(status, 200);
    const [cus] = stripe.callsTo('customers.create');
    assert.equal(cus.args[0].email, 'pat@example.com'); // from the customer record
    const [e] = w.db.rows('autopay_enrollments');
    assert.equal(e.status, 'pending');
    assert.equal(e.consent_text, renderConsent({ businessName: 'Rector HVAC', planDescription: 'Quarterly HVAC maintenance', amountCents: 12000, cadence: 'monthly' }).text);
    const [create] = stripe.callsTo('checkout.sessions.create');
    const params = create.args[0];
    assert.equal(params.mode, 'setup');
    assert.equal(params.customer, 'cus_new');
    assert.deepEqual(params.payment_method_types, ['card']);
    assert.deepEqual(params.setup_intent_data, { metadata: { tr_enrollment: e.id } });
    assert.equal(params.metadata.tr_kind, 'autopay_setup');
    assert.equal(params.metadata.tr_enrollment, e.id);
    assert.equal(params.line_items, undefined);
    assert.equal(params.payment_intent_data, undefined);
    assert.match(params.custom_text.submit.message, /^By saving this card, you authorize Rector HVAC/);
    const success = new URL(params.success_url);
    assert.equal(success.searchParams.get('done'), '1');
    assert.equal(verifyPayToken(SECRET, success.searchParams.get('m'), { expectKind: 'm' }).payload.e, e.id);
    assert.equal(params.cancel_url, `https://gettradereadyapp.com/pay.html?s=${encodeURIComponent(s)}`);
    assert.equal(create.args[1].idempotencyKey, `tr-su:ri1:c1:12000:${BUCKET}`);
  });

  test('expired → 410; stale consent → 409; reassigned plan → 404', async () => {
    w = W.world();
    const expired = await call({ s: sTok({ nowSec: Math.floor(NOW_MS / 1000) - 8 * 86400 }), consentVersion: CONSENT_VERSION, amount: 120 });
    assert.deepEqual([expired.status, expired.body.code], [410, 'expired']);
    const stale = await call({ s: sTok(), consentVersion: 'old', amount: 120 });
    assert.deepEqual([stale.status, stale.body.code], [409, 'changed']);
    const changed = await call({ s: sTok(), consentVersion: CONSENT_VERSION, amount: 99 });
    assert.equal(changed.body.code, 'changed');
    w.restore();
    w = W.world({ plans: [W.planRow({ customerId: 'c2' })] });
    assert.equal((await call({ s: sTok(), consentVersion: CONSENT_VERSION, amount: 120 })).status, 404);
  });
});

describe('pay checkout route', () => {
  let createPayCheckoutHandler;
  before(async () => {
    ({ createPayCheckoutHandler } = await import('../src/routes/pay/checkout.js'));
  });

  test('CORS preflight, 405, per-IP limit of 10/min, and error mapping', async () => {
    w = W.world();
    const handler = createPayCheckoutHandler({ stripeFactory: () => stripeWith() });
    const pre = await handler(fakeC({ method: 'OPTIONS', headers: { origin: 'https://www.gettradereadyapp.com' }, env: ENV }));
    assert.deepEqual([pre.status, pre.headers['Access-Control-Allow-Origin'], pre.headers['Access-Control-Allow-Headers']], [200, 'https://www.gettradereadyapp.com', 'Content-Type']);
    assert.equal((await handler(fakeC({ method: 'GET', env: ENV }))).status, 405);
    const ip = { 'cf-connecting-ip': '203.0.113.77' };
    for (let i = 0; i < 10; i++) await handler(fakeC({ method: 'POST', body: {}, env: ENV, headers: ip }));
    assert.equal((await handler(fakeC({ method: 'POST', body: {}, env: ENV, headers: ip }))).status, 429);

    const boom = createPayCheckoutHandler({ stripeFactory: () => stripeWith({ 'checkout.sessions.create': async () => { throw new Error('stripe down'); } }) });
    const res = await boom(fakeC({ method: 'POST', body: { t: pTok() }, env: ENV }));
    assert.deepEqual([res.status, res.body.code], [500, 'server_error']);
    const busy = createPayCheckoutHandler({ stripeFactory: () => stripeWith({ 'checkout.sessions.create': async () => { throw stripeError('StripeIdempotencyError', { statusCode: 409 }); } }) });
    const res2 = await busy(fakeC({ method: 'POST', body: { t: pTok() }, env: ENV }));
    assert.deepEqual([res2.status, res2.body.code], [409, 'busy']);
  });
});

describe('pay checkout — mutual exclusion with the autopay sweep', () => {
  test('a claim that appears while the session is created → session withdrawn, 409 in_flight', async () => {
    w = W.world();
    const stripe = stripeWith({
      'checkout.sessions.create': async () => {
        // The sweep claims the invoice right now, between our first check and our session.
        w.db.rows('autopay_charges').push({ id: 'c-new', user_id: USER, invoice_id: 'inv1', enrollment_id: 'e', attempt: 1, amount_cents: 12000, status: 'claimed', created_at: new Date().toISOString() });
        return { id: 'cs_race', status: 'open', url: 'https://checkout.stripe.com/c/pay/cs_race' };
      },
    });
    const res = await call({ t: pTok() }, { stripe });
    assert.deepEqual([res.status, res.body.code], [409, 'in_flight']);
    assert.deepEqual(stripe.callsTo('checkout.sessions.expire').map((c) => c.args), [['cs_race', {}, { stripeAccount: ACCOUNT }]]);
  });

  test('older settled claims (e.g. a failed autopay) do not block paying by link', async () => {
    w = W.world({ charges: [{ id: 'c-old', user_id: USER, invoice_id: 'inv1', enrollment_id: 'e', attempt: 1, amount_cents: 12000, status: 'failed', created_at: '2026-10-01T00:00:00.000Z' }] });
    const res = await call({ t: pTok() });
    assert.equal(res.status, 200);
  });
});

// Phase 28 (tips spec §4.2, §8): the tip is a second server-priced "Tip" line,
// offered only on a full-balance payment, re-checked against the owner's
// setting, capped at the amount being paid, and part of the idempotency key.
describe('pay checkout — tips (Phase 28)', () => {
  const TIPS_ON = () => ({ settings: [W.settingsRow({ tipsEnabled: true })] });
  const createArgs = (stripe) => stripe.callsTo('checkout.sessions.create')[0].args;
  const TIP_LINE = (cents) => ({ price_data: { currency: 'usd', unit_amount: cents, product_data: { name: 'Tip' } }, quantity: 1 });

  test('a tip adds exactly one "Tip" line, the metadata and the key; the invoice line is unchanged', async () => {
    w = W.world(TIPS_ON());
    const { status, body, stripe } = await call({ t: pTok(), tipCents: 1800 });
    assert.deepEqual([status, body], [200, { url: 'https://checkout.stripe.com/c/pay/cs_test_1#fidabc' }]);
    const [params, opts] = createArgs(stripe);
    const idem = `tr-co:inv1:12000:t1800:n:${BUCKET}`;
    assert.deepEqual(opts, { stripeAccount: ACCOUNT, idempotencyKey: idem });
    assert.deepEqual(params.line_items, [
      { price_data: { currency: 'usd', unit_amount: 12000, product_data: { name: 'Invoice INV-0042' } }, quantity: 1 },
      TIP_LINE(1800),
    ]);
    assert.deepEqual(params.metadata, { invoiceId: 'inv1', tr_kind: 'invoice', tr_invoice_cents: '12000', tr_tip_cents: '1800', tr_idem: idem });
    assert.deepEqual(params.payment_method_types, ['card']);
    assert.equal(params.mode, 'payment');
  });

  test('no tip line, no tr_tip_cents and the old key unless tipCents > 0 (absent, null, 0)', async () => {
    for (const body of [{}, { tipCents: null }, { tipCents: 0 }]) {
      w = W.world(TIPS_ON());
      const { status, stripe } = await call({ t: pTok(), ...body });
      assert.equal(status, 200, JSON.stringify(body));
      const [params, opts] = createArgs(stripe);
      const idem = `tr-co:inv1:12000:n:${BUCKET}`;
      assert.equal(params.line_items.length, 1);
      assert.equal('tr_tip_cents' in params.metadata, false);
      assert.equal(params.metadata.tr_idem, idem);
      assert.equal(opts.idempotencyKey, idem);
      w.restore();
      w = null;
    }
  });

  test('a tipCents of 0 or null still goes through when tips are off', async () => {
    w = W.world();
    assert.equal((await call({ t: pTok(), tipCents: 0 })).status, 200);
    assert.equal((await call({ t: pTok(), tipCents: null })).status, 200);
  });

  test('tips turned off since the page loaded → 409 tips_off before any Stripe call', async () => {
    for (const tipsEnabled of [undefined, false, null, 'true', 1]) {
      w = W.world({ settings: [W.settingsRow(tipsEnabled === undefined ? {} : { tipsEnabled })] });
      const res = await call({ t: pTok(), tipCents: 1800 });
      assert.deepEqual([res.status, res.body.code, res.body.error], [409, 'tips_off', 'Tips are no longer offered. Please reload.'], String(tipsEnabled));
      assert.equal(res.body.businessName, 'Rector HVAC');
      assert.equal(res.stripe.calls.length, 0);
      w.restore();
      w = null;
    }
  });

  test('a tip on a deposit link is refused, including a stale one after the deposit was paid', async () => {
    w = W.world(TIPS_ON());
    const deposit = await call({ t: pTok({ cents: 5000, balanceCents: 12000 }), tipCents: 500 });
    assert.deepEqual([deposit.status, deposit.body.code], [409, 'tips_off']);
    assert.equal(deposit.stripe.calls.length, 0);
    const noB = await call({ t: pTok({ cents: 5000 }), tipCents: 500 });
    assert.deepEqual([noB.status, noB.body.code], [409, 'tips_off']);
    assert.equal(noB.stripe.calls.length, 0);
    w.restore();
    // The deposit landed; the link now asks for the live balance, but it was minted as a deposit.
    w = W.world({ ...TIPS_ON(), invoices: [W.invoiceRow({ amount: 300, payments: [{ id: 'p1', amount: 100, date: '2026-10-02', method: 'stripe' }] })] });
    const afterDeposit = await call({ t: pTok({ cents: 10000, balanceCents: 30000 }), tipCents: 500 });
    assert.deepEqual([afterDeposit.status, afterDeposit.body.code], [409, 'tips_off']);
    assert.equal(afterDeposit.stripe.calls.length, 0);
    // The same link without a tip still pays the live balance.
    const plain = await call({ t: pTok({ cents: 10000, balanceCents: 30000 }) });
    assert.equal(plain.status, 200);
    assert.equal(createArgs(plain.stripe)[0].line_items[0].price_data.unit_amount, 20000);
  });

  test('the tip is capped at the invoice amount being paid: 100% is fine, one cent over is refused', async () => {
    w = W.world(TIPS_ON());
    const over = await call({ t: pTok(), tipCents: 12001 });
    assert.deepEqual([over.status, over.body.code], [400, 'tip_invalid']);
    assert.equal(over.stripe.calls.length, 0);
    const exact = await call({ t: pTok(), tipCents: 12000 });
    assert.equal(exact.status, 200);
    assert.deepEqual(createArgs(exact.stripe)[0].line_items[1], TIP_LINE(12000));
  });

  test('the cap follows the live balance, not the invoice total', async () => {
    w = W.world({ ...TIPS_ON(), invoices: [W.invoiceRow({ payments: [{ id: 'p1', amount: 20, date: '2026-10-02', method: 'cash' }] })] });
    const over = await call({ t: pTok(), tipCents: 10001 });
    assert.deepEqual([over.status, over.body.code], [400, 'tip_invalid']);
    const ok = await call({ t: pTok(), tipCents: 10000 });
    assert.equal(ok.status, 200);
    assert.equal(createArgs(ok.stripe)[0].line_items[0].price_data.unit_amount, 10000);
  });

  test('malformed tipCents (negative, fractional, string, huge, boolean) → 400 tip_invalid, nothing created', async () => {
    w = W.world(TIPS_ON());
    for (const tipCents of [-1, 1.5, '1800', 1e15, true, {}, [], NaN]) {
      const res = await call({ t: pTok(), tipCents });
      assert.deepEqual([res.status, res.body.code], [400, 'tip_invalid'], String(tipCents));
      assert.equal(res.stripe.calls.length, 0);
    }
  });

  test('a page whose amount is stale (baseCents differs from what is charged now) → 409 changed', async () => {
    w = W.world({ ...TIPS_ON(), invoices: [W.invoiceRow({ payments: [{ id: 'p1', amount: 20, date: '2026-10-02', method: 'cash' }] })] });
    const stale = await call({ t: pTok(), tipCents: 1800, baseCents: 12000 });
    assert.deepEqual([stale.status, stale.body.code], [409, 'changed']);
    assert.equal(stale.stripe.calls.length, 0);
    const fresh = await call({ t: pTok(), tipCents: 1800, baseCents: 10000 });
    assert.equal(fresh.status, 200);
  });

  test('the tip rides the idempotency key: a double-click replays, a changed tip mints a new session and expires the old one', async () => {
    w = W.world(TIPS_ON());
    const keyFor = (tip) => `tr-co:inv1:12000:t${tip}:n:${BUCKET}`;
    const a = await call({ t: pTok(), tipCents: 1800 });
    const b = await call({ t: pTok(), tipCents: 1800 });
    assert.equal(createArgs(a.stripe)[1].idempotencyKey, createArgs(b.stripe)[1].idempotencyKey);
    assert.notEqual(keyFor(1800), keyFor(2400));
    const stripe = stripeWith({
      'checkout.sessions.list': async () => ({
        data: [
          { id: 'cs_tip_1800', metadata: { invoiceId: 'inv1', tr_idem: keyFor(1800) } },
          { id: 'cs_no_tip', metadata: { invoiceId: 'inv1', tr_idem: `tr-co:inv1:12000:n:${BUCKET}` } },
        ],
        has_more: false,
      }),
    });
    const changed = await call({ t: pTok(), tipCents: 2400 }, { stripe });
    assert.equal(changed.status, 200);
    assert.equal(createArgs(stripe)[1].idempotencyKey, keyFor(2400));
    assert.equal(createArgs(stripe)[0].metadata.tr_idem, keyFor(2400));
    assert.deepEqual(stripe.callsTo('checkout.sessions.expire').map((c) => c.args[0]), ['cs_tip_1800', 'cs_no_tip']);
  });

  test('the re-minted replay keeps the tip line and metadata', async () => {
    w = W.world(TIPS_ON());
    let n = 0;
    const stripe = stripeWith({
      'checkout.sessions.create': async () => {
        n += 1;
        return n === 1 ? { id: 'cs_old', status: 'expired', url: 'x' } : { id: 'cs_new', status: 'open', url: 'https://checkout.stripe.com/c/pay/cs_new' };
      },
    });
    const res = await call({ t: pTok(), tipCents: 1800 }, { stripe });
    assert.equal(res.body.url, 'https://checkout.stripe.com/c/pay/cs_new');
    const [, second] = stripe.callsTo('checkout.sessions.create');
    assert.equal(second.args[1].idempotencyKey, `tr-co:inv1:12000:t1800:n:${BUCKET}:rcs_old`);
    assert.equal(second.args[0].line_items[1].price_data.unit_amount, 1800);
    assert.equal(second.args[0].metadata.tr_tip_cents, '1800');
  });

  test('a client-supplied tip price or label is ignored; only tipCents counts', async () => {
    w = W.world(TIPS_ON());
    const { stripe } = await call({ t: pTok(), tipCents: 500, tip: 99999, tipName: 'x', line_items: [{ price: 'price_x' }], tr_tip_cents: '9' });
    const [params] = createArgs(stripe);
    assert.deepEqual(params.line_items[1], TIP_LINE(500));
    assert.equal(params.metadata.tr_tip_cents, '500');
  });

  test('with the autopay box ticked the tip rides this payment only; the authorization stays the plan amount', async () => {
    w = W.world(TIPS_ON());
    const { status, stripe } = await call({ t: pTok(), tipCents: 1800, autopay: optIn() });
    assert.equal(status, 200);
    const [params] = createArgs(stripe);
    assert.equal(params.line_items.length, 2);
    assert.equal(params.metadata.tr_tip_cents, '1800');
    assert.equal(params.payment_intent_data.setup_future_usage, 'off_session');
    const [e] = w.db.rows('autopay_enrollments');
    assert.equal(e.max_amount_cents, 12000);
    assert.equal(e.consent_text.includes('18.00'), false);
  });
});

// Phase 28 review fixes (tips spec §13): Stripe replays the CACHED create
// response for a repeated key, so a replayed session may be dead; and a
// payment that completed but isn't booked yet must block a second checkout.
// `fakeCheckoutSessions` models both (replayed `open` response, live status).
describe('pay checkout — replayed sessions and unbooked payments (Phase 28 review)', () => {
  const TIPS_ON = () => ({ settings: [W.settingsRow({ tipsEnabled: true })] });
  const stripeFor = (cs) => fakeStripe({ ...cs.handlers, 'customers.create': async () => ({ id: 'cus_new' }) });
  const urlOf = (res) => res.body.url;
  const liveByUrl = (cs, res) => [...cs.sessions.values()].find((x) => x.url === urlOf(res));

  test('tip A -> B -> A inside one bucket lands on a LIVE session, and only one stays open', async () => {
    w = W.world(TIPS_ON());
    const cs = fakeCheckoutSessions();
    const stripe = stripeFor(cs);
    const a1 = await call({ t: pTok(), tipCents: 1800 }, { stripe });
    const b = await call({ t: pTok(), tipCents: 2400 }, { stripe });
    const a2 = await call({ t: pTok(), tipCents: 1800 }, { stripe });
    for (const r of [a1, b, a2]) assert.equal(r.status, 200);
    // The cached replay of A's key says "open"; the live A was expired by B.
    assert.equal(liveByUrl(cs, a1).status, 'expired');
    assert.equal(liveByUrl(cs, b).status, 'expired');
    const live = liveByUrl(cs, a2);
    assert.equal(live.status, 'open');
    assert.notEqual(urlOf(a2), urlOf(a1));
    assert.equal(live.metadata.tr_tip_cents, '1800');
    assert.deepEqual(cs.open().map((x) => x.id), [live.id]);
  });

  test('A -> B -> A -> B -> A keeps landing on a live session (a re-minted key is not reused blindly)', async () => {
    w = W.world(TIPS_ON());
    const cs = fakeCheckoutSessions();
    const stripe = stripeFor(cs);
    let last;
    for (const tipCents of [1800, 2400, 1800, 2400, 1800, 2400, 1800]) {
      last = await call({ t: pTok(), tipCents }, { stripe });
      assert.equal(last.status, 200);
      assert.equal(liveByUrl(cs, last).status, 'open', `tip ${tipCents}`);
      assert.equal(cs.open().length, 1);
    }
    assert.equal(liveByUrl(cs, last).metadata.tr_tip_cents, '1800');
  });

  test('an identical double-submit still yields exactly one session', async () => {
    w = W.world(TIPS_ON());
    const cs = fakeCheckoutSessions();
    const stripe = stripeFor(cs);
    const [x, y] = await Promise.all([call({ t: pTok(), tipCents: 1800 }, { stripe }), call({ t: pTok(), tipCents: 1800 }, { stripe })]);
    const z = await call({ t: pTok(), tipCents: 1800 }, { stripe, nowMs: NOW_MS + 60_000 });
    assert.equal(urlOf(x), urlOf(y));
    assert.equal(urlOf(x), urlOf(z));
    assert.equal(cs.sessions.size, 1);
    assert.equal(cs.open().length, 1);
  });

  test('a double-submit of the re-minted tip (after A -> B) also yields one session', async () => {
    w = W.world(TIPS_ON());
    const cs = fakeCheckoutSessions();
    const stripe = stripeFor(cs);
    await call({ t: pTok(), tipCents: 1800 }, { stripe });
    await call({ t: pTok(), tipCents: 2400 }, { stripe });
    const x = await call({ t: pTok(), tipCents: 1800 }, { stripe });
    const y = await call({ t: pTok(), tipCents: 1800 }, { stripe });
    assert.equal(urlOf(x), urlOf(y));
    assert.equal(liveByUrl(cs, y).status, 'open');
    assert.equal(cs.open().length, 1);
    assert.equal(cs.sessions.size, 3);
  });

  test('a replayed session that completed meanwhile is never handed out → 409 maybe_paid', async () => {
    w = W.world();
    const stripe = stripeWith({
      'checkout.sessions.create': async () => ({ id: 'cs_cached', status: 'open', url: 'x' }),
      'checkout.sessions.retrieve': async () => ({ id: 'cs_cached', status: 'complete' }),
    });
    assert.equal((await call({ t: pTok() }, { stripe })).body.code, 'maybe_paid');
  });

  test('a failed live-status read falls back to the create response', async () => {
    w = W.world();
    const stripe = stripeWith({ 'checkout.sessions.retrieve': async () => { throw stripeError('boom'); } });
    const res = await call({ t: pTok() }, { stripe });
    assert.equal(res.status, 200);
  });

  test('a session that stays expired after the re-mints is an error, never an expired URL', async () => {
    w = W.world();
    let n = 0;
    const stripe = stripeWith({ 'checkout.sessions.create': async () => ({ id: `cs_dead_${(n += 1)}`, status: 'expired', url: 'x' }) });
    await assert.rejects(() => call({ t: pTok() }, { stripe }), /still expired/);
  });

  const unbooked = (over = {}) => ({ id: 'cs_paid', status: 'complete', metadata: { invoiceId: 'inv1' }, ...over });
  const completeList = (data) => async (params) => ({ data: params.status === 'complete' ? data : [], has_more: false });

  test('a completed session not yet in the ledger refuses a new checkout: 409 in_flight, no session created', async () => {
    w = W.world(TIPS_ON());
    const stripe = stripeWith({ 'checkout.sessions.list': completeList([unbooked()]) });
    const res = await call({ t: pTok(), tipCents: 2400 }, { stripe });
    assert.deepEqual([res.status, res.body.code], [409, 'in_flight']);
    assert.match(res.body.error, /being processed/);
    assert.equal(stripe.callsTo('checkout.sessions.create').length, 0);
    assert.equal(w.db.rows('autopay_enrollments').length, 0);
    // Scoped like the sweep: the complete list, on the owner's account, last 8 days, after the open pass.
    const lists = stripe.callsTo('checkout.sessions.list');
    assert.deepEqual(lists.map((c) => c.args[0].status), ['open', 'complete']);
    assert.deepEqual(lists[1].args[0], { status: 'complete', created: { gte: Math.floor(NOW_MS / 1000) - 8 * 86400 }, limit: 100 });
    assert.deepEqual(lists[1].args[1], { stripeAccount: ACCOUNT });
  });

  test('a paid-with-tip session not yet booked blocks a second checkout with any tip (or none)', async () => {
    w = W.world(TIPS_ON());
    const cs = fakeCheckoutSessions();
    const stripe = stripeFor(cs);
    const first = await call({ t: pTok(), tipCents: 1800 }, { stripe });
    cs.complete(liveByUrl(cs, first).id); // paid; the webhook hasn't booked it
    for (const tipCents of [undefined, 0, 1800, 2400]) {
      const res = await call({ t: pTok(), ...(tipCents === undefined ? {} : { tipCents }) }, { stripe });
      assert.deepEqual([res.status, res.body.code], [409, 'in_flight'], String(tipCents));
    }
    assert.equal(cs.sessions.size, 1);
  });

  test("another invoice's completed session does not block this one", async () => {
    w = W.world();
    const stripe = stripeWith({ 'checkout.sessions.list': completeList([unbooked({ metadata: { invoiceId: 'inv2' } })]) });
    assert.equal((await call({ t: pTok() }, { stripe })).status, 200);
  });

  test('a completed session that IS booked (stripe_<id> in the ledger) does not block a payment of the remaining balance', async () => {
    w = W.world({ invoices: [W.invoiceRow({ payments: [{ id: 'stripe_cs_paid', amount: 50, date: '2026-10-03', method: 'stripe', stripeSessionId: 'cs_paid', tipAmount: 9 }] })] });
    const stripe = stripeWith({ 'checkout.sessions.list': completeList([unbooked()]) });
    const res = await call({ t: pTok() }, { stripe });
    assert.equal(res.status, 200);
    assert.equal(stripe.callsTo('checkout.sessions.create')[0].args[0].line_items[0].price_data.unit_amount, 7000);
  });

  test('a booked session does not hide an unbooked one on the same invoice', async () => {
    w = W.world({ invoices: [W.invoiceRow({ payments: [{ id: 'stripe_cs_paid', amount: 50, date: '2026-10-03', method: 'stripe' }] })] });
    const stripe = stripeWith({ 'checkout.sessions.list': completeList([unbooked(), unbooked({ id: 'cs_second' })]) });
    assert.equal((await call({ t: pTok() }, { stripe })).body.code, 'in_flight');
  });

  test('a Stripe error listing completed sessions is not treated as clear', async () => {
    w = W.world();
    const stripe = stripeWith({
      'checkout.sessions.list': async (params) => {
        if (params.status === 'complete') throw stripeError('boom');
        return { data: [], has_more: false };
      },
    });
    await assert.rejects(() => call({ t: pTok() }, { stripe }), /boom/);
    assert.equal(stripe.callsTo('checkout.sessions.create').length, 0);
  });
});
