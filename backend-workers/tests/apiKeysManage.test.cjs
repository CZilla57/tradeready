// POST /api/api-keys/manage (Roadmap Phase 23, spec §2 and build record
// §14.1). The `api_key_admin` RPC is scripted here; its SQL semantics (cap,
// rotate pairing, replay, ownership) are proven on a real PostgreSQL by
// supabase/verify/local/api_keys.sh. These tests pin the Worker side: the
// raw key appears exactly once (the 200 body) and never in any request the
// Worker makes; the RPC gets the hash and display prefix; replays never
// return a secret; list/activity never select key_hash; every error maps to
// the contract's code; and the route is JWT-authed with appCors.

const { describe, test, before, afterEach } = require('node:test');
const assert = require('node:assert/strict');

const { apiKeysManageCore, toKeySummary, requestHash } = require('../lib/api/keyAdmin.js');
const keys = require('../lib/api/keys.js');

const ENV = { SUPABASE_URL: 'https://supa.test', SUPABASE_SERVICE_ROLE_KEY: 'srk', SUPABASE_ANON_KEY: 'anon' };
const OWNER = '11111111-1111-4111-8111-111111111111';
const KEY_ID = '22222222-2222-4222-8222-222222222222';
const NEW_ID = '33333333-3333-4333-8333-333333333333';
const OP = '0193f123-0000-4000-8000-000000000001';
const NOW = Date.parse('2026-10-03T18:00:00Z');
const BYTES = Buffer.alloc(32, 0x5a);
const SECRET = keys.generateApiKey(BYTES);
const realFetch = global.fetch;
afterEach(() => { global.fetch = realFetch; });

function jsonRes(body, status = 200) {
  return { ok: status >= 200 && status < 300, status, json: async () => body, text: async () => JSON.stringify(body) };
}

const keyRow = (over = {}) => ({
  id: KEY_ID,
  name: 'Books',
  key_prefix: 'trk_WlpaWlpa',
  scopes: ['invoices:read', 'customers:read'],
  created_at: '2026-10-01T00:00:00+00:00',
  expires_at: '2027-10-01T00:00:00+00:00',
  revoked_at: null,
  last_used_at: null,
  replaced_by: null,
  ...over,
});

// rpc: FIFO envelopes (or a function of the body); rest: url → rows.
function backend({ rpc = [], rest = () => [], rpcStatus = 200 } = {}) {
  const calls = [];
  const q = Array.isArray(rpc) ? [...rpc] : null;
  global.fetch = async (url, init = {}) => {
    const u = String(url);
    calls.push({ u, method: init.method || 'GET', body: init.body ? JSON.parse(init.body) : null, raw: init.body || '' });
    if (u.includes('/rest/v1/rpc/api_key_admin')) {
      const body = JSON.parse(init.body);
      return jsonRes(q ? q.shift() : rpc(body), rpcStatus);
    }
    if (u.startsWith('https://supa.test/rest/v1/')) return jsonRes(rest(u));
    throw new Error(`unexpected fetch ${u}`);
  };
  return calls;
}

const run = (body, over = {}) =>
  apiKeysManageCore(ENV, { userId: OWNER, body, nowMs: NOW, randomBytes: () => BYTES, ...over });

const createBody = (over = {}) => ({ action: 'create', operationId: OP, name: '  Books ', scopes: ['invoices:read', 'customers:read'], ...over });

