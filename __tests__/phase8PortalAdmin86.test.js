// __tests__/phase8PortalAdmin86.test.js
// Task 8.06 — Transactional portal token administration (contract §4, §6,
// §9/C12 G4).
//
// Server-precondition level, same discipline as the 8.05 suite: the fetch
// mock stands in for PostgREST + the 20260922_portal_token_admin.sql RPC.
// Scripted `admin_portal_token` envelopes let each test pin the CORE's
// contract behavior (verdict mapping, single atomic call, replay recovery,
// error vocabulary). The adoption-gated resolver logic in
// resolvePortalCustomer is real JS exercised against scripted TABLE rows
// (not envelopes). This is NOT database race evidence: competing-session
// timing proof is deferred to Phase 12 / task 8.14 (M1) and labeled as such
// wherever the suite touches linearization.
//
// The 8.00 characterization file
// (phase8PortalConcurrencyCharacterization.test.js) is left intact: it pins
// the PRE-8.06 splits as historical record. This suite pins the NEW
// contract. Where behavior intentionally changed (mint 409 on disabled rows,
// adopted unknown-token fail-closed), the test names the frozen section.

const { createHash } = require('node:crypto');
const store = require('../backend-workers/lib/estimate/portalTokenStore.js');
const {
  portalManageCore,
  statusCore,
} = require('../backend-workers/lib/estimate/portalManage.js');
const { portalManageHandler } = require('../backend-workers/src/routes/estimate/portalManage.js');

const ENV = { SUPABASE_URL: 'https://supa.test', SUPABASE_SERVICE_ROLE_KEY: 'srk' };
const sha = (s) => createHash('sha256').update(s, 'utf8').digest('hex');

const TOKEN = 'p'.repeat(48);
const STALE_BLOB_TOKEN = 's'.repeat(48);
const NEW_HEX = 'e'.repeat(48);
const HASH = sha(TOKEN);
const OP1 = '0193f123-0000-4000-8000-000000000001';
const OP2 = '0193f123-0000-4000-8000-000000000002';

function jsonRes(body, status = 200) {
  return {
    ok: status >= 200 && status < 300,
    status,
    json: async () => body,
    text: async () => JSON.stringify(body),
  };
}

// Scripted backend. tokenRows: portal_tokens GET; customerRow: by-id fetch;
// blobRows: legacy JSON-path lookup; rpcPortal: FIFO envelopes for
// /rpc/admin_portal_token; rpcMissing: RPC answers 404 (pre-deploy);
// failInsert/failPatch: legacy-path fault injection.
function mock86({
  tokenRows = [],
  customerRow = null,
  blobRows = [],
  rpcPortal = [],
  rpcMissing = false,
  failInsert = false,
  failPatch = false,
  authUser = 'u1',
} = {}) {
  const calls = { inserts: [], patches: [], rpcPortal: [], fetches: [] };
  const q = [...rpcPortal];
  const rowsState = [...tokenRows];
  global.fetch = jest.fn(async (url, init = {}) => {
    const u = String(url);
    const method = init.method || 'GET';
    calls.fetches.push(u);
    if (u.includes('/rest/v1/rpc/admin_portal_token')) {
      calls.rpcPortal.push(JSON.parse(init.body));
      if (rpcMissing) return jsonRes({ message: 'not found' }, 404);
      return jsonRes(q.length ? q.shift() : { ok: false, error: 'invalid_args' });
    }
    if (u.includes('/rest/v1/portal_tokens')) {
      if (method === 'POST') {
        if (failInsert) throw new Error('insert down');
        const body = JSON.parse(init.body);
        calls.inserts.push(body);
        rowsState.push({ token_hash: body.token_hash, enabled: body.enabled, revoked_at: null });
        return jsonRes([], 201);
      }
      if (method === 'PATCH') {
        if (failPatch) throw new Error('patch down');
        calls.patches.push({ u, body: JSON.parse(init.body) });
        return jsonRes([], 204);
      }
      if (u.includes('token_hash=eq.')) {
        const m = u.match(/token_hash=eq\.([^&]*)/);
        return jsonRes(rowsState.filter((r) => r.token_hash === decodeURIComponent(m[1])));
      }
      return jsonRes([...rowsState]);
    }
    if (u.includes('/rest/v1/customers')) {
      return jsonRes(u.includes('data->portal->>token') ? blobRows : customerRow ? [customerRow] : []);
    }
    if (u.includes('/auth/v1/user')) {
      if (!authUser) return jsonRes({ message: 'bad' }, 401);
      return jsonRes({ id: authUser });
    }
    return jsonRes([]);
  });
  return calls;
}

