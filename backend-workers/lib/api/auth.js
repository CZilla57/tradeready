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
// security boundary (keys carry 256 random bits): it bounds how many
// authorize RPCs a caller can cause, before the RPC is ever awaited.
//
// Only tag-valid keys reach it (keys.js verifyApiKey, checked in v1.js before
// any of this): a forged, random or untagged key is answered 401 without a
// token, a cache entry or an RPC. So everything below is spent only by keys
// the Worker itself minted, and each one names its owner.
//
//   Client key. The IPv4 address, or the IPv6 /64 prefix (one subscriber's
//   allocation), from cf-connecting-ip. Requests without the header share one
//   bucket (accepted: Cloudflare always sets it).
//
//   Per-hash in flight. At most KNOWN_IN_FLIGHT RPCs run at once for one key
//   hash, whether or not it is in the positive cache; excess is 429 from
//   memory (Retry-After: 1). The slot is taken before the RPC and released in
//   a `finally`.
//
//   Positive cache. A sha256 hash that authorized (or was rate limited, which
//   only a live key can be) on this isolate in the last 60 minutes. It never
//   skips the RPC (revocation, expiry and rate limits are checked on every
//   admitted request); it only lets the hash bypass the token buckets. LRU
//   (a hit moves it to the back), at most MAX_KNOWN_PER_OWNER per owner.
//
//   Token buckets. Any other key must take one token from its client's
//   bucket, one from its OWNER's bucket and one isolate token, synchronously
//   before the RPC is awaited; if any is empty, 429 from memory with
//   Retry-After to that window's end. The isolate token comes from the shared
//   pool (GLOBAL_TOKENS) or, once that is empty, from the reserve
//   (GLOBAL_RESERVE), but only for an owner that holds no token in the
//   window: one cold admission per owner at a time. All tokens are refunded
//   only when the RPC answers `ok` or `rate_limited` (a live key), and only
//   to the window and pool that issued them. Denials, `unavailable` and
//   transport failures keep them. So per isolate and window, hashes outside
//   the positive cache cause at most CLIENT_TOKENS RPCs per client,
//   OWNER_TOKENS per owner and GLOBAL_TOKENS + GLOBAL_RESERVE in all, plus
//   one more per refunded admission, whatever the RPC answers (outages
//   included; once an RPC fails in a window the reserve closes, so an outage
//   sequence stays at GLOBAL_TOKENS). Owners whose dead keys empty the shared
//   pool cannot lock out another owner until GLOBAL_RESERVE more owners have
//   done the same.
//
//   Negative cache. The first unknown, revoked or expired answer for a
//   tag-valid hash is final and remembered for the key's life, answered from
//   memory (no token, no RPC). At most MAX_DENIED_PER_OWNER entries per owner
//   (the owner's oldest goes first), so cycling a pool of one owner's dead
//   keys larger than that only re-spends that owner's tokens. The denial
//   also removes the hash from the positive cache.
//
//   Rate-limited shed. A `rate_limited` answer makes that hash 429 from memory
//   (same Retry-After and X-RateLimit-*) until the reported reset.
//
//   Junk counter. Requests with a missing, malformed or forged key, or a key
//   in the query string, count per client; past JUNK_LIMIT in a window,
//   missing, malformed or forged keys get 429 until the window ends. It never
//   touches a request that carries a tag-valid key.
//
// Every structure is its own capped Map that evicts its own oldest entries,
// so churn in one cannot evict another. Evicting a client's bucket is
// harmless: the isolate-wide pools still bound the RPCs. The
// in-flight map never evicts (its entries are all busy); at its cap a new
// hash is refused. Only sha256 hex hashes enter the per-hash maps (anything
// else is ignored), never a key.

// Every window and limit of the guard, in one place.
const GUARD_LIMITS = Object.freeze({
  WINDOW_MS: 60_000, // one window for the token buckets and the junk counter
  CLIENT_TOKENS: 10, // RPCs per client per window, hashes outside the positive cache
  OWNER_TOKENS: 10, // RPCs per owner (from the key's tag) per window, hashes outside the positive cache
  GLOBAL_TOKENS: 60, // shared isolate pool per window, hashes outside the positive cache
  GLOBAL_RESERVE: 240, // per window: an owner holding no token may take its first one here when the shared pool is empty
  KNOWN_IN_FLIGHT: 4, // concurrent RPCs per key hash (cached or not)
  KNOWN_TTL_MS: 3_600_000, // positive cache lifetime (refreshed by each success)
  JUNK_LIMIT: 20, // keyless/malformed/forged/query-key requests per client per window
  MAX_CLIENTS: 2000, // per-client token buckets
  MAX_OWNERS: 10_000, // per-owner token buckets
  MAX_JUNK_CLIENTS: 2000, // per-client junk counters
  MAX_KNOWN_KEYS: 10_000, // positive cache
  MAX_KNOWN_PER_OWNER: 10, // positive-cache entries per owner (an owner has at most 10 working keys)
  MAX_IN_FLIGHT_KEYS: 1000, // busy known hashes at once (an entry exists only while busy; refused past it)
  MAX_DENIED_KEYS: 10_000, // negative cache (dead keys)
  MAX_DENIED_PER_OWNER: 100, // negative-cache entries per owner; past it the owner's oldest goes
  MAX_LIMITED_KEYS: 2000, // rate-limited shed
});

