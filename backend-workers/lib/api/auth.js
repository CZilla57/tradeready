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
// hammering traffic, not security boundaries (keys are 256-bit). Layers:
//
//   1. IP failure guard. The `limit`-th failed request in a window from one
//      cf-connecting-ip (every unknown/revoked/expired key, malformed or
//      missing key, key in the query) blocks that address for one window.
//      Requests with NO well-formed key are answered 429 while blocked.
//   2. Well-formed keys are never flatly rejected by the IP block (valid keys
//      behind a shared egress IP must keep working), but while their IP is
//      blocked a key hash NOT in the positive cache may reach the authorize
//      RPC only `ipBudget` times per window per IP; beyond that, 429 from
//      memory. A flood of distinct random well-formed keys therefore costs
//      the database at most `limit` + `ipBudget` RPCs per window per IP.
//   3. Positive cache: sha256 hashes that authorized (or were rate limited,
//      which only a live key can be) in the last `knownTtlMs`. A hash in it
//      is never held to the IP budget. It does NOT skip the RPC: revocation
//      and expiry are checked on every request, and a denial removes the hash.
//      Accepted trade-off: a valid key this isolate has not seen recently,
//      arriving from an address that is over the threshold, shares that IP's
//      small budget.
//   4. Unknown-key negative cache, keyed by hash: after `unknownLimit`
//      "unknown key" answers for one hash in a window, that hash is answered
//      401 invalid_key from memory until the window ends.
//   5. Rate-limited-key shed, keyed by hash: once the RPC answers
//      `rate_limited`, further requests with it are answered 429 from memory
//      (same Retry-After and X-RateLimit-*) until the reported reset.
//
// Only sha256 hex hashes ever enter the per-hash maps (anything else is
// ignored), never the presented key. Every map is separate and capped: past
// its cap, expired entries are swept and then the oldest in THAT map are
// evicted, so churn in one map (an attacker's random keys) cannot evict the
// entries of another (known-good keys, active rate-limit entries).
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
  ipBudget = 5,
  knownTtlMs = 300_000,
  maxKnownKeys = 500,
  maxEntries = GUARD_MAX_ENTRIES,
} = {}) {
  const failures = new Map(); // ip -> { start, count }
  const blockedUntil = new Map(); // ip -> ms
  const unknownKeys = new Map(); // key hash -> { start, count }
  const limitedKeys = new Map(); // key hash -> { until, rate }
  const knownKeys = new Map(); // key hash -> expiry ms (positive cache)
  const budgets = new Map(); // ip -> { start, count } of RPCs spent while blocked

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
      // A failure inside an existing block (a budgeted RPC) never extends it.
      if (next.count >= limit && !((blockedUntil.get(ip) || 0) > now)) {
        setBounded(blockedUntil, ip, now + windowMs, maxEntries, (until) => until <= now);
      }
    },
    // Spend one of the IP's RPC credits for a key hash outside the positive
    // cache. Meant for use only while the IP is blocked; false = answer 429.
    takeIpBudget(ip, now = Date.now()) {
      const w = budgets.get(ip);
      const cur = w && now - w.start < windowMs ? w : { start: now, count: 0 };
      if (cur.count >= ipBudget) return false;
      setBounded(budgets, ip, { start: cur.start, count: cur.count + 1 }, maxEntries, windowExpired(now));
      return true;
    },

    // Positive cache (never skips the RPC; it only exempts from the IP budget).
    isKnownKey(keyHash, now = Date.now()) {
      if (!HASH_RE.test(keyHash)) return false;
      const until = knownKeys.get(keyHash);
      if (!until) return false;
      if (until <= now) {
        knownKeys.delete(keyHash);
        return false;
      }
      return true;
    },
    knownKey(keyHash, now = Date.now()) {
      if (!HASH_RE.test(keyHash)) return;
      setBounded(knownKeys, keyHash, now + knownTtlMs, maxKnownKeys, (until) => until <= now);
    },
    forgetKey(keyHash) {
      knownKeys.delete(keyHash);
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
      return {
        ips: failures.size,
        blocked: blockedUntil.size,
        unknownKeys: unknownKeys.size,
        limitedKeys: limitedKeys.size,
        knownKeys: knownKeys.size,
        budgets: budgets.size,
      };
    },
  };
}

module.exports = { authorizeKey, logApiRequest, eventForStatus, createAuthFailureGuard };
