// utils/calendar.ts
// Pure day/week selectors behind CalendarScreen (Phase 11 A3, 2026-08-07
// spec). Same local-frame discipline as scheduleSmarts: dates compare as raw
// "YYYY-MM-DD" strings, time math is minutes-since-midnight (FA-039). The
// block-size rule (missing end → max(labor, 1h)) is scheduleSmarts.blockWindow
// so the calendar can never disagree with conflict detection.

import type { DateString, Job } from "../types/models";
import type { ResolvedSchedule } from "./scheduleConfig";
import {
  TERMINAL_STATUSES,
  blockWindow,
  findScheduleConflicts,
  toMinutes,
} from "./scheduleSmarts";
import { getWeekDates } from "./dateHelpers";
import { isArchived } from "./archive";

export interface CalendarBlock {
  job: Job;
  startMinutes: number;
  endMinutes: number;
  /** Column within the overlap cluster (0-based) … */
  lane: number;
  /** … out of this many side-by-side columns. 1 = full width. */
  laneCount: number;
  /** Terminal-status jobs render (history matters) but never conflict. */
  isTerminal: boolean;
  /** Live-vs-live overlap, buffer-aware (same semantics as AddJobScreen). */
  inConflict: boolean;
}

export interface CalendarDay {
  date: DateString;
  /** Blocks sorted by start, lane-assigned for side-by-side rendering. */
  timed: CalendarBlock[];
  /** Jobs scheduled for the date with no start time ("" or null). */
  untimed: Job[];
}

/** Greedy interval lane assignment; laneCount is per overlap cluster. */
function assignLanes(
  blocks: { startMinutes: number; endMinutes: number }[]
): { lane: number; laneCount: number }[] {
  const out = blocks.map(() => ({ lane: 0, laneCount: 1 }));
  const laneEnds: number[] = [];
  let clusterStart = 0;
  let clusterMaxEnd = -1;

  const closeCluster = (endIndex: number) => {
    for (let i = clusterStart; i < endIndex; i++) out[i].laneCount = laneEnds.length;
  };

  blocks.forEach((b, i) => {
    if (laneEnds.length > 0 && b.startMinutes >= clusterMaxEnd) {
      closeCluster(i);
      laneEnds.length = 0;
      clusterStart = i;
    }
    let lane = laneEnds.findIndex((end) => end <= b.startMinutes);
    if (lane === -1) {
      lane = laneEnds.length;
      laneEnds.push(b.endMinutes);
    } else {
      laneEnds[lane] = b.endMinutes;
    }
    out[i].lane = lane;
    clusterMaxEnd = Math.max(clusterMaxEnd, b.endMinutes);
  });
  closeCluster(blocks.length);
  return out;
}

export function buildCalendarDay(
  jobs: Job[],
  date: DateString,
  schedule: ResolvedSchedule
): CalendarDay {
  const dayJobs = jobs.filter((j) => j.scheduledDate === date);
  const untimed = dayJobs.filter((j) => !j.scheduledStartTime);

  const sized = dayJobs
    .filter((j) => !!j.scheduledStartTime)
    .map((j) => {
      const [startMinutes, endMinutes] = blockWindow(
        j.scheduledStartTime as string,
        j.scheduledEndTime,
        j.laborHours ?? 0
      );
      return { job: j, startMinutes, endMinutes };
    })
    .sort((a, b) => a.startMinutes - b.startMinutes || a.endMinutes - b.endMinutes);

  const lanes = assignLanes(sized);
  const timed = sized.map((b, i) => {
    const isTerminal = TERMINAL_STATUSES.has(b.job.status);
    const inConflict =
      !isTerminal &&
      findScheduleConflicts(dayJobs, {
        excludeJobId: b.job.id,
        date,
        start: b.job.scheduledStartTime as string,
        end: b.job.scheduledEndTime,
        laborHours: b.job.laborHours ?? 0,
        bufferMinutes: schedule.bufferMinutes,
      }).length > 0;
    return { ...b, ...lanes[i], isTerminal, inConflict };
  });

  return { date, timed, untimed };
}

/**
 * Hour-aligned axis range for a day view: the work window, stretched to
 * cover any out-of-hours block, never past midnight.
 */
export function dayAxis(
  day: CalendarDay,
  schedule: ResolvedSchedule
): { startMinutes: number; endMinutes: number } {
  let start = toMinutes(schedule.workDayStart);
  let end = toMinutes(schedule.workDayEnd);
  for (const b of day.timed) {
    start = Math.min(start, b.startMinutes);
    end = Math.max(end, b.endMinutes);
  }
  return {
    startMinutes: Math.floor(start / 60) * 60,
    endMinutes: Math.min(Math.ceil(end / 60) * 60, 24 * 60),
  };
}

/** The 7 Mon–Sun days containing `anchorDate` (getWeekDates order). */
export function buildCalendarWeek(
  jobs: Job[],
  anchorDate: DateString,
  schedule: ResolvedSchedule
): CalendarDay[] {
  return getWeekDates(anchorDate).map((d) => buildCalendarDay(jobs, d, schedule));
}

/**
 * The unscheduled approved-work queue: approved, no date ("" or null), not
 * archived — the same predicate as Today's unscheduled_approved insight —
 * oldest first so long-waiting work surfaces at the top.
 */
export function selectUnscheduledApproved(jobs: Job[]): Job[] {
  return jobs
    .filter((j) => j.status === "approved" && !j.scheduledDate && !isArchived(j))
    .sort((a, b) => (a.createdAt || "").localeCompare(b.createdAt || ""));
}

/** Minutes-since-midnight → "HH:MM" axis label (no clamp — 1440 is "24:00"). */
export function minutesToLabel(minutes: number): string {
  const h = Math.floor(minutes / 60);
  const m = minutes % 60;
  return `${String(h).padStart(2, "0")}:${String(m).padStart(2, "0")}`;
}
