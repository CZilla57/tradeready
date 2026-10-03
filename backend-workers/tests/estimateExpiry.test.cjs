// Quote expiration dates (Roadmap Phase 32) — Worker side.
// Spec: docs/superpowers/specs/2026-10-03-quote-expiration-design.md §2.4,
// §4.1–§4.5, §8. The expiry vectors are the shared parity fixture the Swift
// suite also loads. `Date.now` is stubbed per test; every handler reads it
// once, and nothing may read the process time zone (the suite also runs
// under TZ=America/Phoenix, and one test flips process.env.TZ at runtime).

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { createHash } = require('node:crypto');
const { before, beforeEach, afterEach, describe, test } = require('node:test');

const {
  ANYWHERE_ON_EARTH_ZONE,
  isResolvableTimeZone,
  validateSnapshotValidity,
  snapshotExpiry,
  formatValidUntil,
  expiredMessage,
} = require('../lib/estimate/estimateExpiry.js');
const { snapshotDigest } = require('../lib/estimate/quoteOptions.js');

const FIXTURE_PATH = path.join(__dirname, '../../native/QuoteExpiryTests/Fixtures/quote-expiry-vectors.json');
const fixture = JSON.parse(fs.readFileSync(FIXTURE_PATH, 'utf8'));

const clone = (v) => JSON.parse(JSON.stringify(v));
const DAY_MS = 86_400_000;

// Phoenix (UTC-7, no DST). 2026-10-03T06:30Z is Oct 2, 23:30 local — the
// FA-039 instant where the UTC date is already a day ahead.
const NOW = Date.parse('2026-10-03T06:30:00Z');
const VALID_AT = Date.parse('2026-11-03T06:30:00Z'); // Nov 2, 23:30 Phoenix
const EXPIRED_AT = Date.parse('2026-11-03T07:00:00Z'); // Nov 3, 00:00 Phoenix

function addDays(ymd, days) {
  const [y, m, d] = ymd.split('-').map(Number);
  return new Date(Date.UTC(y, m - 1, d) + days * DAY_MS).toISOString().slice(0, 10);
}

function vectorSnapshot(v) {
  const s = {};
  if (v.validUntil !== null) s.validUntil = v.validUntil;
  if (v.timeZone !== null) s.validUntilTimeZone = v.timeZone;
  return s;
}

const legacySnapshot = () => ({
  businessName: 'Rector HVAC',
  customerName: 'Pat Lee',
  jobTitle: 'Panel upgrade',
  lineItems: [{ label: 'Labor (2 hrs @ $100/hr)', amount: 200 }],
  total: 200,
  currency: 'USD',
});

const datedSnapshot = (validUntil = '2026-11-02', validUntilTimeZone = 'America/Phoenix') => ({
  ...legacySnapshot(),
  validUntil,
  validUntilTimeZone,
});

function optionsSnapshot(validUntil = '2026-11-02') {
  const tiers = [
    { id: 'qt_good', name: 'Repair', lineItems: [{ label: 'Repair', amount: 1200 }], total: 1200 },
    { id: 'qt_better', name: 'Standard unit', lineItems: [{ label: 'Unit', amount: 1850 }], total: 1850 },
  ];
  return {
    ...datedSnapshot(validUntil),
    jobTitle: 'AC replacement',
    lineItems: clone(tiers[1].lineItems),
    total: 1850,
    options: { recommendedTierId: 'qt_better', tiers, addOns: [] },
  };
}

let realNow;
let originalFetch;
let originalWarn;
beforeEach(() => {
  realNow = Date.now;
  originalFetch = global.fetch;
  originalWarn = console.warn;
});
afterEach(() => {
  Date.now = realNow;
  global.fetch = originalFetch;
  console.warn = originalWarn;
});
function at(ms) { Date.now = () => ms; }

