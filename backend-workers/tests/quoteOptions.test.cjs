// Good/better/best quote options (Roadmap Phase 25) — Worker side.
// Spec: docs/superpowers/specs/2026-10-02-quote-options-design.md §2.2–§4, §8.
// The selection vectors are the shared parity fixture the Swift suite also
// loads; every vector (including jsOnly ones) runs here.

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { before, beforeEach, afterEach, describe, test } = require('node:test');

const {
  validateSnapshotOptions,
  snapshotDigest,
  resolveSelection,
  isResolvedSelection,
} = require('../lib/estimate/quoteOptions.js');

const FIXTURE_PATH = path.join(__dirname, '../../native/QuoteOptionsTests/Fixtures/quote-selection-vectors.json');
const fixture = JSON.parse(fs.readFileSync(FIXTURE_PATH, 'utf8'));

const clone = (v) => JSON.parse(JSON.stringify(v));

// A full snapshot as the device sends it: top level mirrors the recommended
// tier (spec §2.2 compatibility rule), options carry every tier.
function optionsSnapshot(name = 'main') {
  const options = clone(fixture.snapshots[name]);
  const recommended = options.tiers.find((t) => t.id === options.recommendedTierId);
  return {
    businessName: 'Rector HVAC',
    customerName: 'Pat Lee',
    jobTitle: 'AC replacement',
    lineItems: clone(recommended.lineItems),
    total: recommended.total,
    currency: 'USD',
    options,
  };
}

const legacySnapshot = () => ({
  businessName: 'Rector HVAC',
  customerName: 'Pat Lee',
  jobTitle: 'Panel upgrade',
  lineItems: [{ label: 'Labor (2 hrs @ $100/hr)', amount: 200 }],
  total: 200,
  currency: 'USD',
});

describe('resolveSelection — shared parity vectors', () => {
  test('the fixture has vectors, including jsOnly ones', () => {
    assert.ok(fixture.vectors.length >= 10);
    assert.ok(fixture.vectors.some((v) => v.jsOnly));
  });

  for (const vector of fixture.vectors) {
    test(`${vector.jsOnly ? '[jsOnly] ' : ''}${vector.name}`, () => {
      const snapshot = { options: fixture.snapshots[vector.snapshot] };
      const result = resolveSelection(snapshot, clone(vector.input));
      const { expect } = vector;
      if (!expect.ok) {
        assert.deepEqual(result, { error: expect.error });
        return;
      }
      assert.equal(result.error, undefined);
      const { selection } = result;
      assert.equal(selection.tierId, vector.input.tierId);
      assert.equal(selection.tierName, expect.tierName);
      assert.deepEqual(selection.addOnIds, expect.addOnIds);
      assert.equal(selection.total, expect.total);
      assert.deepEqual(selection.lineItems, expect.lineItems);
      const byId = new Map(fixture.snapshots[vector.snapshot].addOns.map((a) => [a.id, a]));
      assert.deepEqual(
        selection.addOns,
        expect.addOnIds.map((id) => ({ id, label: byId.get(id).label, amount: byId.get(id).amount }))
      );
      assert.equal(isResolvedSelection(selection), true);
    });
  }

  test('the add-on cap applies to the raw list, before de-duplication', () => {
    const snapshot = { options: fixture.snapshots.main };
    const ten = Array(10).fill('qa_haul');
    assert.deepEqual(resolveSelection(snapshot, { tierId: 'qt_good', addOnIds: ten }).selection.addOnIds, ['qa_haul']);
    assert.deepEqual(resolveSelection(snapshot, { tierId: 'qt_good', addOnIds: [...ten, 'qa_haul'] }), { error: 'invalid_addons' });
  });

  test('each amount is rounded to whole cents before summing', () => {
    const snapshot = { options: {
      recommendedTierId: 't1',
      tiers: [
        { id: 't1', name: 'Tiny', lineItems: [], total: 0.01 },
        { id: 't2', name: 'Sub-cent engine total', lineItems: [], total: 1850.499 },
      ],
      addOns: [{ id: 'a1', label: 'Fourteen cents', amount: 0.14 }],
    } };
    // Unrounded cents would give 0.15000000000000002.
    assert.equal(resolveSelection(snapshot, { tierId: 't1', addOnIds: ['a1'] }).selection.total, 0.15);
    assert.equal(resolveSelection(snapshot, { tierId: 't2', addOnIds: [] }).selection.total, 1850.5);
  });

  test('a missing or malformed input is "choose an option"', () => {
    const snapshot = { options: fixture.snapshots.main };
    for (const input of [undefined, null, 'qt_good', [], { tierId: 7 }]) {
      assert.deepEqual(resolveSelection(snapshot, input), { error: 'choose_option' });
    }
  });

  test('the output carries only label/amount line fields and never mutates the snapshot', () => {
    const snapshot = { options: clone(fixture.snapshots.main) };
    snapshot.options.tiers[0].lineItems[0].internal = 'cost policy';
    const before = clone(snapshot);
    const { selection } = resolveSelection(snapshot, { tierId: 'qt_good', addOnIds: ['qa_ws'] });
    assert.deepEqual(Object.keys(selection.lineItems[0]).sort(), ['amount', 'label']);
    assert.deepEqual(snapshot, before);
  });
});