describe('create', () => {
  test('mints server-side, sends only hash + prefix, returns the secret once', async () => {
    const calls = backend({ rpc: [{ ok: true, decision: 'committed', key: keyRow() }] });
    const out = await run(createBody());
    assert.equal(out.status, 200);
    assert.equal(out.json.secret, SECRET);
    assert.deepEqual(Object.keys(out.json), ['ok', 'key', 'secret']);
    assert.deepEqual(out.json.key, {
      id: KEY_ID, name: 'Books', prefix: 'trk_WlpaWlpa', scopes: ['customers:read', 'invoices:read'],
      createdAt: '2026-10-01T00:00:00.000Z', expiresAt: '2027-10-01T00:00:00.000Z', revokedAt: null,
      lastUsedAt: null, replacedBy: null, status: 'active',
    });
    assert.equal(calls.length, 1);
    const sent = calls[0].body;
    assert.equal(sent.p_key_hash, keys.sha256Hex(SECRET));
    assert.equal(sent.p_key_prefix, SECRET.slice(0, 12));
    assert.equal(sent.p_name, 'Books', 'trimmed');
    assert.deepEqual(sent.p_scopes, ['customers:read', 'invoices:read'], 'canonical order');
    assert.equal(sent.p_expiry_days, 365, 'default expiry is 1 year');
    assert.equal(sent.p_operation_id, OP);
    assert.ok(!calls[0].raw.includes(SECRET), 'the raw key never reaches the database');
    assert.ok(!calls[0].raw.includes(SECRET.slice(4)), 'not even its body');
  });

  test('expiry choices map to 90 / 365 / none', async () => {
    for (const [expiry, days] of [['90d', 90], ['1y', 365], ['none', null]]) {
      const calls = backend({ rpc: [{ ok: true, key: keyRow() }] });
      await run(createBody({ expiry }));
      assert.equal(calls[0].body.p_expiry_days, days, expiry);
    }
  });

  test('the request hash covers the intent: stable on retry, different for a different request', async () => {
    const a = requestHash({ action: 'create', name: 'Books', scopes: ['customers:read'], expiry: '1y' });
    const b = requestHash({ action: 'create', name: 'Books', scopes: ['customers:read'], expiry: '1y' });
    const c = requestHash({ action: 'create', name: 'Books', scopes: ['customers:read'], expiry: '90d' });
    assert.equal(a, b);
    assert.notEqual(a, c);
    const calls = backend({ rpc: [{ ok: true, key: keyRow() }, { ok: true, key: keyRow() }] });
    await run(createBody());
    await run(createBody({ name: 'Books', scopes: ['customers:read', 'invoices:read', 'customers:read'] }));
    assert.equal(calls[0].body.p_request_hash, calls[1].body.p_request_hash, 'normalized intents hash the same');
  });

  test('a replayed operation is 409 already_completed with id and prefix and NO secret', async () => {
    backend({ rpc: [{ ok: false, error: 'already_completed', key: { id: KEY_ID, key_prefix: 'trk_WlpaWlpa' } }] });
    const out = await run(createBody());
    assert.deepEqual(out, { status: 409, json: { error: 'already_completed', key: { id: KEY_ID, prefix: 'trk_WlpaWlpa' } } });
    assert.ok(!JSON.stringify(out).includes('trk_WlpaWlpaWlpa'), 'no secret in a replay');
  });

  test('cap, conflict and fail-closed mapping', async () => {
    backend({ rpc: [{ ok: false, error: 'key_limit' }] });
    assert.deepEqual(await run(createBody()), { status: 409, json: { error: 'key_limit', maxLiveKeys: 5 } });
    backend({ rpc: [{ ok: false, error: 'operation_conflict' }] });
    assert.deepEqual(await run(createBody()), { status: 409, json: { error: 'operation_conflict' } });
    backend({ rpc: [{ ok: false, error: 'invalid_args' }] });
    assert.deepEqual(await run(createBody()), { status: 400, json: { error: 'invalid_request' } });
    backend({ rpc: [{ message: 'function not found' }], rpcStatus: 404 });
    assert.deepEqual(await run(createBody()), { status: 503, json: { error: 'unavailable' } }, 'migration not applied');
    backend({ rpc: [{ weird: true }] });
    assert.deepEqual(await run(createBody()), { status: 503, json: { error: 'unavailable' } });
    backend({ rpc: [{ ok: false, error: 'forbidden' }] });
    const errs = [];
    const orig = console.error;
    console.error = (...a) => errs.push(a.join(' '));
    try {
      assert.deepEqual(await run(createBody()), { status: 500, json: { error: 'server_error' } });
    } finally {
      console.error = orig;
    }
    assert.ok(!errs.join('').includes(SECRET));
  });

  test('invalid input is a 400 before any database contact', async () => {
    const cases = [
      { action: 'nope' },
      createBody({ operationId: undefined }),
      createBody({ operationId: 'not-a-uuid' }),
      createBody({ operationId: '0193f123-0000-1000-8000-000000000001' }),
      createBody({ name: '' }),
      createBody({ name: 'x'.repeat(41) }),
      createBody({ name: 'bad\u0007name' }),
      createBody({ scopes: [] }),
      createBody({ scopes: ['payroll:read'] }),
      createBody({ scopes: 'invoices:read' }),
      createBody({ expiry: '30d' }),
      { action: 'rotate', operationId: OP, keyId: 'nope' },
      { action: 'rotate', operationId: OP, keyId: KEY_ID, grace: '1h' },
      { action: 'revoke', keyId: 42 },
      { action: 'activity', keyId: 'x' },
    ];
    for (const body of cases) {
      const calls = backend();
      const out = await run(body);
      assert.deepEqual(out, { status: 400, json: { error: 'invalid_request' } }, JSON.stringify(body));
      assert.equal(calls.length, 0, JSON.stringify(body));
    }
    const calls = backend();
    assert.deepEqual(await apiKeysManageCore(ENV, { userId: 'nope', body: { action: 'list' }, nowMs: NOW }), { status: 401, json: { error: 'unauthorized' } });
    assert.equal(calls.length, 0);
  });
});

