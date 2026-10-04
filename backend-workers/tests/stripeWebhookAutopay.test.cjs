// Webhook Phase 24 behavior (spec §4.5): payment-mode and setup-mode
// activation, replacement detaching the old card, ownership checks, receipts
// only on 'appended', and best-effort legacy Payment Link deactivation.
// The handler takes a fake Stripe client through its stripeFactory; its
// constructEventAsync accepts the signature 'valid'.

const assert = require('node:assert/strict');
const { before, afterEach, describe, test } = require('node:test');
const { fakeStripe, fakeC } = require('./helpers/fakes.cjs');
const W = require('./helpers/autopayWorld.cjs');

const { USER, ACCOUNT, ENV, OWNER_EMAIL } = W;

let createStripeWebhookHandler;
before(async () => {
  ({ createStripeWebhookHandler } = await import('../src/routes/stripe/webhook.js'));
});

let w;
afterEach(() => w && w.restore());

const PENDING = () => W.enrollmentRow({
  id: 'e0000000-0000-4000-8000-0000000000aa',
  status: 'pending', payment_method_id: null, card_brand: null, card_last4: null, card_exp_month: null, card_exp_year: null,
  billing_email: null, activated_at: null, checkout_session_id: 'cs_1', consent_text: 'Pay future invoices…\n\nI authorize Rector HVAC…',
  created_at: '2026-10-03T18:00:00.000Z',
});

function pm(over = {}) {
  return { id: 'pm_new', type: 'card', customer: 'cus_1', card: { brand: 'visa', last4: '4242', exp_month: 8, exp_year: 2027, wallet: { type: 'apple_pay' } }, ...over };
}

function stripeWith(over = {}) {
  return fakeStripe({
    'paymentIntents.retrieve': async () => ({ id: 'pi_1', status: 'succeeded', payment_method: pm(), latest_charge: { payment_method_details: { card: { brand: 'visa', last4: '4242' } } } }),
    'setupIntents.retrieve': async () => ({ id: 'seti_1', status: 'succeeded', payment_method: pm() }),
    'paymentMethods.detach': async (id) => ({ id }),
    'paymentLinks.update': async (id) => ({ id, active: false }),
    ...over,
  });
}

function paymentEvent(sessionOver = {}, eventOver = {}) {
  return {
    id: 'evt_1', type: 'checkout.session.completed', account: ACCOUNT, ...eventOver,
    data: { object: {
      id: 'cs_1', mode: 'payment', status: 'complete', payment_status: 'paid', amount_total: 12000,
      payment_intent: 'pi_1', customer_details: { email: 'payer@example.com' },
      metadata: { invoiceId: 'inv1', tr_kind: 'invoice', tr_enrollment: PENDING().id },
      ...sessionOver,
    } },
  };
}

function setupEvent(sessionOver = {}, eventOver = {}) {
  return {
    id: 'evt_2', type: 'checkout.session.completed', account: ACCOUNT, ...eventOver,
    data: { object: {
      id: 'cs_1', mode: 'setup', status: 'complete', payment_status: 'no_payment_required', setup_intent: 'seti_1',
      customer_details: { email: 'saver@example.com' },
      metadata: { tr_kind: 'autopay_setup', tr_enrollment: PENDING().id },
      ...sessionOver,
    } },
  };
}

async function deliver(event, stripe = stripeWith()) {
  const handler = createStripeWebhookHandler({ stripeFactory: () => stripe });
  const res = await handler(fakeC({ method: 'POST', rawBody: JSON.stringify(event), headers: { 'stripe-signature': 'valid' }, env: ENV }));
  return { res, stripe };
}

const enrollmentById = (id) => w.db.rows('autopay_enrollments').find((e) => e.id === id);
const mailTo = (addr) => w.emails.filter((e) => e.to[0] === addr);

