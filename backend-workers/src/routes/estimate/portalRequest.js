// POST /api/estimate/portal-request  { p, kind, note, jobRef?, requestKey,
// website } — the portal's follow-up / reschedule / cancel request write
// (Phase 12C). Thin Hono shell; the whole accept/reject surface lives in
// lib/estimate/portalRequest.js (tested there).

import { applyCors } from '../../../lib/estimate/cors.js';
import { createRateLimiter } from '../../../lib/guards.js';
import { portalRequestCore } from '../../../lib/estimate/portalRequest.js';
import { clientIp, jsonBody } from '../../appCors.js';

const allow = createRateLimiter({ limit: 10 });

export async function portalRequestHandler(c) {
  applyCors(c, 'POST, OPTIONS');
  if (c.req.method === 'OPTIONS') return c.body(null, 200);
  if (c.req.method !== 'POST') return c.json({ error: 'Method not allowed' }, 405);

  const ip = clientIp(c);
  if (!allow(ip)) return c.json({ error: 'Too many requests. Please wait a moment.' }, 429);

  const body = (await jsonBody(c)) || {};
  let out;
  try {
    out = await portalRequestCore(c.env, { body, ip, nowMs: Date.now() });
  } catch (err) {
    console.error('[estimate/portal-request] failed:', err.message);
    return c.json({ error: 'Database error' }, 500);
  }
  return c.json(out.json, out.status);
}