const HASH_RE = /^[0-9a-f]{64}$/;
const NO_IP_CLIENT = 'no-ip';
const NEGATIVE_ERRORS = DENIED_ERRORS;
// Every denial of a TAG-VALID key is one-way: a revoked key is never
// un-revoked, an expired key never un-expires, and an unknown hash never
// appears later (its id came from the Worker CSPRNG at mint, so an absent row
// was deleted with its account or never committed, and its secret was never
// handed out). All three are remembered for the key's life, until evicted.
const DEAD_ERRORS = new Set(['key_revoked', 'key_expired', 'invalid_key']);

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

// A capped map whose entries belong to owners: at most maxPerOwner entries per
// owner (the owner's oldest goes first), then at most maxTotal in all
// (expired first, then oldest). Iteration order is write order, so a re-set
// moves an entry to the back (LRU). An entry without an owner is only under
// the total cap.
function ownedMap(maxTotal, maxPerOwner) {
  const entries = new Map(); // key -> { value, owner }
  const byOwner = new Map(); // owner -> Set(key), oldest first
  function remove(key) {
    const e = entries.get(key);
    if (!e) return;
    entries.delete(key);
    const set = e.owner ? byOwner.get(e.owner) : null;
    if (set) {
      set.delete(key);
      if (set.size === 0) byOwner.delete(e.owner);
    }
  }
  return {
    get: (key) => entries.get(key),
    remove,
    size: () => entries.size,
    set(key, value, owner, isExpired) {
      remove(key);
      const o = typeof owner === 'string' && owner !== '' ? owner : null;
      entries.set(key, { value, owner: o });
      if (o) {
        let set = byOwner.get(o);
        if (!set) byOwner.set(o, (set = new Set()));
        set.add(key);
        while (set.size > maxPerOwner) remove(set.values().next().value);
      }
      if (entries.size <= maxTotal) return;
      for (const [k, e] of entries) if (k !== key && isExpired(e.value)) remove(k);
      while (entries.size > maxTotal) remove(entries.keys().next().value);
    },
  };
}

