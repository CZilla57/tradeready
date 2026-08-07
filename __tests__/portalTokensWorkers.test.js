// __tests__/portalTokensWorkers.test.js
// Phase 12D: server-owned portal tokens. The resolver contract is the
// load-bearing piece — a hash KNOWN to the table but revoked/disabled must
// hard-stop (oracle-free null) and NEVER fall through to the legacy blob
// lookup; that hard-stop is what makes rotate/disable instant. Unknown
// hashes fall back to pre-Phase-D blob tokens and lazily backfill a table
// row. portalManageCore pins mint/set_enabled/rotate incl. the 409
// stale-paint guard and that no raw token ever reaches a Supabase write.
// All token fixtures are low-entropy on purpose (gitleaks rule).

const store = require("../backend-workers/lib/estimate/portalTokenStore.js");
const { portalManageCore } = require("../backend-workers/lib/estimate/portalManage.js");

const ENV = { SUPABASE_URL: "https://supa.test", SUPABASE_SERVICE_ROLE_KEY: "srk" };
const TOKEN = "p".repeat(48);
const HASH = store.sha256Hex(TOKEN);
const NEW_HEX = "e".repeat(48);

function jsonRes(body, status = 200) {
  return { ok: status >= 200 && status < 300, status, json: async () => body, text: async () => JSON.stringify(body) };
}

afterEach(() => { delete global.fetch; jest.restoreAllMocks(); });

// url-keyed fetch mock; records every call for order/body assertions.
function mockBackend({ tokenRows = [], customerRows = [], blobRows = [] } = {}) {
  const calls = { all: [], tokenInserts: [], tokenPatches: [] };
  global.fetch = jest.fn(async (url, init = {}) => {
    const u = String(url);
    const method = init.method || "GET";
    calls.all.push({ u, method, body: init.body ? JSON.parse(init.body) : null });
    if (u.includes("/rest/v1/portal_tokens")) {
      if (method === "POST") { calls.tokenInserts.push(JSON.parse(init.body)); return jsonRes([], 201); }
      if (method === "PATCH") { calls.tokenPatches.push({ u, body: JSON.parse(init.body) }); return jsonRes([], 204); }
      return jsonRes(tokenRows);
    }
    if (u.includes("/rest/v1/customers")) {
      // blob JSON-path lookup vs by-id fetch are distinguishable by filter
      return jsonRes(u.includes("data->portal->>token") ? blobRows : customerRows);
    }
    return jsonRes([]);
  });
  return calls;
}

const customer = { user_id: "u1", id: "c1", data: { name: "Dana", portal: { token: TOKEN, enabled: true } } };
const activeRow = { token_hash: HASH, user_id: "u1", customer_id: "c1", enabled: true, revoked_at: null };

describe("portalTokenStore.resolvePortalCustomer", () => {
  test("active table row authenticates without ever consulting the blob path", async () => {
    const calls = mockBackend({ tokenRows: [activeRow], customerRows: [customer] });
    const row = await store.resolvePortalCustomer(ENV, TOKEN);
    expect(row).toEqual(customer);
    expect(calls.all.some((c) => c.u.includes("data->portal->>token"))).toBe(false);
    const tokenLookup = calls.all.find((c) => c.u.includes("portal_tokens"));
    expect(tokenLookup.u).toContain(`token_hash=eq.${HASH}`);
  });

  test.each([
    ["revoked", { ...activeRow, enabled: false, revoked_at: "2026-08-07T00:00:00.000Z" }],
    ["disabled", { ...activeRow, enabled: false }],
  ])("%s table row hard-stops — null, blob NEVER consulted", async (_l, row) => {
    const calls = mockBackend({ tokenRows: [row], blobRows: [customer] });
    expect(await store.resolvePortalCustomer(ENV, TOKEN)).toBeNull();
    expect(calls.all.some((c) => c.u.includes("data->portal->>token"))).toBe(false);
  });

  test("unknown hash falls back to the blob token AND backfills a table row", async () => {
    const calls = mockBackend({ tokenRows: [], blobRows: [customer] });
    const row = await store.resolvePortalCustomer(ENV, TOKEN);
    expect(row).toEqual(customer);
    expect(calls.tokenInserts).toHaveLength(1);
    expect(calls.tokenInserts[0]).toMatchObject({ token_hash: HASH, user_id: "u1", customer_id: "c1", enabled: true });
    expect(JSON.stringify(calls.tokenInserts)).not.toContain(TOKEN);
  });

  test("backfill failure never blocks the response", async () => {
    jest.spyOn(console, "error").mockImplementation(() => {});
    global.fetch = jest.fn(async (url, init = {}) => {
      const u = String(url);
      if (u.includes("portal_tokens") && (init.method || "GET") === "POST") throw new Error("insert down");
      if (u.includes("portal_tokens")) return jsonRes([]);
      if (u.includes("data->portal->>token")) return jsonRes([customer]);
      return jsonRes([]);
    });
    expect(await store.resolvePortalCustomer(ENV, TOKEN)).toEqual(customer);
  });

  test("unknown hash + blob miss → null", async () => {
    mockBackend({ tokenRows: [], blobRows: [] });
    expect(await store.resolvePortalCustomer(ENV, TOKEN)).toBeNull();
  });
});

