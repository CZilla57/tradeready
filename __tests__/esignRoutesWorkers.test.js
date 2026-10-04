/** @jest-environment node */
// __tests__/esignRoutesWorkers.test.js
// Roadmap Phase 19 — e-signatures with audit trail, route level (spec
// docs/superpowers/specs/2026-10-03-esignature-upgrade-design.md §3.5, §6).
//
// The Worker handlers run against an in-memory PostgREST stand-in (jobs,
// signature_records, signature_events, auth) and a stubbed Resend. The seal
// key pair is generated per run; no private key exists in the repo.
// Server-precondition level only: the database's own guarantees (unique
// token hash, append-only trigger, cascade, RLS) are proved separately by
// supabase/verify/esign_records.sh.

const { createHash } = require('node:crypto');
const { estimateRespondHandler } = require('../backend-workers/src/routes/estimate/respond.js');
const { estimateViewHandler } = require('../backend-workers/src/routes/estimate/view.js');
const { estimateCreateLinkHandler } = require('../backend-workers/src/routes/estimate/createLink.js');
const { changeRespondHandler } = require('../backend-workers/src/routes/estimate/changeRespond.js');
const { changeViewHandler } = require('../backend-workers/src/routes/estimate/changeView.js');
const { esignCopyHandler } = require('../backend-workers/src/routes/esign/copy.js');
const { esignPreviewHandler } = require('../backend-workers/src/routes/esign/preview.js');
const { esignVerifyHandler } = require('../backend-workers/src/routes/esign/verify.js');
const { esignPublicKeysHandler } = require('../backend-workers/src/routes/esign/publicKeys.js');
const { esignRecordHandler } = require('../backend-workers/src/routes/esign/record.js');
const { snapshotDigest, canonicalJson } = require('../backend-workers/lib/estimate/quoteOptions.js');
const { verifySeal } = require('../backend-workers/lib/esign/seal.js');
const { signingTexts } = require('../backend-workers/lib/esign/texts.js');

const sha = (s) => createHash('sha256').update(s, 'utf8').digest('hex');
const clone = (v) => JSON.parse(JSON.stringify(v));
const OWNER = '11111111-2222-4333-8444-555555555555';
const TOKEN = 'tok_esign_0123456789abcdef';
const CO_TOKEN = 'tok_change_0123456789';
// The edge address is unique per request (the routes rate-limit by it);
// helpers expose the one each request used as `edgeIp`.
const EDGE_IP = '203.0.113.9';
const SPOOF_IP = '6.6.6.6';
const NOW = Date.UTC(2026, 9, 3, 18, 0, 0); // 2026-10-03 11:00 in Phoenix

let SEAL_ENV;
beforeAll(async () => {
  const pair = await crypto.subtle.generateKey({ name: 'Ed25519' }, true, ['sign', 'verify']);
  const pkcs8 = Buffer.from(await crypto.subtle.exportKey('pkcs8', pair.privateKey)).toString('base64');
  const raw = Buffer.from(await crypto.subtle.exportKey('raw', pair.publicKey)).toString('base64');
  SEAL_ENV = { ESIGN_SEAL_PRIVATE_KEY: pkcs8, ESIGN_SEAL_KEY_ID: 'k-test', ESIGN_SEAL_PUBLIC_KEYS: JSON.stringify({ 'k-test': raw }) };
});

beforeEach(() => {
  jest.spyOn(Date, 'now').mockReturnValue(NOW);
  jest.spyOn(console, 'error').mockImplementation(() => {});
});
afterEach(() => {
  delete global.fetch;
  jest.restoreAllMocks();
});

// ── fixtures ─────────────────────────────────────────────────────────────

function esignSnapshot(extra = {}) {
  return {
    businessName: 'Rector HVAC',
    customerName: 'Pat Lee',
    jobTitle: 'Panel upgrade',
    lineItems: [{ label: 'Labor', amount: 600 }, { label: 'Panel', amount: 900 }],
    total: 1500,
    currency: 'USD',
    scope: 'Replace the 100A panel with a 200A panel.',
    businessContact: { phone: '(602) 555-0143', email: 'office@rectorhvac.test' },
    signature: { drawPad: true },
    esign: { version: 1, timeZone: 'America/Phoenix' },
    ...extra,
  };
}
const legacySnapshot = () => ({
  businessName: 'Rector HVAC', customerName: 'Pat Lee', jobTitle: 'Panel upgrade',
  lineItems: [{ label: 'Labor', amount: 600 }], total: 600, currency: 'USD',
});
const DRAWN = { w: 600, h: 200, strokes: [[[10, 100, 0], [200, 50, 120], [400, 150, 240]]] };

function jobRow({ snapshot = esignSnapshot(), approval = {}, changeOrders } = {}) {
  const data = {
    id: 'job-1', title: 'Panel upgrade', status: 'estimate_sent',
    approval: { token: TOKEN, sentAt: '2026-10-02T12:00:00.000Z', snapshot, ...approval },
  };
  if (changeOrders) data.changeOrders = changeOrders;
  return { id: 'job-1', user_id: OWNER, data };
}
const coSnapshot = () => ({
  businessName: 'Rector HVAC', customerName: 'Pat Lee', jobTitle: 'Panel upgrade',
  lineItems: [{ label: 'Extra circuit', amount: 450 }], total: 450, currency: 'USD',
  scope: 'Add a 20A circuit to the garage.', esign: { version: 1 },
});
const changeOrder = (extra = {}) => ({
  id: 'co-1', description: 'Add a 20A circuit to the garage.', amount: 450,
  approval: { token: CO_TOKEN, sentAt: '2026-10-02T12:00:00.000Z', snapshot: coSnapshot() }, ...extra,
});

