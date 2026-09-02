// Phase 0 task 4 (ESTIMATE_WORKFLOW_ROADMAP.md): the WORKERS estimate write
// routes (create-link, respond, change-respond) converted to the conditional
// contract. The point of these tests is the concurrency matrix — every write
// is interleaved with a racing mutation to prove neither side is silently lost.
//
// A tiny stateful Supabase-REST simulator backs the jobs table so an
// optimistic-concurrency PATCH behaves for real: a version-guarded PATCH
// applies only when updated_at still matches, and a zero-row PATCH is a
// conflict. `afterRead` lets a test slip a concurrent write in between the
// handler's read and its write.

import { estimateCreateLinkHandler } from '../backend-workers/src/routes/estimate/createLink.js';
import { estimateRespondHandler } from '../backend-workers/src/routes/estimate/respond.js';
import { changeRespondHandler } from '../backend-workers/src/routes/estimate/changeRespond.js';

const ENV = {
  SUPABASE_URL: 'https://supa.test',
  SUPABASE_ANON_KEY: 'anon',
  SUPABASE_SERVICE_ROLE_KEY: 'srk',
};

// ---- stateful jobs-table simulator --------------------------------------

function createSupabaseSim({ job, user = { id: 'u1' }, afterRead = null }) {
  // `job` = { id, user_id, data, updated_at }. Version bumps on each write.
  let version = 1;
  const store = new Map();
  if (job) store.set(job.id, { ...job, updated_at: job.updated_at || `v${version}` });
  const bump = () => `v${++version}`;

  // Directly mutate the row (simulates another writer). Bumps the version.
  function raceWrite(id, mutate) {
    const row = store.get(id);
    const next = { ...row, data: mutate(structuredClone(row.data)), updated_at: bump() };
    store.set(id, next);
  }

  let reads = 0;
  const fetchImpl = jest.fn(async (url, init = {}) => {
    const u = new URL(url);
    if (u.pathname.endsWith('/auth/v1/user')) {
      return { ok: !!user, status: user ? 200 : 401, json: async () => user, text: async () => '' };
    }
    if (!u.pathname.endsWith('/rest/v1/jobs')) throw new Error(`unexpected url ${url}`);

    const strip = (k) => {
      const v = u.searchParams.get(k);
      return v == null ? null : v.replace(/^eq\./, '');
    };
    const id = strip('id');
    const method = init.method || 'GET';

    if (method === 'GET') {
      const row = store.get(id);
      const ownerOk = !u.searchParams.has('user_id') || strip('user_id') === row?.user_id;
      const out = row && ownerOk ? [{ user_id: row.user_id, data: row.data, updated_at: row.updated_at }] : [];
      reads += 1;
      if (afterRead) afterRead({ reads, raceWrite });
      return { ok: true, status: 200, json: async () => out, text: async () => JSON.stringify(out) };
    }

    if (method === 'PATCH') {
      const expected = strip('updated_at');
      const row = store.get(id);
      if (!row || row.updated_at !== expected) {
        return { ok: true, status: 200, json: async () => [], text: async () => '[]' }; // conflict
      }
      const body = JSON.parse(init.body);
      const next = { ...row, data: body.data, updated_at: bump() };
      store.set(id, next);
      const rep = [{ user_id: next.user_id, data: next.data, updated_at: next.updated_at }];
      return { ok: true, status: 200, json: async () => rep, text: async () => JSON.stringify(rep) };
    }
    throw new Error(`unexpected method ${method}`);
  });

  return { fetchImpl, store, raceWrite, get: (id) => store.get(id) };
}

// ---- Hono-context fake ---------------------------------------------------

function makeCtx({ method = 'POST', headers = {}, body }) {
  const lower = {};
  for (const [k, v] of Object.entries(headers)) lower[k.toLowerCase()] = v;
  const resHeaders = {};
  return {
    env: ENV,
    _res: resHeaders,
    req: {
      method,
      header: (name) => lower[String(name).toLowerCase()],
      json: async () => body,
    },
    header: (k, v) => { resHeaders[k] = v; },
    json: (b, status = 200) => ({ status, body: b, headers: resHeaders }),
    body: (b, status = 200) => ({ status, body: b, headers: resHeaders }),
  };
}

