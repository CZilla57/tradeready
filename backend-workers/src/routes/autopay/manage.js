// POST /api/autopay/manage {action:'remove', enrollmentId} — the owner
// removes a customer's saved card (Phase 24 spec §4.8, §6.3; contract in the
// build record §13.1). Revokes (owner), detaches the card best-effort, emails
// the customer "turned off by {Business}". Idempotent.

import { appCors, clientIp, jsonBody } from '../../appCors.js';
import { createRateLimiter } from '../../../lib/guards.js';
import { makeStripe } from '../../../lib/stripe/client.js';
import { ownerRemove } from '../../../lib/autopay/ownerRoutes.js';
import { resolveOwner } from './ownerAuth.js';

export function createAutopayManageHandler({ stripeFactory = makeStripe } = {}) {
  const allow = createRateLimiter({ limit: 20 });
  return async function autopayManageHandler(c) {
    appCors(c, 'POST, OPTIONS');
    if (c.req.method === 'OPTIONS') return c.body(null, 200);
    if (c.req.method !== 'POST') return c.json({ error: 'Method not allowed', code: 'method_not_allowed' }, 405);
    if (!allow(clientIp(c))) return c.json({ error: 'Too many requests. Please wait a moment.', code: 'rate_limited' }, 429);
    try {
      const owner = await resolveOwner(c);
      if (!owner.userId) return c.json(owner.body, owner.status);
      const body = (await jsonBody(c)) || null;
      const stripe = c.env.STRIPE_SECRET_KEY ? stripeFactory(c.env) : null;
      const { status, body: out } = await ownerRemove(c.env, { stripe, userId: owner.userId, body });
      return c.json(out, status);
    } catch (err) {
      console.error('[autopay/manage] failed:', err.message);
      return c.json({ error: 'Could not update automatic payments.', code: 'server_error' }, 500);
    }
  };
}

export const autopayManageHandler = createAutopayManageHandler();
