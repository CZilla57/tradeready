// Owner routes (Phase 24 spec §4.8) pinned to the contract in the spec's
// build record §13.1, plus the customer's turn-off (§4.4 autopay-off), the
// disconnect and account-deletion cleanup (§4.11), and the manual cron route.

const assert = require('node:assert/strict');
const { before, afterEach, describe, test } = require('node:test');
const { fakeStripe, fakeC } = require('./helpers/fakes.cjs');
const W = require('./helpers/autopayWorld.cjs');
const { autopayOff } = require('../lib/pay/payService.js');
const { mintManageToken } = require('../lib/pay/payToken.js');

const { USER, OTHER_USER, ACCOUNT, ENV, SECRET, OWNER_EMAIL } = W;
const AUTH = { authorization: 'Bearer user-jwt' };

let autopayStatusHandler;
let createAutopayManageHandler;
let createDisconnectHandler;
let createDeleteAccountHandler;
let cronRunAutopayHandler;
before(async () => {
  ({ autopayStatusHandler } = await import('../src/routes/autopay/status.js'));
  ({ createAutopayManageHandler } = await import('../src/routes/autopay/manage.js'));
  ({ createDisconnectHandler } = await import('../src/routes/stripe/disconnect.js'));
  ({ createDeleteAccountHandler } = await import('../src/routes/deleteAccount.js'));
  ({ cronRunAutopayHandler } = await import('../src/routes/cron.js'));
});

let w;
afterEach(() => w && w.restore());

const stripeWith = (over = {}) => fakeStripe({ 'paymentMethods.detach': async (id) => ({ id }), ...over });

const ENROLLMENT_KEYS = ['activatedAt', 'card', 'consentedAt', 'customerId', 'id', 'maxAmount', 'recurringInvoiceId', 'revokeReason', 'revokedAt', 'revokedBy', 'status'];

