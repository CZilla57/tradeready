// __tests__/calendarBusyWorkers.test.js
// Roadmap Phase 26 (spec docs/superpowers/specs/2026-10-03-calendar-sync-design.md
// §3.1–§3.2, §7 "Worker"): POST /api/calendar/busy through its handler core
// (backend-workers/lib/calendar/busyCore.js). PostgREST is a mocked
// global.fetch holding one calendar_busy row; time is injected.

const { busyCore } = require("../backend-workers/lib/calendar/busyCore.js");

const ENV = { SUPABASE_URL: "https://supa.test", SUPABASE_SERVICE_ROLE_KEY: "srk" };
const USER = "11111111-2222-4333-8444-555555555555";
const SOURCE_A = "0b8f1c1e-2f6a-4c55-9d3e-1a2b3c4d5e6f";
const SOURCE_B = "9a8b7c6d-5e4f-4a3b-8c2d-1e0f9a8b7c6d";
// 2026-10-03T14:10Z = 09:10 in America/Chicago.
const NOW_MS = Date.UTC(2026, 9, 3, 14, 10);
const DAY_MS = 86400000;

const iso = (ms) => `${new Date(ms).toISOString().slice(0, 16)}:00Z`;

function snapshot(over = {}) {
  return {
    v: 1,
    computedAt: "2026-10-03T14:05:00Z",
    windowStart: "2026-10-03T05:00:00Z",
    windowEnd: "2026-10-17T05:00:00Z",
    timed: [["2026-10-06T15:00:00Z", "2026-10-06T16:30:00Z"]],
    allDay: [["2026-10-10", "2026-10-11"]],
    ...over,
  };
}

function jsonRes(body, status = 200) {
  return { ok: status >= 200 && status < 300, status, json: async () => body, text: async () => JSON.stringify(body) };
}

/** One-row calendar_busy table. `missing` answers 404 (not deployed);
 *  `failStatus` answers that status to every call. */
function mockTable({ row = null, missing = false, failStatus = null } = {}) {
  const state = { row, calls: [] };
  global.fetch = jest.fn(async (url, init = {}) => {
    const u = String(url);
    const method = init.method || "GET";
    state.calls.push({ method, url: u, body: init.body ? JSON.parse(init.body) : undefined, headers: init.headers });
    if (!u.includes("/rest/v1/calendar_busy")) return jsonRes([]);
    if (missing) return jsonRes({ code: "PGRST205" }, 404);
    if (failStatus) return jsonRes({ message: "boom" }, failStatus);
    if (method === "GET") return jsonRes(state.row ? [state.row] : []);
    if (method === "POST") {
      state.row = JSON.parse(init.body);
      return jsonRes(null, 201);
    }
    if (method === "DELETE") {
      state.row = null;
      return jsonRes(null, 204);
    }
    return jsonRes({}, 405);
  });
  return state;
}

const put = (body, extra = {}) =>
  busyCore(ENV, { userId: USER, body: { action: "put", sourceId: SOURCE_A, snapshot: snapshot(), ...body }, nowMs: NOW_MS, ...extra });

function storedRow(over = {}) {
  return {
    user_id: USER,
    source_id: SOURCE_A,
    snapshot: { v: 1, timed: [["2026-10-06T15:00:00Z", "2026-10-06T16:30:00Z"]], allDay: [] },
    computed_at: "2026-10-03T14:05:00+00:00",
    window_start: "2026-10-03T05:00:00+00:00",
    window_end: "2026-10-17T05:00:00+00:00",
    received_at: "2026-10-03T14:06:12.345+00:00",
    ...over,
  };
}

let logs;
beforeEach(() => {
  logs = [];
  for (const level of ["log", "warn", "error"]) {
    jest.spyOn(console, level).mockImplementation((...args) => logs.push(args.join(" ")));
  }
});
afterEach(() => {
  delete global.fetch;
  jest.restoreAllMocks();
});

