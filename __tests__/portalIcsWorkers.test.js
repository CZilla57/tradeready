// __tests__/portalIcsWorkers.test.js
// Phase 12A: add-to-calendar for owner-scheduled job appointments.
// buildJobIcs emits FLOATING local time (no Z, no TZID) on purpose — owner-
// naive schedule strings carry no zone, and a local-trades appointment
// renders correctly at face value (spec §4, decision D6). portalIcsCore is
// oracle-free: unknown token, foreign job, and unscheduled job are the same
// 404 as the portal view.

const { buildJobIcs } = require("../backend-workers/lib/booking/ics.js");

const STAMP = "2026-08-10T12:00:00.000Z";

describe("buildJobIcs", () => {
  test("timed event: floating DTSTART/DTEND, no Z, escaped summary", () => {
    const ics = buildJobIcs({
      businessName: "Ace; Plumbing", title: "Heater, swap", date: "2026-08-12",
      start: "09:00", end: "10:30", uid: "j1@tradeready-portal", stampUtc: STAMP,
    });
    expect(ics).toContain("DTSTART:20260812T090000\r\n");
    expect(ics).toContain("DTEND:20260812T103000\r\n");
    expect(ics).toContain("SUMMARY:Heater\\, swap — Ace\\; Plumbing");
    expect(ics).toContain("DTSTAMP:20260810T120000Z");
    expect(ics).not.toMatch(/DTSTART:[^\r]*Z/);
    expect(ics).toContain("UID:j1@tradeready-portal");
  });

  test("missing or inverted end falls back to start + 60 minutes", () => {
    const noEnd = buildJobIcs({ businessName: "B", title: "T", date: "2026-08-12", start: "09:00", end: null, uid: "u", stampUtc: STAMP });
    expect(noEnd).toContain("DTEND:20260812T100000");
    const inverted = buildJobIcs({ businessName: "B", title: "T", date: "2026-08-12", start: "09:00", end: "08:00", uid: "u", stampUtc: STAMP });
    expect(inverted).toContain("DTEND:20260812T100000");
    const nearMidnight = buildJobIcs({ businessName: "B", title: "T", date: "2026-08-12", start: "23:30", end: null, uid: "u", stampUtc: STAMP });
    expect(nearMidnight).toContain("DTEND:20260812T235900"); // clamped, never rolls over
  });

  test("no start time → all-day event with exclusive DTEND (month rollover safe)", () => {
    const ics = buildJobIcs({ businessName: "B", title: "T", date: "2026-08-31", start: null, end: null, uid: "u", stampUtc: STAMP });
    expect(ics).toContain("DTSTART;VALUE=DATE:20260831");
    expect(ics).toContain("DTEND;VALUE=DATE:20260901");
  });

  test("no title falls back to a generic summary", () => {
    const ics = buildJobIcs({ businessName: "Ace", title: "", date: "2026-08-12", start: null, end: null, uid: "u", stampUtc: STAMP });
    expect(ics).toContain("SUMMARY:Appointment — Ace");
  });
});

const { portalIcsCore } = require("../backend-workers/lib/estimate/portalIcs.js");

const ENV = { SUPABASE_URL: "https://supa.test", SUPABASE_SERVICE_ROLE_KEY: "srk" };
const TOKEN = "p".repeat(48);

function mockPortalBackend({ customerRows = [], jobRows = [], settingsRows = [] } = {}) {
  global.fetch = jest.fn(async (url) => {
    const u = String(url);
    const body = u.includes("/rest/v1/customers") ? customerRows
      : u.includes("/rest/v1/jobs") ? jobRows
      : u.includes("/rest/v1/settings") ? settingsRows
      : [];
    return { ok: true, status: 200, json: async () => body, text: async () => "[]" };
  });
}

afterEach(() => { delete global.fetch; });

describe("portalIcsCore", () => {
  const customer = { user_id: "u1", id: "c1", data: { name: "Dana" } };
  const schedJob = { id: "j1", data: { title: "Heater", customerId: "c1", scheduledDate: "2026-08-12", scheduledStartTime: "09:00", scheduledEndTime: "10:00" } };

  test("unknown token → oracle-free 404", async () => {
    mockPortalBackend({ customerRows: [] });
    expect(await portalIcsCore(ENV, { token: TOKEN, jobId: "j1", stampUtc: STAMP }))
      .toEqual({ ok: false, status: 404, error: "This link is invalid." });
  });

  test("job not in this customer's rows → same 404", async () => {
    mockPortalBackend({ customerRows: [customer], jobRows: [schedJob] });
    expect((await portalIcsCore(ENV, { token: TOKEN, jobId: "other", stampUtc: STAMP })).status).toBe(404);
  });

  test("unscheduled job → same 404", async () => {
    mockPortalBackend({ customerRows: [customer], jobRows: [{ id: "j2", data: { title: "NoSched", customerId: "c1" } }] });
    expect((await portalIcsCore(ENV, { token: TOKEN, jobId: "j2", stampUtc: STAMP })).status).toBe(404);
  });

  test("scheduled job → floating VEVENT with the business name", async () => {
    mockPortalBackend({ customerRows: [customer], jobRows: [schedJob], settingsRows: [{ data: { businessName: "Ace" } }] });
    const out = await portalIcsCore(ENV, { token: TOKEN, jobId: "j1", stampUtc: STAMP });
    expect(out.ok).toBe(true);
    expect(out.ics).toContain("DTSTART:20260812T090000");
    expect(out.ics).toContain("SUMMARY:Heater — Ace");
    expect(out.ics).toContain("UID:j1@tradeready-portal");
  });
});
