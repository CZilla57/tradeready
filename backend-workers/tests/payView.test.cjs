// GET /api/pay/view (Phase 24 spec §4.4): exact keys per kind, the
// paid / unsynced / deleted / disconnected states, deposit vs full, the
// autopay-offer matrix (§2.2), and the session receipt only on a metadata
// match. Fake Supabase + fake Stripe; no network.

const assert = require('node:assert/strict');
const { before, afterEach, describe, test } = require('node:test');
const { fakeStripe, fakeC } = require('./helpers/fakes.cjs');
const W = require('./helpers/autopayWorld.cjs');
const { view } = require('../lib/pay/payService.js');
const { mintInvoicePayToken, mintSetupToken, mintManageToken, verifyPayToken } = require('../lib/pay/payToken.js');
const { renderConsent } = require('../lib/autopay/consentText.js');

const { USER, OTHER_USER, SECRET, ENV } = W;
const NOW_SEC = Math.floor(Date.UTC(2026, 9, 3, 18) / 1000);

let w;
afterEach(() => w && w.restore());

const pTok = (over = {}) => mintInvoicePayToken(SECRET, { userId: USER, invoiceId: 'inv1', ...over });
const viewP = (token, extra = {}) => view(ENV, { stripe: extra.stripe || fakeStripe(), query: { t: token, ...extra.query }, nowSec: NOW_SEC });

const INVOICE_KEYS = ['amountDue', 'autopay', 'businessName', 'depositRequested', 'description', 'due', 'invoiceNumber', 'kind', 'paid', 'paidAt', 'receipt'];
const OFFER_KEYS = ['amount', 'cadence', 'consentText', 'consentVersion', 'isUpdate', 'planDescription'];

