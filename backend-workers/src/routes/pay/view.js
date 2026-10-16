// GET /api/pay/view?t=|s=|m=[&session_id=] — the pay page's read (Phase 24
// spec §4.4). Browser-facing: estimate-page CORS (applyCors), rate-limited
// per IP, no auth beyond the signed token. Logic and the whitelisted
// response shapes live in lib/pay/payService.js and lib/pay/payView.js.

import { applyCors } from '../../../lib/estimate/cors.js';
import { createRateLimiter } from '../../../lib/guards.js';
import { makeStripe } from '../../../lib/stripe/client.js';
import { view } from '../../../lib/pay/payService.js';
import { clientIp } from '../../appCors.js';

export function createPayViewHandler({ stripeFactory = makeStripe } = {}) {
  const allow = createRateLimiter({ limit: 60 });
  return async function payViewHandler(c) {
    applyCors(c, 'GET, OPTIONS');
    if (c.req.method === 'OPTIONS') return c.body(null, 200);
    if (c.req.method !== 'GET') return c.json({ error: 'Method not allowed', code: 'method_not_allowed' }, 405);
    if (!allow(clientIp(c))) return c.json({ error: 'Too many requests. Please wait a moment.', code: 'rate_limited' }, 429);
    // Never cache: paid state and links change under the same URL.
    c.header('Cache-Control', 'no-store');
    try {
      const query = { t: c.req.query('t'), s: c.req.query('s'), m: c.req.query('m'), session_id: c.req.query('session_id') };
      const stripe = c.env.STRIPE_SECRET_KEY ? stripeFactory(c.env) : null;
      const { status, body } = await view(c.env, { stripe, query });
      return c.json(body, status);
    } catch (err) {
      console.error('[pay/view] failed:', err.message);
      return c.json({ error: 'Something went wrong. Please try again.', code: 'server_error' }, 500);
    }
  };
}

export const payViewHandler = createPayViewHandler();