describe('rotate and revoke', () => {
  test('rotate returns the new key with its secret and the old key as expiring', async () => {
    const calls = backend({
      rpc: [{
        ok: true,
        decision: 'committed',
        key: keyRow({ id: NEW_ID, key_prefix: SECRET.slice(0, 12), created_at: '2026-10-03T18:00:00+00:00' }),
        previous: keyRow({ replaced_by: NEW_ID, expires_at: '2026-10-04T18:00:00+00:00' }),
      }],
    });
    const out = await run({ action: 'rotate', operationId: OP, keyId: KEY_ID });
    assert.equal(out.status, 200);
    assert.deepEqual(Object.keys(out.json), ['ok', 'key', 'previous', 'secret']);
    assert.equal(out.json.secret, SECRET);
    assert.equal(out.json.key.id, NEW_ID);
    assert.equal(out.json.previous.status, 'expiring');
    assert.equal(out.json.previous.replacedBy, NEW_ID);
    assert.equal(calls[0].body.p_grace_seconds, 86400, 'default grace is 24 hours');
    assert.equal(calls[0].body.p_key_id, KEY_ID);
    assert.ok(!calls[0].raw.includes(SECRET));
  });

  test('immediate grace and not_found', async () => {
    const calls = backend({ rpc: [{ ok: false, error: 'not_found' }] });
    assert.deepEqual(await run({ action: 'rotate', operationId: OP, keyId: KEY_ID, grace: 'immediate' }), { status: 404, json: { error: 'not_found' } });
    assert.equal(calls[0].body.p_grace_seconds, 0);
  });

  test('revoke needs no operation id and mints nothing', async () => {
    const calls = backend({ rpc: [{ ok: true, decision: 'committed', key: keyRow({ revoked_at: '2026-10-03T18:00:00+00:00' }) }] });
    const out = await run({ action: 'revoke', keyId: KEY_ID });
    assert.equal(out.status, 200);
    assert.equal(out.json.key.status, 'revoked');
    assert.equal(out.json.secret, undefined);
    assert.equal(calls[0].body.p_key_hash, null);
    assert.equal(calls[0].body.p_operation_id, null);
    backend({ rpc: [{ ok: false, error: 'not_found' }] });
    assert.deepEqual(await run({ action: 'revoke', keyId: KEY_ID }), { status: 404, json: { error: 'not_found' } });
  });
});

describe('list and activity', () => {
  test('owner-scoped, never selects key_hash, merges live and history, newest first', async () => {
    const live = [keyRow({ id: NEW_ID, created_at: '2026-10-03T00:00:00+00:00' })];
    const history = [
      keyRow({ id: NEW_ID, created_at: '2026-10-03T00:00:00+00:00' }),
      keyRow({ revoked_at: '2026-10-02T00:00:00+00:00' }),
      keyRow({ id: '44444444-4444-4444-8444-444444444444', expires_at: '2026-10-01T00:00:00+00:00', created_at: '2026-09-01T00:00:00+00:00' }),
      keyRow({ id: '55555555-5555-4555-8555-555555555555', replaced_by: NEW_ID, expires_at: '2026-10-04T00:00:00+00:00', created_at: '2026-09-15T00:00:00+00:00' }),
    ];
    const calls = backend({ rest: (u) => (u.includes('revoked_at=is.null') ? live : history) });
    const out = await run({ action: 'list' });
    assert.equal(out.status, 200);
    assert.equal(calls.length, 2);
    for (const c of calls) {
      assert.equal(c.method, 'GET');
      assert.ok(c.u.includes(`user_id=eq.${OWNER}`), c.u);
      assert.ok(!c.u.includes('key_hash'), c.u);
      assert.ok(!c.u.includes('operation_id') && !c.u.includes('request_hash'), c.u);
    }
    assert.deepEqual(out.json.keys.map((k) => [k.id.slice(0, 4), k.status]), [
      ['3333', 'active'], ['2222', 'revoked'], ['5555', 'expiring'], ['4444', 'expired'],
    ]);
    assert.equal(out.json.liveCount, 1);
    assert.equal(out.json.maxLiveKeys, 5);
    for (const k of out.json.keys) {
      assert.deepEqual(Object.keys(k), ['id', 'name', 'prefix', 'scopes', 'createdAt', 'expiresAt', 'revokedAt', 'lastUsedAt', 'replacedBy', 'status']);
    }
  });

  test('activity: the last 50 owner rows, optionally for one key', async () => {
    const calls = backend({
      rest: () => [{ created_at: '2026-10-03T17:00:00+00:00', key_id: KEY_ID, event: 'ok', route: '/v1/invoices', status: 200, ip: '203.0.113.9' }],
    });
    const out = await run({ action: 'activity', keyId: KEY_ID });
    assert.deepEqual(out, {
      status: 200,
      json: { ok: true, events: [{ at: '2026-10-03T17:00:00.000Z', keyId: KEY_ID, event: 'ok', route: '/v1/invoices', status: 200, ip: '203.0.113.9' }] },
    });
    assert.ok(calls[0].u.startsWith(`https://supa.test/rest/v1/api_access_log?user_id=eq.${OWNER}&key_id=eq.${KEY_ID}`));
    assert.ok(calls[0].u.includes('order=created_at.desc') && calls[0].u.includes('limit=50'));
  });

  test('tables missing (migration not applied) → 503', async () => {
    global.fetch = async () => jsonRes({ message: 'relation does not exist' }, 404);
    assert.deepEqual(await run({ action: 'list' }), { status: 503, json: { error: 'unavailable' } });
    assert.deepEqual(await run({ action: 'activity' }), { status: 503, json: { error: 'unavailable' } });
  });
});