describe('snapshotExpiry — shared parity vectors', () => {
  test('the fixture keeps the agreed schema and covers every spec §8 case', () => {
    assert.deepEqual(Object.keys(fixture).filter((k) => k !== 'description'), ['vectors']);
    for (const v of fixture.vectors) {
      assert.deepEqual(Object.keys(v).sort(), ['expired', 'name', 'now', 'timeZone', 'validUntil'], v.name);
      assert.match(v.now, /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/, v.name);
      assert.equal(typeof v.expired, 'boolean');
    }
    const zones = new Set(fixture.vectors.map((v) => v.timeZone));
    for (const z of ['America/Phoenix', 'America/New_York', 'Pacific/Auckland', 'Mars/Olympus', null]) {
      assert.ok(zones.has(z), String(z));
    }
    assert.ok(fixture.vectors.some((v) => v.validUntil === null));
  });

  for (const v of fixture.vectors) {
    test(v.name, () => {
      const result = snapshotExpiry(vectorSnapshot(v), Date.parse(v.now));
      assert.deepEqual(result, { validUntil: v.validUntil, expired: v.expired });
    });
  }

  test('the process time zone never matters (TZ flipped at runtime)', () => {
    const saved = process.env.TZ;
    try {
      for (const tz of ['Pacific/Kiritimati', 'Etc/GMT+12', 'America/Phoenix', 'UTC']) {
        process.env.TZ = tz;
        for (const v of fixture.vectors) {
          assert.equal(snapshotExpiry(vectorSnapshot(v), Date.parse(v.now)).expired, v.expired, `${tz}: ${v.name}`);
        }
        assert.equal(formatValidUntil('2026-11-02'), 'November 2, 2026', tz);
      }
    } finally {
      if (saved === undefined) delete process.env.TZ;
      else process.env.TZ = saved;
    }
  });

  test('undated, malformed and non-object snapshots never expire', () => {
    const far = Date.parse('2099-01-01T00:00:00Z');
    for (const s of [undefined, null, [], 'x', legacySnapshot(), { validUntil: '2026-02-30', validUntilTimeZone: 'UTC' }, { validUntil: 20261102 }]) {
      assert.deepEqual(snapshotExpiry(s, far), { validUntil: null, expired: false });
    }
  });
});

describe('isResolvableTimeZone / formatValidUntil / expiredMessage', () => {
  test('zones', () => {
    assert.equal(ANYWHERE_ON_EARTH_ZONE, 'Etc/GMT+12');
    for (const z of ['America/Phoenix', 'Pacific/Auckland', 'Etc/GMT+12', 'UTC']) assert.equal(isResolvableTimeZone(z), true, z);
    for (const z of ['Mars/Olympus', '', null, undefined, 42]) assert.equal(isResolvableTimeZone(z), false, String(z));
  });

  test('formatValidUntil never shifts a day', () => {
    assert.equal(formatValidUntil('2026-11-02'), 'November 2, 2026');
    assert.equal(formatValidUntil('2026-01-01'), 'January 1, 2026');
    assert.equal(formatValidUntil('2026-12-31'), 'December 31, 2026');
    assert.equal(formatValidUntil('2028-02-29'), 'February 29, 2028');
  });

  test('expiredMessage is self-contained and falls back to "the business"', () => {
    assert.equal(expiredMessage(datedSnapshot(), '2026-11-02'),
      'This estimate expired on November 2, 2026. Please ask Rector HVAC for an updated estimate.');
    assert.equal(expiredMessage({ ...datedSnapshot(), businessName: '  ' }, '2026-11-02'),
      'This estimate expired on November 2, 2026. Please ask the business for an updated estimate.');
    assert.equal(expiredMessage(undefined, '2026-11-02'),
      'This estimate expired on November 2, 2026. Please ask the business for an updated estimate.');
  });
});

