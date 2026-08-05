// utils/storage/dailyOps.ts
// Derived, read-only queries that power the Today tab: today's scheduled jobs,
// their expected earnings, overdue invoices, and open leads. These filter/sort
// the collections but never write.

import { loadJobs, loadInvoices } from "./collections";
import { reportError } from "../analytics";
import { isFullyPaid } from "../invoicePayments";
import { daysPastDue } from "../invoiceHelpers";
import { jobBillableTotal } from "../changeOrders";
import type { Job, Invoice } from "../../types/models";

export async function loadJobsForDate(dateString: string): Promise<Job[]> {
  try {
    const allJobs = await loadJobs();

    // Filter by date and sort chronologically by start time
    return allJobs
      .filter((job) => job.scheduledDate === dateString)
      .sort((a, b) => {
        // Push jobs without a start time to the end of the day
        if (!a.scheduledStartTime) return 1;
        if (!b.scheduledStartTime) return -1;
        return a.scheduledStartTime.localeCompare(b.scheduledStartTime);
      });
  } catch (error) {
    console.error("Error loading jobs for date:", error);
    reportError(error, { context: 'loadJobsForDate' });
    return [];
  }
}

export async function getExpectedEarningsForDate(dateString: string): Promise<number> {
  try {
    const todaysJobs = await loadJobsForDate(dateString);

    // Sum the estimated totals to calculate expected daily revenue
    const total = todaysJobs.reduce((sum, job) => {
      return sum + jobBillableTotal(job);
    }, 0);

    return total;
  } catch (error) {
    console.error("Error calculating expected earnings:", error);
    reportError(error, { context: 'getExpectedEarnings' });
    return 0;
  }
}

/** Pure overdue selector — local-frame day math (FA-039): daysPastDue
 * compares local midnights, so a bare "YYYY-MM-DD" due date never gets
 * parsed as UTC midnight (which put due-today invoices in this list west of
 * UTC). Due-today is NOT overdue — it belongs to the Today due-soon insight
 * (utils/todayInsights.ts), not this list. Extracted so TodayScreen can
 * derive the overdue subset from its already-loaded invoice list instead of
 * parsing the blob twice per focus. */
export function filterOverdueInvoices(invoices: Invoice[]): Invoice[] {
  return invoices
    .filter((inv) => !isFullyPaid(inv) && daysPastDue(inv.due) >= 1)
    .sort((a, b) => new Date(a.due).getTime() - new Date(b.due).getTime());
}

export async function loadOverdueInvoices(): Promise<Invoice[]> {
  try {
    return filterOverdueInvoices(await loadInvoices());
  } catch {
    return [];
  }
}

export async function loadLeadJobs(): Promise<Job[]> {
  try {
    const jobs = await loadJobs();
    return jobs
      .filter((j) => j.status === "lead")
      .sort((a, b) => new Date(a.createdAt || 0).getTime() - new Date(b.createdAt || 0).getTime());
  } catch {
    return [];
  }
}