describe('webhook — payment-mode activation', () => {
  test('books the payment, activates with card details only, sends receipt + "autopay on"', async () => {
    w = W.world({ enrollments: [PENDING()] });
    const { res, stripe } = await deliver(paymentEvent());
    assert.deepEqual([res.status, res.body], [200, { received: true }]);
    assert.equal(w.db.rows('invoices')[0].data.payments[0].id, 'stripe_cs_1');

    const [retrieve] = stripe.callsTo('paymentIntents.retrieve');
    assert.deepEqual(retrieve.args, ['pi_1', { expand: ['payment_method', 'latest_charge'] }, { stripeAccount: ACCOUNT }]);

    const e = enrollmentById(PENDING().id);
    assert.equal(e.status, 'active');
    assert.ok(e.activated_at);
    assert.deepEqual(
      [e.payment_method_id, e.card_brand, e.card_last4, e.card_exp_month, e.card_exp_year, e.card_wallet, e.billing_email],
      ['pm_new', 'visa', '4242', 8, 2027, 'apple_pay', 'payer@example.com']
    );
    assert.equal(JSON.stringify(e).includes('"number"'), false, 'no card number is ever stored');

    const mails = mailTo('payer@example.com');
    assert.equal(mails.length, 2);
    const on = mails.find((m) => /^Automatic payments are on/.test(m.subject));
    assert.match(on.text, /Automatic payments are on for your "Quarterly HVAC maintenance" plan with Rector HVAC, using your Visa ending 4242\./);
    assert.match(on.text, /This is the authorization you gave on 2026-10-01:\n\nPay future invoices…\n\nI authorize Rector HVAC…/);
    assert.match(on.text, /Manage or turn off automatic payments: https:\/\/gettradereadyapp\.com\/pay\.html\?m=m\./);
    const receipt = mails.find((m) => /^Payment receipt/.test(m.subject));
    assert.match(receipt.text, /Amount paid: \$120\.00\nCard: Visa ending 4242/);
  });

  test('replacement: the prior active enrollment becomes replaced and its card is detached', async () => {
    const old = W.enrollmentRow({ id: 'e0000000-0000-4000-8000-0000000000bb', payment_method_id: 'pm_old' });
    w = W.world({ enrollments: [old, PENDING()] });
    const { stripe } = await deliver(paymentEvent());
    const prior = enrollmentById(old.id);
    assert.deepEqual([prior.status, prior.revoke_reason, prior.revoked_by], ['replaced', 'replaced', null]);
    assert.equal(enrollmentById(PENDING().id).status, 'active');
    assert.deepEqual(stripe.callsTo('paymentMethods.detach').map((c) => c.args), [['pm_old', {}, { stripeAccount: ACCOUNT }]]);
    assert.equal(w.db.rows('autopay_enrollments').filter((e) => e.status === 'active').length, 1);
  });

  test('replacement with the SAME card keeps the card attached', async () => {
    const old = W.enrollmentRow({ id: 'e0000000-0000-4000-8000-0000000000bb', payment_method_id: 'pm_new' });
    w = W.world({ enrollments: [old, PENDING()] });
    const { stripe } = await deliver(paymentEvent());
    assert.equal(stripe.callsTo('paymentMethods.detach').length, 0);
  });

  test('redelivery: no second ledger entry, receipt or confirmation', async () => {
    w = W.world({ enrollments: [PENDING()] });
    const stripe = stripeWith();
    await deliver(paymentEvent(), stripe);
    await deliver(paymentEvent(), stripe);
    assert.equal(w.db.rows('invoices')[0].data.payments.length, 1);
    assert.equal(mailTo('payer@example.com').length, 2);
  });

  test('ownership: a different connected account books nothing and activates nothing', async () => {
    w = W.world({ enrollments: [PENDING()] });
    const { res } = await deliver(paymentEvent({}, { account: 'acct_attacker' }));
    assert.deepEqual(res.body, { received: true, skipped: true });
    assert.equal(enrollmentById(PENDING().id).status, 'pending');
    assert.equal(w.emails.length, 0);
  });

  test("the owner's account changed since consent → not activated", async () => {
    w = W.world({ enrollments: [PENDING()], accounts: [{ user_id: USER, stripe_account_id: ACCOUNT }] });
    w.db.rows('autopay_enrollments')[0].stripe_account_id = 'acct_previous';
    await deliver(paymentEvent());
    assert.equal(enrollmentById(PENDING().id).status, 'pending');
  });

  test('a card attached to another Customer, or a session that is not the enrollment’s, is refused', async () => {
    w = W.world({ enrollments: [PENDING()] });
    await deliver(paymentEvent(), stripeWith({ 'paymentIntents.retrieve': async () => ({ id: 'pi_1', status: 'succeeded', payment_method: pm({ customer: 'cus_someone' }) }) }));
    assert.equal(enrollmentById(PENDING().id).status, 'pending');
    w.restore();
    w = W.world({ enrollments: [PENDING()] });
    await deliver(paymentEvent({ id: 'cs_other' }));
    assert.equal(enrollmentById(PENDING().id).status, 'pending');
  });

  test('a revoked enrollment is never resurrected', async () => {
    w = W.world({ enrollments: [{ ...PENDING(), status: 'revoked', revoked_by: 'system', revoke_reason: 'stripe_disconnected' }] });
    await deliver(paymentEvent());
    assert.equal(enrollmentById(PENDING().id).status, 'revoked');
    assert.equal(mailTo('payer@example.com').filter((m) => /Automatic payments are on/.test(m.subject)).length, 0);
  });

  test('activation errors are logged and still answered 200 (the ledger write already succeeded)', async () => {
    w = W.world({ enrollments: [PENDING()], failOn: { 'GET autopay_enrollments': 500 } });
    const { res } = await deliver(paymentEvent());
    assert.deepEqual([res.status, res.body], [200, { received: true }]);
    assert.equal(w.db.rows('invoices')[0].data.payments.length, 1);
  });
});

