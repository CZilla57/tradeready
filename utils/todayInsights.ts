// utils/todayInsights.ts
// Deterministic "proactive insights" rules for the Today screen (2026-08-04
// spec: docs/superpowers/specs/2026-08-04-today-insights-design.md). Pure —
// no I/O, no Expo/RN imports, injected clock — mirroring estimateFollowUps.ts.
// The card (components/InsightsCard.tsx) renders the first 3 of whatever this
// returns, so PRIORITY IS THE ORDER THE RULES RUN in selectTodayInsights.

import type { Job, Invoice, Customer, RecurringJob, Expense, ExpenseCategoryId } from "../types/models";
import { EXPENSE_CATEGORIES } from "./moneyUtils";
import { computeTimeTracking, formatElapsed } from "./timeTracking";
import { computeEstimateBreakdown } from "./pricingEngine";
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
  | "low_margin_estimate"
  | "uninvoiced_complete"
  | "due_soon"
  | "open_slot"
  | "unscheduled_approved"
  | "maintenance_due"
  | "expense_anomaly";

export type InsightTarget =
  | { type: "job"; jobId: string }
  | { type: "createInvoice"; jobId: string }
  | { type: "invoice"; invoiceId: string }
  | { type: "invoices" }
  | { type: "jobs" }
  | { type: "schedule"; jobId: string }
  | { type: "selectDate"; date: string }
  | { type: "customer"; customerId: string }
  | { type: "customers" }
  | { type: "money" };

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

/** Fire when the implied margin is at least this many percentage points under
 * the Settings target — one point of drift is negotiation noise, three is a
 * pricing problem. */
const MARGIN_TOLERANCE_PTS = 3;

/**
 * Statuses where the price is still the owner's to change. After `approved`
 * the estimate is contracted — a low margin there is Phase 13's est-vs-actual
 * conversation, not a repricing prompt.
 */
const LOW_MARGIN_STATUSES: ReadonlySet<Job["status"]> = new Set([
  "lead",
  "estimate_sent",
]);

/**
 * low_margin_estimate: the price on a not-yet-approved job doesn't deliver the
 * Settings margin target. All inputs are the job's OWN stored fields — labor
 * hours × rate, marked-up materials (computeEstimateBreakdown), and the job's
 * own overhead % — so nothing is inferred. The implied margin uses the same
 * base calculateEstimate applies margin to (costs + overhead). Jobs without
 * real pricing inputs (CSV imports, quick-adds: laborHours/laborRate 0) are
 * excluded rather than guessed at. Travel isn't stored on Job, so when travel
 * existed costs are understated and this errs toward silence, never a false
 * alarm. One row — the worst offender — with the count of others in the
 * detail; its id embeds estimateTotal so a dismissal resets when the price
 * changes (a repriced job is a new question).
 */
