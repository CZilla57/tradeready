// The one place the Worker constructs a Stripe client (Phase 24 spec §4.1).
// Every route and the autopay sweep take an injectable `stripeFactory`
// defaulting to makeStripe, so tests run against an in-memory fake.
//
// The API version pin is unchanged from the four constructors this replaced
// (createPaymentLink, stripe/webhook, stripe/createConnectAccount,
// stripe/connectStatus). See spec §0.5 for why no version or SDK bump is
// needed. createFetchHttpClient is the SDK's fetch transport, required off
// Node (Workers has no Node http module).

const Stripe = require('stripe');

const STRIPE_API_VERSION = '2023-10-16';

function makeStripe(env) {
  return new Stripe(env.STRIPE_SECRET_KEY, {
    apiVersion: STRIPE_API_VERSION,
    httpClient: Stripe.createFetchHttpClient(),
  });
}

// constructEventAsync needs the SubtleCrypto provider on Workers (no sync
// crypto.createHmac).
function webhookCryptoProvider() {
  return Stripe.createSubtleCryptoProvider();
}

// Stripe SDK errors carry `type` ('StripeCardError', …). An unknown outcome
// (network failure, Stripe 5xx, 429, idempotency conflict while the first
// request is still in flight) must never be read as a decline.
function isUnknownOutcome(err) {
  if (!err) return false;
  if (err.type === 'StripeCardError') return false;
  if (err.type === 'StripeConnectionError' || err.type === 'StripeAPIError' || err.type === 'StripeRateLimitError') return true;
  if (err.type === 'StripeIdempotencyError') return true;
  const status = Number(err.statusCode);
  if (Number.isFinite(status) && (status >= 500 || status === 429 || status === 409)) return true;
  // No HTTP status at all: a thrown fetch/timeout, not an answer from Stripe.
  return !Number.isFinite(status);
}

module.exports = { makeStripe, webhookCryptoProvider, isUnknownOutcome, STRIPE_API_VERSION };
