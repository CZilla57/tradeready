// __tests__/jobDunningParity.test.js
// ANTI-DRIFT GATE, mirrors paymentMathParity.test.js's pattern. Client
// (utils/jobStatus.ts isJobDunningEligible) and backend
// (backend/lib/selectInvoicesToRemind.js isJobDunningEligible) implement the
// same dunning-eligibility rule and cannot share code — backend/ is a
// separate CommonJS package. Changing one without mirroring it in the other
// fails here immediately.

import { isJobDunningEligible } from "../utils/jobStatus";

const backend = require("../backend/lib/selectInvoicesToRemind");

describe.each([
  ["undefined status (no linked job) is eligible", undefined, true],
  ["lead is not eligible", "lead", false],
  ["estimate_sent is not eligible", "estimate_sent", false],
  ["approved is not eligible", "approved", false],
  ["scheduled is not eligible", "scheduled", false],
  ["in_progress is not eligible", "in_progress", false],
  ["declined is not eligible", "declined", false],
  ["complete is eligible", "complete", true],
  ["invoiced is eligible", "invoiced", true],
  ["paid is eligible", "paid", true],
])("%s", (_label, status, expected) => {
  test("app implementation", () => {
    expect(isJobDunningEligible(status)).toBe(expected);
  });

  test("backend implementation", () => {
    expect(backend.isJobDunningEligible(status)).toBe(expected);
  });

  test("the two implementations agree with each other", () => {
    expect(backend.isJobDunningEligible(status)).toBe(isJobDunningEligible(status));
  });
});
