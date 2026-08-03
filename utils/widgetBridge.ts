// utils/widgetBridge.ts
// JS half of the App Group widget bridge (docs/widget-plan.md, Phase 1).
// Mirrors a MINIMAL snapshot of widget-facing data — next job, running job
// timer, outstanding total — for the WidgetBridge native module to write into
// the shared App Group container, where WidgetKit extensions and Siri App
// Intents (which run in separate processes and cannot read AsyncStorage) pick
// it up.
//
// The native module does not exist yet: it requires owner-approved native
// scaffolding and a fresh EAS build. requireOptionalNativeModule returns null
// in Expo Go, on Android, and in every binary until that lands, and each entry
// point below no-ops in that case — so this file is inert-but-safe to ship
// over OTA ahead of the build.
//
// PII discipline: the App Group container is a plaintext plist — the same
// at-rest protection as AsyncStorage, but a SECOND copy of user data. Mirror
// only what the widget/Siri surfaces actually display (one job's
// name/time/address, the running timer, one total). Never whole collections,
// never phone/email. Sign-out MUST wipe the container — clearAllUserData
// (utils/storage/lifecycle.ts) calls clearWidgetSnapshot; leaving user A's
// next job visible in a widget after user B signs in is the same
// cross-user-leak class as the review_requests wipe gaps (2026-08-02).

import AsyncStorage from "@react-native-async-storage/async-storage";
import { requireOptionalNativeModule } from "expo-modules-core";
import { KEYS } from "./storage/keys";
import { getActiveSession } from "./timeTracking";
import { summarizeInvoices } from "./invoiceStats";
import { roundToCents } from "./invoicePayments";
import { getTodayDateString } from "./dateHelpers";
import type { Invoice, Job, JobStatus } from "../types/models";

export interface WidgetNextJob {
  id: string;
  customerName: string;
  title: string;
  /** Local "YYYY-MM-DD". */
  scheduledDate: string;
  /** "HH:MM" or null when the job has a date but no start time. */
  scheduledStartTime: string | null;
  address: string;
}

export interface WidgetTimer {
  jobId: string;
  jobTitle: string;
  customerName: string;
  /** ISO timestamp of the running session's clock-in. */
  startedAt: string;
}

export interface WidgetSnapshot {
  version: 1;
  /** ISO timestamp of this mirror write (staleness display on the widget). */
  updatedAt: string;
  nextJob: WidgetNextJob | null;
  timer: WidgetTimer | null;
  /** Sum of unpaid invoice balances, dollars (summarizeInvoices semantics). */
  outstandingTotal: number;
}

/** UserDefaults key inside the shared App Group container. */
export const WIDGET_SNAPSHOT_KEY = "widgetSnapshot";

/**
 * UserDefaults key for the pending-action queue (docs/widget-plan.md Phase 3):
 * widget buttons and Siri intents append PendingAction entries here; the app
 * reads-then-clears the batch on launch/foreground (utils/widgetActions.ts).
 */
export const WIDGET_ACTIONS_KEY = "widgetActions";

/**
 * UserDefaults key holding a deep link a Siri intent wants the app to open on
 * its next start (docs/widget-plan.md Phase 4). The on-my-way intent posts the
 * link straight into RN's linking stack for the warm case, but on a cold launch
 * that notification fires before App.tsx subscribes — so the intent also stashes
 * it here and App.tsx drains it once navigation is ready. Payload is
 * `{ url, at }` with an ISO timestamp; see parsePendingOpenUrl in
 * utils/deepLinks.ts for the freshness rule that stops a stale stash from
 * hijacking an unrelated launch.
 */
export const PENDING_OPEN_URL_KEY = "pendingOpenUrl";

// Statuses whose work is finished (or never happening) — their schedule slot
// is history, not the answer to "when is my next job?". Exported so
// utils/widgetActions.ts can reuse the identical set to drop timer_start
// replay actions targeting a done job, without a third copy of this list.
export const DONE_STATUSES: Set<JobStatus> = new Set(["complete", "invoiced", "paid", "declined"]);

/**
 * The next upcoming scheduled job: earliest scheduledDate >= today, ties
 * broken by start time (no-time jobs sort last, matching loadJobsForDate).
 * Today's jobs stay "next" even after their start time passes — mid-afternoon
 * the current job IS the answer. Any live status with a schedule qualifies
 * (new jobs created with a date keep status "lead", so filtering to
 * "scheduled" would miss them); archived and done-status jobs never qualify.
 * Dates compare as local "YYYY-MM-DD" strings — never parsed (FA-039).
 */
