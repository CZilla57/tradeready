// __tests__/phase8PortalConcurrencyCharacterization.test.js
// Task 8.00 (G4) — CHARACTERIZATION ONLY. Pins CURRENT portal token
// core behavior against a URL-keyed fetch mock: the read-then-mint /
// revoke-then-insert splits, the enabled-only 409 guard, the unknown-token
// blob fallback (including the post-adoption stale-blob residual), and the
// archivedAt-vs-archived ICS gap. Mock-level concurrency only — real
// competing-session proof is DEFERRED (M1) to task 8.14. Fixtures use
// low-entropy tokens on purpose (gitleaks rule). No implementation touched.

const store = require("../backend-workers/lib/estimate/portalTokenStore.js");
const { portalManageCore } = require("../backend-workers/lib/estimate/portalManage.js");
const { manageViewCore } = require("../backend-workers/lib/booking/manage.js");
const { portalIcsCore } = require("../backend-workers/lib/estimate/portalIcs.js");

const ENV = { SUPABASE_URL: "https://supa.test", SUPABASE_SERVICE_ROLE_KEY: "srk" };
const TOKEN = "p".repeat(48);
const STALE_BLOB_TOKEN = "s".repeat(48);
const NEW_HEX = "e".repeat(48);
const HASH = store.sha256Hex(TOKEN);
const STALE_HASH = store.sha256Hex(STALE_BLOB_TOKEN);

function jsonRes(body, status = 200) {
  return { ok: status >= 200 && status < 300, status, json: async () => body, text: async () => JSON.stringify(body) };
}

afterEach(() => {
  delete global.fetch;
  jest.restoreAllMocks();
});

// Portal-manage fetch mock. tokenRows: portal_tokens GET; customerRow:
// by-id fetch; blobRows: legacy JSON-path lookup.
function mockManage({ tokenRows = [], customerRow = null, blobRows = [], failInsert = false } = {}) {
  const calls = { inserts: [], patches: [], order: [] };
  global.fetch = jest.fn(async (url, init = {}) => {
    const u = String(url);
    const method = init.method || "GET";
    if (u.includes("/rest/v1/portal_tokens")) {
      if (method === "POST") {
        calls.order.push("insert");
        if (failInsert) throw new Error("insert down");
        calls.inserts.push(JSON.parse(init.body));
        return jsonRes([], 201);
      }
      if (method === "PATCH") {
        calls.order.push("revoke-or-toggle");
        calls.patches.push({ u, body: JSON.parse(init.body) });
        return jsonRes([], 204);
      }
      return jsonRes(tokenRows);
    }
    if (u.includes("/rest/v1/customers")) {
      return jsonRes(u.includes("data->portal->>token") ? blobRows : customerRow ? [customerRow] : []);
    }
    return jsonRes([]);
  });
  return calls;
}

const customer = (over = {}) => ({
  user_id: "u1",
  id: "c1",
  data: { name: "Dana", portal: { token: TOKEN, enabled: true } },
  ...over,
});
const activeRow = { token_hash: HASH, user_id: "u1", customer_id: "c1", enabled: true, revoked_at: null };

