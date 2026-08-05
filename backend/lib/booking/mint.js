// POST /api/booking/mint
// Server-side RNG for the booking token (the device has no secure RNG — the
// create-link precedent). STATELESS on purpose: the device writes the token
// into its settings blob and normal sync publishes it, so the server never
// races a device settings save (spec §4). JWT-authed + per-user rate limit.

const crypto = require('crypto');
const { createRateLimiter } = require('../guards');

const allow = createRateLimiter({ limit: 10 });

module.exports = async function mint(req, res) {
  // Native fetch from the app — CORS is inert here; static real host, like
  // create-link.
  res.setHeader('Access-Control-Allow-Origin', 'https://gettradereadyapp.com');
  res.setHeader('Access-Control-Allow-Methods', 'POST, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type, Authorization');
  if (req.method === 'OPTIONS') return res.status(200).end();
  if (req.method !== 'POST') return res.status(405).json({ error: 'Method not allowed' });

  const SUPABASE_URL = process.env.SUPABASE_URL;
  const SUPABASE_ANON_KEY = process.env.SUPABASE_ANON_KEY;
  if (!SUPABASE_URL || !SUPABASE_ANON_KEY) return res.status(500).json({ error: 'Server misconfiguration.' });

  const auth = req.headers['authorization'];
  if (!auth || !auth.startsWith('Bearer ')) return res.status(401).json({ error: 'Unauthorized' });
  const userRes = await fetch(`${SUPABASE_URL}/auth/v1/user`, {
    headers: { Authorization: auth, apikey: SUPABASE_ANON_KEY },
  });
  if (!userRes.ok) return res.status(401).json({ error: 'Invalid or expired session.' });
  const userId = (await userRes.json())?.id;
  if (!userId) return res.status(401).json({ error: 'Unauthorized' });

  if (!allow(userId)) return res.status(429).json({ error: 'Too many requests. Please wait a moment.' });

  return res.status(200).json({ token: crypto.randomBytes(24).toString('hex') });
};
