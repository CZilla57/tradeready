import type { Invoice } from "../types/models";

export interface CustomerMixResult {
  newCount: number;
  newRevenue: number;
  returningCount: number;
  returningRevenue: number;
}

function parseLocalDate(dateString: string): Date {
  const dateOnly = /^(\d{4})-(\d{2})-(\d{2})$/.exec(dateString);
  if (dateOnly) {
    return new Date(Number(dateOnly[1]), Number(dateOnly[2]) - 1, Number(dateOnly[3]));
  }
  return new Date(dateString);
}

function isInRange(dateString: string, start: Date, end: Date): boolean {
  const d = parseLocalDate(dateString);
  return d >= start && d <= end;
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
    if (!inv.paid) continue;
    const dateStr = inv.paidAt ?? inv.due;
    if (!dateStr || !isInRange(dateStr, start, end)) continue;
    const name = (inv.customer || "").trim().toLowerCase();
    if (!name) continue;
    revenueByCustomer.set(name, (revenueByCustomer.get(name) || 0) + (inv.amount || 0));
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
