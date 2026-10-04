// GET /v1/* — the read-only open API (Roadmap Phase 23). Thin shell around
// lib/api/v1.js handleV1, where the whole request contract lives (tested).
//
// Deliberately NO CORS headers and no OPTIONS handling: browsers cannot read
// these responses cross-origin, so a key pasted into a web page is useless
// there. Keys are server-to-server only (decision D9).
//
// The caller's address is cf-connecting-ip ONLY — never x-forwarded-for,
// whose first entry the caller chooses (spec §0). It keys the failed-auth
// load guard and is written to the access log.

import { handleV1 } from '../../../lib/api/v1.js';
import { createAuthFailureGuard } from '../../../lib/api/auth.js';

const failureGuard = createAuthFailureGuard({ limit: 20 });

export async function apiV1Handler(c) {
  const ip = (c.req.header('cf-connecting-ip') || '').trim() || null;
  const out = await handleV1(
    { method: c.req.method, url: c.req.url, authorization: c.req.header('authorization'), ip },
    c.env,
    { nowMs: Date.now(), failureGuard }
  );
  for (const [name, value] of Object.entries(out.headers)) c.header(name, value);
  return c.json(out.body, out.status);
}