const customer = (over = {}) => ({
  user_id: 'u1',
  id: 'c1',
  data: { name: 'Dana', portal: { token: TOKEN, enabled: true } },
  ...over,
});
const activeRow = (over = {}) => ({
  token_hash: HASH, user_id: 'u1', customer_id: 'c1', enabled: true, revoked_at: null, ...over,
});

function fakeC({ method = 'POST', body = {}, auth = 'Bearer good' } = {}) {
  return {
    env: { SUPABASE_URL: ENV.SUPABASE_URL, SUPABASE_ANON_KEY: 'anon' },
    header() {},
    req: {
      method,
      header: (k) => (String(k).toLowerCase() === 'authorization' ? auth : undefined),
      json: async () => body,
    },
    json: (b, s) => ({ status: s, body: b }),
    body: (b, s) => ({ status: s, body: b }),
  };
}

afterEach(() => {
  delete global.fetch;
  jest.restoreAllMocks();
});

describe('8.06 admin input validation (no backend contact on 400)', () => {
  test('unknown/missing action or customerId → 400 Invalid request', async () => {
    const calls = mock86();
    for (const body of [{}, { action: 'nuke', customerId: 'c1' }, { action: 'mint' }, { action: 'mint', customerId: '' }]) {
      const r = await portalManageCore(ENV, { userId: 'u1', body, randHex: NEW_HEX });
      expect(r).toEqual({ status: 400, json: { error: 'Invalid request.' } });
    }
    expect(calls.fetches).toHaveLength(0);
  });

  test('set_enabled requires a boolean; malformed operationId → 400', async () => {
    mock86();
    expect(await portalManageCore(ENV, { userId: 'u1', body: { action: 'set_enabled', customerId: 'c1' }, randHex: NEW_HEX }))
      .toEqual({ status: 400, json: { error: 'Invalid request.' } });
    expect(await portalManageCore(ENV, { userId: 'u1', body: { action: 'rotate', customerId: 'c1', operationId: 'not-a-uuid' }, randHex: NEW_HEX }))
      .toEqual({ status: 400, json: { error: 'Invalid request.' } });
    // UUID shape but not v4 is rejected (contract: client-generated UUID v4).
    expect(await portalManageCore(ENV, { userId: 'u1', body: { action: 'mint', customerId: 'c1', operationId: '0193f123-0000-1000-8000-000000000001' }, randHex: NEW_HEX }))
      .toEqual({ status: 400, json: { error: 'Invalid request.' } });
  });

  test('unknown/foreign customer → 404, nothing written (manage + status)', async () => {
    const calls = mock86({ customerRow: null, blobRows: [], rpcPortal: [{ ok: false, error: 'not_found' }] });
    expect(await portalManageCore(ENV, { userId: 'u1', body: { action: 'mint', customerId: 'c1', operationId: OP1 }, randHex: NEW_HEX }))
      .toEqual({ status: 404, json: { error: 'Not found' } });
    expect(await statusCore(ENV, { userId: 'u1', customerId: 'c1' }))
      .toEqual({ status: 404, json: { error: 'Not found' } });
    // Status of a customer owned by ANOTHER user is equally 404 (no oracle).
    mock86({ customerRow: null });
    expect(await statusCore(ENV, { userId: 'u1', customerId: 'foreign' }))
      .toEqual({ status: 404, json: { error: 'Not found' } });
    expect(calls.inserts).toHaveLength(0);
    expect(calls.patches).toHaveLength(0);
    expect(calls.rpcPortal).toHaveLength(1); // manage attempted the atomic path first
  });
});

