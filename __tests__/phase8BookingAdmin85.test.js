// __tests__/phase8BookingAdmin85.test.js
// Task 8.05 — Server-authoritative booking links (contract §1, §3, §5 G3).
//
// Server-precondition level, same discipline as the 8.04 suite: the fetch
// mock stands in for PostgREST + the 20260921_booking_admin_state.sql RPC.
// Scripted `admin_booking_link` envelopes let each test pin the CORE's
// contract behavior (verdict mapping, single atomic call, replay recovery,
// error vocabulary). The DUAL-READ authority in lookupUserByBookingToken is
// real JS logic and is exercised against scripted TABLE rows (not envelopes).
// This is NOT database race evidence: competing-session timing proof is
// deferred to Phase 12 / task 8.14 (M1) and labeled as such wherever the
// suite touches linearization.
//
// The 8.00 characterization files are left intact except G3-01 (which pinned
// the ABSENCE of /api/booking/admin — now implemented; see note there).

const { createHash } = require('node:crypto');
const {
  adminCore,
  statusCore,
  requestHash,
} = require('../backend-workers/lib/booking/admin.js');
const {
  lookupUserByBookingToken,
} = require('../backend-workers/lib/booking/store.js');
const { bookingAdminHandler } = require('../backend-workers/src/routes/booking/admin.js');

const ENV = { SUPABASE_URL: 'https://supa.test', SUPABASE_SERVICE_ROLE_KEY: 'srk' };
const sha = (s) => createHash('sha256').update(s, 'utf8').digest('hex');

const OLD_TOKEN = '0'.repeat(48);
const NEW_TOKEN = 'a'.repeat(48);
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

// Scripted backend. settingsBlob: rows for the JSON-path blob lookup.
// linkState: rows for booking_link_state (by hash or by user_id).
// settingsByUser: rows for the adopted-branch settings fetch.
// tableMissing: every booking_link_state read answers 404 (pre-deploy).
// rpcAdmin: FIFO envelopes for /rpc/admin_booking_link.
// authUser: id returned by /auth/v1/user (null → session invalid).
function mock85({
  settingsBlob = [],
  linkState = [],
  settingsByUser = [],
  tableMissing = false,
  rpcAdmin = [],
  authUser = 'u1',
} = {}) {
  const calls = { rpcAdmin: [], fetches: [] };
  const q = [...rpcAdmin];
  global.fetch = jest.fn(async (url, init = {}) => {
    const u = String(url);
    calls.fetches.push(u);
    if (u.includes('/rest/v1/rpc/admin_booking_link')) {
      calls.rpcAdmin.push(JSON.parse(init.body));
      return jsonRes(q.length ? q.shift() : { ok: false, error: 'invalid_args' });
    }
    if (u.includes('/rest/v1/booking_link_state')) {
      if (tableMissing) return jsonRes({ message: 'relation not found' }, 404);
      const hm = u.match(/token_hash=eq\.([^&]*)/);
      const um = u.match(/user_id=eq\.([^&]*)/);
      if (hm) return jsonRes(linkState.filter((r) => r.token_hash === decodeURIComponent(hm[1])));
      if (um) return jsonRes(linkState.filter((r) => r.user_id === decodeURIComponent(um[1])));
      return jsonRes(linkState);
    }
    if (u.includes('/rest/v1/settings')) {
      if (u.includes('bookingLink->>token')) {
        const m = u.match(/bookingLink->>token=eq\.([^&]*)/);
        const token = m ? decodeURIComponent(m[1]) : null;
        const enabledOnly = u.includes('bookingLink->>enabled=eq.true');
        return jsonRes(
          settingsBlob.filter((r) => {
            const link = r.data && r.data.bookingLink;
            if (!link || (token && link.token !== token)) return false;
            if (enabledOnly && link.enabled !== true) return false;
            return true;
          })
        );
      }
      const um = u.match(/user_id=eq\.([^&]*)/);
      if (um) return jsonRes(settingsByUser.filter((r) => r.user_id === decodeURIComponent(um[1])));
      return jsonRes([]);
    }
    if (u.includes('/auth/v1/user')) {
      if (!authUser) return jsonRes({ message: 'bad' }, 401);
      return jsonRes({ id: authUser });
    }
    return jsonRes([]);
  });
  return calls;
}

