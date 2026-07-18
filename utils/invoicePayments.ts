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

/**
 * Deterministic chronological ordering. Code-unit comparison, NOT localeCompare:
 * localeCompare is locale/ICU-dependent and Hermes may lack full ICU, so two
 * devices could otherwise sort the same ledger differently and derive different
 * paidAt values. Dates are "YYYY-MM-DD", so lexicographic equals chronological.
 */
function comparePayments(a: Payment, b: Payment): number {
  if (a.date !== b.date) return a.date < b.date ? -1 : 1;
  if (a.id !== b.id) return a.id < b.id ? -1 : 1;
  return 0;
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
    // paidAt is the date of the payment that closed the balance — walk a
    // CHRONOLOGICALLY sorted copy of the ledger (never the stored array,
    // whose order is not guaranteed: applyPayment appends; mergePaymentLedgers
    // stores its union sorted) and stop at the payment that
    // crosses the line. This must be order-independent from how the payments
    // were recorded: a backdated payment must not report the invoice settled
    // before all the money had actually arrived. Example: $400 dated
    // 2026-07-20 recorded first, then $600 backdated to 2026-07-01, on a
    // $1000 invoice — on 2026-07-01 only $600 had arrived, so the invoice
    // wasn't settled yet; it settled on 2026-07-20, when the last dollar
    // needed actually showed up. Walking insertion order would have reported
    // 2026-07-01, a date on which the balance was not yet paid.
    const chronological = [...payments].sort(comparePayments);
    let running = 0;
    let closingDate = chronological[chronological.length - 1].date;
    for (const p of chronological) {
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
 *  - On an id collision the remote entry wins. For `p…` (device) and `stripe_…`
 *    (webhook) namespaces, a shared id means the same payment. The `legacy_…`
 *    namespace is the exception: it synthesizes from the invoice's mutable
 *    `amount`/`paidAt`, so two copies that diverged can emit the same id with
 *    different content. This is mostly self-correcting (merged result gets both
 *    scalars and the remote legacy entry), except when one side is paid and the
 *    other is unpaid with divergent `amount`: the surviving entry carries one
 *    side's amount while `invoice.amount` comes from the other, making merge
 *    commutative in payments membership but not in the `paid` flag.
 *  - The union is sorted canonically by (date, id) using comparePayments
 *    (code-unit comparison, not localeCompare — see that function's doc).
 *    withDerivedPaidFields now derives `paidAt` chronologically regardless of
 *    array order, so this sort is no longer load-bearing for `paidAt`
 *    agreement between devices — but it keeps the stored `payments` array
 *    itself canonical and stable, which every other order-sensitive consumer
 *    (equality checks, snapshot-style tests) relies on. Canonical ordering
 *    applies to merges only — applyPayment still appends.
 *
 * Pure: neither input is mutated.
 */
export function mergePaymentLedgers(local: Invoice, remote: Invoice): Invoice {
  const byId = new Map<string, Payment>();
  for (const p of materializeLegacyLedger(local)) byId.set(p.id, p);
  for (const p of materializeLegacyLedger(remote)) byId.set(p.id, p);

  const merged = [...byId.values()].sort(comparePayments);

  return withDerivedPaidFields(remote, merged);
}
