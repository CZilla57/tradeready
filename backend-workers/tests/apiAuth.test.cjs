// Open API keys, cursor, request-contract helpers and the OpenAPI document
// (Roadmap Phase 23, spec §2, §5, §7, §8, §10). Pure units plus the
// authorize-RPC envelope mapping against a stubbed fetch. No network.

const { describe, test, afterEach } = require('node:test');
const assert = require('node:assert/strict');
const { createHash } = require('node:crypto');

const keys = require('../lib/api/keys.js');
const { encodeCursor, decodeCursor } = require('../lib/api/cursor.js');
const { authorizeKey, logApiRequest, eventForStatus, createAuthFailureGuard } = require('../lib/api/auth.js');
const v1 = require('../lib/api/v1.js');
const { OPENAPI_DOCUMENT, API_BASE_URL, COMPONENT, toOpenApiPath } = require('../lib/api/openapi.js');
const { FIELDS, RESOURCE_NAMES } = require('../lib/api/resources.js');

const SECRET = 'cursor-secret-for-tests';
const realFetch = global.fetch;
afterEach(() => { global.fetch = realFetch; });

function jsonRes(body, status = 200) {
  return { ok: status >= 200 && status < 300, status, json: async () => body, text: async () => JSON.stringify(body) };
}

describe('key format (§2)', () => {
  test('trk_ + 43 base64url chars over 32 bytes; 12-char display prefix', () => {
    const bytes = Buffer.alloc(32, 0xab);
    const key = keys.generateApiKey(bytes);
    assert.match(key, /^trk_[A-Za-z0-9_-]{43}$/);
    assert.equal(key.length, 47);
    assert.equal(key.slice(4), bytes.toString('base64url'));
    assert.equal(keys.displayPrefix(key), key.slice(0, 12));
    assert.equal(keys.displayPrefix(key).length, 12);
    assert.ok(keys.isWellFormedKey(key));
    assert.throws(() => keys.generateApiKey(Buffer.alloc(16)), /32 random bytes/);
    assert.throws(() => keys.generateApiKey('not bytes'));
  });

  test('two keys from different bytes never share a hash; the hash is sha256 hex', () => {
    const a = keys.generateApiKey(Buffer.alloc(32, 1));
    const b = keys.generateApiKey(Buffer.alloc(32, 2));
    assert.notEqual(keys.sha256Hex(a), keys.sha256Hex(b));
    assert.equal(keys.sha256Hex(a), createHash('sha256').update(a).digest('hex'));
    assert.match(keys.sha256Hex(a), /^[0-9a-f]{64}$/);
  });

  test('Bearer parsing: only "Bearer trk_<43>" passes, and every failure is the same invalid_key', () => {
    const key = keys.generateApiKey(Buffer.alloc(32, 7));
    assert.deepEqual(keys.parseBearer(`Bearer ${key}`), { key });
    for (const bad of [undefined, '', key, `Basic ${key}`, `Bearer`, `Bearer ${key.slice(0, -1)}`, `Bearer ${key}x`,
      `Bearer sk_${key.slice(3)}`, `Bearer ${key} extra`, `bearer ${key}`, `Bearer trk_${'!'.repeat(43)}`]) {
      assert.deepEqual(keys.parseBearer(bad), { error: 'invalid_key' }, String(bad));
    }
  });

  test('a key in the query string is detected by name or by value', () => {
    const q = (s) => new URLSearchParams(s);
    assert.equal(keys.keyInQuery(q('limit=5')), false);
    assert.equal(keys.keyInQuery(q('api_key=abc')), true);
    assert.equal(keys.keyInQuery(q('access_token=abc')), true);
    assert.equal(keys.keyInQuery(q('KEY=abc')), true);
    assert.equal(keys.keyInQuery(q('cursor=trk_abc')), true);
    assert.equal(keys.keyInQuery(q('anything=%20trk_abc')), true);
  });

  test('scopes: known only, de-duplicated, canonical order; presets', () => {
    assert.deepEqual(keys.normalizeScopes(['invoices:read', 'customers:read', 'invoices:read']), ['customers:read', 'invoices:read']);
    assert.equal(keys.normalizeScopes([]), null);
    assert.equal(keys.normalizeScopes(['payroll:read']), null);
    assert.equal(keys.normalizeScopes('customers:read'), null);
    assert.deepEqual([...keys.PRESETS.everything], keys.SCOPES);
    assert.deepEqual([...keys.PRESETS.bookkeeping], ['customers:read', 'invoices:read', 'expenses:read', 'mileage:read']);
  });

  test('scope per resource; account needs any scope', () => {
    assert.ok(keys.hasScope(['jobs:read'], 'estimates'));
    assert.ok(keys.hasScope(['invoices:read'], 'payments'));
    assert.ok(!keys.hasScope(['jobs:read'], 'invoices'));
    assert.ok(!keys.hasScope(['customers:read'], 'mileage'));
    assert.ok(keys.hasScope(['mileage:read'], 'account'));
    assert.ok(!keys.hasScope([], 'account'));
    assert.ok(!keys.hasScope(['jobs:read'], 'nope'));
    for (const r of RESOURCE_NAMES) assert.ok(keys.RESOURCE_SCOPE[r], `scope for ${r}`);
  });

  test('names: trimmed, 1–40 chars, no control characters', () => {
    assert.equal(keys.normalizeName('  Books  '), 'Books');
    assert.equal(keys.normalizeName('x'.repeat(40)), 'x'.repeat(40));
    assert.equal(keys.normalizeName('x'.repeat(41)), null);
    assert.equal(keys.normalizeName('   '), null);
    assert.equal(keys.normalizeName('a\nb'), null);
    assert.equal(keys.normalizeName('a b'), null);
    assert.equal(keys.normalizeName(5), null);
  });
});

