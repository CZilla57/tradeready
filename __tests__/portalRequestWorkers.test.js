// __tests__/portalRequestWorkers.test.js
// Phase 12C: the portal's FIRST write path. portalRequestStore pins the
// Supabase wire contract — ignore-duplicates on insert (a retry must never
// clobber createdAt/handledAt/conversion stamps), best-effort logging, the
// daily-cap count query. portalRequestCore pins the whole accept/reject
// surface: honeypot, validation, oracle-free 404s, the durable per-token cap
// (fail-OPEN on log-table errors), server-timestamped rows, deterministic
// idempotent ids, and that no raw portal token ever reaches a log row.

const store = require("../backend-workers/lib/estimate/portalRequestStore.js");
const { portalRequestCore } = require("../backend-workers/lib/estimate/portalRequest.js");

const ENV = { SUPABASE_URL: "https://supa.test", SUPABASE_SERVICE_ROLE_KEY: "srk" };
const TOKEN = "p".repeat(48);
const NOW_MS = Date.UTC(2026, 7, 10, 12, 0);

function jsonRes(body, status = 200) {
  return { ok: status >= 200 && status < 300, status, json: async () => body, text: async () => JSON.stringify(body) };
}

afterEach(() => { delete global.fetch; jest.restoreAllMocks(); });

describe("portalRequestStore", () => {
  test("insertPortalRequest posts a sync-shaped row with ignore-duplicates", async () => {
    global.fetch = jest.fn(async () => jsonRes([], 201));
    await store.insertPortalRequest(ENV, "u1", { id: "bkpr_x", status: "new" });
    const [url, init] = global.fetch.mock.calls[0];
    expect(String(url)).toContain("/rest/v1/bookingRequests");
    expect(init.headers.Prefer).toBe("resolution=ignore-duplicates");
    const posted = JSON.parse(init.body);
    expect(posted.id).toBe("bkpr_x");
    expect(posted.user_id).toBe("u1");
    expect(posted.deleted).toBe(false);
    expect(posted.data.status).toBe("new");
  });

  test("logPortalEvent posts the row and NEVER throws on failure", async () => {
    global.fetch = jest.fn(async () => { throw new Error("db down"); });
    await expect(
      store.logPortalEvent(ENV, { userId: "u1", tokenPrefix: "pppppppp", event: "request", ip: "1.2.3.4" })
    ).resolves.toBeUndefined();
  });

  test("countTodayRequests queries by user + prefix + event since UTC midnight", async () => {
    global.fetch = jest.fn(async () => jsonRes([{ id: "a" }, { id: "b" }]));
    const n = await store.countTodayRequests(ENV, { userId: "u1", tokenPrefix: "pppppppp", nowMs: NOW_MS });
    expect(n).toBe(2);
    const url = String(global.fetch.mock.calls[0][0]);
    expect(url).toContain("portal_access_log?user_id=eq.u1");
    expect(url).toContain("token_prefix=eq.pppppppp");
    expect(url).toContain("event=eq.request");
    expect(url).toContain("created_at=gte.2026-08-10T00%3A00%3A00.000Z");
  });
});