// ── in-memory PostgREST + Resend ─────────────────────────────────────────

function jsonRes(body, status = 200) {
  return { ok: status < 400, status, json: async () => body, text: async () => JSON.stringify(body) };
}
const eqParam = (u, k) => {
  const v = u.searchParams.get(k);
  return v == null ? undefined : decodeURIComponent(v).replace(/^eq\./, '');
};

function installBackend(initialRow, { failRecordInsert = 0, failResend = false, failEventsRead = false, authUser = OWNER } = {}) {
  const db = {
    job: initialRow ? { ...clone(initialRow), updated_at: 'v1', deleted: false } : null,
    version: 1,
    records: [],
    events: [],
    emails: [],
    jobWrites: [],
    recordInserts: 0,
    failRecordInsert,
    calls: [],
  };
  let eventId = 0;
  let clock = 0;
  const stamp = () => new Date(NOW + (clock += 1000)).toISOString().replace('Z', '+00:00');
  global.fetch = jest.fn(async (url, init = {}) => {
    const u = new URL(String(url));
    const method = init.method || 'GET';
    db.calls.push(`${method} ${u.pathname}`);
    if (u.hostname === 'api.resend.com') {
      db.emails.push(JSON.parse(init.body));
      return failResend ? jsonRes({ message: 'down' }, 503) : jsonRes({ id: 'em_1' });
    }
    if (u.pathname === '/auth/v1/user') {
      return authUser && init.headers.Authorization === 'Bearer good' ? jsonRes({ id: authUser }) : jsonRes({ msg: 'bad' }, 401);
    }
    if (u.pathname === '/rest/v1/jobs') {
      const live = db.job && !db.job.deleted && eqParam(u, 'id') === db.job.id
        && (eqParam(u, 'user_id') === undefined || eqParam(u, 'user_id') === db.job.user_id);
      if (method === 'GET') return jsonRes(live ? [clone(db.job)] : []);
      if (method === 'PATCH') {
        if (!live || eqParam(u, 'updated_at') !== db.job.updated_at) return jsonRes([]);
        const { data } = JSON.parse(init.body);
        db.version += 1;
        db.job = { ...db.job, data, updated_at: `v${db.version}` };
        db.jobWrites.push(clone(data));
        return jsonRes([{ data, updated_at: db.job.updated_at }]);
      }
      if (method === 'POST') {
        const b = JSON.parse(init.body);
        db.version += 1;
        db.job = { ...db.job, data: b.data, updated_at: `v${db.version}` };
        db.jobWrites.push(clone(b.data));
        return jsonRes([], 201);
      }
    }
    if (u.pathname === '/rest/v1/signature_records') {
      if (method === 'POST') {
        db.recordInserts += 1;
        if (db.failRecordInsert > 0) { db.failRecordInsert -= 1; return jsonRes({ message: 'db down' }, 503); }
        const row = JSON.parse(init.body);
        if (db.records.some((r) => r.approval_token_sha256 === row.approval_token_sha256)) return jsonRes([], 201);
        db.records.push(clone(row));
        return jsonRes([row], 201);
      }
      const match = db.records.filter((r) => ['id', 'approval_token_sha256', 'user_id', 'job_id', 'change_order_id']
        .every((k) => {
          const raw = u.searchParams.get(k);
          if (raw == null) return true;
          if (raw === 'is.null') return r[k] == null;
          return String(r[k]) === raw.replace(/^eq\./, '');
        }));
      return jsonRes(clone(match.slice(0, 1)));
    }
    if (u.pathname === '/rest/v1/signature_events') {
      if (method === 'POST') {
        const row = JSON.parse(init.body);
        db.events.push({ id: (eventId += 1), ...row, created_at: stamp() });
        return jsonRes(null, 201);
      }
      if (failEventsRead) return jsonRes({ message: 'down' }, 503);
      const h = eqParam(u, 'approval_token_sha256');
      const ev = eqParam(u, 'event');
      const limit = Number(u.searchParams.get('limit') || 1000);
      return jsonRes(clone(db.events.filter((e) => e.approval_token_sha256 === h && (!ev || e.event === ev)).slice(0, limit)));
    }
    throw new Error(`unexpected ${method} ${url}`);
  });
  return db;
}

