// GET /api/stripe/connect-status — Workers port of
// backend/lib/stripe/connectStatus.js.
// Returns the Stripe Connect status for the authenticated user:
// { connected: false } or { connected: true, details_submitted, display_name }
//
// Auth: Supabase JWT via "Authorization: Bearer <token>"

import Stripe from 'stripe';
import { appCors } from '../../appCors.js';

export async function connectStatusHandler(c) {
  appCors(c, 'GET, OPTIONS');
  if (c.req.method === 'OPTIONS') return c.body(null, 200);
  if (c.req.method !== 'GET') return c.json({ error: 'Method not allowed' }, 405);

  const { STRIPE_SECRET_KEY, SUPABASE_URL, SUPABASE_ANON_KEY, SUPABASE_SERVICE_ROLE_KEY } = c.env;
  if (!STRIPE_SECRET_KEY || !SUPABASE_URL || !SUPABASE_ANON_KEY || !SUPABASE_SERVICE_ROLE_KEY) {
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

  const accountRes = await fetch(
    `${SUPABASE_URL}/rest/v1/stripe_accounts?user_id=eq.${encodeURIComponent(userId)}&select=stripe_account_id`,
    {
      headers: {
        Authorization: `Bearer ${SUPABASE_SERVICE_ROLE_KEY}`,
        apikey: SUPABASE_SERVICE_ROLE_KEY,
      },
    }
  );
  const rows = accountRes.ok ? await accountRes.json() : [];
  const stripeAccountId = rows[0]?.stripe_account_id;

  if (!stripeAccountId) return c.json({ connected: false }, 200);

  try {
    const stripe = new Stripe(STRIPE_SECRET_KEY, {
      apiVersion: '2023-10-16',
      httpClient: Stripe.createFetchHttpClient(),
    });
    const account = await stripe.accounts.retrieve(stripeAccountId);

    return c.json({
      connected: true,
      details_submitted: account.details_submitted,
      display_name:
        account.settings?.dashboard?.display_name ||
        account.business_profile?.name ||
        null,
    }, 200);
  } catch (err) {
    // Account was deleted or deauthorized on Stripe's side — treat as not connected.
    if (err.type === 'StripeInvalidRequestError') {
      return c.json({ connected: false }, 200);
    }
    console.error('[connect-status] error:', err.message);
    return c.json({ error: 'Could not check Stripe connection status.' }, 500);
  }
}
