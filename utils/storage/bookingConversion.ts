// Converts server-inserted booking requests into the local data model.
// Idempotent and flag-free (modeled on applyEstimateDecisions /
// migrateCustomerIdentity): safe on every sign-in and foreground. The server
// only ever INSERTS request rows with status "new"; the device owns Customer
// and Job creation via the sanctioned paths, then marks the request
// "converted" so the state syncs back and other devices converge.
//
// The lead job id is DETERMINISTIC (jbk_<requestId>): if a run crashes after
// saveJobs but before the request is marked, the rerun regenerates the same
// id and merge-by-id absorbs it — no duplicate leads, same philosophy as the
// recurring engines' ruleId+occurrenceNumber dedupe guard.
//
// Residual (final review 2026-08-04): that same guard doesn't cover
// customers — customer ids are time-based, not deterministic, so two devices
// converting the same request concurrently can each create a Customer record
// for the same person. The existing duplicate-customer detection/merge flow
// surfaces the pair; accepted as-is for a solo-operator app.

import { loadJobs, saveJobs, loadCustomers, saveCustomers } from "./collections";
import { loadSettings } from "./settings";
import { loadBookingRequests, saveBookingRequests } from "./bookingRequests";
import { upsertCustomerInList } from "./customers";
import type { BookingRequest, Customer, Job, Settings } from "../../types/models";

export function convertBookingRequests(
  requests: BookingRequest[],
  jobs: Job[],
  customers: Customer[],
  settings: Settings,
): { requests: BookingRequest[]; jobs: Job[]; customers: Customer[]; changed: boolean } {
  let nextCustomers = customers;
  let nextJobs = jobs;
  let customersChanged = false;
  let jobsChanged = false;
  let requestsChanged = false;

  const nextRequests = requests.map((r) => {
    if (r.status !== "new") return r;

    const { customer, customers: c2, changed } = upsertCustomerInList(nextCustomers, {
      name: r.name,
      email: r.email,
      phone: r.phone,
      address: r.address,
    });
    if (changed) { nextCustomers = c2; customersChanged = true; }
    if (!customer) return r; // unusable name — leave the request for inspection

    const jobId = `jbk_${r.id}`;
    if (!nextJobs.some((j) => j.id === jobId)) {
      // The server's UTC day is fine here — the date is informational, and
      // deriving it from the request keeps conversion fully deterministic.
      const requestDate = r.createdAt.slice(0, 10);
      const timingLine = r.preferredTiming.trim() ? `Preferred timing: ${r.preferredTiming.trim()}\n` : "";
      const lead: Job = {
        id: jobId,
        customerId: customer.id,
        customerName: customer.name,
        title: "Quote request",
        description: r.details,
        status: "lead",
        scheduledDate: null,
        scheduledStartTime: null,
        scheduledEndTime: null,
        address: r.address,
        // AddJob new-job pricing parity (AddJobScreen.tsx ~337), fallbacks included.
        estimateTotal: 0,
        laborHours: 0,
        laborRate: settings.laborRate ?? 85,
        materials: [],
        materialMarkup: settings.materialMarkup ?? 20,
        overhead: settings.overheadPercent ?? 15,
        margin: settings.marginPercent ?? 20,
        notes: `${timingLine}Came in via booking link ${requestDate}`,
        invoiceId: null,
        createdAt: requestDate,
      };
      nextJobs = [...nextJobs, lead];
      jobsChanged = true;
    }

    requestsChanged = true;
    return { ...r, status: "converted" as const, convertedJobId: jobId, convertedCustomerId: customer.id };
  });

  return {
    requests: requestsChanged ? nextRequests : requests,
    jobs: jobsChanged ? nextJobs : jobs,
    customers: customersChanged ? nextCustomers : customers,
    changed: requestsChanged || jobsChanged || customersChanged,
  };
}

// Save-only-what-changed: a save re-enqueues the whole collection, so a no-op
// run must not write (same rule as migrateCustomerIdentity).
export async function applyBookingRequests(): Promise<void> {
  const [requests, jobs, customers, settings] = await Promise.all([
    loadBookingRequests(),
    loadJobs(),
    loadCustomers(),
    loadSettings(),
  ]);
  if (!requests.some((r) => r.status === "new")) return;
  const out = convertBookingRequests(requests, jobs, customers, settings);
  if (out.customers !== customers) await saveCustomers(out.customers);
  if (out.jobs !== jobs) await saveJobs(out.jobs);
  if (out.requests !== requests) await saveBookingRequests(out.requests);
}