let originalFetch;
beforeEach(() => { originalFetch = global.fetch; });
afterEach(() => { global.fetch = originalFetch; jest.restoreAllMocks(); });

const OWNER_HEADERS = { authorization: 'Bearer jwt', origin: 'https://gettradereadyapp.com' };
const CUSTOMER_HEADERS = { origin: 'https://czilla57.github.io', 'user-agent': 'ua', 'x-forwarded-for': '9.9.9.9' };

// =========================================================================
// respond — estimate customer decision
// =========================================================================
describe('estimateRespondHandler (conditional)', () => {
  const jobWith = (approval) => ({
    id: 'j1', user_id: 'u1', updated_at: 'v1',
    data: { estimateTotal: 2400, approval },
  });

  it('records an approval and preserves the rest of the blob', async () => {
    const sim = createSupabaseSim({ job: jobWith({ token: 'TOK', sentAt: 's', snapshot: {} }) });
    global.fetch = sim.fetchImpl;
    const res = await estimateRespondHandler(makeCtx({
      headers: CUSTOMER_HEADERS,
      body: { jobId: 'j1', token: 'TOK', decision: 'approved', signerName: 'Sam Doe' },
    }));
    expect(res.status).toBe(200);
    expect(res.body).toMatchObject({ ok: true, decision: 'approved' });
    const saved = sim.get('j1').data;
    expect(saved.approval.decision).toBe('approved');
    expect(saved.approval.signerName).toBe('Sam Doe');
    expect(saved.estimateTotal).toBe(2400); // untouched
  });

  it('404s on a bad token and writes nothing', async () => {
    const sim = createSupabaseSim({ job: jobWith({ token: 'TOK', sentAt: 's', snapshot: {} }) });
    global.fetch = sim.fetchImpl;
    const res = await estimateRespondHandler(makeCtx({
      headers: CUSTOMER_HEADERS,
      body: { jobId: 'j1', token: 'WRONG', decision: 'approved', signerName: 'Sam' },
    }));
    expect(res.status).toBe(404);
    expect(sim.get('j1').updated_at).toBe('v1'); // no write
  });

  it('holds the terminal approved lock (no rewrite) when a decline arrives late', async () => {
    const sim = createSupabaseSim({ job: jobWith({ token: 'TOK', sentAt: 's', snapshot: {}, decision: 'approved', consentAt: 'c1' }) });
    global.fetch = sim.fetchImpl;
    const res = await estimateRespondHandler(makeCtx({
      headers: CUSTOMER_HEADERS,
      body: { jobId: 'j1', token: 'TOK', decision: 'declined' },
    }));
    expect(res.status).toBe(200);
    expect(res.body.decision).toBe('approved');
    expect(sim.get('j1').updated_at).toBe('v1'); // skip — nothing written
  });

  it('CONCURRENCY: an owner edit landing between read and write does not lose the customer decision', async () => {
    const sim = createSupabaseSim({
      job: jobWith({ token: 'TOK', sentAt: 's', snapshot: {} }),
      // On the FIRST read only, an owner edits an unrelated field, bumping the
      // version so the customer's first PATCH conflicts and must retry.
      afterRead: ({ reads, raceWrite }) => {
        if (reads === 1) raceWrite('j1', (data) => ({ ...data, ownerNote: 'called customer' }));
      },
    });
    global.fetch = sim.fetchImpl;
    const res = await estimateRespondHandler(makeCtx({
      headers: CUSTOMER_HEADERS,
      body: { jobId: 'j1', token: 'TOK', decision: 'approved', signerName: 'Sam' },
    }));
    expect(res.status).toBe(200);
    const saved = sim.get('j1').data;
    expect(saved.approval.decision).toBe('approved'); // customer decision survived
    expect(saved.ownerNote).toBe('called customer'); // owner edit survived too
  });
});

