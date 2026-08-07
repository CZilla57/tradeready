// __tests__/bookingAvailability.test.js
// The Workers-side availability twin (Phase 11 B2): resolveSchedule +
// computeCandidateSlots mirrors of the client engine, plus the naive→UTC
// resolver the public boundary needs. Runs under Node's full ICU (jest);
// the Workers runtime ICU check is Phase C task 1 before deploy.
//
// DST facts used (America/Chicago, 2026): spring forward Sun Mar 8
// (02:00→03:00 local does not exist); fall back Sun Nov 1 (01:00–02:00
// local happens twice — CDT then CST).

const {
  resolveSchedule,
  computeCandidateSlots,
  zonedTimeToUtc,
  resolveSlotsUtc,
} = require("../backend-workers/lib/booking/availability.js");

describe("zonedTimeToUtc", () => {
  test("summer and winter offsets resolve correctly (America/Chicago)", () => {
    expect(zonedTimeToUtc("2026-08-10", "09:00", "America/Chicago")).toBe(
      "2026-08-10T14:00:00.000Z" // CDT, UTC-5
    );
    expect(zonedTimeToUtc("2026-01-15", "09:00", "America/Chicago")).toBe(
      "2026-01-15T15:00:00.000Z" // CST, UTC-6
    );
  });

  test("a nonexistent spring-forward local time returns null", () => {
    expect(zonedTimeToUtc("2026-03-08", "02:30", "America/Chicago")).toBeNull();
  });

  test("an ambiguous fall-back local time resolves to the FIRST occurrence", () => {
    // 01:30 happens at 06:30Z (CDT) and 07:30Z (CST); first = CDT
    expect(zonedTimeToUtc("2026-11-01", "01:30", "America/Chicago")).toBe(
      "2026-11-01T06:30:00.000Z"
    );
  });

  test("far-east and half-hour zones", () => {
    expect(zonedTimeToUtc("2026-08-10", "09:00", "Pacific/Auckland")).toBe(
      "2026-08-09T21:00:00.000Z" // NZST, UTC+12
    );
    expect(zonedTimeToUtc("2026-08-10", "09:00", "Asia/Kolkata")).toBe(
      "2026-08-10T03:30:00.000Z" // IST, UTC+5:30
    );
  });

  test("UTC round-trips", () => {
    expect(zonedTimeToUtc("2026-08-10", "00:00", "UTC")).toBe(
      "2026-08-10T00:00:00.000Z"
    );
  });
});

describe("resolveSlotsUtc", () => {
  test("appends startUtc/endUtc and DROPS slots whose start does not exist locally", () => {
    const slots = [
      { date: "2026-03-08", start: "01:30", end: "02:30" },
      { date: "2026-03-08", start: "02:30", end: "03:30" }, // start nonexistent
      { date: "2026-03-08", start: "09:00", end: "10:00" },
    ];
    const resolved = resolveSlotsUtc(slots, "America/Chicago");
    expect(resolved.map((s) => s.start)).toEqual(["01:30", "09:00"]);
    expect(resolved[1]).toEqual({
      date: "2026-03-08",
      start: "09:00",
      end: "10:00",
      startUtc: "2026-03-08T14:00:00.000Z", // CDT already active
      endUtc: "2026-03-08T15:00:00.000Z",
    });
  });
});

describe("server twin — resolveSchedule + computeCandidateSlots", () => {
  test("absent schedule resolves to the same defaults as the client", () => {
    const r = resolveSchedule({});
    expect(r).toEqual({
      timeZone: null,
      workDays: [1, 2, 3, 4, 5, 6],
      workDayStart: "08:00",
      workDayEnd: "17:00",
      defaultDurationMinutes: 60,
      bufferMinutes: 0,
      slotLeadHours: 24,
      slotWindowDays: 14,
      blackouts: [],
      bookableSlotsEnabled: false,
    });
  });

  test("slots respect jobs, buffer, and lead like the client engine", () => {
    const schedule = resolveSchedule({ schedule: { slotLeadHours: 0, bufferMinutes: 30 } });
    const jobs = [
      {
        id: "j1",
        status: "scheduled",
        scheduledDate: "2026-08-10",
        scheduledStartTime: "09:00",
        scheduledEndTime: "11:00",
        laborHours: 2,
      },
    ];
    const slots = computeCandidateSlots({
      schedule,
      jobs,
      fromDate: "2026-08-10",
      days: 1,
      now: { date: "2026-08-01", minutes: 0 },
    });
    const starts = slots.map((s) => s.start);
    expect(starts).not.toContain("08:00"); // padded busy 08:30–11:30
    expect(starts[0]).toBe("11:30");
  });

  test("reservations arrive as extraBusy and block", () => {
    const schedule = resolveSchedule({ schedule: { slotLeadHours: 0 } });
    const slots = computeCandidateSlots({
      schedule,
      jobs: [],
      extraBusy: [{ date: "2026-08-10", start: "08:00", end: "16:00" }],
      fromDate: "2026-08-10",
      days: 1,
      now: { date: "2026-08-01", minutes: 0 },
    });
    expect(slots.map((s) => s.start)).toEqual(["16:00"]);
  });
});