let ipCounter = 0;
function fakeC({ method = 'GET', body, query = {}, headers = {}, env = {} } = {}) {
  ipCounter += 1;
  const edgeIp = `198.51.${(ipCounter >> 8) & 255}.${ipCounter & 255}`;
  const h = {
    'cf-connecting-ip': edgeIp,
    'x-forwarded-for': `${SPOOF_IP}, 10.0.${ipCounter % 250}.${ipCounter % 250}`,
    'user-agent': 'Mozilla/5.0 (test)',
    ...headers,
  };
  const out = { headers: {}, waits: [] };
  const c = {
    env: { SUPABASE_URL: 'https://supa.test', SUPABASE_SERVICE_ROLE_KEY: 'srk', SUPABASE_ANON_KEY: 'anon', RESEND_API_KEY: 're_test', ...SEAL_ENV, ...env },
    executionCtx: { waitUntil: (p) => out.waits.push(p) },
    header: (k, v) => { out.headers[k.toLowerCase()] = v; },
    req: {
      method,
      header: (k) => h[String(k).toLowerCase()],
      query: (k) => query[k],
      json: async () => (body === undefined ? undefined : clone(body)),
    },
    json: (b, s) => ({ status: s, body: b, headers: out.headers }),
    body: (b, s) => ({ status: s, body: b, headers: out.headers }),
  };
  c.flush = () => Promise.all(out.waits);
  c.edgeIp = edgeIp;
  return c;
}

const V2 = { ESIGN_V2: 'true' };
const STRICT = { ESIGN_V2: 'true', ESIGN_REQUIRE_CONSENT: 'true' };

function approveBody(db, extra = {}) {
  return {
    jobId: 'job-1', token: TOKEN, decision: 'approved', signerName: '  Pat Lee ',
    snapshotDigest: snapshotDigest(db.job.data.approval.snapshot),
    consent: { accepted: true, version: 1 },
    drawn: DRAWN,
    signerEmail: 'pat@example.test',
    ...extra,
  };
}
async function respond(db, body, env = V2) {
  const c = fakeC({ method: 'POST', body, env });
  const res = await estimateRespondHandler(c);
  await c.flush();
  return { ...res, edgeIp: c.edgeIp };
}

// ── respond (approve) ────────────────────────────────────────────────────

