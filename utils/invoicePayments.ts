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

import type { DateString, Invoice, Payment } from "../types/models";
import { isInRange } from "./moneyUtils";

/**
 * Balances are floats, so "settled" means "within half a cent", never === 0.
 * 0.1 + 0.2 !== 0.3 in IEEE 754 and invoices really do split into thirds.
 */
export const PAID_EPSILON = 0.005;

/**
 * Coerce a persisted amount to a finite number.
 *
 * Invoice and payment amounts are supposed to be numbers, and both invoice
 * creation screens validate that. But this data round-trips through JSON blobs
 * in Supabase and through older app versions, and six money call sites already
 * carried defensive `parseFloat(String(x)) || 0` wrappers while nine did not.
 * Rather than scatter that further, the derivations take responsibility: a
 * malformed amount contributes zero instead of concatenating a string or
 * poisoning the whole sum with NaN.
 *
 * INVARIANT: every read of invoice.amount or payment.amount in this module
 * goes through here — for arithmetic, comparison, or accumulation alike.
 * This was applied piecemeal at first and each pass missed a site, producing
 * functions in this same file that disagreed about whether an invoice was
 * settled. If you add a function that touches an amount, coerce it here too.
 *
 * Exported for utils/csvExport.ts, whose income rows must coerce amounts
 * identically or the export's sum-equivalence with collectedInRange breaks.
 */
export function toAmount(value: unknown): number {
  const n = typeof value === "number" ? value : parseFloat(String(value));
  return Number.isFinite(n) ? n : 0;
}

/** Total received against this invoice, in dollars. */
export function amountPaid(invoice: Invoice): number {
  const ledger = invoice.payments;
  if (ledger && ledger.length > 0) {
    // Voided entries stay in the ledger (so a union can't resurrect them) but
    // contribute nothing.
    return ledger.reduce((sum, p) => (p.voidedAt ? sum : sum + toAmount(p.amount)), 0);
  }
  return invoice.paid ? toAmount(invoice.amount) : 0;
}

/** Still owed, in dollars. Never negative — an overpayment reads as zero due. */
export function balanceDue(invoice: Invoice): number {
  return Math.max(0, toAmount(invoice.amount) - amountPaid(invoice));
}

export function isFullyPaid(invoice: Invoice): boolean {
  return balanceDue(invoice) <= PAID_EPSILON;
}

/** Something has been received, but not everything. */
export function isPartlyPaid(invoice: Invoice): boolean {
  return amountPaid(invoice) > PAID_EPSILON && !isFullyPaid(invoice);
}

/**
 * Money received BEYOND what the invoice was for, in dollars. Zero normally.
 *
 * balanceDue clamps at zero, which is right for "what's still owed" but means
 * an overpayment vanishes from every surface. A customer who pays a
 * full-amount link after already paying a deposit hands over more than the
 * invoice was for, and the tradesperson needs to know they owe it back.
 *
 * Voided entries are excluded, and a legacy invoice always reports zero — its
 * implied payment is exactly its amount by construction.
 */