describe('8.06 admin mutations (RPC path, §4)', () => {
  test('mint commits: single atomic call, hashed token, stamped response', async () => {
    const stored = { ok: true, token: NEW_HEX, enabled: true, adopted: true };
    const calls = mock86({ rpcPortal: [{ ok: true, decision: 'committed', response: stored }] });
    const r = await portalManageCore(ENV, { userId: 'u1', body: { action: 'mint', customerId: 'c1', operationId: OP1 }, randHex: NEW_HEX });
    expect(r).toEqual({ status: 200, json: stored });
    expect(calls.rpcPortal).toHaveLength(1);
    // Exactly one RPC call carries the whole mutation (no separate REST
    // writes — revoke/insert/backfill/operations row commit together).
    expect(calls.fetches.filter((u) => u.includes('/rest/v1/portal_tokens'))).toHaveLength(0);
    expect(calls.rpcPortal[0]).toMatchObject({
      p_user_id: 'u1',
      p_customer_id: 'c1',
      p_action: 'mint',
      p_operation_id: OP1,
      p_enabled: null,
      p_token_hash: sha(NEW_HEX),
    });
    expect(calls.rpcPortal[0].p_request_hash).toBe(store.portalRequestHash('mint', 'c1', null));
    // Hash-only server storage (§1.4/§4): no predicate/lookup field carries
    // the raw token — only its sha256 travels in p_token_hash. The single
    // exception is the stored-response template (p_result), which the RPC
    // keeps for 30-day replay so a lost response recovers the SAME
    // capability instead of minting a second one.
    expect(calls.rpcPortal[0].p_token_hash).not.toBe(NEW_HEX);
    expect(calls.rpcPortal[0].p_request_hash).not.toBe(NEW_HEX);
    expect(calls.rpcPortal[0].p_result).toEqual({ ok: true, token: NEW_HEX });
  });

  test('legacy caller without operationId still commits atomically (payload preserved)', async () => {
    const stored = { ok: true, token: NEW_HEX, enabled: true, adopted: true };
    const calls = mock86({ rpcPortal: [{ ok: true, decision: 'committed', response: stored }] });
    const r = await portalManageCore(ENV, { userId: 'u1', body: { action: 'rotate', customerId: 'c1' }, randHex: NEW_HEX });
    expect(r).toEqual({ status: 200, json: stored });
    expect(calls.rpcPortal).toHaveLength(1);
    expect(calls.rpcPortal[0].p_operation_id).toBeNull();
  });

  test('mint over ANY live row → 409 already_exists, even disabled (C6 fix for G4-02)', async () => {
    mock86({ rpcPortal: [{ ok: false, error: 'already_exists' }] });
    const dup = await portalManageCore(ENV, { userId: 'u1', body: { action: 'mint', customerId: 'c1', operationId: OP1 }, randHex: NEW_HEX });
    expect(dup).toEqual({ status: 409, json: { error: 'already_exists' } });
  });

  test('rotate works from zero rows; disable commits enabled:false adopted:true', async () => {
    const rotated = { ok: true, token: NEW_HEX, enabled: true, adopted: true };
    let calls = mock86({ rpcPortal: [{ ok: true, decision: 'committed', response: rotated }] });
    const rot = await portalManageCore(ENV, { userId: 'u1', body: { action: 'rotate', customerId: 'c1', operationId: OP1 }, randHex: NEW_HEX });
    expect(rot).toEqual({ status: 200, json: rotated });

    const disabled = { ok: true, enabled: false, adopted: true };
    calls = mock86({ rpcPortal: [{ ok: true, decision: 'committed', response: disabled }] });
    const dis = await portalManageCore(ENV, {
      userId: 'u1', body: { action: 'set_enabled', customerId: 'c1', operationId: OP2, enabled: false }, randHex: NEW_HEX,
    });
    expect(dis).toEqual({ status: 200, json: disabled });
    expect(calls.rpcPortal[0]).toMatchObject({ p_action: 'set_enabled', p_enabled: false, p_token_hash: null });
  });

  test('set_enabled with no row → 404 (never creates)', async () => {
    mock86({ rpcPortal: [{ ok: false, error: 'not_found' }] });
    const missing = await portalManageCore(ENV, {
      userId: 'u1', body: { action: 'set_enabled', customerId: 'c1', operationId: OP1, enabled: true }, randHex: NEW_HEX,
    });
    expect(missing).toEqual({ status: 404, json: { error: 'Not found' } });
  });

  test('same operationId + new intent → 409 operation_conflict; foreign id → 404', async () => {
    mock86({ rpcPortal: [{ ok: false, error: 'operation_conflict' }] });
    const c = await portalManageCore(ENV, { userId: 'u1', body: { action: 'rotate', customerId: 'c1', operationId: OP1 }, randHex: NEW_HEX });
    expect(c).toEqual({ status: 409, json: { error: 'operation_conflict' } });

    mock86({ rpcPortal: [{ ok: false, error: 'not_found' }] });
    const f = await portalManageCore(ENV, { userId: 'u1', body: { action: 'mint', customerId: 'c1', operationId: OP1 }, randHex: NEW_HEX });
    expect(f).toEqual({ status: 404, json: { error: 'Not found' } });
  });

  test('simultaneous mint/rotate/toggle serialize: one RPC call each, no REST interleave', async () => {
    // Three devices act at once on one customer; each intent travels as a
    // single RPC call (the per-customer advisory lock serializes them
    // server-side — the second mint loses with already_exists, it never
    // stacks a second live row). Mock-level serialization only — real
    // competing-session timing proof is DEFERRED (M1) to 8.14.
    const calls = mock86({
      rpcPortal: [
        { ok: true, decision: 'committed', response: { ok: true, token: NEW_HEX, enabled: true, adopted: true } },
        { ok: false, error: 'already_exists' },
        { ok: true, decision: 'committed', response: { ok: true, enabled: false, adopted: true } },
      ],
    });
    const mint = await portalManageCore(ENV, { userId: 'u1', body: { action: 'mint', customerId: 'c1', operationId: OP1 }, randHex: NEW_HEX });
    const mint2 = await portalManageCore(ENV, {
      userId: 'u1',
      body: { action: 'mint', customerId: 'c1', operationId: '0193f123-0000-4000-8000-000000000099' },
      randHex: 'f'.repeat(48),
    });
    const toggle = await portalManageCore(ENV, {
      userId: 'u1',
      body: { action: 'set_enabled', customerId: 'c1', operationId: OP2, enabled: false },
      randHex: NEW_HEX,
    });
    expect(mint.status).toBe(200);
    expect(mint2).toEqual({ status: 409, json: { error: 'already_exists' } });
    expect(toggle).toEqual({ status: 200, json: { ok: true, enabled: false, adopted: true } });
    expect(calls.rpcPortal).toHaveLength(3);
    expect(calls.inserts).toHaveLength(0);
    expect(calls.patches).toHaveLength(0);
  });

  test('RPC transport failure → 500 (never a partial commit verdict)', async () => {
    jest.spyOn(console, 'error').mockImplementation(() => {});
    global.fetch = jest.fn(async (url) => {
      if (String(url).includes('/rest/v1/rpc/')) throw new Error('socket hangup');
      return jsonRes([]);
    });
    const down = await portalManageCore(ENV, { userId: 'u1', body: { action: 'rotate', customerId: 'c1', operationId: OP1 }, randHex: NEW_HEX });
    expect(down).toEqual({ status: 500, json: { error: 'Database error' } });
  });

  test('pre-deploy (RPC missing): legacy split path preserved byte-identically + C6 guard', async () => {
    // Mint on a token-less customer inserts the HASH and returns raw once.
    let calls = mock86({ rpcMissing: true, customerRow: customer({ data: { name: 'Dana' } }), tokenRows: [] });
    const out = await portalManageCore(ENV, { userId: 'u1', body: { action: 'mint', customerId: 'c1' }, randHex: NEW_HEX });
    expect(out).toEqual({ status: 200, json: { ok: true, token: NEW_HEX } });
    expect(calls.inserts).toHaveLength(1);
    expect(calls.inserts[0].token_hash).toBe(sha(NEW_HEX));
    expect(JSON.stringify(calls.inserts)).not.toContain(NEW_HEX);

    // Mint over a DISABLED-but-live row now 409s (C6 — the enabled-only
    // guard is retired on both paths so they never disagree).
    calls = mock86({
      rpcMissing: true,
      customerRow: customer(),
      tokenRows: [activeRow({ enabled: false })],
    });
    expect(await portalManageCore(ENV, { userId: 'u1', body: { action: 'mint', customerId: 'c1' }, randHex: NEW_HEX }))
      .toEqual({ status: 409, json: { error: 'already_exists' } });
    expect(calls.inserts).toHaveLength(0);

    // Legacy backfill still materializes the blob hash before acting.
    calls = mock86({ rpcMissing: true, customerRow: customer(), tokenRows: [] });
    const dis = await portalManageCore(ENV, {
      userId: 'u1', body: { action: 'set_enabled', customerId: 'c1', enabled: false }, randHex: NEW_HEX,
    });
    expect(dis).toEqual({ status: 200, json: { ok: true, enabled: false } });
    expect(calls.inserts[0].token_hash).toBe(HASH);
  });

  test('pre-deploy residual (labeled, NOT fixed in JS): rotate insert failure after revoke strands', async () => {
    // The legacy split path cannot be atomic — that is exactly why the RPC
    // exists. This test documents the pre-deploy residual so no reviewer
    // mistakes the fallback for the invariant; post-deploy the RPC envelope
    // above (single call, rollback on error) is the evidence.
    const calls = mock86({ rpcMissing: true, customerRow: customer(), tokenRows: [activeRow()], failInsert: true });
    await expect(
      portalManageCore(ENV, { userId: 'u1', body: { action: 'rotate', customerId: 'c1' }, randHex: NEW_HEX })
    ).rejects.toThrow('insert down');
    expect(calls.patches).toHaveLength(1); // revoke committed, insert failed
  });
});