describe('respond: approve with consent writes the decision, then the sealed record', () => {
  test('decision first with the four server keys and the edge IP; record sealed and verifiable', async () => {
    const db = installBackend(jobRow());
    db.events.push({ id: 900, user_id: OWNER, approval_token_sha256: sha(TOKEN), event: 'link_created', ip: null, created_at: '2026-10-02T12:00:00.250+00:00' });
    db.events.push({ id: 901, user_id: OWNER, approval_token_sha256: sha(TOKEN), event: 'viewed', ip: EDGE_IP, created_at: '2026-10-03T17:59:00+00:00' });
    const res = await respond(db, approveBody(db));
    expect(res.status).toBe(200);
    const a = db.job.data.approval;
    expect(a).toMatchObject({ decision: 'approved', signerName: 'Pat Lee', ip: res.edgeIp, consentAt: new Date(NOW).toISOString(), signatureMethod: 'typed_drawn' });
    expect(a.ip).not.toBe(SPOOF_IP);
    expect(a.signatureRecordId).toMatch(/^[0-9a-f-]{36}$/);
    expect(a.recordDigest).toMatch(/^[0-9a-f]{64}$/);
    expect(a.signatureEvidence).toEqual({
      v: 1, consentVersion: 1, drawn: DRAWN, email: 'pat@example.test',
      events: [
        { type: 'link_created', at: '2026-10-02T12:00:00.250Z', actor: 'owner' },
        { type: 'viewed', at: '2026-10-03T17:59:00.000Z', ip: EDGE_IP },
      ],
    });
    // The job write happened before the record insert.
    const writeIdx = db.calls.indexOf('PATCH /rest/v1/jobs');
    const insertIdx = db.calls.indexOf('POST /rest/v1/signature_records');
    expect(writeIdx).toBeGreaterThan(-1);
    expect(insertIdx).toBeGreaterThan(writeIdx);
    expect(db.records).toHaveLength(1);
    const row = db.records[0];
    expect(row).toMatchObject({
      id: a.signatureRecordId, user_id: OWNER, approval_token_sha256: sha(TOKEN), job_id: 'job-1',
      change_order_id: null, document_type: 'estimate', record_digest: a.recordDigest, seal_alg: 'Ed25519', seal_key_id: 'k-test',
    });
    expect(sha(canonicalJson(row.record))).toBe(a.recordDigest);
    expect(await verifySeal(SEAL_ENV, a.recordDigest, 'k-test', row.seal)).toBe(true);
    expect(row.record.consent).toMatchObject({ version: 1, acceptedAt: a.consentAt });
    expect(row.record.consent.text).toBe(signingTexts(a.snapshot, 'estimate').disclosureText);
    expect(row.record.intent.text).toBe(signingTexts(a.snapshot, 'estimate').intent);
    expect(row.record.document).toEqual(a.snapshot);
    expect(JSON.stringify(row)).not.toContain(TOKEN);
    expect(res.body).toEqual({
      ok: true, decision: 'approved', consentAt: a.consentAt,
      recordId: a.signatureRecordId, recordDigest: a.recordDigest, signatureMethod: 'typed_drawn',
    });
    expect(db.events.map((e) => e.event)).toEqual(['link_created', 'viewed', 'signed', 'copy_emailed']);
    expect(db.events[2].ip).toBe(res.edgeIp);
  });

  test('typed name only (no drawing, no email): method typed, no email sent', async () => {
    const db = installBackend(jobRow());
    const res = await respond(db, approveBody(db, { drawn: null, signerEmail: '' }));
    expect(res.status).toBe(200);
    expect(res.body.signatureMethod).toBe('typed');
    expect(db.records[0].record.signer).toEqual({ typedName: 'Pat Lee', drawn: null, email: null });
    expect(db.emails).toHaveLength(0);
  });

  test('without consent: 400 reload_required when consent is required, nothing written', async () => {
    const db = installBackend(jobRow());
    const body = approveBody(db);
    delete body.consent;
    const res = await respond(db, body, STRICT);
    expect(res.status).toBe(400);
    expect(res.body.code).toBe('reload_required');
    expect(db.jobWrites).toHaveLength(0);
    expect(db.records).toHaveLength(0);
  });

  test('without consent before it is required: an old page still signs, consent and intent null', async () => {
    const db = installBackend(jobRow());
    const res = await respond(db, { jobId: 'job-1', token: TOKEN, decision: 'approved', signerName: 'Pat Lee' });
    expect(res.status).toBe(200);
    expect(db.records[0].record.consent).toBeNull();
    expect(db.records[0].record.intent).toBeNull();
    expect(db.job.data.approval.signatureEvidence.consentVersion).toBeNull();
  });

  test('with consent required, a legacy snapshot (no esign) also needs consent and gets a record', async () => {
    const db = installBackend(jobRow({ snapshot: legacySnapshot() }));
    const noConsent = await respond(db, { jobId: 'job-1', token: TOKEN, decision: 'approved', signerName: 'Pat' }, STRICT);
    expect(noConsent.status).toBe(400);
    const res = await respond(db, approveBody(db), STRICT);
    expect(res.status).toBe(200);
    expect(db.records).toHaveLength(1);
  });

  test('payload errors are 400 with a code, before any DB contact', async () => {
    for (const [extra, code] of [
      [{ consent: { accepted: false, version: 1 } }, 'consent_required'],
      [{ consent: { accepted: true, version: 9 } }, 'consent_version_unknown'],
      [{ drawn: { w: 600, h: 200, strokes: [[[1, 2, 3, 4]]] } }, 'drawing_invalid'],
      [{ drawn: { w: 600, h: 200, strokes: Array.from({ length: 41 }, () => [[1, 1, 0], [2, 2, 1]]) } }, 'drawing_too_large'],
      [{ signerEmail: 'nope' }, 'email_invalid'],
    ]) {
      const db = installBackend(jobRow());
      const res = await respond(db, approveBody(db, extra));
      expect([res.status, res.body.code]).toEqual([400, code]);
      expect(typeof res.body.error).toBe('string');
      expect(db.calls).toEqual([]);
    }
  });

  test('typed-name rules apply on the signature path (after the token check)', async () => {
    const db = installBackend(jobRow());
    const long = await respond(db, approveBody(db, { signerName: 'x'.repeat(201) }));
    expect([long.status, long.body.code]).toEqual([400, 'name_too_long']);
    const ctl = await respond(db, approveBody(db, { signerName: 'Pat\u0007' }));
    expect([ctl.status, ctl.body.code]).toEqual([400, 'name_invalid']);
    const bad = await respond(db, approveBody(db, { token: 'wrong' }));
    expect(bad.status).toBe(404);
    expect(db.jobWrites).toHaveLength(0);
  });

  test('a consenting signature must echo the digest of the snapshot on screen (409)', async () => {
    const db = installBackend(jobRow());
    const missing = approveBody(db);
    delete missing.snapshotDigest;
    expect((await respond(db, missing)).status).toBe(409);
    expect((await respond(db, approveBody(db, { snapshotDigest: 'f'.repeat(64) }))).status).toBe(409);
    expect(db.jobWrites).toHaveLength(0);
  });

  test('expired estimates are refused (410) before any sealing', async () => {
    const db = installBackend(jobRow({ snapshot: esignSnapshot({ validUntil: '2026-10-01', validUntilTimeZone: 'America/Phoenix' }) }));
    const res = await respond(db, approveBody(db));
    expect(res.status).toBe(410);
    expect(db.records).toHaveLength(0);
    expect(db.events).toHaveLength(0);
  });

  test('options: the resolved selection goes into the record', async () => {
    const options = {
      tiers: [
        { id: 'good', name: 'Good', lineItems: [{ label: 'Labor', amount: 300 }], total: 300 },
        { id: 'best', name: 'Best', lineItems: [{ label: 'Labor', amount: 500 }], total: 500 },
      ],
      addOns: [{ id: 'a1', label: 'Surge guard', amount: 120 }],
      recommendedTierId: 'best',
    };
    const db = installBackend(jobRow({ snapshot: esignSnapshot({ options }) }));
    const res = await respond(db, approveBody(db, { selection: { tierId: 'good', addOnIds: ['a1'] } }));
    expect(res.status).toBe(200);
    expect(res.body.selection).toMatchObject({ tierId: 'good', total: 420 });
    expect(db.records[0].record.selection).toEqual(db.job.data.approval.selection);
  });
});

