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
//   - the raw key never appears in a console call, a log body or any
//     request the Worker makes.

const { createHash } = require('node:crypto');
const { handleV1 } = require('../backend-workers/lib/api/v1.js');
const { createAuthFailureGuard } = require('../backend-workers/lib/api/auth.js');
const { apiV1Handler } = require('../backend-workers/src/routes/api/v1.js');
const { FIELDS } = require('../backend-workers/lib/api/resources.js');

const OWNER = '11111111-1111-4111-8111-111111111111';
const INTRUDER = '99999999-9999-4999-8999-999999999999';
const KEY_ID = '22222222-2222-4222-8222-222222222222';
const BASE = 'https://tradeready-backend.tradeready.workers.dev';
const ENV = {
  SUPABASE_URL: 'https://supa.test',
  SUPABASE_SERVICE_ROLE_KEY: 'srk',
  API_CURSOR_SECRET: 'cursor-secret',
};
const BUSINESS_TABLES = ['jobs', 'invoices', 'customers', 'expenses', 'trips', 'settings'];
const ALL_SCOPES = ['customers:read', 'jobs:read', 'invoices:read', 'expenses:read', 'mileage:read'];

// Keys are built at runtime so no key-shaped literal sits in the repo.
const mkKey = (ch) => `trk_${ch.repeat(43)}`;
const KEY = mkKey('A');
const KEY_JOBS_ONLY = mkKey('J');
const KEY_REVOKED = mkKey('R');
const KEY_EXPIRED = mkKey('E');
const KEY_LIMITED = mkKey('L');
const KEY_UNKNOWN = mkKey('U');
const sha = (s) => createHash('sha256').update(s).digest('hex');
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
  [sha(KEY_JOBS_ONLY)]: { ok: true, userId: OWNER, keyId: KEY_ID, scopes: ['jobs:read'], name: 'Jobs', prefix: 'trk_JJJJJJJJ', expiresAt: null, limit: 60, remaining: 59, reset: 1791040000 },
  [sha(KEY_REVOKED)]: { ok: false, error: 'key_revoked' },
  [sha(KEY_EXPIRED)]: { ok: false, error: 'key_expired' },
  [sha(KEY_LIMITED)]: { ok: false, error: 'rate_limited', retryAfter: 17, limit: 60, remaining: 0, reset: 1791040017 },
  [sha(KEY_UNKNOWN)]: { ok: false, error: 'invalid_key' },
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
beforeEach(() => { guard = createAuthFailureGuard({ limit: 20 }); });

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
    { nowMs, failureGuard: guard }
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
    expect(logRows()).toEqual([{ user_id: OWNER, key_id: KEY_ID, event: 'denied', route: '/v1/invoices', status: 403, ip: '203.0.113.9' }]);
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

  test('missing or malformed bearer is 401 invalid_key with no database contact', async () => {
    for (const key of [null, 'trk_short', 'sk_live_whatever']) {
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

  test('20 malformed or keyless requests block that address; the RPC sees no more junk', async () => {
    for (let i = 0; i < 20; i++) expect((await api('/v1/customers', { key: null, ip: '198.51.100.5' })).status).toBe(401);
    const rpcBefore = calls.length;
    const blocked = await api('/v1/customers', { key: 'trk_short', ip: '198.51.100.5' });
    expect(blocked.status).toBe(429);
    expect(blocked.headers['Retry-After']).toBe('60');
    expect((await api('/v1/customers', { key: null, ip: '198.51.100.5' })).status).toBe(429);
    expect(calls.length).toBe(rpcBefore);
    expect((await api('/v1/customers', { key: null, ip: '198.51.100.6' })).status).toBe(401);
  });

  test('a well-formed key is never rejected by the IP failure guard (shared egress address)', async () => {
    // Junk from the shared address, including the cheap ?token=x trick.
    for (let i = 0; i < 15; i++) await api('/v1/customers', { key: null, ip: '198.51.100.5' });
    for (let i = 0; i < 15; i++) await api('/v1/customers?token=x', { key: null, ip: '198.51.100.5' });
    expect((await api('/v1/customers', { key: 'trk_short', ip: '198.51.100.5' })).status).toBe(429);
    expect((await api('/v1/customers', { key: null, ip: '198.51.100.5' })).status).toBe(429);
    // Other owners' valid keys on the same address still go to the RPC and are served
    // (never-seen keys share the blocked address's small RPC budget, see below).
    for (const key of [KEY, KEY_JOBS_ONLY]) {
      const rpcBefore = calls.filter((c) => c.url.endsWith('/rpc/api_key_authorize')).length;
      const res = await api('/v1/jobs', { key, ip: '198.51.100.5' });
      expect(res.status).toBe(200);
      expect(calls.filter((c) => c.url.endsWith('/rpc/api_key_authorize')).length).toBe(rpcBefore + 1);
    }
    // And a valid key keeps working after the block is long established.
    expect((await api('/v1/customers', { key: KEY, ip: '198.51.100.5', nowMs: NOW + 30_000 })).status).toBe(200);
  });

  test('well-formed unknown keys are answered 401 from memory after 5 RPCs for the same hash', async () => {
    const rpcCount = () => calls.filter((c) => c.url.endsWith('/rpc/api_key_authorize')).length;
    for (let i = 0; i < 12; i++) {
      const res = await api('/v1/customers', { key: KEY_UNKNOWN, ip: '198.51.100.7' });
      expect(res.status).toBe(401);
      expect(res.body.error.code).toBe('invalid_key');
      expect(res.headers['WWW-Authenticate']).toMatch(/^Bearer/);
    }
    expect(rpcCount()).toBe(5);
    // A different unknown hash is judged on its own, and valid keys are untouched.
    expect((await api('/v1/customers', { key: mkKey('V'), ip: '198.51.100.7' })).status).toBe(401);
    expect(rpcCount()).toBe(6);
    expect((await api('/v1/customers', { key: KEY, ip: '198.51.100.7' })).status).toBe(200);
    // Shedding ends with the window: the hash is looked up again.
    await api('/v1/customers', { key: KEY_UNKNOWN, ip: '198.51.100.7', nowMs: NOW + 61_000 });
    expect(rpcCount()).toBe(8);
  });

  describe('distinct well-formed random keys from one address (resource-cap defeat)', () => {
    const rpcCount = () => calls.filter((c) => c.url.endsWith('/rpc/api_key_authorize')).length;
    const IP = '198.51.100.20';
    const fresh = (tag, i) => `trk_${sha(`${tag}${i}`).slice(0, 43)}`;
    const addValid = (key) => { KEYS_BY_HASH[sha(key)] = { ...KEYS_BY_HASH[sha(KEY)] }; };
    afterEach(() => { for (const k of Object.keys(KEYS_BY_HASH)) if (!ALL_KEYS.some((a) => sha(a) === k)) delete KEYS_BY_HASH[k]; });

    test('500 distinct unknown keys from one IP cost exactly 25 RPCs (20 failures + 5 budget); known and fresh keys still work', async () => {
      // KEY authorizes first, so it is in the positive cache.
      expect((await api('/v1/customers', { key: KEY, ip: IP })).status).toBe(200);
      expect(rpcCount()).toBe(1);
      let shed = 0;
      for (let i = 0; i < 500; i++) {
        const res = await api('/v1/customers', { key: fresh('junk', i), ip: IP });
        if (res.status === 429) { shed++; expect(res.headers['Retry-After']).toBe('60'); } else expect(res.status).toBe(401);
      }
      expect(rpcCount()).toBe(1 + 25);
      expect(shed).toBe(475);
      // During the flood a previously authorized key from the same IP still succeeds (and is checked by the RPC).
      const before = rpcCount();
      expect((await api('/v1/customers', { key: KEY, ip: IP })).status).toBe(200);
      expect(rpcCount()).toBe(before + 1);
      // The attacker's churn did not evict the positive-cache entry.
      expect(guard.sizes().knownKeys).toBe(1);
      // Another IP is unaffected, even for unknown keys.
      expect((await api('/v1/customers', { key: fresh('other', 0), ip: '198.51.100.21' })).status).toBe(401);
      expect((await api('/v1/jobs', { key: KEY_JOBS_ONLY, ip: '198.51.100.21' })).status).toBe(200);
    });

    test('valid never-seen keys from a blocked IP do not consume the budget (or each other\'s); unknown keys do', async () => {
      for (let i = 0; i < 20; i++) await api('/v1/customers', { key: null, ip: IP }); // block the address
      expect((await api('/v1/customers', { key: null, ip: IP })).status).toBe(429);
      const keys = Array.from({ length: 12 }, (_, i) => fresh('valid', i));
      keys.forEach(addValid);
      for (const key of keys) expect((await api('/v1/customers', { key, ip: IP })).status).toBe(200);
      expect(rpcCount()).toBe(12);
      // Unknown keys spend the budget (5 per window) ...
      for (let i = 0; i < 5; i++) expect((await api('/v1/customers', { key: fresh('junk', i), ip: IP })).status).toBe(401);
      expect((await api('/v1/customers', { key: fresh('junk', 5), ip: IP })).status).toBe(429);
      // ... and with it spent, a never-seen valid key waits for the next window (the accepted residual) ...
      const late = fresh('late', 0);
      addValid(late);
      expect((await api('/v1/customers', { key: late, ip: IP })).status).toBe(429);
      // ... while keys the isolate already knows are unaffected.
      expect((await api('/v1/customers', { key: keys[0], ip: IP })).status).toBe(200);
      expect((await api('/v1/customers', { key: late, ip: IP, nowMs: NOW + 61_000 })).status).toBe(200);
    });

    test('a key that authorized 30 minutes ago still passes during a flood (60-minute positive cache)', async () => {
      expect((await api('/v1/customers', { key: KEY, ip: IP, nowMs: NOW })).status).toBe(200);
      const later = NOW + 30 * 60_000;
      for (let i = 0; i < 100; i++) await api('/v1/customers', { key: fresh('junk', i), ip: IP, nowMs: later });
      expect(guard.blockedFor(IP, later)).toBeGreaterThan(0);
      const before = rpcCount();
      expect((await api('/v1/customers', { key: KEY, ip: IP, nowMs: later })).status).toBe(200);
      expect(rpcCount()).toBe(before + 1); // still checked by the RPC
      // Each success refreshes the 60-minute TTL; once it lapses the key is an ordinary never-seen key again.
      expect(guard.isKnownKey(sha(KEY), later + 59 * 60_000)).toBe(true);
      expect(guard.isKnownKey(sha(KEY), later + 61 * 60_000)).toBe(false);
    });

    test('a budget 429 never outlasts the block, and requests during a block do not extend it', async () => {
      for (let i = 0; i < 20; i++) await api('/v1/customers', { key: null, ip: IP }); // block opens at NOW for 60 s
      const t = NOW + 30_000;
      for (let i = 0; i < 5; i++) expect((await api('/v1/customers', { key: fresh('junk', i), ip: IP, nowMs: t })).status).toBe(401);
      for (let i = 5; i < 30; i++) {
        const res = await api('/v1/customers', { key: fresh('junk', i), ip: IP, nowMs: t });
        expect(res.status).toBe(429);
        expect(res.headers['Retry-After']).toBe('30');
      }
      expect((await api('/v1/customers', { key: null, ip: IP, nowMs: t })).status).toBe(429);
      // One window after the block began it is over, whatever was sent meanwhile.
      expect((await api('/v1/customers', { key: null, ip: IP, nowMs: NOW + 60_000 })).status).toBe(401);
      expect((await api('/v1/customers', { key: fresh('junk', 99), ip: IP, nowMs: NOW + 60_000 })).status).toBe(401);
    });

    test('the positive cache never skips the RPC: a revoked key is refused and forgotten', async () => {
      const key = fresh('flip', 0);
      addValid(key);
      expect((await api('/v1/customers', { key, ip: IP })).status).toBe(200);
      for (let i = 0; i < 20; i++) await api('/v1/customers', { key: null, ip: IP });
      const before = rpcCount();
      expect((await api('/v1/customers', { key, ip: IP })).status).toBe(200);
      expect(rpcCount()).toBe(before + 1);
      KEYS_BY_HASH[sha(key)] = { ok: false, error: 'key_revoked' };
      const res = await api('/v1/customers', { key, ip: IP });
      expect(res.status).toBe(401);
      expect(res.body.error.code).toBe('key_revoked');
      expect(rpcCount()).toBe(before + 2);
      expect(guard.isKnownKey(sha(key), NOW)).toBe(false);
    });
  });

  test('revoked and expired keys are not negative-cached (only unknown hashes are)', async () => {
    const rpcCount = () => calls.filter((c) => c.url.endsWith('/rpc/api_key_authorize')).length;
    for (let i = 0; i < 8; i++) {
      expect((await api('/v1/customers', { key: KEY_REVOKED })).body.error.code).toBe('key_revoked');
      expect((await api('/v1/customers', { key: KEY_EXPIRED })).body.error.code).toBe('key_expired');
    }
    expect(rpcCount()).toBe(16);
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
      { ...ENV, API_CURSOR_SECRET: '' }, { nowMs: Date.now(), failureGuard: guard });
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
    const g = createAuthFailureGuard({ limit: 20, maxEntries: 50 });
    for (let i = 0; i < 500; i++) {
      for (let f = 0; f < 20; f++) g.fail(`ip-${i}`, NOW + i);
      const hash = sha(`k${i}`);
      for (let f = 0; f < 5; f++) g.unknownKey(hash, NOW + i);
      g.rateLimitedKey(sha(`l${i}`), { retryAfter: 600, rate: { limit: 60, remaining: 0, reset: 1 } }, NOW + i);
    }
    expect(g.sizes()).toMatchObject({ ips: 50, blocked: 50, unknownKeys: 50, limitedKeys: 50 });
    // The newest entries survive; the oldest were evicted.
    expect(g.blockedFor('ip-499', NOW + 500)).toBeGreaterThan(0);
    expect(g.blockedFor('ip-0', NOW + 500)).toBe(0);
    expect(g.keyShed(sha('k499'), NOW + 500)).toEqual({ error: 'invalid_key' });
    expect(g.keyShed(sha('k0'), NOW + 500)).toBeNull();
    expect(g.keyShed(sha('l499'), NOW + 500).error).toBe('rate_limited');
    expect(g.keyShed(sha('l0'), NOW + 500)).toBeNull();
    // A raw key is refused by the per-hash maps, so it can never be remembered.
    g.unknownKey(KEY_UNKNOWN, NOW);
    g.rateLimitedKey(KEY_UNKNOWN, { retryAfter: 60 }, NOW);
    g.knownKey(KEY_UNKNOWN, NOW);
    expect(g.keyShed(KEY_UNKNOWN, NOW)).toBeNull();
    expect(g.isKnownKey(KEY_UNKNOWN, NOW)).toBe(false);
    expect(g.sizes()).toMatchObject({ ips: 50, blocked: 50, unknownKeys: 50, limitedKeys: 50, knownKeys: 0 });
  });

  test('the default caps keep the maps bounded under a flood of distinct addresses and keys', () => {
    const g = createAuthFailureGuard();
    for (let i = 0; i < 5000; i++) {
      g.fail(`ip-${i}`, NOW);
      g.unknownKey(sha(`k${i}`), NOW);
      g.rateLimitedKey(sha(`l${i}`), { retryAfter: 60 }, NOW);
    }
    const sizes = g.sizes();
    for (const n of Object.values(sizes)) expect(n).toBeLessThanOrEqual(2000);
  });

  test('churn in one map never evicts another: known keys and active rate-limit entries survive unknown-key floods', () => {
    const g = createAuthFailureGuard({ maxEntries: 100, maxKnownKeys: 20 });
    g.knownKey(sha('good'), NOW);
    g.rateLimitedKey(sha('limited'), { retryAfter: 600, rate: null }, NOW);
    for (let i = 0; i < 5000; i++) {
      g.unknownKey(sha(`junk${i}`), NOW + i);
      g.fail(`ip-${i}`, NOW + i);
    }
    expect(g.isKnownKey(sha('good'), NOW + 5000)).toBe(true);
    expect(g.keyShed(sha('limited'), NOW + 5000).error).toBe('rate_limited');
    // The positive cache is itself bounded (oldest evicted) and expires.
    for (let i = 0; i < 100; i++) g.knownKey(sha(`k${i}`), NOW + i);
    expect(g.sizes().knownKeys).toBe(20);
    expect(g.isKnownKey(sha('k99'), NOW + 100)).toBe(true);
    expect(g.isKnownKey(sha('k99'), NOW + 100 + 3_600_000)).toBe(false);
  });
});
