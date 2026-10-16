// GET /v1/* — the read-only open API (Roadmap Phase 23). Thin shell around
// lib/api/v1.js handleV1, where the whole request contract lives (tested).
//
// Deliberately NO CORS headers and no OPTIONS handling: browsers cannot read
// these responses cross-origin, so a key pasted into a web page is useless
// there. Keys are server-to-server only (decision D9).
//
// The caller's address is cf-connecting-ip ONLY — never x-forwarded-for,
// whose first entry the caller chooses (spec §0). The raw address is written
// to the access log; the request guard keys on clientKey() of it (the IPv4
// address or the IPv6 /64), and a request without the header shares one
// bucket with every other such request (spec §14.4a).

import { handleV1 } from '../../../lib/api/v1.js';
import { createApiGuard } from '../../../lib/api/auth.js';

// One guard per isolate; its windows and limits are GUARD_LIMITS in auth.js.
const guard = createApiGuard();

export async function apiV1Handler(c) {
  const ip = (c.req.header('cf-connecting-ip') || '').trim() || null;
  const out = await handleV1(
    { method: c.req.method, url: c.req.url, authorization: c.req.header('authorization'), ip },
    c.env,
    { nowMs: Date.now(), guard }
  );
  for (const [name, value] of Object.entries(out.headers)) c.header(name, value);
  return c.json(out.body, out.status);
}