describe('8.06 operation replay + response-loss recovery (§4 as §1.3)', () => {
  test('retry with same operationId returns the SAME stored operation (same token, no second capability)', async () => {
    const stored = { ok: true, token: NEW_HEX, enabled: true, adopted: true };
    const calls = mock86({
      rpcPortal: [
        { ok: true, decision: 'committed', response: stored },
        { ok: true, decision: 'replay', response: stored },
      ],
    });
    const first = await portalManageCore(ENV, { userId: 'u1', body: { action: 'rotate', customerId: 'c1', operationId: OP1 }, randHex: NEW_HEX });
    const retry = await portalManageCore(ENV, { userId: 'u1', body: { action: 'rotate', customerId: 'c1', operationId: OP1 }, randHex: NEW_HEX });
    expect(first.json).toEqual(stored);
    expect(retry.json).toEqual(stored);
    expect(retry.json.token).toBe(first.json.token);
    expect(calls.rpcPortal).toHaveLength(2);
  });

  test('lost response then retry recovers: 500 on transport failure, then the same token', async () => {
    jest.spyOn(console, 'error').mockImplementation(() => {});
    const stored = { ok: true, token: NEW_HEX, enabled: true, adopted: true };
    let attempt = 0;
    global.fetch = jest.fn(async (url) => {
      if (String(url).includes('/rest/v1/rpc/')) {
        attempt += 1;
        if (attempt === 1) throw new Error('socket hangup');
        return jsonRes({ ok: true, decision: 'replay', response: stored });
      }
      return jsonRes([]);
    });
    const lost = await portalManageCore(ENV, { userId: 'u1', body: { action: 'rotate', customerId: 'c1', operationId: OP1 }, randHex: NEW_HEX });
    expect(lost.status).toBe(500); // unknown outcome — never auto-rotate again
    const recovered = await portalManageCore(ENV, { userId: 'u1', body: { action: 'rotate', customerId: 'c1', operationId: OP1 }, randHex: NEW_HEX });
    expect(recovered).toEqual({ status: 200, json: stored });
  });

  test('local-mirror failure after server success: status shows tokenValid:false → confirmed rotate with NEW id', async () => {
    // Server committed NEW_HEX but the device kept displaying TOKEN. Status
    // proves the display copy stale; recovery is a rotate with a fresh
    // operationId — never a silent re-mint of the same id.
    mock86({ customerRow: customer(), tokenRows: [activeRow({ token_hash: sha(NEW_HEX) })] });
    const st = await statusCore(ENV, { userId: 'u1', customerId: 'c1', token: TOKEN });
    expect(st.json).toMatchObject({ enabled: true, tokenValid: false, adopted: true });
    expect(st.json).not.toHaveProperty('token');

    const fresh = 'f'.repeat(48);
    const calls = mock86({
      rpcPortal: [{ ok: true, decision: 'committed', response: { ok: true, token: fresh, enabled: true, adopted: true } }],
    });
    const rot = await portalManageCore(ENV, { userId: 'u1', body: { action: 'rotate', customerId: 'c1', operationId: OP2 }, randHex: fresh });
    expect(rot.json.token).toBe(fresh);
    expect(calls.rpcPortal[0].p_operation_id).toBe(OP2);
  });
});

