// POST /api/stripe/create-connect-account — Workers port of
// backend/lib/stripe/createConnectAccount.js.
// Creates or reconnects a Stripe Express account for the authenticated user.
// Returns { onboarding_url } pointing to the Stripe-hosted onboarding form.
//
// Auth: Supabase JWT via "Authorization: Bearer <token>"
//
// Required bindings:
//   STRIPE_SECRET_KEY, SUPABASE_URL, SUPABASE_ANON_KEY, SUPABASE_SERVICE_ROLE_KEY

import Stripe from 'stripe';
import { appCors } from '../../appCors.js';

export async function createConnectAccountHandler(c) {
  appCors(c, 'POST, OPTIONS');
  if (c.req.method === 'OPTIONS') return c.body(null, 200);
  if (c.req.method !== 'POST') return c.json({ error: 'Method not allowed' }, 405);

  const { STRIPE_SECRET_KEY, SUPABASE_URL, SUPABASE_ANON_KEY, SUPABASE_SERVICE_ROLE_KEY } = c.env;
  if (!STRIPE_SECRET_KEY || !SUPABASE_URL || !SUPABASE_ANON_KEY || !SUPABASE_SERVICE_ROLE_KEY) {
    return c.json({ error: 'Server misconfiguration. Check the server environment configuration.' }, 500);
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
    const stripe = new Stripe(STRIPE_SECRET_KEY, {
      apiVersion: '2023-10-16',
      httpClient: Stripe.createFetchHttpClient(),
    });

    // Reuse an existing account if one was already created for this user.
    let stripeAccountId = await getStripeAccountId(c.env, userId);
    if (!stripeAccountId) {
      const account = await stripe.accounts.create({
        type: 'express',
        capabilities: {
          card_payments: { requested: true },
          transfers: { requested: true },
        },
      });
      stripeAccountId = account.id;
      await saveStripeAccountId(c.env, userId, stripeAccountId);
    }

    // Generate a fresh onboarding link (these expire after a few minutes).
    // Vercel's VERCEL_URL has no Workers equivalent; the incoming request's
    // own origin is correct on *.workers.dev during parallel testing AND on
    // the eventual custom domain after cutover, with no redeploy needed.
    const baseUrl = new URL(c.req.url).origin;
    const accountLink = await stripe.accountLinks.create({
      account: stripeAccountId,
      refresh_url: `${baseUrl}/api/stripe/connect-return?status=refresh`,
      return_url: `${baseUrl}/api/stripe/connect-return?status=complete`,
      type: 'account_onboarding',
    });

    return c.json({ onboarding_url: accountLink.url }, 200);
  } catch (err) {
    console.error('[create-connect-account] error:', err.message);
    return c.json({ error: 'Could not start Stripe onboarding. Please try again.' }, 500);
  }
}

async function getStripeAccountId(env, userId) {
  const res = await fetch(
    `${env.SUPABASE_URL}/rest/v1/stripe_accounts?user_id=eq.${encodeURIComponent(userId)}&select=stripe_account_id`,
    {
      headers: {
        Authorization: `Bearer ${env.SUPABASE_SERVICE_ROLE_KEY}`,
        apikey: env.SUPABASE_SERVICE_ROLE_KEY,
      },
    }
  );
  if (!res.ok) return null;
  const rows = await res.json();
  return rows[0]?.stripe_account_id ?? null;
}

async function saveStripeAccountId(env, userId, stripeAccountId) {
  await fetch(`${env.SUPABASE_URL}/rest/v1/stripe_accounts`, {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${env.SUPABASE_SERVICE_ROLE_KEY}`,
      apikey: env.SUPABASE_SERVICE_ROLE_KEY,
      'Content-Type': 'application/json',
      // Upsert: if the user already has a row (e.g. from a previous session), update it.
      Prefer: 'resolution=merge-duplicates',
    },
    body: JSON.stringify({ user_id: userId, stripe_account_id: stripeAccountId }),
  });
}
