// Phase 0 (ESTIMATE_WORKFLOW_ROADMAP.md) — the concurrency-safe Job-write
// prerequisite. These pin the WORKERS estimateStore's new versioned-read and
// conditional-write helpers directly (the routes are converted in task 4).
//
// The contract under test (roadmap "Prerequisite: concurrency-safe Job writes"):
//   1. mutation reads return data AND updated_at
//   2. a write supplies the exact version it read; updates only if still current
//   3. a zero-row update is a CONFLICT, never a success
//   4. on conflict, refetch and re-plan against the fresh row (bounded)
//   5. an operation the fresh row can no longer accept returns a typed conflict
//   6. the DB trigger owns updated_at — writes never send their own

const store = require('../backend-workers/lib/estimateStore.js');

const ENV = { SUPABASE_URL: 'https://supa.test', SUPABASE_SERVICE_ROLE_KEY: 'srk' };

// A tiny queue-driven fetch mock: each call shifts the next scripted response
// and records the [url, init] it was invoked with.
function scriptFetch(responses) {
  const calls = [];
  global.fetch = jest.fn(async (url, init) => {
    calls.push([url, init]);
    const r = responses.shift();
    if (!r) throw new Error(`unexpected fetch: ${url}`);
    return {
      ok: r.ok !== false,
      status: r.status || 200,
      json: async () => r.rows,
      text: async () => JSON.stringify(r.rows ?? r.text ?? ''),
    };
  });
  return calls;
}

afterEach(() => {
  delete global.fetch;
  jest.restoreAllMocks();
});

describe('fetchJobVersioned', () => {
  it('selects updated_at and returns it alongside user_id + data', async () => {
    const calls = scriptFetch([{ rows: [{ user_id: 'u1', data: { a: 1 }, updated_at: 'V1' }] }]);
    const row = await store.fetchJobVersioned(ENV, 'j1');
    expect(row).toEqual({ user_id: 'u1', data: { a: 1 }, updated_at: 'V1' });
    const [url, init] = calls[0];
    expect(url).toContain('jobs?id=eq.j1');
    expect(url).toContain('deleted=eq.false');
    expect(url).toContain('updated_at'); // version column is selected
    expect(init.headers.Authorization).toBe('Bearer srk');
  });

  it('returns null for a missing/deleted row', async () => {
    scriptFetch([{ rows: [] }]);
    expect(await store.fetchJobVersioned(ENV, 'nope')).toBeNull();
  });
});

describe('fetchJobForUserVersioned', () => {
  it('scopes by user_id and returns the version', async () => {
    const calls = scriptFetch([{ rows: [{ user_id: 'u1', data: {}, updated_at: 'V1' }] }]);
    const row = await store.fetchJobForUserVersioned(ENV, 'j1', 'u1');
    expect(row.updated_at).toBe('V1');
    expect(calls[0][0]).toContain('user_id=eq.u1');
  });

  it('returns null when the row belongs to someone else (no rows)', async () => {
    scriptFetch([{ rows: [] }]);
    expect(await store.fetchJobForUserVersioned(ENV, 'j1', 'u2')).toBeNull();
  });
});

describe('conditionalUpdateJob', () => {
  it('PATCHes with an updated_at=eq guard, never sends its own updated_at, and returns the fresh row', async () => {
    const calls = scriptFetch([{ rows: [{ user_id: 'u1', data: { a: 2 }, updated_at: 'V2' }] }]);
    const out = await store.conditionalUpdateJob(ENV, 'j1', 'V1', { a: 2 });
    expect(out).toEqual({ updated: true, row: { user_id: 'u1', data: { a: 2 }, updated_at: 'V2' } });

    const [url, init] = calls[0];
    expect(init.method).toBe('PATCH');
    expect(url).toContain('id=eq.j1');
    expect(url).toContain('updated_at=eq.V1'); // optimistic-concurrency guard
    expect(url).toContain('deleted=eq.false');
    expect(init.headers.Prefer).toContain('return=representation');
    const body = JSON.parse(init.body);
    expect(body).toEqual({ data: { a: 2 } }); // behavior #6: no client updated_at
    expect(body).not.toHaveProperty('updated_at');
  });

  it('url-encodes the version so a "+" in the timezone offset is not a space', async () => {
    const calls = scriptFetch([{ rows: [{ user_id: 'u1', data: {}, updated_at: 'V2' }] }]);
    await store.conditionalUpdateJob(ENV, 'j1', '2026-09-02T00:00:00+00:00', {});
    expect(calls[0][0]).toContain('updated_at=eq.2026-09-02T00%3A00%3A00%2B00%3A00');
  });

  it('treats a zero-row update as a CONFLICT, not a success', async () => {
    scriptFetch([{ rows: [] }]);
    const out = await store.conditionalUpdateJob(ENV, 'j1', 'STALE', { a: 9 });
    expect(out).toEqual({ updated: false });
  });

  it('throws on a transport/HTTP error (distinct from a conflict)', async () => {
    scriptFetch([{ ok: false, status: 500, text: 'boom' }]);
    await expect(store.conditionalUpdateJob(ENV, 'j1', 'V1', {})).rejects.toThrow(/500/);
  });
});