describe('respond: record failures, idempotency, declines, email', () => {
  test('record-insert failure → 200 recordPending; the next view lazily seals the same record', async () => {
    const db = installBackend(jobRow(), { failRecordInsert: 1 });
    const res = await respond(db, approveBody(db));
    expect(res.status).toBe(200);
    expect(res.body.recordPending).toBe(true);
    expect(db.job.data.approval.decision).toBe('approved');
    expect(db.records).toHaveLength(0);

    const c = fakeC({ query: { j: 'job-1', t: TOKEN }, env: V2 });
    const view = await estimateViewHandler(c);
    await c.flush();
    expect(view.status).toBe(200);
    expect(db.records).toHaveLength(1);
    const a = db.job.data.approval;
    expect(db.records[0].id).toBe(a.signatureRecordId);
    expect(db.records[0].record_digest).toBe(a.recordDigest);
    expect(await verifySeal(SEAL_ENV, a.recordDigest, 'k-test', db.records[0].seal)).toBe(true);
    expect(view.body.signed).toEqual({
      recordId: a.signatureRecordId, recordDigest: a.recordDigest, signatureMethod: 'typed_drawn',
      signedAt: a.consentAt, typedName: 'Pat Lee', drawn: DRAWN, recordPending: false,
    });
    expect(view.body.signed).not.toHaveProperty('email');
  });

  test('the emailed copy still carries the seal when only the insert failed', async () => {
    const db = installBackend(jobRow(), { failRecordInsert: 1 });
    await respond(db, approveBody(db));
    expect(db.emails).toHaveLength(1);
    const pdf = Buffer.from(db.emails[0].attachments[0].content, 'base64').toString('latin1');
    expect(pdf).toContain('Ed25519, key k-test');
  });

  test('no seal key: 200 recordPending, and the record is sealed once the key exists', async () => {
    const db = installBackend(jobRow());
    const c = fakeC({ method: 'POST', body: approveBody(db), env: { ...V2, ESIGN_SEAL_PRIVATE_KEY: '' } });
    const res = await estimateRespondHandler(c);
    await c.flush();
    expect(res.body.recordPending).toBe(true);
    expect(db.records).toHaveLength(0);
    const copy = await esignCopyHandler(fakeC({ query: { j: 'job-1', t: TOKEN } }));
    expect(copy.status).toBe(200);
    expect(db.records).toHaveLength(1);
  });

  test('double approve stays on the terminal lock: same record, no second insert or email', async () => {
    const db = installBackend(jobRow());
    const first = await respond(db, approveBody(db));
    const second = await respond(db, approveBody(db, { signerName: 'Someone Else' }));
    expect(second.status).toBe(200);
    expect(second.body.recordId).toBe(first.body.recordId);
    expect(second.body.recordDigest).toBe(first.body.recordDigest);
    expect(db.recordInserts).toBe(1);
    expect(db.records).toHaveLength(1);
    expect(db.emails).toHaveLength(1);
    expect(db.jobWrites).toHaveLength(1);
    expect(db.job.data.approval.signerName).toBe('Pat Lee');
  });

  test('decline logs an event, writes no record and no signature keys', async () => {
    const db = installBackend(jobRow());
    const res = await respond(db, { jobId: 'job-1', token: TOKEN, decision: 'declined', declineReason: 'Too high' });
    expect(res.status).toBe(200);
    expect(db.records).toHaveLength(0);
    expect(db.job.data.approval.signatureRecordId).toBeUndefined();
    expect(db.events.map((e) => [e.event, e.ip])).toEqual([['declined', res.edgeIp]]);
  });

  test('email: Resend gets the PDF; a send failure never fails respond', async () => {
    const db = installBackend(jobRow(), { failResend: true });
    const res = await respond(db, approveBody(db));
    expect(res.status).toBe(200);
    expect(res.body.recordPending).toBeUndefined();
    expect(db.emails).toHaveLength(1);
    const e = db.emails[0];
    expect(e.to).toEqual(['pat@example.test']);
    expect(e.from).toBe('Rector HVAC via TradeReady <estimates@gettradereadyapp.com>');
    expect(e.reply_to).toBe('office@rectorhvac.test');
    expect(e.attachments[0].filename).toMatch(/^signed-estimate-[0-9a-f]{8}\.pdf$/);
    expect(Buffer.from(e.attachments[0].content, 'base64').toString('latin1').startsWith('%PDF-1.4')).toBe(true);
    expect(db.events.map((x) => x.event)).toEqual(['signed', 'copy_email_failed']);
  });

  test('an unreadable event trail degrades to an empty trail, never a failed signature', async () => {
    const db = installBackend(jobRow(), { failEventsRead: true });
    const res = await respond(db, approveBody(db));
    expect(res.status).toBe(200);
    expect(db.records[0].record.events).toEqual([]);
  });
});

describe('flags off: exactly the previous behavior', () => {
  test('respond writes the legacy approval only, with the clientIp, and touches no esign table', async () => {
    const db = installBackend(jobRow());
    const res = await respond(db, approveBody(db), {});
    expect(res.status).toBe(200);
    expect(res.body).toEqual({ ok: true, decision: 'approved', consentAt: new Date(NOW).toISOString() });
    const a = db.job.data.approval;
    expect(Object.keys(a).sort()).toEqual(['consentAt', 'decision', 'ip', 'sentAt', 'signerName', 'snapshot', 'token', 'userAgent']);
    expect(a.signerName).toBe('  Pat Lee ');
    expect(db.calls.every((x) => x.endsWith('/rest/v1/jobs'))).toBe(true);
    expect(db.emails).toHaveLength(0);
  });

  test('view has no esign block (not even the snapshot marker), no signed view, logs nothing', async () => {
    const db = installBackend(jobRow());
    const c = fakeC({ query: { j: 'job-1', t: TOKEN } });
    const res = await estimateViewHandler(c);
    await c.flush();
    expect(res.body.esign).toBeUndefined();
    expect(res.body.signed).toBeUndefined();
    expect(db.calls).toEqual(['GET /rest/v1/jobs']);
  });

  test('preview is off', async () => {
    installBackend(jobRow());
    expect((await esignPreviewHandler(fakeC({ query: { j: 'job-1', t: TOKEN } }))).status).toBe(404);
  });
});