function createApiGuard(overrides = {}) {
  const L = { ...GUARD_LIMITS, ...overrides };
  const clients = new Map(); // client -> { start, used } token bucket
  const owners = new Map(); // owner id -> { start, used } token bucket
  const junk = new Map(); // client -> { start, count }
  const knownKeys = ownedMap(L.MAX_KNOWN_KEYS, L.MAX_KNOWN_PER_OWNER); // key hash -> expiry ms (positive cache, LRU)
  const inFlight = new Map(); // key hash -> { count } while its RPCs run
  const deniedKeys = ownedMap(L.MAX_DENIED_KEYS, L.MAX_DENIED_PER_OWNER); // key hash -> error (negative cache, for life)
  const limitedKeys = new Map(); // key hash -> { until, rate }
  // A window is an object; when it ends it is REPLACED, never reset, so a
  // late refund can tell whether the window that issued its token is current.
  // `used` counts the shared pool, `reserved` the reserve (see takeTokens);
  // `failed` closes the reserve once an RPC in the window failed.
  let globalWindow = { start: -Infinity, used: 0, reserved: 0, failed: false };

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

    // Read-only: the seconds this client's junk counter would answer 429 for
    // right now, or 0. Counts nothing.
    junkBlocked(client, now = Date.now()) {
      const w = junk.get(client);
      if (!current(w, now) || w.count < L.JUNK_LIMIT) return 0;
      return secondsLeft(w, now);
    },

    // For a hash outside the positive cache, before the RPC: one token from
    // the client's bucket, one from the owner's (when an owner is given) and
    // one isolate token, or none. The isolate token comes from the shared
    // pool (GLOBAL_TOKENS); when that is empty, an owner that holds no token
    // in this window may take its first one from the reserve
    // (GLOBAL_RESERVE). So owners that spend the shared pool on denied keys
    // cannot lock another owner out, and the isolate still admits at most
    // GLOBAL_TOKENS + GLOBAL_RESERVE per window (plus refunded admissions).
    //   { ticket }       admitted; pass the ticket to refundTokens
    //   { retryAfter }   a bucket is empty; answer 429
    takeTokens(client, now = Date.now(), owner = null) {
      let c = clients.get(client);
      if (!current(c, now)) c = { start: now, used: 0 };
      let o = null;
      if (typeof owner === 'string' && owner !== '') {
        o = owners.get(owner);
        if (!current(o, now)) o = { start: now, used: 0 };
      }
      if (!current(globalWindow, now)) globalWindow = { start: now, used: 0, reserved: 0, failed: false };
      const g = globalWindow;
      const clientEmpty = c.used >= L.CLIENT_TOKENS;
      const ownerEmpty = Boolean(o) && o.used >= L.OWNER_TOKENS;
      let pool = null;
      if (g.used < L.GLOBAL_TOKENS) pool = 'shared';
      else if (o && o.used === 0 && !g.failed && g.reserved < L.GLOBAL_RESERVE) pool = 'reserve';
      if (clientEmpty || ownerEmpty || !pool) {
        return {
          retryAfter: Math.max(
            clientEmpty ? secondsLeft(c, now) : 0,
            ownerEmpty ? secondsLeft(o, now) : 0,
            pool ? 0 : secondsLeft(g, now)
          ),
        };
      }
      c.used += 1;
      if (pool === 'shared') g.used += 1;
      else g.reserved += 1;
      setBounded(clients, client, c, L.MAX_CLIENTS, (v) => !current(v, now));
      if (o) {
        o.used += 1;
        setBounded(owners, owner, o, L.MAX_OWNERS, (v) => !current(v, now));
      }
      return { ticket: { client, clientWindow: c, owner: o ? owner : null, ownerWindow: o, globalWindow: g, pool, refunded: false } };
    },

    // The RPC called the key live (`ok` or `rate_limited`): give every token
    // back, each only to the window that issued it and only if that window is
    // still the bucket's current one (an ended window has been replaced).
    refundTokens(ticket) {
      if (!ticket || ticket.refunded) return;
      ticket.refunded = true;
      const c = ticket.clientWindow;
      if (clients.get(ticket.client) === c && c.used > 0) c.used -= 1;
      const o = ticket.ownerWindow;
      if (o && owners.get(ticket.owner) === o && o.used > 0) o.used -= 1;
      const g = ticket.globalWindow;
      if (globalWindow === g) {
        if (ticket.pool === 'reserve') {
          if (g.reserved > 0) g.reserved -= 1;
        } else if (g.used > 0) g.used -= 1;
      }
    },

    // An RPC failed (`unavailable`, transport error): close the reserve for
    // the rest of this window. The reserve exists so denied keys cannot lock
    // other owners out; it is not a way to send more traffic into an outage,
    // so an outage stays at GLOBAL_TOKENS per window (plus reserve tokens
    // already taken before the first failure came back).
    rpcFailed(now = Date.now()) {
      if (current(globalWindow, now)) globalWindow.failed = true;
    },

    // Test hook: isolate tokens (shared + reserve) spent in the current window.
    globalTokensUsed(now = Date.now()) {
      return current(globalWindow, now) ? globalWindow.used + globalWindow.reserved : 0;
    },

    // For any tag-valid hash: a slot, or null when KNOWN_IN_FLIGHT of its RPCs
    // are already running (or MAX_IN_FLIGHT_KEYS hashes are busy). Release it
    // in a `finally` (or at once when the request is refused afterwards).
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
    // LRU: a hit moves the entry to the back without extending its TTL, so a
    // key in active use is the last to be evicted; and one owner holds at
    // most MAX_KNOWN_PER_OWNER entries.
    isKnownKey(keyHash, now = Date.now()) {
      if (!HASH_RE.test(keyHash)) return false;
      const e = knownKeys.get(keyHash);
      if (!e) return false;
      if (e.value <= now) {
        knownKeys.remove(keyHash);
        return false;
      }
      knownKeys.set(keyHash, e.value, e.owner, (until) => until <= now);
      return true;
    },
    knownKey(keyHash, now = Date.now(), owner = null) {
      if (!HASH_RE.test(keyHash)) return;
      deniedKeys.remove(keyHash);
      knownKeys.set(keyHash, now + L.KNOWN_TTL_MS, owner, (until) => until <= now);
    },

    // The RPC said unknown, revoked or expired. For a tag-valid key every one
    // of these is final, so it is answered from memory for the key's life
    // (until evicted: per owner past MAX_DENIED_PER_OWNER, then oldest past
    // MAX_DENIED_KEYS), and dropped from the positive cache. An evicted key
    // that comes back is an unseen key again and spends its owner's tokens.
    deniedKey(keyHash, error, now = Date.now(), owner = null) {
      if (!HASH_RE.test(keyHash)) return;
      knownKeys.remove(keyHash);
      if (!NEGATIVE_ERRORS.has(error) || !DEAD_ERRORS.has(error)) return;
      deniedKeys.set(keyHash, error, owner, () => false);
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
      if (denied) return { error: denied.value };
      return null;
    },

    // Test hook: how many entries each map holds.
    sizes() {
      return {
        clients: clients.size,
        owners: owners.size,
        junk: junk.size,
        knownKeys: knownKeys.size(),
        inFlight: inFlight.size,
        deniedKeys: deniedKeys.size(),
        limitedKeys: limitedKeys.size,
      };
    },
  };
}

module.exports = { authorizeKey, logApiRequest, eventForStatus, createApiGuard, clientKey, GUARD_LIMITS };
