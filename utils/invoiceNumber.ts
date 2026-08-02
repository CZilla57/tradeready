// utils/invoiceNumber.ts
// Single home for the next-invoice-number rule: scan the digits of every
// existing invoice.number, take max + 1, render `${prefix}-%04d`. Extracted
// 2026-08-01 from the two near-identical screen-local copies
// (AddInvoiceScreen.autoInvoiceNumber, CreateInvoiceFromJobScreen.
// nextInvoiceNumber) so the recurring-invoice generator isn't a third copy
// (architecture-contract reuse rule; they differed only in the null guard
// and parseInt radix — the guarded form was kept).
// 2026-08-02: prefix + starting number became Settings-configurable
// (invoicePrefix / invoiceStartNumber, both optional — absent keeps the
// original INV-from-1 behavior, so pre-existing settings blobs need no
// migration).

import type { Invoice } from "../types/models";

/** Structurally satisfied by Settings — call sites pass the whole object. */
export interface InvoiceNumberOptions {
  invoicePrefix?: string;
  invoiceStartNumber?: number;
}

export const DEFAULT_INVOICE_PREFIX = "INV";

/** Blank → "INV"; trailing dashes/spaces stripped because rendering adds the dash. */
export function normalizeInvoicePrefix(prefix: string | undefined): string {
  const trimmed = (prefix ?? "").trim().replace(/[-\s]+$/, "");
  return trimmed || DEFAULT_INVOICE_PREFIX;
}

export function nextInvoiceNumber(invoices: Invoice[], options?: InvoiceNumberOptions): string {
  const prefix = normalizeInvoicePrefix(options?.invoicePrefix);
  const rawStart = options?.invoiceStartNumber;
  const start = typeof rawStart === "number" && isFinite(rawStart) && rawStart >= 1
    ? Math.floor(rawStart)
    : 1;
  const nums = invoices
    .map((inv) => {
      let raw = inv.number || "";
      // Strip a leading occurrence of the current prefix before the digit
      // scan, so a digit-bearing prefix (e.g. "2026") can't compound its own
      // digits into the counter and run the sequence away.
      if (raw.toUpperCase().startsWith(prefix.toUpperCase())) {
        raw = raw.slice(prefix.length);
      }
      return parseInt(raw.replace(/\D/g, ""), 10);
    })
    .filter(Boolean);
  // The starting number is a floor, not a reset: once the sequence has grown
  // past it, existing numbering keeps winning.
  const next = Math.max(nums.length ? Math.max(...nums) + 1 : 1, start);
  return `${prefix}-${String(next).padStart(4, "0")}`;
}
