// utils/scheduleSmarts.ts
// Pure schedule-intelligence helpers behind AddJobScreen's smart pickers
// (2026-08-01 spec: docs/superpowers/specs/2026-08-01-smart-schedule-pickers-design.md).
// Times are "HH:MM" 24-hour strings; dates are "YYYY-MM-DD". All math is
// minutes-since-midnight in the device's local frame — no Date parsing of
// date strings, no UTC (FA-039).

import type { Job } from "../types/models";

/**
 * Job statuses whose schedules are history — never flagged as conflicts. A
 * job declined via the estimate-approval loop keeps its schedule fields, but
 * its slot is dead — warning against it would mislead.
 */
export const TERMINAL_STATUSES: ReadonlySet<Job["status"]> = new Set([
  "complete",
  "invoiced",
  "paid",
  "declined",
]);

export type ConflictQuery = {
  excludeJobId?: string;
  date: string;
  start: string;
  end?: string | null;
  laborHours: number;
  /**
   * Required gap between appointments (Settings.schedule.bufferMinutes via
   * resolveSchedule). Pads the CANDIDATE window symmetrically, so a gap
   * smaller than the buffer conflicts and a gap exactly equal to it is legal
   * (strict-touch semantics preserved). Absent/0 = pre-Phase-11 behavior.
   */
  bufferMinutes?: number;
};

export function toMinutes(time: string): number {
  const [h, m] = time.split(":").map(Number);
  return h * 60 + m;
}

function toTimeString(totalMinutes: number): string {
  const clamped = Math.min(totalMinutes, 23 * 60 + 59);
  const h = Math.floor(clamped / 60);
  const m = clamped % 60;
  return `${String(h).padStart(2, "0")}:${String(m).padStart(2, "0")}`;
}

/**
 * start + laborHours, rounded UP to the next 15-minute boundary (trades think
 * in quarter-hours; rounding down would understate the block), clamped to
 * 23:59 — the schedule has no multi-day window. Callers guard laborHours > 0.
 */
export function addLaborToStart(start: string, laborHours: number): string {
  const raw = toMinutes(start) + laborHours * 60;
  return toTimeString(Math.ceil(raw / 15) * 15);
}

/**
 * Picker-open default when Start is empty: 08:00 for any non-today date,
 * otherwise the next half-hour boundary from `now`, clamped to 23:30.
 */
export function defaultStartTime(scheduledDate: string, now: Date): string {
  const today = `${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, "0")}-${String(now.getDate()).padStart(2, "0")}`;
  if (scheduledDate && scheduledDate !== today) return "08:00";
  const next = Math.ceil((now.getHours() * 60 + now.getMinutes()) / 30) * 30;
  return toTimeString(Math.min(next, 23 * 60 + 30));
}

/** Picker-open default when End is empty but Start is set. */
export function defaultEndTime(start: string, laborHours: number): string {
  return addLaborToStart(start, laborHours > 0 ? laborHours : 1);
}

/** 2 → "2h", 2.5 → "2h 30m", 0.25 → "15m" (for the schedule hint row). */
export function formatLaborHint(laborHours: number): string {
  const totalMinutes = Math.round(laborHours * 60);
  const h = Math.floor(totalMinutes / 60);
  const m = totalMinutes % 60;
  if (h > 0 && m > 0) return `${h}h ${m}m`;
  if (h > 0) return `${h}h`;
  return `${m}m`;
}

/**
 * [startMinutes, endMinutes) window; a missing end blocks max(labor, 1h).
 * Exported for the calendar selectors (utils/calendar.ts) so the block-size
 * rule has exactly one home.
 */
export function blockWindow(
  start: string,
  end: string | null | undefined,
  laborHours: number
): [number, number] {
  const s = toMinutes(start);
  if (end) return [s, toMinutes(end)];
  return [s, Math.min(s + Math.max(laborHours, 1) * 60, 24 * 60)];
}

/**
 * Other jobs whose window overlaps the candidate window on the same date.
 * Strict overlap — windows that merely touch (9–11 vs 11–1) don't conflict.
 * Warning-only by design: callers must never block saving on this.
 */
export function findScheduleConflicts(jobs: Job[], query: ConflictQuery): Job[] {
  if (!query.date || !query.start) return [];
  const [rawStart, rawEnd] = blockWindow(query.start, query.end, query.laborHours);
  const buffer = query.bufferMinutes ?? 0;
  const qStart = Math.max(0, rawStart - buffer);
  const qEnd = Math.min(24 * 60, rawEnd + buffer);
  return jobs.filter((j) => {
    if (j.id === query.excludeJobId) return false;
    if (j.scheduledDate !== query.date) return false;
    if (!j.scheduledStartTime) return false;
    if (TERMINAL_STATUSES.has(j.status)) return false;
    const [s, e] = blockWindow(j.scheduledStartTime, j.scheduledEndTime, j.laborHours ?? 0);
    return qStart < e && s < qEnd;
  });
}

export type FreeGap = { start: string; minutes: number };

/**
 * Largest free gap inside [dayStart, dayEnd) on `date`, from the same busy
 * windows findScheduleConflicts uses (missing end → max(labor, 1h)). Returns
 * null when the date has no live scheduled job — an empty day is not an
 * "open slot" (the Today empty-schedule state owns that message) — or when
 * every minute is booked. Ties go to the earlier gap (strict >).
 */
export function largestFreeGap(
  jobs: Job[],
  date: string,
  dayStart = "08:00",
  dayEnd = "17:00"
): FreeGap | null {
  const dayJobs = jobs.filter(
    (j) =>
      j.scheduledDate === date &&
      !!j.scheduledStartTime &&
      !TERMINAL_STATUSES.has(j.status)
  );
  if (dayJobs.length === 0) return null;

  const startMin = toMinutes(dayStart);
  const endMin = toMinutes(dayEnd);

  const busy = dayJobs
    .map((j) => blockWindow(j.scheduledStartTime as string, j.scheduledEndTime, j.laborHours ?? 0))
    .map(([s, e]): [number, number] => [Math.max(s, startMin), Math.min(e, endMin)])
    .filter(([s, e]) => s < e)
    .sort((a, b) => a[0] - b[0]);

  const merged: [number, number][] = [];
  for (const [s, e] of busy) {
    const last = merged[merged.length - 1];
    if (last && s <= last[1]) last[1] = Math.max(last[1], e);
    else merged.push([s, e]);
  }

  let best: FreeGap | null = null;
  let cursor = startMin;
  for (const [s, e] of merged) {
    if (s - cursor > (best?.minutes ?? 0)) best = { start: toTimeString(cursor), minutes: s - cursor };
    cursor = Math.max(cursor, e);
  }
  if (endMin - cursor > (best?.minutes ?? 0)) best = { start: toTimeString(cursor), minutes: endMin - cursor };
  return best;
}
