// The autopay sweep end to end (Phase 24 spec §4.6, §4.7, §4.10) against a
// fake Supabase and a fake Stripe client: success → ledger entry + receipt;
// decline / insufficient funds / authentication_required / expired card →
// fallback email + owner alert (revoking on hard declines); missing card;
// unknown outcome → idempotent replay; the 6 h list fallback; claim
// conflicts between concurrent sweeps; the 'superseded' invoice-email claim.

const assert = require('node:assert/strict');
const { afterEach, describe, test } = require('node:test');
const { fakeStripe, cardError, connectionError, invalidRequest } = require('./helpers/fakes.cjs');
const W = require('./helpers/autopayWorld.cjs');
const { runAutopayCharges } = require('../lib/autopay/runAutopayCharges.js');
const { runQuarterHourly } = require('../lib/cronQuarterHourly.js');
const { verifyPayToken } = require('../lib/pay/payToken.js');

const { USER, ACCOUNT, ENV, SECRET, OWNER_EMAIL } = W;
const OPEN = new Date(Date.UTC(2026, 10, 1, 14, 5)); // due date, window open
const TODAY = () => new Date().toISOString().slice(0, 10); // ledger dates use the real clock

let w;
afterEach(() => w && w.restore());

function pm(over = {}) {
  return { id: 'pm_1', type: 'card', customer: 'cus_1', card: { brand: 'visa', last4: '4242', exp_month: 8, exp_year: 2027 }, ...over };
}

function stripeWith(over = {}) {
  return fakeStripe({
    'checkout.sessions.list': async () => ({ data: [], has_more: false }),
    'checkout.sessions.expire': async (id) => ({ id, status: 'expired' }),
    'paymentMethods.retrieve': async () => pm(),
    'paymentMethods.detach': async (id) => ({ id, customer: null }),
    'paymentIntents.create': async (params) => ({ id: 'pi_1', status: 'succeeded', amount: params.amount, amount_received: params.amount }),
    'paymentIntents.cancel': async (id) => ({ id, status: 'canceled' }),
    ...over,
  });
}

const sweep = (stripe, now = OPEN, env = ENV) => runAutopayCharges(env, { stripeFactory: () => stripe, now });
const charge = () => w.db.rows('autopay_charges')[0];
const enrollment = () => w.db.rows('autopay_enrollments')[0];
const invoiceData = () => w.db.rows('invoices')[0].data;
const customerMail = () => w.emails.filter((e) => e.to[0] !== OWNER_EMAIL);
const ownerMail = () => w.emails.filter((e) => e.to[0] === OWNER_EMAIL);

describe('autopay sweep — success', () => {
  test('charges off-session, books the ledger entry, settles the claim, sends one receipt', async () => {
    w = W.world({ enrollments: [W.enrollmentRow()] });
    const stripe = stripeWith();
    const r = await sweep(stripe);
    assert.equal(r.charged, 1);

    const [create] = stripe.callsTo('paymentIntents.create');
    assert.deepEqual(create.args, [
      {
        amount: 12000, currency: 'usd', customer: 'cus_1', payment_method: 'pm_1', off_session: true, confirm: true,
        payment_method_types: ['card'], description: 'Invoice INV-0042',
        metadata: { invoiceId: 'inv1', source: 'autopay', tr_enrollment: enrollment().id },
      },
      { stripeAccount: ACCOUNT, idempotencyKey: 'tr-autopay:inv1:1' },
    ]);

    assert.deepEqual(invoiceData().payments, [{
      id: 'stripe_pi_1', amount: 120, date: TODAY(), method: 'stripe',
      stripePaymentIntentId: 'pi_1', channel: 'autopay', note: 'Autopay · Visa •••• 4242',
    }]);
    assert.equal(invoiceData().paid, true);

    const c = charge();
    assert.deepEqual([c.status, c.attempt, c.amount_cents, c.payment_intent_id], ['succeeded', 1, 12000, 'pi_1']);
    assert.ok(c.customer_notified_at);

    const [receipt] = customerMail();
    assert.equal(customerMail().length, 1);
    assert.deepEqual(receipt.to, ['pat@example.com']);
    assert.equal(receipt.from, 'Rector HVAC via TradeReady <invoices@gettradereadyapp.com>');
    assert.equal(receipt.reply_to, 'office@rectorhvac.com');
    assert.equal(receipt.subject, 'Automatic payment receipt – Invoice INV-0042');
    assert.match(receipt.text, /paid automatically with your saved card/);
    assert.match(receipt.text, /Amount paid: \$120\.00\nCard: Visa ending 4242/);
    assert.match(receipt.text, /This invoice is now paid in full\./);
    assert.match(receipt.text, /Manage or turn off automatic payments: https:\/\/gettradereadyapp\.com\/pay\.html\?m=m\./);
    assert.equal(ownerMail().length, 0, 'no owner alert on success');
    assert.equal(w.pushes.length, 0);
  });

  test('a second sweep never charges the same invoice again', async () => {
    w = W.world({ enrollments: [W.enrollmentRow()] });
    const stripe = stripeWith();
    await sweep(stripe);
    await sweep(stripe, new Date(OPEN.getTime() + 15 * 60e3));
    assert.equal(stripe.callsTo('paymentIntents.create').length, 1);
    assert.equal(invoiceData().payments.length, 1);
  });

  test('concurrent sweeps: the claim lets exactly one charge through', async () => {
    w = W.world({ enrollments: [W.enrollmentRow()] });
    const stripe = stripeWith();
    await Promise.all([sweep(stripe), sweep(stripe), sweep(stripe)]);
    assert.equal(stripe.callsTo('paymentIntents.create').length, 1);
    assert.equal(w.db.rows('autopay_charges').length, 1);
    assert.equal(customerMail().length, 1);
  });

  test('the card account updater refresh is stored and used in the note', async () => {
    w = W.world({ enrollments: [W.enrollmentRow()] });
    await sweep(stripeWith({ 'paymentMethods.retrieve': async () => pm({ card: { brand: 'visa', last4: '1881', exp_month: 1, exp_year: 2030 } }) }));
    assert.deepEqual([enrollment().card_last4, enrollment().card_exp_month, enrollment().card_exp_year], ['1881', 1, 2030]);
    assert.equal(invoiceData().payments[0].note, 'Autopay · Visa •••• 1881');
  });

  test('a partly paid invoice is charged only its balance', async () => {
    w = W.world({ enrollments: [W.enrollmentRow()], invoices: [W.invoiceRow({ payments: [{ id: 'p0', amount: 70, date: '2026-10-20', method: 'cash' }] })] });
    const stripe = stripeWith();
    await sweep(stripe);
    assert.equal(stripe.callsTo('paymentIntents.create')[0].args[0].amount, 5000);
  });

  test('no Stripe key → the sweep is a no-op', async () => {
    w = W.world({ enrollments: [W.enrollmentRow()] });
    const r = await sweep(stripeWith(), OPEN, { ...ENV, STRIPE_SECRET_KEY: '' });
    assert.equal(r.charged, 0);
    assert.equal(w.net.calls.length, 0);
  });
});