describe('validateSnapshotValidity', () => {
  const TOGETHER = 'Valid-until date and time zone must be sent together.';
  const BAD_DATE = 'The valid-until date is invalid.';
  const BAD_ZONE = 'The valid-until time zone is invalid.';
  const PAST = 'The valid-until date is in the past.';
  const FAR = 'The valid-until date is too far in the future.';
  const check = (extra) => validateSnapshotValidity({ ...legacySnapshot(), ...extra }, NOW);

  test('runs only when either key is present', () => {
    assert.equal(validateSnapshotValidity(legacySnapshot(), NOW), null);
    assert.equal(check({ validUntil: null, validUntilTimeZone: null }), null);
    assert.equal(validateSnapshotValidity(undefined, NOW), null);
  });

  test('both keys or neither', () => {
    assert.equal(check({ validUntil: '2026-11-01' }), TOGETHER);
    assert.equal(check({ validUntilTimeZone: 'America/Phoenix' }), TOGETHER);
    assert.equal(check({ validUntil: '2026-11-01', validUntilTimeZone: null }), TOGETHER);
  });

  test('the date must be a real YYYY-MM-DD', () => {
    for (const validUntil of ['2026-02-30', '2027-02-29', '2026-13-01', '2026-11-1', '11/02/2026', '2026-11-02T00:00:00Z', '', 20261102, '0001-01-01']) {
      assert.equal(check({ validUntil, validUntilTimeZone: 'America/Phoenix' }), BAD_DATE, String(validUntil));
    }
  });

  test('the zone must be a non-empty string of at most 64 characters', () => {
    for (const validUntilTimeZone of ['', '   ', 'x'.repeat(65), 42, {}, []]) {
      assert.equal(check({ validUntil: '2026-11-01', validUntilTimeZone }), BAD_ZONE, JSON.stringify(validUntilTimeZone));
    }
  });

  test('an unresolvable zone is accepted with a warning and judged anywhere-on-Earth', () => {
    const warnings = [];
    console.warn = (...args) => warnings.push(args.join(' '));
    // AoE today at NOW (06:30Z) is Oct 2.
    assert.equal(check({ validUntil: '2026-10-02', validUntilTimeZone: 'Mars/Olympus' }), null);
    assert.equal(check({ validUntil: '2026-10-01', validUntilTimeZone: 'Mars/Olympus' }), PAST);
    assert.equal(check({ validUntil: '2026-11-01', validUntilTimeZone: 'x'.repeat(64) }), null);
    assert.equal(warnings.length, 3);
  });

  test('"past" is judged in the owner zone, not UTC (FA-039)', () => {
    // UTC is already Oct 3, Phoenix is still Oct 2: today is valid there.
    assert.equal(check({ validUntil: '2026-10-02', validUntilTimeZone: 'America/Phoenix' }), null);
    assert.equal(check({ validUntil: '2026-10-01', validUntilTimeZone: 'America/Phoenix' }), PAST);
    // Auckland is already Oct 3 (19:30 NZDT).
    assert.equal(check({ validUntil: '2026-10-02', validUntilTimeZone: 'Pacific/Auckland' }), PAST);
    assert.equal(check({ validUntil: '2026-10-03', validUntilTimeZone: 'Pacific/Auckland' }), null);
  });

  test('at most 400 days ahead of today in the zone', () => {
    assert.equal(check({ validUntil: addDays('2026-10-02', 365), validUntilTimeZone: 'America/Phoenix' }), null);
    assert.equal(check({ validUntil: addDays('2026-10-02', 400), validUntilTimeZone: 'America/Phoenix' }), null);
    assert.equal(check({ validUntil: addDays('2026-10-02', 401), validUntilTimeZone: 'America/Phoenix' }), FAR);
  });
});

// ── Route-level tests. Routes are ESM, so they load via dynamic import(). ──

let estimateRespondHandler;
let estimateViewHandler;
let estimateCreateLinkHandler;
let worker;
before(async () => {
  ({ estimateRespondHandler } = await import('../src/routes/estimate/respond.js'));
  ({ estimateViewHandler } = await import('../src/routes/estimate/view.js'));
  ({ estimateCreateLinkHandler } = await import('../src/routes/estimate/createLink.js'));
  worker = (await import('../src/index.js')).default;
});

// An in-memory jobs row behind a stubbed fetch (same shape as
// quoteOptions.test.cjs): GET reads, PATCH is the conditional write, POST is
// create-link's upsert.
function installDb(row) {
  const db = { row: clone(row), version: 1, gets: 0, patches: [] };
  db.row.updated_at = 'v1';
  global.fetch = async (url, init = {}) => {
    const u = new URL(String(url));
    const method = init.method || 'GET';
    if (u.pathname === '/auth/v1/user') return jsonRes({ id: db.row.user_id });
    if (u.pathname !== '/rest/v1/jobs') throw new Error(`unexpected fetch ${url}`);
    if (method === 'GET') {
      db.gets += 1;
      return jsonRes([clone(db.row)]);
    }
    if (method === 'PATCH') {
      const expected = (u.searchParams.get('updated_at') || '').replace(/^eq\./, '');
      const { data } = JSON.parse(init.body);
      db.patches.push({ expected, data });
      if (expected !== db.row.updated_at) return jsonRes([]);
      db.version += 1;
      db.row = { ...db.row, data, updated_at: `v${db.version}` };
      return jsonRes([{ data, updated_at: db.row.updated_at }]);
    }
    if (method === 'POST') {
      db.patches.push({ upsert: true, data: JSON.parse(init.body).data });
      return jsonRes([]);
    }
    throw new Error(`unexpected ${method} ${url}`);
  };
  return db;
}