describe('cursor (§5)', () => {
  const at = { updatedAt: '2026-10-03T12:00:00.123456+00:00', id: 'inv,1(x)."y"', resource: 'invoices' };

  test('round-trips exactly, including microseconds and reserved characters in the id', () => {
    const c = encodeCursor(SECRET, at);
    assert.match(c, /^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$/);
    assert.deepEqual(decodeCursor(SECRET, c, 'invoices'), { updatedAt: at.updatedAt, id: at.id });
  });

  test('tampering, a cross-resource cursor, the wrong secret and junk are all refused', () => {
    const c = encodeCursor(SECRET, at);
    const [payload, sig] = c.split('.');
    const forged = Buffer.from(JSON.stringify({ u: at.updatedAt, i: 'other', r: 'invoices' })).toString('base64url');
    assert.equal(decodeCursor(SECRET, `${forged}.${sig}`, 'invoices'), null, 'payload swap');
    assert.equal(decodeCursor(SECRET, `${payload}.${sig.slice(0, -2)}AA`, 'invoices'), null, 'tag edit');
    assert.equal(decodeCursor(SECRET, c, 'payments'), null, 'cross-resource');
    assert.equal(decodeCursor('another-secret', c, 'invoices'), null, 'wrong secret');
    assert.equal(decodeCursor(SECRET, payload, 'invoices'), null, 'no tag');
    assert.equal(decodeCursor(SECRET, `${c}.x`, 'invoices'), null, 'extra part');
    assert.equal(decodeCursor(SECRET, 'x'.repeat(2000), 'invoices'), null, 'oversized');
    assert.equal(decodeCursor('', c, 'invoices'), null, 'no secret configured');
    const badTs = encodeCursor(SECRET, { ...at, updatedAt: 'not a time' });
    assert.equal(decodeCursor(SECRET, badTs, 'invoices'), null, 'signed but malformed');
  });

  test('encoding without a secret fails loudly', () => {
    assert.throws(() => encodeCursor('', at), /API_CURSOR_SECRET/);
  });
});

