// The /v1 request contract (spec §5–§7), as one testable function. The
// Hono route (src/routes/api/v1.js) is a thin shell around handleV1.
//
// Order of checks, each one cheaper than the next:
//   1. GET only → 405 method_not_allowed + Allow: GET (no OPTIONS, no CORS).
//   2. A key in the query string → 400 key_in_query (before routing, so a
//      key pasted into any URL is refused, not silently ignored).
//   3. Unknown path → 404 not_found. /v1/openapi.json is public.
//   4. API_KEY_TAG_SECRET unset (or shorter than 32 characters) → 503
//      not_configured for every authenticated route. Fail closed: there is
//      no untagged-key path.
//   5. Bearer parse, then the key's HMAC tag (keys.js verifyApiKey). A
//      missing, malformed or forged key → the per-client junk counter (429
//      rate_limited past its limit) or 401 invalid_key. It costs no token,
//      no cache entry and no RPC. Only tag-valid keys go further, and each
//      names its key id and owner.
//   6. Per-key-hash memory guards (no database contact): a hash the RPC
//      called revoked or expired → the same 401 for the rest of its life; an
//      unknown one → 401 for 60 s; a hash the RPC said is over its limit →
//      429 rate_limited until its reset. Then admission (auth.js
//      createApiGuard): at most 4 RPCs in flight per hash, else 429; and a
//      hash outside the positive cache also takes one client, one owner and
//      one isolate token, else 429. All taken before the RPC is awaited.
//   7. api_key_authorize RPC → 401 key_revoked | key_expired | invalid_key,
//      429 rate_limited, 503 unavailable (also when the row's id or owner is
//      not the one the tag names). From here on the request has an owner
//      and every outcome is logged against the key.
//   8. Scope → 403 insufficient_scope.
//   9. Query parameters → 400 invalid_parameter | invalid_cursor.
//  10. GET-only reads scoped to the resolved owner → 200 | 404 | 500.
//
// Every response carries TradeReady-Api-Version and Cache-Control: no-store
// (openapi.json is the one cacheable document). Responses that resolved a
// key also carry X-RateLimit-Limit/Remaining/Reset for its minute window.

const { API_VERSION, RESOURCES, RESOURCE_NAMES, expandRow, invoiceLedger, toPublic, isoUtc } = require('./resources.js');
const { parseBearer, keyInQuery, hasScope, sha256Hex, tagSecretFrom, verifyApiKey, RESOURCE_SCOPE } = require('./keys.js');
const { encodeCursor, decodeCursor } = require('./cursor.js');
const store = require('./store.js');
const { authorizeKey, logApiRequest, clientKey } = require('./auth.js');

const DEFAULT_LIMIT = 50;
const MAX_LIMIT = 100;
const MAX_ID_CHARS = 200;
// Safety overlap for transactions that commit out of clock order (§5).
const UPDATED_SINCE_OVERLAP_MS = 5000;
const LIST_PARAMS = ['limit', 'cursor', 'updated_since'];
const ISO_TS_RE = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(:\d{2}(\.\d{1,9})?)?(Z|[+-]\d{2}:\d{2})$/;

const ERRORS = Object.freeze({
  invalid_key: [401, 'The API key is missing, malformed or not recognized. Send it as "Authorization: Bearer trk_…".'],
  key_revoked: [401, 'This API key was revoked. Create a new key in the TradeReady app.'],
  key_expired: [401, 'This API key has expired. Create a new key in the TradeReady app.'],
  key_in_query: [400, 'Send the API key in the Authorization header, never in the URL. Treat a key that was sent in a URL as exposed: revoke it and create a new one.'],
  insufficient_scope: [403, 'This API key does not have the scope this resource needs.'],
  not_found: [404, 'Not found.'],
  invalid_parameter: [400, 'Invalid query parameter.'],
  invalid_cursor: [400, 'The cursor is not valid for this resource. Start again without a cursor.'],
  method_not_allowed: [405, 'The TradeReady API is read-only. Use GET.'],
  rate_limited: [429, 'Rate limit reached. Retry after the number of seconds in the Retry-After header.'],
  unavailable: [503, 'The API is temporarily unavailable. Try again later.'],
  not_configured: [503, 'The API is not configured to accept keys right now. Try again later.'],
  server_error: [500, 'Something went wrong on our side. Try again later.'],
});
const ERROR_CODES = Object.freeze(Object.keys(ERRORS));

const WWW_AUTHENTICATE = { 'WWW-Authenticate': 'Bearer realm="TradeReady API"' };

// The route table the router and the OpenAPI document share.
const ROUTES = Object.freeze([
  { kind: 'openapi', template: '/v1/openapi.json' },
  { kind: 'account', resource: 'account', template: '/v1/account' },
  ...RESOURCE_NAMES.flatMap((r) => [
    { kind: 'list', resource: r, template: `/v1/${r}` },
    { kind: 'single', resource: r, template: `/v1/${r}/:id` },
  ]),
]);

