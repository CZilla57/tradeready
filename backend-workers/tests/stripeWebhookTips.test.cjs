// Webhook tip split (Phase 28, tips spec §4.3, §4.4, §8): a pay-page session
// with a "Tip" line books ONE ledger entry, amount = the invoice portion and
// tipAmount = the tip, split only from the server-set metadata that adds up
// exactly to amount_total. Legacy sessions and mismatches book the whole
// amount as before. paid/paidAt come from `amount` only. The receipt itemizes
// once, on the 'appended' outcome. Fake Stripe + fake Supabase; no network.

const assert = require('node:assert/strict');
const { before, afterEach, describe, mock, test } = require('node:test');
const { fakeStripe, fakeC } = require('./helpers/fakes.cjs');
const W = require('./helpers/autopayWorld.cjs');

const { ACCOUNT, ENV } = W;
const TODAY = new Date().toISOString().split('T')[0];

let createStripeWebhookHandler;
before(async () => {
  ({ createStripeWebhookHandler } = await import('../src/routes/stripe/webhook.js'));
});

let w;
afterEach(() => {
  mock.restoreAll();
  if (w) w.restore();
  w = null;
});

function stripeWith(over = {}) {
  return fakeStripe({
    'paymentIntents.retrieve': async () => ({ id: 'pi_1', status: 'succeeded', latest_charge: { payment_method_details: { card: { brand: 'visa', last4: '4242' } } } }),
    'paymentLinks.update': async (id) => ({ id, active: false }),
    ...over,
  });
}

// A paid pay-page session: $120.00 invoice + $18.00 tip by default.
function tipEvent({ amountTotal = 13800, metadata = {}, session = {} } = {}) {
  return {
    id: 'evt_1', type: 'checkout.session.completed', account: ACCOUNT,
    data: { object: {
      id: 'cs_1', mode: 'payment', status: 'complete', payment_status: 'paid', amount_total: amountTotal,
      payment_intent: 'pi_1', customer_details: { email: 'payer@example.com' },
      metadata: { invoiceId: 'inv1', tr_kind: 'invoice', tr_invoice_cents: '12000', tr_tip_cents: '1800', ...metadata },
      ...session,
    } },
  };
}

async function deliver(event, stripe = stripeWith()) {
  const handler = createStripeWebhookHandler({ stripeFactory: () => stripe });
  const res = await handler(fakeC({ method: 'POST', rawBody: JSON.stringify(event), headers: { 'stripe-signature': 'valid' }, env: ENV }));
  return { res, stripe };
}

const payments = () => w.db.rows('invoices')[0].data.payments;
const invoice = () => w.db.rows('invoices')[0].data;
const receipts = () => w.emails.filter((m) => m.to[0] === 'payer@example.com');
const mismatchWarnings = () => console.warn.mock.calls.filter((c) => String(c.arguments[0]).includes('tip_split_mismatch'));
const quietWarn = () => mock.method(console, 'warn', () => {});