describe('validateSnapshotOptions', () => {
  test('accepts the fixture snapshots, absent add-ons, and omitted descriptions', () => {
    assert.equal(validateSnapshotOptions(optionsSnapshot('main')), null);
    assert.equal(validateSnapshotOptions(optionsSnapshot('floaty')), null);
    const noAddOns = optionsSnapshot();
    delete noAddOns.options.addOns;
    assert.equal(validateSnapshotOptions(noAddOns), null);
    const emptyAddOns = optionsSnapshot();
    emptyAddOns.options.addOns = [];
    assert.equal(validateSnapshotOptions(emptyAddOns), null);
    const zeroTotal = optionsSnapshot();
    zeroTotal.options.tiers[0].total = 0;
    zeroTotal.options.tiers[0].lineItems = [];
    assert.equal(validateSnapshotOptions(zeroTotal), null);
  });

  test('accepts exactly 2 and 3 tiers and 10 add-ons', () => {
    const two = optionsSnapshot();
    two.options.tiers = two.options.tiers.slice(1);
    assert.equal(validateSnapshotOptions(two), null);
    const ten = optionsSnapshot();
    ten.options.addOns = Array.from({ length: 10 }, (_, i) => ({ id: `qa_${i}`, label: `Add-on ${i}`, amount: 10 }));
    assert.equal(validateSnapshotOptions(ten), null);
  });

  test('caps count UTF-16 units, like the native editor (utf16.count)', () => {
    const emoji = optionsSnapshot();
    emoji.options.tiers[0].name = '👍'.repeat(30); // 60 UTF-16 units
    assert.equal(validateSnapshotOptions(emoji), null);
    emoji.options.tiers[0].name = `${'👍'.repeat(30)}x`;
    assert.match(validateSnapshotOptions(emoji), /Option names/);
  });

  const rejects = [
    ['options is not an object', (s) => { s.options = []; }],
    ['options is a string', (s) => { s.options = 'tiers'; }],
    ['one tier', (s) => { s.options.tiers = s.options.tiers.slice(0, 1); s.options.recommendedTierId = s.options.tiers[0].id; }],
    ['four tiers', (s) => { s.options.tiers.push({ ...clone(s.options.tiers[0]), id: 'qt_fourth' }); }],
    ['tiers missing', (s) => { delete s.options.tiers; }],
    ['duplicate tier ids', (s) => { s.options.tiers[1].id = s.options.tiers[0].id; s.options.recommendedTierId = s.options.tiers[0].id; }],
    ['empty tier id', (s) => { s.options.tiers[0].id = ''; }],
    ['negative tier total', (s) => { s.options.tiers[0].total = -1; }],
    ['non-numeric tier total', (s) => { s.options.tiers[0].total = '1200'; }],
    ['non-finite tier total', (s) => { s.options.tiers[0].total = Infinity; }],
    ['negative line amount', (s) => { s.options.tiers[1].lineItems[0].amount = -0.01; }],
    ['line items not an array', (s) => { s.options.tiers[1].lineItems = {}; }],
    ['line label not a string', (s) => { s.options.tiers[1].lineItems[0].label = 5; }],
    ['unknown recommendedTierId', (s) => { s.options.recommendedTierId = 'qt_nope'; }],
    ['missing recommendedTierId', (s) => { delete s.options.recommendedTierId; }],
    ['empty tier name', (s) => { s.options.tiers[0].name = '   '; }],
    ['tier name over 60', (s) => { s.options.tiers[0].name = 'n'.repeat(61); }],
    ['tier description over 300', (s) => { s.options.tiers[0].description = 'd'.repeat(301); }],
    ['tier description not a string', (s) => { s.options.tiers[0].description = 12; }],
    ['eleven add-ons', (s) => {
      s.options.addOns = Array.from({ length: 11 }, (_, i) => ({ id: `qa_${i}`, label: `Add-on ${i}`, amount: 10 }));
    }],
    ['add-ons not an array', (s) => { s.options.addOns = { id: 'qa_haul' }; }],
    ['duplicate add-on ids', (s) => { s.options.addOns[1].id = s.options.addOns[0].id; }],
    ['add-on amount zero', (s) => { s.options.addOns[0].amount = 0; }],
    ['add-on amount negative', (s) => { s.options.addOns[0].amount = -5; }],
    ['add-on amount over 1,000,000', (s) => { s.options.addOns[0].amount = 1_000_000.01; }],
    ['add-on amount not a number', (s) => { s.options.addOns[0].amount = '150'; }],
    ['empty add-on label', (s) => { s.options.addOns[0].label = ''; }],
    ['add-on label over 80', (s) => { s.options.addOns[0].label = 'l'.repeat(81); }],
    ['add-on description over 200', (s) => { s.options.addOns[0].description = 'd'.repeat(201); }],
  ];
  for (const [name, mutate] of rejects) {
    test(`rejects: ${name}`, () => {
      const snapshot = optionsSnapshot();
      mutate(snapshot);
      const error = validateSnapshotOptions(snapshot);
      assert.equal(typeof error, 'string');
      assert.ok(error.length > 0);
    });
  }

  test('boundary lengths are accepted', () => {
    const s = optionsSnapshot();
    s.options.tiers[0].name = 'n'.repeat(60);
    s.options.tiers[0].description = 'd'.repeat(300);
    s.options.addOns[0].label = 'l'.repeat(80);
    s.options.addOns[0].description = 'd'.repeat(200);
    s.options.addOns[0].amount = 1_000_000;
    assert.equal(validateSnapshotOptions(s), null);
  });
});