function jsonRes(body, status = 200) {
  return { ok: status < 400, status, json: async () => body, text: async () => JSON.stringify(body) };
}

let ipCounter = 0;
function fakeC({ method = 'POST', body = {}, query = {}, headers = {} } = {}) {
  ipCounter += 1;
  const reqHeaders = { 'x-forwarded-for': `203.0.113.${ipCounter}`, 'user-agent': 'node-test', ...headers };
  return {
    env: { SUPABASE_URL: 'https://supa.test', SUPABASE_SERVICE_ROLE_KEY: 'srk', SUPABASE_ANON_KEY: 'anon' },
    header() {},
    req: {
      method,
      header: (k) => reqHeaders[String(k).toLowerCase()],
      query: (k) => query[k],
      json: async () => body,
    },
    json: (b, s) => ({ status: s, body: b }),
    body: (b, s) => ({ status: s, body: b }),
  };
}

const TOKEN = 'tok_abcdef1234567890';
const STALE = 'This estimate was just updated. Please reload the page to see the latest version.';

function jobRow(snapshot, approvalExtra = {}) {
  return {
    user_id: 'owner-1',
    data: {
      id: 'job-1', title: 'Panel upgrade', status: 'estimate_sent', customerId: 'cust-1',
      approval: { token: TOKEN, sentAt: '2026-10-02T12:00:00.000Z', snapshot, ...approvalExtra },
    },
  };
}

const approveBody = (extra = {}) => ({ jobId: 'job-1', token: TOKEN, decision: 'approved', signerName: 'Pat Lee', ...extra });
const declineBody = (extra = {}) => ({ jobId: 'job-1', token: TOKEN, decision: 'declined', declineReason: 'Too late', ...extra });

describe('create-link validity checks (§4.2)', () => {
  const linkC = (snapshot) => fakeC({ body: { jobId: 'job-1', snapshot }, headers: { authorization: 'Bearer good' } });

  test('every validation error is a 400 before any DB contact', async () => {
    at(NOW);
    const cases = [
      [{ ...legacySnapshot(), validUntil: '2026-11-01' }, 'Valid-until date and time zone must be sent together.'],
      [datedSnapshot('2026-02-30'), 'The valid-until date is invalid.'],
      [datedSnapshot('2026-11-01', ''), 'The valid-until time zone is invalid.'],
      [datedSnapshot('2026-10-01'), 'The valid-until date is in the past.'],
      [datedSnapshot(addDays('2026-10-02', 401)), 'The valid-until date is too far in the future.'],
    ];
    for (const [snapshot, error] of cases) {
      const db = installDb({ user_id: 'owner-1', data: { id: 'job-1' } });
      const res = await estimateCreateLinkHandler(linkC(snapshot));
      assert.equal(res.status, 400, error);
      assert.equal(res.body.error, error);
      assert.equal(db.gets, 0, error);
      assert.equal(db.patches.length, 0, error);
    }
  });

  test('a dated snapshot is stored as sent; today in the owner zone is accepted (FA-039)', async () => {
    at(NOW);
    const snapshot = datedSnapshot('2026-10-02'); // Phoenix today; UTC is already Oct 3
    const db = installDb({ user_id: 'owner-1', data: { id: 'job-1' } });
    const res = await estimateCreateLinkHandler(linkC(snapshot));
    assert.equal(res.status, 200);
    assert.equal(res.body.sentAt, new Date(NOW).toISOString(), 'sentAt reads the same clock');
    assert.deepEqual(db.patches[0].data.approval.snapshot, snapshot);
  });

  test('an unresolvable zone is stored unchanged (never rewritten)', async () => {
    at(NOW);
    console.warn = () => {};
    const snapshot = datedSnapshot('2026-11-02', 'Mars/Olympus');
    const db = installDb({ user_id: 'owner-1', data: { id: 'job-1' } });
    const res = await estimateCreateLinkHandler(linkC(snapshot));
    assert.equal(res.status, 200);
    assert.equal(db.patches[0].data.approval.snapshot.validUntilTimeZone, 'Mars/Olympus');
  });

  test('extension: an expired undecided link keeps its token and gets the new date', async () => {
    at(EXPIRED_AT);
    const db = installDb(jobRow(datedSnapshot('2026-11-02')));
    const res = await estimateCreateLinkHandler(linkC(datedSnapshot('2026-12-01')));
    assert.equal(res.status, 200);
    assert.equal(res.body.token, TOKEN);
    assert.equal(db.patches[0].data.approval.token, TOKEN);
    assert.equal(db.patches[0].data.approval.snapshot.validUntil, '2026-12-01');
  });

  test('undated snapshots are untouched by the new checks', async () => {
    at(NOW);
    const db = installDb({ user_id: 'owner-1', data: { id: 'job-1' } });
    const res = await estimateCreateLinkHandler(linkC(legacySnapshot()));
    assert.equal(res.status, 200);
    assert.deepEqual(db.patches[0].data.approval.snapshot, legacySnapshot());
  });
});

