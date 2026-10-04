// __tests__/estimateUpdateRequestWorkers.test.js
// Phase 32 (quote expiration, spec §4.5): "Request an updated estimate".
// insertRequestIfAbsent pins the Supabase wire contract — ignore-duplicates
// PLUS return=representation, so the caller learns whether THIS call created
// the row. estimateUpdateRequestCore pins the whole accept/reject surface:
// honeypot, 400/404/409 paths, the exact row shape with no contact fields,
// the deterministic one-per-expiry-episode id, notify-once driven by the
// insert result, and the note cap. Mirrors portalRequestWorkers.test.js.

const { createHash } = require("node:crypto");
const store = require("../backend-workers/lib/estimate/portalRequestStore.js");
const { estimateUpdateRequestCore } = require("../backend-workers/lib/estimate/estimateUpdateRequest.js");

const ENV = { SUPABASE_URL: "https://supa.test", SUPABASE_SERVICE_ROLE_KEY: "srk", RESEND_API_KEY: "re_test" };
// Low-entropy on purpose (gitleaks lesson, CI run 31205163008).
const TOKEN = "t".repeat(48);
// Phoenix: validUntil 2026-11-02 is still valid at 06:30Z on Nov 3 (23:30
// local) and expired at 07:00Z (local midnight).
const VALID_AT = Date.parse("2026-11-03T06:30:00Z");
const EXPIRED_AT = Date.parse("2026-11-03T07:00:00Z");

function jsonRes(body, status = 200) {
  return { ok: status >= 200 && status < 300, status, json: async () => body, text: async () => JSON.stringify(body) };
}

const expectedId = (validUntil, jobId = "j1", token = TOKEN) =>
  `bkeu_${createHash("sha256").update(`${jobId}|${token}|${validUntil}`).digest("hex").slice(0, 20)}`;

afterEach(() => { delete global.fetch; jest.restoreAllMocks(); });

describe("insertRequestIfAbsent", () => {
  test("posts a sync-shaped row with ignore-duplicates + return=representation; true when a row came back", async () => {
    global.fetch = jest.fn(async (_url, init) => jsonRes([JSON.parse(init.body)], 201));
    const inserted = await store.insertRequestIfAbsent(ENV, "u1", { id: "bkeu_x", status: "portal_change_requested" });
    expect(inserted).toBe(true);
    const [url, init] = global.fetch.mock.calls[0];
    expect(String(url)).toBe("https://supa.test/rest/v1/bookingRequests");
    expect(init.method).toBe("POST");
    expect(init.headers.Prefer).toBe("resolution=ignore-duplicates,return=representation");
    const posted = JSON.parse(init.body);
    expect(posted.id).toBe("bkeu_x");
    expect(posted.user_id).toBe("u1");
    expect(posted.deleted).toBe(false);
    expect(posted.data.status).toBe("portal_change_requested");
  });

  test("an existing id comes back as [] → false (never clobbered)", async () => {
    global.fetch = jest.fn(async () => jsonRes([], 201));
    await expect(store.insertRequestIfAbsent(ENV, "u1", { id: "bkeu_x" })).resolves.toBe(false);
  });

  test("a DB error throws (the route maps it to 500)", async () => {
    global.fetch = jest.fn(async () => jsonRes({ message: "boom" }, 500));
    await expect(store.insertRequestIfAbsent(ENV, "u1", { id: "bkeu_x" })).rejects.toThrow("Supabase insert 500");
  });
});

