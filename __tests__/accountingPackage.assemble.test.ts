// __tests__/accountingPackage.assemble.test.ts
import { buildAccountingPackage, packageFilename } from "../utils/accountingPackage";
import type { Invoice } from "../types/models";

const JAN1 = new Date(2026, 0, 1), DEC31 = new Date(2026, 11, 31, 23, 59, 59);
const input = { invoices: [] as Invoice[], expenses: [], trips: [], customers: [], jobNameById: {} };

test("filename uses local dates, or all-time", () => {
  expect(packageFilename(JAN1, DEC31, false)).toBe("TradeReady-Accounting_2026-01-01_2026-12-31.zip");
  expect(packageFilename(JAN1, DEC31, true)).toBe("TradeReady-Accounting_all-time.zip");
});

test("assembles a deterministic non-empty zip beginning with a local file header", () => {
  const a = buildAccountingPackage(input, JAN1, DEC31);
  expect(a.filename).toContain(".zip");
  expect(Array.from(a.bytes.slice(0, 4))).toEqual([0x50, 0x4b, 0x03, 0x04]);
  const b = buildAccountingPackage(input, JAN1, DEC31);
  expect(Array.from(b.bytes)).toEqual(Array.from(a.bytes));
});