describe('status is computed at response time', () => {
  test('revoked > expired > expiring > active', () => {
    assert.equal(toKeySummary(keyRow({ revoked_at: '2026-10-01T00:00:00Z', replaced_by: NEW_ID }), NOW).status, 'revoked');
    assert.equal(toKeySummary(keyRow({ expires_at: '2026-10-03T17:59:59Z', replaced_by: NEW_ID }), NOW).status, 'expired');
    assert.equal(toKeySummary(keyRow({ expires_at: '2026-10-03T18:00:01Z', replaced_by: NEW_ID }), NOW).status, 'expiring');
    assert.equal(toKeySummary(keyRow({ expires_at: null }), NOW).status, 'active');
    assert.equal(toKeySummary(keyRow({ expires_at: null }), NOW).expiresAt, null);
  });
});

describe('route wiring (full Worker fetch)', () => {
  let worker;
  before(async () => {
    worker = (await import('../src/index.js')).default;
  });
  const call = (init = {}, path = '/api/api-keys/manage') =>
    worker.fetch(new Request(`https://w.test${path}`, { method: 'POST', ...init }), ENV, { waitUntil() {} });

  test('OPTIONS answers appCors; GET is 405', async () => {
    global.fetch = async () => { throw new Error('no fetch expected'); };
    const pre = await call({ method: 'OPTIONS', headers: { origin: 'https://gettradereadyapp.com' } });
    assert.equal(pre.status, 200);
    assert.equal(pre.headers.get('access-control-allow-methods'), 'POST, OPTIONS');
    assert.match(pre.headers.get('access-control-allow-headers'), /Authorization/);
    const get = await call({ method: 'GET' });
    assert.equal(get.status, 405);
    assert.deepEqual(await get.json(), { error: 'method_not_allowed' });
  });

  test('no bearer or a rejected session is 401 unauthorized, with no RPC call', async () => {
    const calls = [];
    global.fetch = async (url) => {
      calls.push(String(url));
      return jsonRes({ message: 'bad jwt' }, 401);
    };
    const none = await call({ body: JSON.stringify({ action: 'list' }) });
    assert.equal(none.status, 401);
    assert.deepEqual(await none.json(), { error: 'unauthorized' });
    const bad = await call({ headers: { authorization: 'Bearer expired' }, body: JSON.stringify({ action: 'list' }) });
    assert.equal(bad.status, 401);
    assert.deepEqual(calls, ['https://supa.test/auth/v1/user']);
  });

  test('create end to end: JWT → RPC → secret in the body; 11th call in a minute is 429', async () => {
    const user = '66666666-6666-4666-8666-666666666666';
    const seen = [];
    global.fetch = async (url, init = {}) => {
      const u = String(url);
      seen.push({ u, body: init.body || '' });
      if (u.endsWith('/auth/v1/user')) return jsonRes({ id: user });
      if (u.endsWith('/rpc/api_key_admin')) return jsonRes({ ok: true, decision: 'committed', key: keyRow() });
      if (u.includes('/rest/v1/api_keys')) return jsonRes([]);
      throw new Error(`unexpected ${u}`);
    };
    const res = await call({
      headers: { authorization: 'Bearer good', 'content-type': 'application/json' },
      body: JSON.stringify(createBody()),
    });
    assert.equal(res.status, 200);
    const body = await res.json();
    assert.match(body.secret, /^trk_[A-Za-z0-9_-]{43}$/);
    assert.equal(body.secret.slice(0, 12), JSON.parse(seen[1].body).p_key_prefix);
    for (const s of seen) assert.ok(!s.body.includes(body.secret), 'secret never sent anywhere');
    let last;
    for (let i = 0; i < 10; i++) {
      last = await call({ headers: { authorization: 'Bearer good' }, body: JSON.stringify({ action: 'list' }) });
    }
    assert.equal(last.status, 429);
    assert.deepEqual(await last.json(), { error: 'rate_limited' });
  });
});