describe('request contract helpers (§5)', () => {
  test('routes', () => {
    assert.deepEqual(v1.matchRoute('/v1/invoices'), { kind: 'list', resource: 'invoices', template: '/v1/invoices' });
    assert.deepEqual(v1.matchRoute('/v1/invoices/'), { kind: 'list', resource: 'invoices', template: '/v1/invoices' });
    assert.deepEqual(v1.matchRoute('/v1/invoices/inv%2F1'), { kind: 'single', resource: 'invoices', id: 'inv/1', template: '/v1/invoices/:id' });
    assert.deepEqual(v1.matchRoute('/v1/account'), { kind: 'account', resource: 'account', template: '/v1/account' });
    assert.equal(v1.matchRoute('/v1/openapi.json').kind, 'openapi');
    for (const p of ['/v1', '/v1/', '/v1/payroll', '/v1/invoices/a/b', '/v1/account/x', '/v1x/invoices', '/v2/invoices',
      '/v1/invoices/%E0%A4%A', `/v1/invoices/${'x'.repeat(201)}`]) {
      assert.equal(v1.matchRoute(p), null, p);
    }
  });

  test('query parameters: unknown, duplicate and malformed values are refused, naming the parameter', () => {
    const p = (s, allowed = v1.LIST_PARAMS) => v1.parseParams(new URLSearchParams(s), allowed);
    assert.deepEqual(p(''), { limit: 50, cursor: null, updatedSince: null });
    assert.deepEqual(p('limit=100&updated_since=2026-10-01T00:00:00-07:00&cursor=abc'),
      { limit: 100, cursor: 'abc', updatedSince: '2026-10-01T07:00:00.000Z' });
    assert.match(p('limt=5').message, /"limt"/);
    assert.equal(p('limt=5').error, 'invalid_parameter');
    assert.match(p('limit=5&limit=6').message, /more than once/);
    for (const bad of ['limit=0', 'limit=101', 'limit=5.5', 'limit=', 'limit=abc', 'limit=-1', 'limit=0050']) {
      assert.equal(p(bad).error, 'invalid_parameter', bad);
    }
    for (const bad of ['updated_since=2026-10-01', 'updated_since=yesterday', 'updated_since=2026-10-01T00:00:00',
      'updated_since=2026-13-01T00:00:00Z']) {
      assert.equal(p(bad).error, 'invalid_parameter', bad);
    }
    assert.equal(p('limit=5', []).error, 'invalid_parameter', 'single-record routes take no parameters');
    assert.ok(p(`x${'\u0001'.repeat(3)}${'y'.repeat(100)}=1`).message.length < 80, 'echo is bounded and printable');
  });

  test('nextUpdatedSince is the last row minus 5 seconds', () => {
    assert.equal(v1.overlapWatermark('2026-10-03T12:00:00.123456+00:00'), '2026-10-03T11:59:55.123Z');
    assert.equal(v1.overlapWatermark('garbage'), null);
  });

  test('stable error vocabulary', () => {
    assert.deepEqual([...v1.ERROR_CODES].sort(), ['invalid_cursor', 'invalid_key', 'invalid_parameter', 'insufficient_scope',
      'key_expired', 'key_in_query', 'key_revoked', 'method_not_allowed', 'not_found', 'rate_limited', 'server_error',
      'unavailable'].sort());
    assert.equal(v1.ERRORS.insufficient_scope[0], 403);
    assert.equal(v1.ERRORS.rate_limited[0], 429);
    assert.equal(v1.ERRORS.unavailable[0], 503);
    assert.equal(v1.ERRORS.server_error[0], 500);
  });
});

