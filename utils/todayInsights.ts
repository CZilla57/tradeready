// utils/todayInsights.ts
// Deterministic "proactive insights" rules for the Today screen (2026-08-04
// spec: docs/superpowers/specs/2026-08-04-today-insights-design.md). Pure —
// no I/O, no Expo/RN imports, injected clock — mirroring estimateFollowUps.ts.
// The card (components/InsightsCard.tsx) renders the first 3 of whatever this
// returns, so PRIORITY IS THE ORDER THE RULES RUN in selectTodayInsights.

import type { Job, Invoice } from "../types/models";
import { computeTimeTracking, formatElapsed } from "./timeTracking";
import { formatLaborHint, largestFreeGap } from "./scheduleSmarts";
import { isArchived } from "./archive";
import { selectUnscheduledApproved } from "./calendar";
import {
  isBlackoutDate,
  isWorkDay,
  SCHEDULE_DEFAULTS,
  type ResolvedSchedule,
} from "./scheduleConfig";
import { isFullyPaid, balanceDue } from "./invoicePayments";
import { daysPastDue } from "./invoiceHelpers";
import { formatMoney, formatQuote } from "./format";
import { formatLocalDate } from "./recurrence";
import { shiftDate } from "./dateHelpers";
import { jobBillableTotal } from "./changeOrders";

export type InsightKind =
  | "labor_overrun"
  | "uninvoiced_complete"
  | "due_soon"
  | "open_slot"
  | "unscheduled_approved";

export type InsightTarget =
  | { type: "job"; jobId: string }
  | { type: "createInvoice"; jobId: string }
  | { type: "invoice"; invoiceId: string }
  | { type: "invoices" }
  | { type: "jobs" }
  | { type: "schedule"; jobId: string }
  | { type: "selectDate"; date: string };

export type TodayInsight = {
  kind: InsightKind;
  /** Stable dedup identity (Phase 15): what dismissals/snoozes and analytics
   * hang on. Deterministic per kind — `kind:recordId`, `kind:all` for
   * aggregate rows, `kind:date`/`kind:period` for time-scoped rows. */
  id: string;
  title: string;
  detail?: string;
  target: InsightTarget;
  /** Deterministic "why am I seeing this" — every number computed in code. */
  reason: string;
  /** Prefills the AI coach input (never auto-sent). */
  coachPrompt?: string;
};

/** Quarter-hour floor — sub-15-minute overruns are noise to a trade. */
const OVERRUN_MIN_HOURS = 0.25;
// The open-slot work window comes from Settings.schedule via resolveSchedule
// since Phase 11 A5 (absent schedule = the old fixed 08:00–17:00; the
// original "no setting in v1" spec note is superseded by the 2026-08-07
// calendar spec). Non-workday and blacked-out tomorrows are silent.
/** How many days ahead (inclusive) "due soon" looks; day +1 belongs to the
 * Overdue section (due-today is NOT overdue — existing semantics). */
const DUE_SOON_DAYS = 2;
/** Minimum free gap worth surfacing, in minutes. */
const MIN_GAP_MINUTES = 120;

/**
 * Statuses where "running over the labor estimate" is a live, present-tense
 * problem. A clock-in on `approved` does not auto-advance (applyClockIn only
 * advances from `scheduled`), so `approved` can carry sessions too.
 * Completed/invoiced jobs are excluded — after completion the money
 * conversation belongs to invoicing, not the timer.
 */
const OVERRUN_STATUSES: ReadonlySet<Job["status"]> = new Set([
  "approved",
  "scheduled",
  "in_progress",
]);

function selectLaborOverruns(jobs: Job[], now: Date): TodayInsight[] {
  const out: TodayInsight[] = [];
  for (const job of jobs) {
    if (!OVERRUN_STATUSES.has(job.status) || isArchived(job)) continue;
    if (!(job.laborHours > 0) || !job.timeSessions?.length) continue;
    const t = computeTimeTracking(job.timeSessions, job.laborHours, now.getTime());
    if (t.overUnder === null || t.overUnder < OVERRUN_MIN_HOURS) continue;
    out.push({
      kind: "labor_overrun",
      id: `labor_overrun:${job.id}`,
      title: `'${job.title}' is ${formatElapsed(t.overUnder * 3600000)} over its ${formatLaborHint(job.laborHours)} labor estimate`,
      reason:
        `You've logged ${formatElapsed(t.liveMs)} on '${job.title}' against a ` +
        `${formatLaborHint(job.laborHours)} labor estimate — at least 15 minutes over. ` +
        `This clears on its own when the job is completed or the estimate is updated.`,
      target: { type: "job", jobId: job.id },
      coachPrompt:
        `I'm working on '${job.title}' and I've logged ${formatElapsed(t.liveMs)} ` +
        `against a ${formatLaborHint(job.laborHours)} labor estimate at ` +
        `${formatMoney(job.laborRate)}/hr (estimate total ${formatQuote(job.estimateTotal)}). ` +
        `How should I handle the overrun — talk to the customer now, absorb it, or adjust the bill?`,
    });
  }
  return out;
}

