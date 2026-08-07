// POST /api/booking/respond — the owner's decision on a booking (Phase 11
// D2): resolve_reschedule or decline. JWT wrapper follows mint.js; the
// ownership check (as a 404, no oracle) lives in lib/booking/respond.js.

import { respondCore } from '../../../lib/booking/respond.js';
import { createRateLimiter } from '../../../lib/guards.js';
import { jsonBody } from '../../appCors.js';

const allow = createRateLimiter({ limit: 20 });

export async function bookingRespondHandler(c) {
  // Native fetch from the app — CORS is inert here; static real host, like
  // mint/create-link.
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

  const body = (await jsonBody(c)) || {};
  const { status, body: out } = await respondCore(c.env, {
    userId,
    requestId: body.requestId,
    action: body.action,
    nowMs: Date.now(),
  });
  return c.json(out, status);
}
