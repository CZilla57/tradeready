// Tap to Pay on iPhone — owner routes (Phase 18 spec §2.1). All three are
// POST, Supabase-JWT authed (the same /auth/v1/user check the other owner
// routes use), appCors, and rate limited PER USER (the key is the verified
// user id, so a shared NAT neither starves nor shelters anyone). Every Stripe
// call targets the caller's own connected account, looked up server-side.
//
//   POST /api/terminal/connection-token  → { secret }
//   POST /api/terminal/location          → { locationId, address }
//   POST /api/terminal/payment-intent    → { paymentIntentId, clientSecret, amount, amountCents }
//
// Errors are { error, code }. Nothing here is reachable until the native
// capability flag ships; deploying the routes is the owner's call.

import { appCors, jsonBody } from '../appCors.js';
import { createRateLimiter } from '../../lib/guards.js';
import { makeStripe } from '../../lib/stripe/client.js';
import { resolveConnectedOwner } from '../../lib/stripe/connectedAccount.js';
import { createConnectionToken, locationAction, createTerminalPaymentIntent } from '../../lib/terminal/terminal.js';

const TOO_MANY = { error: 'Too many requests. Please wait a moment.', code: 'rate_limited' };

function terminalRoute({ limit, name, failMessage, stripeFactory, run }) {
  const allow = createRateLimiter({ limit });
  return async function terminalHandler(c) {
    appCors(c, 'POST, OPTIONS');
    if (c.req.method === 'OPTIONS') return c.body(null, 200);
    if (c.req.method !== 'POST') return c.json({ error: 'Method not allowed', code: 'method_not_allowed' }, 405);
    try {
      const owner = await resolveConnectedOwner(c.env, c.req.header('authorization'));
      if (!owner.userId) return c.json(owner.body, owner.status);
      if (!allow(owner.userId)) return c.json(TOO_MANY, 429);
      const body = (await jsonBody(c)) || null;
      const stripe = stripeFactory(c.env);
      const { status, body: out } = await run({ c, stripe, body, ...owner });
      return c.json(out, status);
    } catch (err) {
      if (err && err.type === 'StripeIdempotencyError') {
        return c.json({ error: 'That request was already used with different details. Start again.', code: 'operation_conflict' }, 409);
      }
      if (err && err.type === 'StripeInvalidRequestError') {
        console.error(`[terminal/${name}] stripe rejected:`, err.message);
        return c.json({ error: 'Stripe could not process this request. Check your Stripe account setup.', code: 'stripe_rejected' }, 422);
      }
      console.error(`[terminal/${name}] failed:`, err && err.message);
      return c.json({ error: failMessage, code: 'server_error' }, 500);
    }
  };
}

export function createConnectionTokenHandler({ stripeFactory = makeStripe, limit = 30 } = {}) {
  return terminalRoute({
    limit,
    name: 'connection-token',
    failMessage: 'Could not start card payments. Please try again.',
    stripeFactory,
    run: ({ stripe, stripeAccountId }) => createConnectionToken({ stripe, stripeAccountId }),
  });
}

export function createLocationHandler({ stripeFactory = makeStripe, limit = 10 } = {}) {
  return terminalRoute({
    limit,
    name: 'location',
    failMessage: 'Could not set up the card payment location. Please try again.',
    stripeFactory,
    run: ({ stripe, stripeAccountId, body }) => locationAction({ stripe, stripeAccountId, body }),
  });
}

export function createPaymentIntentHandler({ stripeFactory = makeStripe, now = () => Date.now(), limit = 10 } = {}) {
  return terminalRoute({
    limit,
    name: 'payment-intent',
    failMessage: 'Could not start the card payment. Please try again.',
    stripeFactory,
    run: ({ c, stripe, userId, stripeAccountId, body }) =>
      createTerminalPaymentIntent(c.env, { stripe, userId, stripeAccountId, body, nowMs: now() }),
  });
}

export const connectionTokenHandler = createConnectionTokenHandler();
export const locationHandler = createLocationHandler();
export const paymentIntentHandler = createPaymentIntentHandler();
