// utils/widgetActions.ts
// Replay engine for the widget/Siri pending-action queue (docs/widget-plan.md
// Phase 3-4). Home-screen widget buttons and Siri App Intents run in separate
// processes — they cannot touch AsyncStorage, the sync queue, or trip/job
// save paths directly. Instead they append a PendingAction to the App Group
// container (utils/widgetBridge.ts WIDGET_ACTIONS_KEY, native side in
// modules/widget-bridge/ios/WidgetBridgeModule.swift). This module is the
// JS-side consumer: read the batch, replay it through the app's NORMAL save
// paths (loadJobs/saveJobs, loadTrips/saveTrips) so sync/notifications/widget-
// mirror side effects fire exactly as if the user had tapped the buttons
// in-app, then clear the container so the batch never replays twice.
//
// The queue is native-written input the app doesn't fully control — parse it
// the same way utils/deepLinks.ts treats deep links: strict, and anything
// that fails a guard is silently dropped rather than thrown.

import { applyClockIn, applyClockOut, getActiveSession } from "./timeTracking";
import {
  getWidgetSharedItem,
  removeWidgetSharedItem,
  refreshWidgetSnapshot,
  WIDGET_ACTIONS_KEY,
  DONE_STATUSES,
} from "./widgetBridge";
import { loadJobs, saveJobs, loadTrips, saveTrips } from "./storage";
import { HOME_LABEL } from "./mileageUtils";
import type { Job, Trip } from "../types/models";

export type PendingActionType = "timer_start" | "timer_stop" | "trip_log";

/** One entry in the widgetActions queue — see docs/widget-plan.md Phase 3-4 contract. */
export interface PendingAction {
  id: string;
  type: PendingActionType;
  /** ISO 8601 timestamp the action happened. */
  at: string;
  /** timer_start always carries one; timer_stop carries one when the widget/Siri side knows it. */
  jobId?: string;
  /** Local "YYYY-MM-DD" — trip_log only. */
  date?: string;
  odometerStart?: number;
  odometerEnd?: number;
}

/**
 * Parse+validate the raw JSON string from the shared container. Malformed
 * JSON, a non-array payload, or entries missing id/type/at are dropped.
 * Deliberately does NOT narrow `type` against the known enum here — an
 * unrecognized type just falls through every branch downstream as a no-op,
 * same effect as dropping it, with one fewer place that has to agree on the
 * enum.
 */
export function parsePendingActions(raw: string | null): PendingAction[] {
  if (!raw) return [];
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    return [];
  }
  if (!Array.isArray(parsed)) return [];
  return parsed.filter((entry): entry is PendingAction => {
    if (!entry || typeof entry !== "object") return false;
    const e = entry as Record<string, unknown>;
    return typeof e.id === "string" && typeof e.type === "string" && typeof e.at === "string";
  });
}

/**
 * Apply timer_start/timer_stop pending actions against the jobs collection.
 * Pure — the caller saves the result. timer_start looks its job up by jobId;
 * a missing/deleted job silently drops the action, and so does a job whose
 * status is in DONE_STATUSES (utils/widgetBridge.ts) — Siri/widget must not
 * clock into a job that's already complete/invoiced/paid/declined. This is a
 * REPLAY-LAYER policy, not a rule of clocking in itself: applyClockIn has no
 * status guard of its own, since the in-app TimeTrackingCard button still
 * needs to work on "complete"/"invoiced" jobs (TIME_TRACKING_STATUSES).
 * timer_stop uses the action's jobId when present, else falls back to
 * whichever single job has a running session (Siri's "stop my timer"
 * doesn't always know which job — see selectActiveTimer in
 * utils/widgetBridge.ts for the same "one running session" assumption).
 * Guard failures inside applyClockIn/applyClockOut (already clocked in,
 * nothing running) drop silently too, per the shared contract.
 */