describe('GET /api/autopay/status', () => {
  const recent = (days) => new Date(Date.now() - days * 86400e3).toISOString();

  test('the §13.1 shape, key by key; pending/abandoned rows and consent IP/UA never sent', async () => {
    const active = W.enrollmentRow({ card_wallet: 'apple_pay', consented_at: '2026-10-02T12:00:00+00:00', activated_at: '2026-10-02T12:01:07.123456+00:00' });
    const revoked = W.enrollmentRow({ recurring_invoice_id: 'ri2', status: 'revoked', revoked_by: 'customer', revoke_reason: 'customer_turned_off', revoked_at: '2026-10-03T00:00:00Z', consented_at: '2026-09-01T00:00:00Z' });
    const pending = W.enrollmentRow({ status: 'pending', activated_at: null, recurring_invoice_id: 'ri3' });
    const abandoned = W.enrollmentRow({ status: 'revoked', activated_at: null, revoke_reason: 'abandoned', recurring_invoice_id: 'ri4' });
    const other = W.enrollmentRow({ user_id: OTHER_USER });
    const charges = [
      { id: 'a', user_id: USER, invoice_id: 'inv1', enrollment_id: active.id, attempt: 1, amount_cents: 12000, status: 'failed', failure_code: 'card_declined', decline_code: 'insufficient_funds', created_at: recent(1) },
      { id: 'b', user_id: USER, invoice_id: 'inv0', enrollment_id: active.id, attempt: 1, amount_cents: 12000, status: 'succeeded', created_at: recent(30) },
      { id: 'c', user_id: USER, invoice_id: 'old', enrollment_id: active.id, attempt: 1, amount_cents: 12000, status: 'succeeded', created_at: recent(121) },
      { id: 'd', user_id: OTHER_USER, invoice_id: 'x', enrollment_id: other.id, attempt: 1, amount_cents: 1, status: 'succeeded', created_at: recent(1) },
    ];
    w = W.world({ enrollments: [active, revoked, pending, abandoned, other], charges });
    const res = await autopayStatusHandler(fakeC({ method: 'GET', headers: AUTH, env: ENV }));
    assert.equal(res.status, 200);
    assert.deepEqual(Object.keys(res.body).sort(), ['charges', 'enrollments']);
    assert.deepEqual(res.body.enrollments.map((e) => e.id), [active.id, revoked.id]);
    for (const e of res.body.enrollments) assert.deepEqual(Object.keys(e).sort(), ENROLLMENT_KEYS);
    assert.deepEqual(res.body.enrollments[0], {
      id: active.id, recurringInvoiceId: 'ri1', customerId: 'c1', status: 'active',
      card: { brand: 'visa', last4: '4242', expMonth: 8, expYear: 2027, wallet: 'apple_pay' },
      maxAmount: 120, consentedAt: '2026-10-02T12:00:00.000Z', activatedAt: '2026-10-02T12:01:07.123Z',
      revokedAt: null, revokedBy: null, revokeReason: null,
    });
    assert.deepEqual([res.body.enrollments[1].status, res.body.enrollments[1].revokedBy, res.body.enrollments[1].revokeReason], ['revoked', 'customer', 'customer_turned_off']);
    assert.deepEqual(res.body.charges, [
      { invoiceId: 'inv1', status: 'failed', amount: 120, failureReason: 'insufficient_funds', at: charges[0].created_at },
      { invoiceId: 'inv0', status: 'succeeded', amount: 120, failureReason: null, at: charges[1].created_at },
    ]);
    const flat = JSON.stringify(res.body);
    for (const s of ['203.0.113', 'agent', 'pm_1', 'cus_1', ACCOUNT, 'consent text', 'pat@example.com']) assert.equal(flat.includes(s), false, s);
  });

  test('failureReason enum', () => {
    const { normalizeFailureReason: n } = require('../lib/autopay/reasons.js');
    const f = (failure_code, decline_code, status = 'failed') => n({ status, failure_code, decline_code });
    assert.equal(f('authentication_required', 'authentication_required'), 'authentication_required');
    assert.equal(f('card_declined', 'authentication_required'), 'authentication_required');
    assert.equal(f('expired_card', null), 'expired_card');
    assert.equal(f('card_declined', 'insufficient_funds'), 'insufficient_funds');
    assert.equal(f('card_declined', 'lost_card'), 'card_declined');
    assert.equal(f('incorrect_cvc', null), 'card_declined');
    assert.equal(f('payment_method_missing', null), 'payment_method_missing');
    assert.equal(f('processing_error', null), 'processing_error');
    assert.equal(f('amount_above_authorized', null, 'skipped'), 'amount_above_authorized');
    assert.equal(f('unknown', null), 'unknown');
    assert.equal(f(null, null, 'succeeded'), null);
    assert.equal(f(null, null, 'claimed'), null);
  });

  test('auth, method and CORS', async () => {
    w = W.world();
    const pre = await autopayStatusHandler(fakeC({ method: 'OPTIONS', env: ENV }));
    assert.deepEqual([pre.status, pre.headers['Access-Control-Allow-Methods'], pre.headers['Access-Control-Allow-Headers']], [200, 'GET, OPTIONS', 'Content-Type, Authorization']);
    assert.deepEqual((await autopayStatusHandler(fakeC({ method: 'POST', headers: AUTH, env: ENV }))).body, { error: 'Method not allowed', code: 'method_not_allowed' });
    const none = await autopayStatusHandler(fakeC({ method: 'GET', env: ENV }));
    assert.deepEqual([none.status, none.body.code], [401, 'unauthorized']);
    const bad = await autopayStatusHandler(fakeC({ method: 'GET', headers: { authorization: 'Bearer expired' }, env: ENV }));
    assert.deepEqual([bad.status, bad.body.code], [401, 'unauthorized']);
  });

  test('a Supabase error → 500 server_error', async () => {
    w = W.world({ failOn: { 'GET autopay_enrollments': 500 } });
    const res = await autopayStatusHandler(fakeC({ method: 'GET', headers: AUTH, env: ENV }));
    assert.deepEqual([res.status, res.body.code], [500, 'server_error']);
  });
});

