// __tests__/bookingRespond.test.js
// Phase 11 D2: the owner respond core
// (backend-workers/lib/booking/respond.js). JWT auth lives in the route
// wrapper; the core takes the resolved userId and enforces OWNERSHIP as a
// 404 (no oracle — a valid request id belonging to someone else is
// indistinguishable from an unknown one). Both actions free the
// reservation; resolve_reschedule lands on confirmed (the owner has moved
// the job — the job's own schedule is the busy-ness truth now), decline
// lands on declined and emails the customer.

const { respondCore } = require("../backend-workers/lib/booking/respond.js");

const ENV = {
  SUPABASE_URL: "https://supa.test",
  SUPABASE_SERVICE_ROLE_KEY: "srk",
  RESEND_API_KEY: "re_test",
};
const NOW_MS = Date.UTC(2026, 7, 10, 12, 0);

const data = (over = {}) => ({
  id: "bk1_aa",
  status: "reschedule_requested",
  kind: "booked",
  name: "Dana Fox",
  email: "dana@x.com",
  phone: "",
  address: "",
  details: "Water heater",
  preferredTiming: "",
  createdAt: "2026-08-07T15:00:00.000Z",
  slot: {
    date: "2026-08-12",
    start: "09:00",
    end: "10:00",
    timeZone: "America/Phoenix",
    startUtc: "2026-08-12T16:00:00.000Z",
    endUtc: "2026-08-12T17:00:00.000Z",
  },
  manageToken: "m".repeat(48),
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

function mockBackend({ requestRows = [] } = {}) {
  const calls = { requestPatches: [], reservationPatches: [], emails: [] };
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
    if (u.includes("api.resend.com")) {
      calls.emails.push(JSON.parse(init.body));
      return jsonRes({});
    }
    return jsonRes([]);
  });
  return calls;
}

afterEach(() => {
  delete global.fetch;
});

describe("respondCore", () => {
  test("unknown id and foreign ownership both → 404, indistinguishable", async () => {
    mockBackend({ requestRows: [] });
    const unknown = await respondCore(ENV, { userId: "u1", requestId: "bkX", action: "decline", nowMs: NOW_MS });
    expect(unknown.status).toBe(404);

    mockBackend({ requestRows: [{ id: "bk1_aa", user_id: "SOMEONE_ELSE", data: data() }] });
    const foreign = await respondCore(ENV, { userId: "u1", requestId: "bk1_aa", action: "decline", nowMs: NOW_MS });
    expect(foreign.status).toBe(404);
    expect(foreign.body).toEqual(unknown.body);
  });

  test("resolve_reschedule: reschedule_requested → confirmed, reservation freed, owner history", async () => {
    const calls = mockBackend({ requestRows: [{ id: "bk1_aa", user_id: "u1", data: data() }] });
    const r = await respondCore(ENV, { userId: "u1", requestId: "bk1_aa", action: "resolve_reschedule", nowMs: NOW_MS });
    expect(r.status).toBe(200);
    expect(r.body).toEqual({ ok: true, status: "confirmed" });

    const patched = calls.requestPatches[0].body.data;
    expect(patched.status).toBe("confirmed");
    expect(patched.history[1]).toEqual({
      at: new Date(NOW_MS).toISOString(),
      actor: "owner",
      event: "resolve_reschedule",
    });
    // Slot freed: the moved job's own schedule is the busy-ness truth now.
    expect(calls.reservationPatches).toHaveLength(1);
    expect(calls.reservationPatches[0].url).toContain("request_id=eq.bk1_aa");
    expect(calls.reservationPatches[0].body).toEqual({ status: "cancelled" });
  });

  test("decline works from booked/confirmed/reschedule_requested, frees the slot, emails the customer", async () => {
    for (const status of ["booked", "confirmed", "reschedule_requested"]) {
      const calls = mockBackend({ requestRows: [{ id: "bk1_aa", user_id: "u1", data: data({ status }) }] });
      const r = await respondCore(ENV, { userId: "u1", requestId: "bk1_aa", action: "decline", nowMs: NOW_MS });
      expect(r.body).toEqual({ ok: true, status: "declined" });
      expect(calls.reservationPatches).toHaveLength(1);
      expect(calls.emails).toHaveLength(1);
      expect(calls.emails[0].to).toBe("dana@x.com");
      expect(calls.emails[0].subject).toContain("appointment");
      expect(calls.emails[0].text).toContain("2026-08-12");
    }
  });

  test("no customer email on file → decline still succeeds without an email", async () => {
    const calls = mockBackend({ requestRows: [{ id: "bk1_aa", user_id: "u1", data: data({ email: "" }) }] });
    const r = await respondCore(ENV, { userId: "u1", requestId: "bk1_aa", action: "decline", nowMs: NOW_MS });
    expect(r.status).toBe(200);
    expect(calls.emails).toHaveLength(0);
  });

  test("illegal transitions and unknown actions rejected", async () => {
    const calls = mockBackend({ requestRows: [{ id: "bk1_aa", user_id: "u1", data: data({ status: "declined" }) }] });
    expect((await respondCore(ENV, { userId: "u1", requestId: "bk1_aa", action: "decline", nowMs: NOW_MS })).status).toBe(409);
    expect((await respondCore(ENV, { userId: "u1", requestId: "bk1_aa", action: "resolve_reschedule", nowMs: NOW_MS })).status).toBe(409);
    expect((await respondCore(ENV, { userId: "u1", requestId: "bk1_aa", action: "nuke", nowMs: NOW_MS })).status).toBe(400);
    expect(calls.requestPatches).toHaveLength(0);
  });

  test("resolve_reschedule only applies to reschedule_requested", async () => {
    mockBackend({ requestRows: [{ id: "bk1_aa", user_id: "u1", data: data({ status: "booked" }) }] });
    expect(
      (await respondCore(ENV, { userId: "u1", requestId: "bk1_aa", action: "resolve_reschedule", nowMs: NOW_MS })).status
    ).toBe(409);
  });
});
