// Tests for utils/availability.ts — the deterministic candidate-slot engine
// (Phase 11 B1, 2026-08-07 spec §5). Pure and timezone-free: everything is
// owner-naive "YYYY-MM-DD" / "HH:MM" strings and minutes-since-midnight;
// `now` is injected. Busy windows follow scheduleSmarts.blockWindow (missing
// end → max(labor, 1h)) padded by the schedule buffer; slots start on the
// 30-minute grid and run defaultDurationMinutes.
//
// Date facts used: 2026-08-10 Mon, 08-11 Tue, 08-15 Sat, 08-16 Sun.

import { computeCandidateSlots, type CandidateSlot } from "../utils/availability";
import { resolveSchedule, SCHEDULE_DEFAULTS } from "../utils/scheduleConfig";
import type { Job, Settings } from "../types/models";

const settingsWith = (schedule?: unknown): Settings =>
  ({ schedule } as unknown as Settings);

/** Lead 0 so slot visibility is purely structural unless a test sets it. */
const OPEN = resolveSchedule(settingsWith({ slotLeadHours: 0 }));
/** A `now` far before every fixture date. */
const EARLY = { date: "2026-08-01", minutes: 0 };

function job(overrides: Partial<Job>): Job {
  return {
    id: "j1",
    customerId: "c1",
    customerName: "Dana",
    title: "Faucet repair",
    description: "",
    status: "scheduled",
    scheduledDate: "2026-08-10",
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

const starts = (slots: CandidateSlot[], date: string) =>
  slots.filter((s) => s.date === date).map((s) => s.start);

describe("computeCandidateSlots — structure", () => {
  test("an empty workday yields grid-aligned hour slots across the work window", () => {
    const slots = computeCandidateSlots({
      schedule: OPEN,
      jobs: [],
      fromDate: "2026-08-10",
      days: 1,
      now: EARLY,
    });
    // 08:00–17:00, 60-min duration, 30-min grid → 08:00 … 16:00 starts
    expect(slots[0]).toEqual({ date: "2026-08-10", start: "08:00", end: "09:00" });
    expect(slots[slots.length - 1]).toEqual({ date: "2026-08-10", start: "16:00", end: "17:00" });
    expect(slots).toHaveLength(17);
  });

  test("output is sorted by date then start across the horizon", () => {
    const slots = computeCandidateSlots({
      schedule: OPEN,
      jobs: [],
      fromDate: "2026-08-10",
      days: 2,
      now: EARLY,
    });
    const keys = slots.map((s) => `${s.date}T${s.start}`);
    expect(keys).toEqual([...keys].sort());
    expect(slots.filter((s) => s.date === "2026-08-11")).toHaveLength(17);
  });

  test("horizon: only `days` days starting at fromDate", () => {
    const slots = computeCandidateSlots({
      schedule: OPEN,
      jobs: [],
      fromDate: "2026-08-10",
      days: 3,
      now: EARLY,
    });
    expect(new Set(slots.map((s) => s.date))).toEqual(
      new Set(["2026-08-10", "2026-08-11", "2026-08-12"])
    );
  });

  test("non-workdays and blackout days yield nothing", () => {
    const withBlackout = resolveSchedule(
      settingsWith({
        slotLeadHours: 0,
        blackouts: [{ id: "b1", start: "2026-08-11", end: "2026-08-11" }],
      })
    );
    const slots = computeCandidateSlots({
      schedule: withBlackout,
      jobs: [],
      fromDate: "2026-08-10",
      days: 8, // Mon 10th … Mon 17th, includes Sun 16th + blacked-out Tue 11th
      now: EARLY,
    });
    const dates = new Set(slots.map((s) => s.date));
    expect(dates.has("2026-08-16")).toBe(false); // Sunday (Mon–Sat default)
    expect(dates.has("2026-08-11")).toBe(false); // blackout
    expect(dates.has("2026-08-15")).toBe(true); // Saturday works
  });
});

describe("computeCandidateSlots — busy windows", () => {
  test("a scheduled job blocks its window; the gap after realigns to the grid", () => {
    // Job 09:00–11:00 → morning slot 08:00 only; afternoon resumes 11:00
    const s = starts(
      computeCandidateSlots({
        schedule: OPEN,
        jobs: [job({})],
        fromDate: "2026-08-10",
        days: 1,
        now: EARLY,
      }),
      "2026-08-10"
    );
    expect(s).toContain("08:00");
    expect(s).not.toContain("08:30"); // 08:30+60 = 09:30 overlaps the job
    expect(s).not.toContain("09:00");
    expect(s).not.toContain("10:30");
    expect(s).toContain("11:00");
  });

  test("a job ending off-grid pushes the next slot to the following grid line", () => {
    const s = starts(
      computeCandidateSlots({
        schedule: OPEN,
        jobs: [job({ scheduledStartTime: "08:00", scheduledEndTime: "09:15" })],
        fromDate: "2026-08-10",
        days: 1,
        now: EARLY,
      }),
      "2026-08-10"
    );
    expect(s[0]).toBe("09:30");
  });

  test("missing end time blocks max(laborHours, 1h), like conflict math", () => {
    const s = starts(
      computeCandidateSlots({
        schedule: OPEN,
        jobs: [job({ scheduledEndTime: null, laborHours: 3 })], // 09:00–12:00
        fromDate: "2026-08-10",
        days: 1,
        now: EARLY,
      }),
      "2026-08-10"
    );
    expect(s).not.toContain("11:30");
    expect(s).toContain("12:00");
  });

  test("terminal-status jobs do not block", () => {
    const s = starts(
      computeCandidateSlots({
        schedule: OPEN,
        jobs: [job({ status: "paid" })],
        fromDate: "2026-08-10",
        days: 1,
        now: EARLY,
      }),
      "2026-08-10"
    );
    expect(s).toContain("09:00");
    expect(s).toHaveLength(17);
  });

  test("buffer pads jobs on both sides", () => {
    const buffered = resolveSchedule(settingsWith({ slotLeadHours: 0, bufferMinutes: 30 }));
    const s = starts(
      computeCandidateSlots({
        schedule: buffered,
        jobs: [job({})], // padded busy 08:30–11:30
        fromDate: "2026-08-10",
        days: 1,
        now: EARLY,
      }),
      "2026-08-10"
    );
    expect(s).not.toContain("08:00"); // 08:00+60 = 09:00 > 08:30 padded start
    expect(s[0]).toBe("11:30");
  });

  test("extraBusy windows (server reservations) block with the same padding", () => {
    const s = starts(
      computeCandidateSlots({
        schedule: OPEN,
        jobs: [],
        extraBusy: [{ date: "2026-08-10", start: "08:00", end: "12:00" }],
        fromDate: "2026-08-10",
        days: 1,
        now: EARLY,
      }),
      "2026-08-10"
    );
    expect(s[0]).toBe("12:00");
  });

  test("a fully-booked day yields nothing", () => {
    const slots = computeCandidateSlots({
      schedule: OPEN,
      jobs: [job({ scheduledStartTime: "07:00", scheduledEndTime: "18:00" })],
      fromDate: "2026-08-10",
      days: 1,
      now: EARLY,
    });
    expect(slots).toHaveLength(0);
  });
});

describe("computeCandidateSlots — duration and lead time", () => {
  test("longer durations only fit where the gap is long enough", () => {
    const ninety = resolveSchedule(
      settingsWith({ slotLeadHours: 0, defaultDurationMinutes: 90 })
    );
    const s = starts(
      computeCandidateSlots({
        schedule: ninety,
        jobs: [job({ scheduledStartTime: "09:30", scheduledEndTime: "15:30" })],
        fromDate: "2026-08-10",
        days: 1,
        now: EARLY,
      }),
      "2026-08-10"
    );
    // Morning gap 08:00–09:30 fits exactly one 90-min slot; afternoon 15:30–17:00 one
    expect(s).toEqual(["08:00", "15:30"]);
  });

  test("lead time hides near-term slots, across day boundaries", () => {
    const lead24 = resolveSchedule(settingsWith({ slotLeadHours: 24 }));
    const slots = computeCandidateSlots({
      schedule: lead24,
      jobs: [],
      fromDate: "2026-08-10",
      days: 2,
      now: { date: "2026-08-10", minutes: 10 * 60 }, // Mon 10:00
    });
    // Monday entirely inside 24h; Tuesday opens at 10:00
    expect(slots.filter((s) => s.date === "2026-08-10")).toHaveLength(0);
    expect(starts(slots, "2026-08-11")[0]).toBe("10:00");
  });

  test("zero lead keeps future slots on the same day, drops past ones", () => {
    const slots = computeCandidateSlots({
      schedule: OPEN,
      jobs: [],
      fromDate: "2026-08-10",
      days: 1,
      now: { date: "2026-08-10", minutes: 12 * 60 + 10 }, // 12:10
    });
    expect(starts(slots, "2026-08-10")[0]).toBe("12:30");
  });

  test("defaults object is never mutated", () => {
    const before = JSON.stringify(SCHEDULE_DEFAULTS);
    computeCandidateSlots({
      schedule: SCHEDULE_DEFAULTS,
      jobs: [job({})],
      fromDate: "2026-08-10",
      days: 3,
      now: EARLY,
    });
    expect(JSON.stringify(SCHEDULE_DEFAULTS)).toBe(before);
  });
});
