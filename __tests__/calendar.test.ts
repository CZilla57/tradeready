// Tests for utils/calendar.ts — pure day/week selectors behind CalendarScreen
// (Phase 11 A3). Blocks derive end from scheduledEndTime else max(labor,1)h
// (the blockWindow rule shared with conflict math); "" schedule fields are
// treated as missing (AddJobScreen writes "" for cleared fields, not null).
import {
  buildCalendarDay,
  buildCalendarWeek,
  dayAxis,
  selectUnscheduledApproved,
  minutesToLabel,
} from "../utils/calendar";
import { resolveSchedule, SCHEDULE_DEFAULTS } from "../utils/scheduleConfig";
import type { Job, Settings } from "../types/models";

const settingsWith = (schedule?: unknown): Settings =>
  ({ schedule } as unknown as Settings);

function job(overrides: Partial<Job>): Job {
  return {
    id: "j1",
    customerId: "c1",
    customerName: "A",
    title: "Faucet repair",
    description: "",
    status: "scheduled",
    scheduledDate: "2026-08-05",
    scheduledStartTime: "09:00",
    scheduledEndTime: "11:00",
    address: "",
    estimateTotal: 0,
    laborHours: 2,
    laborRate: 85,
    materials: [],
    materialMarkup: 20,
    overhead: 15,
    margin: 20,
    notes: "",
    invoiceId: null,
    createdAt: "2026-08-01",
    ...overrides,
  };
}

describe("buildCalendarDay", () => {
  test("empty day has no blocks", () => {
    const d = buildCalendarDay([], "2026-08-05", SCHEDULE_DEFAULTS);
    expect(d).toEqual({ date: "2026-08-05", timed: [], untimed: [] });
  });

  test("jobs on other dates are excluded", () => {
    const d = buildCalendarDay(
      [job({ scheduledDate: "2026-08-06" })],
      "2026-08-05",
      SCHEDULE_DEFAULTS
    );
    expect(d.timed).toHaveLength(0);
    expect(d.untimed).toHaveLength(0);
  });

  test("block minutes come from start/end times", () => {
    const d = buildCalendarDay([job({})], "2026-08-05", SCHEDULE_DEFAULTS);
    expect(d.timed).toHaveLength(1);
    expect(d.timed[0].startMinutes).toBe(9 * 60);
    expect(d.timed[0].endMinutes).toBe(11 * 60);
  });

  test("missing end derives from max(laborHours, 1h)", () => {
    const twoH = buildCalendarDay(
      [job({ scheduledEndTime: null, laborHours: 2 })],
      "2026-08-05",
      SCHEDULE_DEFAULTS
    );
    expect(twoH.timed[0].endMinutes).toBe(11 * 60);
    const unpriced = buildCalendarDay(
      [job({ scheduledEndTime: "", laborHours: 0 })],
      "2026-08-05",
      SCHEDULE_DEFAULTS
    );
    expect(unpriced.timed[0].endMinutes).toBe(10 * 60);
  });

  test('"" or null start time lands the job in untimed', () => {
    const d = buildCalendarDay(
      [
        job({ id: "a", scheduledStartTime: null, scheduledEndTime: null }),
        job({ id: "b", scheduledStartTime: "", scheduledEndTime: "" }),
        job({ id: "c" }),
      ],
      "2026-08-05",
      SCHEDULE_DEFAULTS
    );
    expect(d.untimed.map((j) => j.id)).toEqual(["a", "b"]);
    expect(d.timed.map((b) => b.job.id)).toEqual(["c"]);
  });

  test("timed blocks sort by start time", () => {
    const d = buildCalendarDay(
      [
        job({ id: "late", scheduledStartTime: "13:00", scheduledEndTime: "14:00" }),
        job({ id: "early", scheduledStartTime: "08:30", scheduledEndTime: "09:30" }),
      ],
      "2026-08-05",
      SCHEDULE_DEFAULTS
    );
    expect(d.timed.map((b) => b.job.id)).toEqual(["early", "late"]);
  });

  test("overlapping blocks share a cluster: side-by-side lanes", () => {
    const d = buildCalendarDay(
      [
        job({ id: "a", scheduledStartTime: "09:00", scheduledEndTime: "12:00" }),
        job({ id: "b", scheduledStartTime: "09:30", scheduledEndTime: "10:30" }),
      ],
      "2026-08-05",
      SCHEDULE_DEFAULTS
    );
    const [a, b] = d.timed;
    expect([a.lane, b.lane].sort()).toEqual([0, 1]);
    expect(a.laneCount).toBe(2);
    expect(b.laneCount).toBe(2);
  });

  test("disjoint blocks each get the full width (lane 0 of 1)", () => {
    const d = buildCalendarDay(
      [
        job({ id: "a", scheduledStartTime: "09:00", scheduledEndTime: "10:00" }),
        job({ id: "b", scheduledStartTime: "10:00", scheduledEndTime: "11:00" }),
      ],
      "2026-08-05",
      SCHEDULE_DEFAULTS
    );
    expect(d.timed.map((b) => b.lane)).toEqual([0, 0]);
    expect(d.timed.map((b) => b.laneCount)).toEqual([1, 1]);
  });

  test("a freed lane is reused within a cluster", () => {
    const d = buildCalendarDay(
      [
        job({ id: "a", scheduledStartTime: "09:00", scheduledEndTime: "12:00" }),
        job({ id: "b", scheduledStartTime: "09:30", scheduledEndTime: "10:30" }),
        job({ id: "c", scheduledStartTime: "10:45", scheduledEndTime: "11:30" }),
      ],
      "2026-08-05",
      SCHEDULE_DEFAULTS
    );
    const byId = Object.fromEntries(d.timed.map((b) => [b.job.id, b]));
    expect(byId.a.lane).toBe(0);
    expect(byId.b.lane).toBe(1);
    expect(byId.c.lane).toBe(1); // b's lane freed at 10:30
    expect(byId.c.laneCount).toBe(2); // cluster used 2 lanes
  });

  test("terminal-status jobs render as blocks but are flagged and never conflict", () => {
    const d = buildCalendarDay(
      [
        job({ id: "live", scheduledStartTime: "09:00", scheduledEndTime: "11:00" }),
        job({ id: "done", status: "paid", scheduledStartTime: "10:00", scheduledEndTime: "12:00" }),
      ],
      "2026-08-05",
      SCHEDULE_DEFAULTS
    );
    const byId = Object.fromEntries(d.timed.map((b) => [b.job.id, b]));
    expect(byId.done.isTerminal).toBe(true);
    expect(byId.live.isTerminal).toBe(false);
    expect(byId.live.inConflict).toBe(false);
    expect(byId.done.inConflict).toBe(false);
  });

  test("overlapping live blocks are flagged inConflict", () => {
    const d = buildCalendarDay(
      [
        job({ id: "a", scheduledStartTime: "09:00", scheduledEndTime: "11:00" }),
        job({ id: "b", scheduledStartTime: "10:00", scheduledEndTime: "12:00" }),
      ],
      "2026-08-05",
      SCHEDULE_DEFAULTS
    );
    expect(d.timed.every((b) => b.inConflict)).toBe(true);
  });

  test("buffer from resolved schedule feeds the conflict flag", () => {
    const buffered = resolveSchedule(settingsWith({ bufferMinutes: 30 }));
    const jobs = [
      job({ id: "a", scheduledStartTime: "09:00", scheduledEndTime: "11:00" }),
      job({ id: "b", scheduledStartTime: "11:15", scheduledEndTime: "12:15" }),
    ];
    const withBuffer = buildCalendarDay(jobs, "2026-08-05", buffered);
    expect(withBuffer.timed.every((b) => b.inConflict)).toBe(true);
    const without = buildCalendarDay(jobs, "2026-08-05", SCHEDULE_DEFAULTS);
    expect(without.timed.every((b) => !b.inConflict)).toBe(true);
  });
});

