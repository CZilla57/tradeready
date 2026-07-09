import type { Invoice } from "../types/models";

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

function parseLocalDate(dateString: string): Date {
  const dateOnly = /^(\d{4})-(\d{2})-(\d{2})$/.exec(dateString);
  if (dateOnly) {
    return new Date(Number(dateOnly[1]), Number(dateOnly[2]) - 1, Number(dateOnly[3]));
  }
  return new Date(dateString);
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
    if (!inv.paid || !inv.paidAt || !inv.due) continue;
    const days = daysBetween(inv.due, inv.paidAt);
    totalDays += days;
    paidCount++;

    const name = inv.customer || "Unknown";
    const entry = byCustomer.get(name);
    if (entry) {
      entry.totalDays += days;
      entry.count++;
      entry.totalAmount += inv.amount || 0;
    } else {
      byCustomer.set(name, { totalDays: days, count: 1, totalAmount: inv.amount || 0 });
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
