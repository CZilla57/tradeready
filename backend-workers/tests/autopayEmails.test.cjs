// Autopay email builders (Phase 24 spec §4.7): deterministic templates,
// header sanitizing, allowlisted links only, plausible recipients only.

const assert = require('node:assert/strict');
const { describe, test } = require('node:test');
const E = require('../lib/autopay/emails.js');

const settings = { businessName: 'Rector HVAC', email: 'office@rectorhvac.com', contactName: 'Chad', phone: '555-0100' };
const PAY = 'https://gettradereadyapp.com/pay.html?t=p.abc.def';
const MANAGE = 'https://gettradereadyapp.com/pay.html?m=m.abc.def';

describe('autopay emails', () => {
  test('deterministic: same input, same output', () => {
    const args = { settings, to: 'pat@example.com', customerName: 'Pat', invoiceNumber: 'INV-1', amountCents: 12000, card: 'Visa ending 4242', remainingCents: 0, date: '2026-11-01', autopay: true, manageUrl: MANAGE };
    assert.deepEqual(E.buildReceiptEmail(args), E.buildReceiptEmail(args));
  });

  test('pay-page receipt: full text', () => {
    const mail = E.buildReceiptEmail({ settings, to: 'pat@example.com', customerName: 'Pat Lee', invoiceNumber: 'INV-1', amountCents: 5000, card: 'Visa ending 4242', remainingCents: 7000, date: '2026-10-03' });
    assert.deepEqual(mail, {
      from: 'Rector HVAC via TradeReady <invoices@gettradereadyapp.com>',
      to: ['pat@example.com'],
      subject: 'Payment receipt – Invoice INV-1',
      text: [
        'Hi Pat Lee,', '', 'Thanks for your payment to Rector HVAC.', '',
        'Invoice INV-1', 'Amount paid: $50.00', 'Card: Visa ending 4242', 'Date: 2026-10-03', 'Remaining balance: $70.00', '',
        'Questions? Just reply to this email or contact Rector HVAC.', '',
        'Best regards,', 'Chad', 'Rector HVAC', '555-0100',
      ].join('\n'),
      reply_to: 'office@rectorhvac.com',
    });
  });

  test('header injection is neutralized in From and Subject', () => {
    const evil = { ...settings, businessName: 'Evil "Co" <x@y.z>\r\nBcc: victim@example.com' };
    const mail = E.buildChargeFailedEmail({ settings: evil, to: 'pat@example.com', invoiceNumber: 'INV-1\r\nBcc: a@b.c', amountCents: 100, reason: 'card_declined', payUrl: PAY });
    assert.doesNotMatch(mail.from, /[\r\n"]|<x@/);
    assert.match(mail.from, / via TradeReady <invoices@gettradereadyapp\.com>$/);
    assert.doesNotMatch(mail.subject, /[\r\n]/);
  });

  test('only allowlisted links survive; a bad link drops the line, never the email', () => {
    const mail = E.buildChargeFailedEmail({ settings, to: 'pat@example.com', invoiceNumber: 'INV-1', amountCents: 100, reason: 'card_declined', payUrl: 'https://evil.example/pay.html?t=x', manageUrl: 'https://gettradereadyapp.com/estimate.html?m=x' });
    assert.ok(mail);
    assert.doesNotMatch(mail.text, /evil\.example|estimate\.html/);
    assert.match(mail.text, /Please contact Rector HVAC to pay this invoice\./);
    const ok = E.buildChargeFailedEmail({ settings, to: 'pat@example.com', invoiceNumber: 'INV-1', amountCents: 100, reason: 'card_declined', payUrl: PAY, manageUrl: MANAGE });
    assert.match(ok.text, /You can pay securely here: https:\/\/gettradereadyapp\.com\/pay\.html\?t=p\.abc\.def/);
    assert.match(ok.text, /Manage automatic payments: https:\/\/gettradereadyapp\.com\/pay\.html\?m=m\.abc\.def/);
  });

  test('implausible recipients → no email at all', () => {
    for (const to of [undefined, '', 'nope', 'a@b.c, d@e.f', 'a@b.c\r\nBcc: x@y.z']) {
      assert.equal(E.buildReceiptEmail({ settings, to, invoiceNumber: 'I', amountCents: 1, remainingCents: 0, date: 'd' }), null, String(to));
    }
    assert.equal(E.buildOwnerAlertEmail({ to: 'bad', subject: 's', text: 't' }), null);
  });

  test('failure copy per reason', () => {
    const base = { settings, to: 'pat@example.com', invoiceNumber: 'INV-1', amountCents: 12000, payUrl: PAY, manageUrl: MANAGE };
    assert.match(E.buildChargeFailedEmail({ ...base, reason: 'authentication_required' }).text, /your bank asked you to confirm this payment/);
    assert.match(E.buildChargeFailedEmail({ ...base, reason: 'expired_card' }).text, /the card on file has expired/);
    assert.match(E.buildChargeFailedEmail({ ...base, reason: 'insufficient_funds' }).text, /your card was declined/);
    assert.match(E.buildChargeFailedEmail({ ...base, reason: 'amount_above_authorized', maxAmountCents: 10000 }).text, /more than the \$100\.00 you authorized/);
  });

  test('"autopay off" says who turned it off', () => {
    const args = { settings, to: 'pat@example.com', customerName: 'Pat', planDescription: 'Lawn care' };
    assert.match(E.buildAutopayOffEmail({ ...args, by: 'customer' }).text, /You turned off automatic payments for your "Lawn care" plan with Rector HVAC\./);
    assert.match(E.buildAutopayOffEmail({ ...args, by: 'owner' }).text, /Rector HVAC turned off automatic payments for your "Lawn care" plan\./);
  });

  test('"autopay on" repeats the stored authorization verbatim', () => {
    const consentText = 'Pay future invoices for this plan automatically with this card\n\nI authorize Rector HVAC to …';
    const mail = E.buildAutopayOnEmail({ settings, to: 'pat@example.com', customerName: 'Pat', planDescription: 'Lawn care', card: 'Visa ending 4242', consentText, consentedAt: '2026-10-03T18:00:00.000Z', manageUrl: MANAGE });
    assert.ok(mail.text.includes(`on 2026-10-03:\n\n${consentText}\n\nManage or turn off automatic payments: ${MANAGE}`));
  });

  test('owner alerts come from payments@ and never include the customer’s email', () => {
    const alert = E.ownerChargeProblemAlert({ customerName: 'Pat', invoiceNumber: 'INV-1', amountCents: 12000, reason: 'card_declined', customerEmailed: true });
    const mail = E.buildOwnerAlertEmail({ to: 'owner@example.com', ...alert });
    assert.equal(mail.from, 'TradeReady <payments@gettradereadyapp.com>');
    assert.equal(mail.subject, 'Autopay failed: Pat – invoice INV-1');
    assert.equal(alert.pushTitle, 'Autopay failed');
  });
});

// Phase 28 (tips spec §4.4): the pay-page receipt itemizes a tip; without one
// the text is the unchanged "Amount paid" form; autopay receipts never carry one.
describe('payment receipt — tips (Phase 28)', () => {
  const base = { settings, to: 'pat@example.com', customerName: 'Pat Lee', invoiceNumber: 'INV-1', card: 'Visa ending 4242', date: '2026-10-03' };

  test('with a tip: invoice payment, tip, total charged, card and remaining balance, in order', () => {
    const mail = E.buildReceiptEmail({ ...base, amountCents: 12000, tipCents: 1800, remainingCents: 0 });
    const lines = mail.text.split('\n');
    assert.deepEqual(lines.slice(lines.indexOf('Invoice INV-1'), lines.indexOf('Invoice INV-1') + 6), [
      'Invoice INV-1', 'Invoice payment: $120.00', 'Tip: $18.00', 'Total charged: $138.00', 'Card: Visa ending 4242', 'Date: 2026-10-03',
    ]);
    assert.match(mail.text, /Date: 2026-10-03\nThis invoice is now paid in full\./);
    assert.doesNotMatch(mail.text, /Amount paid/);
    assert.equal(mail.subject, 'Payment receipt – Invoice INV-1');
  });

  test('with a tip and a balance left, the balance excludes the tip', () => {
    const mail = E.buildReceiptEmail({ ...base, amountCents: 5000, tipCents: 500, remainingCents: 7000 });
    assert.match(mail.text, /Invoice payment: \$50\.00\nTip: \$5\.00\nTotal charged: \$55\.00\nCard: Visa ending 4242\nDate: 2026-10-03\nRemaining balance: \$70\.00/);
  });

  test('without a tip (absent, 0, null) the text is byte-identical to the pre-tip receipt', () => {
    const plain = E.buildReceiptEmail({ ...base, amountCents: 5000, remainingCents: 7000 });
    assert.match(plain.text, /Invoice INV-1\nAmount paid: \$50\.00\nCard: Visa ending 4242/);
    assert.doesNotMatch(plain.text, /Tip|Total charged|Invoice payment/);
    for (const tipCents of [0, null, undefined]) {
      assert.deepEqual(E.buildReceiptEmail({ ...base, amountCents: 5000, tipCents, remainingCents: 7000 }), plain, String(tipCents));
    }
  });

  test('a malformed tip (negative, fractional, string) is ignored, never printed', () => {
    const plain = E.buildReceiptEmail({ ...base, amountCents: 5000, remainingCents: 0 });
    for (const tipCents of [-100, 1.5, '500', NaN]) {
      assert.deepEqual(E.buildReceiptEmail({ ...base, amountCents: 5000, tipCents, remainingCents: 0 }), plain, String(tipCents));
    }
  });

  test('an autopay receipt never carries a tip, even if one is passed', () => {
    const args = { ...base, amountCents: 12000, remainingCents: 0, autopay: true, manageUrl: MANAGE };
    const withTip = E.buildReceiptEmail({ ...args, tipCents: 1800 });
    assert.deepEqual(withTip, E.buildReceiptEmail(args));
    assert.doesNotMatch(withTip.text, /Tip|Total charged/);
  });
});
