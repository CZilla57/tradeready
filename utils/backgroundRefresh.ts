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
// CRITICAL — why the imports below are `require`d inside try/catch instead
// of plain `import * as X from "..."`: the first version of this file used
// static imports and shipped a whole-branch review that caught it before
// release. expo-task-manager's ExpoTaskManager.js and expo-background-task's
// ExpoBackgroundTaskModule.js each resolve their native module AT MODULE
// SCOPE via expo-modules-core's `requireNativeModule`, which — unlike
// `requireOptionalNativeModule` — THROWS when the native module isn't
// present, instead of returning null. Every current production build
// (builds 7/9/10) and Expo Go predate the EAS build that will ship these
// modules' native side, so a plain `import` of either package crashes the
// whole app at bundle-evaluation time (via App.tsx's side-effect import of
// this file, pulled in through AuthContext) — before any of this file's own
// "guarded no-op" logic ever gets a chance to run. Jest mocks both packages
// wholesale and Expo Go happens to bundle SOME native modules, which is why
// the test suite and manual Expo Go smoke both stayed green while this bug
// was live. The lazy `require`s below are the fix: they let this file load
// (and everything exported from it degrade to a safe no-op) on any binary
// that lacks the native side, exactly like utils/widgetBridge.ts already
// does for its own native module via requireOptionalNativeModule — same
// mirror-the-App.tsx-pattern used for `let Updates: any = null; try {
// Updates = require("expo-updates"); } catch {}` a few files over.
//
// On a build that DOES ship both native modules (build 11+), every branch
// below behaves identically to the plain-import version: both requires
// succeed, defineTask runs, and registerBackgroundRefresh/runBackgroundRefresh
// work exactly as documented.
//
// Sign-out does NOT unregister this task: runBackgroundRefresh no-ops the
// moment supabase.auth.getSession() reports no user, and clearAllUserData
// (utils/storage/lifecycle.ts) already wipes the App Group container on
// sign-out. Unregistering/re-registering on every sign-in/out would just be
// churn against the OS's scheduler for no behavioral difference.

import type * as TaskManagerModule from "expo-task-manager";
import type * as BackgroundTaskModule from "expo-background-task";
import { supabase } from "./supabase";
import { syncIfOnline } from "./sync";
import { replayWidgetActions } from "./widgetActions";

export const BACKGROUND_REFRESH_TASK = "tradeready-background-refresh";

let TaskManager: typeof TaskManagerModule | null = null;
try {
  // eslint-disable-next-line @typescript-eslint/no-require-imports -- lazy/guarded require: see the file header incident note above (expo-task-manager throws at module scope when its native module is absent)
  TaskManager = require("expo-task-manager");
} catch {
  // Native module absent (Expo Go, any binary built before this wave) — every
  // export below degrades to a no-op via the null checks that follow.
}

let BackgroundTask: typeof BackgroundTaskModule | null = null;
try {
  // eslint-disable-next-line @typescript-eslint/no-require-imports -- lazy/guarded require: see the file header incident note above (expo-background-task throws at module scope when its native module is absent)
  BackgroundTask = require("expo-background-task");
} catch {
  // Same guard as above.
}

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
// have already been called by then (expo-task-manager requirement). Only
// registered when BOTH packages actually loaded — a binary with, say,
// expo-task-manager's native module but not expo-background-task's (or vice
// versa) has no coherent way to run this task anyway, and defineTask itself
// would have nothing meaningful to hand back from BackgroundTaskResult.
if (TaskManager && BackgroundTask) {
  const taskManager = TaskManager;
  const backgroundTask = BackgroundTask;
  taskManager.defineTask(BACKGROUND_REFRESH_TASK, async () => {
    try {
      await runBackgroundRefresh();
      return backgroundTask.BackgroundTaskResult.Success;
    } catch {
      return backgroundTask.BackgroundTaskResult.Failed;
    }
  });
}

/**
 * Registers the periodic wake with the OS. Safe to call on every
 * session-start: the installed package's own registerTaskAsync
 * (node_modules/expo-background-task/build/BackgroundTask.js) already checks
 * TaskManager.isTaskRegisteredAsync internally and returns early rather than
 * double-registering, so no extra idempotency guard is needed on this side.
 *
 * Wrapped so unsupported platforms/Expo Go/pre-this-wave binaries never
 * throw: the null check below covers a binary missing either native module
 * outright (see the top-of-file requires), TaskManager.isAvailableAsync()
 * short-circuits the common "loaded but not actually usable" case (Expo Go,
 * web), and the try/catch also swallows registerTaskAsync's
 * UnavailabilityError for any environment that reports available but still
 * lacks the native module.
 */
export async function registerBackgroundRefresh(): Promise<void> {
  if (!TaskManager || !BackgroundTask) return;
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
