// __tests__/invoicePaymentsLegacyEquivalence.test.js
// The safety net for the phase-4 Money-tab sweep.
//
// Every analytics site currently computes collected revenue as
//   inv.paid ? inv.amount : 0,  bucketed on (inv.paidAt || inv.due)
// and outstanding as
//   !inv.paid ? inv.amount : 0.
//
// Phase 4 replaces those with amountPaid/balanceDue/collectedInRange. On
// invoices that carry no ledger — which is all existing data — the results
// must be IDENTICAL, not merely close. This enumerates the legacy shapes and
// pins that equality. If this file ever fails, the sweep changed real numbers
// and the change is wrong.

import {
  amountPaid,
  balanceDue,
  isFullyPaid,
  collectedInRange,
} from "../utils/invoicePayments";
import { isInRange } from "../utils/moneyUtils";

// The old formulas, written out verbatim so the comparison is explicit.
const legacyCollected = (inv) => (inv.paid ? inv.amount : 0);
const legacyOutstanding = (inv) => (!inv.paid ? inv.amount : 0);
const legacyInRange = (inv, start, end) =>
  inv.paid && isInRange(inv.paidAt || inv.due, start, end) ? inv.amount : 0;

// Every combination of the fields that vary on legacy invoices.
const AMOUNTS = [0, 0.5, 100, 1234.56, 99999];
const PAID = [true, false];
const PAID_AT = ["2026-07-15", undefined];
const DUES = ["2026-07-20", "2026-06-01"];

const legacyInvoices = [];
let n = 0;
for (const amount of AMOUNTS) {
  for (const paid of PAID) {
    for (const paidAt of PAID_AT) {
      for (const due of DUES) {
        n += 1;
        legacyInvoices.push({
          id: `i${n}`,
          customer: "Acme",
          number: `INV-${n}`,
          desc: "",
          email: "",
          phone: "",
          amount,
          paid,
          paidAt,
          due,
          // No `payments` key at all — this is the whole point.
        });
      }
    }
  }
}

describe("legacy equivalence", () => {
  test("the fixture covers every legacy shape", () => {
    expect(legacyInvoices).toHaveLength(
      AMOUNTS.length * PAID.length * PAID_AT.length * DUES.length,
    );
  });

  test.each(legacyInvoices.map((inv) => [inv.number, inv]))(
    "%s — amountPaid matches the old collected formula",
    (_label, inv) => {
      expect(amountPaid(inv)).toBe(legacyCollected(inv));
    },
  );

  test.each(legacyInvoices.map((inv) => [inv.number, inv]))(
    "%s — balanceDue matches the old outstanding formula",
    (_label, inv) => {
      expect(balanceDue(inv)).toBe(legacyOutstanding(inv));
    },
  );

  test.each(legacyInvoices.map((inv) => [inv.number, inv]))(
    "%s — isFullyPaid matches the old paid flag",
    (_label, inv) => {
      // A zero-amount invoice is trivially settled either way; every other
      // invoice must agree with its stored boolean.
      if (inv.amount === 0) return;
      expect(isFullyPaid(inv)).toBe(inv.paid);
    },
  );

  test("collectedInRange matches the old date-bucketed formula over the whole set", () => {
    const start = new Date(2026, 6, 1);
    const end = new Date(2026, 6, 31);
    const expected = legacyInvoices.reduce((sum, inv) => sum + legacyInRange(inv, start, end), 0);
    expect(collectedInRange(legacyInvoices, start, end)).toBe(expected);
  });
});