const blobRow = (token, enabled = true, userId = 'u1') => ({
  user_id: userId,
  data: {
    businessName: 'Rivera Plumbing',
    bookingLink: { token, enabled },
    schedule: { timeZone: 'America/Chicago', bookableSlotsEnabled: true },
  },
});
const stateRow = (over = {}) => ({
  user_id: 'u1',
  token_hash: sha(OLD_TOKEN),
  enabled: true,
  revision: 1,
  adopted_at: '2026-09-20T00:00:00.000Z',
  ...over,
});

function fakeC({ method = 'POST', body = {}, auth = 'Bearer good', authUser } = {}) {
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
    __authUser: authUser,
  };
}

afterEach(() => {
  delete global.fetch;
  jest.restoreAllMocks();
});

describe('8.05 admin input validation (no backend contact on 400)', () => {
  test('unknown/missing action → 400 Invalid action', async () => {
    const calls = mock85();
    for (const body of [{}, { action: 'nuke' }, { action: 'mint ' }]) {
      const r = await adminCore(ENV, { userId: 'u1', body, rawToken: NEW_TOKEN });
      expect(r).toEqual({ status: 400, body: { error: 'Invalid action.' } });
    }
    expect(calls.fetches).toHaveLength(0);
  });

  test('mutation without operationId / with malformed id → 400', async () => {
    mock85();
    expect(await adminCore(ENV, { userId: 'u1', body: { action: 'mint' }, rawToken: NEW_TOKEN }))
      .toEqual({ status: 400, body: { error: 'Missing operation id.' } });
    expect(await adminCore(ENV, { userId: 'u1', body: { action: 'rotate', operationId: 'not-a-uuid' }, rawToken: NEW_TOKEN }))
      .toEqual({ status: 400, body: { error: 'Invalid operation id.' } });
    // UUID shape but not v4 is rejected (contract: client-generated UUID v4).
    expect(await adminCore(ENV, { userId: 'u1', body: { action: 'mint', operationId: '0193f123-0000-1000-8000-000000000001' }, rawToken: NEW_TOKEN }))
      .toEqual({ status: 400, body: { error: 'Invalid operation id.' } });
  });

  test('set_enabled requires a boolean; expectedRevision must be a non-negative int', async () => {
    mock85();
    expect(await adminCore(ENV, { userId: 'u1', body: { action: 'set_enabled', operationId: OP1 }, rawToken: NEW_TOKEN }))
      .toEqual({ status: 400, body: { error: 'Invalid enabled value.' } });
    expect(await adminCore(ENV, { userId: 'u1', body: { action: 'set_enabled', operationId: OP1, enabled: 'yes' }, rawToken: NEW_TOKEN }))
      .toEqual({ status: 400, body: { error: 'Invalid enabled value.' } });
    expect(await adminCore(ENV, { userId: 'u1', body: { action: 'rotate', operationId: OP1, expectedRevision: -1 }, rawToken: NEW_TOKEN }))
      .toEqual({ status: 400, body: { error: 'Invalid expected revision.' } });
    expect(await adminCore(ENV, { userId: 'u1', body: { action: 'rotate', operationId: OP1, expectedRevision: '1' }, rawToken: NEW_TOKEN }))
      .toEqual({ status: 400, body: { error: 'Invalid expected revision.' } });
  });
});