describe('authorizeKey: the RPC envelope contract (§4)', () => {
  const ENV = { SUPABASE_URL: 'https://supa.test', SUPABASE_SERVICE_ROLE_KEY: 'srk' };
  const ARGS = { keyHash: 'a'.repeat(64), route: '/v1/jobs', ip: '203.0.113.9' };
  const OWNER = '11111111-1111-4111-8111-111111111111';
  const KEY_ID = '22222222-2222-4222-8222-222222222222';
  const script = (status, body) => {
    const calls = [];
    global.fetch = async (url, init) => {
      calls.push({ url: String(url), init });
      return jsonRes(body, status);
    };
    return calls;
  };

  test('sends only the hash, the route template and the edge IP to the RPC', async () => {
    const calls = script(200, { ok: true, userId: OWNER, keyId: KEY_ID, scopes: ['jobs:read'], limit: 60, remaining: 59, reset: 1 });
    const out = await authorizeKey(ENV, ARGS);
    assert.equal(out.kind, 'ok');
    assert.equal(calls[0].url, 'https://supa.test/rest/v1/rpc/api_key_authorize');
    assert.equal(calls[0].init.method, 'POST');
    assert.deepEqual(JSON.parse(calls[0].init.body), { p_key_hash: 'a'.repeat(64), p_route: '/v1/jobs', p_ip: '203.0.113.9' });
    assert.deepEqual(out.rate, { limit: 60, remaining: 59, reset: 1 });
  });

  test('denials, rate limits and fail-closed cases', async () => {
    script(200, { ok: false, error: 'key_revoked' });
    assert.deepEqual(await authorizeKey(ENV, ARGS), { kind: 'denied', error: 'key_revoked' });
    script(200, { ok: false, error: 'key_expired' });
    assert.deepEqual(await authorizeKey(ENV, ARGS), { kind: 'denied', error: 'key_expired' });
    script(200, { ok: false, error: 'invalid_key' });
    assert.deepEqual(await authorizeKey(ENV, ARGS), { kind: 'denied', error: 'invalid_key' });
    script(200, { ok: false, error: 'rate_limited', retryAfter: 12.2, limit: 60, remaining: 0, reset: 99 });
    assert.deepEqual(await authorizeKey(ENV, ARGS), { kind: 'rate_limited', retryAfter: 13, rate: { limit: 60, remaining: 0, reset: 99 } });
    script(404, { message: 'function not found' });
    assert.deepEqual(await authorizeKey(ENV, ARGS), { kind: 'unavailable' }, 'not deployed');
    script(200, { surprise: true });
    assert.deepEqual(await authorizeKey(ENV, ARGS), { kind: 'unavailable' }, 'non-envelope');
    script(200, { ok: false, error: 'forbidden' });
    assert.deepEqual(await authorizeKey(ENV, ARGS), { kind: 'unavailable' }, 'unknown error');
    script(200, { ok: true, userId: 'not-a-uuid', keyId: KEY_ID, scopes: [] });
    assert.deepEqual(await authorizeKey(ENV, ARGS), { kind: 'unavailable' }, 'bad owner id never reaches a query');
    script(500, { message: 'boom' });
    await assert.rejects(authorizeKey(ENV, ARGS), /500/);
  });

  test('the access log row: key id, route template, status, event — never a key', async () => {
    const calls = script(201, {});
    await logApiRequest(ENV, { userId: OWNER, keyId: KEY_ID, route: '/v1/invoices/:id', status: 404, ip: null });
    assert.equal(calls[0].url, 'https://supa.test/rest/v1/api_access_log');
    assert.deepEqual(JSON.parse(calls[0].init.body), {
      user_id: OWNER, key_id: KEY_ID, event: 'error', route: '/v1/invoices/:id', status: 404, ip: null,
    });
    global.fetch = async () => { throw new Error('log table down'); };
    const errors = [];
    const orig = console.error;
    console.error = (...a) => errors.push(a.join(' '));
    try {
      await logApiRequest(ENV, { userId: OWNER, keyId: KEY_ID, route: '/v1/jobs', status: 200, ip: null });
    } finally {
      console.error = orig;
    }
    assert.equal(errors.length, 1, 'best-effort: logged, never thrown');
  });

  test('event per status', () => {
    assert.equal(eventForStatus(200), 'ok');
    assert.equal(eventForStatus(403), 'denied');
    assert.equal(eventForStatus(429), 'rate_limited');
    assert.equal(eventForStatus(400), 'error');
    assert.equal(eventForStatus(404), 'error');
    assert.equal(eventForStatus(500), 'error');
  });
});

