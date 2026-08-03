// utils/timeTracking.ts
// Clock-in/out session math for a job, extracted from JobDetailScreen's
// TimeTrackingCard (roadmap #7) so the fiddly timer/rollup logic is unit-tested
// instead of recomputed inline every render tick. Pure: the caller passes the
// current time so the running total is deterministic in tests.

import { JOB_STATUSES } from "./pricingEngine";
import type { Job, JobStatus } from "../types/models";

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

/**
 * Pure clock-in: appends a new open session and, for a job still sitting at
 * "scheduled", advances status via the JOB_STATUSES `.next` chain (never a
 * hardcoded "in_progress" — see utils/pricingEngine.ts). Returns null only
 * when a session is already running. Deliberately has NO status guard:
 * TIME_TRACKING_STATUSES (above) already governs which statuses JobDetail's
 * TimeTrackingCard renders the Clock In button for — including "complete"
 * and "invoiced" — so a second, stricter guard here would silently break
 * that in-app control. Done-status filtering for the widget/Siri replay
 * path lives in utils/widgetActions.ts instead, which is a policy decision
 * for THAT caller, not a rule of clocking in itself.
 */
export function applyClockIn(job: Job, atIso: string): Job | null {
  if (getActiveSession(job.timeSessions || [])) return null;

  const timeSessions = [...(job.timeSessions || []), { start: atIso, end: null }];
  const next: Job = { ...job, timeSessions };
  if (job.status === "scheduled") {
    const advanced = JOB_STATUSES.scheduled.next;
    if (advanced) next.status = advanced;
  }
  return next;
}

/**
 * Pure clock-out: closes the last open session with `end = atIso`, clamping
 * to `start` if the given timestamp is somehow earlier (clock skew, replayed
 * widget/Siri action arriving out of order). Returns null when nothing is
 * running.
 */
export function applyClockOut(job: Job, atIso: string): Job | null {
  const active = getActiveSession(job.timeSessions || []);
  if (!active) return null;

  const end = atIso < active.start ? active.start : atIso;
  const timeSessions = (job.timeSessions || []).map((s, i, arr) =>
    i === arr.length - 1 && !s.end ? { ...s, end } : s
  );
  return { ...job, timeSessions };
}
