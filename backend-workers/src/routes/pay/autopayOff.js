// POST /api/pay/autopay-off {m} — the customer turns automatic payments off
// from the manage page (Phase 24 spec §2.5, §4.4). Revokes the enrollment
// (by customer), detaches the saved card, emails the customer a
// confirmation and alerts the owner. Idempotent: an enrollment that is
// already off answers 200 {status:'off', changed:false}.

import { applyCors } from '../../../lib/estimate/cors.js';
import { createRateLimiter } from '../../../lib/guards.js';
import { makeStripe } from '../../../lib/stripe/client.js';
import { autopayOff } from '../../../lib/pay/payService.js';
import { clientIp, jsonBody } from '../../appCors.js';

export function createPayAutopayOffHandler({ stripeFactory = makeStripe } = {}) {
  const allow = createRateLimiter({ limit: 10 });
  return async function payAutopayOffHandler(c) {
    applyCors(c, 'POST, OPTIONS');
    if (c.req.method === 'OPTIONS') return c.body(null, 200);
    if (c.req.method !== 'POST') return c.json({ error: 'Method not allowed', code: 'method_not_allowed' }, 405);
    if (!allow(clientIp(c))) return c.json({ error: 'Too many requests. Please wait a moment.', code: 'rate_limited' }, 429);
    c.header('Cache-Control', 'no-store');
    try {
      const body = (await jsonBody(c)) || {};
      const stripe = c.env.STRIPE_SECRET_KEY ? stripeFactory(c.env) : null;
      const { status, body: out } = await autopayOff(c.env, { stripe, body });
      return c.json(out, status);
    } catch (err) {
      console.error('[pay/autopay-off] failed:', err.message);
      return c.json({ error: 'Something went wrong. Please try again.', code: 'server_error' }, 500);
    }
  };
}

export const payAutopayOffHandler = createPayAutopayOffHandler();