// ── view / create-link events ────────────────────────────────────────────

describe('view and create-link', () => {
  test('view sends the server-rendered signing texts and logs viewed (first 20 only)', async () => {
    const db = installBackend(jobRow());
    const c = fakeC({ query: { j: 'job-1', t: TOKEN }, env: V2 });
    const res = await estimateViewHandler(c);
    await c.flush();
    expect(res.body.esign).toEqual(signingTexts(db.job.data.approval.snapshot, 'estimate'));
    expect(res.body.scope).toBe('Replace the 100A panel with a 200A panel.');
    expect(db.events).toEqual([expect.objectContaining({ event: 'viewed', ip: c.edgeIp, approval_token_sha256: sha(TOKEN), user_id: OWNER })]);
    for (let i = 0; i < 25; i += 1) {
      const ci = fakeC({ query: { j: 'job-1', t: TOKEN }, env: V2 });
      await estimateViewHandler(ci);
      await ci.flush();
    }
    expect(db.events.filter((e) => e.event === 'viewed')).toHaveLength(20);
  });

  test('a legacy snapshot under ESIGN_V2 alone keeps the legacy page', async () => {
    const db = installBackend(jobRow({ snapshot: legacySnapshot() }));
    const c = fakeC({ query: { j: 'job-1', t: TOKEN }, env: V2 });
    const res = await estimateViewHandler(c);
    await c.flush();
    expect(res.body.esign).toBeUndefined();
    expect(db.events).toHaveLength(0);
  });

  test('create-link validates the snapshot additions and logs link_created for the owner', async () => {
    const db = installBackend({ id: 'job-1', user_id: OWNER, data: { id: 'job-1' } });
    const bad = await estimateCreateLinkHandler(fakeC({
      method: 'POST', env: V2, headers: { authorization: 'Bearer good' },
      body: { jobId: 'job-1', snapshot: esignSnapshot({ terms: 'x'.repeat(4001) }) },
    }));
    expect(bad).toMatchObject({ status: 400, body: { error: 'The terms must be text of at most 4,000 characters.' } });
    const ok = await estimateCreateLinkHandler(fakeC({
      method: 'POST', env: V2, headers: { authorization: 'Bearer good' }, body: { jobId: 'job-1', snapshot: esignSnapshot() },
    }));
    expect(ok.status).toBe(200);
    expect(db.events).toEqual([expect.objectContaining({ event: 'link_created', ip: null, user_id: OWNER, approval_token_sha256: sha(ok.body.token) })]);
  });
});

// ── copy / preview / verify / public keys ────────────────────────────────