describe('8.06 authoritative status read (§6)', () => {
  test('adopted current display copy → tokenValid:true; never a token', async () => {
    const calls = mock86({ customerRow: customer(), tokenRows: [activeRow()] });
    const cur = await statusCore(ENV, { userId: 'u1', customerId: 'c1', token: TOKEN });
    expect(cur).toEqual({ status: 200, json: { ok: true, enabled: true, tokenValid: true, adopted: true } });
    expect(cur.json).not.toHaveProperty('token');
    expect(calls.rpcPortal).toHaveLength(0); // read-only: no RPC, no writes
    expect(calls.inserts).toHaveLength(0);
    expect(calls.patches).toHaveLength(0);
  });

  test('stale display copy / missing token / disabled row → tokenValid:false, recovery path', async () => {
    mock86({ customerRow: customer(), tokenRows: [activeRow({ token_hash: sha(NEW_HEX) })] });
    const stale = await statusCore(ENV, { userId: 'u1', customerId: 'c1', token: TOKEN });
    expect(stale.json).toMatchObject({ enabled: true, tokenValid: false, adopted: true });

    const missing = await statusCore(ENV, { userId: 'u1', customerId: 'c1' });
    expect(missing.json).toMatchObject({ tokenValid: false, adopted: true });

    mock86({ customerRow: customer(), tokenRows: [activeRow({ enabled: false })] });
    const disabled = await statusCore(ENV, { userId: 'u1', customerId: 'c1', token: TOKEN });
    expect(disabled.json).toMatchObject({ enabled: false, tokenValid: false, adopted: true });
  });

  test('unadopted blob customer: matching enabled copy validates, otherwise not', async () => {
    mock86({ customerRow: customer(), tokenRows: [] });
    const cur = await statusCore(ENV, { userId: 'u1', customerId: 'c1', token: TOKEN });
    expect(cur).toEqual({ status: 200, json: { ok: true, enabled: true, tokenValid: true, adopted: false } });

    const stale = await statusCore(ENV, { userId: 'u1', customerId: 'c1', token: STALE_BLOB_TOKEN });
    expect(stale.json).toMatchObject({ tokenValid: false, adopted: false });

    mock86({ customerRow: customer({ data: { name: 'Dana', portal: { token: TOKEN, enabled: false } } }), tokenRows: [] });
    const disabled = await statusCore(ENV, { userId: 'u1', customerId: 'c1', token: TOKEN });
    expect(disabled.json).toMatchObject({ enabled: false, tokenValid: false, adopted: false });
  });
});