describe('failed-auth load guard (§6)', () => {
  test('the 20th failure in a minute blocks that address for a minute; others are unaffected', () => {
    const g = createAuthFailureGuard({ limit: 20, windowMs: 60_000 });
    const t0 = 1_000_000;
    for (let i = 0; i < 19; i++) g.fail('198.51.100.1', t0 + i);
    assert.equal(g.blockedFor('198.51.100.1', t0 + 100), 0, '19 failures: not blocked');
    g.fail('198.51.100.1', t0 + 200);
    assert.equal(g.blockedFor('198.51.100.1', t0 + 300), 60, '20th failure blocks');
    assert.equal(g.blockedFor('198.51.100.2', t0 + 300), 0, 'per address');
    assert.equal(g.blockedFor('198.51.100.1', t0 + 200 + 60_000), 0, 'block lifts after the window');
  });
});

describe('per-key-hash memory guards (§6)', () => {
  const H1 = 'a'.repeat(64);
  const H2 = 'b'.repeat(64);

  test('unknown hash: shed from the 5th unknown answer until the window ends; per hash', () => {
    const g = createAuthFailureGuard({ unknownLimit: 5, windowMs: 60_000 });
    const t0 = 5_000_000;
    assert.equal(g.keyShed(H1, t0), null);
    for (let i = 0; i < 4; i++) g.unknownKey(H1, t0 + i);
    assert.equal(g.keyShed(H1, t0 + 10), null, 'four unknown answers: still goes to the RPC');
    g.unknownKey(H1, t0 + 20);
    assert.deepEqual(g.keyShed(H1, t0 + 30), { error: 'invalid_key' });
    assert.equal(g.keyShed(H2, t0 + 30), null, 'another hash is unaffected');
    assert.equal(g.keyShed(H1, t0 + 60_000), null, 'the window ends and the hash is looked up again');
  });

  test('rate-limited hash: shed until the reported reset, with the stored rate headers', () => {
    const g = createAuthFailureGuard();
    const t0 = 9_000_000;
    const rate = { limit: 60, remaining: 0, reset: 123 };
    g.rateLimitedKey(H1, { retryAfter: 17, rate }, t0);
    assert.deepEqual(g.keyShed(H1, t0 + 5_000), { error: 'rate_limited', retryAfter: 12, rate });
    assert.equal(g.keyShed(H2, t0 + 5_000), null);
    assert.equal(g.keyShed(H1, t0 + 17_000), null, 'reset reached');
    g.rateLimitedKey(H2, { rate: null }, t0);
    assert.equal(g.keyShed(H2, t0 + 59_000).error, 'rate_limited', 'no reset reported: a short fixed window');
    assert.equal(g.keyShed(H2, t0 + 60_000), null);
  });

  test('only sha256 hex is accepted as a guard key, so a presented key is never remembered', () => {
    const g = createAuthFailureGuard();
    const raw = `trk_${'Z'.repeat(43)}`;
    g.unknownKey(raw, 1);
    g.rateLimitedKey(raw, { retryAfter: 30 }, 1);
    g.knownKey(raw, 1);
    assert.deepEqual(g.sizes(), { ips: 0, blocked: 0, unknownKeys: 0, limitedKeys: 0, knownKeys: 0, budgets: 0 });
  });

  test('over the threshold, hashes outside the positive cache share a small per-IP budget; known hashes do not', () => {
    const g = createAuthFailureGuard({ limit: 3, windowMs: 1000, ipBudget: 2 });
    for (let i = 0; i < 3; i++) g.fail('ip', 0);
    assert.ok(g.blockedFor('ip', 10) > 0);
    assert.equal(g.takeIpBudget('ip', 10), true);
    assert.equal(g.takeIpBudget('ip', 20), true);
    assert.equal(g.takeIpBudget('ip', 30), false);
    assert.equal(g.takeIpBudget('other', 30), true, 'per address');
    g.fail('ip', 40); // a budgeted RPC that failed must not extend the block
    assert.equal(g.blockedFor('ip', 1000), 0, 'block ends one window after it began');
    g.knownKey(H1, 0);
    assert.equal(g.isKnownKey(H1, 299_999), true);
    assert.equal(g.isKnownKey(H1, 300_000), false, 'five-minute TTL');
    g.knownKey(H2, 0);
    g.forgetKey(H2);
    assert.equal(g.isKnownKey(H2, 1), false);
  });

  test('the IP failure window restarts after it elapses (failures do not accumulate across windows)', () => {
    const g = createAuthFailureGuard({ limit: 3, windowMs: 1000 });
    g.fail('ip', 0); g.fail('ip', 100);
    g.fail('ip', 2000); g.fail('ip', 2100);
    assert.equal(g.blockedFor('ip', 2200), 0);
    g.fail('ip', 2200);
    assert.ok(g.blockedFor('ip', 2300) > 0);
  });
});

