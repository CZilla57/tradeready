// GET /api/estimate/portal-ics?p=<token>&j=<jobId> — "Add to calendar" for a
// portal appointment (Phase 12A). Consumed as a plain link (like booking
// manage's ?format=ics), so CORS is irrelevant to the download itself; the
// shared estimate CORS is applied anyway for family consistency.

import { applyCors } from '../../../lib/estimate/cors.js';
import { createRateLimiter } from '../../../lib/guards.js';
import { portalIcsCore } from '../../../lib/estimate/portalIcs.js';
import { clientIp } from '../../appCors.js';

const allow = createRateLimiter({ limit: 30 });

export async function portalIcsHandler(c) {
  applyCors(c, 'GET, OPTIONS');
  if (c.req.method === 'OPTIONS') return c.body(null, 200);
  if (c.req.method !== 'GET') return c.json({ error: 'Method not allowed' }, 405);
  if (!allow(clientIp(c))) return c.json({ error: 'Too many requests.' }, 429);

  const token = c.req.query('p');
  const jobId = c.req.query('j');
  if (!token || !jobId) return c.json({ error: 'Missing link parameters.' }, 400);

  let out;
  try {
    out = await portalIcsCore(c.env, { token, jobId, stampUtc: new Date().toISOString() });
  } catch (err) {
    console.error('[estimate/portal-ics] failed:', err.message);
    return c.json({ error: 'Database error' }, 500);
  }
  if (!out.ok) return c.json({ error: out.error }, out.status);
  return c.body(out.ics, 200, {
    'Content-Type': 'text/calendar; charset=utf-8',
    'Content-Disposition': 'attachment; filename="appointment.ics"',
  });
}
