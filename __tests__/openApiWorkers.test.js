// __tests__/openApiWorkers.test.js
// Roadmap Phase 23 — read-only open API route tests (spec §10 "Route
// tests"). Run under TZ=America/Phoenix like every *Workers oracle.
//
// A small fake PostgREST stands in for Supabase: it serves the blob tables
// for TWO owners, honours the filters the API sends (owner, id, deleted,
// updated_since, the keyset cursor, the estimate filter, payment
// containment, order, limit, select) and THROWS on any read without a
// user_id filter. The `api_key_authorize` RPC is scripted per key hash; its
// SQL is proven separately on a real PostgreSQL
// (supabase/verify/local/api_keys.sh).
//
// The security bar pinned here:
//   - every Supabase read carries user_id=eq.<resolved owner>;
//   - no non-GET ever reaches jobs|invoices|customers|expenses|trips|settings
//     (the only POSTs are the authorize RPC and the access-log insert);
//   - 405 for POST/PUT/PATCH/DELETE/HEAD/OPTIONS on every /v1 path;
//   - scopes, revoked/expired keys, rate limits, fail-closed 503;
//   - unknown parameters, key-in-query, no CORS headers;
//   - forged, random or untagged keys cost nothing (no token, no cache
//     entry, no RPC), and a missing API_KEY_TAG_SECRET fails closed (503);
//   - the raw key never appears in a console call, a log body or any
//     request the Worker makes.

const { createHash, createHmac } = require('node:crypto');
const { handleV1 } = require('../backend-workers/lib/api/v1.js');
const { createApiGuard, GUARD_LIMITS } = require('../backend-workers/lib/api/auth.js');
const { apiV1Handler } = require('../backend-workers/src/routes/api/v1.js');
const { FIELDS } = require('../backend-workers/lib/api/resources.js');

const OWNER = '11111111-1111-4111-8111-111111111111';
const INTRUDER = '99999999-9999-4999-8999-999999999999';
const KEY_ID = '22222222-2222-4222-8222-222222222222';
const KEY_ID_JOBS = '33333333-3333-4333-8333-333333333333';
const BASE = 'https://tradeready-backend.tradeready.workers.dev';
const TAG_SECRET = 'tag-secret-for-route-tests-0123456789-abcdefgh';
const ENV = {
  SUPABASE_URL: 'https://supa.test',
  SUPABASE_SERVICE_ROLE_KEY: 'srk',
  API_CURSOR_SECRET: 'cursor-secret',
  API_KEY_TAG_SECRET: TAG_SECRET,
};
const BUSINESS_TABLES = ['jobs', 'invoices', 'customers', 'expenses', 'trips', 'settings'];
const ALL_SCOPES = ['customers:read', 'jobs:read', 'invoices:read', 'expenses:read', 'mileage:read'];