describe('updateJobConditionally (bounded retry orchestrator)', () => {
  const fresh = (v, data = {}) => ({ user_id: 'u1', data, updated_at: v });

  it('writes on the first try when the version is current', async () => {
    scriptFetch([{ rows: [fresh('V2', { done: true })] }]); // the PATCH
    const plan = jest.fn((row) => ({ data: { ...row.data, done: true } }));
    const fetchRow = jest.fn(async () => fresh('V1'));
    const out = await store.updateJobConditionally(ENV, 'j1', fetchRow, plan);
    expect(out).toEqual({ ok: true, changed: true, row: fresh('V2', { done: true }) });
    expect(fetchRow).toHaveBeenCalledTimes(1);
    expect(plan).toHaveBeenCalledTimes(1);
  });

  it('refetches and re-plans against the fresh row after a version conflict, then succeeds', async () => {
    scriptFetch([
      { rows: [] },                       // 1st PATCH: version moved -> conflict
      { rows: [fresh('V3', { n: 2 })] },  // 2nd PATCH: succeeds
    ]);
    const versions = [fresh('V1', { n: 0 }), fresh('V2', { n: 1 })]; // read #1, read #2
    const fetchRow = jest.fn(async () => versions.shift());
    // plan re-applies against whatever it is handed (proves it saw the fresh row)
    const plan = jest.fn((row) => ({ data: { n: row.data.n + 1 } }));

    const out = await store.updateJobConditionally(ENV, 'j1', fetchRow, plan);
    expect(out.ok).toBe(true);
    expect(fetchRow).toHaveBeenCalledTimes(2);
    expect(plan).toHaveBeenLastCalledWith(fresh('V2', { n: 1 })); // re-planned on fresh
  });

  it('returns a typed conflict (no write) when plan says the fresh row cannot accept it', async () => {
    scriptFetch([]); // no PATCH should be attempted
    const fetchRow = jest.fn(async () => fresh('V1', { decision: 'approved' }));
    const plan = jest.fn(() => ({ conflict: true, reason: 'decided' }));
    const out = await store.updateJobConditionally(ENV, 'j1', fetchRow, plan);
    expect(out).toEqual({ ok: false, conflict: true, reason: 'decided' });
    expect(global.fetch).not.toHaveBeenCalled();
  });

  it('skips the write (changed:false) when plan reports the row is already in the desired state', async () => {
    scriptFetch([]); // no PATCH
    const fetchRow = jest.fn(async () => fresh('V1', { done: true }));
    const plan = jest.fn(() => ({ skip: true }));
    const out = await store.updateJobConditionally(ENV, 'j1', fetchRow, plan);
    expect(out).toEqual({ ok: true, changed: false, row: fresh('V1', { done: true }) });
    expect(global.fetch).not.toHaveBeenCalled();
  });

  it('reports notFound when the row is missing', async () => {
    scriptFetch([]);
    const fetchRow = jest.fn(async () => null);
    const out = await store.updateJobConditionally(ENV, 'j1', fetchRow, jest.fn());
    expect(out).toEqual({ ok: false, notFound: true });
  });

  it('gives up with a conflict after exhausting the retry budget', async () => {
    scriptFetch([{ rows: [] }, { rows: [] }, { rows: [] }]); // every PATCH conflicts
    const fetchRow = jest.fn(async () => fresh('Vx'));
    const plan = jest.fn(() => ({ data: {} }));
    const out = await store.updateJobConditionally(ENV, 'j1', fetchRow, plan, { tries: 3 });
    expect(out).toEqual({ ok: false, conflict: true, reason: 'max-retries' });
    expect(global.fetch).toHaveBeenCalledTimes(3);
  });
});
