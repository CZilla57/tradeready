// __tests__/phase8BookingLifecycle84.test.js
// Task 8.04 — Atomic reservations and booking lifecycle (contract §2 G1/G2).
//
// Server-precondition level: the fetch mock stands in for PostgREST + the
// 20260920_booking_lifecycle_rpcs.sql functions. Scripted RPC envelopes let
// each test pin the CORE's contract behavior (verdict mapping, atomicity —
// exactly one RPC call and no compensation DELETE on the RPC path, guarded
// transitions, proof handling, notify-once). This is NOT database race
// evidence: real competing-session proof is the checked-in
// supabase/verify/booking_lifecycle_concurrency.sh, labeled DEFERRED (M1).
//
// The 8.00 characterization files are untouched: they pin PRE-8.04 behavior
// against stateless mocks. This file pins the FIXED behavior.

const { reserveCore } = require("../backend-workers/lib/booking/reserve.js");
const { manageActionCore } = require("../backend-workers/lib/booking/manage.js");
const { respondCore } = require("../backend-workers/lib/booking/respond.js");

const ENV = {
  SUPABASE_URL: "https://supa.test",
  SUPABASE_SERVICE_ROLE_KEY: "srk",
  RESEND_API_KEY: "re_test",
};
// 2026-08-10T12:00Z = Mon Aug 10, 07:00 America/Chicago.
const NOW_MS = Date.UTC(2026, 7, 10, 12, 0);
const RAND = "abc123";
const MANAGE = "m".repeat(48);

