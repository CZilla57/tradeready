// API key resolution and the open API's only writes (spec §2, §4, §6).
//
// authorizeKey() is one round trip to the `api_key_authorize` RPC
// (supabase/migrations/20261003_api_keys.sql), which in ONE transaction:
// looks the hash up; refuses a revoked or expired key and logs `denied`
// against it; checks and increments the durable per-key minute/day and
// per-owner day counters (refusing over-limit requests with `rate_limited`);
// and bumps last_used_at at most once a minute. Only the sha256 HASH of the
// presented key ever leaves the Worker.
//
// Like the portal RPCs, a transport 404 means "not deployed" and the routes
// answer 503 `unavailable` — fail closed, never fall back to anything.
//
// logApiRequest() is the per-request audit row (`ok` | `denied` |
// `error` | `rate_limited`) for requests that resolved to a key. It stores
// the key id, the route TEMPLATE and the status — never the key, never
// query values. Best-effort: it never throws.

const { createRateLimiter } = require('../guards.js');

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const DENIED_ERRORS = new Set(['invalid_key', 'key_revoked', 'key_expired']);

function headers(env) {
  return {
    Authorization: `Bearer ${env.SUPABASE_SERVICE_ROLE_KEY}`,
    apikey: env.SUPABASE_SERVICE_ROLE_KEY,
    'Content-Type': 'application/json',
  };
}

function rateFrom(out) {
  const limit = Number(out.limit);
  const remaining = Number(out.remaining);
  const reset = Number(out.reset);
  if (!Number.isFinite(limit) || !Number.isFinite(remaining) || !Number.isFinite(reset)) return null;
  return { limit, remaining: Math.max(0, remaining), reset };
}

// Returns one of:
//   { kind: 'ok', userId, keyId, scopes, name, prefix, expiresAt, rate }
//   { kind: 'denied', error: 'invalid_key' | 'key_revoked' | 'key_expired' }
//   { kind: 'rate_limited', retryAfter, rate }
//   { kind: 'unavailable' }               (RPC not deployed / bad envelope)
// Throws on transport failure; the caller maps that to 503 too.
async function authorizeKey(env, { keyHash, route, ip }) {
  let res;
  try {
    res = await fetch(`${env.SUPABASE_URL}/rest/v1/rpc/api_key_authorize`, {
      method: 'POST',
      headers: headers(env),
      body: JSON.stringify({ p_key_hash: keyHash, p_route: route, p_ip: ip || null }),
    });
  } catch (err) {
    throw new Error(`api_key_authorize transport failed: ${err.message}`);
  }
  if (res.status === 404) return { kind: 'unavailable' };
  if (!res.ok) throw new Error(`api_key_authorize returned ${res.status}`);
  let out;
  try {
    out = await res.json();
  } catch {
    return { kind: 'unavailable' };
  }
  if (!out || typeof out.ok !== 'boolean') return { kind: 'unavailable' };
  if (!out.ok) {
    if (DENIED_ERRORS.has(out.error)) return { kind: 'denied', error: out.error };
    if (out.error === 'rate_limited') {
      const retryAfter = Math.max(1, Math.ceil(Number(out.retryAfter) || 60));
      return { kind: 'rate_limited', retryAfter, rate: rateFrom(out) };
    }
    return { kind: 'unavailable' };
  }
  // A success envelope must name a real owner and key; anything else fails
  // closed rather than reading data for an unknown tenant.
  if (typeof out.userId !== 'string' || !UUID_RE.test(out.userId)) return { kind: 'unavailable' };
  if (typeof out.keyId !== 'string' || !UUID_RE.test(out.keyId)) return { kind: 'unavailable' };
  if (!Array.isArray(out.scopes)) return { kind: 'unavailable' };
  return {
    kind: 'ok',
    userId: out.userId,
    keyId: out.keyId,
    scopes: out.scopes.filter((s) => typeof s === 'string'),
    name: typeof out.name === 'string' ? out.name : null,
    prefix: typeof out.prefix === 'string' ? out.prefix : null,
    expiresAt: typeof out.expiresAt === 'string' ? out.expiresAt : null,
    rate: rateFrom(out),
  };
}

function eventForStatus(status) {
  if (status >= 200 && status < 300) return 'ok';
  if (status === 403) return 'denied';
  if (status === 429) return 'rate_limited';
  return 'error';
}

async function logApiRequest(env, { userId, keyId, route, status, ip }) {
  try {
    const res = await fetch(`${env.SUPABASE_URL}/rest/v1/api_access_log`, {
      method: 'POST',
      headers: { ...headers(env), Prefer: 'return=minimal' },
      body: JSON.stringify({
        user_id: userId,
        key_id: keyId,
        event: eventForStatus(status),
        route,
        status,
        ip: ip || null,
      }),
    });
    if (!res.ok) console.error('[api/v1] access log write failed:', res.status);
  } catch (err) {
    console.error('[api/v1] access log write threw:', err.message);
  }
}

// Failed-auth load guard (spec §6): 20 failures per minute per
// cf-connecting-ip, per isolate. A load guard for junk traffic, not a
// security boundary (keys are 256-bit). Built on the shared
// createRateLimiter: each failure is one hit, and the `limit`-th failure in
// a window (the first hit the limiter refuses) opens a block for one
// window. The block is checked BEFORE the RPC, so at most `limit` failures
// per window ever reach the database from one address.
function createAuthFailureGuard({ limit = 20, windowMs = 60_000 } = {}) {
  const record = createRateLimiter({ limit: limit - 1, windowMs });
  const blockedUntil = new Map();
  return {
    // Seconds until the block lifts, or 0 when not blocked.
    blockedFor(ip, now = Date.now()) {
      const until = blockedUntil.get(ip);
      if (!until) return 0;
      if (until <= now) {
        blockedUntil.delete(ip);
        return 0;
      }
      return Math.ceil((until - now) / 1000);
    },
    fail(ip, now = Date.now()) {
      if (!record(ip, now)) {
        blockedUntil.set(ip, now + windowMs);
        if (blockedUntil.size > 1000) {
          for (const [k, until] of blockedUntil) if (until <= now) blockedUntil.delete(k);
        }
      }
    },
  };
}

module.exports = { authorizeKey, logApiRequest, eventForStatus, createAuthFailureGuard };
