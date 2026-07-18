// utils/invoicePayments.ts
// The single home for payment-ledger math. Every screen and analytics helper
// that needs "how much has been paid" or "what's still owed" routes through
// here — nobody sums an invoice's payments by hand.
//
// LEGACY FALLBACK (the reason this feature needed no migration): invoices
// created before the ledger existed have no `payments` array. For those,
// amountPaid derives from the old boolean — a paid invoice counts as one
// implicit payment of the full amount, an unpaid one as zero. That is exactly
// what every money surface already assumed, so converted analytics return
// identical numbers on legacy data.

import type { Invoice, Payment } from "../types/models";

/**
 * Balances are floats, so "settled" means "within half a cent", never === 0.
 * 0.1 + 0.2 !== 0.3 in IEEE 754 and invoices really do split into thirds.
 */
export const PAID_EPSILON = 0.005;

/** Total received against this invoice, in dollars. */
export function amountPaid(invoice: Invoice): number {
  const ledger = invoice.payments;
  if (ledger && ledger.length > 0) {
    return ledger.reduce((sum, p) => sum + p.amount, 0);
  }
  return invoice.paid ? invoice.amount : 0;
}

/** Still owed, in dollars. Never negative — an overpayment reads as zero due. */
export function balanceDue(invoice: Invoice): number {
  return Math.max(0, invoice.amount - amountPaid(invoice));
}

export function isFullyPaid(invoice: Invoice): boolean {
  return balanceDue(invoice) <= PAID_EPSILON;
}

/** Something has been received, but not everything. */
export function isPartlyPaid(invoice: Invoice): boolean {
  return amountPaid(invoice) > PAID_EPSILON && !isFullyPaid(invoice);
}

// Monotonic within a run so several payments recorded in the same millisecond
// can't collide on `p<Date.now()>`. Mirrors newCustomerId in storage/customers.
let _pidCounter = 0;
export function newPaymentId(): string {
  _pidCounter += 1;
  return `p${Date.now()}_${_pidCounter}`;
}

/**
 * Convert a legacy invoice's implied payment into a real ledger entry.
 *
 * CRITICAL: amountPaid falls back to `paid`/`amount` only while the ledger is
 * empty. Appending to a legacy paid invoice without calling this first would
 * drop the original amount from the total the moment the array became
 * non-empty. Any function that starts a ledger must go through here.
 *
 * Returns the existing ledger untouched when one is already present.
 */
export function materializeLegacyLedger(invoice: Invoice): Payment[] {
  if (invoice.payments && invoice.payments.length > 0) return invoice.payments;
  if (!invoice.paid) return [];
  return [
    {
      id: `legacy_${invoice.id}`,
      amount: invoice.amount,
      date: invoice.paidAt || invoice.due,
      method: "other",
      note: "Recorded before payment history was itemised",
    },
  ];
}

/** Recompute the legacy `paid`/`paidAt` fields from a ledger. */
function withDerivedPaidFields(invoice: Invoice, payments: Payment[]): Invoice {
  const next: Invoice = { ...invoice, payments };
  const settled = balanceDue(next) <= PAID_EPSILON;
  if (settled) {
    // paidAt is the date of the payment that closed the balance — walk the
    // ledger in order and stop at the one that crossed the line.
    let running = 0;
    let closingDate = payments.length ? payments[payments.length - 1].date : invoice.due;
    for (const p of payments) {
      running += p.amount;
      if (running >= invoice.amount - PAID_EPSILON) {
        closingDate = p.date;
        break;
      }
    }
    return { ...next, paid: true, paidAt: closingDate };
  }
  const rest: Invoice = { ...next, paid: false };
  delete rest.paidAt;
  return rest;
}

/**
 * Append a payment and recompute paid/paidAt. Pure — returns a new Invoice and
 * does not save or sync. Callers hand the result to saveInvoices themselves.
 */
export function applyPayment(invoice: Invoice, payment: Payment): Invoice {
  const ledger = [...materializeLegacyLedger(invoice), payment];
  return withDerivedPaidFields(invoice, ledger);
}

/**
 * Remove a payment by id and recompute paid/paidAt. Removing the payment that
 * settled an invoice legitimately flips it back to unpaid — the UI confirms
 * that consequence with the user before calling this.
 */
export function removePayment(invoice: Invoice, paymentId: string): Invoice {
  const ledger = materializeLegacyLedger(invoice).filter((p) => p.id !== paymentId);
  return withDerivedPaidFields(invoice, ledger);
}