describe('8.05 admin mutations (RPC path, §1)', () => {
  test('mint commits: single atomic call, hashed token, stamped response', async () => {
    const stored = { ok: true, enabled: true, token: NEW_TOKEN, revision: 1, operationId: OP1 };
    const calls = mock85({ rpcAdmin: [{ ok: true, decision: 'committed', response: stored }] });
    const r = await adminCore(ENV, { userId: 'u1', body: { action: 'mint', operationId: OP1 }, rawToken: NEW_TOKEN });
    expect(r).toEqual({ status: 200, body: stored });
    expect(calls.rpcAdmin).toHaveLength(1);
    // Exactly one RPC call carries the whole mutation (no separate REST
    // writes — revision bump + token row + operations row commit together).
    expect(calls.fetches.filter((u) => u.includes('/rest/v1/booking_link_state'))).toHaveLength(0);
    expect(calls.rpcAdmin[0]).toMatchObject({
      p_user_id: 'u1',
      p_action: 'mint',
      p_operation_id: OP1,
      p_request_hash: requestHash('mint', null),
      p_enabled: null,
      p_expected_revision: null,
      p_token_hash: sha(NEW_TOKEN),
    });
    expect(calls.rpcAdmin[0].p_result).toEqual({ ok: true, operationId: OP1, token: NEW_TOKEN });
    // Hash-only server storage (§1.4): no predicate/lookup field carries the
    // raw token — only its sha256 travels in p_token_hash. The single
    // exception is the stored-response template (p_result), which the RPC
    // keeps for 30-day replay so a lost response recovers the SAME
    // capability instead of minting a second one (§1.3).
    expect(calls.rpcAdmin[0].p_token_hash).not.toBe(NEW_TOKEN);
    expect(calls.rpcAdmin[0].p_request_hash).not.toBe(NEW_TOKEN);
    expect(calls.rpcAdmin[0].p_token_hash).toBe(sha(NEW_TOKEN));
  });

  test('rotate works from zero rows; disable commits enabled:false', async () => {
    const rotated = { ok: true, enabled: true, token: NEW_TOKEN, revision: 1, operationId: OP1 };
    let calls = mock85({ rpcAdmin: [{ ok: true, decision: 'committed', response: rotated }] });
    const rot = await adminCore(ENV, { userId: 'u1', body: { action: 'rotate', operationId: OP1 }, rawToken: NEW_TOKEN });
    expect(rot).toEqual({ status: 200, body: rotated });

    const disabled = { ok: true, enabled: false, revision: 2, operationId: OP2 };
    calls = mock85({ rpcAdmin: [{ ok: true, decision: 'committed', response: disabled }] });
    const dis = await adminCore(ENV, {
      userId: 'u1', body: { action: 'set_enabled', operationId: OP2, enabled: false }, rawToken: NEW_TOKEN,
    });
    expect(dis).toEqual({ status: 200, body: disabled });
    expect(calls.rpcAdmin[0]).toMatchObject({
      p_action: 'set_enabled', p_enabled: false, p_token_hash: null,
    });
  });

  test('mint over an enabled token → 409 already_exists; set_enabled with no row → 404', async () => {
    mock85({ rpcAdmin: [{ ok: false, error: 'already_exists' }] });
    const dup = await adminCore(ENV, { userId: 'u1', body: { action: 'mint', operationId: OP1 }, rawToken: NEW_TOKEN });
    expect(dup).toEqual({ status: 409, body: { error: 'already_exists' } });

    mock85({ rpcAdmin: [{ ok: false, error: 'not_found' }] });
    const missing = await adminCore(ENV, {
      userId: 'u1', body: { action: 'set_enabled', operationId: OP1, enabled: true }, rawToken: NEW_TOKEN,
    });
    expect(missing).toEqual({ status: 404, body: { error: 'Not found' } });
  });

  test('stale expectedRevision → 409 with current state echoed; absent → last-writer-wins', async () => {
    mock85({ rpcAdmin: [{ ok: false, error: 'stale_revision', enabled: true, revision: 4 }] });
    const stale = await adminCore(ENV, {
      userId: 'u1', body: { action: 'set_enabled', operationId: OP1, enabled: false, expectedRevision: 1 }, rawToken: NEW_TOKEN,
    });
    expect(stale).toEqual({ status: 409, body: { error: 'stale_revision', enabled: true, revision: 4 } });

    const committed = { ok: true, enabled: false, revision: 5, operationId: OP2 };
    const calls = mock85({ rpcAdmin: [{ ok: true, decision: 'committed', response: committed }] });
    const lww = await adminCore(ENV, {
      userId: 'u1', body: { action: 'set_enabled', operationId: OP2, enabled: false }, rawToken: NEW_TOKEN,
    });
    expect(lww).toEqual({ status: 200, body: committed });
    expect(calls.rpcAdmin[0].p_expected_revision).toBeNull();
  });

  test('same operationId + new intent → 409 operation_conflict; foreign id → 404', async () => {
    mock85({ rpcAdmin: [{ ok: false, error: 'operation_conflict' }] });
    const c = await adminCore(ENV, { userId: 'u1', body: { action: 'rotate', operationId: OP1 }, rawToken: NEW_TOKEN });
    expect(c).toEqual({ status: 409, body: { error: 'operation_conflict' } });

    mock85({ rpcAdmin: [{ ok: false, error: 'not_found' }] });
    const f = await adminCore(ENV, { userId: 'u1', body: { action: 'mint', operationId: OP1 }, rawToken: NEW_TOKEN });
    expect(f).toEqual({ status: 404, body: { error: 'Not found' } });
  });

  test('RPC not deployed / transport failure → 500 (new route has no legacy fallback)', async () => {
    jest.spyOn(console, 'error').mockImplementation(() => {});
    global.fetch = jest.fn(async (url) => {
      if (String(url).includes('/rest/v1/rpc/')) return jsonRes({ message: 'not found' }, 404);
      return jsonRes([]);
    });
    const missing = await adminCore(ENV, { userId: 'u1', body: { action: 'mint', operationId: OP1 }, rawToken: NEW_TOKEN });
    expect(missing.status).toBe(500);

    global.fetch = jest.fn(async () => { throw new Error('boom'); });
    const down = await adminCore(ENV, { userId: 'u1', body: { action: 'mint', operationId: OP1 }, rawToken: NEW_TOKEN });
    expect(down.status).toBe(500);
  });
});