function selectUninvoicedComplete(jobs: Job[]): TodayInsight[] {
  const done = jobs.filter((j) => j.status === "complete" && !j.invoiceId && !isArchived(j));
  if (done.length === 0) return [];
  if (done.length === 1) {
    const job = done[0];
    return [{
      kind: "uninvoiced_complete",
      id: `uninvoiced_complete:${job.id}`,
      title: `'${job.title}' is complete but not invoiced`,
      detail: jobBillableTotal(job) > 0 ? `${formatQuote(jobBillableTotal(job))} to bill` : undefined,
      reason: `'${job.title}' is marked complete but has no invoice yet. This clears once an invoice is created.`,
      target: { type: "createInvoice", jobId: job.id },
    }];
  }
  return [{
    kind: "uninvoiced_complete",
    id: "uninvoiced_complete:all",
    title: `${done.length} completed jobs haven't been invoiced`,
    reason: `${done.length} jobs are marked complete but have no invoice yet. This clears as invoices are created.`,
    target: { type: "jobs" },
  }];
}

function dueLabel(days: number): string {
  if (days === 0) return "today";
  if (days === -1) return "tomorrow";
  return `in ${-days} days`;
}

function selectDueSoon(invoices: Invoice[], now: Date): TodayInsight[] {
  const soon = invoices
    .map((inv) => ({ inv, days: daysPastDue(inv.due, now) }))
    .filter(({ inv, days }) => !isFullyPaid(inv) && days <= 0 && days >= -DUE_SOON_DAYS);
  if (soon.length === 0) return [];
  if (soon.length === 1) {
    const { inv, days } = soon[0];
    return [{
      kind: "due_soon",
      id: `due_soon:${inv.id}`,
      title: `Invoice ${inv.number} (${formatMoney(balanceDue(inv))}) is due ${dueLabel(days)}`,
      reason:
        `Invoice ${inv.number} still has a balance and is due ${dueLabel(days)} ` +
        `(within the ${DUE_SOON_DAYS}-day heads-up window). Once past due it moves to the Overdue section.`,
      target: { type: "invoice", invoiceId: inv.id },
    }];
  }
  const total = soon.reduce((s, { inv }) => s + balanceDue(inv), 0);
  return [{
    kind: "due_soon",
    id: "due_soon:all",
    title: `${formatMoney(total)} across ${soon.length} invoices is due within ${DUE_SOON_DAYS} days`,
    reason:
      `${soon.length} invoices still carry a balance and fall due within ${DUE_SOON_DAYS} days. ` +
      `Once past due they move to the Overdue section.`,
    target: { type: "invoices" },
  }];
}

function selectScheduleInsights(
  jobs: Job[],
  now: Date,
  schedule: ResolvedSchedule
): TodayInsight[] {
  const out: TodayInsight[] = [];
  const tomorrow = shiftDate(formatLocalDate(now), 1); // local-frame (FA-039)

  const unscheduled = selectUnscheduledApproved(jobs);

  let fittedJobId: string | null = null;
  const tomorrowIsOpen = isWorkDay(schedule, tomorrow) && !isBlackoutDate(schedule, tomorrow);
  const gap = tomorrowIsOpen
    ? largestFreeGap(jobs, tomorrow, schedule.workDayStart, schedule.workDayEnd)
    : null;
  if (gap && gap.minutes >= MIN_GAP_MINUTES) {
    const gapLabel = formatLaborHint(gap.minutes / 60);
    // Best fill: the largest approved unscheduled job that still fits.
    const fit = unscheduled
      .filter((j) => j.laborHours > 0 && j.laborHours * 60 <= gap.minutes)
      .sort((a, b) => b.laborHours - a.laborHours)[0];
    const gapReason =
      `Tomorrow (${tomorrow}) has ${gapLabel} free between your working hours ` +
      `${schedule.workDayStart}–${schedule.workDayEnd} — at least 2 hours.`;
    if (fit) {
      fittedJobId = fit.id;
      out.push({
        kind: "open_slot",
        id: `open_slot:${tomorrow}`,
        title: `Tomorrow has a ${gapLabel} open slot — '${fit.title}' (${formatLaborHint(fit.laborHours)}) would fit`,
        reason:
          `${gapReason} '${fit.title}' is approved, unscheduled, and its ` +
          `${formatLaborHint(fit.laborHours)} labor estimate fits the gap.`,
        target: { type: "schedule", jobId: fit.id },
      });
    } else {
      out.push({
        kind: "open_slot",
        id: `open_slot:${tomorrow}`,
        title: `Tomorrow has a ${gapLabel} open slot`,
        reason: gapReason,
        target: { type: "selectDate", date: tomorrow },
      });
    }
  }

  const remaining = unscheduled.filter((j) => j.id !== fittedJobId);
  if (remaining.length === 1) {
    out.push({
      kind: "unscheduled_approved",
      id: `unscheduled_approved:${remaining[0].id}`,
      title: `'${remaining[0].title}' is approved but not scheduled`,
      reason: `'${remaining[0].title}' is approved but has no date on the schedule. This clears once it's scheduled.`,
      target: { type: "schedule", jobId: remaining[0].id },
    });
  } else if (remaining.length > 1) {
    out.push({
      kind: "unscheduled_approved",
      id: "unscheduled_approved:all",
      title: `${remaining.length} approved jobs aren't on the schedule yet`,
      reason: `${remaining.length} approved jobs have no date on the schedule. This clears as they're scheduled.`,
      target: { type: "jobs" },
    });
  }
  return out;
}

export function selectTodayInsights(
  jobs: Job[],
  invoices: Invoice[],
  now: Date,
  schedule: ResolvedSchedule = SCHEDULE_DEFAULTS
): TodayInsight[] {
  const safeJobs = jobs || [];
  const safeInvoices = invoices || [];
  return [
    ...selectLaborOverruns(safeJobs, now),
    ...selectUninvoicedComplete(safeJobs),
    ...selectDueSoon(safeInvoices, now),
    ...selectScheduleInsights(safeJobs, now, schedule),
  ];
}
