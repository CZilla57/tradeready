// /api/booking/manage — the customer's per-booking self-service surface
// (Phase 11 D1). GET ?m=<manageToken> returns the minimal status card, or
// the event as text/calendar with ?format=ics; POST { m, action, note }
// walks the manage state machine. Cores live in lib/booking/manage.js.

import { manageViewCore, manageActionCore } from '../../../lib/booking/manage.js';
import { buildIcs } from '../../../lib/booking/ics.js';
import { applyCors } from '../../../lib/estimate/cors.js';
import { createRateLimiter } from '../../../lib/guards.js';
import { clientIp, jsonBody } from '../../appCors.js';

const allowView = createRateLimiter({ limit: 30 });
const allowAction = createRateLimiter({ limit: 10 });

export async function bookingManageHandler(c) {
  applyCors(c, 'GET, POST, OPTIONS');
  if (c.req.method === 'OPTIONS') return c.body(null, 200);

  const ip = clientIp(c);

  if (c.req.method === 'GET') {
    if (!allowView(ip)) return c.json({ error: 'Too many requests.' }, 429);
    const token = c.req.query('m');
    const view = await manageViewCore(c.env, { token: token ? String(token) : undefined });
    if (view.status !== 200) return c.json(view.body, view.status);

    if (c.req.query('format') === 'ics') {
      c.header('Content-Type', 'text/calendar; charset=utf-8');
      c.header('Content-Disposition', 'attachment; filename="appointment.ics"');
      return c.body(
        buildIcs({
          businessName: view.body.businessName || 'your booked business',
          slot: view.body.slot,
          uid: `${String(token).slice(0, 12)}@tradeready-booking`,
        }),
        200
      );
    }
    return c.json(view.body, 200);
  }

  if (c.req.method === 'POST') {
    if (!allowAction(ip)) return c.json({ error: 'Too many requests. Please wait a moment.' }, 429);
    const body = (await jsonBody(c)) || {};
    const { status, body: out } = await manageActionCore(c.env, {
      token: typeof body.m === 'string' ? body.m : undefined,
      action: body.action,
      note: body.note,
      nowMs: Date.now(),
    });
    return c.json(out, status);
  }

  return c.json({ error: 'Method not allowed' }, 405);
}
