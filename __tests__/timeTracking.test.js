// __tests__/timeTracking.test.js
// Roadmap #7 (7.4): clock-in/out session math extracted from JobDetailScreen's
// TimeTrackingCard. All timestamps are UTC ("Z") and `now` is injected, so the
// rollups are deterministic regardless of the machine timezone.

import {
  computeTimeTracking,
  getActiveSession,
  formatElapsed,
  TIME_TRACKING_STATUSES,
  applyClockIn,
  applyClockOut,
} from "../utils/timeTracking";

const MIN = 60000;
const HOUR = 3600000;

describe("getActiveSession", () => {
  test("no sessions → null", () => {
    expect(getActiveSession([])).toBeNull();
  });
  test("all sessions ended → null", () => {
    expect(getActiveSession([{ start: "a", end: "b" }])).toBeNull();
  });
  test("last session without an end is active", () => {
    const active = { start: "z", end: null };
    expect(getActiveSession([{ start: "a", end: "b" }, active])).toBe(active);
  });
  test("a missing end field also counts as active", () => {
    const active = { start: "z" };
    expect(getActiveSession([active])).toBe(active);
  });
});

describe("formatElapsed", () => {
  test("under a minute is 'just now'", () => {
    expect(formatElapsed(0)).toBe("just now");
    expect(formatElapsed(59 * 1000)).toBe("just now");
  });
  test("minutes only", () => {
    expect(formatElapsed(1 * MIN)).toBe("1m");
    expect(formatElapsed(30 * MIN)).toBe("30m");
  });
  test("hours and minutes", () => {
    expect(formatElapsed(HOUR)).toBe("1h 0m");
    expect(formatElapsed(HOUR + 30 * MIN)).toBe("1h 30m");
  });
});

describe("computeTimeTracking", () => {
  test("no sessions: idle, zeroed, estimate drives a negative overUnder", () => {
    const t = computeTimeTracking([], 2, 1000);
    expect(t).toMatchObject({
      activeSession: null,
      isClocked: false,
      completedMs: 0,
      liveMs: 0,
      timerStr: "0m",
      trackedHours: 0,
      overUnder: -2,
      sessionCount: 0,
    });
  });

  test("one ended session, idle: 'Hh MMm' readout and rolled-up total", () => {
    const sessions = [
      { start: "2026-07-04T09:00:00.000Z", end: "2026-07-04T10:30:00.000Z" }, // 1h30m
    ];
    const t = computeTimeTracking(sessions, 2, Date.parse("2026-07-04T12:00:00.000Z"));
    expect(t.isClocked).toBe(false);
    expect(t.completedMs).toBe(90 * MIN);
    expect(t.liveMs).toBe(90 * MIN);
    expect(t.timerStr).toBe("1h 30m");
    expect(t.trackedHours).toBeCloseTo(1.5, 5);
    expect(t.overUnder).toBeCloseTo(-0.5, 5);
    expect(t.sessionCount).toBe(1);
  });

  test("clocked in: live time is added and the readout is H:MM:SS", () => {
    const active = { start: "2026-07-04T10:30:00.000Z", end: null };
    const sessions = [
      { start: "2026-07-04T08:00:00.000Z", end: "2026-07-04T09:00:00.000Z" }, // 1h
      active,
    ];
    const now = Date.parse("2026-07-04T11:00:00.000Z"); // active running 30m
    const t = computeTimeTracking(sessions, 2, now);
    expect(t.isClocked).toBe(true);
    expect(t.activeSession).toBe(active);
    expect(t.completedMs).toBe(HOUR);
    expect(t.liveMs).toBe(HOUR + 30 * MIN);
    expect(t.timerStr).toBe("1:30:00");
    expect(t.sessionCount).toBe(2); // 1 ended + the active one
  });

  test("clocked in under an hour uses M:SS", () => {
    const active = { start: "2026-07-04T11:00:00.000Z", end: null };
    const now = Date.parse("2026-07-04T11:05:30.000Z"); // 5m30s
    const t = computeTimeTracking([active], 0, now);
    expect(t.timerStr).toBe("5:30");
    expect(t.sessionCount).toBe(1);
  });

  test("no estimate → overUnder is null", () => {
    const sessions = [{ start: "2026-07-04T09:00:00.000Z", end: "2026-07-04T10:00:00.000Z" }];
    expect(computeTimeTracking(sessions, 0, 0).overUnder).toBeNull();
  });
});

