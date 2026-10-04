// Calendar busy times (Roadmap Phase 26, spec
// docs/superpowers/specs/2026-10-03-calendar-sync-design.md §3): the route
// wrapper (src/routes/calendar/busy.js: CORS, owner JWT, per-user rate limit,
// the 64 KB raw-body cap), the store's PostgREST calls, and the gate helpers.
// The handler core's full matrix and the shared parity vectors run in the
// root Jest suites (__tests__/calendarBusyWorkers.test.js,
// __tests__/calendarBusyParity.test.js).

const assert = require('node:assert/strict');
const { afterEach, before, describe, test } = require('node:test');

const {
  parseInstant,
  parseDateDays,
  normalizeInstant,
  validateSnapshot,
  gateFreshness,
  calendarBusyGate,
  isSourceId,
} = require('../lib/calendar/busyGate.js');
const store = require('../lib/calendar/busyStore.js');

const ENV = { SUPABASE_URL: 'https://supa.test', SUPABASE_SERVICE_ROLE_KEY: 'srk', SUPABASE_ANON_KEY: 'anon' };
const SOURCE = '0b8f1c1e-2f6a-4c55-9d3e-1a2b3c4d5e6f';

function res(body, status = 200) {
  return { ok: status >= 200 && status < 300, status, json: async () => body, text: async () => JSON.stringify(body) };
}

const realFetch = global.fetch;
afterEach(() => {
  global.fetch = realFetch;
});

describe('gate helpers', () => {
  test('parseInstant accepts only the minute-precision Z form and real dates', () => {
    assert.equal(parseInstant('2026-10-03T14:05:00Z'), Date.UTC(2026, 9, 3, 14, 5));
    for (const bad of ['2026-10-03T14:05:30Z', '2026-10-03T14:05:00.000Z', '2026-10-03T14:05:00+00:00',
      '2026-02-29T10:00:00Z', '2026-13-01T10:00:00Z', '2026-10-03T24:00:00Z', '', null, 7]) {
      assert.equal(parseInstant(bad), null, String(bad));
    }
    assert.equal(parseInstant('2028-02-29T10:00:00Z'), Date.UTC(2028, 1, 29, 10, 0));
  });

  test('parseDateDays round-trips real dates only', () => {
    assert.equal(parseDateDays('1970-01-02'), 1);
    assert.equal(parseDateDays('2026-02-30'), null);
    assert.equal(parseDateDays('2026-1-02'), null);
  });

  test('normalizeInstant reads PostgREST timestamptz output', () => {
    assert.equal(normalizeInstant('2026-10-03T14:05:00+00:00'), '2026-10-03T14:05:00Z');
    assert.equal(normalizeInstant('2026-10-03T09:05:00-05:00'), '2026-10-03T14:05:00Z');
    assert.equal(normalizeInstant('2026-10-03T14:05:00Z'), '2026-10-03T14:05:00Z');
    assert.equal(normalizeInstant('2026-10-03T14:05:30+00:00'), null);
    assert.equal(normalizeInstant(null), null);
  });

  test('isSourceId is a lowercase UUID', () => {
    assert.equal(isSourceId(SOURCE), true);
    assert.equal(isSourceId(SOURCE.toUpperCase()), false);
    assert.equal(isSourceId('0b8f1c1e2f6a4c559d3e1a2b3c4d5e6f'), false);
  });

  test('validateSnapshot returns parsed values', () => {
    const out = validateSnapshot({
      v: 1, computedAt: '2026-10-03T14:05:00Z', windowStart: '2026-10-03T05:00:00Z', windowEnd: '2026-10-17T05:00:00Z',
      timed: [['2026-10-06T15:00:00Z', '2026-10-06T16:30:00Z']], allDay: [['2026-10-10', '2026-10-10']],
    }, { nowMs: Date.UTC(2026, 9, 3, 14, 10) });
    assert.equal(out.ok, true);
    assert.deepEqual(out.value.timed, [[Date.UTC(2026, 9, 6, 15, 0), Date.UTC(2026, 9, 6, 16, 30)]]);
    assert.deepEqual(out.value.allDay, [[parseDateDays('2026-10-10'), parseDateDays('2026-10-10')]]);
  });

  test('gateFreshness: no row off, unparseable received_at stale', () => {
    assert.deepEqual(gateFreshness(null, { nowMs: 0 }), { state: 'off' });
    const row = {
      snapshot: { v: 1, timed: [], allDay: [] }, computed_at: '2026-10-03T14:05:00Z',
      window_start: '2026-10-03T05:00:00Z', window_end: '2026-10-17T05:00:00Z', received_at: 'yesterday',
    };
    assert.deepEqual(gateFreshness(row, { nowMs: Date.UTC(2026, 9, 3, 15) }), { state: 'stale' });
  });

  test('calendarBusyGate honors a custom ttlHours', () => {
    const row = {
      snapshot: { v: 1, timed: [], allDay: [] }, computed_at: '2026-10-03T14:05:00Z',
      window_start: '2026-10-03T05:00:00Z', window_end: '2026-10-17T05:00:00Z', received_at: '2026-10-03T14:05:00Z',
    };
    const nowMs = Date.UTC(2026, 9, 3, 16, 6);
    assert.equal(calendarBusyGate(row, { timeZone: 'America/Chicago', nowMs, ttlHours: 2 }).state, 'stale');
    assert.equal(calendarBusyGate(row, { timeZone: 'America/Chicago', nowMs }).state, 'fresh');
  });
});