describe("G4 portal token integrity (characterization)", () => {
  test("G4-01: simultaneous mints both succeed at core level (no serialization)", async () => {
    // Two devices paint "Create" on a stale view; each core call observes
    // zero rows and each inserts. This mock answers the 8.06 RPC as
    // not-deployed, so the legacy split path runs: post-deploy the single
    // atomic RPC call (per-customer lock + single-active index) serializes
    // this — pinned in phase8PortalAdmin86.test.js, mock-level only.
    const calls = mockManage({ customerRow: customer({ data: { name: "Dana" } }) });
    const first = await portalManageCore(ENV, { userId: "u1", body: { action: "mint", customerId: "c1" }, randHex: NEW_HEX });
    const second = await portalManageCore(ENV, { userId: "u1", body: { action: "mint", customerId: "c1" }, randHex: "f".repeat(48) });
    expect(first.status).toBe(200);
    expect(second.status).toBe(200);
    expect(calls.inserts).toHaveLength(2);
  });

  test("G4-02: mint-after-disable is REFUSED (implemented by 8.06; 8.00 pinned the gap)", async () => {
    // 8.00 characterization pinned the INVARIANT GAP: the enabled-only 409
    // guard let mint stack a second non-revoked row beside a disabled one.
    // Task 8.06 implements contract §4/C6 verbatim — 409 on ANY non-revoked
    // row (RPC + legacy guard) plus the partial unique index — so this now
    // asserts the fix. Concurrency detail (mock-level only, NOT race
    // evidence — real competing-session proof is DEFERRED M1 to 8.14).
    const disabledRow = { ...activeRow, enabled: false, revoked_at: null };
    const calls = mockManage({ tokenRows: [disabledRow], customerRow: customer() });
    const r = await portalManageCore(ENV, { userId: "u1", body: { action: "mint", customerId: "c1" }, randHex: NEW_HEX });
    expect(r).toEqual({ status: 409, json: { error: "already_exists" } });
    expect(calls.inserts).toHaveLength(0);
  });

  test("G4-03: set_enabled targets ALL non-revoked rows (filter pinned)", async () => {
    const calls = mockManage({ tokenRows: [activeRow], customerRow: customer() });
    const r = await portalManageCore(ENV, {
      userId: "u1",
      body: { action: "set_enabled", customerId: "c1", enabled: false },
      randHex: NEW_HEX,
    });
    expect(r.status).toBe(200);
    expect(r.json).toEqual({ ok: true, enabled: false });
    expect(calls.patches).toHaveLength(1);
    expect(calls.patches[0].u).toContain("revoked_at=is.null");
    expect(calls.patches[0].body).toEqual({ enabled: false });
  });

  test("G4-04: rotate insert failure after revoke strands the customer (recovery gap)", async () => {
    // Revoke commits, then the fresh insert throws: no active token remains
    // and the raw replacement is lost. Order pinned (revoke first); §4 adds
    // the single-transaction + operation-replay recovery.
    const calls = mockManage({ tokenRows: [activeRow], customerRow: customer(), failInsert: true });
    await expect(
      portalManageCore(ENV, { userId: "u1", body: { action: "rotate", customerId: "c1" }, randHex: NEW_HEX })
    ).rejects.toThrow("insert down");
    expect(calls.order).toEqual(["revoke-or-toggle", "insert"]);
    expect(calls.patches[0].body.revoked_at).toBeTruthy();
  });

  test("G4-05: unknown stale blob token FAILS CLOSED after adoption (implemented by 8.06)", async () => {
    // 8.00 characterization pinned the RESIDUAL: an adopted customer's stale
    // blob token missed the hash lookup, fell through to the legacy blob
    // path, and AUTHENTICATED. Task 8.06 implements the §4 fix — unknown-hash
    // fallback is restricted to unadopted (zero-row) customers — so this now
    // asserts the 404 with NO backfill insert (a conflicting backfill must
    // never authorize the stale token).
    const newHash = store.sha256Hex(NEW_HEX);
    const adoptedRows = [{ token_hash: newHash, user_id: "u1", customer_id: "c1", enabled: true, revoked_at: null }];
    const staleBlobCustomer = {
      user_id: "u1",
      id: "c1",
      data: { name: "Dana", portal: { token: STALE_BLOB_TOKEN, enabled: true } },
    };
    global.fetch = jest.fn(async (url, init = {}) => {
      const u = String(url);
      const method = init.method || "GET";
      if (u.includes("/rest/v1/portal_tokens") && method === "GET") {
        // Only the NEW hash is known; the stale hash misses.
        return jsonRes(u.includes(newHash) || !u.includes("token_hash=eq") ? adoptedRows : []);
      }
      if (u.includes("/rest/v1/portal_tokens")) return jsonRes([], 201);
      if (u.includes("/rest/v1/customers") && u.includes("data->portal->>token")) {
        return jsonRes(u.includes(encodeURIComponent(STALE_BLOB_TOKEN)) ? [staleBlobCustomer] : []);
      }
      if (u.includes("/rest/v1/customers")) {
        return jsonRes(u.includes("id=eq.c1") ? [staleBlobCustomer] : []);
      }
      return jsonRes([]);
    });
    // Sanity: the stale hash really is unknown to the table…
    expect(STALE_HASH).not.toBe(newHash);
    expect(await store.resolvePortalCustomer(ENV, STALE_BLOB_TOKEN)).toBeNull();
    // …and no backfill insert was attempted for the adopted customer.
    expect(global.fetch.mock.calls.some(([u, init]) => String(u).includes("/rest/v1/portal_tokens") && (init.method || "GET") === "POST")).toBe(false);
  });

  test("G4-06: unknown token + blob miss still fails closed (preserved)", async () => {
    mockManage({ tokenRows: [], customerRow: null, blobRows: [] });
    expect(await store.resolvePortalCustomer(ENV, "z".repeat(48))).toBeNull();
  });

  test("G4-07: booking manage view returns the stored slot verbatim (immutability basis)", async () => {
    const stored = { date: "2026-08-10", start: "09:00", end: "10:00" };
    global.fetch = jest.fn(async (url) => {
      const u = String(url);
      if (u.includes("/rest/v1/bookingRequests")) {
        return jsonRes([{ id: "bk1", user_id: "u1", data: { id: "bk1", status: "confirmed", slot: stored, manageToken: "m".repeat(48) } }]);
      }
      if (u.includes("/rest/v1/settings")) return jsonRes([{ user_id: "u1", data: { businessName: "Rivera" } }]);
      return jsonRes([]);
    });
    const view = await manageViewCore(ENV, { token: "m".repeat(48) });
    expect(view.status).toBe(200);
    expect(view.body.slot).toEqual(stored);
    expect(view.body.status).toBe("confirmed");
  });

  test("G4-08: archivedAt-only job serves 404 from portal ICS (implemented by 8.06/C12)", async () => {
    // 8.00 characterization pinned the ARCHIVE GAP: canonical archive marker
    // is archivedAt but portalIcs checked d.archived — never set by RN — so
    // an archived job served 200. Task 8.06 implements the frozen C12 fix
    // (d.archived || d.archivedAt, same in portalAssemble), so this now
    // asserts the 404.
    const archivedJob = {
      id: "j1",
      data: {
        title: "Heater swap",
        scheduledDate: "2026-08-12",
        scheduledStartTime: "09:00",
        scheduledEndTime: "10:00",
        archivedAt: "2026-08-11",
      },
    };
    const cust = { user_id: "u1", id: "c1", data: { name: "Dana" } };
    global.fetch = jest.fn(async (url, init = {}) => {
      const u = String(url);
      const method = init.method || "GET";
      if (u.includes("/rest/v1/portal_tokens") && method === "GET") return jsonRes([activeRow]);
      if (u.includes("/rest/v1/customers") && u.includes("data->portal->>token")) return jsonRes([]);
      if (u.includes("/rest/v1/customers")) return jsonRes([cust]);
      if (u.includes("/rest/v1/jobs")) return jsonRes([archivedJob]);
      if (u.includes("/rest/v1/settings")) return jsonRes([{ user_id: "u1", data: { businessName: "Rivera" } }]);
      if (u.includes("/rest/v1/portal_access_log")) return jsonRes([]);
      return jsonRes([]);
    });
    const r = await portalIcsCore(ENV, { token: TOKEN, jobId: "j1", stampUtc: "2026-08-10T12:00:00.000Z", ip: "127.0.0.1" });
    expect(r).toEqual({ ok: false, status: 404, error: "This link is invalid." });
  });
});
