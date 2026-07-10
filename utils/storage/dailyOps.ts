// utils/storage/dailyOps.ts
// Derived, read-only queries that power the Today tab: today's scheduled jobs,
// their expected earnings, overdue invoices, and open leads. These filter/sort
// the collections but never write.

import { loadJobs, loadInvoices } from "./collections";
import { reportError } from "../analytics";
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
      return sum + (Number(job.estimateTotal) || 0);
    }, 0);

    return total;
  } catch (error) {
    console.error("Error calculating expected earnings:", error);
    reportError(error, { context: 'getExpectedEarnings' });
    return 0;
  }
}

export async function loadOverdueInvoices(): Promise<Invoice[]> {
  try {
    const invoices = await loadInvoices();
    const today = new Date();
    today.setHours(0, 0, 0, 0);
    return invoices
      .filter((inv) => !inv.paid && new Date(inv.due) < today)
      .sort((a, b) => new Date(a.due).getTime() - new Date(b.due).getTime());
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