describe('webhook — setup-mode activation', () => {
  test('activates from the SetupIntent; nothing is booked', async () => {
    w = W.world({ enrollments: [PENDING()] });
    const { res, stripe } = await deliver(setupEvent());
    assert.deepEqual([res.status, res.body], [200, { received: true }]);
    assert.deepEqual(stripe.callsTo('setupIntents.retrieve')[0].args, ['seti_1', { expand: ['payment_method'] }, { stripeAccount: ACCOUNT }]);
    const e = enrollmentById(PENDING().id);
    assert.deepEqual([e.status, e.payment_method_id, e.billing_email], ['active', 'pm_new', 'saver@example.com']);
    assert.equal(w.db.rows('invoices')[0].data.payments, undefined);
    assert.equal(mailTo('saver@example.com').length, 1);
  });

  test('incomplete or foreign setup sessions are skipped', async () => {
    w = W.world({ enrollments: [PENDING()] });
    assert.deepEqual((await deliver(setupEvent({ status: 'open' }))).res.body, { received: true, skipped: true });
    assert.deepEqual((await deliver(setupEvent({ metadata: {} }))).res.body, { received: true, skipped: true });
    assert.equal(enrollmentById(PENDING().id).status, 'pending');
  });

  test('a failed SetupIntent does not activate', async () => {
    w = W.world({ enrollments: [PENDING()] });
    await deliver(setupEvent(), stripeWith({ 'setupIntents.retrieve': async () => ({ id: 'seti_1', status: 'requires_payment_method', payment_method: null }) }));
    assert.equal(enrollmentById(PENDING().id).status, 'pending');
  });
});