// =========================================================================
// change-respond — change-order customer decision
// =========================================================================
describe('changeRespondHandler (conditional)', () => {
  const jobWithCo = (co) => ({
    id: 'j1', user_id: 'u1', updated_at: 'v1',
    data: { estimateTotal: 2400, changeOrders: [{ id: 'coB', title: 'Subfloor', amount: 200, createdAt: 'd', ...co }] },
  });
  const req = (over) => ({ jobId: 'j1', changeOrderId: 'coB', token: 'TOK', decision: 'approved', signerName: 'Dana R', ...over });

  it('records into the right CO element', async () => {
    const sim = createSupabaseSim({ job: jobWithCo({ approval: { token: 'TOK', sentAt: 's', snapshot: {} } }) });
    global.fetch = sim.fetchImpl;
    const res = await changeRespondHandler(makeCtx({ headers: CUSTOMER_HEADERS, body: req() }));
    expect(res.status).toBe(200);
    const co = sim.get('j1').data.changeOrders[0];
    expect(co.approval.decision).toBe('approved');
    expect(co.approval.signerName).toBe('Dana R');
    expect(sim.get('j1').data.estimateTotal).toBe(2400);
  });

  it('409s when the CO was manually decided on site (writes nothing)', async () => {
    const sim = createSupabaseSim({ job: jobWithCo({ approval: { token: 'TOK', sentAt: 's', snapshot: {} }, manualDecision: { decision: 'approved', decidedAt: 'd' } }) });
    global.fetch = sim.fetchImpl;
    const res = await changeRespondHandler(makeCtx({ headers: CUSTOMER_HEADERS, body: req({ decision: 'declined' }) }));
    expect(res.status).toBe(409);
    expect(res.body.error).toBe('This change was already decided.');
    expect(sim.get('j1').updated_at).toBe('v1');
  });

  it('409s once link-declined — declined is final for change orders', async () => {
    const sim = createSupabaseSim({ job: jobWithCo({ approval: { token: 'TOK', sentAt: 's', snapshot: {}, decision: 'declined' } }) });
    global.fetch = sim.fetchImpl;
    const res = await changeRespondHandler(makeCtx({ headers: CUSTOMER_HEADERS, body: req() }));
    expect(res.status).toBe(409);
  });

  it('404s on a bad token', async () => {
    const sim = createSupabaseSim({ job: jobWithCo({ approval: { token: 'TOK', sentAt: 's', snapshot: {} } }) });
    global.fetch = sim.fetchImpl;
    const res = await changeRespondHandler(makeCtx({ headers: CUSTOMER_HEADERS, body: req({ token: 'WRONG' }) }));
    expect(res.status).toBe(404);
  });

  it('CONCURRENCY: a racing manual decision on the SAME CO wins — the stale customer link cannot overwrite it', async () => {
    const sim = createSupabaseSim({
      job: jobWithCo({ approval: { token: 'TOK', sentAt: 's', snapshot: {} } }),
      afterRead: ({ reads, raceWrite }) => {
        if (reads === 1) {
          raceWrite('j1', (data) => {
            data.changeOrders[0].manualDecision = { decision: 'approved', decidedAt: 'd' };
            return data;
          });
        }
      },
    });
    global.fetch = sim.fetchImpl;
    const res = await changeRespondHandler(makeCtx({ headers: CUSTOMER_HEADERS, body: req({ decision: 'declined' }) }));
    expect(res.status).toBe(409); // loser gets a conflict
    expect(sim.get('j1').data.changeOrders[0].manualDecision.decision).toBe('approved'); // manual outcome preserved
    expect(sim.get('j1').data.changeOrders[0].approval.decision).toBeUndefined(); // customer decline never landed
  });
});

