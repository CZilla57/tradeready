// __tests__/bookingCalendarBusyWorkers.test.js
// Roadmap Phase 26 (spec docs/superpowers/specs/2026-10-03-calendar-sync-design.md
// §3.3, §7 "Worker"): calendar busy times in the public slots and reserve
// cores (backend-workers/lib/booking/{slots,reserve}.js). Kept beside
// bookingSlotsReserve.test.js (which pins the pre-calendar behavior and must
// stay green untouched) so the two suites cannot drift. Network is a mocked
// global.fetch keyed by URL; time and randomness are injected.

const { slotsCore } = require("../backend-workers/lib/booking/slots.js");
const { reserveCore } = require("../backend-workers/lib/booking/reserve.js");
const {
  resolveSchedule,
  computeCandidateSlots,
  resolveSlotsUtc,
  nowInZone,
} = require("../backend-workers/lib/booking/availability.js");

const ENV = { SUPABASE_URL: "https://supa.test", SUPABASE_SERVICE_ROLE_KEY: "srk" };
// 2026-08-10T12:00Z = Mon Aug 10, 07:00 in America/Chicago
const NOW_MS = Date.UTC(2026, 7, 10, 12, 0);
const RAND = "abc123";
const MANAGE = "m".repeat(48);
const TOKEN = "t".repeat(48);
const USER = "u1aaaaaaaa-owner";

const enabledSettings = (over = {}) => ({
  businessName: "Rivera Plumbing",
  schedule: { timeZone: "America/Chicago", slotLeadHours: 0, bookableSlotsEnabled: true, ...over },
});

function calendarRow(over = {}) {
  return {
    user_id: USER,
    source_id: "0b8f1c1e-2f6a-4c55-9d3e-1a2b3c4d5e6f",
    // 09:00–10:00 CDT on Mon Aug 10.
    snapshot: { v: 1, timed: [["2026-08-10T14:00:00Z", "2026-08-10T15:00:00Z"]], allDay: [] },
    computed_at: "2026-08-10T11:00:00+00:00",
    window_start: "2026-08-10T05:00:00+00:00",
    window_end: "2026-08-24T05:00:00+00:00",
    received_at: "2026-08-10T11:00:30.000+00:00",
    ...over,
  };
}

function jsonRes(body, status = 200) {
  return { ok: status >= 200 && status < 300, status, json: async () => body, text: async () => JSON.stringify(body) };
}

/** URL-dispatching Supabase mock. `calendar` is the calendar_busy GET answer:
 *  an array of rows, or a status number (404 = not deployed, 500 = failure). */
function mockBackend({ settings = enabledSettings(), jobsRows = [], reservationRows = [], calendar = [] } = {}) {
  const calls = { reservePosts: [], requestPosts: [], calendarReads: 0 };
  global.fetch = jest.fn(async (url, init = {}) => {
    const u = String(url);
    const method = init.method || "GET";
    if (u.includes("/rest/v1/settings")) return jsonRes([{ user_id: USER, data: settings }]);
    if (u.includes("/rest/v1/jobs")) return jsonRes(jobsRows);
    if (u.includes("/rest/v1/calendar_busy")) {
      calls.calendarReads += 1;
      return typeof calendar === "number" ? jsonRes({ code: "x" }, calendar) : jsonRes(calendar);
    }
    if (u.includes("/rest/v1/booking_reservations")) {
      if (method === "POST") {
        calls.reservePosts.push(JSON.parse(init.body));
        return jsonRes({}, 201);
      }
      return jsonRes(reservationRows);
    }
    if (u.includes("/rest/v1/bookingRequests")) {
      calls.requestPosts.push(JSON.parse(init.body));
      return jsonRes({}, 201);
    }
    return jsonRes([]);
  });
  return calls;
}

const reserveBody = (slot) => ({
  b: TOKEN,
  name: "Dana Fox",
  phone: "555-0100",
  email: "dana@x.com",
  address: "12 Elm",
  details: "Water heater replacement",
  slot,
});
const reserve = (slot) => reserveCore(ENV, { body: reserveBody(slot), nowMs: NOW_MS, randHex: RAND, manageToken: MANAGE });
const slots = () => slotsCore(ENV, { token: TOKEN, nowMs: NOW_MS });

/** Today's offers, computed the pre-Phase-26 way. */
function todaysOffers(settings = enabledSettings()) {
  const schedule = resolveSchedule(settings);
  const now = nowInZone(schedule.timeZone, NOW_MS);
  return resolveSlotsUtc(
    computeCandidateSlots({ schedule, jobs: [], extraBusy: [], fromDate: now.date, days: schedule.slotWindowDays, now }),
    schedule.timeZone
  );
}

let warnings;
beforeEach(() => {
  warnings = [];
  jest.spyOn(console, "warn").mockImplementation((...a) => warnings.push(a.join(" ")));
  jest.spyOn(console, "error").mockImplementation(() => {});
});
afterEach(() => {
  delete global.fetch;
  jest.restoreAllMocks();
});