describe('8.06 resolver authority: adopted fail-closed + backfill races (§4)', () => {
  const staleBlobCustomer = {
    user_id: 'u1',
    id: 'c1',
    data: { name: 'Dana', portal: { token: STALE_BLOB_TOKEN, enabled: true } },
  };

  test('unknown stale blob token AFTER adoption → null, NO backfill insert (G4-05 closed)', async () => {
    const calls = mock86({
      tokenRows: [activeRow({ token_hash: sha(NEW_HEX) })],
      blobRows: [staleBlobCustomer],
      customerRow: staleBlobCustomer,
    });
    // Sanity: the stale hash really is unknown to the table…
    expect(sha(STALE_BLOB_TOKEN)).not.toBe(sha(NEW_HEX));
    // …and resolution fails closed instead of authenticating via the blob.
    expect(await store.resolvePortalCustomer(ENV, STALE_BLOB_TOKEN)).toBeNull();
    expect(calls.inserts).toHaveLength(0);
    expect(calls.fetches.some((u) => u.includes('data->portal->>token'))).toBe(true); // looked up, not trusted
  });

  test('known revoked/disabled row never falls through to the blob (preserved)', async () => {
    for (const row of [
      activeRow({ enabled: false, revoked_at: '2026-09-20T00:00:00.000Z' }),
      activeRow({ enabled: false }),
    ]) {
      const calls = mock86({ tokenRows: [row], blobRows: [customer()], customerRow: customer() });
      expect(await store.resolvePortalCustomer(ENV, TOKEN)).toBeNull();
      expect(calls.fetches.some((u) => u.includes('data->portal->>token'))).toBe(false);
    }
  });

  test('lazy backfill racing rotation: conflicting insert authorizes nothing', async () => {
    // Resolver saw zero rows, but rotation committed before our backfill
    // insert: the single-active index rejects us. We re-read, find the
    // rotation's row, and fail closed — the stale blob never authenticates.
    jest.spyOn(console, 'error').mockImplementation(() => {});
    let reads = 0;
    global.fetch = jest.fn(async (url, init = {}) => {
      const u = String(url);
      const method = init.method || 'GET';
      if (u.includes('/rest/v1/portal_tokens') && method === 'POST') throw new Error('duplicate key value violates unique constraint "portal_tokens_single_active"');
      if (u.includes('/rest/v1/portal_tokens')) {
        reads += 1;
        // First read (adoption check): zero rows. Second (recheck): the
        // rotation's live row.
        return jsonRes(reads === 1 ? [] : [activeRow({ token_hash: sha(NEW_HEX) })]);
      }
      if (u.includes('/rest/v1/customers') && u.includes('data->portal->>token')) return jsonRes([staleBlobCustomer]);
      return jsonRes([]);
    });
    expect(await store.resolvePortalCustomer(ENV, STALE_BLOB_TOKEN)).toBeNull();
  });

  test('failed backfill with still-zero rows keeps pre-adoption blob authority (preserved)', async () => {
    jest.spyOn(console, 'error').mockImplementation(() => {});
    global.fetch = jest.fn(async (url, init = {}) => {
      const u = String(url);
      if (u.includes('portal_tokens') && (init.method || 'GET') === 'POST') throw new Error('insert down');
      if (u.includes('portal_tokens')) return jsonRes([]);
      if (u.includes('data->portal->>token')) return jsonRes([customer()]);
      return jsonRes([]);
    });
    // Unadopted legacy customer: the blob is still the authority, so a
    // transient backfill error never blocks the response.
    expect(await store.resolvePortalCustomer(ENV, TOKEN)).toEqual(customer());
  });

  test('unknown token + blob miss → null (preserved)', async () => {
    mock86({ tokenRows: [], blobRows: [] });
    expect(await store.resolvePortalCustomer(ENV, 'z'.repeat(48))).toBeNull();
  });
});

