// utils/businessSnapshot.ts
// Reads live storage and produces a compact business summary for the AI advisor.
// The aggregation logic lives in the pure `aggregateSnapshot` function (unit-testable).

import { loadInvoices, loadJobs, loadCustomers, loadExpenses, loadTrips, loadSettings } from "./storage";
import { isOverdue } from "./invoiceStats";
import { buildCustomerList } from "./customerList";
import { collectedByPeriod, balanceDue } from "./invoicePayments";
import { summarizeTaxWindow, formatPeriodRange, formatDeadline } from "./taxEstimate";
import { jobBillableTotal } from "./changeOrders";
import type { Invoice, Job, Customer, JobStatus, Expense, Trip, Settings } from "../types/models";

export interface TopCustomerEntry {
  name: string;
  lifetimeSpend: number;
  amountOwed: number;
}

/**
 * The tax set-aside figures the AI coach may CITE. The coach's system prompt
 * pairs these with a hard constraint: guidance only — filing, eligibility,
 * election, and entity questions get declined and referred to a professional.
 */
export interface TaxSnapshotBlock {
  periodReserve: number;
  ytdReserve: number;
  /** "Jun 1 – Aug 31" */
  periodLabel: string;
  /** "Sep 15" */
  dueLabel: string;
  incomeRateSet: boolean;
  needsVehicleChoice: boolean;
  ratesKnown: boolean;
}

export interface BusinessSnapshot {
  /** ISO "YYYY-MM-DD" when the snapshot was taken. */
  asOf: string;
  revenueThisMonth: number;
  revenueLastMonth: number;
  outstandingTotal: number;
  overdueTotal: number;
  overdueCount: number;
  /** Active (pre-complete) jobs bucketed by status. */
  activeJobsByStatus: Partial<Record<JobStatus, number>>;
  totalCustomers: number;
  /** Top 5 customers by lifetime spend. */
  topCustomers: TopCustomerEntry[];
  /** Mean billable total (estimate + approved change orders) for complete/invoiced/paid jobs (0 when no done jobs). */
  avgCompletedJobValue: number;
  /** Tax set-aside figures; absent when the tax inputs failed to load. */
  tax?: TaxSnapshotBlock;
}

const ACTIVE_STATUSES = new Set<JobStatus>([
  "lead", "estimate_sent", "approved", "scheduled", "in_progress",
]);

const DONE_STATUSES = new Set<JobStatus>(["complete", "invoiced", "paid"]);

/**
 * Pure aggregation — no async, no storage calls. Pass `now` for deterministic tests.
 */
export function aggregateSnapshot(
  invoices: Invoice[],
  jobs: Job[],
  rawCustomers: Customer[],
  now: Date = new Date(),
): Omit<BusinessSnapshot, "asOf"> {
  const thisYear = now.getFullYear();
  const thisMonth = now.getMonth();
  const lastYear = thisMonth === 0 ? thisYear - 1 : thisYear;
  const lastMonth = thisMonth === 0 ? 11 : thisMonth - 1;

  let outstandingTotal = 0;
  let overdueTotal = 0;
  let overdueCount = 0;

  // Build month windows once so payments bucket by their own dates.
  const thisMonthRange = { start: new Date(thisYear, thisMonth, 1), end: new Date(thisYear, thisMonth + 1, 0) };
  const lastMonthRange = { start: new Date(lastYear, lastMonth, 1), end: new Date(lastYear, lastMonth + 1, 0) };

  // Walk every invoice's ledger once for both months rather than once per
  // month per invoice (collectedInRange re-materialises the ledger each call).
  const [revenueThisMonth, revenueLastMonth] = collectedByPeriod(invoices, [thisMonthRange, lastMonthRange]);

  for (const inv of invoices) {
    // Not either/or any more: a partly-paid invoice contributes revenue for
    // what arrived AND outstanding for what's still owed.
    const balance = balanceDue(inv);
    outstandingTotal += balance;
    if (balance > 0 && isOverdue(inv)) {
      overdueTotal += balance;
      overdueCount++;
    }
  }

  const activeJobsByStatus: Partial<Record<JobStatus, number>> = {};
  let completedJobTotal = 0;
  let completedJobCount = 0;

  for (const job of jobs) {
    if (ACTIVE_STATUSES.has(job.status)) {
      activeJobsByStatus[job.status] = (activeJobsByStatus[job.status] ?? 0) + 1;
    }
    if (DONE_STATUSES.has(job.status) && jobBillableTotal(job) > 0) {
      completedJobTotal += jobBillableTotal(job);
      completedJobCount++;
    }
  }

  const customerList = buildCustomerList(invoices, rawCustomers);

  const topCustomers: TopCustomerEntry[] = customerList.slice(0, 5).map((c) => ({
    name: c.name,
    lifetimeSpend: c.totalSpent,
    amountOwed: c.totalOwed,
  }));

  return {
    revenueThisMonth,
    revenueLastMonth,
    outstandingTotal,
    overdueTotal,
    overdueCount,
    activeJobsByStatus,
    totalCustomers: customerList.length,
    topCustomers,
    avgCompletedJobValue: completedJobCount > 0 ? completedJobTotal / completedJobCount : 0,
  };
}

/**
 * Pure: reduce a tax window summary to the compact block the system prompt
 * renders. Kept separate from aggregateSnapshot so its inputs (expenses,
 * trips, settings) stay out of that function's signature and tests.
 */
export function buildTaxSnapshotBlock(args: {
  invoices: Invoice[];
  expenses: Expense[];
  trips: Trip[];
  settings: Partial<Settings>;
  now?: Date;
}): TaxSnapshotBlock {
  const s = summarizeTaxWindow(args);
  return {
    periodReserve: s.current.reserve,
    ytdReserve: s.ytd.reserve,
    periodLabel: formatPeriodRange(s.period),
    dueLabel: formatDeadline(s.period),
    incomeRateSet: s.incomeRateSet,
    needsVehicleChoice: s.needsVehicleChoice,
    ratesKnown: s.current.ratesKnown,
  };
}

/** Loads all collections from storage and returns a snapshot for the AI system prompt. */
export async function getBusinessSnapshot(): Promise<BusinessSnapshot> {
  const [invoices, jobs, customers, expenses, trips, settings] = await Promise.all([
    loadInvoices(),
    loadJobs(),
    loadCustomers(),
    loadExpenses(),
    loadTrips(),
    loadSettings(),
  ]);
  const now = new Date();
  return {
    asOf: now.toISOString().split("T")[0],
    ...aggregateSnapshot(invoices, jobs, customers, now),
    tax: buildTaxSnapshotBlock({ invoices, expenses, trips, settings, now }),
  };
}