describe('8.05 operation replay + response-loss recovery (§1.3)', () => {
  test('retry with same operationId returns the SAME stored operation (same token, no second capability)', async () => {
    const stored = { ok: true, enabled: true, token: NEW_TOKEN, revision: 3, operationId: OP1 };
    const calls = mock85({
      rpcAdmin: [
        { ok: true, decision: 'committed', response: stored },
        { ok: true, decision: 'replay', response: stored },
      ],
    });
    const first = await adminCore(ENV, { userId: 'u1', body: { action: 'rotate', operationId: OP1 }, rawToken: NEW_TOKEN });
    const retry = await adminCore(ENV, { userId: 'u1', body: { action: 'rotate', operationId: OP1 }, rawToken: NEW_TOKEN });
    expect(first.body).toEqual(stored);
    expect(retry.body).toEqual(stored);
    expect(retry.body.token).toBe(first.body.token);
    expect(retry.body.revision).toBe(3); // verbatim replay, not a second bump
    expect(calls.rpcAdmin).toHaveLength(2);
  });

  test('lost response then retry recovers: 500 on transport failure, then the same token', async () => {
    jest.spyOn(console, 'error').mockImplementation(() => {});
    const stored = { ok: true, enabled: true, token: NEW_TOKEN, revision: 1, operationId: OP1 };
    let attempt = 0;
    global.fetch = jest.fn(async (url) => {
      if (String(url).includes('/rest/v1/rpc/')) {
        attempt += 1;
        if (attempt === 1) throw new Error('socket hangup');
        return jsonRes({ ok: true, decision: 'replay', response: stored });
      }
      return jsonRes([]);
    });
    const lost = await adminCore(ENV, { userId: 'u1', body: { action: 'mint', operationId: OP1 }, rawToken: NEW_TOKEN });
    expect(lost.status).toBe(500); // unknown outcome — never auto-mint again
    const recovered = await adminCore(ENV, { userId: 'u1', body: { action: 'mint', operationId: OP1 }, rawToken: NEW_TOKEN });
    expect(recovered).toEqual({ status: 200, body: stored });
  });
});

