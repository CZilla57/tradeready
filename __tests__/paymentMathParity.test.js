// __tests__/paymentMathParity.test.js
// ANTI-DRIFT GATE. utils/invoicePayments.ts (app, TypeScript) and
// backend/lib/paymentMath.js (Vercel functions, CommonJS) implement the same
// money rules and cannot share code — backend/ is a separate package.
//
// This runs BOTH over the same vectors and asserts they agree with each other
// AND with the expected values. Changing one implementation without mirroring
// it in the other fails here immediately. That is the entire point of the file;
// do not weaken it to make a change land.

import { amountPaid, balanceDue, isFullyPaid, PAID_EPSILON } from "../utils/invoicePayments";

const backend = require("../backend/lib/paymentMath");
const { paymentVectors } = require("../__fixtures__/paymentVectors");

describe("the two implementations agree on the epsilon", () => {
  test("PAID_EPSILON matches", () => {
    expect(backend.PAID_EPSILON).toBe(PAID_EPSILON);
  });
});

describe.each(paymentVectors.map((v) => [v.label, v]))("%s", (_label, v) => {
  test("app implementation matches the expected values", () => {
    expect(amountPaid(v.invoice)).toBeCloseTo(v.expectedAmountPaid, 6);
    expect(balanceDue(v.invoice)).toBeCloseTo(v.expectedBalance, 6);
    expect(isFullyPaid(v.invoice)).toBe(v.expectedFullyPaid);
  });

  test("backend implementation matches the expected values", () => {
    expect(backend.amountPaid(v.invoice)).toBeCloseTo(v.expectedAmountPaid, 6);
    expect(backend.balanceDue(v.invoice)).toBeCloseTo(v.expectedBalance, 6);
    expect(backend.isFullyPaid(v.invoice)).toBe(v.expectedFullyPaid);
  });

  test("the two implementations agree with each other exactly", () => {
    expect(backend.amountPaid(v.invoice)).toBe(amountPaid(v.invoice));
    expect(backend.balanceDue(v.invoice)).toBe(balanceDue(v.invoice));
    expect(backend.isFullyPaid(v.invoice)).toBe(isFullyPaid(v.invoice));
  });
});