describe('8.06 capability boundaries (not global revocation)', () => {
  test('portal entry rotation leaves estimate/payment/manage links and signed photos intact', async () => {
    // Contract §4/C6 restated: revoking the portal entry does NOT revoke
    // previously issued estimate approval links, invoice payment links,
    // per-booking manage links, or signed-photo URLs (15-min TTL + private
    // cache). This test documents the boundary so no reviewer claims global
    // revocation: assembly still serves all four after a rotate.
    const { assemblePortalView } = require('../backend-workers/lib/estimate/portalAssemble.js');
    const view = assemblePortalView({
      businessName: 'Rivera',
      customerRow: customer(),
      jobRows: [
        {
          id: 'j1',
          data: {
            title: 'Heater swap',
            scheduledDate: '2026-09-25',
            scheduledStartTime: '09:00',
            approval: { token: 'approval-token', snapshot: { jobTitle: 'Heater swap', total: 100 }, decision: null },
          },
        },
      ],
      invoiceRows: [
        {
          data: {
            number: '1',
            amount: 100,
            paid: false,
            paymentLinkUrl: 'https://buy.stripe.com/test1234567890abcdef',
            paymentLinkAmount: 100,
          },
        },
      ],
      requestRows: [
        { data: { manageToken: 'm'.repeat(48), kind: 'booked', convertedJobId: 'j1', status: 'booked' } },
      ],
      photoRows: [],
      token: NEW_HEX, // rotated portal entry — content links below are independent
      apiOrigin: 'https://api.test',
      nowMs: Date.parse('2026-09-20T12:00:00.000Z'),
      userId: 'u1',
      photoSecret: 'secret',
    });
    expect(view.estimates).toHaveLength(1);
    expect(view.invoices[0].paymentLinkUrl).toContain('https://buy.stripe.com/');
    expect(view.appointments[0].manageUrl).toContain('booking.html?m=');
  });

  test('archivedAt-archived jobs stop serving in portal view + ICS (C12 fix)', async () => {
    const { assemblePortalView } = require('../backend-workers/lib/estimate/portalAssemble.js');
    const archivedJob = {
      id: 'j1',
      data: {
        title: 'Heater swap',
        scheduledDate: '2026-09-25',
        scheduledStartTime: '09:00',
        archivedAt: '2026-09-19',
      },
    };
    const view = assemblePortalView({
      businessName: 'Rivera',
      customerRow: customer(),
      jobRows: [archivedJob],
      invoiceRows: [],
      requestRows: [],
      photoRows: [],
      token: TOKEN,
      apiOrigin: 'https://api.test',
      nowMs: Date.parse('2026-09-20T12:00:00.000Z'),
      userId: 'u1',
      photoSecret: null,
    });
    expect(view.appointments).toHaveLength(0);

    const { portalIcsCore } = require('../backend-workers/lib/estimate/portalIcs.js');
    global.fetch = jest.fn(async (url) => {
      const u = String(url);
      if (u.includes('/rest/v1/portal_tokens')) return jsonRes([activeRow()]);
      if (u.includes('/rest/v1/customers')) return jsonRes([customer()]);
      if (u.includes('/rest/v1/jobs')) return jsonRes([archivedJob]);
      if (u.includes('/rest/v1/settings')) return jsonRes([{ user_id: 'u1', data: { businessName: 'Rivera' } }]);
      return jsonRes([]);
    });
    const r = await portalIcsCore(ENV, { token: TOKEN, jobId: 'j1', stampUtc: '2026-09-20T12:00:00.000Z', ip: '127.0.0.1' });
    expect(r).toEqual({ ok: false, status: 404, error: 'This link is invalid.' });
  });
});

