// __tests__/phase8BookingIntegrityCharacterization.test.js
// Task 8.00 (G1/G2) — CHARACTERIZATION ONLY. Pins CURRENT reserve/lifecycle
// core behavior against a URL-keyed fetch mock. Nothing here is database race
// evidence: every "concurrent" case below is two sequential core calls sharing
// one stale snapshot, which is exactly what two racing isolates observe. The
// mocked identical-start 409 (G1-03) pins the error MAPPING, not the Postgres
// partial unique index — real competing-session proof is DEFERRED (M1) to
// task 8.14 with a live PG harness. No implementation file is touched.

const { reserveCore } = require("../backend-workers/lib/booking/reserve.js");
const { manageActionCore, manageViewCore } = require("../backend-workers/lib/booking/manage.js");
const { respondCore } = require("../backend-workers/lib/booking/respond.js");

const ENV = { SUPABASE_URL: "https://supa.test", SUPABASE_SERVICE_ROLE_KEY: "srk" };
// 2026-08-10T12:00Z = Mon Aug 10, 07:00 America/Chicago.
const NOW_MS = Date.UTC(2026, 7, 10, 12, 0);
const RAND = "abc123";
const MANAGE = "m".repeat(48);

const enabledSettings = (scheduleOver = {}) => ({
  businessName: "Rivera Plumbing",
  schedule: {
    timeZone: "America/Chicago",
    slotLeadHours: 0,
    bookableSlotsEnabled: true,
    defaultDurationMinutes: 60,
    ...scheduleOver,
  },
});

function jsonRes(body, status = 200) {
  return {
    ok: status >= 200 && status < 300,
    status,
    json: async () => body,
    text: async () => JSON.stringify(body),
  };
}

// Shared stale snapshot: both "racing" calls observe the same reservations.
function mockBackend({
  settingsRows = [],
  jobsRows = [],
  reservationRows = [],
  reserveInsertStatus = 201,
  requestInsertStatus = 201,
  reservationDeleteStatus = 204,
} = {}) {
  const calls = {
    reservePosts: [],
    requestPosts: [],
    requestPatches: [],
    reservationPatches: [],
    deletes: [],
    order: [],
  };
  global.fetch = jest.fn(async (url, init = {}) => {
    const u = String(url);
    const method = init.method || "GET";
    if (u.includes("/rest/v1/settings")) return jsonRes(settingsRows);
    if (u.includes("/rest/v1/jobs")) return jsonRes(jobsRows);
    if (u.includes("/rest/v1/booking_reservations")) {
      if (method === "POST") {
        calls.reservePosts.push(JSON.parse(init.body));
        return jsonRes({}, reserveInsertStatus);
      }
      if (method === "DELETE") {
        calls.deletes.push(u);
        return jsonRes({}, reservationDeleteStatus);
      }
      if (method === "PATCH") {
        calls.reservationPatches.push(JSON.parse(init.body));
        calls.order.push("reservation-patch");
        return jsonRes({}, 204);
      }
      return jsonRes(reservationRows);
    }
    if (u.includes("/rest/v1/bookingRequests")) {
      if (method === "POST") {
        calls.requestPosts.push(JSON.parse(init.body));
        return jsonRes({}, requestInsertStatus);
      }
      if (method === "PATCH") {
        calls.requestPatches.push(JSON.parse(init.body));
        calls.order.push("request-patch");
        return jsonRes({}, 204);
      }
      return jsonRes([]);
    }
    if (u.includes("exp.host")) return jsonRes({});
    if (u.includes("/auth/v1/admin/users")) return jsonRes({ email: "owner@x.com" });
    if (u.includes("api.resend.com")) return jsonRes({});
    return jsonRes([]);
  });
  return calls;
}

const settingsRow = (data, userId = "u1") => [{ user_id: userId, data }];
const reserveBody = (over = {}) => ({
  b: "t".repeat(48),
  slot: { date: "2026-08-10", start: "09:00" },
  name: "Dana Fox",
  phone: "555-0100",
  email: "dana@x.com",
  address: "12 Elm",
  details: "Water heater replacement",
  ...over,
});
const runReserve = (body, manageToken = MANAGE) =>
  reserveCore(ENV, { body, nowMs: NOW_MS, randHex: RAND, manageToken });

afterEach(() => {
  delete global.fetch;
  jest.restoreAllMocks();
});