describe("estimateUpdateRequestCore", () => {
  const snapshot = (over = {}) => ({
    businessName: "Ace Plumbing", customerName: "Dana Fox", jobTitle: "Water heater swap",
    lineItems: [{ label: "Labor", amount: 400 }], total: 400, currency: "USD",
    validUntil: "2026-11-02", validUntilTimeZone: "America/Phoenix", ...over,
  });
  const jobRow = ({ snap = snapshot(), approval = {}, data = {} } = {}) => ({
    user_id: "u1",
    data: {
      id: "j1", title: "Heater", status: "estimate_sent", customerId: "c1", customerName: "Job-level Name",
      phone: "555-0100", email: "dana@x.com", address: "12 Elm", notes: "gate code 1234",
      approval: { token: TOKEN, sentAt: "2026-10-03T12:00:00.000Z", snapshot: snap, ...approval },
      ...data,
    },
  });

  function mockBackend({ jobRows = [jobRow()], existingIds = new Set(), failNotify = false, pushToken } = {}) {
    const calls = { inserts: [], emails: [], pushes: [], jobGets: 0 };
    global.fetch = jest.fn(async (url, init = {}) => {
      const u = String(url);
      const method = init.method || "GET";
      if (u.includes("/rest/v1/jobs")) { calls.jobGets += 1; return jsonRes(jobRows); }
      if (u.includes("/rest/v1/bookingRequests") && method === "POST") {
        const posted = JSON.parse(init.body);
        calls.inserts.push(posted);
        if (existingIds.has(posted.id)) return jsonRes([], 201);
        existingIds.add(posted.id);
        return jsonRes([posted], 201);
      }
      if (u.includes("/rest/v1/settings")) {
        return jsonRes([{ data: pushToken ? { pushToken: { token: pushToken } } : {} }]);
      }
      if (u.includes("/auth/v1/admin/users/")) return jsonRes({ email: "owner@example.test" });
      if (u.startsWith("https://api.resend.com/")) {
        calls.emails.push(JSON.parse(init.body));
        return failNotify ? jsonRes({ message: "down" }, 500) : jsonRes({ id: "e1" });
      }
      if (u.startsWith("https://exp.host/")) { calls.pushes.push(JSON.parse(init.body)); return jsonRes({}); }
      return jsonRes([]);
    });
    return calls;
  }

  const body = (over = {}) => ({ jobId: "j1", token: TOKEN, note: "", website: "", ...over });
  const run = (b, nowMs = EXPIRED_AT) => estimateUpdateRequestCore(ENV, { body: b, ip: "1.1.1.1", nowMs });

  test("honeypot gets a silent fake success and touches nothing", async () => {
    jest.spyOn(console, "warn").mockImplementation(() => {});
    const calls = mockBackend();
    await expect(run(body({ website: "http://spam.example" }))).resolves.toEqual({ status: 200, json: { ok: true } });
    expect(global.fetch).not.toHaveBeenCalled();
    expect(calls.inserts).toHaveLength(0);
  });

  test.each([
    ["no jobId", { jobId: undefined }],
    ["no token", { token: "" }],
    ["non-string jobId", { jobId: 7 }],
    ["non-string token", { token: ["t"] }],
  ])("%s → 400 Missing link parameters.", async (_l, over) => {
    mockBackend();
    await expect(run(body(over))).resolves.toEqual({ status: 400, json: { error: "Missing link parameters." } });
    expect(global.fetch).not.toHaveBeenCalled();
  });

  test.each([
    ["unknown job", { jobRows: [] }],
    ["job without an approval link", { jobRows: [jobRow({ data: { approval: undefined } })] }],
  ])("%s → 404", async (_l, backend) => {
    const calls = mockBackend(backend);
    await expect(run(body())).resolves.toEqual({ status: 404, json: { error: "This link is invalid or has expired." } });
    expect(calls.inserts).toHaveLength(0);
  });

  test("wrong token → the same oracle-free 404", async () => {
    const calls = mockBackend();
    const out = await run(body({ token: "u".repeat(48) }));
    expect(out).toEqual({ status: 404, json: { error: "This link is invalid or has expired." } });
    expect(calls.inserts).toHaveLength(0);
  });

  test("already approved → 409 already_approved (checked before expiry)", async () => {
    const calls = mockBackend({ jobRows: [jobRow({ approval: { decision: "approved", consentAt: "2026-10-04T00:00:00.000Z" } })] });
    await expect(run(body())).resolves.toEqual({
      status: 409, json: { error: "This estimate was already approved.", code: "already_approved" },
    });
    expect(calls.inserts).toHaveLength(0);
  });

  test.each([
    ["still valid at 23:30 local on the date", jobRow(), VALID_AT],
    ["undated", jobRow({ snap: snapshot({ validUntil: undefined, validUntilTimeZone: undefined }) }), Date.parse("2099-01-01T00:00:00Z")],
  ])("not expired (%s) → 409 estimate_not_expired", async (_l, row, nowMs) => {
    const calls = mockBackend({ jobRows: [row] });
    await expect(run(body(), nowMs)).resolves.toEqual({
      status: 409, json: { error: "This estimate is still open. Please reload the page.", code: "estimate_not_expired" },
    });
    expect(calls.inserts).toHaveLength(0);
    expect(calls.emails).toHaveLength(0);
  });

  test("expired: inserts the exact row — no contact fields, server timestamp, job linkage", async () => {
    const calls = mockBackend();
    await expect(run(body({ note: "  Still keen, can you re-quote?  " }))).resolves.toEqual({ status: 200, json: { ok: true } });
    expect(calls.inserts).toHaveLength(1);
    expect(calls.inserts[0].user_id).toBe("u1");
    expect(calls.inserts[0].id).toBe(expectedId("2026-11-02"));
    expect(calls.inserts[0].data).toEqual({
      id: expectedId("2026-11-02"),
      status: "portal_change_requested",
      portalKind: "quote_update",
      jobRef: "j1",
      name: "Dana Fox",
      phone: "",
      email: "",
      address: "",
      details: 'Updated estimate requested for "Water heater swap" (expired November 2, 2026) — Still keen, can you re-quote?',
      preferredTiming: "",
      createdAt: new Date(EXPIRED_AT).toISOString(),
      source: "estimate",
      sourceCustomerId: "c1",
    });
    const flat = JSON.stringify(calls.inserts[0]);
    expect(flat).not.toContain("555-0100");
    expect(flat).not.toContain("dana@x.com");
    expect(flat).not.toContain("gate code");
  });

  test("no note → no trailing dash; name falls back to the job; a non-string customerId is dropped", async () => {
    const row = jobRow({ snap: snapshot({ customerName: "" }), data: { customerId: 42 } });
    const calls = mockBackend({ jobRows: [row] });
    await run(body({ note: "   " }));
    const data = calls.inserts[0].data;
    expect(data.details).toBe('Updated estimate requested for "Water heater swap" (expired November 2, 2026)');
    expect(data.name).toBe("Job-level Name");
    expect("sourceCustomerId" in data).toBe(false);
  });

  test("a declined estimate past its date can still ask for an update", async () => {
    const calls = mockBackend({ jobRows: [jobRow({ approval: { decision: "declined", consentAt: "then" } })] });
    await expect(run(body())).resolves.toEqual({ status: 200, json: { ok: true } });
    expect(calls.inserts).toHaveLength(1);
  });

  test("the note is trimmed and capped at 300 characters", async () => {
    const calls = mockBackend();
    await run(body({ note: `  ${"n".repeat(400)}  ` }));
    const { details } = calls.inserts[0].data;
    expect(details.endsWith(` — ${"n".repeat(300)}`)).toBe(true);
    expect(details).not.toContain("n".repeat(301));
  });

  test("insert-if-absent drives notify-once: the first call emails the owner, retries are silent successes", async () => {
    const calls = mockBackend({ pushToken: "ExponentPushToken[x]" });
    const first = await run(body({ note: "Please re-quote" }));
    const second = await run(body({ note: "Second click, different note" }), EXPIRED_AT + 60_000);
    expect(first).toEqual({ status: 200, json: { ok: true } });
    expect(second).toEqual({ status: 200, json: { ok: true } });
    expect(calls.inserts).toHaveLength(2);
    expect(calls.inserts[1].id).toBe(calls.inserts[0].id);
    expect(calls.emails).toHaveLength(1);
    expect(calls.emails[0].to).toBe("owner@example.test");
    expect(calls.emails[0].subject).toBe("Updated estimate requested: Dana Fox");
    expect(calls.emails[0].text).toContain("Updated estimate requested — Dana Fox.");
    expect(calls.emails[0].text).toContain("Please re-quote");
    expect(calls.pushes).toHaveLength(1);
    expect(calls.pushes[0]).toMatchObject({
      title: "Updated estimate requested",
      data: { type: "booking_update", jobId: "j1" },
    });
  });

  test("one row per expiry episode: a later expiry after an extension is a new id", async () => {
    const existingIds = new Set();
    const first = mockBackend({ existingIds });
    await run(body());
    const extended = jobRow({ snap: snapshot({ validUntil: "2026-12-01" }) });
    const second = mockBackend({ jobRows: [extended], existingIds });
    await run(body(), Date.parse("2026-12-02T07:00:00Z"));
    expect(first.inserts[0].id).toBe(expectedId("2026-11-02"));
    expect(second.inserts[0].id).toBe(expectedId("2026-12-01"));
    expect(second.emails).toHaveLength(1);
  });

  test("a failed owner email never fails the customer's request", async () => {
    jest.spyOn(console, "error").mockImplementation(() => {});
    const calls = mockBackend({ failNotify: true });
    await expect(run(body())).resolves.toEqual({ status: 200, json: { ok: true } });
    expect(calls.emails).toHaveLength(1);
  });

  test("an unknown zone is judged anywhere-on-Earth (never early)", async () => {
    const row = jobRow({ snap: snapshot({ validUntilTimeZone: "Mars/Olympus" }) });
    mockBackend({ jobRows: [row] });
    expect((await run(body(), Date.parse("2026-11-03T11:59:59Z"))).status).toBe(409);
    const calls = mockBackend({ jobRows: [row] });
    expect((await run(body(), Date.parse("2026-11-03T12:00:00Z"))).status).toBe(200);
    expect(calls.inserts).toHaveLength(1);
  });
});
