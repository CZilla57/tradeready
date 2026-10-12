// Open API keys, cursor, request-contract helpers and the OpenAPI document
// (Roadmap Phase 23, spec §2, §5, §7, §8, §10). Pure units plus the
// authorize-RPC envelope mapping against a stubbed fetch. No network.

const { describe, test, afterEach } = require('node:test');
const assert = require('node:assert/strict');
const { createHash, createHmac } = require('node:crypto');

const keys = require('../lib/api/keys.js');
const { encodeCursor, decodeCursor } = require('../lib/api/cursor.js');
const { authorizeKey, logApiRequest, eventForStatus, createApiGuard, clientKey, GUARD_LIMITS } = require('../lib/api/auth.js');
const v1 = require('../lib/api/v1.js');
const { OPENAPI_DOCUMENT, API_BASE_URL, COMPONENT, toOpenApiPath } = require('../lib/api/openapi.js');
const { FIELDS, RESOURCE_NAMES } = require('../lib/api/resources.js');

const SECRET = 'cursor-secret-for-tests';
const sha = (v) => createHash('sha256').update(v).digest('hex');
const realFetch = global.fetch;
afterEach(() => { global.fetch = realFetch; });

function jsonRes(body, status = 200) {
  return { ok: status >= 200 && status < 300, status, json: async () => body, text: async () => JSON.stringify(body) };
}