describe('snapshotDigest', () => {
  // Rebuilds every object with its keys in reverse insertion order.
  function reverseKeys(v) {
    if (Array.isArray(v)) return v.map(reverseKeys);
    if (v && typeof v === 'object') {
      const out = {};
      for (const k of Object.keys(v).reverse()) out[k] = reverseKeys(v[k]);
      return out;
    }
    return v;
  }

  // Every path to a numeric leaf, e.g. ['options','tiers',1,'lineItems',0,'amount'].
  function numericPaths(v, prefix = []) {
    if (typeof v === 'number') return [prefix];
    if (v && typeof v === 'object') {
      return Object.keys(v).flatMap((k) => numericPaths(v[k], [...prefix, Array.isArray(v) ? Number(k) : k]));
    }
    return [];
  }

  test('is SHA-256 hex and stable across clones', () => {
    const s = optionsSnapshot();
    assert.match(snapshotDigest(s), /^[0-9a-f]{64}$/);
    assert.equal(snapshotDigest(s), snapshotDigest(clone(s)));
  });

  test('is independent of object key order at every depth', () => {
    const s = optionsSnapshot();
    const reversed = reverseKeys(s);
    assert.notEqual(JSON.stringify(reversed), JSON.stringify(s));
    assert.equal(snapshotDigest(reversed), snapshotDigest(s));
  });

  test('changes when any amount changes', () => {
    const s = optionsSnapshot();
    const base = snapshotDigest(s);
    const paths = numericPaths(s);
    assert.ok(paths.length >= 15);
    for (const p of paths) {
      const mutated = clone(s);
      let node = mutated;
      for (const k of p.slice(0, -1)) node = node[k];
      node[p[p.length - 1]] += 0.01;
      assert.notEqual(snapshotDigest(mutated), base, `amount at ${p.join('.')}`);
    }
  });

  test('changes when array order, a label, or the recommended tier changes', () => {
    const s = optionsSnapshot();
    const base = snapshotDigest(s);
    const reordered = clone(s);
    reordered.options.addOns.reverse();
    assert.notEqual(snapshotDigest(reordered), base);
    const relabeled = clone(s);
    relabeled.options.tiers[0].name = 'Repair only';
    assert.notEqual(snapshotDigest(relabeled), base);
    const recommended = clone(s);
    recommended.options.recommendedTierId = 'qt_best';
    assert.notEqual(snapshotDigest(recommended), base);
  });

  test('treats undefined members like JSON does', () => {
    const s = legacySnapshot();
    assert.equal(snapshotDigest({ ...s, extra: undefined }), snapshotDigest(s));
  });
});

