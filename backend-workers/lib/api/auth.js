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

// In-memory request guard (spec §6, §14.4a), per isolate. A load guard, not a
// security boundary (keys are 256-bit): it bounds how many authorize RPCs a
// caller can cause, before the RPC is ever awaited.
//
//   Client key. The IPv4 address, or the IPv6 /64 prefix (one subscriber's
//   allocation), from cf-connecting-ip. Requests without the header share one
//   bucket (accepted: Cloudflare always sets it).
//
//   Positive cache. A sha256 hash that authorized (or was rate limited, which
//   only a live key can be) on this isolate in the last 60 minutes. It never
//   skips the RPC (revocation, expiry and rate limits are checked on every
//   admitted request); it only lets the hash bypass the token buckets. At most
//   KNOWN_IN_FLIGHT of its RPCs run at once; excess is 429 from memory.
//
//   Token buckets. Any other well-formed key must take one token from its
//   client's bucket AND one from the isolate-wide bucket, synchronously before
//   the RPC is awaited; if either is empty, 429 from memory with Retry-After to
//   that window's end. Both tokens are refunded only when the RPC answers `ok`
//   or `rate_limited` (a live key), and only to the window that issued them.
//   Denials, `unavailable` and transport failures keep them. So per isolate
//   and window: at most CLIENT_TOKENS RPCs per client and GLOBAL_TOKENS in all
//   for hashes outside the positive cache, whatever the RPC answers.
//
//   Negative cache. The first unknown/revoked/expired answer for a hash is
//   remembered for DENIED_TTL_MS and answered from memory (no token, no RPC);
//   the denial also removes the hash from the positive cache.
//
//   Rate-limited shed. A `rate_limited` answer makes that hash 429 from memory
//   (same Retry-After and X-RateLimit-*) until the reported reset.
//
//   Junk counter. Requests with a missing or malformed key, or a key in the
//   query string, count per client; past JUNK_LIMIT in a window, missing or
//   malformed keys get 429 until the window ends. It never touches a request
//   that carries a well-formed key.
//
// Every structure is its own capped Map that evicts its own oldest entries,
// so churn in one cannot evict another. Evicting a client's bucket is
// harmless: the isolate-wide bucket still bounds the RPCs. The in-flight map
// never evicts (its entries are all busy); at its cap a new hash is refused. Only sha256 hex
// hashes enter the per-hash maps (anything else is ignored), never a key.

// Every window and limit of the guard, in one place.
const GUARD_LIMITS = Object.freeze({
  WINDOW_MS: 60_000, // one window for the token buckets and the junk counter
  CLIENT_TOKENS: 10, // RPCs per client per window, hashes outside the positive cache
  GLOBAL_TOKENS: 60, // RPCs per isolate per window, hashes outside the positive cache
  KNOWN_IN_FLIGHT: 4, // concurrent RPCs per positively cached hash
  KNOWN_TTL_MS: 3_600_000, // positive cache lifetime (refreshed by each success)
  DENIED_TTL_MS: 60_000, // negative cache lifetime (unknown, revoked, expired)
  JUNK_LIMIT: 20, // keyless/malformed/query-key requests per client per window
  MAX_CLIENTS: 2000, // per-client token buckets
  MAX_JUNK_CLIENTS: 2000, // per-client junk counters
  MAX_KNOWN_KEYS: 1000, // positive cache
  MAX_IN_FLIGHT_KEYS: 1000, // busy known hashes at once (an entry exists only while busy; refused past it)
  MAX_DENIED_KEYS: 2000, // negative cache
  MAX_LIMITED_KEYS: 2000, // rate-limited shed
});

const HASH_RE = /^[0-9a-f]{64}$/;
const NO_IP_CLIENT = 'no-ip';
const NEGATIVE_ERRORS = DENIED_ERRORS;

