// GET — returns the Stripe Connect status for the authenticated user.
// Returns { connected: false } or { connected: true, details_submitted, display_name }
//
// Auth: Supabase JWT via "Authorization: Bearer <token>"

const Stripe = require('stripe');

const STRIPE_SECRET_KEY = process.env.STRIPE_SECRET_KEY;
const SUPABASE_URL = process.env.SUPABASE_URL;
const SUPABASE_ANON_KEY = process.env.SUPABASE_ANON_KEY;
const SUPABASE_SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;

module.exports = async function handler(req, res) {
  const allowedOrigins = ['https://tradeready.app'];
  const origin = req.headers['origin'];
  res.setHeader('Access-Control-Allow-Origin', origin && allowedOrigins.includes(origin) ? origin : 'https://tradeready.app');
  res.setHeader('Access-Control-Allow-Methods', 'GET, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type, Authorization');
  if (req.method === 'OPTIONS') return res.status(200).end();
  if (req.method !== 'GET') return res.status(405).json({ error: 'Method not allowed' });

  if (!STRIPE_SECRET_KEY || !SUPABASE_URL || !SUPABASE_ANON_KEY || !SUPABASE_SERVICE_ROLE_KEY) {
    return res.status(500).json({ error: 'Server misconfiguration.' });
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

  const accountRes = await fetch(
    `${SUPABASE_URL}/rest/v1/stripe_accounts?user_id=eq.${userId}&select=stripe_account_id`,
    {
      headers: {
        Authorization: `Bearer ${SUPABASE_SERVICE_ROLE_KEY}`,
        apikey: SUPABASE_SERVICE_ROLE_KEY,
      },
    }
  );
  const rows = accountRes.ok ? await accountRes.json() : [];
  const stripeAccountId = rows[0]?.stripe_account_id;

  if (!stripeAccountId) return res.status(200).json({ connected: false });

  try {
    const stripe = new Stripe(STRIPE_SECRET_KEY, { apiVersion: '2023-10-16' });
    const account = await stripe.accounts.retrieve(stripeAccountId);

    return res.status(200).json({
      connected: true,
      details_submitted: account.details_submitted,
      display_name:
        account.settings?.dashboard?.display_name ||
        account.business_profile?.name ||
        null,
    });
  } catch (err) {
    // Account was deleted or deauthorized on Stripe's side — treat as not connected.
    if (err.type === 'StripeInvalidRequestError') {
      return res.status(200).json({ connected: false });
    }
    return res.status(500).json({ error: err.message });
  }
};
