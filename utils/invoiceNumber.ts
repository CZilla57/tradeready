// utils/invoiceNumber.ts
// Single home for the next-invoice-number rule: scan the digits of every
// existing invoice.number, take max + 1, render INV-%04d. Extracted
// 2026-08-01 from the two near-identical screen-local copies
// (AddInvoiceScreen.autoInvoiceNumber, CreateInvoiceFromJobScreen.
// nextInvoiceNumber) so the recurring-invoice generator isn't a third copy
// (architecture-contract reuse rule; they differed only in the null guard
// and parseInt radix — the guarded form was kept).

import type { Invoice } from "../types/models";

export function nextInvoiceNumber(invoices: Invoice[]): string {
  const nums = invoices
    .map((inv) => parseInt((inv.number || "").replace(/\D/g, ""), 10))
    .filter(Boolean);
  const next = nums.length ? Math.max(...nums) + 1 : 1;
  return `INV-${String(next).padStart(4, "0")}`;
}