export function selectNextJob(jobs: Job[], now: number = Date.now()): WidgetNextJob | null {
  const today = getTodayDateString(new Date(now));
  const candidates = jobs.filter(
    (j): j is Job & { scheduledDate: string } =>
      !j.archivedAt &&
      j.scheduledDate !== null &&
      j.scheduledDate >= today &&
      !DONE_STATUSES.has(j.status),
  );
  candidates.sort((a, b) => {
    if (a.scheduledDate !== b.scheduledDate) return a.scheduledDate < b.scheduledDate ? -1 : 1;
    if (!a.scheduledStartTime) return 1;
    if (!b.scheduledStartTime) return -1;
    return a.scheduledStartTime.localeCompare(b.scheduledStartTime);
  });
  const job = candidates[0];
  if (!job) return null;
  return {
    id: job.id,
    customerName: job.customerName,
    title: job.title,
    scheduledDate: job.scheduledDate,
    scheduledStartTime: job.scheduledStartTime,
    address: job.address,
  };
}

/**
 * The running clock-in session, if any. Multiple open sessions shouldn't
 * happen (JobDetail closes one before opening another), but if data ever
 * disagrees, the most recent clock-in wins.
 */
export function selectActiveTimer(jobs: Job[]): WidgetTimer | null {
  let best: WidgetTimer | null = null;
  for (const job of jobs) {
    const active = getActiveSession(job.timeSessions || []);
    if (!active) continue;
    if (!best || active.start > best.startedAt) {
      best = {
        jobId: job.id,
        jobTitle: job.title,
        customerName: job.customerName,
        startedAt: active.start,
      };
    }
  }
  return best;
}

export function buildWidgetSnapshot(
  jobs: Job[],
  invoices: Invoice[],
  now: number = Date.now(),
): WidgetSnapshot {
  return {
    version: 1,
    updatedAt: new Date(now).toISOString(),
    nextJob: selectNextJob(jobs, now),
    timer: selectActiveTimer(jobs),
    outstandingTotal: roundToCents(summarizeInvoices(invoices).outstanding),
  };
}

// --- Native bridge (absent until the Phase-1 native leg ships) ---

interface WidgetBridgeNativeModule {
  /** Writes json under key in the App Group UserDefaults, then reloads widget timelines. */
  setSharedItem(key: string, json: string): Promise<void>;
  /** Removes every bridge-owned key from the App Group UserDefaults. */
  clearShared(): Promise<void>;
  /** Reads a single key from the App Group UserDefaults, or null if unset. */
  getSharedItem(key: string): Promise<string | null>;
  /** Removes a single key from the App Group UserDefaults. */
  removeSharedItem(key: string): Promise<void>;
}

function getBridge(): WidgetBridgeNativeModule | null {
  try {
    return requireOptionalNativeModule<WidgetBridgeNativeModule>("WidgetBridge");
  } catch {
    return null;
  }
}

/**
 * Rebuild the snapshot from local storage and mirror it to the App Group
 * container. Fire-and-forget from save paths — best-effort, never throws.
 */
export async function refreshWidgetSnapshot(): Promise<void> {
  const bridge = getBridge();
  if (!bridge) return;
  try {
    // Raw reads on purpose: loadJobs/loadInvoices fall back to sample seed
    // data on a cold cache, and sample records must never surface in a
    // widget — an empty cache mirrors as an empty snapshot instead. Raw
    // reads also avoid a collections → widgetBridge → collections cycle.
    const [jobsRaw, invoicesRaw] = await Promise.all([
      AsyncStorage.getItem(KEYS.jobs),
      AsyncStorage.getItem(KEYS.invoices),
    ]);
    const jobs: Job[] = jobsRaw ? JSON.parse(jobsRaw) : [];
    const invoices: Invoice[] = invoicesRaw ? JSON.parse(invoicesRaw) : [];
    await bridge.setSharedItem(WIDGET_SNAPSHOT_KEY, JSON.stringify(buildWidgetSnapshot(jobs, invoices)));
  } catch {
    // Mirroring is best-effort; never let it break a save path.
  }
}

/** Wipe the App Group container. Part of clearAllUserData — see header. */
export async function clearWidgetSnapshot(): Promise<void> {
  const bridge = getBridge();
  if (!bridge) return;
  try {
    await bridge.clearShared();
  } catch {
    // Best-effort: a failed wipe must not block sign-out.
  }
}

/**
 * Read one key from the shared App Group container (e.g. WIDGET_ACTIONS_KEY).
 * Null when the module is absent, the key was never written, or the read
 * fails — callers (utils/widgetActions.ts) treat null/empty the same as
 * "nothing pending".
 */
export async function getWidgetSharedItem(key: string): Promise<string | null> {
  const bridge = getBridge();
  if (!bridge) return null;
  try {
    return await bridge.getSharedItem(key);
  } catch {
    return null;
  }
}

/**
 * Remove one key from the shared App Group container. Best-effort and silent
 * — a failed clear must not block the replay that called it.
 */
export async function removeWidgetSharedItem(key: string): Promise<void> {
  const bridge = getBridge();
  if (!bridge) return;
  try {
    await bridge.removeSharedItem(key);
  } catch {
    // Best-effort: same discipline as clearWidgetSnapshot above.
  }
}