function matchRoute(pathname) {
  if (pathname !== '/v1' && !pathname.startsWith('/v1/')) return null;
  let rest = pathname.slice(4);
  if (rest.endsWith('/')) rest = rest.slice(0, -1);
  if (rest === '') return null;
  const parts = rest.split('/');
  if (parts.length === 1) {
    const [name] = parts;
    if (name === 'openapi.json') return { kind: 'openapi', template: '/v1/openapi.json' };
    if (name === 'account') return { kind: 'account', resource: 'account', template: '/v1/account' };
    if (RESOURCE_NAMES.includes(name)) return { kind: 'list', resource: name, template: `/v1/${name}` };
    return null;
  }
  if (parts.length === 2 && RESOURCE_NAMES.includes(parts[0])) {
    let id;
    try {
      id = decodeURIComponent(parts[1]);
    } catch {
      return null;
    }
    if (id.length === 0 || id.length > MAX_ID_CHARS) return null;
    return { kind: 'single', resource: parts[0], id, template: `/v1/${parts[0]}/:id` };
  }
  return null;
}

// A parameter name is attacker-chosen: echo at most 40 printable characters.
function safeName(name) {
  return String(name).replace(/[^\x20-\x7e]/g, '?').slice(0, 40);
}

// Returns { limit, cursor, updatedSince } or { error, message }.
function parseParams(searchParams, allowed) {
  const seen = new Set();
  for (const [name] of searchParams) {
    if (!allowed.includes(name)) {
      return { error: 'invalid_parameter', message: `Unknown query parameter "${safeName(name)}".` };
    }
    if (seen.has(name)) {
      return { error: 'invalid_parameter', message: `Query parameter "${safeName(name)}" was sent more than once.` };
    }
    seen.add(name);
  }
  const out = { limit: DEFAULT_LIMIT, cursor: null, updatedSince: null };
  if (searchParams.has('limit')) {
    const raw = searchParams.get('limit');
    const n = /^[0-9]{1,3}$/.test(raw) ? Number(raw) : NaN;
    if (!(n >= 1 && n <= MAX_LIMIT)) {
      return { error: 'invalid_parameter', message: `"limit" must be a whole number from 1 to ${MAX_LIMIT}.` };
    }
    out.limit = n;
  }
  if (searchParams.has('updated_since')) {
    const raw = searchParams.get('updated_since');
    const ms = ISO_TS_RE.test(raw) ? Date.parse(raw) : NaN;
    if (!Number.isFinite(ms)) {
      return {
        error: 'invalid_parameter',
        message: '"updated_since" must be an ISO-8601 timestamp with a time zone, for example 2026-10-03T00:00:00Z.',
      };
    }
    out.updatedSince = new Date(ms).toISOString();
  }
  if (searchParams.has('cursor')) out.cursor = searchParams.get('cursor');
  return out;
}

function overlapWatermark(updatedAt) {
  const ms = Date.parse(updatedAt);
  return Number.isFinite(ms) ? new Date(ms - UPDATED_SINCE_OVERLAP_MS).toISOString() : null;
}

function rateHeaders(rate) {
  if (!rate) return {};
  return {
    'X-RateLimit-Limit': String(rate.limit),
    'X-RateLimit-Remaining': String(rate.remaining),
    'X-RateLimit-Reset': String(rate.reset),
  };
}

function newest(values) {
  let best = null;
  let bestMs = -Infinity;
  for (const v of values) {
    const ms = typeof v === 'string' ? Date.parse(v) : NaN;
    if (Number.isFinite(ms) && ms > bestMs) {
      best = v;
      bestMs = ms;
    }
  }
  return best;
}

// Tables whose freshness the account's dataAsOf reflects: only those the
// key may read.
const SCOPE_TABLE = Object.freeze({
  'customers:read': 'customers',
  'jobs:read': 'jobs',
  'invoices:read': 'invoices',
  'expenses:read': 'expenses',
  'mileage:read': 'trips',
});

async function readAccount(env, auth) {
  const tables = [...new Set(auth.scopes.map((s) => SCOPE_TABLE[s]).filter(Boolean))];
  const [businessName, ...stamps] = await Promise.all([
    store.fetchBusinessName(env, { userId: auth.userId }),
    ...tables.map((table) => store.newestUpdatedAt(env, { table, userId: auth.userId })),
  ]);
  return { data: toPublic.account({ businessName, dataAsOf: newest(stamps), key: auth }) };
}