const sha = (s) => createHash('sha256').update(s).digest('hex');
// A deterministic UUID v4 per seed.
const uuidOf = (seed) => {
  const h = sha(`uuid:${seed}`);
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-4${h.slice(13, 16)}-${'89ab'[parseInt(h[16], 16) & 3]}${h.slice(17, 20)}-${h.slice(20, 32)}`;
};
const uuidBytes = (u) => Buffer.from(u.replace(/-/g, ''), 'hex');
const bytesUuid = (b) => { const h = b.toString('hex'); return `${h.slice(0, 8)}-${h.slice(8, 12)}-${h.slice(12, 16)}-${h.slice(16, 20)}-${h.slice(20)}`; };
// Mints a tagged key exactly as the Worker does (spec §2), computed here with
// node:crypto's HMAC as an independent oracle for the Worker's WebCrypto tag.
// Keys are built at runtime so no key-shaped literal sits in the repo.
function mint({ keyId, ownerId = OWNER, seed, secret = TAG_SECRET }) {
  const signed = Buffer.concat([uuidBytes(keyId), uuidBytes(ownerId), createHash('sha256').update(`body:${seed}`).digest()]);
  const tag = createHmac('sha256', secret).update(Buffer.concat([Buffer.from('tradeready-api-key-v1\0'), signed])).digest().subarray(0, 16);
  return `trk_${Buffer.concat([signed, tag]).toString('base64url')}`;
}
const idsOf = (key) => {
  const b = Buffer.from(key.slice(4), 'base64url');
  return { keyId: bytesUuid(b.subarray(0, 16)), userId: bytesUuid(b.subarray(16, 32)) };
};
const mkKey = (seed) => mint({ keyId: uuidOf(seed), seed });
const KEY = mint({ keyId: KEY_ID, seed: 'A' });
const KEY_JOBS_ONLY = mint({ keyId: KEY_ID_JOBS, seed: 'J' });
const KEY_REVOKED = mkKey('R');
const KEY_EXPIRED = mkKey('E');
const KEY_LIMITED = mkKey('L');
const KEY_UNKNOWN = mkKey('U');
const ALL_KEYS = [KEY, KEY_JOBS_ONLY, KEY_REVOKED, KEY_EXPIRED, KEY_LIMITED, KEY_UNKNOWN];

// Microsecond timestamps in PostgREST's format; minute n of the day.
const ts = (n, micros = '000001') => `2026-10-03T${String(10 + Math.floor(n / 60)).padStart(2, '0')}:${String(n % 60).padStart(2, '0')}:00.${micros}+00:00`;

function seed() {
  const rows = { customers: [], jobs: [], invoices: [], expenses: [], trips: [], settings: [] };
  const add = (table, user_id, id, updated_at, data, deleted = false) => rows[table].push({ id, user_id, updated_at, deleted, data });
  for (let i = 1; i <= 7; i++) {
    add('customers', OWNER, `c${i}`, ts(i), { id: `c${i}`, name: `Customer ${i}`, email: '', phone: '', address: '', notes: 'INTERNAL-NOTE' });
  }
  // Two customers updated in the same microsecond: the (updated_at, id) tie-break.
  add('customers', OWNER, 'c8a', ts(20), { id: 'c8a', name: 'Tie A', notes: 'INTERNAL-NOTE' });
  add('customers', OWNER, 'c8b', ts(20), { id: 'c8b', name: 'Tie B', notes: 'INTERNAL-NOTE' });
  add('customers', OWNER, 'c-dead', ts(30), { id: 'c-dead', name: 'Gone' }, true);
  add('customers', INTRUDER, 'x1', ts(5), { id: 'x1', name: 'Someone else', notes: 'OTHER-TENANT' });
  add('jobs', OWNER, 'j1', ts(1), { id: 'j1', title: 'Plain job', status: 'scheduled', estimateTotal: 100, laborRate: 987.65, notes: 'INTERNAL-NOTE' });
  add('jobs', OWNER, 'j2', ts(2), {
    id: 'j2', title: 'Quoted', status: 'estimate_sent', estimateTotal: 500, customerId: 'c1',
    approval: {
      token: 'APPROVAL-TOKEN', sentAt: '2026-10-01T00:00:00Z', ip: '198.51.100.77', userAgent: 'UA',
      snapshot: { jobTitle: 'Quoted', customerName: 'Customer 1', lineItems: [{ label: 'Labor', amount: 500 }], total: 500, currency: 'USD' },
    },
  });
  add('jobs', OWNER, 'j3', ts(3), { id: 'j3', title: 'Sent by PDF', status: 'estimate_sent', estimateSentAt: '2026-10-01', estimateTotal: 250 });
  add('jobs', INTRUDER, 'jx', ts(2), { id: 'jx', title: 'Other tenant', approval: { token: 't', snapshot: { total: 1 } } });
  add('invoices', OWNER, 'inv1', ts(1), {
    id: 'inv1', number: 'INV-1', amount: 300, customer: 'Customer 1', email: 'PRIVATE-EMAIL', paymentLinkAmount: 300,
    payments: [{ id: 'p1', amount: 100, date: '2026-10-01', method: 'cash', note: 'INTERNAL-NOTE' }, { id: 'p2', amount: 50, date: '2026-10-02', method: 'Cheque' }],
  });
  add('invoices', OWNER, 'inv2', ts(2), { id: 'inv2', number: 'INV-2', amount: 80 });
  add('invoices', OWNER, 'inv3', ts(3), { id: 'inv3', number: 'INV-3', amount: 40, paid: true, paidAt: '2026-09-01' });
  add('invoices', OWNER, 'inv-dead', ts(40), { id: 'inv-dead', amount: 10, payments: [{ id: 'p-dead', amount: 10 }] }, true);
  add('invoices', INTRUDER, 'invx', ts(2), { id: 'invx', amount: 1, payments: [{ id: 'p1', amount: 1 }] });
  add('expenses', OWNER, 'e1', ts(1), { id: 'e1', amount: 12.5, category: 'fuel', receiptUri: 'file:///private/r.jpg', notes: 'INTERNAL-NOTE' });
  add('trips', OWNER, 't1', ts(1), { id: 't1', miles: 12.4, fromLabel: 'Shop', toLabel: 'Site' });
  rows.settings.push({ user_id: OWNER, updated_at: ts(50), data: { businessName: 'Ruiz Electric', anthropicKey: 'sk-ant-SETTINGS-SECRET', pushToken: { token: 'PUSH' } } });
  return rows;
}

const KEYS_BY_HASH = {
  [sha(KEY)]: { ok: true, userId: OWNER, keyId: KEY_ID, scopes: ALL_SCOPES, name: 'Books', prefix: KEY.slice(0, 12), expiresAt: '2027-10-03T00:00:00+00:00', limit: 60, remaining: 41, reset: 1791040000 },
  [sha(KEY_JOBS_ONLY)]: { ok: true, userId: OWNER, keyId: KEY_ID_JOBS, scopes: ['jobs:read'], name: 'Jobs', prefix: 'trk_JJJJJJJJ', expiresAt: null, limit: 60, remaining: 59, reset: 1791040000 },
  [sha(KEY_REVOKED)]: { ok: false, error: 'key_revoked' },
  [sha(KEY_EXPIRED)]: { ok: false, error: 'key_expired' },
  [sha(KEY_LIMITED)]: { ok: false, error: 'rate_limited', retryAfter: 17, limit: 60, remaining: 0, reset: 1791040017 },
  [sha(KEY_UNKNOWN)]: { ok: false, error: 'invalid_key' },
};
// A live envelope for any tagged key: KEY's answer under that key's own id
// and owner (the Worker refuses a row that is not the one the tag names).
const live = (key) => ({ ...KEYS_BY_HASH[sha(KEY)], ...idsOf(key) });
// An 80-byte payload that is not a minted key: random bytes, or a real
// key's id and owner with a made-up body and tag.
const forgedFrom = (seed, prefixBytes = Buffer.alloc(0)) => {
  const fill = Buffer.concat([0, 1, 2].map((j) => createHash('sha256').update(`forge:${seed}:${j}`).digest()));
  return `trk_${Buffer.concat([prefixBytes, fill]).subarray(0, 80).toString('base64url')}`;
};

function jsonRes(body, status = 200) {
  return { ok: status >= 200 && status < 300, status, json: async () => body, text: async () => JSON.stringify(body) };
}

// ── fake PostgREST ───────────────────────────────────────────────────────

function applyQuery(table, rows, url) {
  const p = url.searchParams;
  const owner = p.getAll('user_id');
  if (owner.length !== 1 || !owner[0].startsWith('eq.')) throw new Error(`UNSCOPED READ of ${table}: ${url}`);
  let out = rows.filter((r) => r.user_id === owner[0].slice(3));
  if (p.has('id')) out = out.filter((r) => r.id === p.get('id').replace(/^eq\./, ''));
  if (p.get('deleted') === 'is.false') out = out.filter((r) => r.deleted === false);
  if (p.has('updated_at')) {
    const since = Date.parse(p.get('updated_at').replace(/^gte\./, ''));
    out = out.filter((r) => Date.parse(r.updated_at) >= since);
  }
  const and = p.get('and');
  if (and) {
    if (and.includes('data->approval.not.is.null')) {
      out = out.filter((r) => (r.data.approval !== undefined && r.data.approval !== null) || (r.data.estimateSentAt !== undefined && r.data.estimateSentAt !== null));
    }
    const m = and.match(/or\(updated_at\.gt\."([^"]+)",and\(updated_at\.eq\."([^"]+)",id\.gt\."((?:[^"\\]|\\.)*)"\)\)/);
    if (m) {
      const [, u, , id] = m;
      out = out.filter((r) => r.updated_at > u || (r.updated_at === u && r.id > id));
    }
  }
  if (p.has('data->payments')) {
    const [{ id }] = JSON.parse(p.get('data->payments').replace(/^cs\./, ''));
    out = out.filter((r) => Array.isArray(r.data.payments) && r.data.payments.some((x) => x.id === id));
  }
  const order = p.get('order');
  if (order === 'updated_at.asc,id.asc') {
    out.sort((a, b) => (a.updated_at < b.updated_at ? -1 : a.updated_at > b.updated_at ? 1 : a.id < b.id ? -1 : a.id > b.id ? 1 : 0));
  } else if (order === 'updated_at.desc') {
    out.sort((a, b) => (a.updated_at < b.updated_at ? 1 : -1));
  }
  if (p.has('limit')) out = out.slice(0, Number(p.get('limit')));
  const select = p.get('select');
  if (select === 'updated_at') return out.map((r) => ({ updated_at: r.updated_at }));
  if (select === 'businessName:data->>businessName') return out.map((r) => ({ businessName: r.data.businessName }));
  if (select === 'id,updated_at,deleted,data') return out.map((r) => ({ id: r.id, updated_at: r.updated_at, deleted: r.deleted, data: r.data }));
  throw new Error(`unexpected select ${select}`);
}

let db;
let calls;
let failReads;
function install({ authorizeStatus = 200 } = {}) {
  db = seed();
  calls = [];
  failReads = false;
  global.fetch = jest.fn(async (input, init = {}) => {
    const url = new URL(String(input));
    const method = init.method || 'GET';
    calls.push({ url: String(input), method, body: init.body || '' });
    const path = url.pathname;
    if (path === '/rest/v1/rpc/api_key_authorize') {
      if (authorizeStatus !== 200) return jsonRes({ message: 'not found' }, authorizeStatus);
      const { p_key_hash } = JSON.parse(init.body);
      return jsonRes(KEYS_BY_HASH[p_key_hash] || { ok: false, error: 'invalid_key' });
    }
    if (path === '/rest/v1/api_access_log') return jsonRes(null, 201);
    const table = path.replace('/rest/v1/', '');
    if (BUSINESS_TABLES.includes(table)) {
      if (method !== 'GET') return jsonRes({ message: 'WRITE ATTEMPT' }, 500);
      if (failReads) return jsonRes({ message: 'db down' }, 500);
      return jsonRes(applyQuery(table, db[table], url));
    }
    throw new Error(`unexpected fetch ${input}`);
  });
}

let consoleCalls;
beforeEach(() => {
  install();
  consoleCalls = [];
  for (const level of ['log', 'info', 'warn', 'error', 'debug']) {
    jest.spyOn(console, level).mockImplementation((...args) => consoleCalls.push(args.map(String).join(' ')));
  }
});
afterEach(() => {
  delete global.fetch;
  jest.restoreAllMocks();
});

let guard;
beforeEach(() => { guard = createApiGuard(); });

const NOW = Date.parse('2026-10-03T18:00:00Z');
async function api(path, { key = KEY, method = 'GET', ip = '203.0.113.9', headers = {}, nowMs = NOW, authorization } = {}) {
  const res = await handleV1(
    {
      method,
      url: `${BASE}${path}`,
      authorization: authorization !== undefined ? authorization : key === null ? undefined : `Bearer ${key}`,
      ip,
      ...headers,
    },
    ENV,
    { nowMs, guard }
  );
  return res;
}

const supabaseReads = () => calls.filter((c) => c.method === 'GET' && c.url.startsWith('https://supa.test/rest/v1/'));
const logRows = () => calls.filter((c) => c.url === 'https://supa.test/rest/v1/api_access_log').map((c) => JSON.parse(c.body));

function assertSecurityInvariants() {
  for (const c of calls) {
    const table = new URL(c.url).pathname.replace('/rest/v1/', '');
    if (BUSINESS_TABLES.includes(table)) {
      expect(c.method).toBe('GET');
      expect(new URL(c.url).searchParams.getAll('user_id')).toEqual([`eq.${OWNER}`]);
    } else {
      expect(['rpc/api_key_authorize', 'api_access_log']).toContain(table);
      expect(c.method).toBe('POST');
    }
    for (const k of ALL_KEYS) {
      expect(c.url).not.toContain(k);
      expect(c.body).not.toContain(k);
    }
  }
  for (const line of consoleCalls) for (const k of ALL_KEYS) expect(line).not.toContain(k);
}
afterEach(() => assertSecurityInvariants());

// ── tests ────────────────────────────────────────────────────────────────

describe('read-only by construction', () => {
  const paths = ['/v1', '/v1/openapi.json', '/v1/account', '/v1/customers', '/v1/customers/c1', '/v1/invoices', '/v1/payments/p1', '/v1/nope'];
  test.each(['POST', 'PUT', 'PATCH', 'DELETE', 'HEAD', 'OPTIONS'])('%s on every /v1 path is 405 with Allow: GET, before any I/O', async (method) => {
    for (const path of paths) {
      const res = await api(path, { method });
      expect(res.status).toBe(405);
      expect(res.headers.Allow).toBe('GET');
      expect(res.body).toEqual({ error: { code: 'method_not_allowed', message: expect.any(String) } });
    }
    expect(calls).toHaveLength(0);
  });

  test('a full sweep of every read touches business tables with GET only', async () => {
    for (const r of ['customers', 'jobs', 'estimates', 'invoices', 'payments', 'expenses', 'mileage']) {
      expect((await api(`/v1/${r}`)).status).toBe(200);
      expect((await api(`/v1/${r}?updated_since=2026-10-01T00:00:00Z&limit=2`)).status).toBe(200);
    }
    for (const p of ['/v1/customers/c1', '/v1/jobs/j1', '/v1/estimates/j2', '/v1/invoices/inv1', '/v1/payments/p2', '/v1/payments/legacy_inv3', '/v1/expenses/e1', '/v1/mileage/t1', '/v1/account']) {
      expect((await api(p)).status).toBe(200);
    }
    const nonGet = calls.filter((c) => c.method !== 'GET').map((c) => new URL(c.url).pathname);
    expect([...new Set(nonGet)].sort()).toEqual(['/rest/v1/api_access_log', '/rest/v1/rpc/api_key_authorize']);
  });
});

describe('tenant isolation', () => {
  test("every Supabase read carries the resolved owner's user_id, and another tenant's ids are 404", async () => {
    await api('/v1/customers');
    await api('/v1/jobs/jx');
    await api('/v1/invoices/invx');
    const res = await api('/v1/customers/x1');
    expect(res.status).toBe(404);
    expect(res.body.error.code).toBe('not_found');
    expect(supabaseReads().length).toBeGreaterThan(4);
    for (const c of supabaseReads()) expect(new URL(c.url).searchParams.getAll('user_id')).toEqual([`eq.${OWNER}`]);
    const list = await api('/v1/customers');
    expect(JSON.stringify(list.body)).not.toContain('Someone else');
  });

  test('a payment id shared with another tenant resolves only inside the owner', async () => {
    const res = await api('/v1/payments/p1');
    expect(res.status).toBe(200);
    expect(res.body.data.invoiceId).toBe('inv1');
  });

  test('a deleted record, a missing record and another tenant\'s record are the same 404', async () => {
    const bodies = [];
    for (const id of ['c-dead', 'nope', 'x1']) {
      const res = await api(`/v1/customers/${id}`);
      expect(res.status).toBe(404);
      bodies.push(res.body);
    }
    expect(bodies[0]).toEqual(bodies[1]);
    expect(bodies[1]).toEqual(bodies[2]);
  });
});

describe('field allowlists on the wire', () => {
  test('list and single responses carry exactly the public fields; internal values never appear', async () => {
    const all = [];
    for (const [r, f] of [['customers', 'customers'], ['jobs', 'jobs'], ['estimates', 'estimates'], ['invoices', 'invoices'], ['payments', 'payments'], ['expenses', 'expenses'], ['mileage', 'mileage']]) {
      const res = await api(`/v1/${r}`);
      for (const item of res.body.data) expect(Object.keys(item)).toEqual([...FIELDS[f]]);
      all.push(res.body);
    }
    const acct = await api('/v1/account');
    all.push(acct.body);
    const wire = JSON.stringify(all);
    for (const secret of ['INTERNAL-NOTE', 'APPROVAL-TOKEN', '198.51.100.77', 'PRIVATE-EMAIL', 'file:///', '987.65', 'sk-ant-SETTINGS-SECRET', 'PUSH', 'OTHER-TENANT']) {
      expect(wire).not.toContain(secret);
    }
  });

  test('the settings read selects businessName only — the blob with vendor keys never leaves Postgres', async () => {
    const res = await api('/v1/account');
    expect(res.status).toBe(200);
    expect(res.body.data.businessName).toBe('Ruiz Electric');
    const settingsReads = supabaseReads().filter((c) => c.url.includes('/rest/v1/settings'));
    expect(settingsReads).toHaveLength(1);
    expect(new URL(settingsReads[0].url).searchParams.get('select')).toBe('businessName:data->>businessName');
    expect(res.body.data.key).toEqual({ id: KEY_ID, name: 'Books', prefix: KEY.slice(0, 12), scopes: ALL_SCOPES, expiresAt: '2027-10-03T00:00:00.000Z' });
    expect(res.body.data.dataAsOf).toBe('2026-10-03T10:40:00.000Z');
  });
});

describe('keys and scopes', () => {
  test('a key without the resource scope is 403 insufficient_scope, logged as denied', async () => {
    const res = await api('/v1/invoices', { key: KEY_JOBS_ONLY });
    expect(res.status).toBe(403);
    expect(res.body.error.code).toBe('insufficient_scope');
    expect(supabaseReads()).toHaveLength(0);
    expect(logRows()).toEqual([{ user_id: OWNER, key_id: KEY_ID_JOBS, event: 'denied', route: '/v1/invoices', status: 403, ip: '203.0.113.9' }]);
    expect((await api('/v1/estimates', { key: KEY_JOBS_ONLY })).status).toBe(200);
    expect((await api('/v1/account', { key: KEY_JOBS_ONLY })).status).toBe(200);
  });

  test('account dataAsOf only reflects tables the key may read', async () => {
    await api('/v1/account', { key: KEY_JOBS_ONLY });
    const tables = supabaseReads().map((c) => new URL(c.url).pathname.replace('/rest/v1/', '')).sort();
    expect(tables).toEqual(['jobs', 'settings']);
  });

  test.each([
    [KEY_REVOKED, 'key_revoked'],
    [KEY_EXPIRED, 'key_expired'],
    [KEY_UNKNOWN, 'invalid_key'],
  ])('a dead key is 401 (%#) and the Worker reads nothing; the RPC logs the denial', async (key, code) => {
    const res = await api('/v1/customers', { key });
    expect(res.status).toBe(401);
    expect(res.body.error.code).toBe(code);
    expect(res.headers['WWW-Authenticate']).toMatch(/^Bearer/);
    expect(supabaseReads()).toHaveLength(0);
    expect(logRows()).toHaveLength(0);
    const rpc = calls.find((c) => c.url.endsWith('/rpc/api_key_authorize'));
    expect(JSON.parse(rpc.body)).toEqual({ p_key_hash: sha(key), p_route: '/v1/customers', p_ip: '203.0.113.9' });
  });

  test('missing, malformed, untagged or forged bearer is 401 invalid_key with no database contact', async () => {
    const bytes = Buffer.from(KEY.slice(4), 'base64url');
    const flipped = Buffer.from(bytes);
    flipped[79] ^= 1;
    for (const key of [null, 'trk_short', 'sk_live_whatever', `trk_${'A'.repeat(43)}`, `trk_${'A'.repeat(107)}`,
      forgedFrom('x'), forgedFrom('y', bytes.subarray(0, 32)), `trk_${flipped.toString('base64url')}`,
      mint({ keyId: KEY_ID, seed: 'A', secret: 'some-other-secret-0123456789abcdef' })]) {
      const res = await api('/v1/customers', { key });
      expect(res.status).toBe(401);
      expect(res.body.error.code).toBe('invalid_key');
    }
    expect(calls).toHaveLength(0);
  });

  test('a key in the query string is refused before anything else', async () => {
    for (const q of [`?api_key=${KEY}`, `?token=x`, `?limit=5&cursor=${KEY}`]) {
      const res = await api(`/v1/customers${q}`, { key: null });
      expect(res.status).toBe(400);
      expect(res.body.error.code).toBe('key_in_query');
    }
    expect(calls).toHaveLength(0);
  });

  test('past 20 malformed or keyless requests that address gets 429; the RPC sees no junk', async () => {
    for (let i = 0; i < 20; i++) expect((await api('/v1/customers', { key: null, ip: '198.51.100.5' })).status).toBe(401);
    const rpcBefore = calls.length;
    const blocked = await api('/v1/customers', { key: 'trk_short', ip: '198.51.100.5' });
    expect(blocked.status).toBe(429);
    expect(blocked.headers['Retry-After']).toBe('60');
    expect((await api('/v1/customers', { key: null, ip: '198.51.100.5' })).status).toBe(429);
    expect(calls.length).toBe(rpcBefore);
    expect((await api('/v1/customers', { key: null, ip: '198.51.100.6' })).status).toBe(401);
  });

  test('a well-formed key is never rejected by the junk counter (shared egress address)', async () => {
    // Junk from the shared address, including the cheap ?token=x trick.
    for (let i = 0; i < 15; i++) await api('/v1/customers', { key: null, ip: '198.51.100.5' });
    for (let i = 0; i < 15; i++) await api('/v1/customers?token=x', { key: null, ip: '198.51.100.5' });
    expect((await api('/v1/customers', { key: 'trk_short', ip: '198.51.100.5' })).status).toBe(429);
    expect((await api('/v1/customers', { key: null, ip: '198.51.100.5' })).status).toBe(429);
    // Other owners' valid keys on the same address still go to the RPC and are served.
    for (const key of [KEY, KEY_JOBS_ONLY]) {
      const rpcBefore = calls.filter((c) => c.url.endsWith('/rpc/api_key_authorize')).length;
      const res = await api('/v1/jobs', { key, ip: '198.51.100.5' });
      expect(res.status).toBe(200);
      expect(calls.filter((c) => c.url.endsWith('/rpc/api_key_authorize')).length).toBe(rpcBefore + 1);
    }
    // And a valid key keeps working while the junk 429 is still in force.
    expect((await api('/v1/customers', { key: KEY, ip: '198.51.100.5', nowMs: NOW + 30_000 })).status).toBe(200);
  });

  test('a tag-valid unknown key is answered 401 from memory after its first RPC, for its life', async () => {
    const rpcCount = () => calls.filter((c) => c.url.endsWith('/rpc/api_key_authorize')).length;
    for (let i = 0; i < 12; i++) {
      const res = await api('/v1/customers', { key: KEY_UNKNOWN, ip: '198.51.100.7' });
      expect(res.status).toBe(401);
      expect(res.body.error.code).toBe('invalid_key');
      expect(res.headers['WWW-Authenticate']).toMatch(/^Bearer/);
    }
    expect(rpcCount()).toBe(1);
    // A different unknown hash is judged on its own, and valid keys are untouched.
    expect((await api('/v1/customers', { key: mkKey('V'), ip: '198.51.100.7' })).status).toBe(401);
    expect(rpcCount()).toBe(2);
    expect((await api('/v1/customers', { key: KEY, ip: '198.51.100.7' })).status).toBe(200);
    expect(rpcCount()).toBe(3);
    // Round 6: an unknown tag-valid key is final (its row was deleted with
    // its account, or never committed), so it is never looked up again (it
    // was after 60 s before).
    await api('/v1/customers', { key: KEY_UNKNOWN, ip: '198.51.100.7', nowMs: NOW + 59_999 });
    expect(rpcCount()).toBe(3);
    await api('/v1/customers', { key: KEY_UNKNOWN, ip: '198.51.100.7', nowMs: NOW + 400 * 86_400_000 });
    expect(rpcCount()).toBe(3);
  });

  describe('distinct tag-valid unknown keys from one address (resource-cap defeat)', () => {
    // Since 2026-10-12 a random key is refused before the guard (see the
    // forged-key tests); what reaches the token buckets is a tag-valid key
    // the database does not know, which needs the tag secret or a deleted
    // account's keys. Each such key here has its own owner, so the owner
    // bucket is not what binds; valid keys belong to OWNER.
    const rpcCount = () => calls.filter((c) => c.url.endsWith('/rpc/api_key_authorize')).length;
    const IP = '198.51.100.20';
    const fresh = (tag, i) => mint({ keyId: uuidOf(`${tag}${i}`), ownerId: uuidOf(`owner-${tag}${i}`), seed: `${tag}${i}` });
    const freshValid = (tag, i) => mint({ keyId: uuidOf(`${tag}${i}`), seed: `${tag}${i}` });
    const addValid = (key) => { KEYS_BY_HASH[sha(key)] = live(key); };
    afterEach(() => { for (const k of Object.keys(KEYS_BY_HASH)) if (!ALL_KEYS.some((a) => sha(a) === k)) delete KEYS_BY_HASH[k]; });

    test('500 distinct unknown keys from one IP cost exactly 10 RPCs (the client bucket); known and other-IP keys still work', async () => {
      // KEY authorizes first, so it is in the positive cache (and its tokens came back).
      expect((await api('/v1/customers', { key: KEY, ip: IP })).status).toBe(200);
      expect(rpcCount()).toBe(1);
      let shed = 0;
      for (let i = 0; i < 500; i++) {
        const res = await api('/v1/customers', { key: fresh('junk', i), ip: IP });
        if (res.status === 429) { shed++; expect(res.headers['Retry-After']).toBe('60'); } else expect(res.status).toBe(401);
      }
      expect(rpcCount()).toBe(1 + 10);
      expect(shed).toBe(490);
      // During the flood a previously authorized key from the same IP still succeeds (and is checked by the RPC).
      const before = rpcCount();
      expect((await api('/v1/customers', { key: KEY, ip: IP })).status).toBe(200);
      expect(rpcCount()).toBe(before + 1);
      // The attacker's churn did not evict the positive-cache entry.
      expect(guard.sizes().knownKeys).toBe(1);
      // Another IP has its own bucket (the isolate bucket has 50 left).
      expect((await api('/v1/customers', { key: fresh('other', 0), ip: '198.51.100.21' })).status).toBe(401);
      expect((await api('/v1/jobs', { key: KEY_JOBS_ONLY, ip: '198.51.100.21' })).status).toBe(200);
    });

    test('never-seen valid keys get their tokens back; unknown keys keep theirs', async () => {
      const keys = Array.from({ length: 12 }, (_, i) => freshValid('valid', i));
      keys.forEach(addValid);
      for (const key of keys) expect((await api('/v1/customers', { key, ip: IP })).status).toBe(200);
      expect(rpcCount()).toBe(12); // 12 > 10: every one was refunded
      // Unknown keys spend the client bucket (10 per window) ...
      for (let i = 0; i < 10; i++) expect((await api('/v1/customers', { key: fresh('junk', i), ip: IP })).status).toBe(401);
      expect((await api('/v1/customers', { key: fresh('junk', 10), ip: IP })).status).toBe(429);
      // ... and with it spent, a never-seen valid key waits for the next window (the accepted residual) ...
      const late = freshValid('late', 0);
      addValid(late);
      expect((await api('/v1/customers', { key: late, ip: IP })).status).toBe(429);
      // ... while keys the isolate already knows are unaffected. (keys[11]: since
      // round 6 an owner keeps at most 10 positive-cache entries, its 10
      // working keys, so these 12 same-owner keys leave keys[0..1] cold.)
      expect((await api('/v1/customers', { key: keys[11], ip: IP })).status).toBe(200);
      expect((await api('/v1/customers', { key: late, ip: IP, nowMs: NOW + 60_000 })).status).toBe(200);
    });

    test('a key that authorized 30 minutes ago still passes during a flood (60-minute positive cache)', async () => {
      expect((await api('/v1/customers', { key: KEY, ip: IP, nowMs: NOW })).status).toBe(200);
      const later = NOW + 30 * 60_000;
      for (let i = 0; i < 100; i++) await api('/v1/customers', { key: fresh('junk', i), ip: IP, nowMs: later });
      expect(rpcCount()).toBe(1 + 10);
      const before = rpcCount();
      expect((await api('/v1/customers', { key: KEY, ip: IP, nowMs: later })).status).toBe(200);
      expect(rpcCount()).toBe(before + 1); // still checked by the RPC
      // Each success refreshes the 60-minute TTL; once it lapses the key is an ordinary never-seen key again.
      expect(guard.isKnownKey(sha(KEY), later + 59 * 60_000)).toBe(true);
      expect(guard.isKnownKey(sha(KEY), later + 61 * 60_000)).toBe(false);
    });

    test('a token 429 carries Retry-After to the window end and never outlasts it', async () => {
      for (let i = 0; i < 10; i++) expect((await api('/v1/customers', { key: fresh('junk', i), ip: IP })).status).toBe(401);
      const t = NOW + 30_000;
      for (let i = 10; i < 30; i++) {
        const res = await api('/v1/customers', { key: fresh('junk', i), ip: IP, nowMs: t });
        expect(res.status).toBe(429);
        expect(res.headers['Retry-After']).toBe('30');
      }
      // Keyless requests are judged by the junk counter only.
      expect((await api('/v1/customers', { key: null, ip: IP, nowMs: t })).status).toBe(401);
      // One window after the first token the bucket is full again, whatever was sent meanwhile.
      expect((await api('/v1/customers', { key: fresh('junk', 99), ip: IP, nowMs: NOW + 60_000 })).status).toBe(401);
    });

    test('the positive cache never skips the RPC: a revoked key is refused, forgotten and negative-cached', async () => {
      const key = freshValid('flip', 0);
      addValid(key);
      expect((await api('/v1/customers', { key, ip: IP })).status).toBe(200);
      const before = rpcCount();
      expect((await api('/v1/customers', { key, ip: IP })).status).toBe(200);
      expect(rpcCount()).toBe(before + 1);
      KEYS_BY_HASH[sha(key)] = { ok: false, error: 'key_revoked' };
      const res = await api('/v1/customers', { key, ip: IP });
      expect(res.status).toBe(401);
      expect(res.body.error.code).toBe('key_revoked');
      expect(rpcCount()).toBe(before + 2);
      expect(guard.isKnownKey(sha(key), NOW)).toBe(false);
      const again = await api('/v1/customers', { key, ip: IP });
      expect(again.body.error.code).toBe('key_revoked');
      expect(rpcCount()).toBe(before + 2); // from memory
    });
  });

  test('revoked and expired keys are negative-cached on the first denial, with their own code, for the key\'s life', async () => {
    // Changed 2026-10-12 (§14.4a #5): both denials are one-way, so the entry
    // no longer lapses after 60 s (it was one more RPC per minute before).
    const rpcCount = () => calls.filter((c) => c.url.endsWith('/rpc/api_key_authorize')).length;
    for (let i = 0; i < 8; i++) {
      expect((await api('/v1/customers', { key: KEY_REVOKED })).body.error.code).toBe('key_revoked');
      expect((await api('/v1/customers', { key: KEY_EXPIRED })).body.error.code).toBe('key_expired');
    }
    expect(rpcCount()).toBe(2);
    expect((await api('/v1/customers', { key: KEY_REVOKED, nowMs: NOW + 60_000 })).body.error.code).toBe('key_revoked');
    expect((await api('/v1/customers', { key: KEY_EXPIRED, nowMs: NOW + 400 * 86_400_000 })).body.error.code).toBe('key_expired');
    expect(rpcCount()).toBe(2);
  });
});

describe('rate limits and failure modes', () => {
  test('429 carries Retry-After and the rate headers; nothing is read', async () => {
    const res = await api('/v1/customers', { key: KEY_LIMITED });
    expect(res.status).toBe(429);
    expect(res.body.error.code).toBe('rate_limited');
    expect(res.headers['Retry-After']).toBe('17');
    expect(res.headers['X-RateLimit-Limit']).toBe('60');
    expect(res.headers['X-RateLimit-Remaining']).toBe('0');
    expect(res.headers['X-RateLimit-Reset']).toBe('1791040017');
    expect(supabaseReads()).toHaveLength(0);
  });

  test('a rate-limited key is shed from memory until its reset: no RPC, same headers, counting down', async () => {
    const rpcCount = () => calls.filter((c) => c.url.endsWith('/rpc/api_key_authorize')).length;
    const first = await api('/v1/customers', { key: KEY_LIMITED });
    expect(first.status).toBe(429);
    expect(rpcCount()).toBe(1);
    for (let i = 0; i < 25; i++) {
      const res = await api('/v1/customers', { key: KEY_LIMITED, nowMs: NOW + 5_000 });
      expect(res.status).toBe(429);
      expect(res.body.error.code).toBe('rate_limited');
      expect(res.headers['Retry-After']).toBe('12');
      expect(res.headers['X-RateLimit-Limit']).toBe('60');
      expect(res.headers['X-RateLimit-Remaining']).toBe('0');
      expect(res.headers['X-RateLimit-Reset']).toBe('1791040017');
    }
    expect(rpcCount()).toBe(1);
    expect(supabaseReads()).toHaveLength(0);
    // Other keys, even on the same address, are not shed.
    expect((await api('/v1/customers', { key: KEY })).status).toBe(200);
    // After the reset the RPC is asked again.
    await api('/v1/customers', { key: KEY_LIMITED, nowMs: NOW + 17_000 });
    expect(rpcCount()).toBe(3);
  });

  test('every authenticated response carries version, no-store and rate headers', async () => {
    const res = await api('/v1/customers');
    expect(res.headers).toEqual(expect.objectContaining({
      'TradeReady-Api-Version': '2026-10-03',
      'Cache-Control': 'no-store',
      'X-RateLimit-Limit': '60',
      'X-RateLimit-Remaining': '41',
      'X-RateLimit-Reset': '1791040000',
    }));
    const err = await api('/v1/customers?bogus=1');
    expect(err.headers['TradeReady-Api-Version']).toBe('2026-10-03');
    expect(err.headers['X-RateLimit-Remaining']).toBe('41');
  });

  test('authorize RPC not deployed (404) → 503 unavailable, fail closed', async () => {
    install({ authorizeStatus: 404 });
    const res = await api('/v1/customers');
    expect(res.status).toBe(503);
    expect(res.body.error.code).toBe('unavailable');
    expect(supabaseReads()).toHaveLength(0);
  });

  test('authorize RPC erroring → 503; a data read failing → 500 with no internals, logged as error', async () => {
    install({ authorizeStatus: 500 });
    expect((await api('/v1/customers')).status).toBe(503);
    install();
    failReads = true;
    const res = await api('/v1/customers');
    expect(res.status).toBe(500);
    expect(res.body).toEqual({ error: { code: 'server_error', message: expect.any(String) } });
    expect(JSON.stringify(res.body)).not.toMatch(/supa|db down|rest\/v1/);
    expect(logRows().map((r) => [r.event, r.status])).toEqual([['error', 500]]);
  });

  test('a missing API_CURSOR_SECRET makes lists 503 (never unsigned cursors)', async () => {
    const res = await handleV1({ method: 'GET', url: `${BASE}/v1/customers`, authorization: `Bearer ${KEY}`, ip: null },
      { ...ENV, API_CURSOR_SECRET: '' }, { nowMs: Date.now(), guard });
    expect(res.status).toBe(503);
  });

  test('unknown and malformed parameters are 400 naming the parameter, logged as error', async () => {
    const res = await api('/v1/customers?limt=5');
    expect(res.status).toBe(400);
    expect(res.body.error).toEqual({ code: 'invalid_parameter', message: 'Unknown query parameter "limt".' });
    expect((await api('/v1/customers/c1?limit=5')).status).toBe(400);
    expect((await api('/v1/customers?limit=500')).status).toBe(400);
    expect((await api('/v1/customers?updated_since=yesterday')).status).toBe(400);
    expect(supabaseReads()).toHaveLength(0);
    expect(logRows().every((r) => r.event === 'error' && r.status === 400)).toBe(true);
  });

  test('every logged route is a template — no ids, no query values', async () => {
    await api('/v1/customers/c1?');
    await api('/v1/invoices?limit=2&updated_since=2026-10-01T00:00:00Z');
    await api('/v1/payments/p2');
    expect(logRows().map((r) => r.route)).toEqual(['/v1/customers/:id', '/v1/invoices', '/v1/payments/:id']);
    expect(logRows().every((r) => r.ip === '203.0.113.9' && r.key_id === KEY_ID)).toBe(true);
  });
});

describe('pagination and incremental sync (§5)', () => {
  test('keyset pages of 3 walk every live customer exactly once, tie-broken by id', async () => {
    const seen = [];
    let cursor = null;
    let pages = 0;
    do {
      const res = await api(`/v1/customers?limit=3${cursor ? `&cursor=${encodeURIComponent(cursor)}` : ''}`);
      expect(res.status).toBe(200);
      expect(res.body.data.length).toBeLessThanOrEqual(3);
      seen.push(...res.body.data.map((c) => c.id));
      cursor = res.body.nextCursor;
      pages += 1;
      const q = new URL(supabaseReads().filter((c) => c.url.includes('select=id')).pop().url).searchParams;
      expect(q.get('limit')).toBe('4');
      expect(q.get('order')).toBe('updated_at.asc,id.asc');
    } while (cursor);
    expect(seen).toEqual(['c1', 'c2', 'c3', 'c4', 'c5', 'c6', 'c7', 'c8a', 'c8b']);
    expect(pages).toBe(3);
  });

  test('the last page has nextCursor null; nextUpdatedSince is the last row minus 5 s', async () => {
    const res = await api('/v1/customers?limit=100');
    expect(res.body.nextCursor).toBeNull();
    expect(res.body.nextUpdatedSince).toBe('2026-10-03T10:19:55.000Z');
    expect(res.body.dataAsOf).toBe('2026-10-03T10:30:00.000Z');
  });

  test('a cursor is bound to its resource and tamper-evident', async () => {
    const first = await api('/v1/customers?limit=2');
    const c = first.body.nextCursor;
    expect((await api(`/v1/jobs?cursor=${encodeURIComponent(c)}`)).body.error.code).toBe('invalid_cursor');
    const tampered = `${c.slice(0, -3)}abc`;
    expect((await api(`/v1/customers?cursor=${encodeURIComponent(tampered)}`)).body.error.code).toBe('invalid_cursor');
  });

  test('without updated_since deleted rows are excluded; with it they come back as tombstones', async () => {
    const plain = await api('/v1/customers?limit=100');
    expect(plain.body.data.map((c) => c.id)).not.toContain('c-dead');
    const sync = await api('/v1/customers?updated_since=2026-10-03T10:19:00Z');
    expect(sync.body.data).toEqual([
      expect.objectContaining({ id: 'c8a' }),
      expect.objectContaining({ id: 'c8b' }),
      { id: 'c-dead', deleted: true, updatedAt: '2026-10-03T10:30:00.000Z' },
    ]);
    const pay = await api('/v1/payments?updated_since=2026-10-03T10:30:00Z');
    expect(pay.body.data).toEqual([{ id: 'p-dead', deleted: true, updatedAt: '2026-10-03T10:40:00.000Z' }]);
  });

  test('an empty sync returns nulls, so the consumer keeps its watermark', async () => {
    const res = await api('/v1/mileage?updated_since=2026-10-04T00:00:00Z');
    expect(res.body).toEqual({ data: [], nextCursor: null, dataAsOf: '2026-10-03T10:01:00.000Z', nextUpdatedSince: null });
  });
});

describe('derived resources', () => {
  test('payments are flattened per invoice page; a legacy paid invoice yields its legacy_ entry', async () => {
    const res = await api('/v1/payments?limit=2');
    expect(res.body.data.map((p) => p.id)).toEqual(['p1', 'p2']);
    expect(res.body.nextCursor).not.toBeNull();
    const next = await api(`/v1/payments?limit=2&cursor=${encodeURIComponent(res.body.nextCursor)}`);
    expect(next.body.data.map((p) => p.id)).toEqual(['legacy_inv3']);
    const legacy = await api('/v1/payments/legacy_inv3');
    expect(legacy.body.data).toEqual(expect.objectContaining({ id: 'legacy_inv3', source: 'legacy', amount: 40, invoiceId: 'inv3' }));
    expect((await api('/v1/payments/legacy_inv2')).status).toBe(404);
  });

  test('estimates are jobs with an approval link or a sent stamp; others are 404 as estimates', async () => {
    const res = await api('/v1/estimates');
    expect(res.body.data.map((e) => [e.id, e.status])).toEqual([['j2', 'sent'], ['j3', 'sent']]);
    const listQuery = new URL(supabaseReads().find((c) => c.url.includes('select=id')).url).searchParams;
    expect(listQuery.get('and')).toContain('or(data->approval.not.is.null,data->>estimateSentAt.not.is.null)');
    expect((await api('/v1/estimates/j1')).status).toBe(404);
    expect((await api('/v1/jobs/j1')).status).toBe(200);
  });

  test('invoices embed the same payment objects as /v1/payments', async () => {
    const inv = await api('/v1/invoices/inv1');
    const pay = await api('/v1/payments/p2');
    expect(inv.body.data.payments[1]).toEqual(pay.body.data);
    expect(inv.body.data).toEqual(expect.objectContaining({ amountPaid: 150, balanceDue: 150, status: 'partly_paid', paymentLinkUrl: null }));
  });
});

describe('the Hono route shell', () => {
  function fakeC({ method = 'GET', path = '/v1/customers', headers = {} } = {}) {
    const lower = Object.fromEntries(Object.entries(headers).map(([k, v]) => [k.toLowerCase(), v]));
    const set = {};
    return {
      set,
      env: ENV,
      header: (k, v) => { set[k] = v; },
      req: { method, url: `${BASE}${path}`, header: (k) => lower[String(k).toLowerCase()] },
      json: (body, status) => ({ status, body, headers: { ...set } }),
    };
  }

  test('no CORS headers on any response, even with an Origin', async () => {
    const outs = [
      await apiV1Handler(fakeC({ headers: { authorization: `Bearer ${KEY}`, origin: 'https://gettradereadyapp.com', 'cf-connecting-ip': '203.0.113.1' } })),
      await apiV1Handler(fakeC({ method: 'OPTIONS', headers: { origin: 'https://evil.example' } })),
      await apiV1Handler(fakeC({ headers: { origin: 'https://evil.example' } })),
    ];
    expect(outs.map((o) => o.status)).toEqual([200, 405, 401]);
    for (const o of outs) {
      for (const name of Object.keys(o.headers)) expect(name.toLowerCase()).not.toMatch(/^access-control-/);
    }
  });

  test('logs cf-connecting-ip only — a spoofed x-forwarded-for is ignored', async () => {
    await apiV1Handler(fakeC({ headers: { authorization: `Bearer ${KEY}`, 'x-forwarded-for': '6.6.6.6', 'cf-connecting-ip': '203.0.113.44' } }));
    await apiV1Handler(fakeC({ headers: { authorization: `Bearer ${KEY}`, 'x-forwarded-for': '6.6.6.6' } }));
    expect(logRows().map((r) => r.ip)).toEqual(['203.0.113.44', null]);
    const rpcIps = calls.filter((c) => c.url.endsWith('/rpc/api_key_authorize')).map((c) => JSON.parse(c.body).p_ip);
    expect(rpcIps).toEqual(['203.0.113.44', null]);
  });

  test('openapi.json is public and cacheable', async () => {
    const out = await apiV1Handler(fakeC({ path: '/v1/openapi.json' }));
    expect(out.status).toBe(200);
    expect(out.body.openapi).toBe('3.1.0');
    expect(out.headers['Cache-Control']).toBe('public, max-age=3600');
    expect(calls).toHaveLength(0);
  });
});

describe('in-memory guards stay bounded and hold hashes only', () => {
  test('every map is capped (oldest evicted) and keys are hashes, never the presented key', () => {
    const cap = 50;
    const g = createApiGuard({ MAX_CLIENTS: cap, MAX_JUNK_CLIENTS: cap, MAX_DENIED_KEYS: cap, MAX_LIMITED_KEYS: cap, MAX_KNOWN_KEYS: cap, GLOBAL_TOKENS: 10_000 });
    for (let i = 0; i < 500; i++) {
      for (let f = 0; f < 21; f++) g.junkRequest(`ip-${i}`, NOW + i);
      g.takeTokens(`ip-${i}`, NOW + i);
      g.deniedKey(sha(`k${i}`), 'invalid_key', NOW + i);
      g.rateLimitedKey(sha(`l${i}`), { retryAfter: 600, rate: { limit: 60, remaining: 0, reset: 1 } }, NOW + i);
      g.knownKey(sha(`g${i}`), NOW + i);
    }
    expect(g.sizes()).toMatchObject({ clients: cap, junk: cap, deniedKeys: cap, limitedKeys: cap, knownKeys: cap });
    // The newest entries survive; the oldest were evicted.
    expect(g.junkRequest('ip-499', NOW + 500)).toBeGreaterThan(0);
    expect(g.junkRequest('ip-0', NOW + 500)).toBe(0);
    expect(g.keyShed(sha('k499'), NOW + 500)).toEqual({ error: 'invalid_key' });
    expect(g.keyShed(sha('k0'), NOW + 500)).toBeNull();
    expect(g.keyShed(sha('l499'), NOW + 500).error).toBe('rate_limited');
    expect(g.keyShed(sha('l0'), NOW + 500)).toBeNull();
    expect(g.isKnownKey(sha('g499'), NOW + 500)).toBe(true);
    expect(g.isKnownKey(sha('g0'), NOW + 500)).toBe(false);
    // A raw key is refused by the per-hash maps, so it can never be remembered.
    const before = g.sizes();
    g.deniedKey(KEY_UNKNOWN, 'invalid_key', NOW);
    g.rateLimitedKey(KEY_UNKNOWN, { retryAfter: 60 }, NOW);
    g.knownKey(KEY_UNKNOWN, NOW);
    expect(g.takeInFlight(KEY_UNKNOWN)).toBeNull();
    expect(g.keyShed(KEY_UNKNOWN, NOW)).toBeNull();
    expect(g.isKnownKey(KEY_UNKNOWN, NOW)).toBe(false);
    expect(g.sizes()).toEqual(before);
  });

  test('the default caps keep the maps bounded under a flood of distinct addresses and keys', async () => {
    for (let i = 0; i < 5000; i++) {
      const ip = `10.${(i >> 16) & 255}.${(i >> 8) & 255}.${i & 255}`;
      await api('/v1/customers', { key: null, ip });
      await api('/v1/customers', { key: mint({ keyId: uuidOf(`flood${i}`), ownerId: uuidOf(`flood-owner${i}`), seed: `flood${i}` }), ip, nowMs: NOW + i * 15 });
    }
    for (let i = 0; i < 12_000; i++) {
      guard.deniedKey(sha(`d${i}`), 'invalid_key', NOW);
      guard.rateLimitedKey(sha(`l${i}`), { retryAfter: 60 }, NOW);
      guard.knownKey(sha(`g${i}`), NOW);
    }
    const sizes = guard.sizes();
    expect(sizes.clients).toBeLessThanOrEqual(GUARD_LIMITS.MAX_CLIENTS);
    expect(sizes.owners).toBeLessThanOrEqual(GUARD_LIMITS.MAX_OWNERS);
    expect(sizes.junk).toBeLessThanOrEqual(GUARD_LIMITS.MAX_JUNK_CLIENTS);
    expect(sizes.deniedKeys).toBe(GUARD_LIMITS.MAX_DENIED_KEYS);
    expect(sizes.limitedKeys).toBe(GUARD_LIMITS.MAX_LIMITED_KEYS);
    expect(sizes.knownKeys).toBe(GUARD_LIMITS.MAX_KNOWN_KEYS);
    expect(sizes.inFlight).toBe(0);
  });

  test('churn in one map never evicts another: known keys and active rate-limit entries survive floods', () => {
    const g = createApiGuard({ MAX_CLIENTS: 100, MAX_JUNK_CLIENTS: 100, MAX_DENIED_KEYS: 100, MAX_KNOWN_KEYS: 20, GLOBAL_TOKENS: 10_000 });
    g.knownKey(sha('good'), NOW);
    g.rateLimitedKey(sha('limited'), { retryAfter: 600, rate: null }, NOW);
    for (let f = 0; f < 21; f++) g.junkRequest('ip-A', NOW);
    for (let i = 0; i < 5000; i++) {
      g.deniedKey(sha(`junk${i}`), 'invalid_key', NOW + i);
      g.takeTokens(`ip-${i}`, NOW + i);
    }
    expect(g.isKnownKey(sha('good'), NOW + 5000)).toBe(true);
    expect(g.keyShed(sha('limited'), NOW + 5000).error).toBe('rate_limited');
    expect(g.junkRequest('ip-A', NOW + 5000)).toBeGreaterThan(0); // token churn left the junk map alone
    // The positive cache is itself bounded (oldest evicted) and expires.
    for (let i = 0; i < 100; i++) g.knownKey(sha(`k${i}`), NOW + i);
    expect(g.sizes().knownKeys).toBe(20);
    expect(g.isKnownKey(sha('k99'), NOW + 100)).toBe(true);
    expect(g.isKnownKey(sha('k99'), NOW + 100 + 3_600_000)).toBe(false);
  });
});

describe('request guard bounds, measured with a fake RPC and a fake clock (§14.4a)', () => {
  // A fake authorize RPC that counts calls, tracks how many run at once and
  // can stall or fail. Data reads and log writes go to the fake PostgREST.
  let rpc;
  let mode;
  let gate;
  let rpcByIp;
  function fakeRpc() {
    const base = global.fetch;
    rpc = { calls: 0, inFlight: 0, peak: 0 };
    rpcByIp = new Map();
    mode = 'normal';
    gate = null;
    global.fetch = jest.fn(async (input, init = {}) => {
      if (!String(input).endsWith('/rpc/api_key_authorize')) return base(input, init);
      calls.push({ url: String(input), method: init.method || 'GET', body: init.body || '' });
      const { p_key_hash, p_ip } = JSON.parse(init.body);
      rpc.calls += 1;
      rpcByIp.set(p_ip, (rpcByIp.get(p_ip) || 0) + 1);
      rpc.inFlight += 1;
      rpc.peak = Math.max(rpc.peak, rpc.inFlight);
      try {
        await (gate || new Promise((r) => setImmediate(r)));
      } finally {
        rpc.inFlight -= 1;
      }
      if (mode === 'throw') throw new Error('connection reset');
      if (mode === '404') return jsonRes({ message: 'not found' }, 404);
      return jsonRes(KEYS_BY_HASH[p_key_hash] || { ok: false, error: 'invalid_key' });
    });
  }
  beforeEach(() => fakeRpc());
  afterEach(() => { for (const k of Object.keys(KEYS_BY_HASH)) if (!ALL_KEYS.some((a) => sha(a) === k)) delete KEYS_BY_HASH[k]; });

  let seq = 0;
  // A tag-valid key the database does not know (it needs the tag secret, or
  // a deleted account's key), each under its own owner so the per-owner
  // bucket is not what binds. These measure the token buckets; forged and
  // random keys never reach them (measured below).
  const unseenKey = () => { const n = seq++; return mint({ keyId: uuidOf(`k${n}`), ownerId: uuidOf(`o${n}`), seed: `random-${n}` }); };
  const validKey = () => { const n = seq++; const k = mint({ keyId: uuidOf(`k${n}`), seed: `valid-${n}` }); KEYS_BY_HASH[sha(k)] = live(k); return k; };
  const ipv4 = (i) => `10.${(i >> 16) & 255}.${(i >> 8) & 255}.${i & 255}`;
  const hit = (ip, key, nowMs = NOW) => api('/v1/customers', { key, ip, nowMs });
  // Requests now await the tag check before admission, so a test that holds
  // RPCs open waits for the requests to arrive rather than for one tick.
  async function until(cond) {
    for (let i = 0; i < 10_000 && !cond(); i++) await new Promise((r) => setImmediate(r));
    expect(cond()).toBe(true);
  }

  test.each([['throw'], ['404']])('outage (%s): one client causes at most 10 RPCs per window, many clients at most 60', async (m) => {
    mode = m;
    const statuses = new Map();
    for (let i = 0; i < 1000; i++) {
      const res = await hit('203.0.113.50', unseenKey(), NOW + i * 10); // 1,000 keys in 10 s
      statuses.set(res.status, (statuses.get(res.status) || 0) + 1);
    }
    expect(rpc.calls).toBe(10);
    expect(Object.fromEntries(statuses)).toEqual({ 503: 10, 429: 990 });
    // Next window, 5,000 clients: the isolate bucket (60) binds.
    rpc.calls = 0;
    for (let i = 0; i < 5000; i++) await hit(ipv4(i), unseenKey(), NOW + 60_000 + i);
    expect(rpc.calls).toBe(60);
  });

  test('three concurrent bursts of 1,000 distinct keys, 61 s apart: 300 RPCs per window, at most 10 per client', async () => {
    const perWindow = [];
    for (let b = 0; b < 3; b++) {
      rpc.calls = 0;
      rpcByIp.clear();
      const t = NOW + b * 61_000;
      // 1,000 keys from one client, then 1,000 from 100 clients (10 each).
      await Promise.all([
        ...Array.from({ length: 1000 }, () => hit('203.0.113.60', unseenKey(), t)),
        ...Array.from({ length: 1000 }, (_, i) => hit(ipv4(i % 100), unseenKey(), t)),
      ]);
      perWindow.push(rpc.calls);
      expect(Math.max(...rpcByIp.values())).toBe(10);
    }
    // Round 6: every key here has its own owner, so the reserve admits one
    // per owner after the shared pool: 60 + 240 per window (60 before).
    expect(perWindow).toEqual([300, 300, 300]);
    // One client alone, three concurrent bursts of 1,000 61 s apart: 10 per burst, 30 in all.
    rpc.calls = 0;
    const perBurst = [];
    for (let b = 0; b < 3; b++) {
      const before = rpc.calls;
      await Promise.all(Array.from({ length: 1000 }, () => hit('203.0.113.61', unseenKey(), NOW + (3 + b) * 61_000)));
      perBurst.push(rpc.calls - before);
    }
    expect(perBurst).toEqual([10, 10, 10]);
    expect(rpc.calls).toBe(30);
  });

  test('5,000 keys from distinct addresses in one IPv6 /64 are one client', async () => {
    for (let i = 0; i < 5000; i++) await hit(`2001:db8:1:2::${i.toString(16)}`, unseenKey(), NOW + i);
    expect(rpc.calls).toBe(10);
    expect(guard.sizes().clients).toBe(1);
    // The next /64 is another client.
    await hit('2001:db8:1:3::1', unseenKey(), NOW + 5001);
    expect(rpc.calls).toBe(11);
  });

  test('distinct IPv4 addresses are bounded by the isolate pools (shared 60 + reserve 240)', async () => {
    // Round 6: each unseen key here has its own owner, so after the shared
    // pool (60) each owner's first token comes from the reserve (240): 300 a
    // window (60 before round 6). It takes 300 owners with dead keys.
    for (let i = 0; i < 5000; i++) await hit(ipv4(i), unseenKey(), NOW + i);
    expect(rpc.calls).toBe(300);
    for (let i = 0; i < 5000; i++) await hit(ipv4(10_000 + i), unseenKey(), NOW + 60_000 + i);
    expect(rpc.calls).toBe(600);
  });

  test('junk-IP churn between rounds raises no bound', async () => {
    const A = '203.0.113.70';
    for (let round = 0; round < 5; round++) {
      for (let i = 0; i < 19; i++) await hit(A, unseenKey(), NOW + round * 100);
      for (let i = 0; i < 2500; i++) await hit(`2001:db8:${round}:${i.toString(16)}::1`, null, NOW + round * 100 + 1);
    }
    expect(rpc.calls).toBe(10);
    expect(guard.sizes().junk).toBe(GUARD_LIMITS.MAX_JUNK_CLIENTS);
    // Keyed requests from 2,500 more addresses meet the isolate bucket; A stays capped.
    for (let i = 0; i < 2500; i++) await hit(ipv4(i), unseenKey(), NOW + 600);
    for (let i = 0; i < 100; i++) await hit(A, unseenKey(), NOW + 700);
    expect(rpc.calls).toBe(300); // shared 60 + reserve 240 (one owner per key here); 60 before round 6
  });

  test('2,000 concurrent requests with one known-good key: 4 RPCs at most in flight', async () => {
    const key = validKey();
    expect((await hit('203.0.113.80', key)).status).toBe(200);
    rpc.calls = 0;
    rpc.peak = 0;
    const outs = await Promise.all(Array.from({ length: 2000 }, () => hit('203.0.113.80', key, NOW + 1)));
    expect(rpc.peak).toBe(4);
    expect(rpc.calls).toBe(4);
    expect(outs.filter((o) => o.status === 200)).toHaveLength(4);
    const shed = outs.filter((o) => o.status === 429);
    expect(shed).toHaveLength(1996);
    expect(shed[0].headers['Retry-After']).toBe('1');
    expect(guard.sizes().inFlight).toBe(0); // every slot released
    // Slots are released on a thrown RPC too.
    mode = 'throw';
    await Promise.all(Array.from({ length: 10 }, () => hit('203.0.113.80', key, NOW + 2)));
    expect(guard.sizes().inFlight).toBe(0);
    mode = 'normal';
    expect((await hit('203.0.113.80', key, NOW + 3)).status).toBe(200);
  });

  test('a just-revoked key still in the positive cache is negative-cached after its first denial', async () => {
    const key = validKey();
    expect((await hit('203.0.113.81', key)).status).toBe(200);
    KEYS_BY_HASH[sha(key)] = { ok: false, error: 'key_revoked' };
    rpc.calls = 0;
    const burst = await Promise.all(Array.from({ length: 2000 }, () => hit('203.0.113.81', key, NOW + 10)));
    expect(rpc.calls).toBe(4);
    expect(burst.filter((o) => o.status === 401)).toHaveLength(4);
    expect(guard.isKnownKey(sha(key), NOW + 20)).toBe(false);
    // Then 3,000 sequential requests over the next 3 minutes: none reaches the
    // RPC (a revoked key is remembered for its life; before 2026-10-12 it was
    // one RPC per 60 s negative-cache expiry, 2 here).
    const rpcAt = [];
    for (let i = 0; i < 3000; i++) {
      const before = rpc.calls;
      const res = await hit('203.0.113.81', key, NOW + 20 + i * 60);
      expect(res.body.error.code).toBe('key_revoked');
      if (rpc.calls > before) rpcAt.push(20 + i * 60);
    }
    expect(rpcAt).toEqual([]);
    expect(rpc.calls).toBe(4);
  });

  test('busy known keys are capped too: at most MAX_IN_FLIGHT_KEYS x 4 known-key RPCs in flight', async () => {
    guard = createApiGuard({ MAX_IN_FLIGHT_KEYS: 3 });
    const keys = Array.from({ length: 5 }, validKey);
    for (const k of keys) expect((await hit('203.0.113.82', k)).status).toBe(200);
    rpc.calls = 0;
    rpc.peak = 0;
    let release;
    gate = new Promise((r) => { release = r; });
    let settled = 0;
    const pending = keys.flatMap((k) => Array.from({ length: 10 }, () => hit('203.0.113.82', k, NOW + 1).then((o) => { settled += 1; return o; })));
    await until(() => rpc.inFlight === 12 && settled === 38);
    expect(rpc.inFlight).toBe(12);
    release();
    const outs = await Promise.all(pending);
    gate = null;
    expect(rpc.peak).toBe(12);
    expect(rpc.calls).toBe(12);
    expect(outs.filter((o) => o.status === 200)).toHaveLength(12);
    expect(outs.filter((o) => o.status === 429)).toHaveLength(38);
    expect(guard.sizes().inFlight).toBe(0);
    expect((await hit('203.0.113.82', keys[4], NOW + 2)).status).toBe(200);
  });

  test('no cross-window refund', async () => {
    const C = '203.0.113.90';
    const slow = Array.from({ length: 5 }, validKey);
    let release;
    gate = new Promise((r) => { release = r; });
    const pending = slow.map((k) => hit(C, k, NOW)); // 5 tokens from window 1, answered late
    await until(() => rpc.inFlight === 5);
    gate = null;
    for (let i = 0; i < 5; i++) await hit(C, unseenKey(), NOW + 1); // window 1 is full
    expect((await hit(C, unseenKey(), NOW + 2)).status).toBe(429);
    // Window 2 opens and is spent; then window 1's answers arrive and refund.
    for (let i = 0; i < 10; i++) expect((await hit(C, unseenKey(), NOW + 60_000)).status).toBe(401);
    release();
    expect((await Promise.all(pending)).map((o) => o.status)).toEqual([200, 200, 200, 200, 200]);
    rpc.calls = 0;
    for (let i = 0; i < 50; i++) expect((await hit(C, unseenKey(), NOW + 60_001)).status).toBe(429);
    expect(rpc.calls).toBe(0);
  });

  test('a positively cached key is unaffected while the client and isolate buckets are empty', async () => {
    const C = '203.0.113.91';
    expect((await hit(C, KEY)).status).toBe(200);
    for (let i = 0; i < 10; i++) await hit(C, unseenKey());
    for (let i = 0; i < 400; i++) await hit(ipv4(i), unseenKey()); // shared 60 + reserve 240 since round 6
    expect((await hit(C, unseenKey())).status).toBe(429);
    expect((await hit('203.0.113.92', unseenKey())).status).toBe(429);
    rpc.calls = 0;
    for (let i = 0; i < 20; i++) expect((await hit(C, KEY, NOW + i)).status).toBe(200);
    expect(rpc.calls).toBe(20); // still checked by the RPC every time
  });

  test('a never-seen valid key succeeds when tokens are available, and its tokens come back', async () => {
    const C = '203.0.113.93';
    for (let i = 0; i < 9; i++) await hit(C, unseenKey());
    const key = validKey();
    expect((await hit(C, key)).status).toBe(200); // the 10th token, refunded
    expect((await hit(C, unseenKey())).status).toBe(401); // so a 10th unknown key still gets the RPC
    expect((await hit(C, unseenKey())).status).toBe(429);
    // The isolate token came back too: more clients use exactly the remaining
    // 50 shared tokens plus the 240-token reserve (round 6; 50 before).
    rpc.calls = 0;
    for (let i = 0; i < 400; i++) await hit(ipv4(i), unseenKey());
    expect(rpc.calls).toBe(290);
  });

  test('junk requests (keyless, malformed, forged) never cause a 429 for a tag-valid key', async () => {
    const C = '203.0.113.94';
    for (let i = 0; i < 100; i++) await hit(C, null);
    for (let i = 0; i < 100; i++) await hit(C, forgedFrom(`junk-${i}`));
    for (let i = 0; i < 100; i++) await api('/v1/customers?token=x', { key: null, ip: C });
    for (let i = 0; i < 100; i++) await hit(C, 'trk_short');
    expect((await hit(C, null)).status).toBe(429);
    expect((await hit(C, KEY)).status).toBe(200);
    expect((await hit(C, KEY_UNKNOWN)).status).toBe(401);
    for (let i = 0; i < 9; i++) expect((await hit(C, unseenKey())).status).toBe(401);
  });
  describe('self-verifying keys (§14.4a #5): forged keys cost nothing, owners are bounded', () => {
    const keyBytes = (k) => Buffer.from(k.slice(4), 'base64url');
    const spell = (b) => `trk_${b.toString('base64url')}`;
    const OTHER_SECRET = 'not-the-worker-secret-0123456789abcdef-0123456';

    test('10,000 random and forged keys from 5,000 clients: 0 RPCs, 0 tokens, 0 cache entries; a fresh valid key from a new client still authorizes', async () => {
      const real = keyBytes(KEY);
      const variants = [
        (i) => forgedFrom(`rand-${i}`), // 80 random bytes
        (i) => forgedFrom(`body-${i}`, real.subarray(0, 32)), // KEY's id and owner, made-up body and tag
        (i) => { const b = Buffer.from(real); b[64 + (i % 16)] ^= 1 << (i % 8); return spell(b); }, // KEY with one tag bit flipped
        (i) => mint({ keyId: uuidOf(`w${i}`), seed: `w${i}`, secret: OTHER_SECRET }), // tagged with the wrong secret
        (i) => `trk_${sha(`untagged-${i}`).slice(0, 43)}`, // the pre-tag format (no tag at all)
      ];
      const statuses = new Map();
      for (let batch = 0; batch < 10; batch++) {
        const outs = await Promise.all(Array.from({ length: 1000 }, (_, j) => {
          const i = batch * 1000 + j;
          return hit(ipv4(i % 5000), variants[i % variants.length](i), NOW + i);
        }));
        for (const o of outs) statuses.set(o.status, (statuses.get(o.status) || 0) + 1);
      }
      expect(Object.fromEntries(statuses)).toEqual({ 401: 10_000 });
      expect(rpc.calls).toBe(0);
      expect(guard.globalTokensUsed(NOW + 9_999)).toBe(0);
      expect(guard.sizes()).toMatchObject({ clients: 0, owners: 0, knownKeys: 0, inFlight: 0, deniedKeys: 0, limitedKeys: 0 });
      // The real key whose tag was forged 2,000 times is untouched.
      expect((await hit('203.0.113.200', KEY, NOW + 10_000)).status).toBe(200);
      // A never-seen valid key from a brand-new client, inside the same window.
      const fresh = validKey();
      expect((await hit('198.51.100.250', fresh, NOW + 10_001)).status).toBe(200);
      expect(rpc.calls).toBe(2);
      // And the isolate pools are still whole: 300 unseen keys of 300 owners
      // from new clients all reach the RPC (60 shared + 240 reserve), the 301st does not.
      rpc.calls = 0;
      for (let i = 0; i < 301; i++) await hit(ipv4(60_000 + i), unseenKey(), NOW + 10_002);
      expect(rpc.calls).toBe(300);
    });

    test('the reviewer\'s drain (60 random keys a minute from 6 addresses) no longer locks out unseen valid keys', async () => {
      for (let minute = 0; minute < 5; minute++) {
        const t = NOW + minute * 60_000;
        for (let i = 0; i < 60; i++) await hit(`203.0.113.${100 + (i % 6)}`, forgedFrom(`drain-${minute}-${i}`), t + i);
        const fresh = validKey();
        expect((await hit('198.51.100.251', fresh, t + 100)).status).toBe(200);
      }
      expect(rpc.calls).toBe(5); // only the five valid keys
    });

    test('a forged tag on a real key id: 0 RPCs, whatever the variant', async () => {
      const real = keyBytes(KEY);
      const forgeries = [];
      for (let i = 64; i < 80; i++) for (let bit = 0; bit < 8; bit++) { const b = Buffer.from(real); b[i] ^= 1 << bit; forgeries.push(spell(b)); }
      for (let i = 0; i < 100; i++) forgeries.push(forgedFrom(`id-${i}`, real.subarray(0, 32)));
      forgeries.push(mint({ keyId: KEY_ID, seed: 'A', secret: OTHER_SECRET }));
      // A second spelling of KEY's own bytes (the last character's 2 spare bits).
      const abc = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_';
      const twin = KEY.slice(0, -1) + abc[abc.indexOf(KEY[KEY.length - 1]) ^ 1];
      expect(keyBytes(twin)).toEqual(real);
      forgeries.push(twin);
      for (const [i, k] of forgeries.entries()) {
        const res = await hit(ipv4(50_000 + i), k);
        expect(res.status).toBe(401);
        expect(res.body.error.code).toBe('invalid_key');
      }
      expect(forgeries).toHaveLength(128 + 100 + 2);
      // From one address they are junk: 20 answered 401, the rest 429 until the window ends.
      const one = [];
      for (const k of forgeries) one.push((await hit('203.0.113.201', k)).status);
      expect(one.filter((x) => x === 401)).toHaveLength(20);
      expect(one.filter((x) => x === 429)).toHaveLength(210);
      expect(rpc.calls).toBe(0);
      expect(guard.sizes()).toMatchObject({ clients: 0, owners: 0, deniedKeys: 0, knownKeys: 0 });
      expect(guard.globalTokensUsed(NOW)).toBe(0);
      // KEY itself still authorizes from that same address (junk never touches a tag-valid key).
      expect((await hit('203.0.113.201', KEY)).status).toBe(200);
    });

    test('a revoked attacker key replayed: 1 RPC, then 0 for its life (3,000 replays from 3,000 clients over a year)', async () => {
      for (const error of ['key_revoked', 'key_expired']) {
        rpc.calls = 0;
        const key = validKey();
        KEYS_BY_HASH[sha(key)] = { ok: false, error };
        for (let i = 0; i < 3000; i++) {
          const res = await hit(ipv4(20_000 + i), key, NOW + i * 10_512_000); // 3,000 x ~2.9 h = 1 year
          expect(res.body.error.code).toBe(error);
        }
        expect(rpc.calls).toBe(1);
      }
      // Concurrent replay of a never-seen revoked key from 200 clients: at most
      // 4 RPCs in flight for one hash, then none.
      const key = validKey();
      KEYS_BY_HASH[sha(key)] = { ok: false, error: 'key_revoked' };
      rpc.calls = 0;
      const outs = await Promise.all(Array.from({ length: 2000 }, (_, i) => hit(ipv4(30_000 + (i % 200)), key, NOW + 1)));
      expect(rpc.calls).toBe(4);
      expect(outs.filter((o) => o.status === 401)).toHaveLength(4);
      expect(outs.filter((o) => o.status === 429)).toHaveLength(1996);
      for (let i = 0; i < 100; i++) await hit(ipv4(31_000 + i), key, NOW + 2 + i * 86_400_000);
      expect(rpc.calls).toBe(4);
    });

    test('many tag-valid keys of one owner: 10 RPCs per window, whatever the number of keys or clients', async () => {
      const ATTACKER = uuidOf('attacker-owner');
      let n = 0;
      const ownedKey = (error) => {
        const k = mint({ keyId: uuidOf(`attacker-${n}`), ownerId: ATTACKER, seed: `attacker-${n++}` });
        if (error) KEYS_BY_HASH[sha(k)] = { ok: false, error };
        return k;
      };
      // Three windows of 1,000 distinct revoked keys from 1,000 clients each.
      const perWindow = [];
      const used = [];
      for (let w = 0; w < 3; w++) {
        const before = rpc.calls;
        for (let i = 0; i < 1000; i++) {
          const k = ownedKey('key_revoked');
          used.push(k);
          const res = await hit(ipv4(40_000 + w * 1000 + i), k, NOW + w * 60_000 + i);
          expect([401, 429]).toContain(res.status);
        }
        perWindow.push(rpc.calls - before);
      }
      expect(perWindow).toEqual([10, 10, 10]);
      // Concurrently: 1,000 keys of the owner at once, one window, 1,000 clients.
      const before = rpc.calls;
      await Promise.all(Array.from({ length: 1000 }, (_, i) => hit(ipv4(45_000 + i), ownedKey(null), NOW + 3 * 60_000)));
      expect(rpc.calls - before).toBe(10);
      // Every key that did reach the RPC is remembered for its life: replays cost nothing.
      const replayBefore = rpc.calls;
      for (const k of used.slice(0, 2000)) await hit('203.0.113.202', k, NOW + 4 * 60_000);
      expect(rpc.calls - replayBefore).toBe(10); // only window 4's owner tokens, for keys never admitted before
      // Another owner's never-seen valid key, from a new client, is unaffected.
      expect((await hit('198.51.100.252', validKey(), NOW + 4 * 60_000 + 1)).status).toBe(200);
    });

    test('an authorized row that is not the one the tag names fails closed (503) and keeps its tokens', async () => {
      const key = validKey();
      KEYS_BY_HASH[sha(key)] = { ...live(key), keyId: KEY_ID }; // the RPC returns some other key's row
      const res = await hit('203.0.113.203', key);
      expect(res.status).toBe(503);
      expect(res.body.error.code).toBe('unavailable');
      expect(guard.globalTokensUsed(NOW)).toBe(1);
      expect(guard.isKnownKey(sha(key), NOW)).toBe(false);
      KEYS_BY_HASH[sha(key)] = { ...live(key), userId: INTRUDER };
      expect((await hit('203.0.113.203', key, NOW + 1)).status).toBe(503);
      expect(supabaseReads()).toHaveLength(0);
    });

    test('API_KEY_TAG_SECRET unset or short: every authenticated route is 503 not_configured, before any key is read', async () => {
      for (const secret of [undefined, '', 'x'.repeat(43)]) {
        for (const key of [KEY, null, forgedFrom('nc')]) {
          const res = await handleV1({ method: 'GET', url: `${BASE}/v1/customers`, authorization: key ? `Bearer ${key}` : undefined, ip: '203.0.113.204' },
            { ...ENV, API_KEY_TAG_SECRET: secret }, { nowMs: NOW, guard });
          expect(res.status).toBe(503);
          expect(res.body.error.code).toBe('not_configured');
        }
      }
      expect(rpc.calls).toBe(0);
      expect(calls).toHaveLength(0);
      expect(guard.sizes()).toMatchObject({ clients: 0, junk: 0, owners: 0 });
      const doc = await handleV1({ method: 'GET', url: `${BASE}/v1/openapi.json`, ip: null }, { ...ENV, API_KEY_TAG_SECRET: undefined }, { nowMs: NOW, guard });
      expect(doc.status).toBe(200);
      // The same key under a different secret is a forgery.
      const other = await handleV1({ method: 'GET', url: `${BASE}/v1/customers`, authorization: `Bearer ${KEY}`, ip: '203.0.113.204' },
        { ...ENV, API_KEY_TAG_SECRET: OTHER_SECRET }, { nowMs: NOW, guard });
      expect(other.status).toBe(401);
      expect(rpc.calls).toBe(0);
    });
  });
  describe('round 6: dead tag-valid keys cannot lock other owners out (reviewer scenarios a, b, c)', () => {
    const WINDOW = 60_000;
    const ownerOf = (a) => uuidOf(`r6-account-${a}`);
    const deadKey = (a, i, error) => {
      const k = mint({ keyId: uuidOf(`r6-${a}-${i}`), ownerId: ownerOf(a), seed: `r6-${a}-${i}` });
      KEYS_BY_HASH[sha(k)] = { ok: false, error };
      return k;
    };

    test('(a) 6 accounts cycle 2,004 revoked keys (334 each) at 60/min from 6 IPs: a never-seen valid key of another owner authorizes in 120/120 windows', async () => {
      const pools = Array.from({ length: 6 }, (_, a) => Array.from({ length: 334 }, (_, i) => deadKey(a, i, 'key_revoked')));
      const cursor = [0, 0, 0, 0, 0, 0];
      let authorized = 0;
      const attackRpcs = [];
      for (let w = 0; w < 120; w++) {
        const t = NOW + w * WINDOW;
        const before = rpc.calls;
        for (let r = 0; r < 60; r++) {
          const a = r % 6;
          const key = pools[a][cursor[a]++ % 334];
          const res = await hit(`203.0.113.${110 + a}`, key, t + r);
          expect([401, 429]).toContain(res.status);
        }
        attackRpcs.push(rpc.calls - before);
        if ((await hit('198.51.100.240', validKey(), t + 100)).status === 200) authorized += 1;
      }
      expect(authorized).toBe(120);
      // The attack still costs the database 10 RPCs per account per window:
      // each pool (334) is larger than the per-owner negative cache (100).
      expect(new Set(attackRpcs)).toEqual(new Set([60]));
      // With a pool no larger than the per-owner cap, each dead key costs one RPC, ever.
      rpc.calls = 0;
      const small = Array.from({ length: 6 }, (_, a) => Array.from({ length: 100 }, (_, i) => deadKey(10 + a, i, 'key_revoked')));
      const perWindow = [];
      for (let w = 0; w < 15; w++) {
        const before = rpc.calls;
        for (let r = 0; r < 60; r++) await hit(`203.0.113.${120 + (r % 6)}`, small[r % 6][(w * 10 + Math.floor(r / 6)) % 100], NOW + (200 + w) * WINDOW + r);
        perWindow.push(rpc.calls - before);
      }
      expect(perWindow).toEqual([60, 60, 60, 60, 60, 60, 60, 60, 60, 60, 0, 0, 0, 0, 0]);
    }, 120_000);

    test('(b) 6 deleted accounts (60 keys now invalid_key): 60 RPCs once, then 0; a never-seen valid key authorizes in 120/120 windows', async () => {
      const keys = Array.from({ length: 60 }, (_, i) => deadKey(100 + (i % 6), i, 'invalid_key'));
      let authorized = 0;
      const perWindow = [];
      for (let w = 0; w < 120; w++) {
        const t = NOW + w * WINDOW;
        const before = rpc.calls;
        for (let r = 0; r < 60; r++) {
          const res = await hit(`203.0.113.${130 + (r % 6)}`, keys[r], t + r);
          expect(res.status).toBe(401);
          expect(res.body.error.code).toBe('invalid_key');
        }
        perWindow.push(rpc.calls - before);
        if ((await hit('198.51.100.241', validKey(), t + 100)).status === 200) authorized += 1;
      }
      expect(authorized).toBe(120);
      expect(perWindow[0]).toBe(60);
      expect(perWindow.slice(1).every((n) => n === 0)).toBe(true);
    }, 120_000);

    test('(c) 200 accounts x 5 live keys churn the positive cache for an hour: the warm victim key stays cached and authorized every window', async () => {
      // Live attacker keys answer rate_limited (a live key, refunded, no data read).
      const attackers = [];
      for (let a = 0; a < 200; a++) {
        for (let i = 0; i < 5; i++) {
          const k = mint({ keyId: uuidOf(`r6c-${a}-${i}`), ownerId: uuidOf(`r6c-owner-${a}`), seed: `r6c-${a}-${i}` });
          KEYS_BY_HASH[sha(k)] = { ok: false, error: 'rate_limited', retryAfter: 1, limit: 60, remaining: 0, reset: 1 };
          attackers.push(k);
        }
      }
      const victim = validKey();
      expect((await hit('198.51.100.242', victim, NOW)).status).toBe(200);
      let ok = 0;
      let warm = 0;
      for (let w = 0; w < 60; w++) {
        const t = NOW + w * WINDOW + 1;
        for (let i = 0; i < attackers.length; i++) await hit(ipv4(70_000 + (i % 200)), attackers[i], t + 2);
        if (guard.isKnownKey(sha(victim), t + 3)) warm += 1;
        if ((await hit('198.51.100.242', victim, t + 4)).status === 200) ok += 1;
      }
      expect(warm).toBe(60);
      expect(ok).toBe(60);
      expect(guard.sizes().knownKeys).toBe(1001);
      // Even a burst larger than the whole cache (1,100 accounts x 10 keys)
      // between two uses only makes the victim cold, and a cold live key is
      // admitted (refunds keep the pools full).
      const big = createApiGuard();
      guard = big;
      expect((await hit('198.51.100.242', victim, NOW)).status).toBe(200);
      for (let n = 0; n < 11_000; n++) big.knownKey(sha(`burst-${n}`), NOW + 1, uuidOf(`burst-owner-${Math.floor(n / 10)}`));
      expect(big.isKnownKey(sha(victim), NOW + 2)).toBe(false);
      expect((await hit('198.51.100.242', victim, NOW + 3)).status).toBe(200);
    }, 120_000);

    test('owner windows that straddle a global window get one reserve take per global window (120 skew owners: the victim still authorizes)', async () => {
      const T0 = NOW + 10 * WINDOW;
      // A take at T0 - 60 s opens a global window that ends at T0.
      expect((await hit('198.51.100.243', validKey(), T0 - WINDOW)).status).toBe(200);
      const skew = [];
      for (let a = 0; a < 120; a++) {
        const owner = uuidOf(`skew-owner-${a}`);
        const live = mint({ keyId: uuidOf(`skew-live-${a}`), ownerId: owner, seed: `skew-live-${a}` });
        KEYS_BY_HASH[sha(live)] = { ok: false, error: 'rate_limited', retryAfter: 1, limit: 60, remaining: 0, reset: 1 };
        const dead = [1, 2].map((d) => mint({ keyId: uuidOf(`skew-dead-${a}-${d}`), ownerId: owner, seed: `skew-dead-${a}-${d}` }));
        for (const k of dead) KEYS_BY_HASH[sha(k)] = { ok: false, error: 'key_revoked' };
        skew.push({ live, dead });
        // The live key opens the owner's window at T0 - 30 s and refunds it to 0.
        expect((await hit(ipv4(95_000 + a), live, T0 - 30_000)).status).toBe(429);
      }
      rpc.calls = 0;
      // 6 drain owners spend the shared 60 at T0 (a new global window).
      for (let r = 0; r < 60; r++) await hit(`203.0.113.${140 + (r % 6)}`, deadKey(200 + (r % 6), r, 'key_revoked'), T0 + r);
      expect(rpc.calls).toBe(60);
      // Skew owners: one dead key at T0 + 2 s (reserve), another at T0 + 31 s,
      // after their own owner window rolled over but inside the same global window.
      const first = [];
      for (let a = 0; a < 120; a++) first.push((await hit(ipv4(95_000 + a), skew[a].dead[0], T0 + 2_000)).status);
      const second = [];
      for (let a = 0; a < 120; a++) second.push((await hit(ipv4(95_000 + a), skew[a].dead[1], T0 + 31_000)).status);
      expect(first.filter((x) => x === 401)).toHaveLength(120);
      expect(second.filter((x) => x === 429)).toHaveLength(120); // 120 x 401 before this fix (240 reserve takes)
      expect(rpc.calls).toBe(60 + 120);
      expect(guard.globalTokensUsed(T0 + 31_500)).toBe(180);
      expect((await hit('198.51.100.244', validKey(), T0 + 32_000)).status).toBe(200);
    }, 60_000);

    test('an outage closes the reserve: one RPC failure in a window holds the rest of it to the shared pool', async () => {
      mode = 'throw';
      for (let i = 0; i < 5000; i++) await hit(ipv4(80_000 + i), unseenKey(), NOW + i);
      expect(rpc.calls).toBe(60);
      mode = 'normal';
      rpc.calls = 0;
      for (let i = 0; i < 400; i++) await hit(ipv4(90_000 + i), unseenKey(), NOW + WINDOW + i);
      expect(rpc.calls).toBe(300); // next window, no failure: shared + reserve
    }, 60_000);
  });
});