// ---------------------------------------------------------------------------
// Route-level tests. Routes are ESM, so they load via dynamic import().

let nextApproval;
let estimateRespondHandler;
let estimateViewHandler;
let estimateCreateLinkHandler;

before(async () => {
  ({ nextApproval, estimateRespondHandler } = await import('../src/routes/estimate/respond.js'));
  ({ estimateViewHandler } = await import('../src/routes/estimate/view.js'));
  ({ estimateCreateLinkHandler } = await import('../src/routes/estimate/createLink.js'));
});

const META = { consentAt: '2026-10-02T15:00:00.000Z', ip: '203.0.113.7', userAgent: 'customer-browser' };

describe('nextApproval', () => {
  const pending = () => ({ token: 'tok_1234567890abcdef', sentAt: '2026-10-01T12:00:00.000Z', snapshot: optionsSnapshot(), futureField: { kept: true } });
  const resolved = () => resolveSelection(optionsSnapshot(), { tierId: 'qt_best', addOnIds: ['qa_ws'] }).selection;

  test('approve with a resolved selection stores it', () => {
    const selection = resolved();
    const next = nextApproval(pending(), { decision: 'approved', signerName: 'Pat Lee', selection }, META);
    assert.equal(next.decision, 'approved');
    assert.deepEqual(next.selection, selection);
    assert.deepEqual(next.futureField, { kept: true });
  });

  test('a raw, unresolved request selection is never stored', () => {
    const next = nextApproval(pending(), { decision: 'approved', signerName: 'Pat Lee', selection: { tierId: 'qt_best', addOnIds: ['qa_ws'] } }, META);
    assert.equal('selection' in next, false);
  });

  test('declines never store a selection', () => {
    const next = nextApproval(pending(), { decision: 'declined', declineReason: 'too much', selection: resolved() }, META);
    assert.equal(next.decision, 'declined');
    assert.equal('selection' in next, false);
  });

  test('change-order-style calls (no selection) are unchanged from before', () => {
    const existing = { token: 'co_token_1234567890', sentAt: 'x' };
    assert.deepEqual(nextApproval(existing, { decision: 'approved', signerName: 'Pat' }, META), {
      token: 'co_token_1234567890', sentAt: 'x', decision: 'approved', consentAt: META.consentAt,
      signerName: 'Pat', declineReason: undefined, ip: META.ip, userAgent: META.userAgent,
    });
    const declined = nextApproval(existing, { decision: 'declined', declineReason: 'no' }, META);
    assert.equal('selection' in declined, false);
    assert.equal(declined.declineReason, 'no');
  });

  test('the approved lock returns the same reference, selection or not', () => {
    const approved = { ...pending(), decision: 'approved', selection: resolved() };
    assert.equal(nextApproval(approved, { decision: 'approved', signerName: 'X', selection: resolved() }, META), approved);
    assert.equal(nextApproval(approved, { decision: 'declined' }, META), approved);
  });
});

