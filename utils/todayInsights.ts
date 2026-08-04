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
import { isFullyPaid, balanceDue } from "./invoicePayments";
import { daysPastDue } from "./invoiceHelpers";
import { formatMoney, formatQuote } from "./format";
import { formatLocalDate } from "./recurrence";
import { shiftDate } from "./dateHelpers";

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
  title: string;
  detail?: string;
  target: InsightTarget;
  /** labor_overrun only: prefills the AI coach input (never auto-sent). */
  coachPrompt?: string;
};

/** Quarter-hour floor — sub-15-minute overruns are noise to a trade. */
const OVERRUN_MIN_HOURS = 0.25;
/** Fixed work window for the open-slot rule (no setting in v1, per spec). */
export const WORK_DAY_START = "08:00";
export const WORK_DAY_END = "17:00";
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
      title: `'${job.title}' is ${formatElapsed(t.overUnder * 3600000)} over its ${formatLaborHint(job.laborHours)} labor estimate`,
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
      title: `'${job.title}' is complete but not invoiced`,
      detail: job.estimateTotal > 0 ? `${formatQuote(job.estimateTotal)} to bill` : undefined,
      target: { type: "createInvoice", jobId: job.id },
    }];
  }
  return [{
    kind: "uninvoiced_complete",
    title: `${done.length} completed jobs haven't been invoiced`,
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
      title: `Invoice ${inv.number} (${formatMoney(balanceDue(inv))}) is due ${dueLabel(days)}`,
      target: { type: "invoice", invoiceId: inv.id },
    }];
  }
  const total = soon.reduce((s, { inv }) => s + balanceDue(inv), 0);
  return [{
    kind: "due_soon",
    title: `${formatMoney(total)} across ${soon.length} invoices is due within ${DUE_SOON_DAYS} days`,
    target: { type: "invoices" },
  }];
}

function selectScheduleInsights(jobs: Job[], now: Date): TodayInsight[] {
  const out: TodayInsight[] = [];
  const tomorrow = shiftDate(formatLocalDate(now), 1); // local-frame (FA-039)

  const unscheduled = jobs.filter(
    (j) => j.status === "approved" && !j.scheduledDate && !isArchived(j)
  );

  let fittedJobId: string | null = null;
  const gap = largestFreeGap(jobs, tomorrow, WORK_DAY_START, WORK_DAY_END);
  if (gap && gap.minutes >= MIN_GAP_MINUTES) {
    const gapLabel = formatLaborHint(gap.minutes / 60);
    // Best fill: the largest approved unscheduled job that still fits.
    const fit = unscheduled
      .filter((j) => j.laborHours > 0 && j.laborHours * 60 <= gap.minutes)
      .sort((a, b) => b.laborHours - a.laborHours)[0];
    if (fit) {
      fittedJobId = fit.id;
      out.push({
        kind: "open_slot",
        title: `Tomorrow has a ${gapLabel} open slot — '${fit.title}' (${formatLaborHint(fit.laborHours)}) would fit`,
        target: { type: "schedule", jobId: fit.id },
      });
    } else {
      out.push({
        kind: "open_slot",
        title: `Tomorrow has a ${gapLabel} open slot`,
        target: { type: "selectDate", date: tomorrow },
      });
    }
  }

  const remaining = unscheduled.filter((j) => j.id !== fittedJobId);
  if (remaining.length === 1) {
    out.push({
      kind: "unscheduled_approved",
      title: `'${remaining[0].title}' is approved but not scheduled`,
      target: { type: "schedule", jobId: remaining[0].id },
    });
  } else if (remaining.length > 1) {
    out.push({
      kind: "unscheduled_approved",
      title: `${remaining.length} approved jobs aren't on the schedule yet`,
      target: { type: "jobs" },
    });
  }
  return out;
}

export function selectTodayInsights(jobs: Job[], invoices: Invoice[], now: Date): TodayInsight[] {
  const safeJobs = jobs || [];
  const safeInvoices = invoices || [];
  return [
    ...selectLaborOverruns(safeJobs, now),
    ...selectUninvoicedComplete(safeJobs),
    ...selectDueSoon(safeInvoices, now),
    ...selectScheduleInsights(safeJobs, now),
  ];
}
