// backend/lib/paymentMath.js
// Pure payment-ledger math for the backend. MIRRORS utils/invoicePayments.ts —
// duplicated because backend/ is a separate CommonJS package and cannot import
// the app's TypeScript util (same constraint as backend/lib/overdue.js).
//
// THE TWO COPIES ARE PINNED TOGETHER by __tests__/paymentMathParity.test.js,
// which runs both over __fixtures__/paymentVectors.js. If you change one,
// change the other — the gate will catch you if you don't.
//
// Deliberately does NOT implement paidAt derivation or ledger merging: the
// server never needs them (the Postgres trigger unions ledgers, and the device
// derives paidAt). Keeping the mirror small keeps the drift surface small.

const PAID_EPSILON = 0.005;

/**
 * Total received, in dollars. Voided entries stay in the ledger but contribute
 * nothing. An invoice with no ledger falls back to the legacy `paid` flag.
 */
function amountPaid(invoice) {
  const ledger = invoice && invoice.payments;
  if (ledger && ledger.length > 0) {
    return ledger.reduce((sum, p) => (p && p.voidedAt ? sum : sum + p.amount), 0);
  }
  return invoice && invoice.paid ? invoice.amount : 0;
}

function balanceDue(invoice) {
  return Math.max(0, invoice.amount - amountPaid(invoice));
}

function isFullyPaid(invoice) {
  return balanceDue(invoice) <= PAID_EPSILON;
}

module.exports = { PAID_EPSILON, amountPaid, balanceDue, isFullyPaid };
