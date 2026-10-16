// payment_intent.succeeded branch of the Connect webhook (Phase 18 spec §2.2).
//
// ONLY a PaymentIntent the Worker itself created for Tap to Pay
// (metadata.source === 'tap_to_pay', stamped by lib/terminal/terminal.js) is
// booked. Payment Link and pay-page checkouts ALSO create PaymentIntents; those
// are already booked from their checkout.session.completed event under
// `stripe_<session id>`, so booking them again here would double-count. They
// (and every other payment_intent.* shape) are acknowledged and skipped.
//
// Ledger entry — byte-identical to what the device writes on success:
//   { id: 'stripe_<pi id>', amount, date: metadata.localDate, method: 'stripe',
//     stripePaymentIntentId, channel: 'card_present' }
// Ownership (event.account vs the invoice owner's stripe_accounts row), the
// legacy-ledger materialization, the zero-amount guard and idempotency all live
// in recordStripePayment.

const { recordStripePayment } = require('./recordPayment.js');

const LOCAL_DATE_RE = /^\d{4}-\d{2}-\d{2}$/;

const skipped = (c) => c.json({ received: true, skipped: true }, 200);

async function handleTapToPayIntent(c, event, { record = recordStripePayment } = {}) {
  const pi = event.data && event.data.object;
  const metadata = (pi && pi.metadata) || {};
  if (!pi || !pi.id || metadata.source !== 'tap_to_pay' || !metadata.invoiceId) return skipped(c);

  let result;
  try {
    result = await record(c.env, {
      invoiceId: metadata.invoiceId,
      connectedAccountId: event.account,
      ledgerId: `stripe_${pi.id}`,
      amount: (pi.amount_received || 0) / 100,
      // The device's local day; falls back to the writer's UTC day if absent.
      date: LOCAL_DATE_RE.test(metadata.localDate || '') ? metadata.localDate : undefined,
      extra: { stripePaymentIntentId: pi.id, channel: 'card_present' },
    });
  } catch (err) {
    console.error('[stripe/webhook] failed to book tap to pay payment:', err.message);
    // 500 so Stripe retries transient database errors.
    return c.json({ error: 'Database error' }, 500);
  }
  if (result.outcome === 'ownership_skip' || result.outcome === 'zero_amount') return skipped(c);
  return c.json({ received: true }, 200);
}

module.exports = { handleTapToPayIntent };
