// utils/invoiceStats.ts
// Invoice-list derivations for the Invoices screen — the top-of-screen summary
// stats and the search filter — extracted from the screen (roadmap #7) so
// they're unit-tested.
//
// "Overdue" here is defined the same way getStatus (invoiceHelpers) labels a
// row: unpaid AND daysPastDue > 0. The screen previously counted overdue inline
// with `new Date(inv.due) < new Date()`, which flagged due-today invoices (and
// mixed a UTC-parsed date against local now) — so the Overdue stat disagreed
// with the per-row badges. Routing through daysPastDue makes them agree.

import { daysPastDue } from "./invoiceHelpers";
import type { Invoice } from "../types/models";

export interface InvoiceSummary {
  /** Sum of unpaid invoice amounts. */
  outstanding: number;
  /** Count of unpaid invoices past their due date. */
  overdueCount: number;
  /** Sum of paid invoice amounts. */
  collected: number;
}

/** Unpaid and past due — matches the "Nd overdue" branch of getStatus. */
export function isOverdue(invoice: Invoice): boolean {
  return !invoice.paid && daysPastDue(invoice.due) > 0;
}

export function summarizeInvoices(invoices: Invoice[]): InvoiceSummary {
  let outstanding = 0;
  let overdueCount = 0;
  let collected = 0;
  for (const inv of invoices) {
    if (inv.paid) collected += inv.amount;
    else outstanding += inv.amount;
    if (isOverdue(inv)) overdueCount += 1;
  }
  return { outstanding, overdueCount, collected };
}

/** Case-insensitive match on customer name or invoice number. */
export function filterInvoices(invoices: Invoice[], query: string): Invoice[] {
  const q = query.toLowerCase();
  return invoices.filter(
    (inv) => inv.customer.toLowerCase().includes(q) || inv.number.toLowerCase().includes(q),
  );
}