describe('POST /api/autopay/manage', () => {
  const manage = (body, stripe = stripeWith()) => createAutopayManageHandler({ stripeFactory: () => stripe })(fakeC({ method: 'POST', body, headers: AUTH, env: ENV }));

  test('remove: revoked by owner, card detached, customer told; the response is the §13.1 shape', async () => {
    const e = W.enrollmentRow();
    w = W.world({ enrollments: [e] });
    const stripe = stripeWith();
    const res = await manage({ action: 'remove', enrollmentId: e.id }, stripe);
    assert.equal(res.status, 200);
    assert.deepEqual(Object.keys(res.body).sort(), ['changed', 'enrollment']);
    assert.equal(res.body.changed, true);
    assert.deepEqual(Object.keys(res.body.enrollment).sort(), ENROLLMENT_KEYS);
    assert.deepEqual([res.body.enrollment.status, res.body.enrollment.revokedBy, res.body.enrollment.revokeReason], ['revoked', 'owner', 'owner_removed']);
    assert.ok(res.body.enrollment.revokedAt);
    assert.deepEqual(stripe.callsTo('paymentMethods.detach').map((c) => c.args), [['pm_1', {}, { stripeAccount: ACCOUNT }]]);
    const [mail] = w.emails;
    assert.deepEqual(mail.to, ['pat@example.com']);
    assert.match(mail.text, /Rector HVAC turned off automatic payments for your "Quarterly HVAC maintenance" plan\./);
  });

  test('idempotent: removing again → 200 changed:false, nothing sent', async () => {
    const e = W.enrollmentRow({ status: 'revoked', revoked_by: 'owner', revoke_reason: 'owner_removed', revoked_at: '2026-10-03T00:00:00Z' });
    w = W.world({ enrollments: [e] });
    const stripe = stripeWith();
    const res = await manage({ action: 'remove', enrollmentId: e.id }, stripe);
    assert.deepEqual([res.status, res.body.changed, res.body.enrollment.status], [200, false, 'revoked']);
    assert.equal(stripe.calls.length, 0);
    assert.equal(w.emails.length, 0);
  });

  test("400 for a bad body; 404 for another owner's or an unknown enrollment", async () => {
    const theirs = W.enrollmentRow({ user_id: OTHER_USER });
    w = W.world({ enrollments: [theirs] });
    for (const body of [null, {}, { action: 'pause', enrollmentId: theirs.id }, { action: 'remove', enrollmentId: 'abc' }]) {
      const res = await manage(body);
      assert.deepEqual([res.status, res.body.code], [400, 'invalid_request'], JSON.stringify(body));
    }
    const res = await manage({ action: 'remove', enrollmentId: theirs.id });
    assert.deepEqual([res.status, res.body], [404, { error: 'Not found', code: 'not_found' }]);
    assert.equal(w.db.rows('autopay_enrollments')[0].status, 'active');
  });

  test('a Stripe detach failure is best-effort: still 200', async () => {
    const e = W.enrollmentRow();
    w = W.world({ enrollments: [e] });
    const res = await manage({ action: 'remove', enrollmentId: e.id }, stripeWith({ 'paymentMethods.detach': async () => { throw new Error('stripe down'); } }));
    assert.deepEqual([res.status, res.body.changed], [200, true]);
  });
});

describe('POST /api/pay/autopay-off (customer)', () => {
  test('turns off, detaches, confirms to the customer and alerts the owner; idempotent', async () => {
    const e = W.enrollmentRow();
    w = W.world({ enrollments: [e] });
    const stripe = stripeWith();
    const m = mintManageToken(SECRET, { userId: USER, enrollmentId: e.id });
    const res = await autopayOff(ENV, { stripe, body: { m } });
    assert.deepEqual([res.status, res.body], [200, { status: 'off', changed: true }]);
    const row = w.db.rows('autopay_enrollments')[0];
    assert.deepEqual([row.status, row.revoked_by, row.revoke_reason], ['revoked', 'customer', 'customer_turned_off']);
    assert.equal(stripe.callsTo('paymentMethods.detach').length, 1);
    const customer = w.emails.filter((x) => x.to[0] === 'pat@example.com');
    assert.match(customer[0].text, /You turned off automatic payments/);
    const owner = w.emails.filter((x) => x.to[0] === OWNER_EMAIL);
    assert.equal(owner[0].subject, 'Pat Lee turned off automatic payments');
    assert.equal(w.pushes[0].title, 'Autopay turned off');

    const again = await autopayOff(ENV, { stripe, body: { m } });
    assert.deepEqual(again.body, { status: 'off', changed: false });
    assert.equal(w.emails.length, 2);
  });

  test('a manage link from before a card change turns off the CURRENT enrollment', async () => {
    const old = W.enrollmentRow({ status: 'replaced', payment_method_id: 'pm_old' });
    const cur = W.enrollmentRow({ payment_method_id: 'pm_cur' });
    w = W.world({ enrollments: [old, cur] });
    const res = await autopayOff(ENV, { stripe: stripeWith(), body: { m: mintManageToken(SECRET, { userId: USER, enrollmentId: old.id }) } });
    assert.equal(res.body.changed, true);
    assert.equal(w.db.rows('autopay_enrollments').find((x) => x.id === cur.id).status, 'revoked');
  });

  test('bad or foreign tokens → 404', async () => {
    const e = W.enrollmentRow();
    w = W.world({ enrollments: [e] });
    assert.equal((await autopayOff(ENV, { body: { m: 'nope' } })).status, 404);
    assert.equal((await autopayOff(ENV, { body: { m: mintManageToken(SECRET, { userId: OTHER_USER, enrollmentId: e.id }) } })).status, 404);
    assert.equal((await autopayOff(ENV, { body: {} })).status, 404);
  });
});