describe('webhook — tip split', () => {
  test('a tipped session books ONE entry: amount = invoice portion, tipAmount = tip', async () => {
    quietWarn();
    w = W.world();
    const { res } = await deliver(tipEvent());
    assert.deepEqual([res.status, res.body], [200, { received: true }]);
    assert.deepEqual(payments(), [
      { id: 'stripe_cs_1', amount: 120, date: TODAY, method: 'stripe', stripeSessionId: 'cs_1', tipAmount: 18 },
    ]);
    assert.equal(mismatchWarnings().length, 0);
  });

  test('tipAmount is tipCents / 100: 12.34 and 0.5 survive exactly, 1 cent is 0.01', async () => {
    quietWarn();
    for (const [tip, expected] of [[1234, 12.34], [50, 0.5], [1, 0.01]]) {
      w = W.world();
      await deliver(tipEvent({ amountTotal: 12000 + tip, metadata: { tr_tip_cents: String(tip) } }));
      assert.equal(payments()[0].tipAmount, expected, String(tip));
      assert.equal(payments()[0].amount, 120);
      w.restore();
      w = null;
    }
  });

  test('a zero tip omits the key; so does a session with no tr_tip_cents (no tip chosen)', async () => {
    quietWarn();
    for (const metadata of [{ tr_tip_cents: '0' }, { tr_tip_cents: undefined }]) {
      w = W.world();
      await deliver(tipEvent({ amountTotal: 12000, metadata }));
      assert.deepEqual(payments(), [{ id: 'stripe_cs_1', amount: 120, date: TODAY, method: 'stripe', stripeSessionId: 'cs_1' }], JSON.stringify(metadata));
      assert.equal('tipAmount' in payments()[0], false);
      assert.equal(mismatchWarnings().length, 0);
      w.restore();
      w = null;
    }
  });

  test('a legacy Payment Link session (no tr_ keys) books the whole amount_total, no tip, no warning', async () => {
    quietWarn();
    w = W.world();
    const { res } = await deliver(tipEvent({ amountTotal: 12000, metadata: { tr_kind: undefined, tr_invoice_cents: undefined, tr_tip_cents: undefined }, session: { payment_link: 'plink_1' } }));
    assert.equal(res.status, 200);
    assert.deepEqual(payments(), [{ id: 'stripe_cs_1', amount: 120, date: TODAY, method: 'stripe', stripeSessionId: 'cs_1' }]);
    assert.equal(mismatchWarnings().length, 0);
    assert.equal(w.emails.length, 0, 'legacy link sessions get no TradeReady receipt');
  });

  test('a mismatch books the whole amount_total as the invoice payment and logs tip_split_mismatch', async () => {
    const cases = [
      ['parts do not add up', { amountTotal: 13900 }],
      ['tip metadata is not a number', { metadata: { tr_tip_cents: 'abc' } }],
      ['negative tip metadata', { metadata: { tr_tip_cents: '-100' } }],
      ['fractional tip metadata', { metadata: { tr_tip_cents: '18.5' } }],
      ['invoice metadata missing', { metadata: { tr_invoice_cents: undefined } }],
      ['invoice metadata zero', { amountTotal: 1800, metadata: { tr_invoice_cents: '0' } }],
      ['amount_total missing', { session: { amount_total: undefined } }],
    ];
    for (const [label, over] of cases) {
      mock.method(console, 'warn', () => {});
      w = W.world();
      const event = tipEvent(over);
      const total = event.data.object.amount_total;
      await deliver(event);
      if (total === undefined) {
        // Nothing to book: zero-amount guard, nothing written.
        assert.equal(w.db.rows('invoices')[0].data.payments, undefined, label);
      } else {
        assert.deepEqual(payments(), [{ id: 'stripe_cs_1', amount: total / 100, date: TODAY, method: 'stripe', stripeSessionId: 'cs_1' }], label);
      }
      assert.equal(mismatchWarnings().length, 1, label);
      assert.match(String(mismatchWarnings()[0].arguments[0]), /cs_1/);
      mock.restoreAll();
      w.restore();
      w = null;
    }
  });
});

describe('webhook — paid is derived from the invoice portion only', () => {
  test('an invoice paid exactly, with a tip on top, is paid and not overpaid', async () => {
    quietWarn();
    w = W.world();
    await deliver(tipEvent());
    assert.equal(invoice().paid, true);
    assert.equal(invoice().paidAt, TODAY);
    const { amountPaid, balanceDue } = require('../lib/paymentMath.js');
    assert.equal(amountPaid(invoice()), 120);
    assert.equal(balanceDue(invoice()), 0);
  });

  test('a partial payment with a tip leaves the invoice unpaid; the tip does not reduce the balance', async () => {
    quietWarn();
    w = W.world({ invoices: [W.invoiceRow({ amount: 300 })] });
    await deliver(tipEvent());
    assert.equal(invoice().paid, false);
    assert.equal('paidAt' in invoice(), false);
    const { balanceDue } = require('../lib/paymentMath.js');
    assert.equal(balanceDue(invoice()), 180);
    assert.match(receipts()[0].text, /Remaining balance: \$180\.00/);
  });

  test('a tip never settles an invoice the invoice portion left short', async () => {
    quietWarn();
    w = W.world({ invoices: [W.invoiceRow({ amount: 130 })] });
    await deliver(tipEvent()); // 120 + 18 tip; total 138 > 130, but only 120 counts
    assert.equal(invoice().paid, false);
  });
});