describe('OpenAPI document (§8)', () => {
  test('is OpenAPI 3.1 on the workers.dev base URL (decision Q4)', () => {
    assert.equal(OPENAPI_DOCUMENT.openapi, '3.1.0');
    assert.equal(API_BASE_URL, 'https://tradeready-backend.tradeready.workers.dev');
    assert.deepEqual(OPENAPI_DOCUMENT.servers, [{ url: API_BASE_URL }]);
    assert.equal(OPENAPI_DOCUMENT.info.version, '2026-10-03');
    // Round-trips as plain JSON.
    assert.deepEqual(JSON.parse(JSON.stringify(OPENAPI_DOCUMENT)), OPENAPI_DOCUMENT);
  });

  test('documents every route the router serves, GET only', () => {
    const documented = Object.keys(OPENAPI_DOCUMENT.paths).sort();
    assert.deepEqual(documented, v1.ROUTES.map((r) => toOpenApiPath(r.template)).sort());
    assert.equal(documented.length, 2 + 2 * RESOURCE_NAMES.length);
    for (const [path, item] of Object.entries(OPENAPI_DOCUMENT.paths)) {
      assert.deepEqual(Object.keys(item), ['get'], path);
    }
    assert.deepEqual(OPENAPI_DOCUMENT.paths['/v1/openapi.json'].get.security, [], 'the document itself is public');
  });

  test('documents every public field, exactly, for every resource', () => {
    for (const [name, component] of Object.entries(COMPONENT)) {
      const schema = OPENAPI_DOCUMENT.components.schemas[component];
      assert.deepEqual(Object.keys(schema.properties), [...FIELDS[name]], component);
      assert.deepEqual(schema.required, [...FIELDS[name]], component);
      assert.equal(schema.additionalProperties, false, component);
    }
    const codes = OPENAPI_DOCUMENT.components.schemas.Error.properties.error.properties.code.enum;
    assert.deepEqual([...codes].sort(), [...v1.ERROR_CODES].sort());
  });

  test('every $ref resolves', () => {
    const refs = [];
    (function walk(v) {
      if (Array.isArray(v)) v.forEach(walk);
      else if (v && typeof v === 'object') {
        if (typeof v.$ref === 'string') refs.push(v.$ref);
        Object.values(v).forEach(walk);
      }
    })(OPENAPI_DOCUMENT);
    assert.ok(refs.length > 10);
    for (const r of refs) {
      const [, section, name] = r.match(/^#\/components\/(schemas|headers)\/(.+)$/) || [];
      assert.ok(section && OPENAPI_DOCUMENT.components[section][name], `unresolved ${r}`);
    }
  });
});