describe('view.expired (§4.3)', () => {
  const view = () => estimateViewHandler(fakeC({ method: 'GET', query: { j: 'job-1', t: TOKEN } }));

  test('undated: expired is false, and present', async () => {
    at(Date.parse('2099-01-01T00:00:00Z'));
    installDb(jobRow(legacySnapshot()));
    const res = await view();
    assert.equal(res.status, 200);
    assert.equal(res.body.expired, false);
    assert.equal('validUntil' in res.body, false);
  });

  test('dated: the date and zone arrive through the snapshot; expiry follows the owner zone', async () => {
    installDb(jobRow(datedSnapshot()));
    at(VALID_AT);
    let res = await view();
    assert.equal(res.body.expired, false);
    assert.equal(res.body.validUntil, '2026-11-02');
    assert.equal(res.body.validUntilTimeZone, 'America/Phoenix');
    assert.equal(res.body.snapshotDigest, snapshotDigest(datedSnapshot()));
    at(EXPIRED_AT);
    res = await view();
    assert.equal(res.body.expired, true);
  });

  test('declined and expired is expired; approved is never expired', async () => {
    at(EXPIRED_AT);
    installDb(jobRow(datedSnapshot(), { decision: 'declined', consentAt: 'then' }));
    assert.equal((await view()).body.expired, true);
    installDb(jobRow(datedSnapshot(), { decision: 'approved', consentAt: 'then', signerName: 'Pat Lee' }));
    assert.equal((await view()).body.expired, false);
  });

  test('an unknown zone uses anywhere-on-Earth', async () => {
    installDb(jobRow(datedSnapshot('2026-11-02', 'Mars/Olympus')));
    at(Date.parse('2026-11-03T11:59:59Z'));
    assert.equal((await view()).body.expired, false);
    at(Date.parse('2026-11-03T12:00:00Z'));
    assert.equal((await view()).body.expired, true);
  });
});

