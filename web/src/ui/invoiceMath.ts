import type { Invoice } from '@shared/types/models';
import { parseLocalDate } from '@shared/utils/moneyUtils';
import { amountPaid, balanceDue, isFullyPaid } from '@shared/utils/invoicePayments';

// Web-side reimplementation of the invoice roll-ups the mobile app keeps in
// utils/invoiceStats.ts. That module can't be imported here: it pulls
// `daysPastDue` from utils/invoiceHelpers.ts, which imports expo-constants and
// other react-native-only modules. These reimplementations match the app's
// logic exactly (same daysPastDue rounding, same per-invoice summing) so the
// portal's overdue badges and totals agree with the app.

/** Local-frame day count from a "YYYY-MM-DD" due date to today. */
export function daysPastDue(dueDate: string, now: Date = new Date()): number {
  const due = parseLocalDate(dueDate);
  due.setHours(0, 0, 0, 0);
  const today = new Date(now.getTime());
  today.setHours(0, 0, 0, 0);
  return Math.round((today.getTime() - due.getTime()) / (1000 * 60 * 60 * 24));
}

/** Has a remaining balance and is past due. */
export function isOverdue(invoice: Invoice): boolean {
  return !isFullyPaid(invoice) && daysPastDue(invoice.due) > 0;
}

export interface InvoiceSummary {
  outstanding: number;
  overdueCount: number;
  collected: number;
}

export function summarizeInvoices(invoices: Invoice[]): InvoiceSummary {
  let outstanding = 0;
  let overdueCount = 0;
  let collected = 0;
  for (const inv of invoices) {
    collected += amountPaid(inv);
    outstanding += balanceDue(inv);
    if (isOverdue(inv)) overdueCount += 1;
  }
  return { outstanding, overdueCount, collected };
}
