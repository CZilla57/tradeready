// utils/insightMutes.ts
// Per-insight dismiss/snooze persistence for the Today insights card (Phase 15
// contextual-AI spec: docs/superpowers/specs/2026-08-07-contextual-ai-design.md).
// Only insights whose condition cannot self-resolve are muteable (the card's
// MUTEABLE_KINDS set decides which — the existing self-resolving kinds keep the
// v1 "no dismiss button" behavior). Mutes are DEVICE-LOCAL by design (not
// synced; solo-operator, D2) and persist under a feature-local AsyncStorage key
// that clearAllUserData MUST wipe (utils/storage/lifecycle.ts) — mute ids embed
// this account's record ids, and a stale mute leaking into the next account
// would silently hide its legitimate insights.
//
// Date semantics are local-frame throughout (FA-039): a snooze `until` is a
// local "YYYY-MM-DD" and the mute expires once today >= until.

import AsyncStorage from "@react-native-async-storage/async-storage";
import { formatLocalDate } from "./recurrence";
import { shiftDate } from "./dateHelpers";

export const INSIGHT_MUTES_STORAGE_KEY = "insightMutes";

export type InsightMute = {
  /** The insight's stable id (utils/todayInsights.ts assigns these). */
  id: string;
  /** ISO timestamp of when the mute was created (informational). */
  mutedAt: string;
  /** Local YYYY-MM-DD the snooze expires; absent = permanent dismiss. */
  until?: string;
};

/** Build a mute record: `days` set = snooze until today+days, absent = dismiss. */
export function makeMute(id: string, now: Date, days?: number): InsightMute {
  return {
    id,
    mutedAt: now.toISOString(),
    ...(days && days > 0 ? { until: shiftDate(formatLocalDate(now), days) } : {}),
  };
}

/** A permanent dismiss is always active; a snooze is active until its day arrives. */
export function isMuteActive(mute: InsightMute, today: string): boolean {
  return !mute.until || mute.until > today;
}

/** Drop muted insights, preserving order — run BEFORE the card's top-3 slice so
 * muting a row promotes the next one. */
export function filterMutedInsights<T extends { id: string }>(
  insights: T[],
  mutes: InsightMute[],
  now: Date
): T[] {
  if (mutes.length === 0) return insights;
  const today = formatLocalDate(now);
  const active = new Set(mutes.filter((m) => isMuteActive(m, today)).map((m) => m.id));
  return insights.filter((i) => !active.has(i.id));
}

/** Keep only mutes that are still active AND (when liveIds is known) still
 * correspond to an insight the engine can emit — bounds growth. */
export function pruneMutes(
  mutes: InsightMute[],
  today: string,
  liveIds?: Iterable<string>
): InsightMute[] {
  const live = liveIds ? new Set(liveIds) : null;
  return mutes.filter((m) => isMuteActive(m, today) && (!live || live.has(m.id)));
}

export async function loadInsightMutes(): Promise<InsightMute[]> {
  try {
    const raw = await AsyncStorage.getItem(INSIGHT_MUTES_STORAGE_KEY);
    const parsed = raw ? JSON.parse(raw) : [];
    return Array.isArray(parsed) ? parsed.filter((m) => m && typeof m.id === "string") : [];
  } catch {
    return [];
  }
}

/** Persist a mute. Prunes expired snoozes (and, when the caller passes the
 * currently-live insight ids, mutes for insights that no longer exist) in the
 * same write. Returns the stored record so callers can update state optimistically. */
export async function muteInsight(
  id: string,
  now: Date,
  opts?: { days?: number; liveIds?: Iterable<string> }
): Promise<InsightMute> {
  const mute = makeMute(id, now, opts?.days);
  const today = formatLocalDate(now);
  const current = await loadInsightMutes();
  const kept = pruneMutes(current, today, opts?.liveIds).filter((m) => m.id !== id);
  await AsyncStorage.setItem(INSIGHT_MUTES_STORAGE_KEY, JSON.stringify([...kept, mute]));
  return mute;
}
