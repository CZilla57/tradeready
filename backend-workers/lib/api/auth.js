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

// In-memory load guards (spec §6), per isolate. Load guards for junk and
// hammering traffic, not security boundaries (keys are 256-bit). Three
// independent layers, all bounded:
//
//   1. IP failure guard. The `limit`-th failed request in a window from one
//      cf-connecting-ip blocks that address for one window. It applies to
//      requests that carry NO well-formed key (missing or malformed
//      Authorization, key in the query, a bad route of that kind). A request
//      carrying a well-formed `trk_` key is NEVER rejected by it: valid keys
//      behind a shared egress IP (an integration platform, a corporate NAT)
//      must not be locked out by someone else's junk. Well-formed keys are
//      shed by the two per-hash layers below instead.
//   2. Unknown-key negative cache, keyed by sha256 of the presented key.
//      After `unknownLimit` "unknown key" answers for the same hash in a
//      window, that hash is answered 401 invalid_key from memory without the
//      RPC, until the window ends. At most `unknownLimit` RPCs per hash per
//      window reach the database.
//   3. Rate-limited-key shed, keyed the same way. Once the RPC answers
//      `rate_limited` for a hash, further requests with it are answered 429
//      from memory (same Retry-After and X-RateLimit-* the RPC gave) until
//      the reported reset, so a key over its limit costs no authorize RPC
//      (each takes the per-owner advisory lock).
//
// Only sha256 hex hashes ever enter the per-hash maps (anything else is
// ignored), never the presented key. Every map is capped: past the cap,
// expired entries are swept and then the oldest entries are evicted.
const GUARD_MAX_ENTRIES = 2000;
const HASH_RE = /^[0-9a-f]{64}$/;

function setBounded(map, key, value, max, isExpired) {
  map.delete(key); // re-insert so iteration order is write order (oldest first)
  map.set(key, value);
  if (map.size <= max) return;
  for (const [k, v] of map) if (isExpired(v)) map.delete(k);
  while (map.size > max) map.delete(map.keys().next().value);
}

function createAuthFailureGuard({
  limit = 20,
  windowMs = 60_000,
  unknownLimit = 5,
  maxEntries = GUARD_MAX_ENTRIES,
} = {}) {
  const failures = new Map(); // ip -> { start, count }
  const blockedUntil = new Map(); // ip -> ms
  const unknownKeys = new Map(); // key hash -> { start, count }
  const limitedKeys = new Map(); // key hash -> { until, rate }

  const windowExpired = (now) => (w) => now - w.start >= windowMs;

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
      const w = failures.get(ip);
      const next = w && now - w.start < windowMs ? { start: w.start, count: w.count + 1 } : { start: now, count: 1 };
      setBounded(failures, ip, next, maxEntries, windowExpired(now));
      if (next.count >= limit) {
        setBounded(blockedUntil, ip, now + windowMs, maxEntries, (until) => until <= now);
      }
    },

    // Answered from memory for this key hash, or null to go to the RPC.
    //   { error: 'invalid_key' }                       (negative cache)
    //   { error: 'rate_limited', retryAfter, rate }    (over its limit)
    keyShed(keyHash, now = Date.now()) {
      if (!HASH_RE.test(keyHash)) return null;
      const limited = limitedKeys.get(keyHash);
      if (limited) {
        if (limited.until > now) {
          return { error: 'rate_limited', retryAfter: Math.max(1, Math.ceil((limited.until - now) / 1000)), rate: limited.rate };
        }
        limitedKeys.delete(keyHash);
      }
      const unknown = unknownKeys.get(keyHash);
      if (unknown) {
        if (now - unknown.start >= windowMs) unknownKeys.delete(keyHash);
        else if (unknown.count >= unknownLimit) return { error: 'invalid_key' };
      }
      return null;
    },
    // The RPC said this hash is unknown.
    unknownKey(keyHash, now = Date.now()) {
      if (!HASH_RE.test(keyHash)) return;
      const w = unknownKeys.get(keyHash);
      const next = w && now - w.start < windowMs ? { start: w.start, count: w.count + 1 } : { start: now, count: 1 };
      setBounded(unknownKeys, keyHash, next, maxEntries, windowExpired(now));
    },
    // The RPC said this key is over its limit; `retryAfter` is whole seconds
    // to its reset (the route's default of 60 applies when the RPC gave none).
    rateLimitedKey(keyHash, { retryAfter, rate = null } = {}, now = Date.now()) {
      if (!HASH_RE.test(keyHash)) return;
      const seconds = Number.isFinite(retryAfter) && retryAfter >= 1 ? retryAfter : 60;
      setBounded(limitedKeys, keyHash, { until: now + seconds * 1000, rate }, maxEntries, (v) => v.until <= now);
    },

    // Test hook: how many entries each map holds.
    sizes() {
      return { ips: failures.size, blocked: blockedUntil.size, unknownKeys: unknownKeys.size, limitedKeys: limitedKeys.size };
    },
  };
}

module.exports = { authorizeKey, logApiRequest, eventForStatus, createAuthFailureGuard };