describe('8.05 authoritative status read (§6)', () => {
  test('no state row → fresh-owner shape, never 404, never a token', async () => {
    const calls = mock85({ linkState: [] });
    const r = await statusCore(ENV, { userId: 'u1' });
    expect(r).toEqual({ status: 200, body: { ok: true, enabled: false, revision: 0, tokenValid: false } });
    expect(r.body).not.toHaveProperty('token');
    expect(calls.rpcAdmin).toHaveLength(0);
  });

  test('missing table (pre-deploy) reads as a fresh owner', async () => {
    mock85({ tableMissing: true });
    const r = await statusCore(ENV, { userId: 'u1', token: OLD_TOKEN });
    expect(r).toEqual({ status: 200, body: { ok: true, enabled: false, revision: 0, tokenValid: false } });
  });

  test('current display copy → tokenValid:true; stale/missing/disabled → false; never adopts', async () => {
    const calls = mock85({ linkState: [stateRow()] });
    const cur = await statusCore(ENV, { userId: 'u1', token: OLD_TOKEN });
    expect(cur).toEqual({ status: 200, body: { ok: true, enabled: true, revision: 1, tokenValid: true } });
    expect(cur.body).not.toHaveProperty('token');

    const stale = await statusCore(ENV, { userId: 'u1', token: NEW_TOKEN });
    expect(stale.body.tokenValid).toBe(false);

    mock85({ linkState: [stateRow({ enabled: false })] });
    const disabled = await statusCore(ENV, { userId: 'u1', token: OLD_TOKEN });
    expect(disabled.body).toMatchObject({ enabled: false, tokenValid: false });

    // Read-only proof: status performs GETs only — no RPC, no POST/PATCH.
    const writes = calls.fetches.filter((u) => u.includes('/rpc/'));
    expect(writes).toHaveLength(0);
  });

  test('status failure → 500', async () => {
    jest.spyOn(console, 'error').mockImplementation(() => {});
    global.fetch = jest.fn(async () => { throw new Error('boom'); });
    const r = await statusCore(ENV, { userId: 'u1' });
    expect(r.status).toBe(500);
  });
});

