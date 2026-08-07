// POST /api/booking/reserve — atomic public slot reservation (Phase 11 C2).
// Thin wrapper: CORS/method/rate-limit plus the injected time/randomness;
// the §6 sequence lives in lib/booking/reserve.js (reserveCore).

import { randomBytes } from 'node:crypto';
import { reserveCore } from '../../../lib/booking/reserve.js';
import { applyCors } from '../../../lib/estimate/cors.js';
import { createRateLimiter } from '../../../lib/guards.js';
import { clientIp, jsonBody } from '../../appCors.js';

const allow = createRateLimiter({ limit: 10 });

export async function bookingReserveHandler(c) {
  applyCors(c, 'POST, OPTIONS');
  if (c.req.method === 'OPTIONS') return c.body(null, 200);
  if (c.req.method !== 'POST') return c.json({ error: 'Method not allowed' }, 405);

  const ip = clientIp(c);
  if (!allow(ip)) return c.json({ error: 'Too many requests. Please wait a moment.' }, 429);

  const body = (await jsonBody(c)) || {};
  const { status, body: out } = await reserveCore(c.env, {
    body,
    nowMs: Date.now(),
    randHex: randomBytes(3).toString('hex'),
    manageToken: randomBytes(24).toString('hex'),
  });
  return c.json(out, status);
}
