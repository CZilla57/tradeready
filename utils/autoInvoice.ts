// utils/autoInvoice.ts
// Shared invoice-from-job derivation + the opt-in auto-invoice-on-complete
// flow (2026-08-03 spec: docs/superpowers/specs/2026-08-03-auto-invoice-on-
// complete-design.md).
//
// The derivation here (line items, draft prefill, due date) was extracted from
// CreateInvoiceFromJobScreen so the automatic path and the manual screen build
// the SAME invoice for the same job — never re-inline it in a screen.
//
// Tracked-time billing: when the job timer was used, the labor line bills the
// tracked hours at the job's labor rate and the total shifts by the hour delta
// (a T&M change order at the agreed rate). The full pricing engine is
// deliberately NOT re-run from the saved job: jobs don't persist every engine
// input (`overhead`/`margin` name drift, no taxPercent) and a hand-adjusted
// estimateTotal must be trusted — so the quoted materials and residual
// overhead lines stay exactly as quoted and only labor moves. Lines therefore
// still sum to the total (the §2.5 residual invariant).
//
// Approved change orders are included in the total and appended as
// `other`-category lines (2026-08-05 spec), so all three invoice paths pick
// them up from this single home.

import { computeEstimateBreakdown } from "./pricingEngine";
import { approvedChangeOrderTotal, changeOrderStatus } from "./changeOrders";
import { computeTimeTracking, applyClockOut } from "./timeTracking";
import { nextInvoiceNumber } from "./invoiceNumber";
import { roundToCents } from "./invoicePayments";
import { jobChangesAfterInvoiceSave } from "./jobStatus";
import { formatQuote } from "./format";
import {
  loadJobs,
  saveJobs,
  loadInvoices,
  saveInvoices,
  loadCustomers,
  loadSettings,
  getOrCreateCustomer,
  resolveCustomer,
} from "./storage";
import { track } from "./analytics";
import type { Job, JobStatus, Invoice, InvoiceLineItem, Settings, Customer } from "../types/models";

/**
 * Tracked time replaces estimated hours only once the work is finished — a
 * deposit requested mid-job (approved/scheduled/in_progress) still bills off
 * the estimate, because the tracked total isn't final yet.
 */
const BILL_TRACKED_STATUSES: readonly JobStatus[] = ["complete", "invoiced", "paid"];

/** Default payment terms: 30 days from today (moved verbatim from CreateInvoiceFromJobScreen). */
export function defaultDueDate(now: Date = new Date()): string {
  const d = new Date(now);
  d.setDate(d.getDate() + 30);
  return d.toISOString().split("T")[0];
}

export interface BillableLabor {
  /** Hours the labor line should bill. */
  hours: number;
  /** True when tracked timer time replaced the estimate's hours. */
  usedTrackedTime: boolean;
}

/**
 * Hours to bill for a job's labor line. Tracked timer time applies ONLY when:
 *  - the estimate actually priced labor hourly (laborHours > 0 AND
 *    laborRate > 0) — a flat-priced job must never gain a tracked-labor
 *    charge on top of its quoted total, and
 *  - the job is done (BILL_TRACKED_STATUSES), and
 *  - at least one COMPLETED session logged time (a still-running session is
 *    the caller's concern — the auto flow clocks out first, the manual screen
 *    deliberately bills completed sessions only).
 * Tracked hours round to 2 decimals.
 */
export function billableLaborHours(job: Job): BillableLabor {
  const estimated = job.laborHours || 0;
  const rate = job.laborRate || 0;
  if (estimated <= 0 || rate <= 0 || !BILL_TRACKED_STATUSES.includes(job.status)) {
    return { hours: estimated, usedTrackedTime: false };
  }
  const { completedMs } = computeTimeTracking(job.timeSessions || [], estimated);
  const tracked = Math.round((completedMs / 3600000) * 100) / 100;
  if (tracked <= 0) return { hours: estimated, usedTrackedTime: false };
  return { hours: tracked, usedTrackedTime: true };
}

