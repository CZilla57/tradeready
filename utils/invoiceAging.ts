import type { Invoice } from "../types/models";
import { isFullyPaid } from "./invoicePayments";
import { parseLocalDate } from "./moneyUtils";

export interface CustomerPaySpeed {
  name: string;
  avgDays: number;
  invoiceCount: number;
  totalAmount: number;
}

export interface InvoiceAgingResult {
  avgDays: number;
  paidCount: number;
  customers: CustomerPaySpeed[];
}

function daysBetween(from: string, to: string): number {
  const a = parseLocalDate(from);
  const b = parseLocalDate(to);
  return Math.round((b.getTime() - a.getTime()) / (1000 * 60 * 60 * 24));
}

export function computeInvoiceAging(invoices: Invoice[]): InvoiceAgingResult {
  const byCustomer = new Map<string, { totalDays: number; count: number; totalAmount: number }>();
  let totalDays = 0;
  let paidCount = 0;

  for (const inv of invoices) {
    // Aging measures how long an invoice took to SETTLE, so partly-paid ones
    // are correctly excluded — they haven't finished aging. paidAt still holds
    // the settling payment's date.
    if (!isFullyPaid(inv) || !inv.paidAt || !inv.due) continue;
    const days = daysBetween(inv.due, inv.paidAt);
    totalDays += days;
    paidCount++;

    const name = inv.customer || "Unknown";
    const entry = byCustomer.get(name);
    // Deliberately the invoice's FACE VALUE, not a collected amount — aging
    // reports "how much settled business did this customer represent", so it
    // sits outside the invoicePayments.ts ledger contract on purpose. Coerced
    // with Number(...) rather than routed through amountPaid/balanceDue
    // (which would change the meaning) because toAmount() is private to that
    // module and a persisted string would otherwise concatenate into this
    // number-typed field.
    if (entry) {
      entry.totalDays += days;
      entry.count++;
      entry.totalAmount += Number(inv.amount) || 0;
    } else {
      byCustomer.set(name, { totalDays: days, count: 1, totalAmount: Number(inv.amount) || 0 });
    }
  }

  const customers: CustomerPaySpeed[] = [];
  for (const [name, data] of byCustomer) {
    customers.push({
      name,
      avgDays: Math.round(data.totalDays / data.count),
      invoiceCount: data.count,
      totalAmount: data.totalAmount,
    });
  }

  customers.sort((a, b) => b.avgDays - a.avgDays);

  return {
    avgDays: paidCount > 0 ? Math.round(totalDays / paidCount) : 0,
    paidCount,
    customers,
  };
}