describe("validateSnapshot matrix → 400 invalid_snapshot, nothing written", () => {
  const cases = [
    ["v is not 1", { snapshot: snapshot({ v: 2 }) }],
    ["v missing", { snapshot: (() => { const s = snapshot(); delete s.v; return s; })() }],
    ["sourceId is not a UUID", { sourceId: "device-1" }],
    ["sourceId is uppercase", { sourceId: SOURCE_A.toUpperCase() }],
    ["sourceId missing", { sourceId: undefined }],
    ["snapshot missing (must be explicit null)", { snapshot: undefined }],
    ["snapshot is an array", { snapshot: [] }],
    ["snapshot is a string", { snapshot: "busy" }],
    ["computedAt carries seconds", { snapshot: snapshot({ computedAt: "2026-10-03T14:05:30Z" }) }],
    ["computedAt carries milliseconds", { snapshot: snapshot({ computedAt: "2026-10-03T14:05:00.000Z" }) }],
    ["windowStart has an offset instead of Z", { snapshot: snapshot({ windowStart: "2026-10-03T05:00:00+00:00" }) }],
    ["an impossible date", { snapshot: snapshot({ timed: [["2026-02-30T10:00:00Z", "2026-02-30T11:00:00Z"]] }) }],
    ["an impossible hour", { snapshot: snapshot({ timed: [["2026-10-06T24:00:00Z", "2026-10-06T24:30:00Z"]] }) }],
    ["windowStart after computedAt", { snapshot: snapshot({ windowStart: "2026-10-03T14:06:00Z" }) }],
    ["windowStart equals windowEnd", { snapshot: snapshot({ windowEnd: "2026-10-03T05:00:00Z", timed: [], allDay: [] }) }],
    ["windowEnd before windowStart", { snapshot: snapshot({ windowEnd: "2026-10-02T05:00:00Z", timed: [], allDay: [] }) }],
    ["window longer than 63 days", { snapshot: snapshot({ windowEnd: iso(Date.parse("2026-10-03T05:00:00Z") + 63 * DAY_MS + 60000) }) }],
    ["computedAt more than 10 min ahead", { snapshot: snapshot({ computedAt: iso(NOW_MS + 10 * 60000 + 60000) }) }],
    ["windowStart more than 10 min ahead", {
      snapshot: snapshot({ windowStart: iso(NOW_MS + 11 * 60000), computedAt: iso(NOW_MS + 11 * 60000), timed: [], allDay: [] }),
    }],
    ["more than 500 timed pairs", {
      snapshot: snapshot({
        timed: Array.from({ length: 501 }, (_, i) => {
          const s = Date.parse("2026-10-03T06:00:00Z") + i * 40 * 60000;
          return [iso(s), iso(s + 20 * 60000)];
        }),
      }),
    }],
    ["a timed pair with start = end", { snapshot: snapshot({ timed: [["2026-10-06T15:00:00Z", "2026-10-06T15:00:00Z"]] }) }],
    ["a timed pair ending before it starts", { snapshot: snapshot({ timed: [["2026-10-06T16:00:00Z", "2026-10-06T15:00:00Z"]] }) }],
    ["a timed pair before windowStart", { snapshot: snapshot({ timed: [["2026-10-03T04:00:00Z", "2026-10-03T06:00:00Z"]] }) }],
    ["a timed pair after windowEnd", { snapshot: snapshot({ timed: [["2026-10-17T04:00:00Z", "2026-10-17T06:00:00Z"]] }) }],
    ["overlapping timed pairs", {
      snapshot: snapshot({ timed: [["2026-10-06T15:00:00Z", "2026-10-06T16:00:00Z"], ["2026-10-06T15:30:00Z", "2026-10-06T17:00:00Z"]] }),
    }],
    ["touching timed pairs (should have merged)", {
      snapshot: snapshot({ timed: [["2026-10-06T15:00:00Z", "2026-10-06T16:00:00Z"], ["2026-10-06T16:00:00Z", "2026-10-06T17:00:00Z"]] }),
    }],
    ["unsorted timed pairs", {
      snapshot: snapshot({ timed: [["2026-10-07T15:00:00Z", "2026-10-07T16:00:00Z"], ["2026-10-06T15:00:00Z", "2026-10-06T16:00:00Z"]] }),
    }],
    ["a timed pair with three entries", { snapshot: snapshot({ timed: [["2026-10-06T15:00:00Z", "2026-10-06T16:00:00Z", "x"]] }) }],
    ["timed is not an array", { snapshot: snapshot({ timed: {} }) }],
    ["more than 100 all-day ranges", {
      snapshot: snapshot({
        allDay: Array.from({ length: 101 }, (_, i) => {
          const d = new Date(Date.UTC(2026, 9, 3) + i * 2 * DAY_MS).toISOString().slice(0, 10);
          return [d, d];
        }),
      }),
    }],
    ["an all-day impossible date", { snapshot: snapshot({ allDay: [["2026-02-30", "2026-02-30"]] }) }],
    ["an all-day range ending before it starts", { snapshot: snapshot({ allDay: [["2026-10-11", "2026-10-10"]] }) }],
    ["an all-day range longer than 63 days", { snapshot: snapshot({ allDay: [["2026-10-03", "2026-12-05"]] }) }],
    ["overlapping all-day ranges", { snapshot: snapshot({ allDay: [["2026-10-10", "2026-10-12"], ["2026-10-12", "2026-10-13"]] }) }],
    ["allDay is not an array", { snapshot: snapshot({ allDay: null }) }],
  ];

  test.each(cases)("%s", async (_label, body) => {
    const table = mockTable();
    const r = await put(body);
    expect(r).toEqual({ status: 400, body: { error: "invalid_snapshot" } });
    expect(table.calls.filter((c) => c.method !== "GET")).toEqual([]);
    expect(table.row).toBeNull();
  });

  test("the edges are accepted: 63-day window, +10 min skew, 500 pairs, 63-day all-day range", async () => {
    mockTable();
    expect((await put({ snapshot: snapshot({ windowEnd: iso(Date.parse("2026-10-03T05:00:00Z") + 63 * DAY_MS) }) })).status).toBe(200);
    expect((await put({ snapshot: snapshot({ computedAt: iso(NOW_MS + 10 * 60000) }) })).status).toBe(200);
    const pairs = Array.from({ length: 500 }, (_, i) => {
      const s = Date.parse("2026-10-03T06:00:00Z") + i * 40 * 60000;
      return [iso(s), iso(s + 20 * 60000)];
    });
    expect((await put({ snapshot: snapshot({ timed: pairs }) })).status).toBe(200);
    expect((await put({ snapshot: snapshot({ allDay: [["2026-10-03", "2026-12-04"]] }) })).status).toBe(200);
  });

  test("an oversized body is refused before any read", async () => {
    const table = mockTable();
    const r = await put({}, { bodyBytes: 64 * 1024 + 1 });
    expect(r.status).toBe(400);
    expect(r.body.error).toBe("invalid_snapshot");
    expect(table.calls).toEqual([]);
    const padded = await put({ padding: "x".repeat(64 * 1024) });
    expect(padded.status).toBe(400);
  });
});