// A fake PostgREST `jobs` table behind global.fetch. `conflicts` makes that
// many conditional PATCHes lose to a simulated concurrent writer, which runs
// `onConflict(row)` (e.g. a device push) before the version moves on.
function installDb(row, { conflicts = 0, onConflict } = {}) {
  const db = { row: clone(row), version: 1, gets: 0, patches: [], conflicts };
  db.row.updated_at = 'v1';
  global.fetch = async (url, init = {}) => {
    const u = new URL(String(url));
    const method = init.method || 'GET';
    if (u.pathname === '/auth/v1/user') return jsonRes({ id: db.row.user_id });
    if (u.pathname !== '/rest/v1/jobs') throw new Error(`unexpected fetch ${url}`);
    if (method === 'GET') {
      db.gets += 1;
      return jsonRes(db.row ? [clone(db.row)] : []);
    }
    if (method === 'PATCH') {
      const expected = (u.searchParams.get('updated_at') || '').replace(/^eq\./, '');
      const { data } = JSON.parse(init.body);
      db.patches.push({ expected, data });
      if (db.conflicts > 0) {
        db.conflicts -= 1;
        if (onConflict) onConflict(db.row);
        db.version += 1;
        db.row.updated_at = `v${db.version}`;
        return jsonRes([]);
      }
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
  const reqHeaders = { 'x-forwarded-for': `198.51.100.${ipCounter}`, 'user-agent': 'node-test', ...headers };
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

function jobRow(snapshot, approvalExtra = {}) {
  return {
    user_id: 'owner-1',
    data: { id: 'job-1', title: 'AC replacement', status: 'estimate_sent', approval: { token: TOKEN, sentAt: '2026-10-01T12:00:00.000Z', snapshot, ...approvalExtra } },
  };
}

function respondBody(extra = {}) {
  return { jobId: 'job-1', token: TOKEN, decision: 'approved', signerName: 'Pat Lee', ...extra };
}

describe('estimate respond handler', () => {
  let originalFetch;
  beforeEach(() => { originalFetch = global.fetch; });
  afterEach(() => { global.fetch = originalFetch; });

  test('legacy approve without a digest still works (conditional write on the read version)', async () => {
    const db = installDb(jobRow(legacySnapshot()));
    const res = await estimateRespondHandler(fakeC({ body: respondBody() }));
    assert.equal(res.status, 200);
    assert.equal(res.body.ok, true);
    assert.equal(res.body.decision, 'approved');
    assert.equal(res.body.selection, undefined);
    assert.equal(db.patches.length, 1);
    assert.equal(db.patches[0].expected, 'v1');
    const written = db.row.data.approval;
    assert.equal(written.decision, 'approved');
    assert.equal(written.signerName, 'Pat Lee');
    assert.equal('selection' in written, false);
    assert.equal(db.row.data.title, 'AC replacement');
  });

  test('legacy: a sent digest is checked; a matching one passes', async () => {
    let db = installDb(jobRow(legacySnapshot()));
    let res = await estimateRespondHandler(fakeC({ body: respondBody({ snapshotDigest: 'f'.repeat(64) }) }));
    assert.equal(res.status, 409);
    assert.equal(res.body.error, 'This estimate was just updated. Please reload the page to see the latest version.');
    assert.equal(db.patches.length, 0);

    db = installDb(jobRow(legacySnapshot()));
    res = await estimateRespondHandler(fakeC({ body: respondBody({ snapshotDigest: snapshotDigest(legacySnapshot()) }) }));
    assert.equal(res.status, 200);
    assert.equal(db.patches.length, 1);
  });

  test('legacy: a selection in the body is ignored', async () => {
    const db = installDb(jobRow(legacySnapshot()));
    const res = await estimateRespondHandler(fakeC({ body: respondBody({ selection: { tierId: 'qt_good' } }) }));
    assert.equal(res.status, 200);
    assert.equal('selection' in db.row.data.approval, false);
  });

  test('options: the digest is required and must match', async () => {
    const snapshot = optionsSnapshot();
    for (const snapshotDigestValue of [undefined, null, 'f'.repeat(64), 42]) {
      const db = installDb(jobRow(snapshot));
      const res = await estimateRespondHandler(fakeC({ body: respondBody({
        snapshotDigest: snapshotDigestValue, selection: { tierId: 'qt_good', addOnIds: [] },
      }) }));
      assert.equal(res.status, 409, String(snapshotDigestValue));
      assert.equal(res.body.error, 'This estimate was just updated. Please reload the page to see the latest version.');
      assert.equal(db.patches.length, 0);
    }
  });

  test('options: approve requires a tier (400) and valid add-ons (400)', async () => {
    const snapshot = optionsSnapshot();
    const digest = snapshotDigest(snapshot);
    const cases = [
      [undefined, 'Please choose an option.'],
      [{ addOnIds: [] }, 'Please choose an option.'],
      [{ tierId: 'qt_nope', addOnIds: [] }, 'Please choose an option.'],
      [{ tierId: 'qt_good', addOnIds: ['qa_nope'] }, 'Invalid add-on selection.'],
      [{ tierId: 'qt_good', addOnIds: 'qa_haul' }, 'Invalid add-on selection.'],
      [{ tierId: 'qt_good', addOnIds: Array(11).fill('qa_haul') }, 'Invalid add-on selection.'],
    ];
    for (const [selection, error] of cases) {
      const db = installDb(jobRow(snapshot));
      const res = await estimateRespondHandler(fakeC({ body: respondBody({ snapshotDigest: digest, selection }) }));
      assert.deepEqual(res, { status: 400, body: { error } }, JSON.stringify(selection));
      assert.equal(db.patches.length, 0);
    }
  });

  test('options: approve stores the resolved selection and returns it', async () => {
    const snapshot = optionsSnapshot();
    const db = installDb(jobRow(snapshot));
    const res = await estimateRespondHandler(fakeC({ body: respondBody({
      snapshotDigest: snapshotDigest(snapshot),
      selection: { tierId: 'qt_best', addOnIds: ['qa_ws', 'qa_haul', 'qa_ws'] },
    }) }));
    assert.equal(res.status, 200);
    const expected = resolveSelection(snapshot, { tierId: 'qt_best', addOnIds: ['qa_haul', 'qa_ws'] }).selection;
    assert.equal(expected.total, 3199.98);
    assert.deepEqual(db.row.data.approval.selection, expected);
    assert.deepEqual(res.body.selection, expected);
    assert.equal(db.row.data.approval.decision, 'approved');
    assert.deepEqual(db.row.data.approval.snapshot, snapshot, 'the frozen snapshot is untouched');
  });

  test('options: decline needs the digest but no selection, and stores none', async () => {
    const snapshot = optionsSnapshot();
    const db = installDb(jobRow(snapshot));
    const res = await estimateRespondHandler(fakeC({ body: respondBody({
      decision: 'declined', signerName: '', declineReason: 'Too much', snapshotDigest: snapshotDigest(snapshot),
    }) }));
    assert.equal(res.status, 200);
    assert.equal(res.body.decision, 'declined');
    assert.equal(db.row.data.approval.decision, 'declined');
    assert.equal('selection' in db.row.data.approval, false);
  });

  test('a conflict re-reads, re-merges onto the newer row, and succeeds', async () => {
    const snapshot = optionsSnapshot();
    const db = installDb(jobRow(snapshot), {
      conflicts: 1,
      onConflict: (row) => { row.data = { ...row.data, notes: 'edited on device' }; },
    });
    const res = await estimateRespondHandler(fakeC({ body: respondBody({
      snapshotDigest: snapshotDigest(snapshot), selection: { tierId: 'qt_good' },
    }) }));
    assert.equal(res.status, 200);
    assert.equal(db.gets, 2);
    assert.equal(db.patches.length, 2);
    assert.deepEqual(db.patches.map((p) => p.expected), ['v1', 'v2']);
    assert.equal(db.row.data.notes, 'edited on device', 'the concurrent write survives');
    assert.equal(db.row.data.approval.selection.tierId, 'qt_good');
    assert.equal(db.row.data.approval.selection.total, 1200);
  });

  test('a conflict caused by a re-send is re-validated and refused as stale', async () => {
    const snapshot = optionsSnapshot();
    const db = installDb(jobRow(snapshot), {
      conflicts: 1,
      onConflict: (row) => {
        const resent = clone(snapshot);
        resent.options.tiers[0].total = 1300;
        row.data = { ...row.data, approval: { ...row.data.approval, snapshot: resent } };
      },
    });
    const res = await estimateRespondHandler(fakeC({ body: respondBody({
      snapshotDigest: snapshotDigest(snapshot), selection: { tierId: 'qt_good' },
    }) }));
    assert.equal(res.status, 409);
    assert.equal(res.body.error, 'This estimate was just updated. Please reload the page to see the latest version.');
    assert.equal(db.patches.length, 1);
  });

  test('three conflicts → 409 "Please try again in a moment."', async () => {
    const db = installDb(jobRow(legacySnapshot()), { conflicts: 3 });
    const res = await estimateRespondHandler(fakeC({ body: respondBody() }));
    assert.deepEqual(res, { status: 409, body: { error: 'Please try again in a moment.' } });
    assert.equal(db.gets, 3);
    assert.equal(db.patches.length, 3);
    assert.equal(db.row.data.approval.decision, undefined);
  });

  test('the approved lock answers without writing', async () => {
    const snapshot = optionsSnapshot();
    const selection = resolveSelection(snapshot, { tierId: 'qt_better', addOnIds: [] }).selection;
    const db = installDb(jobRow(snapshot, { decision: 'approved', consentAt: '2026-10-01T13:00:00.000Z', signerName: 'Pat Lee', selection }));
    const res = await estimateRespondHandler(fakeC({ body: respondBody({
      decision: 'declined', signerName: '', snapshotDigest: snapshotDigest(snapshot),
    }) }));
    assert.equal(res.status, 200);
    assert.equal(res.body.decision, 'approved');
    assert.equal(res.body.consentAt, '2026-10-01T13:00:00.000Z');
    assert.deepEqual(res.body.selection, selection);
    assert.equal(db.patches.length, 0);

    const legacy = installDb(jobRow(legacySnapshot(), { decision: 'approved', consentAt: 'then' }));
    const again = await estimateRespondHandler(fakeC({ body: respondBody() }));
    assert.equal(again.status, 200);
    assert.equal(legacy.patches.length, 0);
  });

  test('bad token → 404 before any digest or selection check', async () => {
    const db = installDb(jobRow(optionsSnapshot()));
    const res = await estimateRespondHandler(fakeC({ body: respondBody({ token: 'tok_wrong_0000000000' }) }));
    assert.equal(res.status, 404);
    assert.equal(db.patches.length, 0);
  });
});

describe('estimate view handler', () => {
  let originalFetch;
  beforeEach(() => { originalFetch = global.fetch; });
  afterEach(() => { global.fetch = originalFetch; });

  test('adds the snapshot digest; selection only once approved', async () => {
    const snapshot = optionsSnapshot();
    installDb(jobRow(snapshot));
    const res = await estimateViewHandler(fakeC({ method: 'GET', query: { j: 'job-1', t: TOKEN } }));
    assert.equal(res.status, 200);
    assert.equal(res.body.snapshotDigest, snapshotDigest(snapshot));
    assert.deepEqual(res.body.options, snapshot.options);
    assert.equal(res.body.decision, null);
    assert.equal('selection' in res.body, false);

    const selection = resolveSelection(snapshot, { tierId: 'qt_good', addOnIds: ['qa_haul'] }).selection;
    installDb(jobRow(snapshot, { decision: 'approved', consentAt: 'then', signerName: 'Pat', selection }));
    const approved = await estimateViewHandler(fakeC({ method: 'GET', query: { j: 'job-1', t: TOKEN } }));
    assert.deepEqual(approved.body.selection, selection);
  });

  test('legacy view keeps its keys and gains only the digest and expired flag', async () => {
    installDb(jobRow(legacySnapshot()));
    const res = await estimateViewHandler(fakeC({ method: 'GET', query: { j: 'job-1', t: TOKEN } }));
    assert.deepEqual(Object.keys(res.body).sort(), [
      ...Object.keys(legacySnapshot()), 'consentAt', 'decision', 'expired', 'signatureRequired', 'signerName', 'snapshotDigest',
    ].sort());
    assert.equal(res.body.expired, false);
  });
});

describe('estimate create-link handler', () => {
  let originalFetch;
  beforeEach(() => { originalFetch = global.fetch; });
  afterEach(() => { global.fetch = originalFetch; });

  const linkC = (snapshot) => fakeC({ body: { jobId: 'job-1', snapshot }, headers: { authorization: 'Bearer good' } });

  test('invalid options → 400 with the validation message, no DB contact', async () => {
    const db = installDb({ user_id: 'owner-1', data: { id: 'job-1' } });
    const snapshot = optionsSnapshot();
    snapshot.options.tiers = snapshot.options.tiers.slice(0, 1);
    const res = await estimateCreateLinkHandler(linkC(snapshot));
    assert.equal(res.status, 400);
    assert.equal(res.body.error, validateSnapshotOptions(snapshot));
    assert.equal(db.gets, 0);
  });

  test('valid options and legacy snapshots are stored as sent', async () => {
    for (const snapshot of [optionsSnapshot(), legacySnapshot()]) {
      const db = installDb({ user_id: 'owner-1', data: { id: 'job-1' } });
      const res = await estimateCreateLinkHandler(linkC(snapshot));
      assert.equal(res.status, 200);
      assert.equal(db.patches.length, 1);
      assert.deepEqual(db.patches[0].data.approval.snapshot, snapshot);
    }
  });
});