const enabledSettings = (scheduleOver = {}) => ({
  businessName: "Rivera Plumbing",
  pushToken: { token: "ExponentPushToken[xyz]" },
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

// Scripted backend. rpc.claim / rpc.transition are FIFO queues of envelopes;
// rpcUnavailable=true answers every /rpc/* with 404 (function not deployed →
// legacy split path). Everything else mirrors the oracle mocks.
function mock84({
  settingsRows = [],
  jobsRows = [],
  jobProofRows = [],
  reservationRows = [],
  requestRows = [],
  rpcUnavailable = false,
  rpcClaim = [],
  rpcTransition = [],
  reserveInsertStatus = 201,
  requestInsertStatus = 201,
} = {}) {
  const calls = {
    rpcClaim: [],
    rpcTransition: [],
    reservePosts: [],
    requestPosts: [],
    requestPatches: [],
    reservationPatches: [],
    deletes: [],
    pushPosts: [],
    emails: [],
  };
  const claimQ = [...rpcClaim];
  const transitionQ = [...rpcTransition];
  global.fetch = jest.fn(async (url, init = {}) => {
    const u = String(url);
    const method = init.method || "GET";
    if (u.includes("/rest/v1/rpc/claim_booking_slot")) {
      calls.rpcClaim.push(JSON.parse(init.body));
      if (rpcUnavailable) return jsonRes({ message: "function not found" }, 404);
      return jsonRes(claimQ.length ? claimQ.shift() : { ok: true });
    }
    if (u.includes("/rest/v1/rpc/transition_booking")) {
      calls.rpcTransition.push(JSON.parse(init.body));
      if (rpcUnavailable) return jsonRes({ message: "function not found" }, 404);
      return jsonRes(transitionQ.length ? transitionQ.shift() : { ok: true, status: "x" });
    }
    if (u.includes("/rest/v1/settings")) return jsonRes(settingsRows);
    if (u.includes("/rest/v1/jobs")) {
      if (u.includes("select=data%2Cupdated_at") || u.includes("select=data,updated_at")) {
        return jsonRes(jobProofRows);
      }
      return jsonRes(jobsRows);
    }
    if (u.includes("/rest/v1/booking_reservations")) {
      if (method === "POST") {
        calls.reservePosts.push(JSON.parse(init.body));
        return jsonRes({}, reserveInsertStatus);
      }
      if (method === "DELETE") {
        calls.deletes.push(u);
        return jsonRes({}, 204);
      }
      if (method === "PATCH") {
        calls.reservationPatches.push({ url: u, body: JSON.parse(init.body) });
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
        calls.requestPatches.push({ url: u, body: JSON.parse(init.body) });
        return jsonRes({}, 204);
      }
      return jsonRes(requestRows);
    }
    if (u.includes("exp.host")) {
      calls.pushPosts.push(JSON.parse(init.body));
      return jsonRes({});
    }
    if (u.includes("/auth/v1/admin/users")) return jsonRes({ email: "owner@x.com" });
    if (u.includes("api.resend.com")) {
      calls.emails.push(JSON.parse(init.body));
      return jsonRes({});
    }
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

const bookedRow = (over = {}) => ({
  id: "bk1",
  user_id: "u1",
  data: {
    id: "bk1",
    status: "booked",
    kind: "booked",
    name: "Dana Fox",
    email: "dana@x.com",
    slot: { date: "2026-08-10", start: "09:00", end: "10:00" },
    manageToken: MANAGE,
    convertedJobId: "jbk_bk1",
    history: [{ at: "2026-08-10T12:00:00.000Z", actor: "customer", event: "booked" }],
    ...over,
  },
});

afterEach(() => {
  delete global.fetch;
  jest.restoreAllMocks();
});

describe("8.04 G1 atomic claim (RPC path)", () => {
  test("identical-start loser: 409 slot_taken, no request row, single RPC call, no compensation", async () => {
    jest.spyOn(console, "error").mockImplementation(() => {});
    const calls = mock84({
      settingsRows: settingsRow(enabledSettings()),
      rpcClaim: [{ ok: false, error: "slot_taken" }],
    });
    const r = await runReserve(reserveBody());
    expect(r.status).toBe(409);
    expect(r.body).toEqual({ error: "slot_taken" });
    expect(calls.rpcClaim).toHaveLength(1);
    expect(calls.reservePosts).toHaveLength(0);
    expect(calls.requestPosts).toHaveLength(0);
    expect(calls.deletes).toHaveLength(0);
  });

  test("overlapping different-start loser: 409 via the in-txn predicate (G1-01 gap closed)", async () => {
    // Pre-8.04 both claims committed at core level (pinned G1-01). The RPC
    // verdict now serializes the pair: the core maps the second verdict.
    const calls = mock84({
      settingsRows: settingsRow(enabledSettings()),
      rpcClaim: [{ ok: true }, { ok: false, error: "slot_taken" }],
    });
    const a = await runReserve(reserveBody({ slot: { date: "2026-08-10", start: "09:00" } }), "a".repeat(48));
    const b = await runReserve(reserveBody({ slot: { date: "2026-08-10", start: "09:30" } }), "b".repeat(48));
    expect(a.status).toBe(200);
    expect(b.status).toBe(409);
    expect(b.body).toEqual({ error: "slot_taken" });
    // Loser held nothing: exactly one committed claim's notify fired.
    expect(calls.pushPosts).toHaveLength(1);
  });

  test("buffer-only loser: 409 (G1-02 gap closed)", async () => {
    const calls = mock84({
      settingsRows: settingsRow(enabledSettings({ bufferMinutes: 60 })),
      rpcClaim: [{ ok: false, error: "slot_taken" }],
    });
    const r = await runReserve(reserveBody({ slot: { date: "2026-08-10", start: "10:00" } }));
    expect(r.status).toBe(409);
    expect(r.body).toEqual({ error: "slot_taken" });
    // Offer-time twin traveled into the claim for in-txn revalidation (§2.5).
    expect(calls.rpcClaim[0]).toMatchObject({ p_buffer_minutes: 60, p_duration_minutes: 60 });
  });

  test("config moved between offer and claim: 409 slot_changed", async () => {
    const calls = mock84({
      settingsRows: settingsRow(enabledSettings()),
      rpcClaim: [{ ok: false, error: "slot_changed" }],
    });
    const r = await runReserve(reserveBody());
    expect(r.status).toBe(409);
    expect(r.body).toEqual({ error: "slot_changed" });
    expect(calls.requestPosts).toHaveLength(0);
  });

  test("disjoint slots: both win; cross-owner same instant: both win", async () => {
    const calls = mock84({
      settingsRows: settingsRow(enabledSettings()),
      rpcClaim: [{ ok: true }, { ok: true }],
    });
    const a = await runReserve(reserveBody({ slot: { date: "2026-08-10", start: "09:00" } }), "a".repeat(48));
    const b = await runReserve(reserveBody({ slot: { date: "2026-08-10", start: "11:00" } }), "b".repeat(48));
    expect(a.status).toBe(200);
    expect(b.status).toBe(200);
    expect(calls.rpcClaim[0].p_user_id).toBe("u1");
    expect(calls.rpcClaim[1].p_user_id).toBe("u1");

    mock84({ settingsRows: settingsRow(enabledSettings(), "u2"), rpcClaim: [{ ok: true }] });
    const c = await runReserve(reserveBody(), "c".repeat(48));
    expect(c.status).toBe(200);
    expect(c.body.slot.startUtc).toBe(a.body.slot.startUtc);
  });

  test("RPC transport failure: 500, exactly one attempt, no compensation delete", async () => {
    jest.spyOn(console, "error").mockImplementation(() => {});
    global.fetch = jest.fn(async (url, init = {}) => {
      const u = String(url);
      if (u.includes("/rest/v1/rpc/")) throw new Error("boom");
      if (u.includes("/rest/v1/settings")) return jsonRes(settingsRow(enabledSettings()));
      if (u.includes("/rest/v1/jobs")) return jsonRes([]);
      if (u.includes("/rest/v1/booking_reservations")) return jsonRes([]);
      if (u.includes("exp.host")) return jsonRes({});
      if (u.includes("/auth/v1/admin/users")) return jsonRes({ email: "o@x.com" });
      if (u.includes("api.resend.com")) return jsonRes({});
      return jsonRes([]);
    });
    const deletes = [];
    const r = await runReserve(reserveBody());
    expect(r.status).toBe(500);
    expect(deletes).toHaveLength(0);
  });

  test("RPC not deployed: legacy split path is byte-identical (compat)", async () => {
    const calls = mock84({
      settingsRows: settingsRow(enabledSettings()),
      rpcUnavailable: true,
    });
    const r = await runReserve(reserveBody());
    expect(r.status).toBe(200);
    expect(r.body.manageToken).toBe(MANAGE);
    expect(r.body.slot.startUtc).toBe("2026-08-10T14:00:00.000Z"); // 09:00 CDT
    expect(calls.reservePosts).toHaveLength(1);
    expect(calls.requestPosts).toHaveLength(1);
    expect(calls.pushPosts).toHaveLength(1);
  });

  test("legacy fallback: racing-insert 409 maps to slot_taken with no request row", async () => {
    const calls = mock84({
      settingsRows: settingsRow(enabledSettings()),
      rpcUnavailable: true,
      reserveInsertStatus: 409,
    });
    const r = await runReserve(reserveBody());
    expect(r.status).toBe(409);
    expect(r.body).toEqual({ error: "slot_taken" });
    expect(calls.requestPosts).toHaveLength(0);
  });

  test("legacy fallback: request failure still compensates (orphan-hold path retained pre-RPC)", async () => {
    jest.spyOn(console, "error").mockImplementation(() => {});
    const calls = mock84({
      settingsRows: settingsRow(enabledSettings()),
      rpcUnavailable: true,
      requestInsertStatus: 500,
    });
    const r = await runReserve(reserveBody());
    expect(r.status).toBe(500);
    expect(calls.deletes).toHaveLength(1);
  });
});

describe("8.04 G2 lifecycle (RPC path)", () => {
  test("manage confirm: single guarded call, server merges entry, notify once", async () => {
    const calls = mock84({
      requestRows: [bookedRow()],
      settingsRows: [{ user_id: "u1", data: { businessName: "R", pushToken: { token: "ExponentPushToken[x]" } } }],
      rpcTransition: [{ ok: true, status: "confirmed" }],
    });
    const r = await manageActionCore(ENV, { token: MANAGE, action: "confirm", nowMs: NOW_MS });
    expect(r.status).toBe(200);
    expect(r.body).toEqual({ ok: true, status: "confirmed" });
    expect(calls.rpcTransition).toHaveLength(1);
    // Guarded write travels with the call; only the history ENTRY crosses —
    // never a whole-blob replay of the (possibly stale) read (§2.6).
    expect(calls.rpcTransition[0]).toMatchObject({
      p_request_id: "bk1",
      p_owner_id: null,
      p_manage_token: MANAGE,
      p_expected: ["booked"],
      p_target: "confirmed",
      p_release: false,
      p_proof: null,
    });
    expect(calls.rpcTransition[0].p_history).toMatchObject({ actor: "customer", event: "confirm" });
    expect(calls.rpcTransition[0]).not.toHaveProperty("p_data");
    expect(calls.requestPatches).toHaveLength(0);
    expect(calls.reservationPatches).toHaveLength(0);
    expect(calls.pushPosts).toHaveLength(0); // confirm does not notify
  });

  test("confirm-vs-cancel race: loser gets 409 invalid_state with echoed status, no second write", async () => {
    const calls = mock84({
      requestRows: [bookedRow({ status: "cancelled" })],
      rpcTransition: [{ ok: false, error: "invalid_state", status: "cancelled" }],
    });
    const r = await manageActionCore(ENV, { token: MANAGE, action: "confirm", nowMs: NOW_MS });
    expect(r.status).toBe(409);
    expect(r.body).toEqual({ error: "invalid_state", status: "cancelled" });
    expect(calls.requestPatches).toHaveLength(0);
    expect(calls.reservationPatches).toHaveLength(0);
  });

  test("retry after commit reads the new state: cancel on cancelled → 409 echo, no write, no notify", async () => {
    // §2.2 verbatim: the retry GETS 409 invalid_state with status echoed; the
    // CLIENT (8.07) maps status == intended target to success ("not server
    // magic"). Server-side: no write, no second history entry, no notify.
    const calls = mock84({
      requestRows: [bookedRow({ status: "cancelled" })],
      settingsRows: [{ user_id: "u1", data: { pushToken: { token: "ExponentPushToken[x]" } } }],
    });
    const r = await manageActionCore(ENV, { token: MANAGE, action: "cancel", nowMs: NOW_MS });
    expect(r.status).toBe(409);
    expect(r.body).toEqual({ error: "invalid_state", status: "cancelled" });
    expect(calls.rpcTransition).toHaveLength(0);
    expect(calls.requestPatches).toHaveLength(0);
    expect(calls.reservationPatches).toHaveLength(0);
    expect(calls.pushPosts).toHaveLength(0);
  });

  test("stale device view: action resolves against CURRENT server state, unknown fields preserved (legacy path)", async () => {
    // Device saw 'booked'; server already has 'confirmed' plus an owner entry
    // and an unknown field. Cancel must transition from confirmed and carry
    // every unknown/concurrent field forward (field protection, §2.6).
    const calls = mock84({
      requestRows: [
        bookedRow({
          status: "confirmed",
          extraOwnerNote: "keep-me",
          history: [
            { at: "2026-08-10T12:00:00.000Z", actor: "customer", event: "booked" },
            { at: "2026-08-10T12:05:00.000Z", actor: "customer", event: "confirm" },
          ],
        }),
      ],
      settingsRows: [{ user_id: "u1", data: { businessName: "R" } }],
      rpcUnavailable: true,
    });
    const r = await manageActionCore(ENV, { token: MANAGE, action: "cancel", nowMs: NOW_MS });
    expect(r.status).toBe(200);
    expect(r.body).toEqual({ ok: true, status: "cancelled" });
    const patched = calls.requestPatches[0].body.data;
    expect(patched.extraOwnerNote).toBe("keep-me");
    expect(patched.history).toHaveLength(3);
    expect(patched.history[2]).toMatchObject({ actor: "customer", event: "cancel" });
    // Release-before-patch order retained (G2-09).
    expect(calls.reservationPatches).toHaveLength(1);
  });

  test("illegal manage transition echoes current status; unknown capability stays 404", async () => {
    const calls = mock84({ requestRows: [bookedRow({ status: "cancelled" })] });
    const r = await manageActionCore(ENV, { token: MANAGE, action: "request_reschedule", nowMs: NOW_MS });
    expect(r.status).toBe(409);
    expect(r.body).toEqual({ error: "invalid_state", status: "cancelled" });
    expect(calls.rpcTransition).toHaveLength(0);

    mock84({ requestRows: [] });
    const unknown = await manageActionCore(ENV, { token: MANAGE, action: "confirm", nowMs: NOW_MS });
    expect(unknown.status).toBe(404);
  });

  test("respond resolve with matching proof: proof forwarded, hold released, 200", async () => {
    const proof = {
      jobId: "j1",
      updatedAt: "2026-08-10T11:00:00.000Z",
      date: "2026-08-12",
      start: "14:00",
    };
    const calls = mock84({
      requestRows: [bookedRow({ status: "reschedule_requested" })],
      rpcTransition: [{ ok: true, status: "confirmed" }],
    });
    const r = await respondCore(ENV, {
      userId: "u1",
      requestId: "bk1",
      action: "resolve_reschedule",
      scheduleProof: proof,
      nowMs: NOW_MS,
    });
    expect(r.status).toBe(200);
    expect(r.body).toEqual({ ok: true, status: "confirmed" });
    expect(calls.rpcTransition).toHaveLength(1);
    expect(calls.rpcTransition[0]).toMatchObject({
      p_request_id: "bk1",
      p_owner_id: "u1",
      p_expected: ["reschedule_requested"],
      p_target: "confirmed",
      p_release: true,
      p_proof: proof,
    });
    expect(calls.emails).toHaveLength(0);
  });

  test("superseding edit after proof: 409 schedule_changed, hold NOT released (RPC path)", async () => {
    const calls = mock84({
      requestRows: [bookedRow({ status: "reschedule_requested" })],
      rpcTransition: [{ ok: false, error: "schedule_changed", status: "reschedule_requested" }],
    });
    const r = await respondCore(ENV, {
      userId: "u1",
      requestId: "bk1",
      action: "resolve_reschedule",
      scheduleProof: { jobId: "j1", updatedAt: "2026-08-10T11:00:00.000Z", date: "2026-08-12", start: "14:00" },
      nowMs: NOW_MS,
    });
    expect(r.status).toBe(409);
    expect(r.body).toEqual({ error: "schedule_changed", status: "reschedule_requested" });
    expect(calls.requestPatches).toHaveLength(0);
    expect(calls.reservationPatches).toHaveLength(0);
  });

  test("legacy path: proof mismatch refuses BEFORE any write; proof-less legacy still resolves (L2)", async () => {
    jest.spyOn(console, "warn").mockImplementation(() => {});
    const mismatch = mock84({
      requestRows: [bookedRow({ status: "reschedule_requested" })],
      jobProofRows: [
        { data: { id: "j1", scheduledDate: "2026-08-12", scheduledStartTime: "15:00" }, updated_at: "2026-08-10T11:30:00.000Z" },
      ],
      rpcUnavailable: true,
    });
    const bad = await respondCore(ENV, {
      userId: "u1",
      requestId: "bk1",
      action: "resolve_reschedule",
      scheduleProof: { jobId: "j1", updatedAt: "2026-08-10T11:00:00.000Z", date: "2026-08-12", start: "14:00" },
      nowMs: NOW_MS,
    });
    expect(bad.status).toBe(409);
    expect(bad.body).toEqual({ error: "schedule_changed", status: "reschedule_requested" });
    expect(mismatch.reservationPatches).toHaveLength(0);
    expect(mismatch.requestPatches).toHaveLength(0);

    mock84({
      requestRows: [bookedRow({ status: "reschedule_requested" })],
      rpcUnavailable: true,
    });
    const legacy = await respondCore(ENV, {
      userId: "u1",
      requestId: "bk1",
      action: "resolve_reschedule",
      nowMs: NOW_MS,
    });
    expect(legacy.status).toBe(200);
    expect(legacy.body).toEqual({ ok: true, status: "confirmed" });
  });

  test("decline retry after commit: 409 echo with exactly one customer email total (no duplicate notify)", async () => {
    const first = mock84({
      requestRows: [bookedRow({ status: "booked" })],
      rpcTransition: [{ ok: true, status: "declined" }],
    });
    const r1 = await respondCore(ENV, { userId: "u1", requestId: "bk1", action: "decline", nowMs: NOW_MS });
    expect(r1.status).toBe(200);
    expect(first.emails).toHaveLength(1);
    expect(first.rpcTransition).toHaveLength(1);

    // Response lost; owner retries. Server reads 'declined' and answers 409
    // with the echo (§2.2 verbatim); 8.07 maps target-match to success. The
    // retry performs zero writes and sends zero emails.
    const retry = mock84({ requestRows: [bookedRow({ status: "declined" })] });
    const r2 = await respondCore(ENV, { userId: "u1", requestId: "bk1", action: "decline", nowMs: NOW_MS + 1000 });
    expect(r2.status).toBe(409);
    expect(r2.body).toEqual({ error: "invalid_state", status: "declined" });
    expect(retry.rpcTransition).toHaveLength(0);
    expect(retry.requestPatches).toHaveLength(0);
    expect(retry.emails).toHaveLength(0);
  });

  test("owner 404 isolation preserved: foreign request is indistinguishable from unknown", async () => {
    mock84({ requestRows: [] });
    const unknown = await respondCore(ENV, { userId: "u1", requestId: "bkX", action: "decline", nowMs: NOW_MS });
    expect(unknown.status).toBe(404);
    mock84({ requestRows: [{ id: "bk1", user_id: "someone-else", data: bookedRow().data }] });
    const foreign = await respondCore(ENV, { userId: "u1", requestId: "bk1", action: "decline", nowMs: NOW_MS });
    expect(foreign.status).toBe(404);
    expect(foreign.body).toEqual(unknown.body);
  });

  test("malformed proof shape is treated as legacy proof-less (never partial verification)", async () => {
    jest.spyOn(console, "warn").mockImplementation(() => {});
    const calls = mock84({
      requestRows: [bookedRow({ status: "reschedule_requested" })],
      rpcTransition: [{ ok: true, status: "confirmed" }],
    });
    const r = await respondCore(ENV, {
      userId: "u1",
      requestId: "bk1",
      action: "resolve_reschedule",
      scheduleProof: { jobId: "j1" }, // missing updatedAt/date/start
      nowMs: NOW_MS,
    });
    expect(r.status).toBe(200);
    expect(calls.rpcTransition[0].p_proof).toBeNull();
  });
});
