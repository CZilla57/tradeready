// __tests__/calendarBusyParity.test.js
// Roadmap Phase 26 (spec docs/superpowers/specs/2026-10-03-calendar-sync-design.md
// §7 "Shared vectors", D18): the Worker side of the shared schedule vectors.
// native/ScheduleTests/Fixtures/scheduleVectors.json is read here AND by the
// Swift availability suite (native/AvailabilityTests, via
// SCHEDULE_FIXTURES_PATH), so the calendar busy gate, the offer pipeline, the
// "24:00" extraBusy end and the zone/now boundary are pinned in both twins
// against the same expected values instead of hand-copied numbers.

const fs = require("fs");
const path = require("path");

const {
  SCHEDULE_DEFAULTS,
  resolveSchedule,
  computeCandidateSlots,
  zonedTimeToUtc,
  nowInZone,
} = require("../backend-workers/lib/booking/availability.js");
const { calendarBusyGate } = require("../backend-workers/lib/calendar/busyGate.js");
const { offerableSlots } = require("../backend-workers/lib/booking/offerable.js");

const FIXTURE = path.join(__dirname, "../native/ScheduleTests/Fixtures/scheduleVectors.json");
const vectors = JSON.parse(fs.readFileSync(FIXTURE, "utf8"));

describe("shared schedule vectors: existing sections", () => {
  test("defaults match the Worker engine", () => {
    expect(SCHEDULE_DEFAULTS.workDays).toEqual(vectors.defaults.workDays);
    expect(SCHEDULE_DEFAULTS.workDayStart).toBe(vectors.defaults.workDayStart);
    expect(SCHEDULE_DEFAULTS.workDayEnd).toBe(vectors.defaults.workDayEnd);
    expect(SCHEDULE_DEFAULTS.defaultDurationMinutes).toBe(vectors.defaults.defaultDurationMinutes);
    expect(SCHEDULE_DEFAULTS.slotWindowDays).toBe(vectors.defaults.slotWindowDays);
    expect(SCHEDULE_DEFAULTS.slotLeadHours).toBe(vectors.defaults.slotLeadHours);
  });

  test.each(vectors.zoneVectors)("zonedTimeToUtc $date $time $zone", (v) => {
    expect(zonedTimeToUtc(v.date, v.time, v.zone)).toBe(v.startUtc);
  });

  test.each(vectors.nowVectors)("nowInZone $zone $utcIso", (v) => {
    expect(nowInZone(v.zone, Date.parse(v.utcIso))).toEqual({ date: v.date, minutes: v.minutes });
  });
});

describe("calendarBusyVectors: the busy-window gate (§2.4)", () => {
  test("the fixture carries every required case", () => {
    const names = vectors.calendarBusyVectors.map((v) => v.name).join("\n");
    for (const needle of ["no row", "null snapshot", "47:59", "48:01", "future computedAt", "windowEnd in the past",
      "invalid snapshot", "across midnight", "spring-forward", "fall-back fold", "Auckland", "Kolkata", "all-day",
      "midnight edges", "mid-day edges", "24:00"]) {
      expect(names).toContain(needle);
    }
  });

  test.each(vectors.calendarBusyVectors.map((v) => [v.name, v]))("%s", (_name, v) => {
    expect(calendarBusyGate(v.row, { timeZone: v.zone, nowMs: Date.parse(v.nowUtc) })).toEqual(v.expected);
  });

  test("the fold vector is the spec's 00:30–02:15", () => {
    const fold = vectors.calendarBusyVectors.find((v) => v.name.includes("fall-back fold"));
    expect(fold.expected.windows).toEqual([{ date: "2026-11-01", start: "00:30", end: "02:15" }]);
  });

  test("the gate never emits a 24:00 end", () => {
    for (const v of vectors.calendarBusyVectors) {
      for (const w of v.expected.windows || []) expect(w.end).not.toBe("24:00");
    }
  });
});

describe("offerableScenarios: the shared offer pipeline", () => {
  test.each(vectors.offerableScenarios.map((s) => [s.name, s]))("%s", (_name, s) => {
    const out = offerableSlots({
      schedule: resolveSchedule({ schedule: s.scheduleBlob }),
      jobs: s.jobs,
      reservations: s.reservations,
      calendarRow: s.row,
      nowMs: Date.parse(s.nowUtc),
    });
    expect(out).toEqual(s.expected);
  });

  test("off is today's computation exactly", () => {
    const s = vectors.offerableScenarios.find((x) => x.row === null);
    const schedule = resolveSchedule({ schedule: s.scheduleBlob });
    const now = nowInZone(schedule.timeZone, Date.parse(s.nowUtc));
    const today = computeCandidateSlots({
      schedule, jobs: s.jobs, extraBusy: [], fromDate: now.date, days: schedule.slotWindowDays, now,
    });
    expect(s.expected.slots.map(({ date, start, end }) => ({ date, start, end }))).toEqual(today);
  });
});

describe('midnightEndVectors: an extraBusy end of "24:00" (§4.6)', () => {
  test.each(vectors.midnightEndVectors.map((v) => [v.name, v]))("%s", (_name, v) => {
    const out = computeCandidateSlots({
      schedule: resolveSchedule({ schedule: v.scheduleBlob }),
      jobs: [],
      extraBusy: v.extraBusy,
      fromDate: v.fromDate,
      days: v.days,
      now: v.now,
    });
    expect(out).toEqual(v.expected);
  });
});
