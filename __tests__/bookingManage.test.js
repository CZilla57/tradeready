// __tests__/bookingManage.test.js
// Phase 11 D1: the customer manage cores
// (backend-workers/lib/booking/manage.js) + the ICS builder. The manage
// token is a capability scoped to ONE booking: the view answers with the
// minimal card (businessName/status/slot — never the customer's own echo,
// never other bookings, never job data), actions walk a strict state
// machine with server-written history, and cancel frees the reservation so
// the slot is immediately re-offerable.

const {
  manageViewCore,
  manageActionCore,
} = require("../backend-workers/lib/booking/manage.js");
const { buildIcs } = require("../backend-workers/lib/booking/ics.js");

const ENV = { SUPABASE_URL: "https://supa.test", SUPABASE_SERVICE_ROLE_KEY: "srk" };
const NOW_MS = Date.UTC(2026, 7, 10, 12, 0);
const MANAGE = "m".repeat(48);

const bookedData = (over = {}) => ({
  id: "bk1_aa",
  status: "booked",
  kind: "booked",
  name: "Dana Fox",
  phone: "555-0100",
  email: "dana@x.com",
  address: "12 Elm",
  details: "Water heater",
  preferredTiming: "",
  createdAt: "2026-08-07T15:00:00.000Z",
  convertedJobId: "jbk_bk1_aa",
  slot: {
    date: "2026-08-12",
    start: "09:00",
    end: "10:00",
    timeZone: "America/Phoenix",
    startUtc: "2026-08-12T16:00:00.000Z",
    endUtc: "2026-08-12T17:00:00.000Z",
  },
  manageToken: MANAGE,
  history: [{ at: "2026-08-07T15:00:00.000Z", actor: "customer", event: "booked" }],
  ...over,
});

function jsonRes(body, status = 200) {
  return {
    ok: status >= 200 && status < 300,
    status,
    json: async () => body,
    text: async () => JSON.stringify(body),
  };
}

function mockBackend({ requestRows = [], settingsRows = [] } = {}) {
  const calls = { requestPatches: [], reservationPatches: [], pushPosts: [] };
  global.fetch = jest.fn(async (url, init = {}) => {
    const u = String(url);
    const method = init.method || "GET";
    if (u.includes("/rest/v1/bookingRequests")) {
      if (method === "PATCH") {
        calls.requestPatches.push({ url: u, body: JSON.parse(init.body) });
        return jsonRes({}, 204);
      }
      return jsonRes(requestRows);
    }
    if (u.includes("/rest/v1/booking_reservations") && method === "PATCH") {
      calls.reservationPatches.push({ url: u, body: JSON.parse(init.body) });
      return jsonRes({}, 204);
    }
    if (u.includes("/rest/v1/settings")) return jsonRes(settingsRows);
    if (u.includes("exp.host")) {
      calls.pushPosts.push(JSON.parse(init.body));
      return jsonRes({});
    }
    if (u.includes("/auth/v1/admin/users")) return jsonRes({ email: "owner@x.com" });
    if (u.includes("api.resend.com")) return jsonRes({});
    return jsonRes([]);
  });
  return calls;
}

const requestRow = (data) => [{ id: data.id, user_id: "u1", data }];
const ownerSettings = [{ user_id: "u1", data: { businessName: "ABC Electrical", pushToken: { token: "ExponentPushToken[x]" } } }];

afterEach(() => {
  delete global.fetch;
});

describe("manageViewCore", () => {
  test("missing or unknown token → 400/404, no oracle", async () => {
    mockBackend();
    expect((await manageViewCore(ENV, { token: undefined })).status).toBe(400);
    mockBackend({ requestRows: [] });
    const r = await manageViewCore(ENV, { token: MANAGE });
    expect(r.status).toBe(404);
    expect(r.body).toEqual({ error: "This link is invalid." });
  });

  test("returns ONLY businessName, status, slot — nothing else leaks", async () => {
    mockBackend({ requestRows: requestRow(bookedData()), settingsRows: ownerSettings });
    const r = await manageViewCore(ENV, { token: MANAGE });
    expect(r.status).toBe(200);
    expect(Object.keys(r.body).sort()).toEqual(["businessName", "slot", "status"]);
    expect(r.body.businessName).toBe("ABC Electrical");
    expect(r.body.status).toBe("booked");
    expect(r.body.slot.date).toBe("2026-08-12");
  });
});

