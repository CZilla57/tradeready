// utils/bulkInvoiceActions.ts
// Pure logic behind the Invoices multi-select bulk actions (Remind / Mark
// paid). The screen owns the composer loop and the saves; these helpers own
// the selection math so it's unit-testable.

import type { Invoice } from "../types/models";
import { isFullyPaid, settleRemaining } from "./invoicePayments";

export interface RemindableSplit {
  /** Unpaid, selected, and reachable on the chosen channel — in list order. */
  eligible: Invoice[];
  /** Unpaid and selected but missing the channel's contact field. */
  skippedNoContact: Invoice[];
}

/** Paid invoices are silently ignored even if selected — nothing to remind. */
export function splitRemindable(
  invoices: Invoice[],
  selectedIds: Iterable<string>,
  channel: "email" | "text",
): RemindableSplit {
  const ids = new Set(selectedIds);
  const selected = invoices.filter((i) => ids.has(i.id) && !isFullyPaid(i));
  const reachable = (i: Invoice) =>
    channel === "email" ? Boolean((i.email || "").trim()) : Boolean((i.phone || "").trim());
  return {
    eligible: selected.filter(reachable),
    skippedNoContact: selected.filter((i) => !reachable(i)),
  };
}

export interface BulkSettleResult {
  /** The full list with every settled invoice swapped in (=== input when nothing settled). */
  updated: Invoice[];
  /** The settled copies, for per-invoice follow-ups (tracking, job reconcile). */
  settled: Invoice[];
}

/**
 * Settle the remaining balance on every selected unpaid invoice, dated
 * `today`. Same-reference return on already-paid invoices comes from
 * settleRemaining, so an all-paid selection returns the input list untouched.
 */
export function bulkSettle(
  invoices: Invoice[],
  selectedIds: Iterable<string>,
  today: string,
): BulkSettleResult {
  const ids = new Set(selectedIds);
  const settled: Invoice[] = [];
  const updated = invoices.map((i) => {
    if (!ids.has(i.id)) return i;
    const s = settleRemaining(i, today);
    if (s !== i) settled.push(s);
    return s;
  });
  return settled.length > 0 ? { updated, settled } : { updated: invoices, settled };
}

/**
 * The generic outreach email begins "Subject: …\n\n…" (invoiceHelpers).
 * Split it the way OutreachScreen does; fall back when the model/template
 * didn't produce one.
 */
export function splitEmailSubject(raw: string, fallbackSubject: string): { subject: string; body: string } {
  if (raw.startsWith("Subject:")) {
    const lines = raw.split("\n");
    return {
      subject: lines[0].replace("Subject:", "").trim() || fallbackSubject,
      body: lines.slice(2).join("\n").trim(),
    };
  }
  return { subject: fallbackSubject, body: raw };
}
