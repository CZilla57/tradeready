// POST /api/calendar/busy — the owner's calendar busy times (Roadmap Phase 26,
// spec docs/superpowers/specs/2026-10-03-calendar-sync-design.md §3.1). Owner
// JWT wrapper copied from routes/booking/admin.js: static CORS, the same auth
// resolution, and a per-user limit (20 per window). The contract lives in
// lib/calendar/busyCore.js so tests run it without a Hono context.
//
// Request: {action: put|status|disable, sourceId?, snapshot?, takeOver?}.
// The raw body is size-checked (64 KB) before it is parsed.

import { busyCore } from '../../../lib/calendar/busyCore.js';
import { MAX_BODY_BYTES } from '../../../lib/calendar/busyGate.js';
import { createRateLimiter } from '../../../lib/guards.js';

const allow = createRateLimiter({ limit: 20 });

export async function calendarBusyHandler(c) {
  // Native fetch from the app — CORS is inert here; static real host, like
  // booking admin/mint.
  c.header('Access-Control-Allow-Origin', 'https://gettradereadyapp.com');
  c.header('Access-Control-Allow-Methods', 'POST, OPTIONS');
  c.header('Access-Control-Allow-Headers', 'Content-Type, Authorization');
  if (c.req.method === 'OPTIONS') return c.body(null, 200);
  if (c.req.method !== 'POST') return c.json({ error: 'Method not allowed' }, 405);

  const { SUPABASE_URL, SUPABASE_ANON_KEY } = c.env;
  if (!SUPABASE_URL || !SUPABASE_ANON_KEY) return c.json({ error: 'Server misconfiguration.' }, 500);

  const auth = c.req.header('authorization');
  if (!auth || !auth.startsWith('Bearer ')) return c.json({ error: 'Unauthorized' }, 401);
  const userRes = await fetch(`${SUPABASE_URL}/auth/v1/user`, {
    headers: { Authorization: auth, apikey: SUPABASE_ANON_KEY },
  });
  if (!userRes.ok) return c.json({ error: 'Invalid or expired session.' }, 401);
  const userId = (await userRes.json())?.id;
  if (!userId) return c.json({ error: 'Unauthorized' }, 401);

  if (!allow(userId)) return c.json({ error: 'Too many requests. Please wait a moment.' }, 429);

  const raw = await c.req.text().catch(() => '');
  const bodyBytes = new TextEncoder().encode(raw).length;
  if (bodyBytes > MAX_BODY_BYTES) return c.json({ error: 'invalid_snapshot' }, 400);
  let body;
  try {
    body = raw ? JSON.parse(raw) : {};
  } catch {
    body = {};
  }

  const { status, body: out } = await busyCore(c.env, { userId, body, nowMs: Date.now(), bodyBytes });
  return c.json(out, status);
}
