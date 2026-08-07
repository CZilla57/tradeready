// Tests for utils/scheduleConfig.ts — resolveSchedule + helpers (Phase 11 A1).
// resolveSchedule is the single sanctioned reader of Settings.schedule: absent
// or garbled config must resolve to defaults that reproduce pre-Phase-11
// behavior (fixed 08:00–17:00 window, Mon–Sat, no buffers, no blackouts).
import {
  resolveSchedule,
  isBlackoutDate,
  isWorkDay,
  SCHEDULE_DEFAULTS,
} from "../utils/scheduleConfig";
import type { Settings } from "../types/models";

const settingsWith = (schedule?: unknown): Settings =>
  ({ schedule } as unknown as Settings);

describe("resolveSchedule", () => {
  test("absent schedule resolves to full defaults", () => {
    const r = resolveSchedule(settingsWith(undefined));
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
    expect(r).toEqual(SCHEDULE_DEFAULTS);
  });

  test("partial overrides merge with defaults", () => {
    const r = resolveSchedule(
      settingsWith({ workDayStart: "07:00", bufferMinutes: 15 })
    );
    expect(r.workDayStart).toBe("07:00");
    expect(r.bufferMinutes).toBe(15);
    expect(r.workDayEnd).toBe("17:00");
    expect(r.workDays).toEqual([1, 2, 3, 4, 5, 6]);
  });

  test("valid full config passes through", () => {
    const r = resolveSchedule(
      settingsWith({
        timeZone: "America/Chicago",
        workDays: [2, 4],
        workDayStart: "09:30",
        workDayEnd: "15:00",
        defaultDurationMinutes: 90,
        bufferMinutes: 30,
        slotLeadHours: 48,
        slotWindowDays: 21,
        bookableSlotsEnabled: true,
      })
    );
    expect(r.timeZone).toBe("America/Chicago");
    expect(r.workDays).toEqual([2, 4]);
    expect(r.workDayStart).toBe("09:30");
    expect(r.workDayEnd).toBe("15:00");
    expect(r.defaultDurationMinutes).toBe(90);
    expect(r.bufferMinutes).toBe(30);
    expect(r.slotLeadHours).toBe(48);
    expect(r.slotWindowDays).toBe(21);
    expect(r.bookableSlotsEnabled).toBe(true);
  });

  test("workDays: out-of-range and non-integer entries filtered, dupes removed, sorted", () => {
    const r = resolveSchedule(
      settingsWith({ workDays: [0, 8, 3, 3, 1.5, "2" as unknown as number, 7, 1] })
    );
    expect(r.workDays).toEqual([1, 3, 7]);
  });

  test("workDays: empty after filtering falls back to default", () => {
    expect(resolveSchedule(settingsWith({ workDays: [] })).workDays).toEqual(
      [1, 2, 3, 4, 5, 6]
    );
    expect(resolveSchedule(settingsWith({ workDays: [0, 9] })).workDays).toEqual(
      [1, 2, 3, 4, 5, 6]
    );
  });

  test("malformed time strings fall back to defaults", () => {
    const r = resolveSchedule(
      settingsWith({ workDayStart: "9am", workDayEnd: "25:00" })
    );
    expect(r.workDayStart).toBe("08:00");
    expect(r.workDayEnd).toBe("17:00");
  });

  test("inverted or equal work window falls back to defaults (both ends)", () => {
    const inverted = resolveSchedule(
      settingsWith({ workDayStart: "18:00", workDayEnd: "09:00" })
    );
    expect(inverted.workDayStart).toBe("08:00");
    expect(inverted.workDayEnd).toBe("17:00");
    const equal = resolveSchedule(
      settingsWith({ workDayStart: "10:00", workDayEnd: "10:00" })
    );
    expect(equal.workDayStart).toBe("08:00");
    expect(equal.workDayEnd).toBe("17:00");
  });

  test("zero is a valid value for bufferMinutes and slotLeadHours (FA-017: no falsy-default)", () => {
    const r = resolveSchedule(
      settingsWith({ bufferMinutes: 0, slotLeadHours: 0 })
    );
    expect(r.bufferMinutes).toBe(0);
    expect(r.slotLeadHours).toBe(0);
  });

  test("negative, non-numeric, or non-positive numeric fields fall back to defaults", () => {
    const r = resolveSchedule(
      settingsWith({
        defaultDurationMinutes: 0,
        bufferMinutes: -5,
        slotLeadHours: -1,
        slotWindowDays: "14" as unknown as number,
      })
    );
    expect(r.defaultDurationMinutes).toBe(60);
    expect(r.bufferMinutes).toBe(0);
    expect(r.slotLeadHours).toBe(24);
    expect(r.slotWindowDays).toBe(14);
  });

  test("blackouts: well-formed entries kept, malformed dropped", () => {
    const r = resolveSchedule(
      settingsWith({
        blackouts: [
          { id: "b1", start: "2026-08-10", end: "2026-08-12", reason: "vacation" },
          { id: "b2", start: "2026-08-15", end: "2026-08-15" },
          { id: "", start: "2026-08-20", end: "2026-08-21" }, // blank id
          { id: "b4", start: "2026-08-22" }, // missing end
          { id: "b5", start: "22/08/2026", end: "2026-08-23" }, // malformed date
          { id: "b6", start: "2026-08-25", end: "2026-08-24" }, // end before start
          "junk",
        ],
      })
    );
    expect(r.blackouts).toEqual([
      { id: "b1", start: "2026-08-10", end: "2026-08-12", reason: "vacation" },
      { id: "b2", start: "2026-08-15", end: "2026-08-15", reason: undefined },
    ]);
  });

  test("empty-string timeZone resolves to null", () => {
    expect(resolveSchedule(settingsWith({ timeZone: "" })).timeZone).toBeNull();
  });
});

describe("isBlackoutDate", () => {
  const r = resolveSchedule(
    settingsWith({
      blackouts: [{ id: "b1", start: "2026-08-10", end: "2026-08-12" }],
    })
  );

  test("inclusive on both bounds", () => {
    expect(isBlackoutDate(r, "2026-08-10")).toBe(true);
    expect(isBlackoutDate(r, "2026-08-11")).toBe(true);
    expect(isBlackoutDate(r, "2026-08-12")).toBe(true);
  });

  test("false outside the period and with no blackouts", () => {
    expect(isBlackoutDate(r, "2026-08-09")).toBe(false);
    expect(isBlackoutDate(r, "2026-08-13")).toBe(false);
    expect(isBlackoutDate(SCHEDULE_DEFAULTS, "2026-08-11")).toBe(false);
  });
});

describe("isWorkDay", () => {
  // 2026-08-10 is a Monday, 2026-08-09 a Sunday, 2026-08-08 a Saturday.
  test("default Mon–Sat: Monday and Saturday work, Sunday does not", () => {
    const r = resolveSchedule(settingsWith(undefined));
    expect(isWorkDay(r, "2026-08-10")).toBe(true);
    expect(isWorkDay(r, "2026-08-08")).toBe(true);
    expect(isWorkDay(r, "2026-08-09")).toBe(false);
  });

  test("custom workDays respected", () => {
    const r = resolveSchedule(settingsWith({ workDays: [1, 3] }));
    expect(isWorkDay(r, "2026-08-10")).toBe(true); // Mon
    expect(isWorkDay(r, "2026-08-11")).toBe(false); // Tue
    expect(isWorkDay(r, "2026-08-12")).toBe(true); // Wed
  });
});