describe('pay view — invoice (t)', () => {
  test('unpaid plan invoice: exact keys, live balance, unchecked offer data', async () => {
    w = W.world();
    const res = await viewP(pTok());
    assert.equal(res.status, 200);
    assert.deepEqual(Object.keys(res.body).sort(), INVOICE_KEYS);
    assert.deepEqual(Object.keys(res.body.autopay).sort(), ['active', 'offer']);
    assert.deepEqual(Object.keys(res.body.autopay.offer).sort(), OFFER_KEYS);
    assert.equal(res.body.kind, 'invoice');
    assert.equal(res.body.businessName, 'Rector HVAC');
    assert.equal(res.body.invoiceNumber, 'INV-0042');
    assert.equal(res.body.description, 'November maintenance');
    assert.equal(res.body.amountDue, 120);
    assert.equal(res.body.depositRequested, null);
    assert.equal(res.body.due, '2026-11-01');
    assert.equal(res.body.paid, false);
    assert.equal(res.body.paidAt, null);
    assert.equal(res.body.receipt, null);
    assert.equal(res.body.autopay.active, null);
    assert.deepEqual({ ...res.body.autopay.offer, consentText: undefined }, {
      planDescription: 'Quarterly HVAC maintenance', amount: 120, cadence: 'every month',
      consentText: undefined, consentVersion: 'autopay-consent-v1', isUpdate: false,
    });
  });

  test('the offer carries the approved §2.3 text, verbatim with substitutions', async () => {
    w = W.world();
    const res = await viewP(pTok());
    assert.equal(res.body.autopay.offer.consentText,
      'Pay future invoices for this plan automatically with this card\n\n' +
      'I authorize Rector HVAC to save this card and charge it automatically, without asking me each time, for invoices under my ' +
      '"Quarterly HVAC maintenance" plan ($120.00 every month). Each charge is made on the invoice\'s due date, including any unpaid ' +
      'invoice under this plan that comes due after today, and is never more than $120.00 unless I approve a new amount. ' +
      "I'll get an email receipt for every charge. I can turn off automatic payments at any time using the link in any receipt, " +
      'from my customer portal, or by contacting Rector HVAC. Turning it off stops future charges. My card details are stored by ' +
      "Stripe, Rector HVAC's payment processor; Rector HVAC sees only the card brand, last four digits and expiry date.");
  });

  test('nothing private crosses the wire', async () => {
    w = W.world({ invoices: [W.invoiceRow({ address: '1 Main St', phone: '555-0199', notes: 'gate code 1234' })], enrollments: [W.enrollmentRow({ max_amount_cents: 10000 })] });
    const flat = JSON.stringify((await viewP(pTok())).body);
    for (const secret of ['pat@example.com', 'Pat Lee', '1 Main St', '555-0199', 'gate code', 'cus_', 'pm_', 'acct_', 'c1', USER, '203.0.113']) {
      assert.equal(flat.includes(secret), false, secret);
    }
  });

  test('paid: "Paid on" date from paidAt or the last live payment; no offer', async () => {
    w = W.world({ invoices: [W.invoiceRow({ payments: [{ id: 'p1', amount: 120, date: '2026-10-02', method: 'cash' }, { id: 'p0', amount: 5, date: '2026-10-05', method: 'cash', voidedAt: '2026-10-06' }] })] });
    const res = await viewP(pTok());
    assert.equal(res.status, 200);
    assert.equal(res.body.paid, true);
    assert.equal(res.body.paidAt, '2026-10-02');
    assert.equal(res.body.amountDue, 0);
    assert.equal(res.body.autopay, null);
  });

  test('paid still shows when the owner disconnected Stripe', async () => {
    w = W.world({ accounts: [], invoices: [W.invoiceRow({ paid: true, paidAt: '2026-10-01' })] });
    const res = await viewP(pTok());
    assert.equal(res.status, 200);
    assert.equal(res.body.paid, true);
  });

  test('not synced yet → 409 not_ready naming the business', async () => {
    w = W.world({ invoices: [] });
    const res = await viewP(pTok());
    assert.deepEqual([res.status, res.body.code, res.body.businessName], [409, 'not_ready', 'Rector HVAC']);
  });

  test("another owner's invoice id → 404 invalid (the token binds the owner)", async () => {
    w = W.world({ invoices: [W.invoiceRow({}, { user_id: OTHER_USER })] });
    const res = await viewP(pTok());
    assert.deepEqual([res.status, res.body.code], [404, 'invalid']);
    assert.equal(res.body.businessName, undefined);
  });

  test('deleted → 410 gone; disconnected → 410 unavailable', async () => {
    w = W.world({ invoices: [W.invoiceRow({}, { deleted: true })] });
    assert.deepEqual([(await viewP(pTok())).status, (await viewP(pTok())).body.code], [410, 'gone']);
    w.restore();
    w = W.world({ accounts: [] });
    const res = await viewP(pTok());
    assert.deepEqual([res.status, res.body.code, res.body.businessName], [410, 'unavailable', 'Rector HVAC']);
  });

  test('bad, forged or missing tokens → 404 invalid without a lookup', async () => {
    w = W.world();
    for (const tok of ['garbage', pTok().slice(0, -3) + 'abc', mintManageToken(SECRET, { userId: USER, enrollmentId: '6f1c2a4e-1d2b-4c3d-8e9f-0a1b2c3d4e5f' })]) {
      const res = await view(ENV, { stripe: fakeStripe(), query: { t: tok }, nowSec: NOW_SEC });
      assert.deepEqual([res.status, res.body.code], [404, 'invalid']);
    }
    assert.equal(w.net.calls.length, 0);
    const none = await view(ENV, { query: {}, nowSec: NOW_SEC });
    assert.deepEqual([none.status, none.body.code], [400, 'bad_request']);
    const noSecret = await view({ ...ENV, PAY_LINK_SIGNING_SECRET: '' }, { query: { t: pTok() }, nowSec: NOW_SEC });
    assert.deepEqual([noSecret.status, noSecret.body.code], [404, 'invalid']);
  });

  test('deposit link: depositRequested, and never an autopay offer', async () => {
    w = W.world({ enrollments: [W.enrollmentRow()] });
    const res = await viewP(pTok({ cents: 6000 }));
    assert.equal(res.body.amountDue, 120);
    assert.equal(res.body.depositRequested, 60);
    assert.equal(res.body.autopay.offer, null);
    assert.deepEqual(res.body.autopay.active, { card: 'Visa ending 4242' });
  });

  test('a deposit link stops asking for its deposit once a payment has landed', async () => {
    // Minted as a $60 deposit against a $120 balance; $60 has since been paid.
    w = W.world({ invoices: [W.invoiceRow({ payments: [{ id: 'stripe_cs_x', amount: 60, date: '2026-10-02', method: 'stripe' }] })] });
    const res = await viewP(pTok({ cents: 6000, balanceCents: 12000 }));
    assert.equal(res.body.amountDue, 60);
    assert.equal(res.body.depositRequested, null, 'no second deposit');
  });

  test('a link minted before a partial payment asks only for the live balance', async () => {
    w = W.world({ invoices: [W.invoiceRow({ payments: [{ id: 'p1', amount: 20, date: '2026-10-02', method: 'cash' }] })] });
    const res = await viewP(pTok({ cents: 12000 }));
    assert.equal(res.body.amountDue, 100);
    assert.equal(res.body.depositRequested, null);
    // Paying the whole remaining balance is a full-balance payment: autopay is
    // still offered, with the plan amount as the ceiling.
    assert.equal(res.body.autopay.offer.amount, 120);
  });
});