describe("portalRequestCore", () => {
  const customer = { user_id: "u1", id: "c1", data: { name: "Dana Fox", phone: "555-0100", email: "dana@x.com", address: "12 Elm", notes: "private" } };
  const schedJob = { id: "j1", data: { title: "Water heater swap", customerId: "c1", scheduledDate: "2026-08-12", scheduledStartTime: "09:00" } };

  function mockBackend({ customerRows = [customer], jobRows = [schedJob], capRows = [], insertStatus = 201, failCap = false } = {}) {
    const calls = { inserts: [], logs: [] };
    global.fetch = jest.fn(async (url, init = {}) => {
      const u = String(url);
      const method = init.method || "GET";
      if (u.includes("/rest/v1/customers")) return jsonRes(customerRows);
      if (u.includes("/rest/v1/jobs")) return jsonRes(jobRows);
      if (u.includes("/rest/v1/settings")) return jsonRes([{ data: { businessName: "Ace" } }]);
      if (u.includes("/rest/v1/portal_access_log")) {
        if (method === "POST") { calls.logs.push(JSON.parse(init.body)); return jsonRes([], 201); }
        if (failCap) throw new Error("no such table");
        return jsonRes(capRows);
      }
      if (u.includes("/rest/v1/bookingRequests") && method === "POST") {
        calls.inserts.push(JSON.parse(init.body));
        return jsonRes([], insertStatus);
      }
      return jsonRes([]);
    });
    return calls;
  }

  // Low-entropy on purpose (gitleaks lesson, CI run 31205163008): a mixed-hex
  // fixture here tripped generic-api-key via the "Key" keyword + entropy.
  const body = (over = {}) => ({ p: TOKEN, kind: "followup", note: "Need the fence painted too", requestKey: "aaaabbbbcccc", ...over });

  test("honeypot gets a silent fake success and writes nothing", async () => {
    const calls = mockBackend();
    const out = await portalRequestCore(ENV, { body: body({ website: "bot" }), ip: "1.1.1.1", nowMs: NOW_MS });
    expect(out).toEqual({ status: 200, json: { ok: true } });
    expect(calls.inserts).toHaveLength(0);
  });

  test.each([
    ["bad kind", { kind: "chat" }],
    ["bad requestKey", { requestKey: "short" }],
    ["followup without a note", { note: "   " }],
  ])("%s → 400", async (_l, over) => {
    mockBackend();
    const out = await portalRequestCore(ENV, { body: body(over), ip: "1.1.1.1", nowMs: NOW_MS });
    expect(out.status).toBe(400);
  });

  test("unknown token → oracle-free 404", async () => {
    mockBackend({ customerRows: [] });
    const out = await portalRequestCore(ENV, { body: body(), ip: "1.1.1.1", nowMs: NOW_MS });
    expect(out).toEqual({ status: 404, json: { error: "This link is invalid." } });
  });

  test("daily cap reached → 429 and a denied log row with token PREFIX only", async () => {
    const calls = mockBackend({ capRows: [{}, {}, {}, {}, {}] });
    const out = await portalRequestCore(ENV, { body: body(), ip: "1.1.1.1", nowMs: NOW_MS });
    expect(out.status).toBe(429);
    expect(calls.inserts).toHaveLength(0);
    const denied = calls.logs.find((l) => l.event === "denied");
    expect(denied.token_prefix).toBe(TOKEN.slice(0, 8));
    expect(JSON.stringify(calls.logs)).not.toContain(TOKEN);
  });

  test("cap-check error fails OPEN (in-memory IP limit still guards)", async () => {
    jest.spyOn(console, "error").mockImplementation(() => {});
    const calls = mockBackend({ failCap: true });
    const out = await portalRequestCore(ENV, { body: body(), ip: "1.1.1.1", nowMs: NOW_MS });
    expect(out).toEqual({ status: 200, json: { ok: true } });
    expect(calls.inserts).toHaveLength(1);
  });

  test("followup inserts the exact row: contact from the CUSTOMER RECORD, server timestamp, portal linkage", async () => {
    const calls = mockBackend();
    await portalRequestCore(ENV, { body: body(), ip: "1.1.1.1", nowMs: NOW_MS });
    expect(calls.inserts).toHaveLength(1);
    const row = calls.inserts[0].data;
    expect(row).toEqual({
      id: expect.stringMatching(/^bkpr_[0-9a-f]{20}$/),
      status: "new",
      name: "Dana Fox",
      phone: "555-0100",
      email: "dana@x.com",
      address: "12 Elm",
      details: "Need the fence painted too",
      preferredTiming: "",
      createdAt: new Date(NOW_MS).toISOString(),
      source: "portal",
      sourceCustomerId: "c1",
    });
    const requestLog = calls.logs.find((l) => l.event === "request");
    expect(requestLog.token_prefix).toBe(TOKEN.slice(0, 8));
  });

  test("reschedule inserts portal_change_requested with jobRef and templated details", async () => {
    const calls = mockBackend();
    await portalRequestCore(ENV, {
      body: body({ kind: "reschedule", jobRef: "j1", note: "Tuesday works better" }),
      ip: "1.1.1.1", nowMs: NOW_MS,
    });
    const row = calls.inserts[0].data;
    expect(row.status).toBe("portal_change_requested");
    expect(row.jobRef).toBe("j1");
    expect(row.portalKind).toBe("reschedule");
    expect(row.details).toBe('Reschedule requested for "Water heater swap" (2026-08-12) — Tuesday works better');
    expect(row.sourceCustomerId).toBe("c1");
  });

  test("cancel with a jobRef that is not this customer's scheduled job → same 404", async () => {
    mockBackend({ jobRows: [{ id: "j2", data: { title: "No sched", customerId: "c1" } }] });
    const out = await portalRequestCore(ENV, { body: body({ kind: "cancel", jobRef: "j2", note: "" }), ip: "1.1.1.1", nowMs: NOW_MS });
    expect(out).toEqual({ status: 404, json: { error: "This link is invalid." } });
  });

  test("same token + requestKey produce the same id on every call (idempotent retry)", async () => {
    const calls = mockBackend();
    await portalRequestCore(ENV, { body: body(), ip: "1.1.1.1", nowMs: NOW_MS });
    await portalRequestCore(ENV, { body: body(), ip: "1.1.1.1", nowMs: NOW_MS + 5000 });
    expect(calls.inserts[0].data.id).toBe(calls.inserts[1].data.id);
    const other = mockBackend();
    await portalRequestCore(ENV, { body: body({ requestKey: "zzzzzzzzzzzz" }), ip: "1.1.1.1", nowMs: NOW_MS });
    expect(other.inserts[0].data.id).not.toBe(calls.inserts[0].data.id);
  });
});