describe('8.05 public authority: config/submit/slots/reserve share one gate (§3/§5)', () => {
  test('R1 pre-adoption: blob token resolves verbatim (backfilled, adopted_at NULL)', async () => {
    // Backfill row exists but nobody adopted yet: authority is the blob.
    mock85({
      settingsBlob: [blobRow(OLD_TOKEN, true)],
      linkState: [stateRow({ adopted_at: null })],
      settingsByUser: [blobRow(OLD_TOKEN, true)],
    });
    const hit = await lookupUserByBookingToken(ENV, OLD_TOKEN);
    expect(hit && hit.user_id).toBe('u1');
  });

  test('R1 post-adoption: backfilled token resolves via state; acknowledged rotate rejects the old token immediately', async () => {
    // After an acknowledged rotate the blob still carries the OLD token
    // (ordinary client sync has not run) while state carries the new hash.
    const calls = mock85({
      settingsBlob: [blobRow(OLD_TOKEN, true)],
      linkState: [stateRow({ token_hash: sha(NEW_TOKEN), revision: 2 })],
      settingsByUser: [blobRow(OLD_TOKEN, true)],
    });
    // Old token: dead on arrival — no second round trip, no sync needed.
    expect(await lookupUserByBookingToken(ENV, OLD_TOKEN)).toBeNull();
    // New token: live even though the blob never saw it.
    const hit = await lookupUserByBookingToken(ENV, NEW_TOKEN);
    expect(hit && hit.user_id).toBe('u1');
    expect(calls.fetches.some((u) => u.includes('/rest/v1/settings?user_id=eq.u1'))).toBe(true);
  });

  test('acknowledged disable rejects before sync; RN stale settings cannot resurrect it (R4)', async () => {
    // Disable committed (adopted, enabled=false). A delayed whole-settings
    // push then replays enabled:true for the old token — auth-inert.
    mock85({
      settingsBlob: [blobRow(OLD_TOKEN, true)], // stale replay, as RN would sync
      linkState: [stateRow({ enabled: false, revision: 2 })],
      settingsByUser: [blobRow(OLD_TOKEN, true)],
    });
    expect(await lookupUserByBookingToken(ENV, OLD_TOKEN)).toBeNull();
  });

  test('R5 old-RN blob-only rotate post-adoption changes nothing authoritative', async () => {
    // Old RN "rotates" by writing a fresh token into the blob only. The
    // server never reads it post-adoption: the newcomer is inert, the
    // current capability keeps resolving.
    mock85({
      settingsBlob: [blobRow('9'.repeat(48), true)], // RN blob-only write
      linkState: [stateRow()], // authority still the old hash
      settingsByUser: [blobRow('9'.repeat(48), true)],
    });
    expect(await lookupUserByBookingToken(ENV, '9'.repeat(48))).toBeNull();
    const still = await lookupUserByBookingToken(ENV, OLD_TOKEN);
    expect(still && still.user_id).toBe('u1');
  });

  test('pre-deploy (table missing): byte-identical legacy behavior', async () => {
    mock85({ tableMissing: true, settingsBlob: [blobRow(OLD_TOKEN, true)] });
    expect((await lookupUserByBookingToken(ENV, OLD_TOKEN)).user_id).toBe('u1');
    mock85({ tableMissing: true, settingsBlob: [blobRow(OLD_TOKEN, false)] });
    expect(await lookupUserByBookingToken(ENV, OLD_TOKEN)).toBeNull();
    mock85({ tableMissing: true, settingsBlob: [] });
    expect(await lookupUserByBookingToken(ENV, 'f'.repeat(48))).toBeNull();
  });

  test('lookup failure still throws (callers map to 500, RN-compatible)', async () => {
    jest.spyOn(console, 'error').mockImplementation(() => {});
    global.fetch = jest.fn(async () => { throw new Error('boom'); });
    await expect(lookupUserByBookingToken(ENV, OLD_TOKEN)).rejects.toThrow();
  });
});

describe('8.05 manage-token independence + mint retention', () => {
  test('admin ops never touch bookingRequests (manage capabilities independent)', async () => {
    const stored = { ok: true, enabled: false, revision: 2, operationId: OP1 };
    const calls = mock85({ rpcAdmin: [{ ok: true, decision: 'committed', response: stored }] });
    await adminCore(ENV, {
      userId: 'u1', body: { action: 'set_enabled', operationId: OP1, enabled: false }, rawToken: NEW_TOKEN,
    });
    await statusCore(ENV, { userId: 'u1' });
    expect(calls.fetches.some((u) => u.includes('bookingRequests'))).toBe(false);
  });

  test('existing mint route is retained (stateless pre-adoption bootstrap)', async () => {
    const fs = require('node:fs');
    const path = require('node:path');
    const mintSrc = fs.readFileSync(
      path.join(__dirname, '..', 'backend-workers', 'src', 'routes', 'booking', 'mint.js'),
      'utf8'
    );
    expect(mintSrc).toMatch(/bookingMintHandler/);
    const indexSrc = fs.readFileSync(
      path.join(__dirname, '..', 'backend-workers', 'src', 'index.js'),
      'utf8'
    );
    expect(indexSrc).toMatch(/\/api\/booking\/mint/);
    expect(indexSrc).toMatch(/\/api\/booking\/admin/);
  });
});