describe('busyStore', () => {
  test('fetch selects the owner row with the service role; 404 means not deployed', async () => {
    const calls = [];
    global.fetch = async (url, init = {}) => {
      calls.push({ url, init });
      return res([{ user_id: 'u1', source_id: SOURCE }]);
    };
    const found = await store.fetchCalendarBusyRow(ENV, 'u 1');
    assert.deepEqual(found, { available: true, row: { user_id: 'u1', source_id: SOURCE } });
    assert.match(calls[0].url, /^https:\/\/supa\.test\/rest\/v1\/calendar_busy\?user_id=eq\.u%201&select=/);
    assert.equal(calls[0].init.headers.Authorization, 'Bearer srk');
    assert.equal(calls[0].init.headers.apikey, 'srk');

    global.fetch = async () => res({ code: 'PGRST205' }, 404);
    assert.deepEqual(await store.fetchCalendarBusyRow(ENV, 'u1'), { available: false, row: null });
    assert.equal(await store.fetchCalendarBusy(ENV, 'u1'), null);
    assert.deepEqual(await store.upsertCalendarBusy(ENV, {}), { available: false });
    assert.deepEqual(await store.deleteCalendarBusy(ENV, 'u1'), { available: false });
  });

  test('any other failure throws', async () => {
    global.fetch = async () => res({ message: 'boom' }, 500);
    await assert.rejects(store.fetchCalendarBusy(ENV, 'u1'), /calendar_busy fetch 500/);
    await assert.rejects(store.upsertCalendarBusy(ENV, {}), /calendar_busy upsert 500/);
    await assert.rejects(store.deleteCalendarBusy(ENV, 'u1'), /calendar_busy delete 500/);
  });

  test('upsert merges on user_id and returns nothing', async () => {
    let seen;
    global.fetch = async (url, init) => {
      seen = { url, init };
      return res(null, 201);
    };
    await store.upsertCalendarBusy(ENV, { user_id: 'u1' });
    assert.equal(seen.url, 'https://supa.test/rest/v1/calendar_busy?on_conflict=user_id');
    assert.equal(seen.init.method, 'POST');
    assert.equal(seen.init.headers.Prefer, 'resolution=merge-duplicates,return=minimal');
    assert.deepEqual(JSON.parse(seen.init.body), { user_id: 'u1' });
  });
});

describe('POST /api/calendar/busy route wrapper', () => {
  let calendarBusyHandler;
  before(async () => {
    ({ calendarBusyHandler } = await import('../src/routes/calendar/busy.js'));
  });

  function fakeC({ method = 'POST', auth = 'Bearer jwt', body = '' } = {}) {
    const headers = {};
    return {
      env: ENV,
      headers,
      header: (k, v) => { headers[k] = v; },
      req: {
        method,
        header: (name) => (name.toLowerCase() === 'authorization' ? auth : undefined),
        text: async () => body,
      },
      json: (out, status = 200) => ({ status, out }),
      body: (out, status = 200) => ({ status, out }),
    };
  }

  function backend(userId) {
    const calls = [];
    global.fetch = async (url, init = {}) => {
      calls.push({ url: String(url), init });
      if (String(url).endsWith('/auth/v1/user')) return userId ? res({ id: userId }) : res({}, 401);
      if (String(url).includes('/rest/v1/calendar_busy')) return (init.method || 'GET') === 'GET' ? res([]) : res(null, 201);
      return res([]);
    };
    return calls;
  }

  test('CORS preflight, method and auth checks', async () => {
    backend('owner-cors');
    const c = fakeC({ method: 'OPTIONS' });
    assert.equal((await calendarBusyHandler(c)).status, 200);
    assert.equal(c.headers['Access-Control-Allow-Origin'], 'https://gettradereadyapp.com');
    assert.equal((await calendarBusyHandler(fakeC({ method: 'GET' }))).status, 405);
    assert.equal((await calendarBusyHandler(fakeC({ auth: null }))).status, 401);
    backend(null);
    assert.equal((await calendarBusyHandler(fakeC())).status, 401);
  });

  test('the raw body is capped at 64 KB before it is parsed or the table is read', async () => {
    const calls = backend('owner-size');
    const big = JSON.stringify({ action: 'put', sourceId: SOURCE, snapshot: null, pad: 'x'.repeat(64 * 1024) });
    const out = await calendarBusyHandler(fakeC({ body: big }));
    assert.deepEqual(out, { status: 400, out: { error: 'invalid_snapshot' } });
    assert.equal(calls.some((c) => c.url.includes('calendar_busy')), false);
  });

  test('a put reaches the core with the verified owner id', async () => {
    const calls = backend('owner-put');
    const out = await calendarBusyHandler(fakeC({ body: JSON.stringify({ action: 'put', sourceId: SOURCE, snapshot: null }) }));
    assert.equal(out.status, 200);
    assert.equal(out.out.ok, true);
    const post = calls.find((c) => c.init.method === 'POST');
    assert.equal(JSON.parse(post.init.body).user_id, 'owner-put');
  });

  test('unparseable JSON is an invalid request, not a crash', async () => {
    backend('owner-json');
    assert.equal((await calendarBusyHandler(fakeC({ body: '{nope' }))).status, 400);
  });

  test('per-user rate limit: 20 per window, then 429', async () => {
    backend('owner-rate');
    const body = JSON.stringify({ action: 'status' });
    for (let i = 0; i < 20; i += 1) assert.equal((await calendarBusyHandler(fakeC({ body }))).status, 200);
    assert.equal((await calendarBusyHandler(fakeC({ body }))).status, 429);
    backend('owner-other');
    assert.equal((await calendarBusyHandler(fakeC({ body }))).status, 200);
  });
});
