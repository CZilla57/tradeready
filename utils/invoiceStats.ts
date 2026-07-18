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
import { amountPaid, balanceDue, isFullyPaid } from "./invoicePayments";
import type { Invoice } from "../types/models";

export interface InvoiceSummary {
  /** Sum of remaining balances. */
  outstanding: number;
  /** Count of unpaid invoices past their due date. */
  overdueCount: number;
  /** Sum of payments received. */
  collected: number;
}

/** Has a remaining balance and is past due — matches the "Nd overdue" badge. */
export function isOverdue(invoice: Invoice): boolean {
  // Legacy invoices without a ledger use the original logic based on the paid flag
  if (!invoice.payments || invoice.payments.length === 0) {
    return !invoice.paid && daysPastDue(invoice.due) > 0;
  }
  // Ledger-based invoices check for remaining balance
  return !isFullyPaid(invoice) && daysPastDue(invoice.due) > 0;
}

export function summarizeInvoices(invoices: Invoice[]): InvoiceSummary {
  let outstanding = 0;
  let overdueCount = 0;
  let collected = 0;
  for (const inv of invoices) {
    // Per-invoice rather than per-flag: a partly-paid invoice contributes to
    // BOTH, which is what makes these totals agree with the rows below them.
    collected += amountPaid(inv);
    outstanding += balanceDue(inv);
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
