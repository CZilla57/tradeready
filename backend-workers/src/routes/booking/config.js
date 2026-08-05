// GET /api/booking/config?b=<token> — Workers port of
// backend/lib/booking/config.js.
// Form bootstrap for book.html. Returns ONLY the business display name —
// the settings blob it reads also holds contact info, rates and the push
// token, none of which may leak to an anonymous caller.

import { lookupUserByBookingToken } from '../../../lib/booking/store.js';
import { applyCors } from '../../../lib/estimate/cors.js';
import { createRateLimiter } from '../../../lib/guards.js';
import { clientIp } from '../../appCors.js';

const allow = createRateLimiter({ limit: 30 });

export async function bookingConfigHandler(c) {
  applyCors(c, 'GET, OPTIONS');
  if (c.req.method === 'OPTIONS') return c.body(null, 200);
  if (c.req.method !== 'GET') return c.json({ error: 'Method not allowed' }, 405);

  const ip = clientIp(c);
  if (!allow(ip)) return c.json({ error: 'Too many requests.' }, 429);

  const token = c.req.query('b');
  if (!token) return c.json({ error: 'Missing link parameters.' }, 400);

  let row;
  try {
    row = await lookupUserByBookingToken(c.env, String(token));
  } catch (err) {
    console.error('[booking/config] lookup failed:', err.message);
    return c.json({ error: 'Database error' }, 500);
  }
  if (!row) return c.json({ error: 'This link is invalid.' }, 404);

  return c.json({ businessName: String(row.data?.businessName || '').slice(0, 120) }, 200);
}
