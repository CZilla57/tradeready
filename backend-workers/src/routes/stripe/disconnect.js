// POST /api/stripe/disconnect — Workers port of backend/lib/stripe/disconnect.js.
// Removes the Stripe Connect link for the authenticated user.
// The Stripe Express account itself is not deleted (the user still owns it),
// only the association in our database is removed.
//
// Auth: Supabase JWT via "Authorization: Bearer <token>"
//
// Phase 24 (spec §4.11): BEFORE the row is deleted, every active or pending
// autopay enrollment is revoked (system, stripe_disconnected) and its saved
// card detached on the old account, best-effort. The account is the
// owner's, but TradeReady can no longer honor "turn off" for it, so its
// saved cards must not stay chargeable through us. A failure here is logged
// and never blocks the disconnect.

import { appCors } from '../../appCors.js';
import { makeStripe } from '../../../lib/stripe/client.js';
import { revokeAllForUser } from '../../../lib/autopay/revoke.js';

export function createDisconnectHandler({ stripeFactory = makeStripe } = {}) {
  return async function disconnectHandler(c) {
    appCors(c, 'POST, OPTIONS');
    if (c.req.method === 'OPTIONS') return c.body(null, 200);
    if (c.req.method !== 'POST') return c.json({ error: 'Method not allowed' }, 405);

    const { SUPABASE_URL, SUPABASE_ANON_KEY, SUPABASE_SERVICE_ROLE_KEY } = c.env;
    if (!SUPABASE_URL || !SUPABASE_ANON_KEY || !SUPABASE_SERVICE_ROLE_KEY) {
      return c.json({ error: 'Server misconfiguration.' }, 500);
    }

    const auth = c.req.header('authorization');
    if (!auth || !auth.startsWith('Bearer ')) return c.json({ error: 'Unauthorized' }, 401);
    const userJwt = auth.slice(7);

    const userRes = await fetch(`${SUPABASE_URL}/auth/v1/user`, {
      headers: { Authorization: `Bearer ${userJwt}`, apikey: SUPABASE_ANON_KEY },
    });
    if (!userRes.ok) return c.json({ error: 'Invalid or expired session.' }, 401);
    const user = await userRes.json();
    const userId = user?.id;
    if (!userId) return c.json({ error: 'Unauthorized' }, 401);

    try {
      const stripe = c.env.STRIPE_SECRET_KEY ? stripeFactory(c.env) : null;
      const { revoked } = await revokeAllForUser(c.env, { userId, stripe, reason: 'stripe_disconnected' });
      if (revoked) console.log(`[stripe/disconnect] revoked ${revoked} autopay enrollment(s) for ${userId}`);
    } catch (err) {
      console.error('[stripe/disconnect] autopay revoke failed:', err.message);
    }

    const deleteRes = await fetch(
      `${SUPABASE_URL}/rest/v1/stripe_accounts?user_id=eq.${encodeURIComponent(userId)}`,
      {
        method: 'DELETE',
        headers: {
          Authorization: `Bearer ${SUPABASE_SERVICE_ROLE_KEY}`,
          apikey: SUPABASE_SERVICE_ROLE_KEY,
          Prefer: 'return=minimal',
        },
      }
    );

    if (!deleteRes.ok && deleteRes.status !== 404) {
      return c.json({ error: 'Failed to disconnect account.' }, 500);
    }

    return c.json({ success: true }, 200);
  };
}

export const disconnectHandler = createDisconnectHandler();
