import { buildReadme, buildSummary } from "../utils/accountingPackage";

const s = buildSummary({ invoices: [], expenses: [], trips: [], customers: [], jobNameById: {} },
  new Date(2026, 0, 1), new Date(2026, 11, 31, 23, 59, 59));

test("README names the control files and states the cash-basis convention", () => {
  const txt = buildReadme(s);
  expect(txt).toContain("active-payments.csv");
  expect(txt).toContain("payment-activity.csv");
  expect(txt).toContain("cash basis");
  expect(txt).toContain("2026-01-01");
  expect(buildReadme(s)).toBe(txt); // deterministic
});