describe("G1 reservation integrity (characterization)", () => {
  test("G1-01: different-start overlap — both claims succeed at core level", async () => {
    // 60-min duration: 09:00 and 09:30 overlap, yet BOTH are offered
    // candidates and BOTH inserts succeed against the mock. The current
    // partial unique index covers identical slot_start_utc only, so nothing
    // below the DB serializes this pair. (Mock-level characterization.)
    const calls = mockBackend({ settingsRows: settingsRow(enabledSettings()) });
    const a = await runReserve(reserveBody({ slot: { date: "2026-08-10", start: "09:00" } }), "a".repeat(48));
    const b = await runReserve(reserveBody({ slot: { date: "2026-08-10", start: "09:30" } }), "b".repeat(48));
    expect(a.status).toBe(200);
    expect(b.status).toBe(200);
    expect(calls.reservePosts).toHaveLength(2);
    expect(calls.requestPosts).toHaveLength(2);
  });

  test("G1-02: buffer-only race — both succeed on a stale snapshot", async () => {
    // buffer 60: 09:00 and 10:00 violate the buffer predicate against each
    // other, but each call's membership recompute sees an empty reservation
    // list, so both commit at core level. The §2.1 RPC must recheck in-txn.
    const calls = mockBackend({
      settingsRows: settingsRow(enabledSettings({ bufferMinutes: 60 })),
    });
    const a = await runReserve(reserveBody({ slot: { date: "2026-08-10", start: "09:00" } }), "a".repeat(48));
    const b = await runReserve(reserveBody({ slot: { date: "2026-08-10", start: "10:00" } }), "b".repeat(48));
    expect(a.status).toBe(200);
    expect(b.status).toBe(200);
    expect(calls.reservePosts).toHaveLength(2);
  });

  test("G1-03: identical-start insert 409 maps to slot_taken, no request row (MOCK-LEVEL ONLY)", async () => {
    // Pins the error mapping. This mocked 409 is NOT database race evidence
    // (M1): it proves the handler translates 409, not that Postgres
    // serializes two live INSERTs. That proof needs the 8.14 PG harness.
    const calls = mockBackend({
      settingsRows: settingsRow(enabledSettings()),
      reserveInsertStatus: 409,
    });
    const r = await runReserve(reserveBody());
    expect(r.status).toBe(409);
    expect(r.body).toEqual({ error: "slot_taken" });
    expect(calls.requestPosts).toHaveLength(0);
  });

  test("G1-04: cross-owner same instant — both succeed (owner-scoped index)", async () => {
    const calls = mockBackend({
      settingsRows: [
        { user_id: "u1", data: enabledSettings() },
        // lookupUserByBookingToken returns the first matching row; emulate
        // per-owner isolation by running one reserve per owner row below.
      ],
    });
    const a = await runReserve(reserveBody());
    expect(a.status).toBe(200);
    // Second owner, same slot instant, separate settings row.
    mockBackend({ settingsRows: settingsRow(enabledSettings(), "u2") });
    const b = await runReserve(reserveBody(), "b".repeat(48));
    expect(b.status).toBe(200);
    expect(b.body.slot.startUtc).toBe(a.body.slot.startUtc);
    expect(calls.reservePosts[0].user_id).toBe("u1");
  });

  test("G1-05: request-insert failure compensates; failed compensation orphans the hold", async () => {
    jest.spyOn(console, "error").mockImplementation(() => {});
    const calls = mockBackend({
      settingsRows: settingsRow(enabledSettings()),
      requestInsertStatus: 500,
      reservationDeleteStatus: 500,
    });
    const r = await runReserve(reserveBody());
    expect(r.status).toBe(500);
    // Compensation was attempted (best-effort) but failed: the hold row
    // remains with status='booked'. This orphan residual is why §2.1 moves
    // both inserts into one transaction.
    expect(calls.deletes).toHaveLength(1);
    expect(calls.deletes[0]).toContain("booking_reservations");
  });
});