describe('pay view — autopay offer matrix (§2.2)', () => {
  async function offerFor(worldOpts) {
    w = W.world(worldOpts);
    const res = await viewP(pTok());
    w.restore();
    w = null;
    return res.body.autopay;
  }

  test('no recurringInvoiceId → no autopay block', async () => {
    assert.equal(await offerFor({ invoices: [W.invoiceRow({ recurringInvoiceId: undefined })] }), null);
  });
  test('plan missing / deleted / paused / not offering / no customer → no offer', async () => {
    assert.equal(await offerFor({ plans: [] }), null);
    assert.equal(await offerFor({ plans: [W.planRow({}, { deleted: true })] }), null);
    assert.equal(await offerFor({ plans: [W.planRow({ isActive: false })] }), null);
    assert.equal(await offerFor({ plans: [W.planRow({ autopayEnabled: false })] }), null);
    assert.equal(await offerFor({ plans: [W.planRow({ autopayEnabled: undefined })] }), null);
    assert.equal(await offerFor({ plans: [W.planRow({ customerId: '' })] }), null);
  });
  test("an invoice moved to another customer isn't offered", async () => {
    assert.equal(await offerFor({ invoices: [W.invoiceRow({ customerId: 'c2' })] }), null);
  });
  test('an active authorization at or above the plan amount → no offer, card shown', async () => {
    const block = await offerFor({ enrollments: [W.enrollmentRow({ max_amount_cents: 12000 })] });
    assert.deepEqual(block, { offer: null, active: { card: 'Visa ending 4242' } });
  });
  test('an active authorization below the plan amount → "Update automatic payments to $X"', async () => {
    const block = await offerFor({ plans: [W.planRow({ amount: 150 })], invoices: [W.invoiceRow({ amount: 150 })], enrollments: [W.enrollmentRow({ max_amount_cents: 12000 })] });
    assert.equal(block.offer.isUpdate, true);
    assert.equal(block.offer.amount, 150);
    assert.match(block.offer.consentText, /^Update automatic payments to \$150\.00\n\nI authorize Rector HVAC/);
    assert.deepEqual(block.active, { card: 'Visa ending 4242' });
  });
  test("a previous customer's authorization on a reassigned plan doesn't count", async () => {
    const block = await offerFor({ enrollments: [W.enrollmentRow({ customer_id: 'c_old' })] });
    assert.equal(block.offer.isUpdate, false);
    assert.equal(block.active, null);
  });
});

