// utils/customerMerge.ts
// Merge two customer records: the LOSER dissolves into the WINNER. Every
// reference that carries customerId + a denormalized name — jobs, invoices,
// recurring-job rules, recurring-invoice rules — re-points to the winner, the
// winner backfills its blank contact fields from the loser (never clobbers —
// same philosophy as upsertCustomerInList), notes concatenate, and the loser
// record is removed. Identity territory: see architecture contract §6.
//
// The pure core (mergeCustomers) is unit-tested; performCustomerMerge is the
// async wrapper that loads collections, runs it, and saves ONLY the
// collections that changed (each save re-enqueues the whole collection for
// sync, so a no-op save is not free).

import type { Customer, Invoice, Job, RecurringInvoice, RecurringJob } from "../types/models";
import {
  loadCustomers, saveCustomers,
  loadJobs, saveJobs,
  loadInvoices, saveInvoices,
  loadRecurringJobs, saveRecurringJobs,
  loadRecurringInvoices, saveRecurringInvoices,
} from "./storage";

const nameKey = (s: string | null | undefined): string => (s || "").trim().toLowerCase();

export interface MergeData {
  customers: Customer[];
  jobs: Job[];
  invoices: Invoice[];
  recurringJobs: RecurringJob[];
  recurringInvoices: RecurringInvoice[];
}

export interface MergeResult extends MergeData {
  winner: Customer;
  /** Per-collection re-point counts, for the confirmation/summary UI. */
  changed: { jobs: number; invoices: number; recurringJobs: number; recurringInvoices: number };
}

/** Winner keeps every non-blank field; blanks backfill from the loser. */
export function mergeCustomerRecords(winner: Customer, loser: Customer): Customer {
  const merged: Customer = { ...winner };
  if (!nameKey(merged.email) && loser.email) merged.email = loser.email;
  if (!nameKey(merged.phone) && loser.phone) merged.phone = loser.phone;
  if (!nameKey(merged.address) && loser.address) merged.address = loser.address;
  const winnerNotes = (winner.notes || "").trim();
  const loserNotes = (loser.notes || "").trim();
  if (loserNotes && loserNotes !== winnerNotes) {
    merged.notes = winnerNotes ? `${winnerNotes}\n\n${loserNotes}` : loserNotes;
  }
  // Lifetime facts: the merged record existed since whichever came first.
  if (loser.createdAt && (!merged.createdAt || loser.createdAt < merged.createdAt)) {
    merged.createdAt = loser.createdAt;
  }
  return merged;
}

/**
 * Pure merge over all five collections. Unchanged collections come back as
 * the SAME reference so callers can skip their saves. Throws on a self-merge
 * or a missing record — screens should have validated both.
 */
export function mergeCustomers(data: MergeData, winnerId: string, loserId: string): MergeResult {
  if (winnerId === loserId) throw new Error("Cannot merge a customer into itself");
  const winner = data.customers.find((c) => c.id === winnerId);
  const loser = data.customers.find((c) => c.id === loserId);
  if (!winner || !loser) throw new Error("Merge customers not found");

  const loserName = nameKey(loser.name);

  // A record belongs to the loser when its id points there — or when it's an
  // orphan (blank customerId) whose denormalized name matches the loser, the
  // same name-fallback join CustomerDetail uses.
  const belongsToLoser = (customerId: string | undefined, name: string | undefined): boolean =>
    customerId === loserId || (!customerId && nameKey(name) === loserName);

  let jobsChanged = 0;
  const jobs = data.jobs.map((j) => {
    if (!belongsToLoser(j.customerId, j.customerName)) return j;
    jobsChanged++;
    return { ...j, customerId: winnerId, customerName: winner.name };
  });

  let invoicesChanged = 0;
  const invoices = data.invoices.map((i) => {
    if (!belongsToLoser(i.customerId, i.customer)) return i;
    invoicesChanged++;
    return { ...i, customerId: winnerId, customer: winner.name };
  });

  let recurringJobsChanged = 0;
  const recurringJobs = data.recurringJobs.map((r) => {
    if (!belongsToLoser(r.customerId, r.customerName)) return r;
    recurringJobsChanged++;
    return { ...r, customerId: winnerId, customerName: winner.name };
  });

  let recurringInvoicesChanged = 0;
  const recurringInvoices = data.recurringInvoices.map((r) => {
    if (!belongsToLoser(r.customerId, r.customerName)) return r;
    recurringInvoicesChanged++;
    return { ...r, customerId: winnerId, customerName: winner.name };
  });

  const mergedWinner = mergeCustomerRecords(winner, loser);
  const customers = data.customers
    .filter((c) => c.id !== loserId)
    .map((c) => (c.id === winnerId ? mergedWinner : c));

  return {
    customers,
    jobs: jobsChanged ? jobs : data.jobs,
    invoices: invoicesChanged ? invoices : data.invoices,
    recurringJobs: recurringJobsChanged ? recurringJobs : data.recurringJobs,
    recurringInvoices: recurringInvoicesChanged ? recurringInvoices : data.recurringInvoices,
    winner: mergedWinner,
    changed: {
      jobs: jobsChanged,
      invoices: invoicesChanged,
      recurringJobs: recurringJobsChanged,
      recurringInvoices: recurringInvoicesChanged,
    },
  };
}

/** Load → merge → save only what changed. Returns the result for the UI. */
export async function performCustomerMerge(winnerId: string, loserId: string): Promise<MergeResult> {
  const [customers, jobs, invoices, recurringJobs, recurringInvoices] = await Promise.all([
    loadCustomers(),
    loadJobs(),
    loadInvoices(),
    loadRecurringJobs(),
    loadRecurringInvoices(),
  ]);
  const data: MergeData = { customers, jobs, invoices, recurringJobs, recurringInvoices };
  const result = mergeCustomers(data, winnerId, loserId);

  // Customers always changed (loser removed). Others only when re-pointed.
  await saveCustomers(result.customers);
  if (result.jobs !== data.jobs) await saveJobs(result.jobs);
  if (result.invoices !== data.invoices) await saveInvoices(result.invoices);
  if (result.recurringJobs !== data.recurringJobs) await saveRecurringJobs(result.recurringJobs);
  if (result.recurringInvoices !== data.recurringInvoices) await saveRecurringInvoices(result.recurringInvoices);

  return result;
}
