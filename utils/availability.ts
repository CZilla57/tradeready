// utils/availability.ts
// The deterministic candidate-slot engine (Phase 11 B1, 2026-08-07 spec §5).
// Pure: no I/O, no clock reads — `now` is injected; results depend only on
// inputs. Owner-naive frame throughout (FA-039): dates are "YYYY-MM-DD"
// strings compared as strings, time math is minutes-since-midnight. UTC does
// not exist here — the public boundary (Workers backend) resolves offered
// slots to instants with the owner's IANA zone.
//
// ⚠️ PARITY: backend-workers/lib/booking/availability.js is the CommonJS
// twin of this module (the server recomputes availability at offer and
// reserve time). Any behavior change here MUST land there too —
// __tests__/availabilityParity.test.ts pins the two together.
//
// Slot shape: starts on a fixed 30-minute grid, runs defaultDurationMinutes.
// Consecutive grid starts deliberately produce OVERLAPPING candidates
// (9:00 and 9:30 for a 60-min service) — that is safe because reservation is
// server-authoritative: the reserve handler recomputes availability with the
// just-taken slot as busy, so overlapping offers can never both be booked.

import type { DateString, Job, TimeString } from "../types/models";
import type { ResolvedSchedule } from "./scheduleConfig";
import { isBlackoutDate, isWorkDay } from "./scheduleConfig";
import { TERMINAL_STATUSES, blockWindow, toMinutes } from "./scheduleSmarts";

/** A reserved/held window the engine must treat as busy (server passes
 *  active reservations here; the client normally omits it). */
export interface BusyWindow {
  date: DateString;
  start: TimeString;
  end: TimeString;
}

export interface CandidateSlot {
  date: DateString;
  start: TimeString;
  end: TimeString;
}

export interface AvailabilityInput {
  schedule: ResolvedSchedule;
  jobs: Job[];
  extraBusy?: BusyWindow[];
  /** First day considered (inclusive). */
  fromDate: DateString;
  /** Horizon length in days (schedule.slotWindowDays at the call sites). */
  days: number;
  /** Injected clock, owner-naive: local date + minutes since midnight. */
  now: { date: DateString; minutes: number };
}

/** Slot starts snap to this grid (fixed for v1 — owner decision D8). */
export const SLOT_GRID_MINUTES = 30;

const DAY_MINUTES = 24 * 60;

/**
 * Calendar-day index of a naive date. Uses Date.UTC on the COMPONENTS purely
 * as day arithmetic — no local-frame Date is ever constructed from a string
 * (FA-039), and UTC epoch-days are immune to DST-length days.
 */
function epochDays(date: DateString): number {
  const [y, m, d] = date.split("-").map(Number);
  return Date.UTC(y, m - 1, d) / 86400000;
}

function shiftNaiveDate(date: DateString, days: number): DateString {
  const [y, m, d] = date.split("-").map(Number);
  const shifted = new Date(Date.UTC(y, m - 1, d + days));
  const yy = shifted.getUTCFullYear();
  const mm = String(shifted.getUTCMonth() + 1).padStart(2, "0");
  const dd = String(shifted.getUTCDate()).padStart(2, "0");
  return `${yy}-${mm}-${dd}`;
}

function minutesToTime(minutes: number): TimeString {
  const h = Math.floor(minutes / 60);
  const m = minutes % 60;
  return `${String(h).padStart(2, "0")}:${String(m).padStart(2, "0")}`;
}

/** Busy [start, end) windows for one day: live jobs + extra windows, each
 *  padded by the buffer, merged into disjoint sorted intervals. */
function busyWindowsFor(
  date: DateString,
  jobs: Job[],
  extraBusy: BusyWindow[],
  bufferMinutes: number
): [number, number][] {
  const raw: [number, number][] = [];

  for (const j of jobs) {
    if (j.scheduledDate !== date) continue;
    if (!j.scheduledStartTime) continue;
    if (TERMINAL_STATUSES.has(j.status)) continue;
    raw.push(blockWindow(j.scheduledStartTime, j.scheduledEndTime, j.laborHours ?? 0));
  }
  for (const b of extraBusy) {
    if (b.date !== date) continue;
    raw.push([toMinutes(b.start), toMinutes(b.end)]);
  }

  const padded = raw
    .map(([s, e]): [number, number] => [
      Math.max(0, s - bufferMinutes),
      Math.min(DAY_MINUTES, e + bufferMinutes),
    ])
    .filter(([s, e]) => s < e)
    .sort((a, b) => a[0] - b[0]);

  const merged: [number, number][] = [];
  for (const [s, e] of padded) {
    const last = merged[merged.length - 1];
    if (last && s <= last[1]) last[1] = Math.max(last[1], e);
    else merged.push([s, e]);
  }
  return merged;
}

export function computeCandidateSlots(input: AvailabilityInput): CandidateSlot[] {
  const { schedule, jobs, extraBusy = [], fromDate, days, now } = input;
  const duration = schedule.defaultDurationMinutes;
  const workStart = toMinutes(schedule.workDayStart);
  const workEnd = toMinutes(schedule.workDayEnd);
  const earliestAbs =
    epochDays(now.date) * DAY_MINUTES + now.minutes + schedule.slotLeadHours * 60;

  const out: CandidateSlot[] = [];

  for (let i = 0; i < days; i++) {
    const date = shiftNaiveDate(fromDate, i);
    if (!isWorkDay(schedule, date)) continue;
    if (isBlackoutDate(schedule, date)) continue;

    const dayAbs = epochDays(date) * DAY_MINUTES;
    const busy = busyWindowsFor(date, jobs, extraBusy, schedule.bufferMinutes);

    // Free gaps clipped to the work window.
    const gaps: [number, number][] = [];
    let cursor = workStart;
    for (const [s, e] of busy) {
      if (s > cursor) gaps.push([cursor, Math.min(s, workEnd)]);
      cursor = Math.max(cursor, e);
      if (cursor >= workEnd) break;
    }
    if (cursor < workEnd) gaps.push([cursor, workEnd]);

    for (const [gapStart, gapEnd] of gaps) {
      let start = Math.ceil(gapStart / SLOT_GRID_MINUTES) * SLOT_GRID_MINUTES;
      for (; start + duration <= gapEnd; start += SLOT_GRID_MINUTES) {
        if (dayAbs + start < earliestAbs) continue;
        out.push({
          date,
          start: minutesToTime(start),
          end: minutesToTime(start + duration),
        });
      }
    }
  }

  // Construction order is already (date asc, start asc) — days iterate
  // forward and gaps/starts advance monotonically within a day.
  return out;
}
