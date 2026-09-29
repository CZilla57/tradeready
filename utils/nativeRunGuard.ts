// utils/nativeRunGuard.ts
// Pure logic for the Expo-side rollback safeguard (defect P12-012, S1;
// docs/native-phase-12-rollback-playbook.md section 5.3, requirement E-1).
//
// Background: if the SwiftUI build ran on this device after this (Expo) build,
// the Expo AsyncStorage holds a stale __syncQueue and stale collection copies.
// Pushing them would overwrite newer native-era rows. So, once per native run,
// at app start and before anything reads or writes a collection, the Expo build
// drops the queue, clears the copies and pulls (utils/nativeRunRuntime.ts does
// the I/O; this file only decides).
//
// Names chosen by the branch owner role (playbook: "the branch owner records
// the record key, the clear or hold choice, the marker path, the fingerprint"):
//
//   AsyncStorage record key ........ "__nativeRun"
//       JSON {run, state:"pending"|"seen", fingerprint?, warn?}
//       run = the LAST USABLE run detected (0 = directory-fallback sentinel, or
//       "no usable run yet" after an unusable-marker detection with no record).
//       fingerprint = present only after an unusable-marker detection.
//       warn = E-2 warning not yet dismissed. Device state: the Expo sign-out
//       keeps it (E-4).
//   Held settings key .............. "__nativeRunHeldSettings"
//       JSON list of {path:string[], removed?:true, value?:unknown}. Account
//       data: the Expo sign-out and the other-owner path remove it.
//   Marker path .................... <Library>/Application Support/
//       TradeReadyNative/native-run-marker.json, where <Library> is the parent
//       of FileSystem.documentDirectory's "Documents" folder (expo-file-system
//       has no Application Support constant).
//   Fingerprint .................... 32-bit FNV-1a, 8 hex digits, prefixed
//       "c:" (hash of the file text) or "u:" (hash of the word "unreadable",
//       when the file cannot be opened). The prefix keeps a file whose text is
//       literally "unreadable" from colliding with the unreadable state.
//   Choice: CLEAR (not hold) the pre-native copies (playbook recommendation).

import {
  SYNC_QUEUE_KEY,
  SYNC_LAST_SYNCED_KEY,
  SYNC_CURSOR_VERSION,
  SYNCED_COLLECTION_TABLES,
} from './storage/keys';

export const NATIVE_RUN_KEY = '__nativeRun';
export const NATIVE_RUN_HELD_SETTINGS_KEY = '__nativeRunHeldSettings';
/** Sentinel run recorded by the directory fallback. No marker can hold 0. */
export const NATIVE_RUN_DIRECTORY_SENTINEL = 0;
export const NATIVE_MARKER_DIR_NAME = 'TradeReadyNative';
export const NATIVE_MARKER_FILE_NAME = 'native-run-marker.json';

export interface NativeRunRecord {
  run: number;
  state: 'pending' | 'seen';
  fingerprint?: string;
  /** E-2 warning shown until dismissed. */
  warn?: boolean;
}

/** What R could observe about the marker file. */
export type MarkerRead =
  | { kind: 'missing' }
  | { kind: 'unreadable' }
  | { kind: 'content'; text: string };

export type MarkerState =
  | { state: 'missing' }
  | { state: 'usable'; run: number }
  | { state: 'unusable'; fingerprint: string };

/** 32-bit FNV-1a as 8 lowercase hex digits. */
export function fnv1a32(text: string): string {
  let h = 0x811c9dc5;
  for (let i = 0; i < text.length; i++) {
    h ^= text.charCodeAt(i);
    h = Math.imul(h, 0x01000193) >>> 0;
  }
  return h.toString(16).padStart(8, '0');
}

export function markerFingerprint(read: MarkerRead): string {
  if (read.kind === 'content') return `c:${fnv1a32(read.text)}`;
  return `u:${fnv1a32('unreadable')}`;
}

/**
 * The three marker states. Mirrors the tests NativeRunMarker.load() applies
 * (schemaVersion 1, run a whole number >= 1) but, unlike it, keeps "missing"
 * and "unusable" apart because they lead to opposite actions.
 */