describe('respond after expiry (§4.4)', () => {
  const EXPIRED_BODY = {
    error: 'This estimate expired on November 2, 2026. Please ask Rector HVAC for an updated estimate.',
    code: 'estimate_expired',
    validUntil: '2026-11-02',
  };

  test('approve is 410 with code, self-contained message and date; nothing is written', async () => {
    at(EXPIRED_AT);
    // With the digest (new page) and without it (old page).
    for (const extra of [{ snapshotDigest: snapshotDigest(datedSnapshot()) }, {}]) {
      const db = installDb(jobRow(datedSnapshot()));
      const res = await estimateRespondHandler(fakeC({ body: approveBody(extra) }));
      assert.equal(res.status, 410);
      assert.deepEqual(res.body, EXPIRED_BODY);
      assert.equal(db.patches.length, 0);
    }
  });

  test('approve at 23:30 local on the date succeeds, stamped with the same clock', async () => {
    at(VALID_AT);
    const db = installDb(jobRow(datedSnapshot()));
    const res = await estimateRespondHandler(fakeC({ body: approveBody({ snapshotDigest: snapshotDigest(datedSnapshot()) }) }));
    assert.equal(res.status, 200);
    assert.equal(res.body.consentAt, new Date(VALID_AT).toISOString());
    assert.equal(db.row.data.approval.decision, 'approved');
  });

  test('decline after expiry is allowed', async () => {
    at(EXPIRED_AT);
    const db = installDb(jobRow(datedSnapshot()));
    const res = await estimateRespondHandler(fakeC({ body: declineBody({ snapshotDigest: snapshotDigest(datedSnapshot()) }) }));
    assert.equal(res.status, 200);
    assert.equal(res.body.decision, 'declined');
    assert.equal(db.row.data.approval.decision, 'declined');
    assert.equal(db.row.data.approval.consentAt, new Date(EXPIRED_AT).toISOString());
  });

  test('declined → re-approve after expiry is refused by the same check', async () => {
    at(EXPIRED_AT);
    const db = installDb(jobRow(datedSnapshot(), { decision: 'declined', consentAt: 'then' }));
    const res = await estimateRespondHandler(fakeC({ body: approveBody() }));
    assert.equal(res.status, 410);
    assert.equal(res.body.code, 'estimate_expired');
    assert.equal(db.patches.length, 0);
  });

  test('an already-approved estimate keeps returning its locked state', async () => {
    at(EXPIRED_AT);
    const db = installDb(jobRow(datedSnapshot(), { decision: 'approved', consentAt: '2026-10-05T00:00:00.000Z', signerName: 'Pat Lee' }));
    const res = await estimateRespondHandler(fakeC({ body: approveBody() }));
    assert.equal(res.status, 200);
    assert.equal(res.body.decision, 'approved');
    assert.equal(res.body.consentAt, '2026-10-05T00:00:00.000Z');
    assert.equal(db.patches.length, 0);
  });

  test('a stale digest is 409 before the 410', async () => {
    at(EXPIRED_AT);
    const db = installDb(jobRow(datedSnapshot()));
    const res = await estimateRespondHandler(fakeC({ body: approveBody({ snapshotDigest: 'f'.repeat(64) }) }));
    assert.equal(res.status, 409);
    assert.equal(res.body.error, STALE);
    assert.equal(db.patches.length, 0);
  });

  test('options: an expired estimate is 410 before "Please choose an option."', async () => {
    const snapshot = optionsSnapshot();
    const digest = snapshotDigest(snapshot);
    at(VALID_AT);
    installDb(jobRow(snapshot));
    let res = await estimateRespondHandler(fakeC({ body: approveBody({ snapshotDigest: digest }) }));
    assert.equal(res.status, 400);
    assert.equal(res.body.error, 'Please choose an option.');
    at(EXPIRED_AT);
    const db = installDb(jobRow(snapshot));
    res = await estimateRespondHandler(fakeC({ body: approveBody({ snapshotDigest: digest }) }));
    assert.equal(res.status, 410);
    assert.equal(res.body.code, 'estimate_expired');
    res = await estimateRespondHandler(fakeC({ body: approveBody({ snapshotDigest: digest, selection: { tierId: 'qt_good', addOnIds: [] } }) }));
    assert.equal(res.status, 410);
    assert.equal(db.patches.length, 0);
  });

  test('undated estimates are unaffected', async () => {
    at(Date.parse('2099-01-01T00:00:00Z'));
    const db = installDb(jobRow(legacySnapshot()));
    const res = await estimateRespondHandler(fakeC({ body: approveBody() }));
    assert.equal(res.status, 200);
    assert.equal(db.patches.length, 1);
  });
});