describe("G2 lifecycle authority (characterization)", () => {
  const bookedRow = (over = {}) => ({
    id: "bk1",
    user_id: "u1",
    data: {
      id: "bk1",
      status: "booked",
      kind: "booked",
      name: "Dana Fox",
      slot: { date: "2026-08-10", start: "09:00", end: "10:00" },
      manageToken: MANAGE,
      history: [{ at: "2026-08-10T12:00:00.000Z", actor: "customer", event: "booked" }],
      ...over,
    },
  });

  function mockLifecycle({ row = bookedRow(), settingsData = { businessName: "Rivera" } } = {}) {
    const calls = { requestPatches: [], reservationPatches: [], order: [] };
    global.fetch = jest.fn(async (url, init = {}) => {
      const u = String(url);
      const method = init.method || "GET";
      if (u.includes("/rest/v1/bookingRequests") && method === "PATCH") {
        calls.requestPatches.push(JSON.parse(init.body));
        calls.order.push("request-patch");
        return jsonRes({}, 204);
      }
      if (u.includes("/rest/v1/bookingRequests")) return jsonRes([row]);
      if (u.includes("/rest/v1/booking_reservations") && method === "PATCH") {
        calls.reservationPatches.push(JSON.parse(init.body));
        calls.order.push("reservation-patch");
        return jsonRes({}, 204);
      }
      if (u.includes("/rest/v1/settings")) return jsonRes([{ user_id: "u1", data: settingsData }]);
      if (u.includes("api.resend.com")) return jsonRes({});
      return jsonRes([]);
    });
    return calls;
  }

  test("G2-06: double transition on a stale read — both 200, forked history, no version check", async () => {
    // Both calls read status='booked'; neither observes the other. Both
    // commit. Each patch carries exactly ONE appended entry off the same
    // base — the second write silently drops the first's entry instead of
    // chaining it. Expected-state guard (§2.2) is absent today.
    const calls = mockLifecycle();
    const first = await manageActionCore(ENV, { token: MANAGE, action: "cancel", nowMs: NOW_MS });
    const second = await manageActionCore(ENV, { token: MANAGE, action: "cancel", nowMs: NOW_MS + 1000 });
    expect(first.status).toBe(200);
    expect(second.status).toBe(200);
    expect(calls.requestPatches).toHaveLength(2);
    expect(calls.requestPatches[0].data.history).toHaveLength(2);
    expect(calls.requestPatches[1].data.history).toHaveLength(2);
    expect(calls.requestPatches[1].data.history[1].at).toBe(new Date(NOW_MS + 1000).toISOString());
  });

  test("G2-07: owner respond retry lost-update — second patch drops the first history entry", async () => {
    const row = bookedRow({ status: "reschedule_requested" });
    const calls = mockLifecycle({ row });
    const baseLen = row.data.history.length;
    const first = await respondCore(ENV, { userId: "u1", requestId: "bk1", action: "resolve_reschedule", nowMs: NOW_MS });
    const second = await respondCore(ENV, { userId: "u1", requestId: "bk1", action: "resolve_reschedule", nowMs: NOW_MS + 500 });
    expect(first.status).toBe(200);
    expect(second.status).toBe(200);
    expect(calls.requestPatches).toHaveLength(2);
    // Lost update, not append: both patches extend the SAME base history.
    expect(calls.requestPatches[0].data.history).toHaveLength(baseLen + 1);
    expect(calls.requestPatches[1].data.history).toHaveLength(baseLen + 1);
  });

  test("G2-08: resolve_reschedule requires no schedule proof today (L2 basis)", async () => {
    const row = bookedRow({ status: "reschedule_requested" });
    mockLifecycle({ row });
    const r = await respondCore(ENV, {
      userId: "u1",
      requestId: "bk1",
      action: "resolve_reschedule",
      nowMs: NOW_MS,
      // No scheduleProof field exists in the current signature at all.
    });
    expect(r.status).toBe(200);
    expect(r.body).toEqual({ ok: true, status: "confirmed" });
  });

  test("G2-09: cancel frees the reservation BEFORE patching the request", async () => {
    const calls = mockLifecycle();
    const r = await manageActionCore(ENV, { token: MANAGE, action: "cancel", nowMs: NOW_MS });
    expect(r.status).toBe(200);
    expect(calls.order).toEqual(["reservation-patch", "request-patch"]);
    expect(calls.reservationPatches[0]).toEqual({ status: "cancelled" });
  });

  test("G2-10: manage view returns the stored slot verbatim (immutability basis)", async () => {
    mockLifecycle();
    const view = await manageViewCore(ENV, { token: MANAGE });
    expect(view.status).toBe(200);
    expect(view.body.slot).toEqual({ date: "2026-08-10", start: "09:00", end: "10:00" });
  });
});