describe('autopay sweep — failures (one attempt, no retry)', () => {
  function decline(code, decline_code) {
    return stripeWith({ 'paymentIntents.create': async () => { throw cardError(code, decline_code, { id: 'pi_failed', status: 'requires_payment_method' }); } });
  }

  async function failWith(stripe) {
    w = W.world({ enrollments: [W.enrollmentRow()] });
    const r = await sweep(stripe);
    return { r, mail: customerMail(), owner: ownerMail() };
  }

  test('generic decline: claim failed, PI canceled, card kept, pay link + owner alert', async () => {
    const stripe = decline('card_declined', 'generic_decline');
    const { r, mail, owner } = await failWith(stripe);
    assert.equal(r.failed, 1);
    const c = charge();
    assert.deepEqual([c.status, c.failure_code, c.decline_code, c.payment_intent_id], ['failed', 'card_declined', 'generic_decline', 'pi_failed']);
    assert.ok(c.customer_notified_at && c.owner_notified_at);
    assert.deepEqual(stripe.callsTo('paymentIntents.cancel').map((x) => x.args[0]), ['pi_failed']);
    assert.equal(enrollment().status, 'active');
    assert.equal(invoiceData().payments, undefined, 'nothing booked');

    assert.equal(mail.length, 1);
    assert.equal(mail[0].subject, 'Action needed: invoice INV-0042 was not paid automatically');
    assert.match(mail[0].text, /but your card was declined\. Nothing was charged\./);
    const payUrl = /You can pay securely here: (\S+)/.exec(mail[0].text)[1];
    const tok = new URL(payUrl).searchParams.get('t');
    assert.deepEqual(verifyPayToken(SECRET, tok, { expectKind: 'p' }).payload, { v: 1, u: USER, i: 'inv1' }, 'full live balance, no fixed amount');
    assert.match(mail[0].text, /tick "pay future invoices automatically"/);
    assert.match(mail[0].text, /Manage automatic payments: https:\/\/gettradereadyapp\.com\/pay\.html\?m=/);

    assert.equal(owner.length, 1);
    assert.equal(owner[0].from, 'TradeReady <payments@gettradereadyapp.com>');
    assert.equal(owner[0].subject, 'Autopay failed: Pat Lee – invoice INV-0042');
    assert.match(owner[0].text, /We emailed them a payment link\./);
    assert.equal(w.pushes.length, 1);
    assert.deepEqual(w.pushes[0].data, { type: 'autopay', invoiceId: 'inv1', recurringInvoiceId: 'ri1' });
    assert.ok(r.autopayHandled.has('inv1'));

    // No automatic retry, ever.
    await sweep(stripe, new Date(OPEN.getTime() + 86400e3));
    assert.equal(stripe.callsTo('paymentIntents.create').length, 1);
  });

  test('insufficient funds is soft: the card stays for the next invoice', async () => {
    const { owner } = await failWith(decline('card_declined', 'insufficient_funds'));
    assert.equal(enrollment().status, 'active');
    assert.match(owner[0].text, /insufficient funds/);
  });

  test('authentication_required: "your bank asked you to confirm this payment", card kept', async () => {
    const { mail } = await failWith(decline('authentication_required', 'authentication_required'));
    assert.match(mail[0].text, /but your bank asked you to confirm this payment\./);
    assert.equal(enrollment().status, 'active');
  });

  test('expired card is hard: revoked (system), card detached, "has expired" copy', async () => {
    const stripe = decline('expired_card', null);
    const { mail, owner } = await failWith(stripe);
    const e = enrollment();
    assert.deepEqual([e.status, e.revoked_by, e.revoke_reason], ['revoked', 'system', 'hard_decline']);
    assert.deepEqual(stripe.callsTo('paymentMethods.detach').map((c) => c.args), [['pm_1', {}, { stripeAccount: ACCOUNT }]]);
    assert.match(mail[0].text, /the card on file has expired/);
    assert.match(mail[0].text, /That card has been removed from automatic payments\./);
    assert.doesNotMatch(mail[0].text, /Manage automatic payments/);
    assert.match(owner[0].text, /Their saved card was removed/);
  });

  test('lost / stolen / pickup / invalid account / restricted are hard declines', async () => {
    for (const dc of ['lost_card', 'stolen_card', 'pickup_card', 'invalid_account', 'restricted_card']) {
      await failWith(decline('card_declined', dc));
      assert.equal(enrollment().status, 'revoked', dc);
      w.restore();
      w = null;
    }
  });

  test('a non-card Stripe error is a processing failure, not a hard decline', async () => {
    const { mail } = await failWith(stripeWith({ 'paymentIntents.create': async () => { throw invalidRequest('Amount must be at least 50 cents', 'amount_too_small'); } }));
    assert.equal(charge().failure_code, 'processing_error');
    assert.equal(enrollment().status, 'active');
    assert.match(mail[0].text, /we couldn't process the card/);
  });

  test('missing card: revoked (system), no charge attempt, fallback sent', async () => {
    const stripe = stripeWith({ 'paymentMethods.retrieve': async () => { throw invalidRequest('No such PaymentMethod'); } });
    const { mail } = await failWith(stripe);
    assert.equal(stripe.callsTo('paymentIntents.create').length, 0);
    assert.deepEqual([charge().status, charge().failure_code], ['failed', 'payment_method_missing']);
    assert.deepEqual([enrollment().status, enrollment().revoke_reason], ['revoked', 'payment_method_missing']);
    assert.match(mail[0].text, /the saved card is no longer available/);
  });

  test('a card detached on Stripe (no customer) counts as missing', async () => {
    const stripe = stripeWith({ 'paymentMethods.retrieve': async () => pm({ customer: null }) });
    await failWith(stripe);
    assert.equal(stripe.callsTo('paymentIntents.create').length, 0);
    assert.equal(charge().failure_code, 'payment_method_missing');
  });

  test('no plausible customer email: owner is told the customer was not emailed', async () => {
    w = W.world({ enrollments: [W.enrollmentRow({ billing_email: null })], invoices: [W.invoiceRow({ email: 'not an email' })], customers: [] });
    await sweep(decline('card_declined', 'generic_decline'));
    assert.equal(customerMail().length, 0);
    assert.match(ownerMail()[0].text, /could not email them a payment link/);
  });
});

describe('autopay sweep — the authorized ceiling', () => {
  test('balance above the ceiling: one skipped claim, the fallback, and no Stripe call', async () => {
    w = W.world({ enrollments: [W.enrollmentRow({ max_amount_cents: 10000 })] });
    const stripe = stripeWith();
    const r = await sweep(stripe);
    assert.equal(r.skipped, 1);
    assert.equal(stripe.calls.length, 0, 'no Stripe call at all for a skip');
    assert.deepEqual([charge().status, charge().failure_code, charge().amount_cents], ['skipped', 'amount_above_authorized', 12000]);
    assert.match(customerMail()[0].text, /the amount due \(\$120\.00\) is more than the \$100\.00 you authorized/);
    assert.match(ownerMail()[0].subject, /^Autopay skipped/);
    await sweep(stripe, new Date(OPEN.getTime() + 3600e3));
    assert.equal(w.db.rows('autopay_charges').length, 1, 'once');
    assert.equal(customerMail().length, 1);
  });
});

describe('autopay sweep — unknown outcomes', () => {
  test('a network failure leaves the claim; the next sweep replays the same key and amount', async () => {
    w = W.world({ enrollments: [W.enrollmentRow()] });
    let first = true;
    const stripe = stripeWith({
      'paymentIntents.create': async (params) => {
        if (first) { first = false; throw connectionError(); }
        return { id: 'pi_1', status: 'succeeded', amount: params.amount, amount_received: params.amount };
      },
    });
    const r1 = await sweep(stripe);
    assert.deepEqual([r1.unknown, charge().status], [1, 'claimed']);
    assert.equal(w.emails.length, 0);

    // Too soon (< 5 min): another run may still be working on it.
    await sweep(stripe, new Date(OPEN.getTime() + 2 * 60e3));
    assert.equal(stripe.callsTo('paymentIntents.create').length, 1);

    const r2 = await sweep(stripe, new Date(OPEN.getTime() + 15 * 60e3));
    assert.equal(r2.charged, 1);
    const [a, b] = stripe.callsTo('paymentIntents.create');
    assert.deepEqual(b.args, a.args, 'identical parameters and idempotency key');
    assert.equal(charge().status, 'succeeded');
    assert.equal(invoiceData().payments.length, 1);
    assert.equal(customerMail().length, 1);
  });

  test('Stripe 5xx / 429 are unknown, never declines', async () => {
    const { apiError, stripeError } = require('./helpers/fakes.cjs');
    for (const err of [apiError(500), apiError(503), stripeError('StripeRateLimitError', { statusCode: 429 })]) {
      w = W.world({ enrollments: [W.enrollmentRow()] });
      const r = await sweep(stripeWith({ 'paymentIntents.create': async () => { throw err; } }));
      assert.equal(r.unknown, 1, err.type);
      assert.equal(charge().status, 'claimed');
      assert.equal(w.emails.length, 0);
      w.restore();
      w = null;
    }
  });

  test('a ledger write failure after a successful charge keeps the claim and retries the append', async () => {
    w = W.world({ enrollments: [W.enrollmentRow()], failOn: { 'POST invoices': 500 } });
    const stripe = stripeWith();
    await sweep(stripe);
    assert.deepEqual([charge().status, charge().payment_intent_id], ['claimed', 'pi_1']);
    assert.equal(customerMail().length, 0);
    w.restore();
    // Supabase recovers; the PI is re-read by id (no new create).
    const rows = w.db.tables;
    w = W.world({ enrollments: rows.autopay_enrollments, charges: rows.autopay_charges });
    const stripe2 = stripeWith({ 'paymentIntents.retrieve': async (id) => ({ id, status: 'succeeded', amount: 12000, amount_received: 12000 }) });
    await sweep(stripe2, new Date(OPEN.getTime() + 20 * 60e3));
    assert.equal(stripe2.callsTo('paymentIntents.create').length, 0);
    assert.equal(charge().status, 'succeeded');
    assert.equal(invoiceData().payments[0].id, 'stripe_pi_1');
    assert.equal(customerMail().length, 1);
  });

  test('after 6 h: list the customer’s PaymentIntents — found → booked', async () => {
    const claim = { id: 'c0000000-0000-4000-8000-000000000001', user_id: USER, invoice_id: 'inv1', enrollment_id: null, attempt: 1, amount_cents: 12000, status: 'claimed', created_at: new Date(OPEN.getTime() - 7 * 3600e3).toISOString(), charge_sent_at: new Date(OPEN.getTime() - 7 * 3600e3).toISOString() };
    const e = W.enrollmentRow();
    claim.enrollment_id = e.id;
    w = W.world({ enrollments: [e], charges: [claim] });
    const stripe = stripeWith({
      'paymentIntents.list': async () => ({ data: [{ id: 'pi_other', metadata: { invoiceId: 'inv9', source: 'autopay' } }, { id: 'pi_found', status: 'succeeded', amount: 12000, amount_received: 12000, metadata: { invoiceId: 'inv1', source: 'autopay' } }] }),
    });
    await sweep(stripe);
    const [list] = stripe.callsTo('paymentIntents.list');
    assert.deepEqual(list.args[0], { customer: 'cus_1', created: { gte: Math.floor(Date.parse(claim.created_at) / 1000) - 3600 }, limit: 100 });
    assert.equal(stripe.callsTo('paymentIntents.create').length, 0);
    assert.equal(charge().status, 'succeeded');
    assert.equal(invoiceData().payments[0].id, 'stripe_pi_found');
  });

  test('after 6 h with no PaymentIntent: failed (unknown), owner told to check Stripe, customer not emailed', async () => {
    const e = W.enrollmentRow();
    const claim = { id: 'c0000000-0000-4000-8000-000000000002', user_id: USER, invoice_id: 'inv1', enrollment_id: e.id, attempt: 1, amount_cents: 12000, status: 'claimed', created_at: new Date(OPEN.getTime() - 7 * 3600e3).toISOString(), charge_sent_at: new Date(OPEN.getTime() - 7 * 3600e3).toISOString() };
    w = W.world({ enrollments: [e], charges: [claim] });
    await sweep(stripeWith({ 'paymentIntents.list': async () => ({ data: [] }) }));
    assert.deepEqual([charge().status, charge().failure_code], ['failed', 'unknown']);
    assert.equal(customerMail().length, 0);
    assert.match(ownerMail()[0].subject, /^Check Stripe/);
  });

  test('a claim whose authorization was turned off meanwhile is never replayed as a new charge', async () => {
    for (const sent of [true, false]) {
      const e = W.enrollmentRow({ status: 'revoked', revoked_by: 'customer' });
      const at = new Date(OPEN.getTime() - 30 * 60e3).toISOString();
      const claim = { id: 'c0000000-0000-4000-8000-000000000003', user_id: USER, invoice_id: 'inv1', enrollment_id: e.id, attempt: 1, amount_cents: 12000, status: 'claimed', created_at: at, charge_sent_at: sent ? at : null };
      w = W.world({ enrollments: [e], charges: [claim] });
      const stripe = stripeWith({ 'paymentIntents.list': async () => ({ data: [] }) });
      await sweep(stripe);
      assert.equal(stripe.callsTo('paymentIntents.create').length, 0);
      if (sent) {
        // A create may have reached Stripe: reconciled, never released.
        assert.equal(stripe.callsTo('paymentIntents.list').length, 1);
        assert.equal(charge().failure_code, 'unknown');
      } else {
        // Nothing was ever sent: released without asking Stripe.
        assert.equal(stripe.callsTo('paymentIntents.list').length, 0);
        assert.equal(w.db.rows('autopay_charges').length, 0);
      }
      w.restore();
      w = null;
    }
  });
});

describe('autopay sweep — housekeeping', () => {
  test('a deleted plan revokes (system) and detaches silently; stale pending rows expire', async () => {
    const pending = W.enrollmentRow({ status: 'pending', payment_method_id: null, activated_at: null, recurring_invoice_id: 'ri2', consented_at: new Date(OPEN.getTime() - 50 * 3600e3).toISOString() });
    w = W.world({ enrollments: [W.enrollmentRow(), pending], plans: [W.planRow({}, { deleted: true })] });
    const stripe = stripeWith();
    const r = await sweep(stripe);
    const [active, stale] = w.db.rows('autopay_enrollments');
    assert.deepEqual([active.status, active.revoked_by, active.revoke_reason], ['revoked', 'system', 'plan_removed']);
    assert.deepEqual([stale.status, stale.revoke_reason], ['revoked', 'abandoned']);
    assert.equal(stripe.callsTo('paymentMethods.detach').length, 1);
    assert.equal(stripe.callsTo('paymentIntents.create').length, 0);
    assert.equal(w.emails.length + w.pushes.length, 0, 'silent');
    assert.deepEqual([r.revoked, r.expired], [1, 1]);
  });

  test("a shared card isn't detached while another plan still uses it", async () => {
    const other = W.enrollmentRow({ recurring_invoice_id: 'ri2' });
    w = W.world({ enrollments: [W.enrollmentRow(), other], plans: [W.planRow({}, { deleted: true }), W.planRow({ id: 'ri2' }, { id: 'ri2' })] });
    const stripe = stripeWith();
    await sweep(stripe);
    assert.equal(stripe.callsTo('paymentMethods.detach').length, 0);
  });
});

describe('*/15 tick — invoice emails after autopay', () => {
  const stamp = new Date(OPEN.getTime() - 3600e3).toISOString();

  test("a failure email supersedes the same run's invoice email (one email, not two)", async () => {
    w = W.world({
      enrollments: [W.enrollmentRow()],
      invoices: [W.invoiceRow({ autoEmailRequestedAt: stamp })],
      settings: [W.settingsRow({ autoSendRecurringInvoicesEnabled: true })],
    });
    const stripe = stripeWith({ 'paymentIntents.create': async () => { throw cardError('card_declined', 'generic_decline', { id: 'pi_x' }); } });
    await runQuarterHourly({ ...ENV }, { autopay: (env) => runAutopayCharges(env, { stripeFactory: () => stripe, now: OPEN }) });
    const log = w.db.rows('auto_invoice_email_log');
    assert.deepEqual(log.map((l) => [l.invoice_id, l.status]), [['inv1', 'superseded']]);
    assert.equal(customerMail().length, 1);
    assert.match(customerMail()[0].subject, /^Action needed/);
  });

  test('an invoice an enrollment will charge says so in its email', async () => {
    const early = new Date(Date.UTC(2026, 9, 20, 15));
    w = W.world({
      enrollments: [W.enrollmentRow()],
      // Stamped 30 h ago on the REAL clock (the email sweep reads it): past
      // the PDF grace, inside the 7-day freshness window.
      invoices: [W.invoiceRow({ autoEmailRequestedAt: new Date(Date.now() - 30 * 3600e3).toISOString(), paymentLinkUrl: 'https://gettradereadyapp.com/pay.html?t=p.x.y', paymentLinkAmount: 120 })],
      settings: [W.settingsRow({ autoSendRecurringInvoicesEnabled: true })],
    });
    const stripe = stripeWith();
    const r = await runAutopayCharges(ENV, { stripeFactory: () => stripe, now: early });
    assert.equal(stripe.callsTo('paymentIntents.create').length, 0);
    const { runInvoiceEmails } = require('../lib/sendInvoiceEmails.js');
    await runInvoiceEmails(ENV, r);
    const [mail] = customerMail();
    assert.match(mail.text, /This invoice will be charged automatically to your Visa ending 4242 on 2026-11-01\. Nothing to do\.\nManage automatic payments: https:\/\/gettradereadyapp\.com\/pay\.html\?m=/);
    assert.match(mail.text, /Prefer to pay now with another card\? https:\/\/gettradereadyapp\.com\/pay\.html\?t=p\.x\.y/);
    assert.doesNotMatch(mail.text, /You can pay securely here/);
  });
});

describe('autopay sweep — mutual exclusion with the pay page', () => {
  test("an open pay-page session for the invoice is expired before the charge", async () => {
    w = W.world({ enrollments: [W.enrollmentRow()] });
    const stripe = stripeWith({
      'checkout.sessions.list': async () => ({ data: [{ id: 'cs_customer_tab', metadata: { invoiceId: 'inv1' } }, { id: 'cs_other', metadata: { invoiceId: 'inv2' } }], has_more: false }),
    });
    await sweep(stripe);
    assert.deepEqual(stripe.callsTo('checkout.sessions.expire').map((c) => c.args), [['cs_customer_tab', {}, { stripeAccount: ACCOUNT }]]);
    const order = stripe.calls.map((c) => c.key);
    assert.ok(order.indexOf('checkout.sessions.expire') < order.indexOf('paymentIntents.create'));
    assert.equal(charge().status, 'succeeded');
  });

  test('a session that already completed (the customer just paid) → no charge, claim released, silent', async () => {
    w = W.world({ enrollments: [W.enrollmentRow()] });
    const stripe = stripeWith({
      'checkout.sessions.list': async () => ({ data: [{ id: 'cs_paid', metadata: { invoiceId: 'inv1' } }], has_more: false }),
      'checkout.sessions.expire': async () => { throw invalidRequest('Only Checkout Sessions with a status of open can be expired.'); },
    });
    const r = await sweep(stripe);
    assert.equal(r.yielded, 1);
    assert.equal(stripe.callsTo('paymentIntents.create').length, 0);
    assert.equal(w.db.rows('autopay_charges').length, 0, 'no attempt happened, so no claim stays');
    assert.equal(w.emails.length + w.pushes.length, 0);
  });

  test('an unknown session check charges nothing and releases the never-sent claim (the pay page is not held in_flight)', async () => {
    w = W.world({ enrollments: [W.enrollmentRow()] });
    const stripe = stripeWith({ 'checkout.sessions.list': async () => { throw connectionError(); } });
    const r = await sweep(stripe);
    assert.equal(r.unknown, 1);
    assert.equal(stripe.callsTo('paymentIntents.create').length, 0);
    assert.equal(w.db.rows('autopay_charges').length, 0);
  });
});

// --- Review fixes (2026-10-04): live re-read before every charge, pay-page
// payments not yet booked, and paginated sweep reads. Every case below fails
// on the pre-fix sweep (see spec §13.7).

const LATER = (min) => new Date(OPEN.getTime() + min * 60e3);
const creates = (stripe) => stripe.callsTo('paymentIntents.create').map((c) => c.args[0].amount);
const invoiceRowNow = () => w.db.rows('invoices')[0];

function claimRow(e, over = {}) {
  return {
    id: 'c0000000-0000-4000-8000-0000000000f1', user_id: USER, invoice_id: 'inv1', enrollment_id: e.id, attempt: 1,
    amount_cents: 12000, status: 'claimed', payment_intent_id: null, charge_sent_at: null,
    created_at: new Date(OPEN.getTime() - 30 * 60e3).toISOString(), updated_at: new Date(OPEN.getTime() - 30 * 60e3).toISOString(),
    ...over,
  };
}

// The owner records 70 of 120 in cash, records the full 120, or deletes it.
function changeInvoice(mode) {
  const row = invoiceRowNow();
  if (mode === 'deleted') row.deleted = true;
  else if (mode === 'paid') row.data = { ...row.data, paid: true, payments: [{ id: 'p_cash', amount: 120, date: '2026-11-01', method: 'cash' }] };
  else row.data = { ...row.data, payments: [{ id: 'p_cash', amount: 70, date: '2026-11-01', method: 'cash' }] };
}

// Wraps the fake Supabase: `transform(url, rows)` may rewrite a GET's rows
// (truncation, a dropped row) or throw to answer 500.
function wrapSupabaseGets(transform) {
  const inner = global.fetch;
  global.fetch = async (input, init = {}) => {
    const url = new URL(String(input));
    const isGet = url.origin === ENV.SUPABASE_URL && url.pathname.startsWith('/rest/v1/') && (init.method || 'GET') === 'GET';
    if (!isGet) return inner(input, init);
    let rows;
    try {
      rows = transform(url, null, 'before');
    } catch (err) {
      return new Response(JSON.stringify({ message: err.message }), { status: 500 });
    }
    const res = await inner(input, init);
    if (!res.ok) return res;
    rows = transform(url, await res.json(), 'after');
    return new Response(JSON.stringify(rows), { status: 200, headers: { 'content-type': 'application/json' } });
  };
  const restore = w.restore;
  w.restore = () => { global.fetch = inner; restore(); };
}

describe('autopay sweep — the invoice is re-read before every charge (review P1-1)', () => {
  for (const mode of ['paid', 'part-paid', 'deleted']) {
    test(`a failed pre-charge check, then the invoice is ${mode}: never charged the stale amount`, async () => {
      w = W.world({ enrollments: [W.enrollmentRow()] });
      let first = true;
      const stripe = stripeWith({
        'checkout.sessions.list': async () => { if (first) { first = false; throw connectionError(); } return { data: [], has_more: false }; },
        'paymentIntents.list': async () => ({ data: [] }),
      });
      const r1 = await sweep(stripe);
      assert.equal(r1.unknown, 1);
      assert.deepEqual(creates(stripe), []);
      changeInvoice(mode);
      await sweep(stripe, LATER(15));
      await sweep(stripe, LATER(30));
      if (mode === 'part-paid') {
        assert.deepEqual(creates(stripe), [5000], 'only ever the live balance');
        assert.equal(invoiceData().paid, true);
        assert.deepEqual(invoiceData().payments.map((p) => p.amount), [70, 50]);
        assert.deepEqual(customerMail().map((m) => m.subject), ['Automatic payment receipt – Invoice INV-0042']);
      } else {
        assert.equal(w.emails.length + w.pushes.length, 0, 'silent');
        assert.deepEqual(creates(stripe), []);
        assert.equal(w.db.rows('autopay_charges').length, 0, 'released: no attempt happened');
        if (mode === 'deleted') assert.equal(invoiceRowNow().deleted, true, 'never resurrected');
        else assert.deepEqual(invoiceData().payments.map((p) => p.id), ['p_cash']);
      }
    });

    test(`a claim left by a run that died before charging, invoice ${mode} meanwhile: released, never replayed`, async () => {
      const e = W.enrollmentRow();
      w = W.world({ enrollments: [e], charges: [claimRow(e)] });
      changeInvoice(mode);
      const stripe = stripeWith();
      await sweep(stripe);
      assert.deepEqual(creates(stripe), []);
      assert.equal(stripe.callsTo('paymentIntents.list').length, 0, 'no create was ever sent, so nothing to reconcile');
      assert.equal(w.db.rows('autopay_charges').length, 0);
      if (mode === 'deleted') assert.equal(invoiceRowNow().deleted, true);
      await sweep(stripe, LATER(15));
      assert.deepEqual(creates(stripe), mode === 'part-paid' ? [5000] : []);
    });
  }

  test('a create that may have reached Stripe is never released: reconciled, then failed (unknown) with the owner told', async () => {
    w = W.world({ enrollments: [W.enrollmentRow()] });
    let first = true;
    const stripe = stripeWith({
      'paymentIntents.create': async (params) => {
        if (first) { first = false; throw connectionError(); }
        return { id: 'pi_2', status: 'succeeded', amount: params.amount, amount_received: params.amount };
      },
      'paymentIntents.list': async () => ({ data: [] }),
    });
    await sweep(stripe);
    assert.equal(charge().status, 'claimed');
    changeInvoice('part-paid');
    await sweep(stripe, LATER(15));
    assert.deepEqual(creates(stripe), [12000], 'the stale 120 is never replayed onto a 50 balance');
    assert.ok(charge().charge_sent_at, 'the claim records that a create may have been sent');
    assert.equal(stripe.callsTo('paymentIntents.list').length, 1, 'reconciled with Stripe before standing down');
    assert.deepEqual([charge().status, charge().failure_code], ['failed', 'unknown']);
    assert.equal(customerMail().length, 0);
    assert.match(ownerMail()[0].subject, /^Check Stripe/);
    await sweep(stripe, LATER(30));
    assert.deepEqual(creates(stripe), [12000], 'no new claim, no second charge');
    assert.equal(w.db.rows('autopay_charges').length, 1);
  });

  test('a create that did reach Stripe, invoice paid in cash meanwhile: the charge is booked (not repeated) and the owner warned', async () => {
    w = W.world({ enrollments: [W.enrollmentRow()] });
    let first = true;
    const stripe = stripeWith({
      'paymentIntents.create': async () => { if (first) { first = false; throw connectionError(); } throw new Error('must not replay'); },
      'paymentIntents.list': async () => ({ data: [{ id: 'pi_1', status: 'succeeded', amount: 12000, amount_received: 12000, metadata: { invoiceId: 'inv1', source: 'autopay' } }] }),
    });
    await sweep(stripe);
    changeInvoice('paid');
    await sweep(stripe, LATER(15));
    assert.equal(stripe.callsTo('paymentIntents.create').length, 1);
    assert.deepEqual([charge().status, charge().payment_intent_id], ['succeeded', 'pi_1']);
    assert.deepEqual(invoiceData().payments.map((p) => p.id), ['p_cash', 'stripe_pi_1']);
    assert.ok(ownerMail().some((m) => /more than the balance/i.test(m.text)), 'owner told about the overpayment');
  });

  test('a create that did reach Stripe, invoice deleted meanwhile: booked on the deleted invoice, which stays deleted, owner warned', async () => {
    w = W.world({ enrollments: [W.enrollmentRow()] });
    let first = true;
    const stripe = stripeWith({
      'paymentIntents.create': async () => { if (first) { first = false; throw connectionError(); } throw new Error('must not replay'); },
      'paymentIntents.list': async () => ({ data: [{ id: 'pi_1', status: 'succeeded', amount: 12000, amount_received: 12000, metadata: { invoiceId: 'inv1', source: 'autopay' } }] }),
    });
    await sweep(stripe);
    changeInvoice('deleted');
    await sweep(stripe, LATER(15));
    assert.equal(stripe.callsTo('paymentIntents.create').length, 1);
    assert.equal(invoiceRowNow().deleted, true, 'never resurrected');
    assert.deepEqual(invoiceData().payments.map((p) => p.id), ['stripe_pi_1'], 'the money is still on record');
    assert.ok(ownerMail().some((m) => /deleted/i.test(m.subject + m.text)), 'owner told a payment landed on a deleted invoice');
  });

  test('the customer turns autopay off mid-sweep (shared card, so it stays attached): nothing is charged', async () => {
    const e1 = W.enrollmentRow();
    const e2 = W.enrollmentRow({ recurring_invoice_id: 'ri2' });
    w = W.world({ enrollments: [e1, e2], plans: [W.planRow(), W.planRow({ id: 'ri2' }, { id: 'ri2' })] });
    const stripe = stripeWith({
      'checkout.sessions.list': async () => {
        // After the sweep's snapshot and claim: the customer's autopay-off.
        const row = w.db.rows('autopay_enrollments').find((x) => x.id === e1.id);
        Object.assign(row, { status: 'revoked', revoked_by: 'customer', revoke_reason: 'customer_turned_off' });
        return { data: [], has_more: false };
      },
    });
    const r = await sweep(stripe);
    assert.deepEqual(creates(stripe), []);
    assert.equal(stripe.callsTo('paymentMethods.detach').length, 0, 'the shared card is still attached on Stripe');
    assert.equal(w.db.rows('autopay_charges').length, 0, 'released');
    assert.equal(r.yielded, 1);
  });
});

describe('autopay sweep — pay-page payment completed but not yet booked (review P1-2)', () => {
  const completed = (over = {}) => ({ id: 'cs_paid', status: 'complete', payment_status: 'paid', amount_total: 12000, metadata: { invoiceId: 'inv1', tr_kind: 'invoice' }, ...over });

  test('a completed session whose webhook has not landed yet → no charge, claim released, a later sweep re-evaluates', async () => {
    w = W.world({ enrollments: [W.enrollmentRow()] });
    const stripe = stripeWith({
      'checkout.sessions.list': async (params) => ({ data: params.status === 'complete' ? [completed()] : [], has_more: false }),
    });
    const r = await sweep(stripe);
    assert.equal(r.yielded, 1);
    assert.deepEqual(creates(stripe), []);
    assert.equal(w.db.rows('autopay_charges').length, 0);
    assert.equal(w.emails.length + w.pushes.length, 0);

    // Still unbooked 15 min later: still no charge.
    await sweep(stripe, LATER(15));
    assert.deepEqual(creates(stripe), []);

    // The webhook books it: the invoice is paid and never charged.
    const row = invoiceRowNow();
    row.data = { ...row.data, paid: true, payments: [{ id: 'stripe_cs_paid', amount: 120, date: '2026-11-01', method: 'stripe', stripeSessionId: 'cs_paid' }] };
    await sweep(stripe, LATER(30));
    assert.deepEqual(creates(stripe), []);
  });

  test('a completed session that is already booked (a deposit) does not block charging the rest', async () => {
    w = W.world({ enrollments: [W.enrollmentRow()], invoices: [W.invoiceRow({ payments: [{ id: 'stripe_cs_dep', amount: 70, date: '2026-10-20', method: 'stripe' }] })] });
    const stripe = stripeWith({
      'checkout.sessions.list': async (params) => ({ data: params.status === 'complete' ? [completed({ id: 'cs_dep', amount_total: 7000 })] : [], has_more: false }),
    });
    await sweep(stripe);
    assert.deepEqual(creates(stripe), [5000]);
  });

  test('a session list that cannot be read to the end never counts as clear', async () => {
    w = W.world({ enrollments: [W.enrollmentRow()] });
    let n = 0;
    const stripe = stripeWith({
      'checkout.sessions.list': async () => ({ data: [{ id: `cs_${++n}`, status: 'open', metadata: { invoiceId: 'other' } }], has_more: true }),
    });
    const r = await sweep(stripe);
    assert.deepEqual(creates(stripe), []);
    assert.equal(r.unknown, 1);
  });
});

describe('autopay sweep — reads are paginated and housekeeping fails closed (review P2)', () => {
  function threePlans() {
    const plans = ['ri1', 'ri2', 'ri3'].map((id) => W.planRow({ id }, { id }));
    const enrollments = plans.map((p) => W.enrollmentRow({ recurring_invoice_id: p.id }));
    const invoices = ['1', '2', '3'].map((n) => W.invoiceRow({ number: `INV-${n}`, recurringInvoiceId: `ri${n}` }, { id: `inv${n}` }));
    return { plans, enrollments, invoices };
  }
  const piPerInvoice = () => stripeWith({
    'paymentIntents.create': async (params) => ({ id: `pi_${params.metadata.invoiceId}`, status: 'succeeded', amount: params.amount, amount_received: params.amount }),
  });

  test('a server row cap smaller than the data (max-rows) skips no due invoice and revokes nothing', async () => {
    w = W.world(threePlans());
    wrapSupabaseGets((url, rows, phase) => (phase === 'after' ? rows.slice(0, 2) : null));
    const stripe = piPerInvoice();
    const r = await sweep(stripe);
    assert.deepEqual(stripe.callsTo('paymentIntents.create').map((c) => c.args[0].metadata.invoiceId).sort(), ['inv1', 'inv2', 'inv3']);
    assert.equal(r.revoked, 0);
    assert.deepEqual(w.db.rows('autopay_enrollments').map((e) => e.status), ['active', 'active', 'active']);
    assert.equal(stripe.callsTo('paymentMethods.detach').length, 0);
  });

  test('a plan missing from a truncated bulk read is confirmed before any revoke', async () => {
    w = W.world(threePlans());
    wrapSupabaseGets((url, rows, phase) => {
      if (phase === 'before' || url.pathname !== '/rest/v1/recurringInvoices' || url.searchParams.get('id') === 'eq.ri2') return rows;
      return rows.filter((p) => p.id !== 'ri2');
    });
    const stripe = piPerInvoice();
    const r = await sweep(stripe);
    assert.equal(r.revoked, 0);
    assert.deepEqual(w.db.rows('autopay_enrollments').map((e) => e.status), ['active', 'active', 'active']);
    assert.equal(stripe.callsTo('paymentMethods.detach').length, 0);
  });

  test('a failed confirmation read fails closed: housekeeping skips, nothing is revoked', async () => {
    w = W.world(threePlans());
    wrapSupabaseGets((url, rows, phase) => {
      if (url.pathname !== '/rest/v1/recurringInvoices') return rows;
      if (url.searchParams.get('id') === 'eq.ri2') throw new Error('boom');
      return phase === 'after' ? rows.filter((p) => p.id !== 'ri2') : rows;
    });
    const stripe = piPerInvoice();
    const r = await sweep(stripe);
    assert.equal(r.revoked, 0);
    assert.equal(w.db.rows('autopay_enrollments').find((e) => e.recurring_invoice_id === 'ri2').status, 'active');
    assert.equal(stripe.callsTo('paymentMethods.detach').length, 0);
  });
});

// --- Re-check follow-ups (2026-10-04, spec §13.7 "Follow-ups").

describe('autopay sweep — re-check follow-ups', () => {
  const { stripeError } = require('./helpers/fakes.cjs');
  const ago = (min) => new Date(OPEN.getTime() - min * 60e3).toISOString();

  test('claims carry their real insert time, not the run start', async () => {
    const e = W.enrollmentRow();
    w = W.world({ enrollments: [e], invoices: [W.invoiceRow(), W.invoiceRow({ number: 'INV-0043' }, { id: 'inv2' })] });
    const stripe = stripeWith({
      'paymentIntents.create': async (params) => {
        if (params.metadata.invoiceId === 'inv1') await new Promise((r) => setTimeout(r, 60));
        return { id: `pi_${params.metadata.invoiceId}`, status: 'succeeded', amount: params.amount, amount_received: params.amount };
      },
    });
    await sweep(stripe);
    const second = w.db.rows('autopay_charges').find((c) => c.invoice_id === 'inv2');
    assert.ok(Date.parse(second.created_at) >= OPEN.getTime() + 50, `created_at ${second.created_at} is the run start`);
    assert.ok(Date.parse(second.charge_sent_at) >= Date.parse(second.created_at));
  });

  test('a stamped claim whose create may still be in flight is not settled failed/unknown', async () => {
    const e = W.enrollmentRow();
    // Claimed long ago, but the create was only stamped a minute ago (another run is mid-create).
    w = W.world({ enrollments: [e], charges: [claimRow(e, { created_at: ago(30), charge_sent_at: ago(1) })] });
    changeInvoice('paid');
    const stripe = stripeWith({ 'paymentIntents.list': async () => ({ data: [] }) });
    const r = await sweep(stripe);
    assert.deepEqual(creates(stripe), []);
    assert.equal(charge().status, 'claimed', 'left for the run that holds it');
    assert.equal(r.unknown, 1);
    assert.equal(w.emails.length + w.pushes.length, 0, 'no wrong alert');
  });

  test('a non-card error on a stamped replay reconciles first: the earlier charge is booked, no pay link', async () => {
    const e = W.enrollmentRow();
    w = W.world({ enrollments: [e], charges: [claimRow(e, { created_at: ago(30), charge_sent_at: ago(30) })] });
    const stripe = stripeWith({
      'paymentIntents.create': async () => { throw stripeError('StripePermissionError', { statusCode: 403, message: 'forbidden' }); },
      'paymentIntents.list': async () => ({ data: [{ id: 'pi_first', status: 'succeeded', amount: 12000, amount_received: 12000, metadata: { invoiceId: 'inv1', source: 'autopay' } }] }),
    });
    await sweep(stripe);
    assert.deepEqual([charge().status, charge().payment_intent_id], ['succeeded', 'pi_first']);
    assert.deepEqual(invoiceData().payments.map((p) => p.id), ['stripe_pi_first']);
    assert.deepEqual(customerMail().map((m) => m.subject), ['Automatic payment receipt – Invoice INV-0042'], 'a receipt, never a pay link');
  });

  test('a non-card error on a stamped replay with no charge on Stripe takes the failed path', async () => {
    const e = W.enrollmentRow();
    w = W.world({ enrollments: [e], charges: [claimRow(e, { created_at: ago(30), charge_sent_at: ago(30) })] });
    const stripe = stripeWith({
      'paymentIntents.create': async () => { throw stripeError('StripePermissionError', { statusCode: 403, message: 'forbidden' }); },
      'paymentIntents.list': async () => ({ data: [] }),
    });
    await sweep(stripe);
    assert.deepEqual([charge().status, charge().failure_code], ['failed', 'processing_error']);
    assert.match(customerMail()[0].subject, /^Action needed/);
  });

  test('an unreachable account: a stamped claim settles unknown after the 6 h window, never before, and is never released', async () => {
    const unreachable = () => { throw stripeError('StripePermissionError', { statusCode: 403, message: 'account deauthorized' }); };
    const stripe = stripeWith({ 'paymentIntents.list': unreachable, 'checkout.sessions.list': unreachable });
    const e = W.enrollmentRow();

    w = W.world({ enrollments: [e], charges: [claimRow(e, { created_at: ago(60), charge_sent_at: ago(60) })] });
    await sweep(stripe);
    assert.equal(charge().status, 'claimed', 'inside the window: wait');
    assert.equal(w.emails.length, 0);
    w.restore();

    w = W.world({ enrollments: [e], charges: [claimRow(e, { created_at: ago(7 * 60), charge_sent_at: ago(7 * 60) })] });
    await sweep(stripe);
    assert.deepEqual([charge().status, charge().failure_code], ['failed', 'unknown'], 'settled, row kept (no new claim possible)');
    assert.equal(customerMail().length, 0);
    assert.match(ownerMail()[0].subject, /^Check Stripe/);
    assert.deepEqual(creates(stripe), []);
  });
});
