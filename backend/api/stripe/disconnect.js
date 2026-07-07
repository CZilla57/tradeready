// POST — removes the Stripe Connect link for the authenticated user.
// The Stripe Express account itself is not deleted (the user still owns it),
// only the association in our database is removed.
//
// Auth: Supabase JWT via "Authorization: Bearer <token>"

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

  if (!SUPABASE_URL || !SUPABASE_ANON_KEY || !SUPABASE_SERVICE_ROLE_KEY) {
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

  const deleteRes = await fetch(
    `${SUPABASE_URL}/rest/v1/stripe_accounts?user_id=eq.${userId}`,
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
    return res.status(500).json({ error: 'Failed to disconnect account.' });
  }

  return res.status(200).json({ success: true });
};
