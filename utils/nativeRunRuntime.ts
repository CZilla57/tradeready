// utils/nativeRunRuntime.ts
// I/O half of the Expo-side rollback safeguard (P12-012; playbook section 5.3,
// E-1..E-4). Decisions live in utils/nativeRunGuard.ts. Names and the
// fingerprint are documented there.
//
//  - ensureNativeRunChecked(): once per JS process, at app start, before any
//    collection read/write, initialSync, launch migration, push-token save,
//    background refresh or widget/Siri replay. Reads only a file and
//    AsyncStorage, so it runs online or offline, signed in or out.
//  - isNativeRunPending(): the run is pending until a pull completes it. Holds
//    (widget/Siri replay, invoice creation) key off this.
//  - completeNativeRunAfterPull(): called by pullRemote after a pull that read
//    every table, the settings and the notes without error.
//
// E-3: this module never writes, moves or deletes the native store, journal,
// LegacyBackups/, the run marker or the native Keychain items. It only reads
// the marker (and stats the native directory).

import AsyncStorage from '@react-native-async-storage/async-storage';
import * as FileSystem from 'expo-file-system/legacy';
import { Platform } from 'react-native';
import { reportError } from './analytics';
import {
  NATIVE_RUN_KEY,
  NATIVE_RUN_HELD_SETTINGS_KEY,
  buildDetectionWrite,
  classifyMarker,
  decideNativeRun,
  nativeMarkerUri,
  nativeSupportDirectoryUri,
  parseHeldEntries,
  parseRecord,
  applyHeldEntries,
  type MarkerRead,
  type NativeRunRecord,
} from './nativeRunGuard';

export { NATIVE_RUN_KEY, NATIVE_RUN_HELD_SETTINGS_KEY };

let checkPromise: Promise<void> | null = null;
let writeFailed = false;
let completing: Promise<void> | null = null;
const listeners = new Set<() => void>();

function notify(): void {
  listeners.forEach(l => { try { l(); } catch { /* listener errors never matter */ } });
}

/** UI subscription (pending notice / E-2 warning). Returns the unsubscribe. */
export function subscribeNativeRun(listener: () => void): () => void {
  listeners.add(listener);
  return () => { listeners.delete(listener); };
}

async function readMarker(documentDirectory: string): Promise<{ read: MarkerRead; directoryExists: boolean }> {
  const markerUri = nativeMarkerUri(documentDirectory);
  const dirUri = nativeSupportDirectoryUri(documentDirectory);
  if (!markerUri || !dirUri) return { read: { kind: 'missing' }, directoryExists: false };

  let read: MarkerRead;
  try {
    // Legacy getInfoAsync resolves { exists:false } for a missing path and does
    // not check path permissions; a rejection is anomalous, so it counts as
    // "cannot open it" (unusable, fail-safe).
    const info = await FileSystem.getInfoAsync(markerUri);
    if (!info.exists) {
      read = { kind: 'missing' };
    } else if (info.isDirectory) {
      read = { kind: 'unreadable' };
    } else {
      try {
        read = { kind: 'content', text: await FileSystem.readAsStringAsync(markerUri) };
      } catch {
        read = { kind: 'unreadable' };
      }
    }
  } catch {
    read = { kind: 'unreadable' };
  }

  let directoryExists = false;
  if (read.kind === 'missing') {
    try {
      directoryExists = !!(await FileSystem.getInfoAsync(dirUri)).exists;
    } catch {
      // Fail-safe: cannot tell, assume the native directory exists (a
      // detection too many costs a pull; a miss lets a stale queue push).
      directoryExists = true;
    }
  }
  return { read, directoryExists };
}

async function readRecord(): Promise<NativeRunRecord | null> {
  try {
    return parseRecord(await AsyncStorage.getItem(NATIVE_RUN_KEY));
  } catch {
    return null;
  }
}

async function runCheck(): Promise<void> {
  try {
    // Only iOS can have a native run; elsewhere there is no signal.
    if (Platform.OS !== 'ios') return;
    const documentDirectory = FileSystem.documentDirectory;
    if (!documentDirectory) return;

    const { read, directoryExists } = await readMarker(documentDirectory);
    const record = await readRecord();
    const decision = decideNativeRun(classifyMarker(read), directoryExists, record);
    if (!decision.fire || !decision.next) return;

    const writes = buildDetectionWrite(decision.next);
    try {
      await AsyncStorage.multiSet(writes);
    } catch {
      try {
        await AsyncStorage.multiSet(writes);
      } catch (e) {
        // The reset did not land. The old record is still there, so the next
        // launch detects again; until then no stale queue may be pushed.
        writeFailed = true;
        reportError(e, { context: 'nativeRunGuard.write' });
      }
    }
  } catch (e) {
    reportError(e, { context: 'nativeRunGuard.check' });
  } finally {
    notify();
  }
}