describe('key format (§2): self-verifying tagged keys', () => {
  const TAG_SECRET = 'tag-secret-for-tests-0123456789abcdef-0123456789';
  const KEY_ID = '22222222-2222-4222-8222-222222222222';
  const OWNER = '11111111-1111-4111-8111-111111111111';
  const BODY = Buffer.alloc(32, 0xab);
  // An independent oracle for the tag (node:crypto, not WebCrypto).
  const oracle = (secret, keyId, ownerId, body) => {
    const signed = Buffer.concat([Buffer.from(keyId.replace(/-/g, ''), 'hex'), Buffer.from(ownerId.replace(/-/g, ''), 'hex'), body]);
    const tag = createHmac('sha256', secret).update(Buffer.concat([Buffer.from('tradeready-api-key-v1\0'), signed])).digest().subarray(0, 16);
    return `trk_${Buffer.concat([signed, tag]).toString('base64url')}`;
  };
  const mint = (over = {}) => keys.mintApiKey(TAG_SECRET, { keyId: KEY_ID, ownerId: OWNER, randomBytes: BODY, ...over });

  test('trk_ + 107 base64url chars over key id | owner id | 32 random bytes | 128-bit HMAC tag', async () => {
    const key = await mint();
    assert.match(key, /^trk_[A-Za-z0-9_-]{107}$/);
    assert.equal(key.length, 111);
    assert.equal(key, oracle(TAG_SECRET, KEY_ID, OWNER, BODY), 'matches the node:crypto oracle byte for byte');
    const bytes = Buffer.from(key.slice(4), 'base64url');
    assert.equal(bytes.length, 80);
    assert.equal(bytes.subarray(0, 16).toString('hex'), KEY_ID.replace(/-/g, ''));
    assert.equal(bytes.subarray(16, 32).toString('hex'), OWNER.replace(/-/g, ''));
    assert.deepEqual(bytes.subarray(32, 64), BODY);
    assert.equal(keys.displayPrefix(key), key.slice(0, 12));
    assert.ok(keys.isWellFormedKey(key));
    assert.deepEqual(await keys.verifyApiKey(TAG_SECRET, key), { keyId: KEY_ID, ownerId: OWNER });
  });

  test('minting refuses a missing or short secret, bad ids and wrong-size bytes', async () => {
    await assert.rejects(keys.mintApiKey(undefined, { keyId: KEY_ID, ownerId: OWNER, randomBytes: BODY }), /API_KEY_TAG_SECRET/);
    await assert.rejects(keys.mintApiKey('x'.repeat(43), { keyId: KEY_ID, ownerId: OWNER, randomBytes: BODY }), /API_KEY_TAG_SECRET/);
    await assert.rejects(mint({ keyId: 'nope' }), /UUID/);
    await assert.rejects(mint({ ownerId: undefined }), /UUID/);
    await assert.rejects(mint({ randomBytes: Buffer.alloc(16) }), /32 random bytes/);
    await assert.rejects(mint({ randomBytes: 'not bytes' }), /32 random bytes/);
  });

  test('verification rejects every forgery, an untagged key and a non-canonical spelling', async () => {
    const key = await mint();
    const bytes = Buffer.from(key.slice(4), 'base64url');
    const spell = (b) => `trk_${b.toString('base64url')}`;
    const rejected = [];
    // Every single-bit flip anywhere in the 80 bytes (id, owner, body or tag).
    for (let i = 0; i < 80; i++) {
      for (let bit = 0; bit < 8; bit++) {
        const b = Buffer.from(bytes);
        b[i] ^= 1 << bit;
        rejected.push(await keys.verifyApiKey(TAG_SECRET, spell(b)));
      }
    }
    assert.equal(rejected.length, 640);
    assert.ok(rejected.every((r) => r === null), 'no single-bit forgery verifies');
    // Another owner's id or key id under the same body and tag.
    assert.equal(await keys.verifyApiKey(TAG_SECRET, spell(Buffer.concat([bytes.subarray(0, 16), Buffer.alloc(16, 9), bytes.subarray(32)]))), null);
    // Right shape, wrong secret.
    assert.equal(await keys.verifyApiKey(TAG_SECRET, oracle('another-secret-0123456789abcdef-0123456789abcdef', KEY_ID, OWNER, BODY)), null);
    assert.equal(await keys.verifyApiKey('another-secret-0123456789abcdef-0123456789abcdef', key), null);
    // The last character carries 2 spare bits: a second spelling of the same bytes is refused.
    const last = key[key.length - 1];
    const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_';
    const idx = alphabet.indexOf(last);
    const twin = key.slice(0, -1) + alphabet[idx ^ 1];
    assert.deepEqual(Buffer.from(twin.slice(4), 'base64url'), bytes, 'same bytes');
    assert.equal(await keys.verifyApiKey(TAG_SECRET, twin), null, 'non-canonical spelling');
    // The pre-tag format (trk_ + 43 over 32 bytes) and junk.
    for (const bad of [`trk_${BODY.toString('base64url')}`, `trk_${'A'.repeat(107)}`, '', null, key.slice(0, -1), `${key}A`]) {
      assert.equal(await keys.verifyApiKey(TAG_SECRET, bad), null, String(bad).slice(0, 20));
    }
    // No secret, no verification.
    assert.equal(await keys.verifyApiKey(undefined, key), null);
    assert.equal(await keys.verifyApiKey('short', key), null);
  });

  test('the tag secret is read from env and must be at least 44 characters (32 bytes in base64)', () => {
    assert.equal(keys.MIN_TAG_SECRET_CHARS, 44);
    assert.equal(Buffer.alloc(32).toString('base64').length, 44);
    assert.equal(keys.tagSecretFrom({}), null);
    assert.equal(keys.tagSecretFrom(undefined), null);
    assert.equal(keys.tagSecretFrom({ API_KEY_TAG_SECRET: 'x'.repeat(32) }), null);
    assert.equal(keys.tagSecretFrom({ API_KEY_TAG_SECRET: 'x'.repeat(43) }), null);
    assert.equal(keys.tagSecretFrom({ API_KEY_TAG_SECRET: 'x'.repeat(44) }), 'x'.repeat(44));
    assert.equal(keys.tagSecretFrom({ API_KEY_TAG_SECRET: 42 }), null);
  });

  test('new key ids are UUID v4 from 16 random bytes', () => {
    assert.equal(keys.newKeyId(Buffer.alloc(16, 0xff)), 'ffffffff-ffff-4fff-bfff-ffffffffffff');
    assert.equal(keys.newKeyId(Buffer.alloc(16, 0)), '00000000-0000-4000-8000-000000000000');
    assert.throws(() => keys.newKeyId(Buffer.alloc(15)), /16 random bytes/);
  });

  test('two keys from different bytes never share a hash; the hash is sha256 hex', async () => {
    const a = await mint({ randomBytes: Buffer.alloc(32, 1) });
    const b = await mint({ randomBytes: Buffer.alloc(32, 2) });
    assert.notEqual(keys.sha256Hex(a), keys.sha256Hex(b));
    assert.equal(keys.sha256Hex(a), createHash('sha256').update(a).digest('hex'));
    assert.match(keys.sha256Hex(a), /^[0-9a-f]{64}$/);
  });

  test('Bearer parsing: only "Bearer trk_<107>" passes, and every failure is the same invalid_key', async () => {
    const key = await mint({ randomBytes: Buffer.alloc(32, 7) });
    assert.deepEqual(keys.parseBearer(`Bearer ${key}`), { key });
    for (const bad of [undefined, '', key, `Basic ${key}`, `Bearer`, `Bearer ${key.slice(0, -1)}`, `Bearer ${key}x`,
      `Bearer sk_${key.slice(3)}`, `Bearer ${key} extra`, `bearer ${key}`, `Bearer trk_${'!'.repeat(107)}`,
      `Bearer trk_${'A'.repeat(43)}`]) {
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
    // not_configured (2026-10-12): API_KEY_TAG_SECRET unset, so no key can be verified (fail closed).
    assert.deepEqual([...v1.ERROR_CODES].sort(), ['invalid_cursor', 'invalid_key', 'invalid_parameter', 'insufficient_scope',
      'key_expired', 'key_in_query', 'key_revoked', 'method_not_allowed', 'not_configured', 'not_found', 'rate_limited',
      'server_error', 'unavailable'].sort());
    assert.equal(v1.ERRORS.not_configured[0], 503);
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

describe('request guard: client key (§14.4a)', () => {
  test('IPv4 is the address; IPv6 is its /64 in any spelling; IPv4-mapped is the IPv4 client', () => {
    assert.equal(clientKey('203.0.113.9'), '203.0.113.9');
    assert.equal(clientKey(' 203.0.113.9 '), '203.0.113.9');
    for (const a of ['2001:db8:1:2::1', '2001:DB8:1:2:ffff:ffff:ffff:ffff', '2001:0db8:0001:0002:0:0:0:9', '[2001:db8:1:2::a]', '2001:db8:1:2::1%eth0']) {
      assert.equal(clientKey(a), '2001:db8:1:2::/64', a);
    }
    assert.notEqual(clientKey('2001:db8:1:3::1'), clientKey('2001:db8:1:2::1'), 'another /64 is another client');
    assert.equal(clientKey('::ffff:203.0.113.9'), '203.0.113.9');
    assert.equal(clientKey('2001:db8:1:2::203.0.113.9'), '2001:db8:1:2::/64');
  });

  test('a missing header is one shared bucket (accepted); garbage never throws', () => {
    assert.equal(clientKey(null), clientKey(undefined));
    assert.equal(clientKey(''), clientKey('   '));
    assert.equal(clientKey(null), clientKey(''));
    assert.ok(clientKey('x'.repeat(500)).length <= 64);
    assert.equal(typeof clientKey('1::2::3'), 'string');
  });
});

describe('request guard: windows and limits (§14.4a)', () => {
  const H1 = 'a'.repeat(64);
  const H2 = 'b'.repeat(64);

  test('the numbers live in one place', () => {
    assert.deepEqual({ ...GUARD_LIMITS }, {
      WINDOW_MS: 60_000, CLIENT_TOKENS: 10, OWNER_TOKENS: 10, GLOBAL_TOKENS: 60, GLOBAL_RESERVE: 240, KNOWN_IN_FLIGHT: 4,
      KNOWN_TTL_MS: 3_600_000, JUNK_LIMIT: 20, MAX_CLIENTS: 2000, MAX_OWNERS: 10_000, MAX_JUNK_CLIENTS: 2000,
      MAX_KNOWN_KEYS: 10_000, MAX_KNOWN_PER_OWNER: 10, MAX_IN_FLIGHT_KEYS: 1000, MAX_DENIED_KEYS: 10_000,
      MAX_DENIED_PER_OWNER: 100, MAX_LIMITED_KEYS: 2000,
    });
    assert.ok(Object.isFrozen(GUARD_LIMITS));
    assert.equal(createApiGuard().limits.CLIENT_TOKENS, 10);
  });

  test('junk: the 21st keyless request in a window is 429 until the window ends; per client', () => {
    const g = createApiGuard();
    const t0 = 1_000_000;
    for (let i = 0; i < 20; i++) assert.equal(g.junkRequest('198.51.100.1', t0 + i), 0);
    assert.equal(g.junkRequest('198.51.100.1', t0 + 100), 60);
    assert.equal(g.junkRequest('198.51.100.1', t0 + 30_000), 30);
    assert.equal(g.junkRequest('198.51.100.2', t0 + 100), 0, 'per client');
    assert.equal(g.junkRequest('198.51.100.1', t0 + 60_000), 0, 'a new window');
  });

  test('tokens: 10 per client and 60 per isolate per window, both or neither, Retry-After to the window end', () => {
    const g = createApiGuard();
    const t0 = 2_000_000;
    for (let i = 0; i < 10; i++) assert.ok(g.takeTokens('c0', t0).ticket);
    assert.deepEqual(g.takeTokens('c0', t0 + 15_000), { retryAfter: 45 });
    // A client-empty refusal took no isolate token: 50 more clients fill the isolate bucket exactly.
    for (let c = 1; c <= 50; c++) assert.ok(g.takeTokens(`c${c}`, t0 + 20_000).ticket, `c${c}`);
    assert.deepEqual(g.takeTokens('fresh', t0 + 20_000), { retryAfter: 40 }, 'isolate bucket empty');
    assert.equal(g.sizes().clients, 51, 'a refused client stored nothing');
    assert.ok(g.takeTokens('fresh', t0 + 60_000).ticket, 'the isolate window ends');
    assert.ok(g.takeTokens('c0', t0 + 60_000).ticket, 'the client window ends');
  });

  test('refunds return both tokens to the issuing window only, once', () => {
    const g = createApiGuard();
    const t0 = 3_000_000;
    const tickets = Array.from({ length: 10 }, () => g.takeTokens('c', t0).ticket);
    assert.ok(g.takeTokens('c', t0).retryAfter);
    g.refundTokens(tickets[0]);
    g.refundTokens(tickets[0]); // a second refund of the same ticket is ignored
    g.refundTokens(null);
    assert.ok(g.takeTokens('c', t0 + 1).ticket, 'one token came back');
    assert.ok(g.takeTokens('c', t0 + 2).retryAfter, 'only one');
    // Window 2: a late refund from window 1 must not top it up.
    const w2 = Array.from({ length: 10 }, () => g.takeTokens('c', t0 + 60_000).ticket);
    assert.ok(w2.every(Boolean));
    for (const t of tickets.slice(1)) g.refundTokens(t);
    assert.ok(g.takeTokens('c', t0 + 60_001).retryAfter, 'no cross-window refund (client bucket)');
    // Same for the isolate bucket.
    const h = createApiGuard();
    const old = Array.from({ length: 60 }, (_, i) => h.takeTokens(`a${i}`, t0).ticket);
    for (let i = 0; i < 60; i++) assert.ok(h.takeTokens(`b${i}`, t0 + 60_000).ticket);
    for (const t of old) h.refundTokens(t);
    assert.ok(h.takeTokens('z', t0 + 60_001).retryAfter, 'no cross-window refund (isolate bucket)');
  });

  test('owner bucket: 10 per owner per window across clients, all-or-none with the client and isolate buckets, refunded once', () => {
    const g = createApiGuard();
    const t0 = 4_000_000;
    const A = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
    const tickets = [];
    for (let i = 0; i < 10; i++) tickets.push(g.takeTokens(`ip-${i}`, t0, A).ticket);
    assert.ok(tickets.every(Boolean));
    assert.deepEqual(g.takeTokens('ip-new', t0 + 15_000, A), { retryAfter: 45 }, 'owner bucket empty');
    assert.equal(g.globalTokensUsed(t0 + 15_000), 10, 'the owner refusal took no isolate token');
    assert.equal(g.sizes().clients, 10, 'nor a client token');
    assert.ok(g.takeTokens('ip-new', t0 + 15_000, 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb').ticket, 'another owner is unaffected');
    g.refundTokens(tickets[0]);
    g.refundTokens(tickets[0]);
    assert.ok(g.takeTokens('ip-x', t0 + 16_000, A).ticket, 'one owner token came back');
    assert.ok(g.takeTokens('ip-y', t0 + 16_000, A).retryAfter, 'only one');
    assert.ok(g.takeTokens('ip-z', t0 + 60_000, A).ticket, 'a new owner window');
    assert.equal(g.sizes().owners, 2);
  });

  test('in flight: 4 slots per known hash, released once, entry gone at zero', () => {
    const g = createApiGuard();
    const slots = Array.from({ length: 4 }, () => g.takeInFlight(H1));
    assert.ok(slots.every(Boolean));
    assert.equal(g.takeInFlight(H1), null);
    assert.ok(g.takeInFlight(H2), 'per hash');
    g.releaseInFlight(slots[0]);
    g.releaseInFlight(slots[0]); // double release is ignored
    g.releaseInFlight(null);
    const again = g.takeInFlight(H1);
    assert.ok(again);
    assert.equal(g.takeInFlight(H1), null, 'exactly one slot came back');
    for (const s of [...slots.slice(1), again]) g.releaseInFlight(s);
    assert.equal(g.sizes().inFlight, 1, 'H1 entry removed at zero; H2 still busy');
    assert.equal(g.takeInFlight('not-a-hash'), null);
  });

  test('at the in-flight map cap a new hash is refused; a busy entry is never evicted', () => {
    const g = createApiGuard({ MAX_IN_FLIGHT_KEYS: 1 });
    const a = Array.from({ length: 4 }, () => g.takeInFlight(H1));
    assert.ok(a.every(Boolean));
    assert.equal(g.takeInFlight(H2), null, 'map full of busy hashes');
    assert.equal(g.takeInFlight(H1), null, 'H1 still capped at 4 (its entry was not evicted)');
    for (const s of a) g.releaseInFlight(s);
    assert.equal(g.sizes().inFlight, 0);
    assert.ok(g.takeInFlight(H2), 'room again once H1 is idle');
  });

  test('negative cache: unknown, revoked and expired for the key\'s life, each with its own code; leaves the positive cache', () => {
    // Changed 2026-10-12 (§14.4a #5, #6): every denial of a tag-valid key is
    // final, so none lapses after 60 s (unknown did until round 6).
    const g = createApiGuard();
    const t0 = 5_000_000;
    const YEAR = 365 * 86_400_000;
    g.knownKey(H1, t0);
    g.deniedKey(H1, 'key_revoked', t0 + 1);
    assert.equal(g.isKnownKey(H1, t0 + 2), false);
    assert.deepEqual(g.keyShed(H1, t0 + 59_999), { error: 'key_revoked' });
    assert.deepEqual(g.keyShed(H1, t0 + 60_001), { error: 'key_revoked' });
    assert.deepEqual(g.keyShed(H1, t0 + 10 * YEAR), { error: 'key_revoked' });
    g.deniedKey(H2, 'key_expired', t0);
    assert.deepEqual(g.keyShed(H2, t0 + 10 * YEAR), { error: 'key_expired' });
    g.deniedKey('c'.repeat(64), 'invalid_key', t0);
    assert.deepEqual(g.keyShed('c'.repeat(64), t0), { error: 'invalid_key' });
    assert.deepEqual(g.keyShed('c'.repeat(64), t0 + 10 * YEAR), { error: 'invalid_key' }, 'unknown: for life too');
    g.deniedKey('d'.repeat(64), 'something_else', t0);
    assert.equal(g.keyShed('d'.repeat(64), t0), null);
    g.knownKey(H2, t0 + 5);
    assert.equal(g.keyShed(H2, t0 + 6), null, 'a success clears the negative entry');
  });

  test('reserve: once the shared pool is empty, an owner holding no token still gets one; 300 per window in all', () => {
    const g = createApiGuard();
    const t0 = 6_000_000;
    const owner = (i) => `00000000-0000-4000-8000-${String(i).padStart(12, '0')}`;
    // 6 owners spend the shared pool (60) on keys the RPC denies (no refund).
    for (let o = 0; o < 6; o++) for (let i = 0; i < 10; i++) assert.ok(g.takeTokens(`ip-${o}-${i}`, t0, owner(o)).ticket);
    assert.equal(g.globalTokensUsed(t0), 60);
    assert.ok(g.takeTokens('ip-x', t0, owner(0)).retryAfter, 'a spent owner gets nothing more');
    assert.ok(g.takeTokens('ip-x', t0).retryAfter, 'no owner, no reserve');
    // A fresh owner: its first token comes from the reserve; its second waits.
    const first = g.takeTokens('ip-v', t0, owner(100));
    assert.equal(first.ticket.pool, 'reserve');
    assert.deepEqual(g.takeTokens('ip-v2', t0 + 30_000, owner(100)), { retryAfter: 30 });
    // A live answer returns it to the reserve, so the owner may go again.
    g.refundTokens(first.ticket);
    assert.equal(g.takeTokens('ip-v3', t0, owner(100)).ticket.pool, 'reserve');
    // The reserve itself is finite: 239 more owners, then nobody new.
    for (let i = 0; i < 239; i++) assert.ok(g.takeTokens(`ip-r${i}`, t0, owner(1000 + i)).ticket);
    assert.equal(g.globalTokensUsed(t0), 300);
    assert.ok(g.takeTokens('ip-late', t0, owner(5000)).retryAfter, 'hard isolate bound: 60 + 240 per window');
    assert.ok(g.takeTokens('ip-late', t0 + 60_000, owner(5000)).ticket, 'a new window');
  });

  test('negative cache per owner: one owner\'s churn evicts only its own oldest entries', () => {
    const g = createApiGuard({ MAX_DENIED_PER_OWNER: 3, MAX_DENIED_KEYS: 100 });
    const A = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
    const B = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
    g.deniedKey(sha('b0'), 'key_revoked', 1, B);
    for (let i = 0; i < 50; i++) g.deniedKey(sha(`a${i}`), 'key_revoked', 1, A);
    assert.equal(g.sizes().deniedKeys, 4, '3 of A + 1 of B');
    assert.deepEqual(g.keyShed(sha('b0'), 2), { error: 'key_revoked' }, "B's entry survives A's churn");
    assert.deepEqual(g.keyShed(sha('a49'), 2), { error: 'key_revoked' });
    assert.equal(g.keyShed(sha('a0'), 2), null, "A's oldest went");
  });

  test('positive cache: LRU on hit, and at most 10 entries per owner', () => {
    const g = createApiGuard({ MAX_KNOWN_KEYS: 3 });
    const owner = (i) => `00000000-0000-4000-8000-${String(i).padStart(12, '0')}`;
    g.knownKey(sha('victim'), 0, owner(0));
    g.knownKey(sha('k1'), 1, owner(1));
    g.knownKey(sha('k2'), 2, owner(2));
    assert.equal(g.isKnownKey(sha('victim'), 3), true); // a hit moves it to the back
    g.knownKey(sha('k3'), 4, owner(3));
    assert.equal(g.isKnownKey(sha('k1'), 5), false, 'the least recently used went');
    assert.equal(g.isKnownKey(sha('victim'), 5), true);
    const h = createApiGuard();
    for (let i = 0; i < 25; i++) h.knownKey(sha(`same-owner-${i}`), i, owner(9));
    h.knownKey(sha('other'), 30, owner(8));
    assert.equal(h.sizes().knownKeys, 11, '10 of one owner + 1');
    assert.equal(h.isKnownKey(sha('same-owner-14'), 31), false);
    assert.equal(h.isKnownKey(sha('same-owner-15'), 31), true);
  });

  test('rate-limited hash: shed until the reported reset, with the stored rate headers', () => {
    const g = createApiGuard();
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

  test('positive cache: sixty-minute TTL', () => {
    const g = createApiGuard();
    g.knownKey(H1, 0);
    assert.equal(g.isKnownKey(H1, 3_599_999), true);
    assert.equal(g.isKnownKey(H1, 3_600_000), false);
  });

  test('only sha256 hex is accepted as a guard key, so a presented key is never remembered', () => {
    const g = createApiGuard();
    const raw = `trk_${'Z'.repeat(107)}`;
    g.deniedKey(raw, 'invalid_key', 1);
    g.rateLimitedKey(raw, { retryAfter: 30 }, 1);
    g.knownKey(raw, 1);
    assert.equal(g.takeInFlight(raw), null);
    assert.deepEqual(g.sizes(), { clients: 0, owners: 0, junk: 0, knownKeys: 0, inFlight: 0, deniedKeys: 0, limitedKeys: 0 });
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
