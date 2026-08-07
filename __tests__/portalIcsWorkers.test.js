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