describe('pay view — receipt after Checkout (t + session_id)', () => {
  const session = (over = {}) => ({
    id: 'cs_test_1', mode: 'payment', status: 'complete', payment_status: 'paid', amount_total: 12000,
    metadata: { invoiceId: 'inv1', tr_kind: 'invoice' },
    payment_intent: { id: 'pi_1', latest_charge: { payment_method_details: { card: { brand: 'visa', last4: '4242' } } } },
    ...over,
  });

  test('a matching session → receipt with card and amounts', async () => {
    w = W.world();
    const stripe = fakeStripe({ 'checkout.sessions.retrieve': async () => session({ metadata: { invoiceId: 'inv1', tr_enrollment: 'x' } }) });
    const res = await viewP(pTok(), { stripe, query: { session_id: 'cs_test_1' } });
    assert.deepEqual(res.body.receipt, { status: 'paid', amountPaid: 120, total: 120, cardBrand: 'Visa', last4: '4242', autopay: true });
    const [call] = stripe.callsTo('checkout.sessions.retrieve');
    assert.deepEqual(call.args, ['cs_test_1', { expand: ['payment_intent.latest_charge'] }, { stripeAccount: W.ACCOUNT }]);
  });

  test("another invoice's session reveals nothing", async () => {
    w = W.world();
    const stripe = fakeStripe({ 'checkout.sessions.retrieve': async () => session({ metadata: { invoiceId: 'inv_other' } }) });
    const res = await viewP(pTok(), { stripe, query: { session_id: 'cs_test_1' } });
    assert.equal(res.body.receipt, null);
  });

  test('an async payment still processing reads "processing"; a malformed id is never sent to Stripe', async () => {
    w = W.world();
    const stripe = fakeStripe({ 'checkout.sessions.retrieve': async () => session({ payment_status: 'unpaid' }) });
    assert.equal((await viewP(pTok(), { stripe, query: { session_id: 'cs_test_1' } })).body.receipt.status, 'processing');
    const res = await viewP(pTok(), { stripe, query: { session_id: '../../v1/customers' } });
    assert.equal(res.body.receipt, null);
    assert.equal(stripe.callsTo('checkout.sessions.retrieve').length, 1);
  });

  test('a Stripe error degrades to no receipt, not an error page', async () => {
    w = W.world();
    const stripe = fakeStripe({ 'checkout.sessions.retrieve': async () => { throw new Error('boom'); } });
    const res = await viewP(pTok(), { stripe, query: { session_id: 'cs_test_1' } });
    assert.equal(res.status, 200);
    assert.equal(res.body.receipt, null);
  });
});

describe('pay view — setup (s)', () => {
  const sTok = (over = {}) => mintSetupToken(SECRET, { userId: USER, planId: 'ri1', customerId: 'c1', nowSec: NOW_SEC, ...over });

  test('exact keys and the same authorization text', async () => {
    w = W.world();
    const res = await view(ENV, { query: { s: sTok() }, nowSec: NOW_SEC });
    assert.equal(res.status, 200);
    assert.deepEqual(Object.keys(res.body).sort(), ['amount', 'businessName', 'cadence', 'consentText', 'consentVersion', 'kind', 'planDescription']);
    assert.equal(res.body.kind, 'setup');
    assert.equal(res.body.amount, 120);
    assert.equal(res.body.consentText, renderConsent({ businessName: 'Rector HVAC', planDescription: 'Quarterly HVAC maintenance', amountCents: 12000, cadence: 'monthly' }).text);
  });

  test('expired → 410 expired naming the business', async () => {
    w = W.world();
    const res = await view(ENV, { query: { s: sTok({ nowSec: NOW_SEC - 8 * 86400 }) }, nowSec: NOW_SEC });
    assert.deepEqual([res.status, res.body.code, res.body.businessName], [410, 'expired', 'Rector HVAC']);
  });

  test('plan no longer offerable, or now another customer’s → 404; disconnected → 410', async () => {
    w = W.world({ plans: [W.planRow({ autopayEnabled: false })] });
    assert.equal((await view(ENV, { query: { s: sTok() }, nowSec: NOW_SEC })).status, 404);
    w.restore();
    w = W.world({ plans: [W.planRow({ customerId: 'c2' })] });
    assert.equal((await view(ENV, { query: { s: sTok() }, nowSec: NOW_SEC })).status, 404);
    w.restore();
    w = W.world({ accounts: [] });
    assert.equal((await view(ENV, { query: { s: sTok() }, nowSec: NOW_SEC })).body.code, 'unavailable');
  });
});