describe("slotsCore with calendar busy times", () => {
  test("fresh busy time removes overlapping offers, nothing else changes", async () => {
    const calls = mockBackend({ calendar: [calendarRow()] });
    const r = await slots();
    expect(r.status).toBe(200);
    expect(Object.keys(r.body).sort()).toEqual(["businessName", "slots", "timeZone"]);
    const monday = r.body.slots.filter((s) => s.date === "2026-08-10").map((s) => s.start);
    expect(monday).not.toContain("08:30");
    expect(monday).not.toContain("09:00");
    expect(monday).not.toContain("09:30");
    expect(monday).toContain("08:00");
    expect(monday).toContain("10:00");
    expect(calls.calendarReads).toBe(1);
  });

  test("the buffer pads a calendar window like a reservation", async () => {
    mockBackend({ settings: enabledSettings({ bufferMinutes: 30 }), calendar: [calendarRow()] });
    const monday = (await slots()).body.slots.filter((s) => s.date === "2026-08-10").map((s) => s.start);
    expect(monday).not.toContain("08:00"); // 08:00–09:00 ends inside the padded 08:30
    expect(monday).not.toContain("10:00");
    expect(monday).toContain("10:30");
  });

  test("stale (past the TTL) → 200 with no slots, logged with a user id prefix only", async () => {
    mockBackend({ calendar: [calendarRow({ computed_at: "2026-08-08T11:00:00+00:00", window_start: "2026-08-08T05:00:00+00:00", received_at: "2026-08-08T11:00:00+00:00" })] });
    const r = await slots();
    expect(r).toEqual({ status: 200, body: { businessName: "Rivera Plumbing", timeZone: "America/Chicago", slots: [] } });
    expect(warnings).toEqual(["[booking/slots] calendar_stale user=u1aaaaaa"]);
  });

  test("a null snapshot (checks on, nothing shared) is stale too", async () => {
    mockBackend({ calendar: [calendarRow({ snapshot: null, computed_at: null, window_start: null, window_end: null })] });
    expect((await slots()).body.slots).toEqual([]);
  });

  test("an absent row → byte-identical to today", async () => {
    mockBackend({ calendar: [] });
    const r = await slots();
    expect(JSON.stringify(r.body.slots)).toBe(JSON.stringify(todaysOffers()));
    expect(warnings).toEqual([]);
  });

  test("a missing table (404) → byte-identical to today", async () => {
    mockBackend({ calendar: 404 });
    const r = await slots();
    expect(r.status).toBe(200);
    expect(JSON.stringify(r.body.slots)).toBe(JSON.stringify(todaysOffers()));
  });

  test("a calendar fetch failure (500) → 500, like a jobs-fetch failure", async () => {
    mockBackend({ calendar: 500 });
    expect(await slots()).toEqual({ status: 500, body: { error: "Database error" } });
  });

  test("coverage caps the days: nothing after the last covered date", async () => {
    // windowEnd Wed Aug 12 00:00 CDT → last covered date Tue Aug 11.
    mockBackend({ calendar: [calendarRow({ window_end: "2026-08-12T05:00:00+00:00" })] });
    const dates = new Set((await slots()).body.slots.map((s) => s.date));
    expect([...dates].sort()).toEqual(["2026-08-10", "2026-08-11"]);
  });

  test("a mid-day windowEnd blocks the rest of that day", async () => {
    // windowEnd Tue Aug 11 12:00 CDT.
    mockBackend({ calendar: [calendarRow({ window_end: "2026-08-11T17:00:00+00:00" })] });
    const tuesday = (await slots()).body.slots.filter((s) => s.date === "2026-08-11").map((s) => s.end);
    expect(tuesday.length).toBeGreaterThan(0);
    expect(tuesday.every((end) => end <= "12:00")).toBe(true);
  });
});

describe("reserveCore with calendar busy times", () => {
  test("a slot overlapping fresh busy time → 409 slot_taken, nothing written", async () => {
    const calls = mockBackend({ calendar: [calendarRow()] });
    const r = await reserve({ date: "2026-08-10", start: "09:00" });
    expect(r).toEqual({ status: 409, body: { error: "slot_taken" } });
    expect(calls.reservePosts).toEqual([]);
    expect(calls.requestPosts).toEqual([]);
  });

  test("a free slot still books (legacy split path, RPC not deployed)", async () => {
    const calls = mockBackend({ calendar: [calendarRow()] });
    const r = await reserve({ date: "2026-08-10", start: "10:00" });
    expect(r.status).toBe(200);
    expect(r.body.slot).toMatchObject({ date: "2026-08-10", start: "10:00", end: "11:00" });
    expect(calls.reservePosts).toHaveLength(1);
  });

  test("stale → 409 slot_taken for any slot", async () => {
    const calls = mockBackend({ calendar: [calendarRow({ snapshot: null, computed_at: null, window_start: null, window_end: null })] });
    expect(await reserve({ date: "2026-08-10", start: "14:00" })).toEqual({ status: 409, body: { error: "slot_taken" } });
    expect(calls.reservePosts).toEqual([]);
    expect(warnings).toEqual(["[booking/reserve] calendar_stale user=u1aaaaaa"]);
  });

  test("an absent row or a missing table books exactly as today", async () => {
    for (const calendar of [[], 404]) {
      const calls = mockBackend({ calendar });
      const r = await reserve({ date: "2026-08-10", start: "09:00" });
      expect(r.status).toBe(200);
      expect(calls.reservePosts[0]).toMatchObject({ slot_date: "2026-08-10", slot_start: "09:00", slot_end: "10:00" });
    }
  });

  test("a calendar fetch failure → 500, nothing written", async () => {
    const calls = mockBackend({ calendar: 500 });
    expect(await reserve({ date: "2026-08-10", start: "10:00" })).toEqual({ status: 500, body: { error: "Database error" } });
    expect(calls.reservePosts).toEqual([]);
  });

  test("coverage caps reserve too: a slot after the last covered date → 409", async () => {
    mockBackend({ calendar: [calendarRow({ window_end: "2026-08-12T05:00:00+00:00" })] });
    expect((await reserve({ date: "2026-08-12", start: "10:00" })).status).toBe(409);
    expect((await reserve({ date: "2026-08-11", start: "10:00" })).status).toBe(200);
  });
});
