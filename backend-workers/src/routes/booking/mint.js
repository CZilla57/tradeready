// POST /api/booking/mint — Workers port of backend/lib/booking/mint.js.
// Server-side RNG for the booking token (the device has no secure RNG — the
// create-link precedent). STATELESS on purpose: the device writes the token
// into its settings blob and normal sync publishes it, so the server never
// races a device settings save (spec §4). JWT-authed + per-user rate limit.

import { randomBytes } from 'node:crypto';
import { createRateLimiter } from '../../../lib/guards.js';

const allow = createRateLimiter({ limit: 10 });

export async function bookingMintHandler(c) {
  // Native fetch from the app — CORS is inert here; static real host, like
  // create-link.
  c.header('Access-Control-Allow-Origin', 'https://gettradereadyapp.com');
  c.header('Access-Control-Allow-Methods', 'POST, OPTIONS');
  c.header('Access-Control-Allow-Headers', 'Content-Type, Authorization');
  if (c.req.method === 'OPTIONS') return c.body(null, 200);
  if (c.req.method !== 'POST') return c.json({ error: 'Method not allowed' }, 405);

  const { SUPABASE_URL, SUPABASE_ANON_KEY } = c.env;
  if (!SUPABASE_URL || !SUPABASE_ANON_KEY) return c.json({ error: 'Server misconfiguration.' }, 500);

  const auth = c.req.header('authorization');
  if (!auth || !auth.startsWith('Bearer ')) return c.json({ error: 'Unauthorized' }, 401);
  const userRes = await fetch(`${SUPABASE_URL}/auth/v1/user`, {
    headers: { Authorization: auth, apikey: SUPABASE_ANON_KEY },
  });
  if (!userRes.ok) return c.json({ error: 'Invalid or expired session.' }, 401);
  const userId = (await userRes.json())?.id;
  if (!userId) return c.json({ error: 'Unauthorized' }, 401);

  if (!allow(userId)) return c.json({ error: 'Too many requests. Please wait a moment.' }, 429);

  return c.json({ token: randomBytes(24).toString('hex') }, 200);
}