// Expands an IPv6 address to its /64 prefix ("2001:db8:1:2::/64"); an
// IPv4-mapped address is its IPv4 client. Null when it does not parse.
function ipv6Client(raw) {
  let addr = raw.replace(/^\[|\]$/g, '').split('%')[0];
  const dotted = /^(.*:)(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/.exec(addr);
  if (dotted) {
    const b = dotted.slice(2).map(Number);
    if (b.some((x) => x > 255)) return null;
    addr = `${dotted[1]}${((b[0] << 8) | b[1]).toString(16)}:${((b[2] << 8) | b[3]).toString(16)}`;
  }
  const halves = addr.split('::');
  if (halves.length > 2) return null;
  const part = (h) => (h === '' ? [] : h.split(':'));
  const head = part(halves[0]);
  const tail = halves.length === 2 ? part(halves[1]) : [];
  if (halves.length === 2 && head.length + tail.length > 7) return null;
  const groups = halves.length === 2 ? [...head, ...Array(8 - head.length - tail.length).fill('0'), ...tail] : head;
  if (groups.length !== 8 || !groups.every((g) => /^[0-9a-f]{1,4}$/.test(g))) return null;
  const n = groups.map((g) => parseInt(g, 16));
  if (n.slice(0, 5).every((x) => x === 0) && n[5] === 0xffff) {
    return `${n[6] >> 8}.${n[6] & 255}.${n[7] >> 8}.${n[7] & 255}`;
  }
  return `${n.slice(0, 4).map((x) => x.toString(16)).join(':')}::/64`;
}

// The guard's client key for a cf-connecting-ip value.
function clientKey(ip) {
  if (typeof ip !== 'string' || ip.trim() === '') return NO_IP_CLIENT;
  const s = ip.trim().toLowerCase().slice(0, 64);
  if (!s.includes(':')) return s;
  return ipv6Client(s) || s;
}

function setBounded(map, key, value, max, isExpired) {
  map.delete(key); // re-insert so iteration order is write order (oldest first)
  map.set(key, value);
  if (map.size <= max) return;
  for (const [k, v] of map) if (k !== key && isExpired(v)) map.delete(k);
  while (map.size > max) map.delete(map.keys().next().value);
}

function createApiGuard(overrides = {}) {
  const L = { ...GUARD_LIMITS, ...overrides };
  const clients = new Map(); // client -> { start, used } token bucket
  const junk = new Map(); // client -> { start, count }
  const knownKeys = new Map(); // key hash -> expiry ms (positive cache)
  const inFlight = new Map(); // key hash -> { count } while its RPCs run
  const deniedKeys = new Map(); // key hash -> { until, error } (negative cache)
  const limitedKeys = new Map(); // key hash -> { until, rate }
  // A window is an object; when it ends it is REPLACED, never reset, so a
  // late refund can tell whether the window that issued its token is current.
  let globalWindow = { start: -Infinity, used: 0 };

  const current = (w, now) => Boolean(w) && now - w.start < L.WINDOW_MS;
  const secondsLeft = (w, now) => Math.max(1, Math.ceil((w.start + L.WINDOW_MS - now) / 1000));

  return {
    limits: L,

    // Keyless, malformed or query-string key: count it; returns the seconds
    // to answer 429 for, or 0 to answer normally.
    junkRequest(client, now = Date.now()) {
      let w = junk.get(client);
      if (!current(w, now)) w = { start: now, count: 0 };
      if (w.count >= L.JUNK_LIMIT) return secondsLeft(w, now);
      w.count += 1;
      setBounded(junk, client, w, L.MAX_JUNK_CLIENTS, (v) => !current(v, now));
      return 0;
    },

    // For a hash outside the positive cache, before the RPC: one token from
    // the client's bucket and one from the isolate's, or neither.
    //   { ticket }       admitted; pass the ticket to refundTokens
    //   { retryAfter }   a bucket is empty; answer 429
    takeTokens(client, now = Date.now()) {
      let c = clients.get(client);
      if (!current(c, now)) c = { start: now, used: 0 };
      if (!current(globalWindow, now)) globalWindow = { start: now, used: 0 };
      const g = globalWindow;
      const clientEmpty = c.used >= L.CLIENT_TOKENS;
      const globalEmpty = g.used >= L.GLOBAL_TOKENS;
      if (clientEmpty || globalEmpty) {
        return { retryAfter: Math.max(clientEmpty ? secondsLeft(c, now) : 0, globalEmpty ? secondsLeft(g, now) : 0) };
      }
      c.used += 1;
      g.used += 1;
      setBounded(clients, client, c, L.MAX_CLIENTS, (v) => !current(v, now));
      return { ticket: { client, clientWindow: c, globalWindow: g, refunded: false } };
    },

    // The RPC called the key live (`ok` or `rate_limited`): give both tokens
    // back, each only to the window that issued it and only if that window is
    // still the bucket's current one (an ended window has been replaced).
    refundTokens(ticket) {
      if (!ticket || ticket.refunded) return;
      ticket.refunded = true;
      const c = ticket.clientWindow;
      if (clients.get(ticket.client) === c && c.used > 0) c.used -= 1;
      const g = ticket.globalWindow;
      if (globalWindow === g && g.used > 0) g.used -= 1;
    },

    // For a positively cached hash: a slot, or null when KNOWN_IN_FLIGHT of
    // its RPCs are already running (or MAX_IN_FLIGHT_KEYS hashes are busy).
    // Release it in a `finally`.
    takeInFlight(keyHash) {
      if (!HASH_RE.test(keyHash)) return null;
      let e = inFlight.get(keyHash);
      if (e) {
        if (e.count >= L.KNOWN_IN_FLIGHT) return null;
        e.count += 1;
      } else {
        // An entry exists only while its hash is busy, so at the cap every
        // entry is busy: refuse rather than evict one, which would let that
        // hash start KNOWN_IN_FLIGHT more. Known-key RPCs in flight per
        // isolate are thus at most MAX_IN_FLIGHT_KEYS * KNOWN_IN_FLIGHT.
        if (inFlight.size >= L.MAX_IN_FLIGHT_KEYS) return null;
        e = { count: 1 };
        inFlight.set(keyHash, e);
      }
      return { keyHash, entry: e, released: false };
    },
    releaseInFlight(slot) {
      if (!slot || slot.released) return;
      slot.released = true;
      slot.entry.count -= 1;
      if (slot.entry.count <= 0 && inFlight.get(slot.keyHash) === slot.entry) inFlight.delete(slot.keyHash);
    },

    // Positive cache (never skips the RPC; it only bypasses the buckets).
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
      deniedKeys.delete(keyHash);
      setBounded(knownKeys, keyHash, now + L.KNOWN_TTL_MS, L.MAX_KNOWN_KEYS, (until) => until <= now);
    },

    // The RPC said unknown, revoked or expired: answer it from memory for
    // DENIED_TTL_MS, and drop it from the positive cache.
    deniedKey(keyHash, error, now = Date.now()) {
      if (!HASH_RE.test(keyHash)) return;
      knownKeys.delete(keyHash);
      if (!NEGATIVE_ERRORS.has(error)) return;
      setBounded(deniedKeys, keyHash, { until: now + L.DENIED_TTL_MS, error }, L.MAX_DENIED_KEYS, (v) => v.until <= now);
    },

    // The RPC said this key is over its limit; `retryAfter` is whole seconds
    // to its reset (60 when the RPC gave none).
    rateLimitedKey(keyHash, { retryAfter, rate = null } = {}, now = Date.now()) {
      if (!HASH_RE.test(keyHash)) return;
      const seconds = Number.isFinite(retryAfter) && retryAfter >= 1 ? retryAfter : 60;
      setBounded(limitedKeys, keyHash, { until: now + seconds * 1000, rate }, L.MAX_LIMITED_KEYS, (v) => v.until <= now);
    },

    // Answered from memory for this key hash, or null to go on:
    //   { error: 'rate_limited', retryAfter, rate }                 (over its limit)
    //   { error: 'invalid_key' | 'key_revoked' | 'key_expired' }    (negative cache)
    keyShed(keyHash, now = Date.now()) {
      if (!HASH_RE.test(keyHash)) return null;
      const limited = limitedKeys.get(keyHash);
      if (limited) {
        if (limited.until > now) {
          return { error: 'rate_limited', retryAfter: Math.max(1, Math.ceil((limited.until - now) / 1000)), rate: limited.rate };
        }
        limitedKeys.delete(keyHash);
      }
      const denied = deniedKeys.get(keyHash);
      if (denied) {
        if (denied.until > now) return { error: denied.error };
        deniedKeys.delete(keyHash);
      }
      return null;
    },

    // Test hook: how many entries each map holds.
    sizes() {
      return {
        clients: clients.size,
        junk: junk.size,
        knownKeys: knownKeys.size,
        inFlight: inFlight.size,
        deniedKeys: deniedKeys.size,
        limitedKeys: limitedKeys.size,
      };
    },
  };
}

module.exports = { authorizeKey, logApiRequest, eventForStatus, createApiGuard, clientKey, GUARD_LIMITS };