describe('pay view — manage (m)', () => {
  const mTok = (enrollmentId, userId = USER) => mintManageToken(SECRET, { userId, enrollmentId });

  test('active: exact keys, card with expiry, a change-card setup link', async () => {
    const e = W.enrollmentRow();
    w = W.world({ enrollments: [e] });
    const res = await view(ENV, { query: { m: mTok(e.id) }, nowSec: NOW_SEC });
    assert.equal(res.status, 200);
    assert.deepEqual(Object.keys(res.body).sort(), ['businessName', 'canTurnOff', 'card', 'kind', 'planDescription', 'setupUrl', 'status']);
    assert.equal(res.body.status, 'on');
    assert.equal(res.body.card, 'Visa ending 4242 (exp 08/27)');
    assert.equal(res.body.canTurnOff, true);
    const s = new URL(res.body.setupUrl).searchParams.get('s');
    assert.deepEqual(verifyPayToken(SECRET, s, { expectKind: 's', nowSec: NOW_SEC }).payload, { v: 1, u: USER, r: 'ri1', c: 'c1', x: NOW_SEC + 7 * 86400 });
  });

  test('revoked: off, no card, cannot turn off again', async () => {
    const e = W.enrollmentRow({ status: 'revoked', revoked_by: 'customer' });
    w = W.world({ enrollments: [e] });
    const res = await view(ENV, { query: { m: mTok(e.id) }, nowSec: NOW_SEC });
    assert.deepEqual([res.body.status, res.body.card, res.body.canTurnOff], ['off', null, false]);
  });

  test('a link to a replaced enrollment shows the current card for the plan', async () => {
    const old = W.enrollmentRow({ status: 'replaced', card_last4: '1111' });
    const cur = W.enrollmentRow({ card_last4: '4444', card_brand: 'mastercard', created_at: '2026-10-02T00:00:00.000Z' });
    w = W.world({ enrollments: [old, cur] });
    const res = await view(ENV, { query: { m: mTok(old.id) }, nowSec: NOW_SEC });
    assert.equal(res.body.card, 'Mastercard ending 4444 (exp 08/27)');
  });

  test("unknown or another owner's enrollment → 404", async () => {
    const e = W.enrollmentRow();
    w = W.world({ enrollments: [e] });
    assert.equal((await view(ENV, { query: { m: mTok('6f1c2a4e-1d2b-4c3d-8e9f-0a1b2c3d4e5f') }, nowSec: NOW_SEC })).status, 404);
    assert.equal((await view(ENV, { query: { m: mTok(e.id, OTHER_USER) }, nowSec: NOW_SEC })).status, 404);
  });
});

describe('pay view route', () => {
  let createPayViewHandler;
  before(async () => {
    ({ createPayViewHandler } = await import('../src/routes/pay/view.js'));
  });

  test('CORS for the public page, no-store, 405, and the per-IP rate limit', async () => {
    w = W.world();
    const handler = createPayViewHandler({ stripeFactory: () => fakeStripe() });
    const pre = await handler(fakeC({ method: 'OPTIONS', headers: { origin: 'https://gettradereadyapp.com' }, env: ENV }));
    assert.equal(pre.status, 200);
    assert.equal(pre.headers['Access-Control-Allow-Origin'], 'https://gettradereadyapp.com');
    assert.equal(pre.headers['Access-Control-Allow-Methods'], 'GET, OPTIONS');
    assert.equal((await handler(fakeC({ method: 'POST', env: ENV }))).status, 405);
    const ok = await handler(fakeC({ method: 'GET', query: { t: pTok() }, env: ENV, headers: { 'cf-connecting-ip': '203.0.113.50' } }));
    assert.equal(ok.status, 200);
    assert.equal(ok.headers['Cache-Control'], 'no-store');
    let last;
    for (let i = 0; i < 60; i++) last = await handler(fakeC({ method: 'GET', query: {}, env: ENV, headers: { 'cf-connecting-ip': '203.0.113.51' } }));
    assert.equal(last.status, 400);
    const limited = await handler(fakeC({ method: 'GET', query: {}, env: ENV, headers: { 'cf-connecting-ip': '203.0.113.51' } }));
    assert.deepEqual([limited.status, limited.body.code], [429, 'rate_limited']);
  });

  test('a Supabase failure → 500 server_error', async () => {
    w = W.world({ failOn: { 'GET settings': 503 } });
    const handler = createPayViewHandler({ stripeFactory: () => fakeStripe() });
    const res = await handler(fakeC({ method: 'GET', query: { t: pTok() }, env: ENV }));
    assert.deepEqual([res.status, res.body.code], [500, 'server_error']);
  });
});
