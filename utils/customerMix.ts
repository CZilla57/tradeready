import type { Invoice } from "../types/models";
import { collectedInRange } from "./invoicePayments";
import { parseLocalDate } from "./moneyUtils";

export interface CustomerMixResult {
  newCount: number;
  newRevenue: number;
  returningCount: number;
  returningRevenue: number;
}

export function computeCustomerMix(
  invoices: Invoice[],
  start: Date,
  end: Date,
): CustomerMixResult {
  const firstInvoiceDate = new Map<string, Date>();

  for (const inv of invoices) {
    if (!inv.due) continue;
    const name = (inv.customer || "").trim().toLowerCase();
    if (!name) continue;
    const d = parseLocalDate(inv.due);
    const existing = firstInvoiceDate.get(name);
    if (!existing || d.getTime() < existing.getTime()) {
      firstInvoiceDate.set(name, d);
    }
  }

  const revenueByCustomer = new Map<string, number>();
  for (const inv of invoices) {
    const name = (inv.customer || "").trim().toLowerCase();
    if (!name) continue;
    // Each payment counts in the window it actually arrived in, so a deposit
    // and its final balance land in the months they were received.
    const collected = collectedInRange([inv], start, end);
    if (collected === 0) continue;
    revenueByCustomer.set(name, (revenueByCustomer.get(name) || 0) + collected);
  }

  let newCount = 0;
  let newRevenue = 0;
  let returningCount = 0;
  let returningRevenue = 0;

  for (const [name, revenue] of revenueByCustomer) {
    const first = firstInvoiceDate.get(name);
    if (!first) continue;
    const isNew = first >= start && first <= end;
    if (isNew) {
      newCount++;
      newRevenue += revenue;
    } else {
      returningCount++;
      returningRevenue += revenue;
    }
  }

  return { newCount, newRevenue, returningCount, returningRevenue };
}