describe("portalManageCore", () => {
  const mint = (over = {}) => ({ action: "mint", customerId: "c1", ...over });

  test.each([
    ["bad action", { action: "steal" }],
    ["missing customerId", { customerId: "" }],
  ])("%s → 400", async (_l, over) => {
    mockBackend({ customerRows: [customer] });
    const out = await portalManageCore(ENV, { userId: "u1", body: mint(over), randHex: NEW_HEX });
    expect(out.status).toBe(400);
  });

  test("customer not owned by caller → 404, nothing written", async () => {
    const calls = mockBackend({ customerRows: [] });
    const out = await portalManageCore(ENV, { userId: "u1", body: mint(), randHex: NEW_HEX });
    expect(out).toEqual({ status: 404, json: { error: "Not found" } });
    expect(calls.tokenInserts).toHaveLength(0);
  });

  test("mint on a token-less customer inserts the HASH and returns the raw token once", async () => {
    const bare = { ...customer, data: { name: "Dana" } };
    const calls = mockBackend({ customerRows: [bare], tokenRows: [] });
    const out = await portalManageCore(ENV, { userId: "u1", body: mint(), randHex: NEW_HEX });
    expect(out).toEqual({ status: 200, json: { ok: true, token: NEW_HEX } });
    expect(calls.tokenInserts).toHaveLength(1);
    expect(calls.tokenInserts[0].token_hash).toBe(store.sha256Hex(NEW_HEX));
    expect(JSON.stringify(calls.all.map((c) => c.body))).not.toContain(NEW_HEX);
  });

  test("mint with an ACTIVE row → 409 already_exists (stale-paint guard), no revoke, no insert", async () => {
    const calls = mockBackend({ customerRows: [customer], tokenRows: [activeRow] });
    const out = await portalManageCore(ENV, { userId: "u1", body: mint(), randHex: NEW_HEX });
    expect(out).toEqual({ status: 409, json: { error: "already_exists" } });
    expect(calls.tokenInserts).toHaveLength(0);
    expect(calls.tokenPatches).toHaveLength(0);
  });

  test("set_enabled flips active rows; non-boolean → 400; token-less customer → 404", async () => {
    const calls = mockBackend({ customerRows: [{ ...customer, data: { name: "Dana" } }], tokenRows: [activeRow] });
    const out = await portalManageCore(ENV, { userId: "u1", body: { action: "set_enabled", customerId: "c1", enabled: false }, randHex: NEW_HEX });
    expect(out).toEqual({ status: 200, json: { ok: true, enabled: false } });
    expect(calls.tokenPatches[0].u).toContain("revoked_at=is.null");
    expect(calls.tokenPatches[0].body).toEqual({ enabled: false });

    mockBackend({ customerRows: [customer] });
    expect((await portalManageCore(ENV, { userId: "u1", body: { action: "set_enabled", customerId: "c1", enabled: "yes" }, randHex: NEW_HEX })).status).toBe(400);

    mockBackend({ customerRows: [{ ...customer, data: { name: "Dana" } }], tokenRows: [] });
    expect((await portalManageCore(ENV, { userId: "u1", body: { action: "set_enabled", customerId: "c1", enabled: true }, randHex: NEW_HEX })).status).toBe(404);
  });

  test("rotate revokes ALL rows first, then inserts the fresh hash", async () => {
    const calls = mockBackend({ customerRows: [{ ...customer, data: { name: "Dana" } }], tokenRows: [activeRow] });
    const out = await portalManageCore(ENV, { userId: "u1", body: { action: "rotate", customerId: "c1" }, randHex: NEW_HEX });
    expect(out.json.token).toBe(NEW_HEX);
    const patchIdx = calls.all.findIndex((c) => c.u.includes("portal_tokens") && c.method === "PATCH");
    const insertIdx = calls.all.findIndex((c) => c.u.includes("portal_tokens") && c.method === "POST");
    expect(patchIdx).toBeGreaterThan(-1);
    expect(patchIdx).toBeLessThan(insertIdx);
    expect(calls.tokenPatches[0].body.enabled).toBe(false);
    expect(typeof calls.tokenPatches[0].body.revoked_at).toBe("string");
  });

  test("legacy blob customer: manage backfills the blob token's hash before acting", async () => {
    // customer blob carries TOKEN; table is empty → set_enabled must first
    // insert hash(TOKEN), then flip it.
    const calls = mockBackend({ customerRows: [customer], tokenRows: [] });
    const out = await portalManageCore(ENV, { userId: "u1", body: { action: "set_enabled", customerId: "c1", enabled: false }, randHex: NEW_HEX });
    expect(out).toEqual({ status: 200, json: { ok: true, enabled: false } });
    expect(calls.tokenInserts[0].token_hash).toBe(HASH);
    expect(calls.tokenPatches).toHaveLength(1);
  });
});