describe("TIME_TRACKING_STATUSES", () => {
  test("covers the on-site statuses only", () => {
    expect(TIME_TRACKING_STATUSES.has("approved")).toBe(true);
    expect(TIME_TRACKING_STATUSES.has("in_progress")).toBe(true);
    expect(TIME_TRACKING_STATUSES.has("invoiced")).toBe(true);
    expect(TIME_TRACKING_STATUSES.has("lead")).toBe(false);
    expect(TIME_TRACKING_STATUSES.has("estimate_sent")).toBe(false);
    expect(TIME_TRACKING_STATUSES.has("paid")).toBe(false);
  });
});

// ── applyClockIn / applyClockOut ─────────────────────────────────────────────
// Pure clock helpers extracted from JobDetailScreen's handleClockIn/
// handleClockOut (docs/widget-plan.md Phase 3-4) so the widget/Siri replay
// engine (utils/widgetActions.ts) can drive the same logic outside a screen.

describe("applyClockIn", () => {
  const job = (over = {}) => ({ id: "j1", status: "scheduled", timeSessions: [], ...over });

  test("appends a new open session", () => {
    const result = applyClockIn(job(), "2026-07-04T09:00:00.000Z");
    expect(result.timeSessions).toEqual([{ start: "2026-07-04T09:00:00.000Z", end: null }]);
  });

  test("advances scheduled -> in_progress via JOB_STATUSES.scheduled.next (never hardcoded)", () => {
    const result = applyClockIn(job({ status: "scheduled" }), "2026-07-04T09:00:00.000Z");
    expect(result.status).toBe("in_progress");
  });

  test("leaves status alone when the job isn't 'scheduled'", () => {
    const result = applyClockIn(job({ status: "approved" }), "2026-07-04T09:00:00.000Z");
    expect(result.status).toBe("approved");
  });

  test("returns null when a session is already running", () => {
    const running = job({ timeSessions: [{ start: "2026-07-04T08:00:00.000Z", end: null }] });
    expect(applyClockIn(running, "2026-07-04T09:00:00.000Z")).toBeNull();
  });

  test.each(["complete", "invoiced"])(
    "succeeds on '%s' — TIME_TRACKING_STATUSES renders the Clock In button for these, so the pure helper must not silently block it",
    (status) => {
      const result = applyClockIn(job({ status }), "2026-07-04T09:00:00.000Z");
      expect(result).not.toBeNull();
      expect(result.timeSessions).toEqual([{ start: "2026-07-04T09:00:00.000Z", end: null }]);
      expect(result.status).toBe(status); // unaffected — only "scheduled" advances
    }
  );

  test.each(["paid", "declined"])(
    "also succeeds on '%s' — applyClockIn has no status guard at all; done-job replay policy lives in utils/widgetActions.ts, not here",
    (status) => {
      expect(applyClockIn(job({ status }), "2026-07-04T09:00:00.000Z")).not.toBeNull();
    }
  );

  test("does not mutate the original job", () => {
    const original = job();
    const result = applyClockIn(original, "2026-07-04T09:00:00.000Z");
    expect(original.timeSessions).toEqual([]);
    expect(result).not.toBe(original);
  });
});

describe("applyClockOut", () => {
  const job = (over = {}) => ({ id: "j1", status: "in_progress", timeSessions: [], ...over });

  test("closes the running session with the given end time", () => {
    const running = job({ timeSessions: [{ start: "2026-07-04T09:00:00.000Z", end: null }] });
    const result = applyClockOut(running, "2026-07-04T10:00:00.000Z");
    expect(result.timeSessions).toEqual([
      { start: "2026-07-04T09:00:00.000Z", end: "2026-07-04T10:00:00.000Z" },
    ]);
  });

  test("clamps end to start when atIso is earlier (clock skew / out-of-order replay)", () => {
    const running = job({ timeSessions: [{ start: "2026-07-04T09:00:00.000Z", end: null }] });
    const result = applyClockOut(running, "2026-07-04T08:00:00.000Z");
    expect(result.timeSessions[0].end).toBe("2026-07-04T09:00:00.000Z");
  });

  test("returns null when nothing is running", () => {
    expect(applyClockOut(job({ timeSessions: [] }), "2026-07-04T10:00:00.000Z")).toBeNull();
    expect(
      applyClockOut(job({ timeSessions: [{ start: "a", end: "b" }] }), "2026-07-04T10:00:00.000Z")
    ).toBeNull();
  });

  test("leaves earlier ended sessions untouched", () => {
    const running = job({
      timeSessions: [
        { start: "2026-07-04T07:00:00.000Z", end: "2026-07-04T08:00:00.000Z" },
        { start: "2026-07-04T09:00:00.000Z", end: null },
      ],
    });
    const result = applyClockOut(running, "2026-07-04T10:00:00.000Z");
    expect(result.timeSessions[0]).toEqual({
      start: "2026-07-04T07:00:00.000Z",
      end: "2026-07-04T08:00:00.000Z",
    });
  });
});