describe("manageActionCore state machine", () => {
  test("confirm: booked → confirmed with a customer history entry", async () => {
    const calls = mockBackend({ requestRows: requestRow(bookedData()), settingsRows: ownerSettings });
    const r = await manageActionCore(ENV, { token: MANAGE, action: "confirm", nowMs: NOW_MS });
    expect(r.status).toBe(200);
    expect(r.body).toEqual({ ok: true, status: "confirmed" });
    expect(calls.requestPatches).toHaveLength(1);
    const patched = calls.requestPatches[0].body.data;
    expect(patched.status).toBe("confirmed");
    expect(patched.history).toHaveLength(2);
    expect(patched.history[1]).toEqual({
      at: new Date(NOW_MS).toISOString(),
      actor: "customer",
      event: "confirm",
    });
    // confirm holds the slot — no reservation change
    expect(calls.reservationPatches).toHaveLength(0);
  });

  test("confirm on an already-confirmed booking is an idempotent no-write", async () => {
    const calls = mockBackend({
      requestRows: requestRow(bookedData({ status: "confirmed" })),
      settingsRows: ownerSettings,
    });
    const r = await manageActionCore(ENV, { token: MANAGE, action: "confirm", nowMs: NOW_MS });
    expect(r.status).toBe(200);
    expect(calls.requestPatches).toHaveLength(0);
  });

  test("request_reschedule keeps the slot held and notifies the owner with the job id", async () => {
    const calls = mockBackend({ requestRows: requestRow(bookedData()), settingsRows: ownerSettings });
    const r = await manageActionCore(ENV, {
      token: MANAGE,
      action: "request_reschedule",
      note: "Can we do afternoon instead?",
      nowMs: NOW_MS,
    });
    expect(r.body.status).toBe("reschedule_requested");
    const patched = calls.requestPatches[0].body.data;
    expect(patched.history[1]).toMatchObject({
      actor: "customer",
      event: "request_reschedule",
      note: "Can we do afternoon instead?",
    });
    expect(calls.reservationPatches).toHaveLength(0); // held until the owner responds
    expect(calls.pushPosts).toHaveLength(1);
    expect(calls.pushPosts[0].data).toEqual({ type: "booking_update", jobId: "jbk_bk1_aa" });
  });

  test("cancel frees the reservation (slot re-offerable) and records history", async () => {
    const calls = mockBackend({ requestRows: requestRow(bookedData({ status: "confirmed" })), settingsRows: ownerSettings });
    const r = await manageActionCore(ENV, { token: MANAGE, action: "cancel", nowMs: NOW_MS });
    expect(r.body.status).toBe("cancelled");
    expect(calls.reservationPatches).toHaveLength(1);
    expect(calls.reservationPatches[0].url).toContain("request_id=eq.bk1_aa");
    expect(calls.reservationPatches[0].url).toContain("status=eq.booked");
    expect(calls.reservationPatches[0].body).toEqual({ status: "cancelled" });
  });

  test("illegal transitions → 409 invalid_state, nothing written", async () => {
    const calls = mockBackend({ requestRows: requestRow(bookedData({ status: "cancelled" })), settingsRows: ownerSettings });
    for (const action of ["confirm", "request_reschedule", "cancel"]) {
      const r = await manageActionCore(ENV, { token: MANAGE, action, nowMs: NOW_MS });
      expect(r.status).toBe(409);
      expect(r.body).toEqual({ error: "invalid_state" });
    }
    expect(calls.requestPatches).toHaveLength(0);
  });

  test("unknown action and oversized note → 400", async () => {
    mockBackend({ requestRows: requestRow(bookedData()), settingsRows: ownerSettings });
    expect((await manageActionCore(ENV, { token: MANAGE, action: "explode", nowMs: NOW_MS })).status).toBe(400);
    expect(
      (
        await manageActionCore(ENV, {
          token: MANAGE,
          action: "request_reschedule",
          note: "x".repeat(301),
          nowMs: NOW_MS,
        })
      ).status
    ).toBe(400);
  });
});

describe("buildIcs", () => {
  test("emits a valid single-event calendar from the slot's UTC instants", () => {
    const ics = buildIcs({
      businessName: "ABC; Electrical, Inc",
      slot: bookedData().slot,
      uid: "bk1_aa@tradeready",
    });
    expect(ics).toContain("BEGIN:VCALENDAR");
    expect(ics).toContain("BEGIN:VEVENT");
    expect(ics).toContain("DTSTART:20260812T160000Z");
    expect(ics).toContain("DTEND:20260812T170000Z");
    expect(ics).toContain("UID:bk1_aa@tradeready");
    // RFC 5545 text escaping for , and ;
    expect(ics).toContain("SUMMARY:Appointment — ABC\\; Electrical\\, Inc");
    expect(ics).toContain("END:VCALENDAR");
    // CRLF line endings throughout
    expect(ics.split("\r\n").length).toBeGreaterThan(5);
  });
});