// =========================================================================
// create-link — owner mints an approval link
// =========================================================================
describe('estimateCreateLinkHandler (conditional)', () => {
  const job = () => ({ id: 'j1', user_id: 'u1', updated_at: 'v1', data: { estimateTotal: 500 } });

  it('mints a token, writes the approval, and returns a link', async () => {
    const sim = createSupabaseSim({ job: job() });
    global.fetch = sim.fetchImpl;
    const res = await estimateCreateLinkHandler(makeCtx({
      headers: OWNER_HEADERS,
      body: { jobId: 'j1', snapshot: { total: 500 } },
    }));
    expect(res.status).toBe(200);
    expect(res.body.token).toMatch(/^[0-9a-f]{48}$/);
    expect(res.body.url).toContain(`t=${res.body.token}`);
    expect(sim.get('j1').data.approval.token).toBe(res.body.token);
  });

  it('returns the existing link unchanged once approved (frozen snapshot)', async () => {
    const sim = createSupabaseSim({ job: {
      id: 'j1', user_id: 'u1', updated_at: 'v1',
      data: { approval: { token: 'FROZEN', sentAt: 's0', snapshot: { total: 500 }, decision: 'approved' } },
    } });
    global.fetch = sim.fetchImpl;
    const res = await estimateCreateLinkHandler(makeCtx({
      headers: OWNER_HEADERS,
      body: { jobId: 'j1', snapshot: { total: 999 } },
    }));
    expect(res.status).toBe(200);
    expect(res.body.token).toBe('FROZEN');
    expect(res.body.sentAt).toBe('s0');
    expect(sim.get('j1').updated_at).toBe('v1'); // skip — nothing written
  });

  it('422s when the job is not synced/owned', async () => {
    const sim = createSupabaseSim({ job: null });
    global.fetch = sim.fetchImpl;
    const res = await estimateCreateLinkHandler(makeCtx({
      headers: OWNER_HEADERS, body: { jobId: 'j1', snapshot: { total: 1 } },
    }));
    expect(res.status).toBe(422);
  });

  it('CONCURRENCY: an unrelated owner edit between read and write does not lose the minted approval', async () => {
    const sim = createSupabaseSim({
      job: job(),
      afterRead: ({ reads, raceWrite }) => {
        if (reads === 1) raceWrite('j1', (data) => ({ ...data, estimateTotal: 650 }));
      },
    });
    global.fetch = sim.fetchImpl;
    const res = await estimateCreateLinkHandler(makeCtx({
      headers: OWNER_HEADERS, body: { jobId: 'j1', snapshot: { total: 500 } },
    }));
    expect(res.status).toBe(200);
    const saved = sim.get('j1').data;
    expect(saved.approval.token).toBe(res.body.token); // link written
    expect(saved.estimateTotal).toBe(650); // concurrent edit survived
  });

  it('CONCURRENCY: a customer approval landing before the mint wins — no second token is issued', async () => {
    // A link already exists (token PRE); the customer approves via that link in
    // the gap between the owner's re-send read and its write. planApprovalWrite
    // then sees an approved snapshot on the fresh row and freezes it.
    const sim = createSupabaseSim({
      job: { id: 'j1', user_id: 'u1', updated_at: 'v1',
        data: { approval: { token: 'PRE', sentAt: 's0', snapshot: { total: 500 } } } },
      afterRead: ({ reads, raceWrite }) => {
        if (reads === 1) {
          raceWrite('j1', (data) => {
            data.approval = { ...data.approval, decision: 'approved', consentAt: 'c1', signerName: 'Sam' };
            return data;
          });
        }
      },
    });
    global.fetch = sim.fetchImpl;
    const res = await estimateCreateLinkHandler(makeCtx({
      headers: OWNER_HEADERS, body: { jobId: 'j1', snapshot: { total: 999 } },
    }));
    expect(res.status).toBe(200);
    expect(res.body.token).toBe('PRE'); // reused the approved link, no new token
    expect(sim.get('j1').data.approval.decision).toBe('approved'); // decision preserved
    expect(sim.get('j1').data.approval.snapshot).toEqual({ total: 500 }); // NOT re-snapshotted to 999
  });
});
