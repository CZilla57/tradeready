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
import { isInRange } from "./moneyUtils";

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
 * Returns a copy of the existing ledger when one is already present.
 */
export function materializeLegacyLedger(invoice: Invoice): Payment[] {
  if (invoice.payments && invoice.payments.length > 0) return [...invoice.payments];
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
  // Derive `settled` from the ledger itself, not from amountPaid(next) — that
  // object still carries the input's stale `paid` flag, so an empty ledger
  // would re-enter the LEGACY FALLBACK and read back the old amount instead
  // of zero. The `payments.length > 0` guard also stops a $0 invoice with an
  // empty ledger from being auto-marked paid.
  const collected = payments.reduce((sum, p) => sum + p.amount, 0);
  const settled = payments.length > 0 && invoice.amount - collected <= PAID_EPSILON;
  const next: Invoice = { ...invoice, payments };
  if (settled) {
    // paidAt is the date of the payment that closed the balance — walk the
    // ledger in INSERTION order (not date order) and stop at the one that
    // crossed the line. A backdated payment recorded after a later-dated one
    // therefore yields a paidAt earlier than a payment already in the
    // ledger — that is intentional: paidAt means "the payment that closed
    // the balance", not "the latest date in the ledger".
    let running = 0;
    let closingDate = payments[payments.length - 1].date;
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
 *
 * IDEMPOTENT by payment id: if the invoice's effective ledger already contains
 * an entry whose `id` equals `payment.id`, the existing entry WINS and the new
 * one is not appended. This guards against silent double-counting when sync
 * merges two devices' ledgers by UNION ON `id` — a retry or webhook re-delivery
 * that appends a duplicate id would be silently collapsed by the union, causing
 * the total to drop. By rejecting duplicates here instead, we ensure the ledger
 * remains idempotent to any caller pattern.
 */
export function applyPayment(invoice: Invoice, payment: Payment): Invoice {
  const ledger = materializeLegacyLedger(invoice);
  // Check if this payment id already exists in the effective ledger
  if (ledger.some((p) => p.id === payment.id)) {
    // Duplicate id: existing entry wins, return invoice with recalculated fields
    return withDerivedPaidFields(invoice, ledger);
  }
  // New id: append and proceed
  const nextLedger = [...ledger, payment];
  return withDerivedPaidFields(invoice, nextLedger);
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

/**
 * The payments received in a window. Legacy invoices resolve through
 * materializeLegacyLedger, so a paid one buckets on `paidAt || due` — exactly
 * the rule the Money tab already applied before the ledger existed.
 */
export function paymentsInRange(invoice: Invoice, start: Date, end: Date): Payment[] {
  return materializeLegacyLedger(invoice).filter((p) => isInRange(p.date, start, end));
}

/** Total collected across a set of invoices in a window, bucketed by payment date. */
export function collectedInRange(invoices: Invoice[], start: Date, end: Date): number {
  let total = 0;
  for (const inv of invoices) {
    for (const p of paymentsInRange(inv, start, end)) total += p.amount;
  }
  return total;
}

/**
 * Combine two versions of the same invoice, keeping the payments from BOTH.
 *
 * This exists because sync's pullRemote used to replace whole records
 * (last-write-wins). That is safe for a boolean `paid` — either side yields the
 * same answer — but with a ledger it destroys money: a payment the Stripe
 * webhook wrote to the cloud vanishes if the device happened to edit the same
 * invoice, or vice versa.
 *
 * Semantics:
 *  - Scalar fields take the REMOTE value (unchanged last-write-wins).
 *  - Payments are UNIONED by id. Both sides are materialized first, so a legacy
 *    invoice contributes its implied entry under the deterministic id
 *    `legacy_<invoice.id>`. That determinism is load-bearing: two legacy copies
 *    synthesize the identical entry and collapse to one. Skipping the
 *    materialize step would union two legacy invoices to [] and silently
 *    un-pay them.
 *  - On an id collision the remote entry wins. Unobservable in practice: the id
 *    namespaces (`p…` device, `stripe_…` webhook, `legacy_…` synthetic) mean a
 *    shared id is the same payment.
 *  - The union is sorted canonically by (date, id). Phase 1 derives `paidAt`
 *    from the closing payment in INSERTION order, so an unsorted union would
 *    let two devices disagree on `paidAt`. Sorting makes this merge genuinely
 *    commutative. Canonical ordering applies to merges only — applyPayment
 *    still appends.
 *
 * Pure: neither input is mutated.
 */
export function mergePaymentLedgers(local: Invoice, remote: Invoice): Invoice {
  const byId = new Map<string, Payment>();
  for (const p of materializeLegacyLedger(local)) byId.set(p.id, p);
  for (const p of materializeLegacyLedger(remote)) byId.set(p.id, p);

  const merged = [...byId.values()].sort((a, b) =>
    a.date === b.date ? a.id.localeCompare(b.id) : a.date.localeCompare(b.date),
  );

  return withDerivedPaidFields(remote, merged);
}