describe('signer copy, preview, verify', () => {
  async function signed() {
    const db = installBackend(jobRow());
    const res = await respond(db, approveBody(db));
    return { db, res };
  }

  test('copy works after the job is soft-deleted: PDF and the JSON envelope', async () => {
    const { db, res } = await signed();
    db.job.deleted = true;
    const pdf = await esignCopyHandler(fakeC({ query: { j: 'job-1', t: TOKEN } }));
    expect(pdf.status).toBe(200);
    expect(pdf.headers['content-type']).toBe('application/pdf');
    expect(pdf.headers['content-disposition']).toBe(`attachment; filename="signed-estimate-${res.body.recordId.slice(0, 8)}.pdf"`);
    expect(Buffer.from(pdf.body).toString('latin1').startsWith('%PDF-1.4')).toBe(true);
    const again = await esignCopyHandler(fakeC({ query: { j: 'job-1', t: TOKEN } }));
    expect(Buffer.from(again.body).equals(Buffer.from(pdf.body))).toBe(true);
    const json = await esignCopyHandler(fakeC({ query: { j: 'job-1', t: TOKEN, format: 'json' } }));
    expect(json.body).toMatchObject({ format: 'tradeready-esign-record', version: 1, recordId: res.body.recordId, recordDigest: res.body.recordDigest, seal: { alg: 'Ed25519', keyId: 'k-test' } });
    expect(sha(canonicalJson(json.body.record))).toBe(res.body.recordDigest);
    expect(db.events.filter((e) => e.event === 'copy_downloaded')).toHaveLength(3);
  });

  test('copy refuses a wrong token, a wrong job, an unsigned link — same answer', async () => {
    const { db } = await signed();
    for (const query of [{ j: 'job-1', t: 'nope' }, { j: 'job-2', t: TOKEN }, { j: 'job-1', t: TOKEN, c: 'co-1' }]) {
      const res = await esignCopyHandler(fakeC({ query }));
      expect([res.status, res.body.code]).toEqual([404, 'not_signed']);
    }
    const unsignedDb = installBackend(jobRow());
    expect((await esignCopyHandler(fakeC({ query: { j: 'job-1', t: TOKEN } }))).status).toBe(404);
    expect(unsignedDb.records).toHaveLength(0);
    expect(db.records).toHaveLength(1);
  });

  test('verify answers validity only — no names, amounts, IPs or emails', async () => {
    const { res } = await signed();
    const ok = await esignVerifyHandler(fakeC({ query: { r: res.body.recordId, d: res.body.recordDigest } }));
    expect(ok.body).toEqual({ valid: true, signedAt: new Date(NOW).toISOString(), documentType: 'estimate', keyId: 'k-test' });
    expect(JSON.stringify(ok.body)).not.toMatch(/Pat|1500|203\.0|example/);
    const tampered = await esignVerifyHandler(fakeC({ query: { r: res.body.recordId, d: '0'.repeat(64) } }));
    expect(tampered.body).toEqual({ valid: false });
    const unknown = await esignVerifyHandler(fakeC({ query: { r: '00000000-0000-4000-8000-000000000000', d: res.body.recordDigest } }));
    expect(unknown.body).toEqual({ valid: false });
    const bad = await esignVerifyHandler(fakeC({ query: { r: 'x', d: 'y' } }));
    expect([bad.status, bad.body.code]).toEqual([400, 'invalid_request']);
  });

  test('verify rejects a record altered at rest, and a seal under an unpublished key', async () => {
    const { db, res } = await signed();
    db.records[0].record.signer.typedName = 'Mallory';
    expect((await esignVerifyHandler(fakeC({ query: { r: res.body.recordId, d: res.body.recordDigest } }))).body).toEqual({ valid: false });
    db.records[0].record.signer.typedName = 'Pat Lee';
    const c = fakeC({ query: { r: res.body.recordId, d: res.body.recordDigest }, env: { ESIGN_SEAL_PUBLIC_KEYS: '{}' } });
    expect((await esignVerifyHandler(c)).body).toEqual({ valid: false });
  });

  test('public keys are listed with the current key id', async () => {
    const res = await esignPublicKeysHandler(fakeC());
    expect(res.body.current).toBe('k-test');
    expect(res.body.keys).toEqual([expect.objectContaining({ keyId: 'k-test', alg: 'Ed25519' })]);
    expect(JSON.stringify(res.body)).not.toContain(SEAL_ENV.ESIGN_SEAL_PRIVATE_KEY);
  });

  test('preview: token-gated unsigned PDF', async () => {
    installBackend(jobRow());
    const res = await esignPreviewHandler(fakeC({ query: { j: 'job-1', t: TOKEN }, env: V2 }));
    expect(res.status).toBe(200);
    expect(res.headers['content-disposition']).toBe('attachment; filename="estimate-unsigned.pdf"');
    expect(Buffer.from(res.body).toString('latin1')).toContain('unsigned copy for review');
    expect((await esignPreviewHandler(fakeC({ query: { j: 'job-1', t: 'nope' }, env: V2 }))).status).toBe(404);
  });
});

// ── change orders ────────────────────────────────────────────────────────

describe('change orders reach parity', () => {
  const coBody = (db, extra = {}) => ({
    jobId: 'job-1', changeOrderId: 'co-1', token: CO_TOKEN, decision: 'approved', signerName: 'Pat Lee',
    snapshotDigest: snapshotDigest(db.job.data.changeOrders[0].approval.snapshot),
    consent: { accepted: true, version: 1 }, ...extra,
  });
  async function coRespond(db, body, env = V2) {
    const c = fakeC({ method: 'POST', body, env });
    const res = await changeRespondHandler(c);
    await c.flush();
    return { ...res, edgeIp: c.edgeIp };
  }

  test('approve: decision then a change_order record; lock on repeat; copy by c=', async () => {
    const db = installBackend(jobRow({ changeOrders: [changeOrder()] }));
    const res = await coRespond(db, coBody(db));
    expect(res.status).toBe(200);
    const a = db.job.data.changeOrders[0].approval;
    expect(a).toMatchObject({ decision: 'approved', ip: res.edgeIp, signatureMethod: 'typed', recordDigest: res.body.recordDigest });
    expect(db.records[0]).toMatchObject({ document_type: 'change_order', change_order_id: 'co-1', approval_token_sha256: sha(CO_TOKEN) });
    expect(db.records[0].record.consent.text).toMatch(/this change order electronically/);
    const again = await coRespond(db, coBody(db));
    expect(again.body.recordId).toBe(res.body.recordId);
    expect(db.recordInserts).toBe(1);
    const copy = await esignCopyHandler(fakeC({ query: { j: 'job-1', t: CO_TOKEN, c: 'co-1' } }));
    expect(copy.status).toBe(200);
    expect(copy.headers['content-disposition']).toMatch(/signed-change-order-/);
  });

  test('a stale page (digest mismatch) is refused 409; a manual decision still wins 409', async () => {
    const db = installBackend(jobRow({ changeOrders: [changeOrder()] }));
    expect((await coRespond(db, coBody(db, { snapshotDigest: 'f'.repeat(64) }))).status).toBe(409);
    const manual = installBackend(jobRow({ changeOrders: [changeOrder({ manualDecision: { decision: 'approved' } })] }));
    expect((await coRespond(manual, coBody(manual))).status).toBe(409);
    expect(db.records).toHaveLength(0);
  });

  test('change-view: texts for change orders, digest, signed view after approval', async () => {
    const db = installBackend(jobRow({ changeOrders: [changeOrder()] }));
    const c = fakeC({ query: { j: 'job-1', co: 'co-1', t: CO_TOKEN }, env: V2 });
    const before = await changeViewHandler(c);
    await c.flush();
    expect(before.body.esign.checkboxLabel).toBe('I agree to use electronic records and signatures for this change order.');
    expect(before.body.snapshotDigest).toBe(snapshotDigest(coSnapshot()));
    await coRespond(db, coBody(db));
    const after = await changeViewHandler(fakeC({ query: { j: 'job-1', co: 'co-1', t: CO_TOKEN }, env: V2 }));
    expect(after.body.esign).toBeUndefined();
    expect(after.body.signed).toMatchObject({ typedName: 'Pat Lee', recordPending: false });
  });

  test('flags off: legacy change-respond response and write', async () => {
    const db = installBackend(jobRow({ changeOrders: [changeOrder()] }));
    const res = await coRespond(db, { jobId: 'job-1', changeOrderId: 'co-1', token: CO_TOKEN, decision: 'approved', signerName: 'Pat' }, {});
    // change-respond stamps consentAt with `new Date()` (unchanged legacy code).
    expect(res.body).toEqual({ ok: true, decision: 'approved', consentAt: expect.stringMatching(/^\d{4}-\d{2}-\d{2}T/) });
    expect(db.calls).toEqual(['GET /rest/v1/jobs', 'POST /rest/v1/jobs']);
    // clientIp (rate limiting / legacy record) already prefers the edge header.
    expect(db.job.data.changeOrders[0].approval.ip).toBe(res.edgeIp);
    expect(db.job.data.changeOrders[0].approval.signatureRecordId).toBeUndefined();
  });
});