describe('POST /api/estimate/request-update route (§4.5)', () => {
  const ENV = { SUPABASE_URL: 'https://supa.test', SUPABASE_SERVICE_ROLE_KEY: 'srk', RESEND_API_KEY: 're_test' };
  let routeIp = 0;
  function call(method, body, ip) {
    routeIp += 1;
    const init = { method, headers: { 'content-type': 'application/json', 'x-forwarded-for': ip || `192.0.2.${routeIp}`, origin: 'https://gettradereadyapp.com' } };
    if (body !== undefined) init.body = JSON.stringify(body);
    return worker.fetch(new Request('https://w.test/api/estimate/request-update', init), ENV, { waitUntil() {} });
  }
  function installBackend(row) {
    const calls = { inserts: [], emails: [] };
    global.fetch = async (url, init = {}) => {
      const u = String(url);
      if (u.includes('/rest/v1/jobs')) return jsonRes([clone(row)]);
      if (u.includes('/rest/v1/bookingRequests')) {
        const posted = JSON.parse(init.body);
        calls.inserts.push(posted);
        return jsonRes(calls.inserts.length === 1 ? [posted] : [], 201);
      }
      if (u.includes('/rest/v1/settings')) return jsonRes([{ data: {} }]);
      if (u.includes('/auth/v1/admin/users/')) return jsonRes({ email: 'owner@example.test' });
      if (u.startsWith('https://api.resend.com/')) { calls.emails.push(JSON.parse(init.body)); return jsonRes({ id: 'e1' }); }
      throw new Error(`unexpected fetch ${u}`);
    };
    return calls;
  }

  test('is wired before the /api/estimate/:action catch-all, with the estimate CORS policy', async () => {
    const opt = await call('OPTIONS');
    assert.equal(opt.status, 200);
    assert.equal(opt.headers.get('access-control-allow-origin'), 'https://gettradereadyapp.com');
    assert.equal(opt.headers.get('access-control-allow-methods'), 'POST, OPTIONS');
    const get = await call('GET');
    assert.equal(get.status, 405);
  });

  test('reads Date.now for the expiry decision; notifies once; retries are silent successes', async () => {
    const calls = installBackend(jobRow(datedSnapshot()));
    const body = { jobId: 'job-1', token: TOKEN, note: 'Still interested', website: '' };
    at(VALID_AT);
    let res = await call('POST', body);
    assert.equal(res.status, 409);
    assert.equal((await res.json()).code, 'estimate_not_expired');
    at(EXPIRED_AT);
    res = await call('POST', body);
    assert.equal(res.status, 200);
    assert.deepEqual(await res.json(), { ok: true });
    res = await call('POST', body);
    assert.equal(res.status, 200);
    assert.equal(calls.inserts.length, 2);
    assert.equal(calls.inserts[0].id, calls.inserts[1].id);
    assert.equal(calls.inserts[0].id, `bkeu_${createHash('sha256').update(`job-1|${TOKEN}|2026-11-02`).digest('hex').slice(0, 20)}`);
    assert.equal(calls.inserts[0].data.createdAt, new Date(EXPIRED_AT).toISOString());
    assert.equal(calls.emails.length, 1, 'only the inserting call notifies');
    assert.equal(calls.emails[0].subject, 'Updated estimate requested: Pat Lee');
  });

  test('honeypot is a fake 200 with no reads or writes; the limiter allows 5 per IP', async () => {
    global.fetch = async (url) => { throw new Error(`no fetch expected: ${url}`); };
    const ip = '198.18.0.77';
    for (let i = 0; i < 5; i += 1) {
      const res = await call('POST', { jobId: 'job-1', token: TOKEN, website: 'http://spam.example' }, ip);
      assert.equal(res.status, 200);
      assert.deepEqual(await res.json(), { ok: true });
    }
    const limited = await call('POST', { jobId: 'job-1', token: TOKEN, website: 'x' }, ip);
    assert.equal(limited.status, 429);
  });

  test('a database failure is a 500, never a fake success', async () => {
    at(EXPIRED_AT);
    const originalError = console.error;
    console.error = () => {};
    try {
      global.fetch = async (url) => {
        if (String(url).includes('/rest/v1/jobs')) return jsonRes([clone(jobRow(datedSnapshot()))]);
        return jsonRes({ message: 'boom' }, 500);
      };
      const res = await call('POST', { jobId: 'job-1', token: TOKEN });
      assert.equal(res.status, 500);
      assert.deepEqual(await res.json(), { error: 'Database error' });
    } finally {
      console.error = originalError;
    }
  });
});
