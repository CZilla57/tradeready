// __fixtures__/paymentVectors.js
// The single source of truth that BOTH payment-math implementations are tested
// against: utils/invoicePayments.ts (app) and backend/lib/paymentMath.js
// (Vercel functions). They are separate packages and cannot share code, so
// __tests__/paymentMathParity.test.js runs both over these vectors and asserts
// they agree. If you change one implementation, change the other or the gate
// fails.
//
// Plain CommonJS so the backend copy can require it without transpilation.

const invoice = (over) => ({
  id: "i1", customer: "Acme", number: "INV-1", desc: "", email: "", phone: "",
  amount: 1000, due: "2026-07-01", paid: false, ...over,
});

const p = (over) => ({ id: "p1", amount: 500, date: "2026-07-01", method: "cash", ...over });

const paymentVectors = [
  {
    label: "legacy unpaid — no ledger",
    invoice: invoice({ paid: false }),
    expectedAmountPaid: 0, expectedBalance: 1000, expectedFullyPaid: false,
  },
  {
    label: "legacy paid — no ledger falls back to the flag",
    invoice: invoice({ paid: true }),
    expectedAmountPaid: 1000, expectedBalance: 0, expectedFullyPaid: true,
  },
  {
    label: "empty ledger array still falls back to the flag",
    invoice: invoice({ paid: true, payments: [] }),
    expectedAmountPaid: 1000, expectedBalance: 0, expectedFullyPaid: true,
  },
  {
    label: "single partial payment",
    invoice: invoice({ payments: [p({ amount: 400 })] }),
    expectedAmountPaid: 400, expectedBalance: 600, expectedFullyPaid: false,
  },
  {
    label: "two payments settling the balance",
    invoice: invoice({ payments: [p({ id: "p1", amount: 400 }), p({ id: "p2", amount: 600 })] }),
    expectedAmountPaid: 1000, expectedBalance: 0, expectedFullyPaid: true,
  },
  {
    label: "ledger wins over a stale paid flag",
    invoice: invoice({ paid: true, payments: [p({ amount: 400 })] }),
    expectedAmountPaid: 400, expectedBalance: 600, expectedFullyPaid: false,
  },
  {
    label: "overpayment clamps the balance at zero",
    invoice: invoice({ payments: [p({ amount: 1200 })] }),
    expectedAmountPaid: 1200, expectedBalance: 0, expectedFullyPaid: true,
  },
  {
    label: "sub-cent shortfall is settled (epsilon)",
    invoice: invoice({ amount: 100, payments: [p({ amount: 99.997 })] }),
    expectedAmountPaid: 99.997, expectedBalance: 100 - 99.997, expectedFullyPaid: true,
  },
  {
    // Sits EXACTLY on the epsilon threshold: balanceDue is the literal 0.005,
    // which rounds to the identical double as PAID_EPSILON. This is what pins
    // the comparison as `<=` rather than `<` — without it, flipping that one
    // operator in either implementation passes the whole vector set.
    label: "balance exactly at the epsilon boundary is settled",
    invoice: invoice({ amount: 0.005, paid: false }),
    expectedAmountPaid: 0,
    expectedBalance: 0.005,
    expectedFullyPaid: true,
  },
  {
    label: "voided payment contributes nothing",
    invoice: invoice({ payments: [p({ id: "p1", amount: 400, voidedAt: "2026-07-22" })] }),
    expectedAmountPaid: 0, expectedBalance: 1000, expectedFullyPaid: false,
  },
  {
    label: "voided payment among live ones",
    invoice: invoice({
      payments: [p({ id: "p1", amount: 400 }), p({ id: "p2", amount: 600, voidedAt: "2026-07-22" })],
    }),
    expectedAmountPaid: 400, expectedBalance: 600, expectedFullyPaid: false,
  },
  {
    label: "every payment voided does NOT fall back to the legacy flag",
    invoice: invoice({ paid: true, payments: [p({ id: "p1", amount: 1000, voidedAt: "2026-07-22" })] }),
    expectedAmountPaid: 0, expectedBalance: 1000, expectedFullyPaid: false,
  },
  {
    // Pins materializeLegacyLedger's synthesized `date: invoice.paidAt ||
    // invoice.due` precedence. Every other legacy-paid vector above leaves
    // paidAt unset, so only the `due` fallback branch is exercised — a drift
    // where an implementation transcribed the rule as `invoice.due ||
    // invoice.paidAt` would still pass the whole vector set. Here paidAt and
    // due are set to DIFFERENT months, so precedence is observable: the
    // parity test's `materializeLegacyLedger` `toEqual` assertion pins the
    // synthesized entry's `date` to paidAt ("2026-06-15"), not due
    // ("2026-07-01").
    label: "legacy paid — paidAt takes precedence over due for the synthesized date",
    invoice: invoice({ paid: true, paidAt: "2026-06-15", due: "2026-07-01" }),
    expectedAmountPaid: 1000, expectedBalance: 0, expectedFullyPaid: true,
  },
];

module.exports = { paymentVectors };