// ── owner route ──────────────────────────────────────────────────────────

describe('POST /api/esign/record (owner)', () => {
  const ownerC = (body, headers = { authorization: 'Bearer good' }) => fakeC({ method: 'POST', body, headers });

  test('auth, validation and method errors', async () => {
    installBackend(jobRow());
    expect((await esignRecordHandler(fakeC({ method: 'POST', body: { jobId: 'job-1' } }))).body.code).toBe('unauthorized');
    expect((await esignRecordHandler(ownerC({ jobId: 'job-1' }, { authorization: 'Bearer bad' }))).status).toBe(401);
    expect((await esignRecordHandler(ownerC({}))).body).toMatchObject({ code: 'invalid_request' });
    expect((await esignRecordHandler(ownerC({ jobId: 'job-1', recordId: 'x' }))).status).toBe(400);
    expect((await esignRecordHandler(fakeC({ method: 'GET' }))).status).toBe(405);
  });

  test('returns the sealed record, the live event log and the PDF', async () => {
    const db = installBackend(jobRow());
    const signedRes = await respond(db, approveBody(db));
    const res = await esignRecordHandler(ownerC({ jobId: 'job-1', recordId: signedRes.body.recordId }));
    expect(res.status).toBe(200);
    expect(res.body).toMatchObject({
      recordId: signedRes.body.recordId, recordDigest: signedRes.body.recordDigest, documentType: 'estimate',
      jobId: 'job-1', changeOrderId: null, signatureMethod: 'typed_drawn', seal: { alg: 'Ed25519', keyId: 'k-test' },
      pdf: { contentType: 'application/pdf', filename: `signed-estimate-${signedRes.body.recordId.slice(0, 8)}.pdf` },
    });
    expect(res.body.events.map((e) => e.type)).toEqual(['signed', 'copy_emailed']);
    expect(Buffer.from(res.body.pdf.base64, 'base64').toString('latin1').startsWith('%PDF-1.4')).toBe(true);
    expect(sha(canonicalJson(res.body.record))).toBe(res.body.recordDigest);
  });

  test("another owner's job is not found; a legacy approval is not found", async () => {
    const db = installBackend(jobRow(), { authUser: '99999999-2222-4333-8444-555555555555' });
    db.records.push({ id: 'r', user_id: OWNER, job_id: 'job-1', change_order_id: null, record: {} });
    expect((await esignRecordHandler(ownerC({ jobId: 'job-1' }))).body.code).toBe('record_not_found');
    installBackend(jobRow({ approval: { decision: 'approved', signerName: 'Pat', consentAt: 'x' } }));
    expect((await esignRecordHandler(ownerC({ jobId: 'job-1' }))).status).toBe(404);
  });

  test('lazily seals a pending record from the owner job; 503 while it cannot', async () => {
    const db = installBackend(jobRow(), { failRecordInsert: 2 });
    await respond(db, approveBody(db));
    expect(db.records).toHaveLength(0);
    const pending = await esignRecordHandler(ownerC({ jobId: 'job-1' }));
    expect([pending.status, pending.body.code]).toEqual([503, 'record_pending']);
    const res = await esignRecordHandler(ownerC({ jobId: 'job-1' }));
    expect(res.status).toBe(200);
    expect(db.records).toHaveLength(1);
    expect(res.body.recordDigest).toBe(db.job.data.approval.recordDigest);
  });
});
