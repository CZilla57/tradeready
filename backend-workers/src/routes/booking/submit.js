// POST /api/booking/submit  { b, name, phone, email, address, details,
// preferredTiming, website } — Workers port of backend/lib/booking/submit.js.
// Public, token-gated write path for the booking link. Inserts ONE row into
// bookingRequests (service role); the DEVICE converts it to Customer + lead
// Job (utils/storage/bookingConversion.ts). Alerts are fire-and-forget —
// their failure never fails the submission. `website` is the honeypot: bots
// fill it, humans never see it; a hit gets a fake success so the bot learns
// nothing.

import { randomBytes } from 'node:crypto';
import { lookupUserByBookingToken, insertBookingRequest, newRequestId } from '../../../lib/booking/store.js';
import { validateBookingPayload } from '../../../lib/booking/validate.js';
import { notifyOwner } from '../../../lib/booking/notifyOwner.js';
import { applyCors } from '../../../lib/estimate/cors.js';
import { createRateLimiter } from '../../../lib/guards.js';
import { clientIp, jsonBody } from '../../appCors.js';

const allow = createRateLimiter({ limit: 10 });

export async function bookingSubmitHandler(c) {
  applyCors(c, 'POST, OPTIONS');
  if (c.req.method === 'OPTIONS') return c.body(null, 200);
  if (c.req.method !== 'POST') return c.json({ error: 'Method not allowed' }, 405);

  const ip = clientIp(c);
  if (!allow(ip)) return c.json({ error: 'Too many requests. Please wait a moment.' }, 429);

  const body = (await jsonBody(c)) || {};
  if (typeof body.website === 'string' && body.website.trim() !== '') {
    console.warn('[booking/submit] honeypot hit — submission dropped');
    return c.json({ ok: true }, 200); // honeypot — silent drop
  }

  const token = body.b;
  if (!token || typeof token !== 'string') return c.json({ error: 'Missing link parameters.' }, 400);

  const checked = validateBookingPayload(body);
  if (!checked.ok) return c.json({ error: checked.error }, 400);

  let row;
  try {
    row = await lookupUserByBookingToken(c.env, token);
  } catch (err) {
    console.error('[booking/submit] lookup failed:', err.message);
    return c.json({ error: 'Database error' }, 500);
  }
  if (!row) return c.json({ error: 'This link is invalid.' }, 404);

  const request = {
    id: newRequestId(Date.now(), randomBytes(3).toString('hex')),
    status: 'new',
    ...checked.value,
    createdAt: new Date().toISOString(),
  };

  try {
    await insertBookingRequest(c.env, row.user_id, request);
  } catch (err) {
    console.error('[booking/submit] insert failed:', err.message);
    return c.json({ error: 'Database error' }, 500);
  }

  try {
    await notifyOwner(c.env, { userId: row.user_id, settingsData: row.data, request });
  } catch (err) {
    console.error('[booking/submit] notify failed:', err.message);
  }

  return c.json({ ok: true }, 200);
}