describe('webhook — receipts and legacy links', () => {
  test('a plain pay-page payment gets exactly one receipt', async () => {
    w = W.world();
    await deliver(paymentEvent({ metadata: { invoiceId: 'inv1', tr_kind: 'invoice' } }));
    await deliver(paymentEvent({ metadata: { invoiceId: 'inv1', tr_kind: 'invoice' } }));
    assert.equal(mailTo('payer@example.com').length, 1);
    assert.equal(w.emails.filter((m) => m.to[0] === OWNER_EMAIL).length, 0);
  });

  test('a partial payment receipt shows the remaining balance', async () => {
    w = W.world({ invoices: [W.invoiceRow({ amount: 300 })] });
    await deliver(paymentEvent({ metadata: { invoiceId: 'inv1', tr_kind: 'invoice' } }));
    assert.match(mailTo('payer@example.com')[0].text, /Remaining balance: \$180\.00/);
  });

  test('legacy Payment Link sessions: no receipt, and the link is deactivated', async () => {
    w = W.world();
    const { res, stripe } = await deliver(paymentEvent({ metadata: { invoiceId: 'inv1' }, payment_link: 'plink_1' }));
    assert.equal(res.status, 200);
    assert.equal(w.emails.length, 0);
    assert.deepEqual(stripe.callsTo('paymentLinks.update').map((c) => c.args), [
      ['plink_1', { active: false, inactive_message: 'This invoice has been paid. Thank you!' }, { stripeAccount: ACCOUNT }],
    ]);
  });

  test('deactivation is best-effort: a Stripe error still answers 200', async () => {
    w = W.world();
    const { res } = await deliver(paymentEvent({ metadata: { invoiceId: 'inv1' }, payment_link: 'plink_1' }), stripeWith({ 'paymentLinks.update': async () => { throw new Error('nope'); } }));
    assert.deepEqual([res.status, res.body], [200, { received: true }]);
  });

  test('ownership-skipped legacy sessions are not deactivated', async () => {
    w = W.world();
    const { stripe } = await deliver(paymentEvent({ metadata: { invoiceId: 'inv1' }, payment_link: 'plink_1' }, { account: 'acct_x' }));
    assert.equal(stripe.callsTo('paymentLinks.update').length, 0);
  });
});

describe('webhook — money for a deleted invoice (review fix, spec §13.7)', () => {
  test('is booked on the invoice, which stays deleted, and the owner is alerted', async () => {
    w = W.world({ invoices: [W.invoiceRow({}, { deleted: true })] });
    const { res } = await deliver(paymentEvent({ metadata: { invoiceId: 'inv1', tr_kind: 'invoice' } }));
    assert.deepEqual([res.status, res.body], [200, { received: true }]);
    const row = w.db.rows('invoices')[0];
    assert.equal(row.deleted, true, 'not resurrected');
    assert.deepEqual(row.data.payments.map((p) => [p.id, p.amount]), [['stripe_cs_1', 120]]);
    const [alert] = mailTo(OWNER_EMAIL);
    assert.ok(alert, 'owner alerted');
    assert.match(alert.subject, /deleted invoice INV-0042/);
    assert.match(alert.text, /\$120\.00/);
    assert.equal(w.pushes.length, 1);
  });
});

describe('webhook — booking never writes the deleted flag (re-check follow-up)', () => {
  test('a delete that lands between the read and the write stays deleted', async () => {
    w = W.world();
    const inner = global.fetch;
    global.fetch = async (input, init = {}) => {
      const res = await inner(input, init);
      const u = new URL(String(input));
      if ((init.method || 'GET') === 'GET' && u.pathname === '/rest/v1/invoices' && u.searchParams.get('id') === 'eq.inv1') {
        w.db.rows('invoices')[0].deleted = true; // the owner deletes it now
      }
      return res;
    };
    const restore = w.restore;
    w.restore = () => { global.fetch = inner; restore(); };
    const { res } = await deliver(paymentEvent({ metadata: { invoiceId: 'inv1', tr_kind: 'invoice' } }));
    assert.equal(res.status, 200);
    const row = w.db.rows('invoices')[0];
    assert.equal(row.deleted, true, 'the booking did not undo the delete');
    assert.deepEqual(row.data.payments.map((p) => p.id), ['stripe_cs_1']);
  });
});
