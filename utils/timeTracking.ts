// utils/timeTracking.ts
// Clock-in/out session math for a job, extracted from JobDetailScreen's
// TimeTrackingCard (roadmap #7) so the fiddly timer/rollup logic is unit-tested
// instead of recomputed inline every render tick. Pure: the caller passes the
// current time so the running total is deterministic in tests.

import type { JobStatus } from "../types/models";

export interface WorkSession {
  /** ISO timestamp when the worker clocked in. */
  start: string;
  /** ISO timestamp when they clocked out, or null/undefined while still running. */
  end?: string | null;
}

export interface TimeTracking {
  /** The still-running session (last one with no end), or null. */
  activeSession: WorkSession | null;
  isClocked: boolean;
  /** Total logged ms across all *ended* sessions. */
  completedMs: number;
  /** completedMs plus the running session's elapsed time when clocked in. */
  liveMs: number;
  /** Human timer readout — "H:MM:SS" while running, "Hh MMm"/"Mm"/"0m" when idle. */
  timerStr: string;
  trackedHours: number;
  /** trackedHours − estimatedHours, or null when there's no estimate. */
  overUnder: number | null;
  /** Ended sessions, plus 1 for the active one. */
  sessionCount: number;
}

/** Job statuses during which time tracking is offered. */
export const TIME_TRACKING_STATUSES: Set<JobStatus> = new Set([
  "approved", "scheduled", "in_progress", "complete", "invoiced",
]);

/** The last session counts as active only while it has no end time. */
export function getActiveSession(sessions: WorkSession[]): WorkSession | null {
  const last = sessions[sessions.length - 1];
  return last && !last.end ? last : null;
}

/** Coarse elapsed-duration label: "2h 30m" / "45m" / "just now". */
export function formatElapsed(ms: number): string {
  const totalMins = Math.floor(ms / 60000);
  const h = Math.floor(totalMins / 60);
  const m = totalMins % 60;
  if (h > 0) return `${h}h ${m}m`;
  if (m > 0) return `${m}m`;
  return "just now";
}

export function computeTimeTracking(
  sessions: WorkSession[],
  estimatedHours: number,
  now: number = Date.now(),
): TimeTracking {
  const activeSession = getActiveSession(sessions);
  const isClocked = !!activeSession;

  const completedMs = sessions.reduce(
    (sum, s) => (s.end ? sum + (new Date(s.end).getTime() - new Date(s.start).getTime()) : sum),
    0,
  );

  const liveMs = activeSession
    ? completedMs + (now - new Date(activeSession.start).getTime())
    : completedMs;

  const totalSecs = Math.floor(liveMs / 1000);
  const h = Math.floor(totalSecs / 3600);
  const m = Math.floor((totalSecs % 3600) / 60);
  const s = totalSecs % 60;

  const timerStr = isClocked
    ? h > 0
      ? `${h}:${String(m).padStart(2, "0")}:${String(s).padStart(2, "0")}`
      : `${m}:${String(s).padStart(2, "0")}`
    : h > 0
    ? `${h}h ${String(m).padStart(2, "0")}m`
    : liveMs > 0
    ? `${m}m`
    : "0m";

  const trackedHours = liveMs / 3600000;
  const overUnder = estimatedHours > 0 ? trackedHours - estimatedHours : null;
  const sessionCount = sessions.filter((s) => s.end).length + (isClocked ? 1 : 0);

  return { activeSession, isClocked, completedMs, liveMs, timerStr, trackedHours, overUnder, sessionCount };
}
