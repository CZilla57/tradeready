// GET /api/autopay/status — the owner's autopay enrollments and the last
// 120 days of automatic charge attempts (Phase 24 spec §4.8; exact contract
// in the spec's build record §13.1). JWT + appCors, like the other app routes.

import { appCors, clientIp } from '../../appCors.js';
import { createRateLimiter } from '../../../lib/guards.js';
import { ownerStatus } from '../../../lib/autopay/ownerRoutes.js';
import { resolveOwner } from './ownerAuth.js';

const allow = createRateLimiter({ limit: 60 });

export async function autopayStatusHandler(c) {
  appCors(c, 'GET, OPTIONS');
  if (c.req.method === 'OPTIONS') return c.body(null, 200);
  if (c.req.method !== 'GET') return c.json({ error: 'Method not allowed', code: 'method_not_allowed' }, 405);
  if (!allow(clientIp(c))) return c.json({ error: 'Too many requests. Please wait a moment.', code: 'rate_limited' }, 429);
  try {
    const owner = await resolveOwner(c);
    if (!owner.userId) return c.json(owner.body, owner.status);
    return c.json(await ownerStatus(c.env, { userId: owner.userId }), 200);
  } catch (err) {
    console.error('[autopay/status] failed:', err.message);
    return c.json({ error: 'Could not load automatic payments.', code: 'server_error' }, 500);
  }
}