describe('disconnect and account deletion (§4.11)', () => {
  test('disconnect revokes every live enrollment and detaches cards on the old account, then deletes the row', async () => {
    const a = W.enrollmentRow({ payment_method_id: 'pm_a' });
    const b = W.enrollmentRow({ recurring_invoice_id: 'ri2', payment_method_id: 'pm_a' });
    const p = W.enrollmentRow({ recurring_invoice_id: 'ri3', status: 'pending', payment_method_id: null });
    w = W.world({ enrollments: [a, b, p] });
    const stripe = stripeWith();
    const res = await createDisconnectHandler({ stripeFactory: () => stripe })(fakeC({ method: 'POST', headers: AUTH, env: ENV }));
    assert.deepEqual([res.status, res.body], [200, { success: true }]);
    for (const e of w.db.rows('autopay_enrollments')) assert.deepEqual([e.status, e.revoked_by, e.revoke_reason], ['revoked', 'system', 'stripe_disconnected']);
    assert.deepEqual(stripe.callsTo('paymentMethods.detach').map((c) => c.args), [['pm_a', {}, { stripeAccount: ACCOUNT }]], 'each card once');
    assert.equal(w.db.rows('stripe_accounts').length, 0);
    assert.equal(w.emails.length, 0);
  });

  test('a cleanup failure never blocks the disconnect', async () => {
    w = W.world({ enrollments: [W.enrollmentRow()], failOn: { 'GET autopay_enrollments': 500 } });
    const res = await createDisconnectHandler({ stripeFactory: () => stripeWith() })(fakeC({ method: 'POST', headers: AUTH, env: ENV }));
    assert.equal(res.status, 200);
    assert.equal(w.db.rows('stripe_accounts').length, 0);
  });

  test('account deletion detaches saved cards only after the core succeeds', async () => {
    w = W.world({ enrollments: [W.enrollmentRow()] });
    const stripe = stripeWith();
    const ok = { handle: async () => ({ status: 200, body: { success: true } }) };
    const res = await createDeleteAccountHandler({ service: ok, stripeFactory: () => stripe })(fakeC({ method: 'POST', headers: AUTH, env: ENV }));
    assert.equal(res.status, 200);
    assert.deepEqual(stripe.callsTo('paymentMethods.detach').map((c) => c.args), [['pm_1', {}, { stripeAccount: ACCOUNT }]]);
  });

  test('a refused or failed deletion leaves autopay untouched', async () => {
    w = W.world({ enrollments: [W.enrollmentRow()] });
    for (const result of [{ status: 429, body: { error: 'x' } }, { status: 500, body: { error: 'x' } }, { status: 401, body: { error: 'x' } }]) {
      const stripe = stripeWith();
      await createDeleteAccountHandler({ service: { handle: async () => result }, stripeFactory: () => stripe })(fakeC({ method: 'POST', headers: AUTH, env: ENV }));
      assert.equal(stripe.calls.length, 0, String(result.status));
    }
  });

  test('the real deletion core is unchanged and byte-identical with its Vercel twin', () => {
    const fs = require('node:fs');
    const path = require('node:path');
    assert.equal(
      fs.readFileSync(path.join(__dirname, '../lib/accountDeletion.js'), 'utf8'),
      fs.readFileSync(path.join(__dirname, '../../backend/lib/accountDeletion.js'), 'utf8')
    );
  });
});

describe('GET /api/cron/run-autopay', () => {
  test('CRON_SECRET guarded', async () => {
    w = W.world();
    assert.equal((await cronRunAutopayHandler(fakeC({ method: 'GET', env: { ...ENV, CRON_SECRET: '' } }))).status, 500);
    assert.equal((await cronRunAutopayHandler(fakeC({ method: 'GET', env: { ...ENV, CRON_SECRET: 'c' } }))).status, 401);
    const res = await cronRunAutopayHandler(fakeC({ method: 'GET', headers: { authorization: 'Bearer c' }, env: { ...ENV, CRON_SECRET: 'c' } }));
    assert.equal(res.status, 200);
    assert.deepEqual(Object.keys(res.body).sort(), ['charged', 'deferred', 'emailedFallback', 'expired', 'failed', 'revoked', 'scanned', 'skipped', 'unknown', 'yielded']);
  });
});