/** Memoized, never rejects. Call it first thing at app start. */
export function ensureNativeRunChecked(): Promise<void> {
  if (!checkPromise) checkPromise = runCheck();
  return checkPromise;
}

/** True when the detection's reset write failed in this process (block pushes). */
export function isNativeRunWriteFailed(): boolean {
  return writeFailed;
}

export async function isNativeRunPending(): Promise<boolean> {
  await ensureNativeRunChecked();
  const record = await readRecord();
  return record?.state === 'pending';
}

/** Invoices wait for the pull (numbering needs the whole invoice list). */
export const isInvoiceCreationBlocked = isNativeRunPending;

export const INVOICE_BLOCKED_TITLE = 'Getting your latest data';
export const INVOICE_BLOCKED_MESSAGE =
  'Invoices can be created once your data has finished loading from the cloud. Connect to the internet and try again in a moment.';

export async function readHeldSettings() {
  try {
    return parseHeldEntries(await AsyncStorage.getItem(NATIVE_RUN_HELD_SETTINGS_KEY));
  } catch {
    return [];
  }
}

export async function getNativeRunNotice(): Promise<{ pending: boolean; warn: boolean }> {
  await ensureNativeRunChecked();
  const record = await readRecord();
  return { pending: record?.state === 'pending', warn: !!record?.warn };
}

export async function dismissNativeRunWarning(): Promise<void> {
  const record = await readRecord();
  if (!record || !record.warn) return;
  const { warn: _warn, ...rest } = record;
  try {
    await AsyncStorage.setItem(NATIVE_RUN_KEY, JSON.stringify(rest));
  } catch { /* leave the warning up */ }
  notify();
}

async function completeInner(): Promise<void> {
  const record = await readRecord();
  if (!record) return;
  if (record.state !== 'pending') {
    // Held paths found while the run is already seen are removed, never applied.
    try {
      if ((await readHeldSettings()).length) await AsyncStorage.removeItem(NATIVE_RUN_HELD_SETTINGS_KEY);
    } catch { /* harmless */ }
    return;
  }

  // Lazy requires: storage/settings and widgetActions import utils/sync,
  // which imports this module.
  /* eslint-disable @typescript-eslint/no-require-imports */
  const { loadSettings, saveSettings } = require('./storage/settings') as typeof import('./storage/settings');
  const { replayWidgetActions } = require('./widgetActions') as typeof import('./widgetActions');
  const { trySync } = require('./sync') as typeof import('./sync');
  /* eslint-enable @typescript-eslint/no-require-imports */

  // 1. Held leaf paths over the pulled settings, saved and queued (bypassing
  //    the hold). Goes through saveSettings even when nothing is held so its
  //    notification sweep re-arms the reminders that pending sweeps cancelled.
  const held = await readHeldSettings();
  const pulled = await loadSettings();
  await saveSettings(applyHeldEntries(pulled, held), { releaseHold: true });

  // 2. Record the run as seen, then remove the held paths. A crash between the
  //    two leaves held paths on a seen run, which the branch above removes.
  const { warn, ...base } = record;
  await AsyncStorage.setItem(NATIVE_RUN_KEY, JSON.stringify({ ...base, state: 'seen', ...(warn ? { warn } : {}) }));
  await AsyncStorage.removeItem(NATIVE_RUN_HELD_SETTINGS_KEY);
  notify();

  // 3. Replay the widget/Siri queue once, now that the jobs are back.
  await replayWidgetActions();
  trySync();
}

/** Called by pullRemote after a fully successful pull. Single-flight, never throws. */
export function completeNativeRunAfterPull(): Promise<void> {
  if (!completing) {
    completing = completeInner()
      .catch(e => { reportError(e, { context: 'nativeRunGuard.complete' }); })
      .finally(() => { completing = null; });
  }
  return completing;
}

/** Test seam: forget the per-process state. */
export function __resetNativeRunForTests(): void {
  checkPromise = null;
  writeFailed = false;
  completing = null;
  listeners.clear();
}