export interface BillableBreakdown {
  /** Hours on the labor line (tracked when usedTrackedTime, else estimated). */
  laborHours: number;
  laborCost: number;
  materialCost: number;
  overheadLine: number;
  hasMaterials: boolean;
  usedTrackedTime: boolean;
  /** Σ approved change-order amounts included in `total` (0 when none). */
  changeOrderTotal: number;
  /** The invoice amount: estimateTotal ± (hour delta × labor rate), in cents-rounded dollars. */
  total: number;
}

/**
 * The billable version of computeEstimateBreakdown: identical to the quoted
 * breakdown until tracked time applies, at which point only the labor line
 * moves and the total shifts by the same delta — materials and the residual
 * overhead line stay as quoted, so lines always sum to the total.
 */
export function computeBillableBreakdown(job: Job): BillableBreakdown {
  const base = computeEstimateBreakdown(job);
  const { hours, usedTrackedTime } = billableLaborHours(job);
  const changeOrderTotal = approvedChangeOrderTotal(job);

  if (!usedTrackedTime) {
    return {
      laborHours: job.laborHours || 0,
      laborCost: base.laborCost,
      materialCost: base.materialCost,
      overheadLine: base.overheadLine,
      hasMaterials: base.hasMaterials,
      usedTrackedTime,
      changeOrderTotal,
      total: roundToCents(base.estimateTotal + changeOrderTotal),
    };
  }

  const laborCost = roundToCents(hours * (job.laborRate || 0));
  return {
    laborHours: hours,
    laborCost,
    materialCost: base.materialCost,
    overheadLine: base.overheadLine,
    hasMaterials: base.hasMaterials,
    usedTrackedTime,
    changeOrderTotal,
    total: roundToCents(base.estimateTotal + laborCost - base.laborCost + changeOrderTotal),
  };
}

/**
 * The invoice line items for a job (extracted from CreateInvoiceFromJobScreen's
 * save path, now tracked-time-aware via computeBillableBreakdown).
 */
export function buildInvoiceLineItems(job: Job): InvoiceLineItem[] {
  const b = computeBillableBreakdown(job);
  const items: InvoiceLineItem[] = [];
  if (b.laborCost > 0) {
    items.push({
      description: `Labor — ${b.laborHours} hrs @ ${formatQuote(job.laborRate || 0)}/hr`,
      amount: b.laborCost,
      category: "labor",
    });
  }
  if (b.hasMaterials) {
    const materials = job.materials || [];
    const label = materials.length === 1
      ? materials[0].name || "Materials"
      : `Materials (${materials.length} items)`;
    items.push({ description: label, amount: b.materialCost, category: "materials" });
  }
  if (b.overheadLine > 1) {
    items.push({ description: "Overhead & operating costs", amount: b.overheadLine, category: "overhead" });
  }
  for (const co of job.changeOrders ?? []) {
    if (changeOrderStatus(co) !== "approved") continue;
    items.push({ description: `Change order — ${co.title}`, amount: co.amount, category: "other" });
  }
  return items;
}

export interface InvoiceDraft {
  customer: string;
  number: string;
  /** 0 when the job has no billable amount (screen renders that as an empty field). */
  amount: number;
  due: string;
  email: string;
  phone: string;
  desc: string;
  usedTrackedTime: boolean;
  billedHours: number;
}

/**
 * The prefill values for an invoice created from a job — used by both
 * CreateInvoiceFromJobScreen's create/requestDeposit modes and the auto flow.
 */
export function prefillInvoiceDraftFromJob(
  job: Job,
  invoices: Invoice[],
  settings: Settings,
  customerRecord?: Customer | null,
): InvoiceDraft {
  const b = computeBillableBreakdown(job);
  return {
    customer: job.customerName || "",
    number: nextInvoiceNumber(invoices, settings),
    amount: b.total,
    due: defaultDueDate(),
    email: customerRecord?.email || "",
    phone: customerRecord?.phone || "",
    desc: job.title || "",
    usedTrackedTime: b.usedTrackedTime,
    billedHours: b.laborHours,
  };
}