describe("put", () => {
  test("stores the snapshot columns, stamps received_at with the Worker clock, answers created", async () => {
    const table = mockTable();
    const r = await put({});
    expect(r).toEqual({ status: 200, body: { ok: true, receivedAt: new Date(NOW_MS).toISOString(), created: true } });
    expect(table.row).toEqual({
      user_id: USER,
      source_id: SOURCE_A,
      snapshot: { v: 1, timed: [["2026-10-06T15:00:00Z", "2026-10-06T16:30:00Z"]], allDay: [["2026-10-10", "2026-10-11"]] },
      computed_at: "2026-10-03T14:05:00Z",
      window_start: "2026-10-03T05:00:00Z",
      window_end: "2026-10-17T05:00:00Z",
      received_at: new Date(NOW_MS).toISOString(),
    });
    const post = table.calls.find((c) => c.method === "POST");
    expect(post.url).toBe("https://supa.test/rest/v1/calendar_busy?on_conflict=user_id");
    expect(post.headers.Prefer).toContain("resolution=merge-duplicates");
    expect(post.headers.Authorization).toBe("Bearer srk");
  });

  test("a second put from the same device replaces the row", async () => {
    const table = mockTable({ row: storedRow() });
    const r = await put({ snapshot: snapshot({ timed: [], allDay: [] }) });
    expect(r.status).toBe(200);
    expect(r.body.created).toBe(false);
    expect(table.row.snapshot).toEqual({ v: 1, timed: [], allDay: [] });
  });

  test("unknown snapshot keys are not stored", async () => {
    const table = mockTable();
    await put({ snapshot: snapshot({ titles: ["Dentist"] }) });
    expect(Object.keys(table.row.snapshot).sort()).toEqual(["allDay", "timed", "v"]);
  });

  test("snapshot null registers checks with nothing shared", async () => {
    const table = mockTable();
    const r = await put({ snapshot: null });
    expect(r.status).toBe(200);
    expect(table.row).toMatchObject({ source_id: SOURCE_A, snapshot: null, computed_at: null, window_start: null, window_end: null });
  });

  test("another device's row → 409 source_mismatch with its receivedAt, nothing written", async () => {
    const table = mockTable({ row: storedRow({ source_id: SOURCE_B }) });
    const r = await put({});
    expect(r).toEqual({ status: 409, body: { error: "source_mismatch", receivedAt: "2026-10-03T14:06:12.345Z" } });
    expect(table.row.source_id).toBe(SOURCE_B);
    expect(table.calls.filter((c) => c.method === "POST")).toEqual([]);
  });

  test("takeOver: true replaces another device's row", async () => {
    const table = mockTable({ row: storedRow({ source_id: SOURCE_B }) });
    const r = await put({ takeOver: true });
    expect(r.status).toBe(200);
    expect(table.row.source_id).toBe(SOURCE_A);
  });

  test("takeOver must be exactly true", async () => {
    mockTable({ row: storedRow({ source_id: SOURCE_B }) });
    expect((await put({ takeOver: "yes" })).status).toBe(409);
  });
});

