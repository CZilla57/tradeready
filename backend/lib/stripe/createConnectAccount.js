// POST — creates or reconnects a Stripe Express account for the authenticated user.
// Returns { onboarding_url } pointing to the Stripe-hosted onboarding form.
//
// Auth: Supabase JWT via "Authorization: Bearer <token>"
//
// Required Vercel env vars:
//   STRIPE_SECRET_KEY, SUPABASE_URL, SUPABASE_ANON_KEY, SUPABASE_SERVICE_ROLE_KEY

const Stripe = require('stripe');

const STRIPE_SECRET_KEY = process.env.STRIPE_SECRET_KEY;
const SUPABASE_URL = process.env.SUPABASE_URL;
const SUPABASE_ANON_KEY = process.env.SUPABASE_ANON_KEY;
const SUPABASE_SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;

module.exports = async function handler(req, res) {
  const allowedOrigins = ['https://tradeready.app'];
  const origin = req.headers['origin'];
  res.setHeader('Access-Control-Allow-Origin', origin && allowedOrigins.includes(origin) ? origin : 'https://tradeready.app');
  res.setHeader('Access-Control-Allow-Methods', 'POST, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type, Authorization');
  if (req.method === 'OPTIONS') return res.status(200).end();
  if (req.method !== 'POST') return res.status(405).json({ error: 'Method not allowed' });

  if (!STRIPE_SECRET_KEY || !SUPABASE_URL || !SUPABASE_ANON_KEY || !SUPABASE_SERVICE_ROLE_KEY) {
    return res.status(500).json({ error: 'Server misconfiguration. Check Vercel environment variables.' });
  }

  const auth = req.headers['authorization'];
  if (!auth || !auth.startsWith('Bearer ')) return res.status(401).json({ error: 'Unauthorized' });
  const userJwt = auth.slice(7);

  const userRes = await fetch(`${SUPABASE_URL}/auth/v1/user`, {
    headers: { Authorization: `Bearer ${userJwt}`, apikey: SUPABASE_ANON_KEY },
  });
  if (!userRes.ok) return res.status(401).json({ error: 'Invalid or expired session.' });
  const user = await userRes.json();
  const userId = user?.id;
  if (!userId) return res.status(401).json({ error: 'Unauthorized' });

  try {
    const stripe = new Stripe(STRIPE_SECRET_KEY, { apiVersion: '2023-10-16' });

    // Reuse an existing account if one was already created for this user.
    let stripeAccountId = await getStripeAccountId(userId);
    if (!stripeAccountId) {
      const account = await stripe.accounts.create({
        type: 'express',
        capabilities: {
          card_payments: { requested: true },
          transfers: { requested: true },
        },
      });
      stripeAccountId = account.id;
      await saveStripeAccountId(userId, stripeAccountId);
    }

    // Generate a fresh onboarding link (these expire after a few minutes).
    const baseUrl = process.env.VERCEL_URL
      ? `https://${process.env.VERCEL_URL}`
      : 'https://backend-tradeready1.vercel.app';
    const accountLink = await stripe.accountLinks.create({
      account: stripeAccountId,
      refresh_url: `${baseUrl}/api/stripe/connect-return?status=refresh`,
      return_url: `${baseUrl}/api/stripe/connect-return?status=complete`,
      type: 'account_onboarding',
    });

    return res.status(200).json({ onboarding_url: accountLink.url });
  } catch (err) {
    console.error('[create-connect-account] error:', err.message);
    return res.status(500).json({ error: 'Could not start Stripe onboarding. Please try again.' });
  }
};

async function getStripeAccountId(userId) {
  const res = await fetch(
    `${SUPABASE_URL}/rest/v1/stripe_accounts?user_id=eq.${userId}&select=stripe_account_id`,
    {
      headers: {
        Authorization: `Bearer ${SUPABASE_SERVICE_ROLE_KEY}`,
        apikey: SUPABASE_SERVICE_ROLE_KEY,
      },
    }
  );
  if (!res.ok) return null;
  const rows = await res.json();
  return rows[0]?.stripe_account_id ?? null;
}

async function saveStripeAccountId(userId, stripeAccountId) {
  await fetch(`${SUPABASE_URL}/rest/v1/stripe_accounts`, {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${SUPABASE_SERVICE_ROLE_KEY}`,
      apikey: SUPABASE_SERVICE_ROLE_KEY,
      'Content-Type': 'application/json',
      // Upsert: if the user already has a row (e.g. from a previous session), update it.
      Prefer: 'resolution=merge-duplicates',
    },
    body: JSON.stringify({ user_id: userId, stripe_account_id: stripeAccountId }),
  });
}