function selectLowMarginEstimates(jobs: Job[], targetMarginPercent: number): TodayInsight[] {
  type Hit = {
    job: Job;
    impliedPct: number;
    profit: number;
    laborCost: number;
    materialCost: number;
    overheadAt: number;
  };
  const hits: Hit[] = [];
  for (const job of jobs) {
    if (!LOW_MARGIN_STATUSES.has(job.status) || isArchived(job)) continue;
    if (!(job.estimateTotal > 0) || !(job.laborHours > 0) || !(job.laborRate > 0)) continue;
    const { laborCost, materialCost } = computeEstimateBreakdown(job);
    const costBase = laborCost + materialCost;
    if (!(costBase > 0)) continue;
    const overheadAt = costBase * ((job.overhead || 0) / 100);
    const profit = job.estimateTotal - costBase - overheadAt;
    const impliedPct = (profit / (costBase + overheadAt)) * 100;
    if (impliedPct <= targetMarginPercent - MARGIN_TOLERANCE_PTS) {
      hits.push({ job, impliedPct, profit, laborCost, materialCost, overheadAt });
    }
  }
  if (hits.length === 0) return [];
  hits.sort((a, b) => a.impliedPct - b.impliedPct);
  const { job, impliedPct, profit, laborCost, materialCost, overheadAt } = hits[0];

  const severe = profit < 0;
  const pointsUnder = Math.round(targetMarginPercent - impliedPct);
  const others = hits.length - 1;
  const baseDetail = severe
    ? `${formatQuote(-profit)} short of break-even`
    : `${formatQuote(profit)} profit on ${formatQuote(job.estimateTotal)}`;
  return [{
    kind: "low_margin_estimate",
    id: `low_margin_estimate:${job.id}:${job.estimateTotal}`,
    title: severe
      ? `'${job.title}' is priced below your costs and overhead`
      : `'${job.title}' is priced ${pointsUnder} points under your ${targetMarginPercent}% margin`,
    detail: others > 0 ? `${baseDetail} · ${others} more under target` : baseDetail,
    reason:
      `Priced at ${formatQuote(job.estimateTotal)}: labor ${formatQuote(laborCost)} + ` +
      `materials ${formatQuote(materialCost)} + overhead at ${job.overhead || 0}% ` +
      `(${formatQuote(overheadAt)}) leaves ${formatQuote(profit)} — an implied margin of ${impliedPct.toFixed(1)}% ` +
      `vs your ${targetMarginPercent}% target. Dismissing hides this until the price changes.`,
    target: { type: "job", jobId: job.id },
    coachPrompt:
      `My estimate for '${job.title}' totals ${formatQuote(job.estimateTotal)}: labor ` +
      `${formatQuote(laborCost)}, materials ${formatQuote(materialCost)}, overhead ` +
      `${formatQuote(overheadAt)} at ${job.overhead || 0}%. That leaves ${formatQuote(profit)} profit — ` +
      `about ${impliedPct.toFixed(0)}% margin vs my ${targetMarginPercent}% target. ` +
      `Should I raise the price, trim costs, or take it as-is?`,
  }];
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

/** Fixed cadence for the maintenance-due rule — a constant, not a setting, per
 * the v1 spec (the work-day-constant precedent; a per-trade table or Settings
 * field is a later, separately-approved change). */
const MAINTENANCE_DUE_MONTHS = 6;

/** Statuses that count as delivered service history. */
const SERVICE_HISTORY_STATUSES: ReadonlySet<Job["status"]> = new Set([
  "complete",
  "invoiced",
  "paid",
]);

/** Statuses meaning "there's already work in motion for this customer". */
const ACTIVE_PIPELINE_STATUSES: ReadonlySet<Job["status"]> = new Set([
  "lead",
  "estimate_sent",
  "approved",
  "scheduled",
  "in_progress",
]);

/** Whole calendar months elapsed from a local YYYY-MM-DD to `now` — pure
 * component math, never Date-parsing the string (FA-039), so timezone/DST
 * can't shift the boundary. */
function monthsBetween(from: string, now: Date): number {
  const [y, m, d] = from.split("-").map(Number);
  let months = (now.getFullYear() - y) * 12 + (now.getMonth() + 1 - m);
  if (now.getDate() < d) months -= 1;
  return months;
}

/**
 * maintenance_due: customers whose last delivered job is MAINTENANCE_DUE_MONTHS+
 * months behind them, with nothing in motion. Strict exclusions instead of
 * guesses (Phase 15 spec §C): customers must be active with a real contact;
 * history joins on a real customerId (jobs with customerId "" never match,
 * and invoice-only customers have no job history — stated v1 limitation);
 * "last service" is the latest scheduledDate over complete/invoiced/paid jobs
 * (archived history still counts — archiving tidies lists, it does not
 * rewrite history); suppressed while ANY non-archived job is in the active
 * pipeline or an active recurring-job rule covers the customer.
 */
function selectMaintenanceDue(
  jobs: Job[],
  customers: Customer[],
  recurringJobs: RecurringJob[],
  now: Date
): TodayInsight[] {
  type Due = { customer: Customer; months: number; lastDate: string; lastTitle: string };
  const due: Due[] = [];
  for (const customer of customers) {
    if (!customer.id || isArchived(customer)) continue;
    if (!(customer.phone || "").trim() && !(customer.email || "").trim()) continue;
    const theirJobs = jobs.filter((j) => j.customerId === customer.id);
    if (theirJobs.some((j) => ACTIVE_PIPELINE_STATUSES.has(j.status) && !isArchived(j))) continue;
    if (recurringJobs.some((r) => r.isActive && r.customerId === customer.id)) continue;
    let lastDate = "";
    let lastTitle = "";
    for (const j of theirJobs) {
      if (!SERVICE_HISTORY_STATUSES.has(j.status) || !j.scheduledDate) continue;
      if (j.scheduledDate > lastDate) {
        lastDate = j.scheduledDate;
        lastTitle = j.title;
      }
    }
    if (!lastDate) continue;
    const months = monthsBetween(lastDate, now);
    if (months >= MAINTENANCE_DUE_MONTHS) due.push({ customer, months, lastDate, lastTitle });
  }
  if (due.length === 0) return [];
  due.sort((a, b) => b.months - a.months);
  if (due.length === 1) {
    const { customer, months, lastDate, lastTitle } = due[0];
    const firstName = customer.name.trim().split(/\s+/)[0] || customer.name;
    return [{
      kind: "maintenance_due",
      id: `maintenance_due:${customer.id}`,
      title: `It's been ${months} months since you worked for ${customer.name}`,
      detail: lastTitle ? `Last job: ${lastTitle}` : undefined,
      reason:
        `Your last delivered job for ${customer.name}${lastTitle ? ` ('${lastTitle}')` : ""} was ` +
        `${lastDate} — ${months} months ago (threshold: ${MAINTENANCE_DUE_MONTHS}). They have no ` +
        `upcoming or in-progress work and no active recurring plan. Snoozing hides this for 30 days.`,
      target: { type: "customer", customerId: customer.id },
      // Privacy (spec §E table): first name + service facts only — no
      // financials, no contact details, no full name.
      coachPrompt:
        `It's been ${months} months since I did${lastTitle ? ` '${lastTitle}'` : " a job"} for ` +
        `${firstName}. Draft a short, friendly check-in text offering to schedule their next service.`,
    }];
  }
  return [{
    kind: "maintenance_due",
    id: "maintenance_due:all",
    title: `${due.length} customers haven't been serviced in ${MAINTENANCE_DUE_MONTHS}+ months`,
    reason:
      `${due.length} customers had their last delivered job over ${MAINTENANCE_DUE_MONTHS} months ` +
      `ago and have no upcoming work or active recurring plan. Snoozing hides this for 30 days.`,
    target: { type: "customers" },
  }];
}

/** Month-to-date spend must exceed this multiple of the prior-3-month average
 * to surface — 1.5× is a real spike, not seasonal drift. */
const EXPENSE_ANOMALY_MULT = 1.5;
/** Below this month-to-date total the multiple is noise — a $40 month that
 * doubles to $90 is not worth a card. */
const EXPENSE_ANOMALY_MIN_MTD = 200;

/** The `YYYY-MM` string `offset` whole months before another — pure component
 * math, never Date-parsing the string (FA-039). */
function shiftMonth(ym: string, offset: number): string {
  let y = Number(ym.slice(0, 4));
  let m = Number(ym.slice(5, 7)) - offset;
  while (m <= 0) { m += 12; y -= 1; }
  while (m > 12) { m -= 12; y += 1; }
  return `${y}-${String(m).padStart(2, "0")}`;
}

/**
 * expense_anomaly: business-level spend is running hot this month. Fires when
 * month-to-date expense total exceeds EXPENSE_ANOMALY_MULT × the average of the
 * prior three FULL calendar months — with all three non-zero (a sample floor:
 * no proration, no guessing from thin history) and MTD ≥ EXPENSE_ANOMALY_MIN_MTD
 * (small-base noise floor). Business-level only; per-job attribution is Phase
 * 13's territory and deliberately out of scope here. All month math is
 * local-frame string work (FA-039) — `expense.date` is a local YYYY-MM-DD,
 * never Date-parsed. One row, month-scoped id: a dismissal lasts the rest of the
 * month and next month is a fresh question. Fires strictly greater than the
 * threshold (exactly 1.5× is silent), matching the spec's ">" wording.
 */
function selectExpenseAnomaly(expenses: Expense[], now: Date): TodayInsight[] {
  const today = formatLocalDate(now); // local YYYY-MM-DD (FA-039)
  const currentYM = today.slice(0, 7);
  const priorYMs = [shiftMonth(currentYM, 1), shiftMonth(currentYM, 2), shiftMonth(currentYM, 3)];

  let mtd = 0;
  const priorTotals = [0, 0, 0];
  const mtdByCat: Partial<Record<ExpenseCategoryId, number>> = {};
  const priorByCat: Partial<Record<ExpenseCategoryId, number>> = {};
  for (const e of expenses) {
    const date = e.date || "";
    const ym = date.slice(0, 7);
    const amount = e.amount || 0;
    if (ym === currentYM && date <= today) {
      // Month-to-date: current month, up to and including today (string compare
      // is safe — same month, same YYYY-MM-DD format).
      mtd += amount;
      mtdByCat[e.category] = (mtdByCat[e.category] || 0) + amount;
    } else {
      const idx = priorYMs.indexOf(ym);
      if (idx >= 0) {
        priorTotals[idx] += amount;
        priorByCat[e.category] = (priorByCat[e.category] || 0) + amount;
      }
    }
  }

  if (priorTotals.some((t) => !(t > 0))) return []; // need three full non-zero months
  const avg = (priorTotals[0] + priorTotals[1] + priorTotals[2]) / 3;
  if (!(avg > 0) || mtd < EXPENSE_ANOMALY_MIN_MTD || !(mtd > EXPENSE_ANOMALY_MULT * avg)) return [];

  const pct = Math.round(((mtd - avg) / avg) * 100);

  // Biggest driver: the category with the largest jump over its own prior-3-mo
  // average — the concrete "where the money went" line in the reason.
  let topCat: ExpenseCategoryId | null = null;
  let topDelta = -Infinity;
  let topMtd = 0;
  let topAvg = 0;
  for (const id of Object.keys(mtdByCat) as ExpenseCategoryId[]) {
    const cMtd = mtdByCat[id] || 0;
    const cAvg = (priorByCat[id] || 0) / 3;
    const delta = cMtd - cAvg;
    if (delta > topDelta) {
      topDelta = delta;
      topCat = id;
      topMtd = cMtd;
      topAvg = cAvg;
    }
  }
  const catLabel = EXPENSE_CATEGORIES.find((c) => c.id === topCat)?.label ?? "Other";

  return [{
    kind: "expense_anomaly",
    id: `expense_anomaly:${currentYM}`,
    title: `Spending is running ${pct}% above your recent monthly average`,
    detail: `${formatMoney(mtd)} so far vs ${formatMoney(avg)} average`,
    reason:
      `This month you've spent ${formatMoney(mtd)} through ${today}, versus a ` +
      `${formatMoney(avg)} average over the prior three months ` +
      `(${priorYMs[0]}, ${priorYMs[1]}, ${priorYMs[2]}) — ${pct}% higher. Biggest driver: ` +
      `${catLabel} (${formatMoney(topMtd)} vs ${formatMoney(topAvg)} average). ` +
      `Dismissing hides this for the rest of the month.`,
    target: { type: "money" },
  }];
}

/** Phase 15 additions ride an options bag so the positional signature stays
 * stable as rules gain inputs. */
export type InsightExtras = {
  /** Settings.marginPercent — the low-margin rule's target. Default 20, the
   * pricing engine's own default (buildEstimateInput). */
  targetMarginPercent?: number;
  /** Customer registry — enables the maintenance_due rule when provided. */
  customers?: Customer[];
  /** Active recurring-job rules — suppress maintenance_due for covered customers. */
  recurringJobs?: RecurringJob[];
  /** Expense records — enables the expense_anomaly rule when provided. */
  expenses?: Expense[];
};

export function selectTodayInsights(
  jobs: Job[],
  invoices: Invoice[],
  now: Date,
  schedule: ResolvedSchedule = SCHEDULE_DEFAULTS,
  extras: InsightExtras = {}
): TodayInsight[] {
  const safeJobs = jobs || [];
  const safeInvoices = invoices || [];
  const targetMarginPercent = extras.targetMarginPercent ?? 20;
  return [
    ...selectLaborOverruns(safeJobs, now),
    ...selectLowMarginEstimates(safeJobs, targetMarginPercent),
    ...selectUninvoicedComplete(safeJobs),
    ...selectDueSoon(safeInvoices, now),
    ...selectScheduleInsights(safeJobs, now, schedule),
    // Long-horizon, so it rides last — it must never crowd out today's-money
    // rows given the card's top-3 cap.
    ...selectMaintenanceDue(safeJobs, extras.customers ?? [], extras.recurringJobs ?? [], now),
    // Business-level spend trend — lowest priority (a month-scale signal, not a
    // today action), so it sits after every job/invoice/customer row.
    ...selectExpenseAnomaly(extras.expenses ?? [], now),
  ];
}
