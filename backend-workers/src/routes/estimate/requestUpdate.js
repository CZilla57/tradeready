// POST /api/estimate/request-update  { jobId, token, note?, website } — the
// estimate page's "Request an updated estimate" once an estimate is past its
// valid-until date (Phase 32 §4.5). Thin Hono shell; the whole
// accept/reject surface lives in lib/estimate/estimateUpdateRequest.js
// (tested there).

import { applyCors } from '../../../lib/estimate/cors.js';
import { createRateLimiter } from '../../../lib/guards.js';
import { estimateUpdateRequestCore } from '../../../lib/estimate/estimateUpdateRequest.js';
import { clientIp, jsonBody } from '../../appCors.js';

const allow = createRateLimiter({ limit: 5 });

export async function estimateRequestUpdateHandler(c) {
  applyCors(c, 'POST, OPTIONS');
  if (c.req.method === 'OPTIONS') return c.body(null, 200);
  if (c.req.method !== 'POST') return c.json({ error: 'Method not allowed' }, 405);

  const ip = clientIp(c);
  if (!allow(ip)) return c.json({ error: 'Too many requests. Please wait a moment.' }, 429);

  const body = (await jsonBody(c)) || {};
  let out;
  try {
    out = await estimateUpdateRequestCore(c.env, { body, ip, nowMs: Date.now() });
  } catch (err) {
    console.error('[estimate/request-update] failed:', err.message);
    return c.json({ error: 'Database error' }, 500);
  }
  return c.json(out.json, out.status);
}
