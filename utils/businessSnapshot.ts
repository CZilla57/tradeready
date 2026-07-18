// utils/businessSnapshot.ts
// Reads live storage and produces a compact business summary for the AI advisor.
// The aggregation logic lives in the pure `aggregateSnapshot` function (unit-testable).

import { loadInvoices, loadJobs, loadCustomers } from "./storage";
import { isOverdue } from "./invoiceStats";
import { buildCustomerList } from "./customerList";
import { collectedInRange, balanceDue } from "./invoicePayments";
import type { Invoice, Job, Customer, JobStatus } from "../types/models";

export interface TopCustomerEntry {
  name: string;
  lifetimeSpend: number;
  amountOwed: number;
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
  /** Mean estimateTotal for complete/invoiced/paid jobs (0 when no done jobs). */
  avgCompletedJobValue: number;
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

  let revenueThisMonth = 0;
  let revenueLastMonth = 0;
  let outstandingTotal = 0;
  let overdueTotal = 0;
  let overdueCount = 0;

  // Build month windows once so payments bucket by their own dates.
  const thisMonthRange = { start: new Date(thisYear, thisMonth, 1), end: new Date(thisYear, thisMonth + 1, 0) };
  const lastMonthRange = { start: new Date(lastYear, lastMonth, 1), end: new Date(lastYear, lastMonth + 1, 0) };

  for (const inv of invoices) {
    // Not either/or any more: a partly-paid invoice contributes revenue for
    // what arrived AND outstanding for what's still owed.
    revenueThisMonth += collectedInRange([inv], thisMonthRange.start, thisMonthRange.end);
    revenueLastMonth += collectedInRange([inv], lastMonthRange.start, lastMonthRange.end);

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
    if (DONE_STATUSES.has(job.status) && job.estimateTotal > 0) {
      completedJobTotal += job.estimateTotal;
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

/** Loads all collections from storage and returns a snapshot for the AI system prompt. */
export async function getBusinessSnapshot(): Promise<BusinessSnapshot> {
  const [invoices, jobs, customers] = await Promise.all([
    loadInvoices(),
    loadJobs(),
    loadCustomers(),
  ]);
  const now = new Date();
  return {
    asOf: now.toISOString().split("T")[0],
    ...aggregateSnapshot(invoices, jobs, customers, now),
  };
}
