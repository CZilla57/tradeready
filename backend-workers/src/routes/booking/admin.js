// POST /api/booking/admin — server-authoritative booking-link administration
// (Phase 8 task 8.05, contract §1). Owner JWT wrapper follows mint.js
// exactly (same auth resolution, same per-user 10/window rate limit); the
// contract lives in lib/booking/admin.js (adminCore) so tests run it without
// a Hono context. The existing mint route is retained untouched — mint stays
// the stateless pre-adoption bootstrap; admin is the adopted authority.
//
// Request: {action: mint|set_enabled|rotate|status, operationId?, enabled?,
// expectedRevision?, token?}. Response: {ok:true, enabled, token?, revision,
// operationId?, tokenValid?}. See the contract doc §1 for the frozen shapes.

import { randomBytes } from 'node:crypto';
import { adminCore } from '../../../lib/booking/admin.js';
import { createRateLimiter } from '../../../lib/guards.js';
import { jsonBody } from '../../appCors.js';

const allow = createRateLimiter({ limit: 10 });

export async function bookingAdminHandler(c) {
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
  const { status, body: out } = await adminCore(c.env, {
    userId,
    body,
    // Server-side RNG for mint/rotate capabilities (the mint precedent);
    // status/set_enabled ignore it.
    rawToken: randomBytes(24).toString('hex'),
  });
  return c.json(out, status);
}