describe('8.05 route-level auth and errors (POST /api/booking/admin)', () => {
  test('401 without bearer; 401 on invalid session; 405 on wrong method', async () => {
    mock85({ authUser: 'u1' });
    expect((await bookingAdminHandler(fakeC({ auth: null, body: {} }))).status).toBe(401);
    expect((await bookingAdminHandler(fakeC({ auth: 'Token x', body: {} }))).status).toBe(401);

    mock85({ authUser: null });
    expect((await bookingAdminHandler(fakeC({ body: { action: 'status' } }))).status).toBe(401);

    mock85({ authUser: 'u1' });
    const get = await bookingAdminHandler(fakeC({ method: 'GET', body: {} }));
    expect(get).toMatchObject({ status: 405 });
  });

  test('validation errors pass through with 400; status reads shape', async () => {
    mock85({ authUser: 'route-user-2', linkState: [] });
    const st = await bookingAdminHandler(fakeC({ body: { action: 'status' } }));
    expect(st).toEqual({
      status: 200,
      body: { ok: true, enabled: false, revision: 0, tokenValid: false },
    });

    mock85({ authUser: 'route-user-3' });
    const invalid = await bookingAdminHandler(fakeC({ body: { action: 'wipe' } }));
    expect(invalid).toEqual({ status: 400, body: { error: 'Invalid action.' } });

    const committed = { ok: true, enabled: true, revision: 1, operationId: OP1 };
    mock85({ authUser: 'route-user-6', rpcAdmin: [{ ok: true, decision: 'committed', response: committed }] });
    const en = await bookingAdminHandler(
      fakeC({ body: { action: 'set_enabled', operationId: OP1, enabled: true } })
    );
    expect(en).toEqual({ status: 200, body: committed });
  });

  test('mint via route returns the frozen shape; operationId echoes', async () => {
    const freshUser = 'route-user-4';
    // Route generates its own server token; script the envelope around it by
    // echoing whatever template the core sent.
    global.fetch = jest.fn(async (url, init = {}) => {
      const u = String(url);
      if (u.includes('/auth/v1/user')) return jsonRes({ id: freshUser });
      if (u.includes('/rest/v1/rpc/admin_booking_link')) {
        const args = JSON.parse(init.body);
        expect(args.p_action).toBe('mint');
        expect(args.p_token_hash).toMatch(/^[0-9a-f]{64}$/);
        return jsonRes({
          ok: true,
          decision: 'committed',
          response: { ...args.p_result, enabled: true, revision: 1 },
        });
      }
      return jsonRes([]);
    });
    const r = await bookingAdminHandler(fakeC({ body: { action: 'mint', operationId: OP1 } }));
    expect(r.status).toBe(200);
    expect(r.body.operationId).toBe(OP1);
    expect(r.body.token).toMatch(/^[0-9a-f]{48}$/);
    expect(r.body).toMatchObject({ ok: true, enabled: true, revision: 1 });
  });

  test('per-user rate limit trips at 11 rapid calls (mint precedent: 10/window)', async () => {
    const limitedUser = 'route-user-5';
    global.fetch = jest.fn(async (url, init = {}) => {
      const u = String(url);
      if (u.includes('/auth/v1/user')) return jsonRes({ id: limitedUser });
      if (u.includes('/rest/v1/rpc/admin_booking_link')) {
        const args = JSON.parse(init.body);
        return jsonRes({ ok: true, decision: 'committed', response: { ...args.p_result, enabled: true, revision: 1 } });
      }
      return jsonRes([]);
    });
    const ids = Array.from({ length: 11 }, (_, i) =>
      `0193f1${String(i).padStart(2, '0')}-0000-4000-8000-00000000000${i % 10}`
    );
    const statuses = [];
    for (const id of ids) {
      const r = await bookingAdminHandler(fakeC({ body: { action: 'mint', operationId: id } }));
      statuses.push(r.status);
    }
    expect(statuses.slice(0, 10)).toEqual(Array(10).fill(200));
    expect(statuses[10]).toBe(429);
  });
});
