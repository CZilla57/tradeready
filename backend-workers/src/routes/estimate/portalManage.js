// POST /api/estimate/portal-manage  { action: mint | set_enabled | rotate,
// customerId, enabled? } — owner-side portal token management (Phase 12D).
// JWT-authed (the caller is the APP, not a portal page — hence appCors, which
// allows the Authorization header, NOT the browser-facing estimate CORS).
// Thin shell; the invariants live in lib/estimate/portalManage.js (tested).

import { randomBytes } from 'node:crypto';
import { createRateLimiter } from '../../../lib/guards.js';
import { portalManageCore } from '../../../lib/estimate/portalManage.js';
import { appCors, jsonBody } from '../../appCors.js';

const allow = createRateLimiter({ limit: 10 });

// Verify the Supabase JWT → user id, or return an error Response
// (photos.js / booking-mint convention — local copy, per-route).
async function authUserId(c) {
  const auth = c.req.header('authorization');
  if (!auth || !auth.startsWith('Bearer ')) {
    return { error: c.json({ error: 'Unauthorized' }, 401) };
  }
  const userRes = await fetch(`${c.env.SUPABASE_URL}/auth/v1/user`, {
    headers: { Authorization: `Bearer ${auth.slice(7)}`, apikey: c.env.SUPABASE_ANON_KEY },
  });
  if (!userRes.ok) {
    return { error: c.json({ error: 'Invalid or expired session. Please sign in again.' }, 401) };
  }
  const user = await userRes.json();
  if (!user?.id) return { error: c.json({ error: 'Unauthorized' }, 401) };
  return { userId: user.id };
}

export async function portalManageHandler(c) {
  appCors(c, 'POST, OPTIONS');
  if (c.req.method === 'OPTIONS') return c.body(null, 200);
  if (c.req.method !== 'POST') return c.json({ error: 'Method not allowed' }, 405);

  const authed = await authUserId(c);
  if (authed.error) return authed.error;
  if (!allow(authed.userId)) return c.json({ error: 'Too many requests.' }, 429);

  const body = (await jsonBody(c)) || {};
  let out;
  try {
    out = await portalManageCore(c.env, {
      userId: authed.userId,
      body,
      randHex: randomBytes(24).toString('hex'),
    });
  } catch (err) {
    console.error('[estimate/portal-manage] failed:', err.message);
    return c.json({ error: 'Database error' }, 500);
  }
  return c.json(out.json, out.status);
}