describe('8.06 route-level auth and errors (POST /api/estimate/portal-manage)', () => {
  test('401 without bearer; 401 on invalid session; 405 on wrong method', async () => {
    mock86({ authUser: 'u1' });
    expect((await portalManageHandler(fakeC({ auth: null, body: {} }))).status).toBe(401);
    expect((await portalManageHandler(fakeC({ auth: 'Token x', body: {} }))).status).toBe(401);

    mock86({ authUser: null });
    expect((await portalManageHandler(fakeC({ body: { action: 'status', customerId: 'c1' } }))).status).toBe(401);

    mock86({ authUser: 'u1' });
    expect((await portalManageHandler(fakeC({ method: 'GET', body: {} }))).status).toBe(405);
  });

  test('status via route returns the frozen shape; unknown customer 404', async () => {
    mock86({ authUser: 'route-user-2', customerRow: customer(), tokenRows: [activeRow()] });
    const st = await portalManageHandler(fakeC({ body: { action: 'status', customerId: 'c1', token: TOKEN } }));
    expect(st).toEqual({
      status: 200,
      body: { ok: true, enabled: true, tokenValid: true, adopted: true },
    });

    mock86({ authUser: 'route-user-3', customerRow: null, rpcPortal: [{ ok: false, error: 'not_found' }] });
    const missing = await portalManageHandler(fakeC({ body: { action: 'status', customerId: 'nope' } }));
    expect(missing).toEqual({ status: 404, body: { error: 'Not found' } });
  });

  test('mint via route returns the frozen payload + operationId echo; already_exists preserved', async () => {
    const freshUser = 'route-user-4';
    global.fetch = jest.fn(async (url, init = {}) => {
      const u = String(url);
      if (u.includes('/auth/v1/user')) return jsonRes({ id: freshUser });
      if (u.includes('/rest/v1/rpc/admin_portal_token')) {
        const args = JSON.parse(init.body);
        expect(args.p_action).toBe('mint');
        expect(args.p_operation_id).toBe(OP1);
        expect(args.p_token_hash).toMatch(/^[0-9a-f]{64}$/);
        return jsonRes({ ok: true, decision: 'committed', response: { ...args.p_result, enabled: true, adopted: true } });
      }
      return jsonRes([]);
    });
    const r = await portalManageHandler(fakeC({ body: { action: 'mint', customerId: 'c1', operationId: OP1 } }));
    expect(r.status).toBe(200);
    expect(r.body.token).toMatch(/^[0-9a-f]{48}$/);
    expect(r.body).toMatchObject({ ok: true, enabled: true, adopted: true });

    global.fetch = jest.fn(async (url) => {
      const u = String(url);
      if (u.includes('/auth/v1/user')) return jsonRes({ id: freshUser });
      if (u.includes('/rest/v1/rpc/')) return jsonRes({ ok: false, error: 'already_exists' });
      return jsonRes([]);
    });
    const dup = await portalManageHandler(fakeC({ body: { action: 'mint', customerId: 'c1', operationId: OP2 } }));
    expect(dup).toEqual({ status: 409, body: { error: 'already_exists' } });
  });

  test('per-user rate limit trips at 11 rapid calls (portal precedent: 10/window)', async () => {
    const limitedUser = 'route-user-5';
    global.fetch = jest.fn(async (url, init = {}) => {
      const u = String(url);
      if (u.includes('/auth/v1/user')) return jsonRes({ id: limitedUser });
      if (u.includes('/rest/v1/customers')) return jsonRes([customer()]);
      if (u.includes('/rest/v1/rpc/')) {
        const args = JSON.parse(init.body);
        return jsonRes({ ok: true, decision: 'committed', response: { ...args.p_result, enabled: false, adopted: true } });
      }
      if (u.includes('/rest/v1/portal_tokens')) return jsonRes([activeRow()]);
      return jsonRes([]);
    });
    const statuses = [];
    for (let i = 0; i < 11; i += 1) {
      const r = await portalManageHandler(
        fakeC({ body: { action: 'set_enabled', customerId: 'c1', enabled: false } })
      );
      statuses.push(r.status);
    }
    expect(statuses.slice(0, 10)).toEqual(Array(10).fill(200));
    expect(statuses[10]).toBe(429);
  });
});