/**
 * Whether marking this job complete should auto-create its invoice. A job
 * with an existing invoiceId is a deposit awaiting "finalize" — that flow
 * edits an existing invoice's amount and keeps the manual review screen.
 */
export function shouldAutoInvoice(job: Job, settings: Settings): boolean {
  if (!settings.autoInvoiceOnComplete) return false;
  if (job.invoiceId) return false;
  if (!(job.estimateTotal > 0)) return false;
  if (!(job.customerName || "").trim()) return false;
  return true;
}

export interface AutoInvoiceResult {
  invoiceId: string;
  number: string;
  /** True when the invoice was stamped for the backend email sweep. */
  autoEmailQueued: boolean;
  /** The address the auto-email will go to ("" when not queued). */
  email: string;
}

/**
 * The auto-invoice-on-complete flow. Call AFTER the job's status was written
 * to "complete". Returns the result (invoice id + auto-email disposition), or
 * null when any gate fails — callers degrade silently to the manual flow.
 *
 * Side effects, mirroring CreateInvoiceFromJobScreen's create mode:
 *  - clocks out a still-running timer session (marking complete is the
 *    natural end of the clock; the final session counts toward billed hours),
 *  - links/creates the customer record via the sanctioned path,
 *  - saves the invoice, then advances the job complete → invoiced via
 *    jobChangesAfterInvoiceSave.
 */
export async function createAutoInvoiceForJob(jobId: string): Promise<AutoInvoiceResult | null> {
  const [jobs, invoices, customers, settings] = await Promise.all([
    loadJobs(),
    loadInvoices(),
    loadCustomers(),
    loadSettings(),
  ]);

  let job = jobs.find((j) => j.id === jobId);
  if (!job || job.status !== "complete") return null;
  if (!shouldAutoInvoice(job, settings)) return null;

  const clockedOut = applyClockOut(job, new Date().toISOString());
  if (clockedOut) job = clockedOut;

  // Prefer the job's linked/name-matched customer record for contact info;
  // only create a fresh record when none exists (same end state as the manual
  // screen, which routes the typed name through getOrCreateCustomer).
  const record =
    resolveCustomer(customers, { customerId: job.customerId, customerName: job.customerName }) ??
    (await getOrCreateCustomer({ name: (job.customerName || "").trim() }));

  const draft = prefillInvoiceDraftFromJob(job, invoices, settings, record);
  if (!(draft.amount > 0)) return null;

  // Fully-automatic emailing (2026-08-06 spec): stamp the invoice for the
  // backend's 15-min sweep only when the owner opted in AND we actually have
  // an address. No email on file → the caller keeps today's send-screen path.
  const autoEmailQueued = !!settings.autoEmailInvoiceOnComplete && !!draft.email.trim();

  const lineItems = buildInvoiceLineItems(job);
  const invoice: Invoice = {
    id: `inv${Date.now()}`,
    customer: draft.customer.trim(),
    customerId: record?.id ?? job.customerId ?? "",
    number: draft.number,
    amount: draft.amount,
    due: draft.due,
    email: draft.email,
    phone: draft.phone,
    desc: draft.desc,
    paid: false,
    jobId,
    ...(lineItems.length > 0 ? { lineItems } : {}),
    ...(autoEmailQueued ? { autoEmailRequestedAt: new Date().toISOString() } : {}),
  };
  await saveInvoices([...invoices, invoice]);

  const jobChanges = jobChangesAfterInvoiceSave("create", invoice.id, false);
  const finalJob = { ...job, ...jobChanges };
  await saveJobs(jobs.map((j) => (j.id === jobId ? finalJob : j)));

  track("invoice_created", {
    source: "auto_on_complete",
    usedTrackedTime: draft.usedTrackedTime,
    autoEmailQueued,
  });
  return {
    invoiceId: invoice.id,
    number: invoice.number,
    autoEmailQueued,
    email: autoEmailQueued ? draft.email : "",
  };
}
