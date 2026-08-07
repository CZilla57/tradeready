// utils/scheduleConfig.ts
// Phase 11 (calendar/availability): the single sanctioned reader of
// Settings.schedule. Every consumer — calendar UI, conflict math, Today
// insights, the availability engine — resolves the owner's scheduling config
// through resolveSchedule so an absent, partial, or garbled blob (settings
// sync whole-blob LWW; old devices; hand-edited cloud rows) always lands on
// safe defaults that reproduce the app's pre-Phase-11 behavior: fixed
// 08:00–17:00 window, Mon–Sat, no buffers, no blackouts, slots off.
//
// Validation is explicit (Number.isFinite + range checks), never truthiness:
// 0 is a legal bufferMinutes/slotLeadHours and must survive (FA-017).
import type { DateString, ScheduleBlackout, Settings, TimeString } from "../types/models";
import { parseLocalDate } from "./moneyUtils";

export interface ResolvedSchedule {
  /** IANA zone, or null until the owner enables slot booking. */
  timeZone: string | null;
  /** ISO weekdays 1–7 (Mon=1), deduped and sorted. */
  workDays: number[];
  workDayStart: TimeString;
  workDayEnd: TimeString;
  defaultDurationMinutes: number;
  bufferMinutes: number;
  slotLeadHours: number;
  slotWindowDays: number;
  blackouts: ScheduleBlackout[];
  bookableSlotsEnabled: boolean;
}

const TIME_RE = /^([01]\d|2[0-3]):[0-5]\d$/;
const DATE_RE = /^\d{4}-\d{2}-\d{2}$/;

export const SCHEDULE_DEFAULTS: ResolvedSchedule = {
  timeZone: null,
  // Mon–Sat: trades commonly work Saturdays (owner decision D5, Phase 11 spec).
  workDays: [1, 2, 3, 4, 5, 6],
  workDayStart: "08:00",
  workDayEnd: "17:00",
  defaultDurationMinutes: 60,
  bufferMinutes: 0,
  slotLeadHours: 24,
  slotWindowDays: 14,
  blackouts: [],
  bookableSlotsEnabled: false,
};

function resolveNumber(raw: unknown, fallback: number, min: number, allowMin: boolean): number {
  if (typeof raw !== "number" || !Number.isFinite(raw)) return fallback;
  if (allowMin ? raw < min : raw <= min) return fallback;
  return raw;
}

function resolveWorkDays(raw: unknown): number[] {
  if (!Array.isArray(raw)) return SCHEDULE_DEFAULTS.workDays;
  const days = [...new Set(raw.filter(
    (d): d is number => typeof d === "number" && Number.isInteger(d) && d >= 1 && d <= 7
  ))].sort((a, b) => a - b);
  return days.length > 0 ? days : SCHEDULE_DEFAULTS.workDays;
}

function resolveBlackouts(raw: unknown): ScheduleBlackout[] {
  if (!Array.isArray(raw)) return [];
  const out: ScheduleBlackout[] = [];
  for (const entry of raw) {
    if (typeof entry !== "object" || entry === null) continue;
    const b = entry as Record<string, unknown>;
    if (typeof b.id !== "string" || b.id === "") continue;
    if (typeof b.start !== "string" || !DATE_RE.test(b.start)) continue;
    if (typeof b.end !== "string" || !DATE_RE.test(b.end)) continue;
    if (b.end < b.start) continue;
    out.push({
      id: b.id,
      start: b.start,
      end: b.end,
      reason: typeof b.reason === "string" ? b.reason : undefined,
    });
  }
  return out;
}

export function resolveSchedule(settings: Settings): ResolvedSchedule {
  const raw = (settings?.schedule ?? {}) as Record<string, unknown>;

  // Work window: each end must be a valid "HH:MM" AND start must precede end,
  // else BOTH revert to defaults — a half-valid window is not a window.
  let workDayStart = typeof raw.workDayStart === "string" && TIME_RE.test(raw.workDayStart)
    ? raw.workDayStart
    : SCHEDULE_DEFAULTS.workDayStart;
  let workDayEnd = typeof raw.workDayEnd === "string" && TIME_RE.test(raw.workDayEnd)
    ? raw.workDayEnd
    : SCHEDULE_DEFAULTS.workDayEnd;
  if (workDayStart >= workDayEnd) {
    workDayStart = SCHEDULE_DEFAULTS.workDayStart;
    workDayEnd = SCHEDULE_DEFAULTS.workDayEnd;
  }

  return {
    timeZone: typeof raw.timeZone === "string" && raw.timeZone !== "" ? raw.timeZone : null,
    workDays: resolveWorkDays(raw.workDays),
    workDayStart,
    workDayEnd,
    defaultDurationMinutes: resolveNumber(raw.defaultDurationMinutes, SCHEDULE_DEFAULTS.defaultDurationMinutes, 0, false),
    bufferMinutes: resolveNumber(raw.bufferMinutes, SCHEDULE_DEFAULTS.bufferMinutes, 0, true),
    slotLeadHours: resolveNumber(raw.slotLeadHours, SCHEDULE_DEFAULTS.slotLeadHours, 0, true),
    slotWindowDays: resolveNumber(raw.slotWindowDays, SCHEDULE_DEFAULTS.slotWindowDays, 0, false),
    blackouts: resolveBlackouts(raw.blackouts),
    bookableSlotsEnabled: raw.bookableSlotsEnabled === true,
  };
}

/** Inclusive on both bounds; pure string comparison (local-frame dates, FA-039). */
export function isBlackoutDate(schedule: ResolvedSchedule, date: DateString): boolean {
  return schedule.blackouts.some((b) => b.start <= date && date <= b.end);
}

/** date is local "YYYY-MM-DD"; parseLocalDate keeps the weekday in the owner's frame. */
export function isWorkDay(schedule: ResolvedSchedule, date: DateString): boolean {
  const day = parseLocalDate(date).getDay(); // 0 = Sunday
  const isoDay = day === 0 ? 7 : day;
  return schedule.workDays.includes(isoDay);
}