async function readList(env, auth, route, params, { nowMs, cursorSecret }) {
  const def = RESOURCES[route.resource];
  const [rows, stamp] = await Promise.all([
    store.listRows(env, {
      table: def.table,
      userId: auth.userId,
      filter: def.filter,
      after: params.after,
      updatedSince: params.updatedSince,
      limit: params.limit,
    }),
    store.newestUpdatedAt(env, { table: def.table, userId: auth.userId }),
  ]);
  const hasMore = rows.length > params.limit;
  const page = hasMore ? rows.slice(0, params.limit) : rows;
  // The cursor and watermark follow the last RAW row scanned, not the last
  // object returned: a payments page can hold zero payments, and an
  // estimates page skips jobs that are not estimates.
  const last = page[page.length - 1];
  return {
    data: page.flatMap((row) => expandRow(route.resource, row, { nowMs })),
    nextCursor: hasMore
      ? encodeCursor(cursorSecret, { updatedAt: last.updated_at, id: String(last.id), resource: route.resource })
      : null,
    dataAsOf: isoUtc(stamp),
    nextUpdatedSince: last ? overlapWatermark(last.updated_at) : null,
  };
}

async function readSingle(env, auth, route, { nowMs }) {
  const def = RESOURCES[route.resource];
  const stampPromise = store.newestUpdatedAt(env, { table: def.table, userId: auth.userId });
  let found = null;
  if (route.resource === 'payments') {
    // A synthesized legacy entry (`legacy_<invoiceId>`) is not stored in the
    // ledger, so it is found through its invoice.
    const row = route.id.startsWith('legacy_')
      ? await store.getRow(env, { table: 'invoices', userId: auth.userId, id: route.id.slice(7) })
      : await store.getInvoiceByPaymentId(env, { userId: auth.userId, paymentId: route.id });
    const payment = row ? invoiceLedger(row).find((p) => String(p.id) === route.id) : null;
    found = payment ? toPublic.payments(payment, row) : null;
  } else {
    const row = await store.getRow(env, { table: def.table, userId: auth.userId, id: route.id });
    found = row ? expandRow(route.resource, row, { nowMs })[0] || null : null;
  }
  const stamp = await stampPromise;
  return found ? { data: found, dataAsOf: isoUtc(stamp) } : null;
}

