// GET /api/booking/slots?b=<token> — public bookable-slot offers for
// book.html (Phase 11 C1). Thin wrapper: CORS/method/rate-limit here, the
// handler logic lives in lib/booking/slots.js (slotsCore) so tests run it
// without a Hono context.

import { slotsCore } from '../../../lib/booking/slots.js';
import { applyCors } from '../../../lib/estimate/cors.js';
import { createRateLimiter } from '../../../lib/guards.js';
import { clientIp } from '../../appCors.js';

const allow = createRateLimiter({ limit: 30 });

export async function bookingSlotsHandler(c) {
  applyCors(c, 'GET, OPTIONS');
  if (c.req.method === 'OPTIONS') return c.body(null, 200);
  if (c.req.method !== 'GET') return c.json({ error: 'Method not allowed' }, 405);

  const ip = clientIp(c);
  if (!allow(ip)) return c.json({ error: 'Too many requests.' }, 429);

  const token = c.req.query('b');
  const { status, body } = await slotsCore(c.env, {
    token: token ? String(token) : undefined,
    nowMs: Date.now(),
  });
  return c.json(body, status);
}
