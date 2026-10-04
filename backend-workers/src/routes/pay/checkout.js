// POST /api/pay/checkout {t, autopay?: {consentVersion, amount}} |
// {s, consentVersion, amount} → {url} of a Stripe-hosted Checkout Session
// created NOW from the live balance (Phase 24 spec §4.4). Browser-facing:
// applyCors, rate-limited per IP. The page navigates top-level to the URL,
// so the CSP's form-action/frame rules never apply.

import { applyCors } from '../../../lib/estimate/cors.js';
import { createRateLimiter } from '../../../lib/guards.js';
import { makeStripe } from '../../../lib/stripe/client.js';
import { checkout } from '../../../lib/pay/payService.js';
import { clientIp, jsonBody } from '../../appCors.js';

export function createPayCheckoutHandler({ stripeFactory = makeStripe } = {}) {
  const allow = createRateLimiter({ limit: 10 });
  return async function payCheckoutHandler(c) {
    applyCors(c, 'POST, OPTIONS');
    if (c.req.method === 'OPTIONS') return c.body(null, 200);
    if (c.req.method !== 'POST') return c.json({ error: 'Method not allowed', code: 'method_not_allowed' }, 405);
    const ip = clientIp(c);
    if (!allow(ip)) return c.json({ error: 'Too many requests. Please wait a moment.', code: 'rate_limited' }, 429);
    c.header('Cache-Control', 'no-store');
    if (!c.env.STRIPE_SECRET_KEY || !c.env.SUPABASE_URL || !c.env.SUPABASE_SERVICE_ROLE_KEY) {
      return c.json({ error: 'Something went wrong. Please try again.', code: 'server_error' }, 500);
    }
    try {
      const body = (await jsonBody(c)) || {};
      const { status, body: out } = await checkout(c.env, {
        stripe: stripeFactory(c.env),
        body,
        ip,
        userAgent: c.req.header('user-agent') || '',
      });
      return c.json(out, status);
    } catch (err) {
      console.error('[pay/checkout] failed:', err.message);
      const busy = err && (err.type === 'StripeIdempotencyError' || Number(err.statusCode) === 409);
      return busy
        ? c.json({ error: 'Please try again in a moment.', code: 'busy' }, 409)
        : c.json({ error: "We couldn't start the payment. Please try again.", code: 'server_error' }, 500);
    }
  };
}

export const payCheckoutHandler = createPayCheckoutHandler();
