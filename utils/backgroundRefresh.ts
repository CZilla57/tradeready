// utils/backgroundRefresh.ts
// Periodic background wake so the widget/Siri surfaces stay fresh without an
// app open (docs/widget-plan.md Tier 2 / .superpowers/sdd/plan-widgets-tier2.md
// Task 1). iOS/Android wake the app a few times a day (the OS treats the
// interval below as a MINIMUM, not a guarantee — it batches/throttles wakes
// for battery); each wake pulls sync so remote changes (webhook-paid
// invoices, a second device's edits, date rollover) reach this device, then
// drains any queued widget/Siri pending actions and re-mirrors the widget
// snapshot via replayWidgetActions' own unconditional refresh.
//
// expo-background-task/expo-task-manager need a native module that first
// ships in the EAS build built with this wave's plugin config — every export
// here is a guarded no-op in Expo Go and any older/current binary, so this
// file is inert-but-safe to ship over OTA ahead of that build (same pattern
// as utils/widgetBridge.ts).
//
// Sign-out does NOT unregister this task: runBackgroundRefresh no-ops the
// moment supabase.auth.getSession() reports no user, and clearAllUserData
// (utils/storage/lifecycle.ts) already wipes the App Group container on
// sign-out. Unregistering/re-registering on every sign-in/out would just be
// churn against the OS's scheduler for no behavioral difference.

import * as TaskManager from "expo-task-manager";
import * as BackgroundTask from "expo-background-task";
import { supabase } from "./supabase";
import { syncIfOnline } from "./sync";
import { replayWidgetActions } from "./widgetActions";

export const BACKGROUND_REFRESH_TASK = "tradeready-background-refresh";

/**
 * The testable core, independent of TaskManager's executor signature. Never
 * throws.
 *
 * syncIfOnline is wrapped in its own try/catch (separate from the rest of the
 * function) so a sync failure — offline, a Supabase outage, whatever —
 * still lets the widget/Siri queue drain and the snapshot refresh below:
 * that part of the work doesn't depend on the network call succeeding, and
 * skipping it just because sync failed would silently delay Siri/widget
 * actions the user already made. (syncIfOnline itself already catches its
 * own errors and never rejects in practice — this guard covers the
 * documented contract even if that ever changes.)
 *
 * replayWidgetActions gets the same treatment even though it already never
 * throws by its own contract (utils/widgetActions.ts) — this function's own
 * "never throws" guarantee shouldn't depend on staying in sync with that
 * file forever.
 */
export async function runBackgroundRefresh(): Promise<void> {
  let userId: string | undefined;
  try {
    const {
      data: { session },
    } = await supabase.auth.getSession();
    userId = session?.user?.id;
  } catch {
    return;
  }
  if (!userId) return;

  try {
    await syncIfOnline(userId);
  } catch {
    // Best-effort — see the doc comment above for why replay still runs.
  }

  try {
    await replayWidgetActions();
  } catch {
    // Belt-and-suspenders — see the doc comment above.
  }
}

// Must run at module scope, not inside a component/effect — the OS can spin
// up JS just to run this task with no views mounted, and defineTask has to
// have already been called by then (expo-task-manager requirement).
TaskManager.defineTask(BACKGROUND_REFRESH_TASK, async () => {
  try {
    await runBackgroundRefresh();
    return BackgroundTask.BackgroundTaskResult.Success;
  } catch {
    return BackgroundTask.BackgroundTaskResult.Failed;
  }
});

/**
 * Registers the periodic wake with the OS. Safe to call on every
 * session-start: the installed package's own registerTaskAsync
 * (node_modules/expo-background-task/build/BackgroundTask.js) already checks
 * TaskManager.isTaskRegisteredAsync internally and returns early rather than
 * double-registering, so no extra idempotency guard is needed on this side.
 *
 * Wrapped so unsupported platforms/Expo Go/pre-this-wave binaries never
 * throw: TaskManager.isAvailableAsync() short-circuits the common case
 * (Expo Go, web), and the try/catch also swallows registerTaskAsync's
 * UnavailabilityError for any environment that reports available but still
 * lacks the native module.
 */
export async function registerBackgroundRefresh(): Promise<void> {
  try {
    const available = await TaskManager.isAvailableAsync();
    if (!available) return;
    await BackgroundTask.registerTaskAsync(BACKGROUND_REFRESH_TASK, {
      minimumInterval: 30, // minutes — the API's unit (BackgroundTask.types.d.ts)
    });
  } catch {
    // Never throw — this runs from AuthContext's session effect.
  }
}