export function applyTimerActions(
  jobs: Job[],
  actions: PendingAction[],
): { jobs: Job[]; changed: boolean } {
  let current = jobs;
  let changed = false;

  for (const action of actions) {
    if (action.type === "timer_start") {
      if (!action.jobId) continue;
      const idx = current.findIndex((j) => j.id === action.jobId);
      if (idx === -1) continue;
      if (DONE_STATUSES.has(current[idx].status)) continue;
      const updated = applyClockIn(current[idx], action.at);
      if (!updated) continue;
      current = current.map((j, i) => (i === idx ? updated : j));
      changed = true;
    } else if (action.type === "timer_stop") {
      const idx = action.jobId
        ? current.findIndex((j) => j.id === action.jobId)
        : current.findIndex((j) => getActiveSession(j.timeSessions || []));
      if (idx === -1) continue;
      const updated = applyClockOut(current[idx], action.at);
      if (!updated) continue;
      current = current.map((j, i) => (i === idx ? updated : j));
      changed = true;
    }
  }

  return { jobs: current, changed };
}

/**
 * Build a Trip from a trip_log pending action. Pure. Returns null when:
 *   - a trip with this action's id already exists (dedupe — a replay must
 *     never double-log the same drive);
 *   - the action has no local date (trip_log always carries one per the
 *     contract; a malformed entry without it can't be dated safely);
 *   - either odometer reading isn't a finite number >= 0.
 * Labels/endpoints match AddTripScreen's "no linked job" convention (HOME_LABEL,
 * fromJobId/toJobId: null) — Siri trips never link to a job.
 */
export function tripFromAction(action: PendingAction, existingTrips: Trip[]): Trip | null {
  const id = `t_siri_${action.id}`;
  if (existingTrips.some((t) => t.id === id)) return null;
  if (!action.date) return null;

  const { odometerStart, odometerEnd } = action;
  if (
    typeof odometerStart !== "number" ||
    !Number.isFinite(odometerStart) ||
    odometerStart < 0 ||
    typeof odometerEnd !== "number" ||
    !Number.isFinite(odometerEnd) ||
    odometerEnd < 0
  ) {
    return null;
  }

  return {
    id,
    date: action.date,
    odometerStart,
    odometerEnd,
    miles: Math.max(0, odometerEnd - odometerStart),
    fromJobId: null,
    fromLabel: HOME_LABEL,
    toJobId: null,
    toLabel: HOME_LABEL,
    purpose: "Business trip (Siri)",
    createdAt: action.date,
  };
}

/**
 * Read+clear the widgetActions queue, replay it through the app's normal
 * save paths, and re-mirror the widget snapshot. Never throws — a broken
 * replay must not block app startup or the foreground resync that calls it.
 *
 * refreshWidgetSnapshot() runs UNCONDITIONALLY, even when there's no queue to
 * replay — this is what AuthContext now calls in place of its old bare
 * refreshWidgetSnapshot() at session-start and post-foreground-sync, so an
 * empty queue (the overwhelmingly common case) must not skip the mirror: a
 * fresh install's widget would otherwise stay on stale/seed data until the
 * first local edit, and remote changes pulled by sync — raw writes that
 * bypass the save-path mirror hooks — would never reach the widget either.
 * refreshWidgetSnapshot is itself a guarded no-op when the native bridge is
 * absent, so this costs nothing in Expo Go/Android/pre-widget builds.
 *
 * The queue is removed right after reading, BEFORE any of the batch is
 * applied — so a mid-replay crash loses at most this one batch rather than
 * replaying it forever on every future launch. Actions appended after this
 * read (a widget tap that lands mid-replay) survive untouched for the next
 * replay. Accepted v1 tradeoff (docs/widget-plan.md Phase 3-4).
 */
export async function replayWidgetActions(): Promise<void> {
  try {
    const raw = await getWidgetSharedItem(WIDGET_ACTIONS_KEY);
    if (raw) {
      await removeWidgetSharedItem(WIDGET_ACTIONS_KEY);

      const actions = parsePendingActions(raw);

      const jobs = await loadJobs();
      const { jobs: nextJobs, changed: jobsChanged } = applyTimerActions(jobs, actions);
      if (jobsChanged) await saveJobs(nextJobs);

      const trips = await loadTrips();
      let nextTrips = trips;
      let tripsChanged = false;
      for (const action of actions) {
        if (action.type !== "trip_log") continue;
        const trip = tripFromAction(action, nextTrips);
        if (!trip) continue;
        nextTrips = [...nextTrips, trip];
        tripsChanged = true;
      }
      if (tripsChanged) await saveTrips(nextTrips);
    }

    await refreshWidgetSnapshot();
  } catch {
    // Best-effort: a broken replay must not break app startup/foreground resync.
  }
}