describe("dayAxis", () => {
  test("empty day covers the work window exactly", () => {
    const d = buildCalendarDay([], "2026-08-05", SCHEDULE_DEFAULTS);
    expect(dayAxis(d, SCHEDULE_DEFAULTS)).toEqual({
      startMinutes: 8 * 60,
      endMinutes: 17 * 60,
    });
  });

  test("out-of-hours blocks stretch the axis to hour boundaries", () => {
    const d = buildCalendarDay(
      [job({ scheduledStartTime: "07:30", scheduledEndTime: "18:10" })],
      "2026-08-05",
      SCHEDULE_DEFAULTS
    );
    expect(dayAxis(d, SCHEDULE_DEFAULTS)).toEqual({
      startMinutes: 7 * 60,
      endMinutes: 19 * 60,
    });
  });

  test("axis never crosses midnight", () => {
    const d = buildCalendarDay(
      [job({ scheduledStartTime: "22:00", scheduledEndTime: null, laborHours: 5 })],
      "2026-08-05",
      SCHEDULE_DEFAULTS
    );
    expect(dayAxis(d, SCHEDULE_DEFAULTS).endMinutes).toBe(24 * 60);
  });
});

describe("buildCalendarWeek", () => {
  test("returns Mon–Sun days containing their jobs", () => {
    // 2026-08-05 is a Wednesday → week 2026-08-03 (Mon) … 2026-08-09 (Sun)
    const week = buildCalendarWeek(
      [
        job({ id: "mon", scheduledDate: "2026-08-03" }),
        job({ id: "wed", scheduledDate: "2026-08-05" }),
        job({ id: "outside", scheduledDate: "2026-08-10" }),
      ],
      "2026-08-05",
      SCHEDULE_DEFAULTS
    );
    expect(week).toHaveLength(7);
    expect(week[0].date).toBe("2026-08-03");
    expect(week[6].date).toBe("2026-08-09");
    expect(week[0].timed.map((b) => b.job.id)).toEqual(["mon"]);
    expect(week[2].timed.map((b) => b.job.id)).toEqual(["wed"]);
    expect(week.flatMap((d) => d.timed).map((b) => b.job.id)).not.toContain("outside");
  });
});

describe("selectUnscheduledApproved", () => {
  test("approved jobs without a date, oldest first; others excluded", () => {
    const picked = selectUnscheduledApproved([
      job({ id: "newer", status: "approved", scheduledDate: null, createdAt: "2026-08-04" }),
      job({ id: "older", status: "approved", scheduledDate: "", createdAt: "2026-08-01" }),
      job({ id: "hasDate", status: "approved" }),
      job({ id: "lead", status: "lead", scheduledDate: null }),
      job({ id: "gone", status: "approved", scheduledDate: null, archivedAt: "2026-08-02" }),
    ]);
    expect(picked.map((j) => j.id)).toEqual(["older", "newer"]);
  });
});

describe("minutesToLabel", () => {
  test("pads to HH:MM", () => {
    expect(minutesToLabel(8 * 60)).toBe("08:00");
    expect(minutesToLabel(17 * 60)).toBe("17:00");
    expect(minutesToLabel(605)).toBe("10:05");
  });
});