describe("status", () => {
  const status = (sourceId = SOURCE_A, nowMs = NOW_MS) =>
    busyCore(ENV, { userId: USER, body: { action: "status", sourceId }, nowMs });

  test("absent row: not enabled, not fresh", async () => {
    mockTable();
    expect(await status()).toEqual({
      status: 200,
      body: { ok: true, enabled: false, thisDevice: false, shared: false, computedAt: null, receivedAt: null, fresh: false, ttlHours: 48 },
    });
  });

  test("a fresh row from this device", async () => {
    mockTable({ row: storedRow() });
    expect((await status()).body).toEqual({
      ok: true, enabled: true, thisDevice: true, shared: true,
      computedAt: "2026-10-03T14:05:00Z", receivedAt: "2026-10-03T14:06:12.345Z", fresh: true, ttlHours: 48,
    });
  });

  test("another device's row, or no sourceId, is not this device", async () => {
    mockTable({ row: storedRow() });
    expect((await status(SOURCE_B)).body.thisDevice).toBe(false);
    expect((await status(null)).body.thisDevice).toBe(false);
    expect((await status(null)).body.enabled).toBe(true);
  });

  test("a stale row (past the 48 h TTL) is enabled but not fresh", async () => {
    mockTable({ row: storedRow() });
    const r = await status(SOURCE_A, Date.parse("2026-10-05T14:06:00Z"));
    expect(r.body).toMatchObject({ enabled: true, shared: true, fresh: false });
  });

  test("a null snapshot is enabled, not shared, not fresh", async () => {
    mockTable({ row: storedRow({ snapshot: null, computed_at: null, window_start: null, window_end: null }) });
    expect((await status()).body).toMatchObject({ enabled: true, shared: false, fresh: false, computedAt: null });
  });

  test("an invalid sourceId is refused", async () => {
    mockTable();
    expect((await status("nope")).status).toBe(400);
  });
});

describe("disable", () => {
  test("deletes the owner's row from any device", async () => {
    const table = mockTable({ row: storedRow({ source_id: SOURCE_B }) });
    const r = await busyCore(ENV, { userId: USER, body: { action: "disable" }, nowMs: NOW_MS });
    expect(r).toEqual({ status: 200, body: { ok: true } });
    expect(table.row).toBeNull();
    expect(table.calls.find((c) => c.method === "DELETE").url).toBe(
      `https://supa.test/rest/v1/calendar_busy?user_id=eq.${USER}`
    );
  });
});

describe("missing table, database errors, unknown actions", () => {
  test.each(["put", "status", "disable"])("a missing table (404) → 503 unavailable for %s", async (action) => {
    mockTable({ missing: true });
    const body = action === "put" ? { action, sourceId: SOURCE_A, snapshot: snapshot() } : { action, sourceId: SOURCE_A };
    expect(await busyCore(ENV, { userId: USER, body, nowMs: NOW_MS })).toEqual({ status: 503, body: { error: "unavailable" } });
  });

  test.each(["put", "status", "disable"])("a PostgREST 500 → 500 for %s", async (action) => {
    mockTable({ failStatus: 500 });
    const body = action === "put" ? { action, sourceId: SOURCE_A, snapshot: snapshot() } : { action };
    expect((await busyCore(ENV, { userId: USER, body, nowMs: NOW_MS })).status).toBe(500);
  });

  test("an unknown or missing action → 400", async () => {
    mockTable();
    expect((await busyCore(ENV, { userId: USER, body: { action: "purge" }, nowMs: NOW_MS })).status).toBe(400);
    expect((await busyCore(ENV, { userId: USER, body: {}, nowMs: NOW_MS })).status).toBe(400);
    expect((await busyCore(ENV, { userId: USER, body: null, nowMs: NOW_MS })).status).toBe(400);
  });
});

describe("logging (§5): counts only, never instants", () => {
  test("put logs counts and a user id prefix", async () => {
    mockTable();
    await put({});
    await put({ snapshot: null });
    await busyCore(ENV, { userId: USER, body: { action: "disable" }, nowMs: NOW_MS });
    expect(logs).toContain("[calendar/busy] put user=11111111 timed=1 allDay=1 windowDays=14");
    expect(logs).toContain("[calendar/busy] put user=11111111 snapshot=null");
    for (const line of logs) {
      expect(line).not.toMatch(/\d{4}-\d{2}-\d{2}/);
      expect(line).not.toContain(USER);
    }
  });

  test("refused and failed requests log no instants either", async () => {
    mockTable({ failStatus: 500 });
    await put({});
    mockTable();
    await put({ snapshot: snapshot({ v: 9 }) });
    for (const line of logs) expect(line).not.toMatch(/\d{4}-\d{2}-\d{2}T/);
  });
});