export function classifyMarker(read: MarkerRead): MarkerState {
  if (read.kind === 'missing') return { state: 'missing' };
  if (read.kind === 'content') {
    try {
      const parsed = JSON.parse(read.text) as { run?: unknown; schemaVersion?: unknown } | null;
      if (
        parsed !== null &&
        typeof parsed === 'object' &&
        parsed.schemaVersion === 1 &&
        typeof parsed.run === 'number' &&
        Number.isSafeInteger(parsed.run) &&
        parsed.run >= 1
      ) {
        return { state: 'usable', run: parsed.run };
      }
    } catch {
      // fall through: unparseable is unusable
    }
  }
  return { state: 'unusable', fingerprint: markerFingerprint(read) };
}

export interface DetectionDecision {
  fire: boolean;
  /** The record to persist (in the same write as the reset) when fire is true. */
  next: NativeRunRecord | null;
}

/**
 * The four rules of the playbook, in order. Anything not matched is "no new
 * native run" and nothing changes (not even the fingerprint).
 */
export function decideNativeRun(
  marker: MarkerState,
  nativeDirectoryExists: boolean,
  record: NativeRunRecord | null,
): DetectionDecision {
  const none: DetectionDecision = { fire: false, next: null };
  if (marker.state === 'usable') {
    if (record && record.run === marker.run) return none;
    return { fire: true, next: { run: marker.run, state: 'pending', warn: true } };
  }
  if (marker.state === 'unusable') {
    if (record && record.fingerprint === marker.fingerprint) return none;
    // The last usable run is kept unchanged; with no record there is none (0).
    return {
      fire: true,
      next: {
        run: record ? record.run : NATIVE_RUN_DIRECTORY_SENTINEL,
        state: 'pending',
        fingerprint: marker.fingerprint,
        warn: true,
      },
    };
  }
  // Missing marker.
  if (!record && nativeDirectoryExists) {
    return { fire: true, next: { run: NATIVE_RUN_DIRECTORY_SENTINEL, state: 'pending', warn: true } };
  }
  // No record and no directory (device never ran native), or a record already
  // exists: a missing marker never fires.
  return none;
}

/** The single atomic multiSet a detection performs. Every value is tiny. */
export function buildDetectionWrite(next: NativeRunRecord): [string, string][] {
  const emptyCursor = JSON.stringify({ version: SYNC_CURSOR_VERSION, tables: {} });
  const pairs: [string, string][] = [
    [SYNC_QUEUE_KEY, '[]'],
    [SYNC_LAST_SYNCED_KEY, emptyCursor],
    // review_requests is deliberately NOT here: local-only, no pull restores it.
    ...SYNCED_COLLECTION_TABLES.map((t): [string, string] => [t, '[]']),
    ['customerNotes', '{}'],
    [NATIVE_RUN_HELD_SETTINGS_KEY, '[]'],
    [NATIVE_RUN_KEY, JSON.stringify(next)],
  ];
  return pairs;
}

export function parseRecord(raw: string | null): NativeRunRecord | null {
  if (!raw) return null;
  try {
    const p = JSON.parse(raw) as Partial<NativeRunRecord> | null;
    if (
      p && typeof p === 'object' &&
      typeof p.run === 'number' && Number.isFinite(p.run) &&
      (p.state === 'pending' || p.state === 'seen')
    ) {
      return {
        run: p.run,
        state: p.state,
        ...(typeof p.fingerprint === 'string' ? { fingerprint: p.fingerprint } : {}),
        ...(p.warn ? { warn: true } : {}),
      };
    }
  } catch {
    // corrupt record: treat as no record (fail-safe: the marker rules decide)
  }
  return null;
}

/**
 * Application Support/TradeReadyNative/ as a file URI, derived from the
 * documentDirectory (".../Data/Application/<id>/Documents/"). Returns null when
 * documentDirectory does not have that shape (not iOS): no native build can
 * have run there, so there is no signal.
 */
export function nativeSupportDirectoryUri(documentDirectory: string | null | undefined): string | null {
  if (!documentDirectory) return null;
  const trimmed = documentDirectory.replace(/\/+$/, '');
  if (!/\/Documents$/.test(trimmed)) return null;
  const library = trimmed.slice(0, -'Documents'.length);
  // "Application Support" contains a space: percent-encode it for a file URI.
  return `${library}Library/Application%20Support/${NATIVE_MARKER_DIR_NAME}/`;
}