describe('webhook — tip receipt and redelivery', () => {
  test('the receipt itemizes invoice payment, tip, total, card and the balance', async () => {
    quietWarn();
    w = W.world();
    await deliver(tipEvent());
    assert.equal(receipts().length, 1);
    const [mail] = receipts();
    assert.match(mail.text, /Invoice INV-0042\nInvoice payment: \$120\.00\nTip: \$18\.00\nTotal charged: \$138\.00\nCard: Visa ending 4242\nDate: \d{4}-\d{2}-\d{2}\nThis invoice is now paid in full\./);
    assert.doesNotMatch(mail.text, /Amount paid/);
  });

  test('a tip-less pay-page receipt is the unchanged "Amount paid" text', async () => {
    quietWarn();
    w = W.world();
    await deliver(tipEvent({ amountTotal: 12000, metadata: { tr_tip_cents: undefined } }));
    assert.match(receipts()[0].text, /Amount paid: \$120\.00\nCard: Visa ending 4242/);
    assert.doesNotMatch(receipts()[0].text, /Tip|Total charged/);
  });

  test('a mismatch receipt shows the whole amount, never a guessed split', async () => {
    quietWarn();
    w = W.world();
    await deliver(tipEvent({ amountTotal: 13900 }));
    assert.match(receipts()[0].text, /Amount paid: \$139\.00/);
    assert.doesNotMatch(receipts()[0].text, /Tip:|Total charged/);
  });

  test('duplicate delivery: no second entry, no second receipt, tip kept once', async () => {
    quietWarn();
    w = W.world();
    const stripe = stripeWith();
    await deliver(tipEvent(), stripe);
    const { res } = await deliver(tipEvent(), stripe);
    assert.deepEqual([res.status, res.body], [200, { received: true }]);
    assert.equal(payments().length, 1);
    assert.equal(payments()[0].tipAmount, 18);
    assert.equal(receipts().length, 1);
  });

  test('an ownership skip books neither the payment nor the tip and sends nothing', async () => {
    quietWarn();
    w = W.world();
    const event = tipEvent();
    event.account = 'acct_attacker';
    const { res } = await deliver(event);
    assert.deepEqual(res.body, { received: true, skipped: true });
    assert.equal(w.db.rows('invoices')[0].data.payments, undefined);
    assert.equal(w.emails.length, 0);
  });

  test('a tip on an autopay opt-in checkout: the tip is booked with the payment, the receipt itemizes it', async () => {
    quietWarn();
    const PENDING = W.enrollmentRow({
      id: 'e0000000-0000-4000-8000-0000000000aa', status: 'pending', payment_method_id: null, card_brand: null, card_last4: null,
      card_exp_month: null, card_exp_year: null, billing_email: null, activated_at: null, checkout_session_id: 'cs_1', consent_text: 'consent',
    });
    w = W.world({ enrollments: [PENDING] });
    const stripe = stripeWith({
      'paymentIntents.retrieve': async () => ({
        id: 'pi_1', status: 'succeeded',
        payment_method: { id: 'pm_new', type: 'card', customer: 'cus_1', card: { brand: 'visa', last4: '4242', exp_month: 8, exp_year: 2027 } },
        latest_charge: { payment_method_details: { card: { brand: 'visa', last4: '4242' } } },
      }),
    });
    await deliver(tipEvent({ metadata: { tr_enrollment: PENDING.id } }), stripe);
    assert.equal(payments()[0].tipAmount, 18);
    assert.equal(w.db.rows('autopay_enrollments')[0].max_amount_cents, 12000, 'the authorization never includes a tip');
    assert.match(receipts().find((m) => /^Payment receipt/.test(m.subject)).text, /Tip: \$18\.00/);
  });
});