export function overpaidAmount(invoice: Invoice): number {
  return Math.max(0, amountPaid(invoice) - toAmount(invoice.amount));
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
      amount: toAmount(invoice.amount),
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
  const collected = payments.reduce((sum, p) => (p.voidedAt ? sum : sum + toAmount(p.amount)), 0);
  const settled = payments.length > 0 && toAmount(invoice.amount) - collected <= PAID_EPSILON;
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
      if (p.voidedAt) continue;
      running += toAmount(p.amount);
      if (running >= toAmount(invoice.amount) - PAID_EPSILON) {
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
 * Re-derive `paid`/`paidAt` from the invoice's own ledger.
 *
 * Call this after changing a field the derivation depends on — notably
 * `amount`. Editing an amount while carrying the old `paid` forward is how the
 * flag drifts out of sync with the ledger.
 *
 * A legacy invoice (no ledger) is returned UNCHANGED: with an empty ledger the
 * stored flag IS the source of truth, and re-deriving would wrongly un-pay it.
 */
export function reconcilePaidFields(invoice: Invoice): Invoice {
  const ledger = invoice.payments;
  if (!ledger || ledger.length === 0) return invoice;
  return withDerivedPaidFields(invoice, ledger);
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
 * Void a payment and recompute paid/paidAt. Pure — returns a new Invoice.
 *
 * The entry is KEPT and flagged rather than removed: a server-side union
 * cannot tell "unknown to me" from "deleted by me", so deletion has to be
 * data. Voiding is idempotent — re-voiding preserves the original void date —
 * and irreversible; to correct one, record a new payment.
 *
 * Voiding the payment that settled an invoice legitimately flips it back to
 * unpaid. The UI confirms that consequence before calling this.
 */
export function voidPayment(invoice: Invoice, paymentId: string, voidedAt: DateString): Invoice {
  const ledger = materializeLegacyLedger(invoice).map((p) =>
    p.id === paymentId && !p.voidedAt ? { ...p, voidedAt } : p,
  );
  return withDerivedPaidFields(invoice, ledger);
}

/**
 * The payments received in a window. Legacy invoices resolve through
 * materializeLegacyLedger, so a paid one buckets on `paidAt || due` — exactly
 * the rule the Money tab already applied before the ledger existed.
 *
 * KEEPS voided entries in the returned array — a payment-history UI needs
 * them so it can render a voided payment struck through rather than have it
 * silently disappear. Any caller that SUMS this result must filter voided
 * entries itself (see collectedInRange, which does).
 */
export function paymentsInRange(invoice: Invoice, start: Date, end: Date): Payment[] {
  return materializeLegacyLedger(invoice).filter((p) => isInRange(p.date, start, end));
}

/** Total collected across a set of invoices in a window, bucketed by payment date. */
export function collectedInRange(invoices: Invoice[], start: Date, end: Date): number {
  let total = 0;
  for (const inv of invoices) {
    for (const p of paymentsInRange(inv, start, end)) {
      if (p.voidedAt) continue;
      total += toAmount(p.amount);
    }
  }
  return total;
}

/** Round to whole cents. Requested amounts become Stripe unit_amounts and
 * cached `paymentLinkAmount`s that later equality-check against a recomputed
 * value — rounding at the boundary is what makes those comparisons exact. */
export function roundToCents(n: number): number {
  return Math.round(n * 100) / 100;
}

/** How a deposit was asked for: a share of the invoice total, or a flat sum. */
export type DepositSpec = { percent: number } | { fixed: number };

/**
 * Resolve a requested deposit to the dollar amount a payment link should
 * charge.
 *
 * Percent applies to the INVOICE TOTAL, not the remaining balance — "50% up
 * front" in trade usage means half the job price. The resolved amount (percent
 * or fixed alike) is then clamped to the remaining balance, so a request can
 * never ask for more than is still owed — e.g. a 50% deposit request on an
 * invoice already 60% paid resolves to the 40% that remains.
 *
 * Returns 0 for nonsense input (non-finite, zero, negative) — callers treat 0
 * as "nothing to request" and disable link generation.
 */
export function resolveDepositAmount(invoice: Invoice, spec: DepositSpec): number {
  const requested =
    "percent" in spec
      ? (toAmount(invoice.amount) * toAmount(spec.percent)) / 100
      : toAmount(spec.fixed);
  if (!(requested > 0)) return 0;
  return roundToCents(Math.min(requested, balanceDue(invoice)));
}

/**
 * Has the customer paid at least what the deposit request asked for?
 * False when no deposit was ever requested — "satisfied" implies an ask.
 */
export function isDepositSatisfied(invoice: Invoice): boolean {
  const request = invoice.depositRequest;
  if (!request) return false;
  return amountPaid(invoice) >= toAmount(request.amount) - PAID_EPSILON;
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
 *  - On an id collision, VOID WINS regardless of side: if either copy has
 *    `voidedAt` set, the surviving entry is the voided one. `voidedAt` is
 *    irreversible, so whichever copy carries it is unambiguously the later
 *    state — that is what keeps this union commutative regardless of arrival
 *    order. When BOTH copies are voided, the EARLIEST void date wins (see
 *    pickSurvivingPayment) — the first void is the real one, and picking a
 *    side-independent value keeps the merge commutative even in that case.
 *    Otherwise the remote entry wins. For `p…` (device) and `stripe_…`
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

/**
 * Pick the surviving entry when both sides carry the same payment id.
 *
 * Void wins, because voidedAt is irreversible — whichever copy has it is the
 * later state. When BOTH are voided, the EARLIEST void date wins: the first
 * void is the real one, and picking a side-independent value is what keeps the
 * merge commutative. A "remote wins" tie-break here would make merge(a,b) and
 * merge(b,a) store different bytes and let two devices ping-pong writes.
 *
 * On an EXACT tie (both voidedAt values identical, entries otherwise
 * differing) `incoming` wins. This is pinned to match the SQL union trigger's
 * `order by voidedAt asc, prio desc`, which also keeps NEW (incoming) on a
 * tie — using `<` rather than `<=` here is what makes that true. Nothing about
 * this tie case moves money either way (voided entries contribute nothing to
 * amountPaid), but the two implementations must still store the same bytes.
 *
 * NOTE: the Postgres union trigger MUST use this same earliest-void rule
 * (including the exact-tie case), or the server and the device will disagree
 * on the stored void date.
 */
function pickSurvivingPayment(existing: Payment | undefined, incoming: Payment): Payment {
  if (!existing) return incoming;
  if (existing.voidedAt && incoming.voidedAt) {
    return existing.voidedAt < incoming.voidedAt ? existing : incoming;
  }
  if (existing.voidedAt) return existing;
  return incoming;
}

export function mergePaymentLedgers(local: Invoice, remote: Invoice): Invoice {
  const byId = new Map<string, Payment>();
  for (const p of materializeLegacyLedger(local)) byId.set(p.id, p);
  for (const p of materializeLegacyLedger(remote)) {
    byId.set(p.id, pickSurvivingPayment(byId.get(p.id), p));
  }

  const merged = [...byId.values()].sort(comparePayments);

  return withDerivedPaidFields(remote, merged);
}

/**
 * This invoice's payments as the UI should display them.
 *
 * An alias for materializeLegacyLedger, which is named for WHY it exists
 * rather than what callers want from it. A legacy paid invoice yields its one
 * synthesized `legacy_<id>` entry; an invoice with a real ledger yields a copy
 * of it. Voided entries ARE included — the history UI renders them struck
 * through, and hiding them would defeat the point of voiding rather than
 * deleting. Anything SUMMING this list must skip voided entries itself.
 */
export const effectivePayments = materializeLegacyLedger;

/**
 * Record a single payment for whatever is still owed, settling the invoice.
 *
 * This is what the "Mark paid" button does. It must go through applyPayment
 * rather than setting `paid: true` directly: a bare flag write is discarded by
 * the ledger merge on the next sync once an invoice has any recorded payment,
 * silently reverting the user's tap.
 *
 * A no-op on an already-settled invoice — returns it unchanged rather than
 * appending a zero-amount entry.
 */
export function settleRemaining(invoice: Invoice, date: DateString): Invoice {
  if (isFullyPaid(invoice)) return invoice;
  return applyPayment(invoice, {
    id: newPaymentId(),
    amount: balanceDue(invoice),
    date,
    method: "other",
  });
}

/**
 * Total collected in each of several windows, walking every ledger ONCE.
 *
 * Equivalent to mapping collectedInRange over the ranges (there is a test
 * pinning that), but the bucketed charts need 6 and 24 windows respectively and
 * the naive form re-materialises every invoice's ledger once per window.
 *
 * Voided payments are excluded, matching collectedInRange. A payment falling in
 * two overlapping ranges counts in both — that is the caller's business.
 *
 * INVARIANT: `Payment.date` must remain a date-only "YYYY-MM-DD" string. Some
 * callers build month-end range boundaries as `new Date(y, m + 1, 0)` — local
 * midnight on the last day of the month, not 23:59:59 — which only matches every
 * date-only payment because isInRange compares date-only strings. A timestamped
 * payment date would risk dropping last-day-of-month payments from these buckets.
 */
export function collectedByPeriod(
  invoices: Invoice[],
  ranges: { start: Date; end: Date }[],
): number[] {
  const totals = new Array<number>(ranges.length).fill(0);
  for (const invoice of invoices) {
    for (const p of effectivePayments(invoice)) {
      if (p.voidedAt) continue;
      const amount = toAmount(p.amount);
      for (let i = 0; i < ranges.length; i++) {
        if (isInRange(p.date, ranges[i].start, ranges[i].end)) totals[i] += amount;
      }
    }
  }
  return totals;
}