export function nativeMarkerUri(documentDirectory: string | null | undefined): string | null {
  const dir = nativeSupportDirectoryUri(documentDirectory);
  return dir ? `${dir}${NATIVE_MARKER_FILE_NAME}` : null;
}

// ---- Held settings paths (E-1 "Settings are held") ------------------------

export interface HeldSettingEntry {
  path: string[];
  removed?: true;
  value?: unknown;
}

function isPlainObject(v: unknown): v is Record<string, unknown> {
  return v !== null && typeof v === 'object' && !Array.isArray(v);
}

/** Leaves of a settings object: nested objects recurse, lists/plain values are leaves. */
function leaves(obj: unknown, prefix: string[] = [], out: Map<string, HeldSettingEntry> = new Map()) {
  if (!isPlainObject(obj)) return out;
  for (const key of Object.keys(obj)) {
    const v = obj[key];
    if (v === undefined) continue;
    const path = [...prefix, key];
    if (isPlainObject(v) && Object.keys(v).length > 0) leaves(v, path, out);
    else out.set(JSON.stringify(path), { path, value: v });
  }
  return out;
}

function normalize<T>(v: T): T {
  return v === undefined ? v : (JSON.parse(JSON.stringify(v)) as T);
}

/**
 * Every leaf value that was added, changed or removed going from `stored` to
 * `next`. Called from saveSettings BEFORE its write (I2): afterwards the
 * stored settings would equal the new ones and the diff would be empty.
 */
export function diffSettingsLeaves(stored: unknown, next: unknown): HeldSettingEntry[] {
  const before = leaves(normalize(stored));
  const after = leaves(normalize(next));
  const out: HeldSettingEntry[] = [];
  for (const [key, entry] of after) {
    const prior = before.get(key);
    if (!prior || JSON.stringify(prior.value) !== JSON.stringify(entry.value)) out.push(entry);
  }
  for (const [key, entry] of before) {
    if (!after.has(key)) out.push({ path: entry.path, removed: true });
  }
  return out;
}

/** Adds newer entries over older ones; the same path is replaced, not duplicated. */
export function mergeHeldEntries(existing: HeldSettingEntry[], added: HeldSettingEntry[]): HeldSettingEntry[] {
  const byPath = new Map<string, HeldSettingEntry>();
  for (const e of existing) byPath.set(JSON.stringify(e.path), e);
  for (const e of added) {
    byPath.delete(JSON.stringify(e.path));
    byPath.set(JSON.stringify(e.path), e);
  }
  return [...byPath.values()];
}

export function parseHeldEntries(raw: string | null): HeldSettingEntry[] {
  if (!raw) return [];
  try {
    const p = JSON.parse(raw) as unknown;
    if (!Array.isArray(p)) return [];
    return p.filter(
      (e): e is HeldSettingEntry =>
        !!e && Array.isArray((e as HeldSettingEntry).path) && (e as HeldSettingEntry).path.length > 0 &&
        (e as HeldSettingEntry).path.every(k => typeof k === 'string'),
    );
  } catch {
    return [];
  }
}

/** Applies held leaf paths over the pulled settings. Removals first, then sets. */
export function applyHeldEntries<T extends object>(pulled: T, held: HeldSettingEntry[]): T {
  const result = normalize(pulled) as Record<string, unknown>;
  for (const e of held.filter(h => h.removed)) {
    let node: unknown = result;
    for (let i = 0; i < e.path.length - 1 && isPlainObject(node); i++) node = node[e.path[i]];
    if (isPlainObject(node)) delete node[e.path[e.path.length - 1]];
  }
  for (const e of held.filter(h => !h.removed)) {
    let node = result;
    for (let i = 0; i < e.path.length - 1; i++) {
      const k = e.path[i];
      if (!isPlainObject(node[k])) node[k] = {};
      node = node[k] as Record<string, unknown>;
    }
    node[e.path[e.path.length - 1]] = normalize(e.value);
  }
  return result as T;
}
