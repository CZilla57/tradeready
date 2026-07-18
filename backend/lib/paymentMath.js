// backend/lib/paymentMath.js
// Pure payment-ledger math for the backend. MIRRORS utils/invoicePayments.ts —
// duplicated because backend/ is a separate CommonJS package and cannot import
// the app's TypeScript util (same constraint as backend/lib/overdue.js).
//
// THE TWO COPIES ARE PINNED TOGETHER by __tests__/paymentMathParity.test.js,
// which runs both over __fixtures__/paymentVectors.js. If you change one,
// change the other — the gate will catch you if you don't.
//
// materializeLegacyLedger is mirrored too (byte-identical synthesized id),
// since any backend code that STARTS a ledger (e.g. the Stripe webhook) must
// route through it exactly as the device does — see the CRITICAL note on the
// TS version.
//
// Deliberately does NOT implement paidAt derivation or ledger merging: once
// the Postgres union trigger is applied, the server will not need them (the
// trigger will union ledgers, and the device derives paidAt). The trigger does
// NOT exist yet: today the server implements a plain read-modify-write, and a
// concurrent ledger write landing between reads is clobbered, not merged.
// Keeping the mirror small keeps the drift surface small.

const PAID_EPSILON = 0.005;

/**
 * Coerce a persisted amount to a finite number. Mirrors utils/invoicePayments.ts
 * `toAmount` — see that copy's doc comment for why this exists: a malformed
 * amount contributes zero instead of concatenating a string or poisoning the
 * whole sum with NaN.
 *
 * INVARIANT: every read of invoice.amount or payment.amount in this file
 * goes through here, same as the TS copy. Keep both sweeps in lockstep —
 * paymentMathParity.test.js will catch a divergence.
 */
function toAmount(value) {
  const n = typeof value === "number" ? value : parseFloat(String(value));
  return Number.isFinite(n) ? n : 0;
}

/**
 * Total received, in dollars. Voided entries stay in the ledger but contribute
 * nothing. An invoice with no ledger falls back to the legacy `paid` flag.
 */
function amountPaid(invoice) {
  const ledger = invoice && invoice.payments;
  if (ledger && ledger.length > 0) {
    return ledger.reduce((sum, p) => (p && p.voidedAt ? sum : sum + toAmount(p.amount)), 0);
  }
  return invoice && invoice.paid ? toAmount(invoice.amount) : 0;
}

function balanceDue(invoice) {
  return Math.max(0, toAmount(invoice.amount) - amountPaid(invoice));
}

function isFullyPaid(invoice) {
  return balanceDue(invoice) <= PAID_EPSILON;
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
function materializeLegacyLedger(invoice) {
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

module.exports = { PAID_EPSILON, amountPaid, balanceDue, isFullyPaid, materializeLegacyLedger };