// req: { method, url, authorization, ip } where ip is cf-connecting-ip only
// (never x-forwarded-for, which the caller controls).
// deps: { nowMs, guard } where guard is createApiGuard() (auth.js).
async function handleV1(req, env, { nowMs = Date.now(), guard }) {
  const base = { 'TradeReady-Api-Version': API_VERSION, 'Cache-Control': 'no-store' };
  const respond = (status, body, extra = {}) => ({ status, body, headers: { ...base, ...extra } });
  const fail = (code, extra = {}, message) =>
    respond(ERRORS[code][0], { error: { code, message: message || ERRORS[code][1] } }, extra);

  if (req.method !== 'GET') return fail('method_not_allowed', { Allow: 'GET' });

  let url;
  try {
    url = new URL(req.url);
  } catch {
    return fail('not_found');
  }
  const client = clientKey(req.ip);
  if (keyInQuery(url.searchParams)) {
    guard.junkRequest(client, nowMs); // counted; always 400, never 429
    return fail('key_in_query');
  }
  const route = matchRoute(url.pathname);
  if (!route) return fail('not_found');

  if (route.kind === 'openapi') {
    const parsed = parseParams(url.searchParams, []);
    if (parsed.error) return fail(parsed.error, {}, parsed.message);
    // Required here, not at the top: openapi.js reads ROUTES and ERRORS from
    // this module, so a top-level require would be circular. The document
    // itself is built once, when openapi.js first loads.
    const { OPENAPI_DOCUMENT } = require('./openapi.js');
    return respond(200, OPENAPI_DOCUMENT, { 'Cache-Control': 'public, max-age=3600' });
  }

  // Fail closed before reading any key: without the tag secret no key can be
  // verified, and there is no untagged fallback.
  const tagSecret = tagSecretFrom(env);
  if (!tagSecret) {
    console.error('[api/v1] API_KEY_TAG_SECRET is not configured');
    return fail('not_configured');
  }

  const bearer = parseBearer(req.authorization);
  // The tag is checked before anything is spent: a forged or random key
  // never takes a token, never enters a cache and never reaches the RPC.
  const tagged = bearer.error ? null : await verifyApiKey(tagSecret, bearer.key);
  if (!tagged) {
    // Junk traffic only: a request with a tag-valid key never reaches this
    // counter, so junk from a shared address cannot lock out valid keys.
    const wait = guard.junkRequest(client, nowMs);
    if (wait > 0) return fail('rate_limited', { 'Retry-After': String(wait) });
    return fail('invalid_key', WWW_AUTHENTICATE);
  }

  // Only the hash is ever remembered, never the key.
  const keyHash = sha256Hex(bearer.key);
  const shed = guard.keyShed(keyHash, nowMs);
  if (shed && shed.error === 'rate_limited') {
    return fail('rate_limited', { 'Retry-After': String(shed.retryAfter), ...rateHeaders(shed.rate) });
  }
  if (shed) return fail(shed.error, WWW_AUTHENTICATE);

  // Admission, decided synchronously BEFORE the RPC is awaited, so a burst of
  // concurrent requests is bounded by what is admitted, not by what has come
  // back. Every hash gets at most a few RPCs in flight. A positively cached
  // hash still goes to the RPC (revocation, expiry and rate limits are
  // checked every time) without spending tokens; any other hash also spends
  // a client token, an owner token and an isolate token.
  const slot = guard.takeInFlight(keyHash);
  if (!slot) return fail('rate_limited', { 'Retry-After': '1' });
  let ticket = null;
  if (!guard.isKnownKey(keyHash, nowMs)) {
    const taken = guard.takeTokens(client, nowMs, tagged.ownerId);
    if (!taken.ticket) {
      guard.releaseInFlight(slot);
      return fail('rate_limited', { 'Retry-After': String(taken.retryAfter) });
    }
    ticket = taken.ticket;
  }

  let auth;
  try {
    auth = await authorizeKey(env, { keyHash, route: route.template, ip: req.ip || null });
  } catch (err) {
    console.error('[api/v1] authorize failed:', err.message);
    auth = { kind: 'unavailable' };
  } finally {
    guard.releaseInFlight(slot);
  }
  // The row must be the one the tag names. A mismatch means the database and
  // the tag secret disagree: fail closed, keep the tokens.
  if (auth.kind === 'ok' && (auth.keyId.toLowerCase() !== tagged.keyId || auth.userId.toLowerCase() !== tagged.ownerId)) {
    console.error('[api/v1] authorized key does not match its tag');
    auth = { kind: 'unavailable' };
  }
  // Only a live key's answer gives the tokens back; denials, outages and
  // transport failures keep them, so an outage cannot make the bound infinite.
  if (auth.kind === 'ok' || auth.kind === 'rate_limited') guard.refundTokens(ticket);
  if (auth.kind === 'unavailable') return fail('unavailable');
  if (auth.kind === 'denied') {
    guard.deniedKey(keyHash, auth.error, nowMs);
    return fail(auth.error, WWW_AUTHENTICATE);
  }
  if (auth.kind === 'rate_limited') {
    guard.knownKey(keyHash, nowMs); // only a live key is ever rate limited
    guard.rateLimitedKey(keyHash, { retryAfter: auth.retryAfter, rate: auth.rate }, nowMs);
    return fail('rate_limited', { 'Retry-After': String(auth.retryAfter), ...rateHeaders(auth.rate) });
  }

  guard.knownKey(keyHash, nowMs);
  const out = await serveAuthorized(env, auth, route, url.searchParams, { nowMs, fail, respond });
  out.headers = { ...out.headers, ...rateHeaders(auth.rate) };
  await logApiRequest(env, {
    userId: auth.userId,
    keyId: auth.keyId,
    route: route.template,
    status: out.status,
    ip: req.ip || null,
  });
  return out;
}

async function serveAuthorized(env, auth, route, searchParams, { nowMs, fail, respond }) {
  if (!hasScope(auth.scopes, route.resource)) return fail('insufficient_scope');

  const parsed = parseParams(searchParams, route.kind === 'list' ? LIST_PARAMS : []);
  if (parsed.error) return fail(parsed.error, {}, parsed.message);

  try {
    if (route.kind === 'account') return respond(200, await readAccount(env, auth));

    if (route.kind === 'list') {
      const cursorSecret = env.API_CURSOR_SECRET;
      if (!cursorSecret) {
        console.error('[api/v1] API_CURSOR_SECRET is not configured');
        return fail('unavailable');
      }
      let after = null;
      if (parsed.cursor !== null) {
        after = decodeCursor(cursorSecret, parsed.cursor, route.resource);
        if (!after) return fail('invalid_cursor');
      }
      return respond(200, await readList(env, auth, route, { ...parsed, after }, { nowMs, cursorSecret }));
    }

    const body = await readSingle(env, auth, route, { nowMs });
    return body ? respond(200, body) : fail('not_found');
  } catch (err) {
    console.error('[api/v1] read failed:', err.message);
    return fail('server_error');
  }
}

module.exports = {
  handleV1,
  matchRoute,
  parseParams,
  overlapWatermark,
  ROUTES,
  ERRORS,
  ERROR_CODES,
  LIST_PARAMS,
  DEFAULT_LIMIT,
  MAX_LIMIT,
  RESOURCE_SCOPE,
};
