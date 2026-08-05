// utils/changeOrders.ts
// Change-order domain logic (2026-08-05 spec). Single source of truth for
// CO status derivation and the job's billable total. Pure — no storage.
//
// jobBillableTotal is what every DISPLAY surface shows for a job's value;
// job.estimateTotal stays the as-approved baseline (computeEstimateBreakdown's
// residual overhead math depends on it) and is never mutated here.
//
// Mirrored (CommonJS) in backend/lib/estimate/changeOrderMath.js for the
// change-view context totals — kept in sync by __tests__/changeOrderParity.test.js.

import { roundToCents } from "./invoicePayments";
import { formatQuote } from "./format";
import { escapeHtml } from "./pdfTemplates";
import type {
  ChangeOrder,
  Customer,
  EstimateApprovalSnapshot,
  Job,
  JobStatus,
  Settings,
} from "../types/models";

export type ChangeOrderStatus = "pending" | "awaiting" | "approved" | "declined" | "cancelled";

let _coCounter = 0;
/** co<timestamp>_<counter> — counter prevents same-millisecond collisions (newCustomerId pattern). */
export function newChangeOrderId(): string {
  _coCounter += 1;
  return `co${Date.now()}_${_coCounter}`;
}

/**
 * Derived status — never stored. Link decision wins over manual in the race
 * window (server-stamped consent is the stronger record); cancelled beats all.
 */
export function changeOrderStatus(co: ChangeOrder): ChangeOrderStatus {
  if (co.cancelledAt) return "cancelled";
  const decision = co.approval?.decision ?? co.manualDecision?.decision;
  if (decision === "approved") return "approved";
  if (decision === "declined") return "declined";
  if (co.approval) return "awaiting";
  return "pending";
}

export function approvedChangeOrderTotal(job: Pick<Job, "changeOrders">): number {
  return roundToCents(
    (job.changeOrders ?? []).reduce(
      (sum, co) => (changeOrderStatus(co) === "approved" ? sum + (co.amount || 0) : sum),
      0,
    ),
  );
}

/** estimateTotal + approved COs — the number every display surface shows. */
export function jobBillableTotal(job: Pick<Job, "estimateTotal" | "changeOrders">): number {
  return roundToCents((job.estimateTotal || 0) + approvedChangeOrderTotal(job));
}

const CO_ADDABLE_STATUSES: readonly JobStatus[] = ["approved", "scheduled", "in_progress", "complete"];

/**
 * COs need an agreed baseline (post-approval) and an open bill (pre-invoiced):
 * before approval, revise the estimate instead; after invoiced, edit the
 * invoice or open a new job.
 */
export function canAddChangeOrder(status: JobStatus): boolean {
  return CO_ADDABLE_STATUSES.includes(status);
}

export type ChangeOrderInputResult =
  | { ok: true; title: string; amount: number }
  | { ok: false; message: string };

/**
 * Form validation for AddChangeOrderScreen. `editingId` excludes the CO being
 * edited from the below-$0 floor check (its old amount is being replaced).
 * NOTE: only PENDING COs are editable, and pending COs never count toward
 * approvedChangeOrderTotal — editingId exists for future-proofing the floor
 * math, not because an approved CO can be edited (it can't).
 */
export function validateChangeOrderInput(
  title: string,
  amountText: string,
  job: Job,
  editingId?: string,
): ChangeOrderInputResult {
  const trimmed = title.trim();
  if (!trimmed) return { ok: false, message: "Please give this change a short title." };
  const amount = parseFloat(amountText);
  if (!amountText.trim() || isNaN(amount) || amount === 0) {
    return { ok: false, message: "Please enter a non-zero amount (negative for a credit)." };
  }
  const others: Pick<Job, "estimateTotal" | "changeOrders"> = {
    estimateTotal: job.estimateTotal,
    changeOrders: (job.changeOrders ?? []).filter((c) => c.id !== editingId),
  };
  if (jobBillableTotal(others) + amount < 0) {
    return { ok: false, message: "This credit would take the job's total below $0." };
  }
  return { ok: true, title: trimmed, amount: roundToCents(amount) };
}

/**
 * Stamps an on-site decision. Refuses (same reference back) when the CO is
 * already decided or cancelled — callers can skip saveJobs on `out === co`.
 */
export function applyManualDecision(
  co: ChangeOrder,
  decision: "approved" | "declined",
  note: string,
  today: string,
): ChangeOrder {
  const status = changeOrderStatus(co);
  if (status !== "pending" && status !== "awaiting") return co;
  const trimmedNote = note.trim();
  return {
    ...co,
    manualDecision: { decision, decidedAt: today, ...(trimmedNote ? { note: trimmedNote } : {}) },
  };
}

/** One-way cancel. Refuses (same reference) unless pending/awaiting. */
export function cancelChangeOrder(co: ChangeOrder, today: string): ChangeOrder {
  const status = changeOrderStatus(co);
  if (status !== "pending" && status !== "awaiting") return co;
  return { ...co, cancelledAt: today };
}

/**
 * Freezes the CO for the customer page — EstimateApprovalSnapshot reused
 * verbatim so the backend and viewer handle one shape (buildEstimateSnapshot
 * pattern). Context totals (original/new) are deliberately NOT frozen here:
 * change-view computes them live so multi-CO jobs show truthful numbers.
 */
export function buildChangeOrderSnapshot(
  co: ChangeOrder,
  job: Job,
  customer: Pick<Customer, "name">,
  settings: Pick<Settings, "businessName">,
): EstimateApprovalSnapshot {
  return {
    businessName: settings.businessName || "Your tradesperson",
    customerName: customer.name || job.customerName,
    jobTitle: job.title,
    lineItems: [{ label: co.title, amount: co.amount }],
    total: co.amount,
    currency: "USD",
  };
}

export interface ChangeOrderMessages {
  /** Plain text — SMS has no markup, so the raw link stays (auto-linkified). */
  sms: string;
  emailSubject: string;
  /** HTML — pass to composeEmail with `isHtml: true`. The approval URL lives
      in an anchor labeled "Review & approve this change" instead of appearing
      as a giant character string (owner feedback 2026-08-05). */
  emailHtml: string;
}

/**
 * The customer-facing send bodies for one change order. Pure and escaped —
 * every user-entered value (names, titles) passes through escapeHtml before
 * landing in the HTML body, matching the pdfTemplates discipline.
 */
export function buildChangeOrderMessages(
  co: ChangeOrder,
  job: Pick<Job, "title" | "customerName">,
  customerName: string,
  url: string,
): ChangeOrderMessages {
  const name = customerName || job.customerName;
  const amountText = `${co.amount >= 0 ? "+" : ""}${formatQuote(co.amount)}`;
  const sms =
    `Hi ${name}, while working on "${job.title}" we found something that changes the scope: ` +
    `${co.title} (${amountText}). ` +
    `Please review and approve before we do this extra work: ${url}`;
  const emailHtml =
    `<p>Hi ${escapeHtml(name)},</p>` +
    `<p>While working on &quot;${escapeHtml(job.title)}&quot; we found something that changes the scope:</p>` +
    `<p><strong>${escapeHtml(co.title)}</strong> (${escapeHtml(amountText)})</p>` +
    `<p><a href="${escapeHtml(url)}">Review &amp; approve this change</a></p>` +
    `<p>Please approve before we do the extra work — thanks!</p>`;
  return { sms, emailSubject: `Change to your ${job.title} job`, emailHtml };
}
