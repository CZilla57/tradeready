// __tests__/invoicePdfIssueDate.test.js
// Invoice has no `created` field (see types/models.ts), so invoiceIssueDate
// recovers the issue date from the ms timestamp both creation paths embed in
// the invoice id: `inv${Date.now()}` (CreateInvoiceFromJobScreen) and
// `String(Date.now())` (AddInvoiceScreen). Sample/legacy ids that aren't
// timestamps fall back to the injected `now`, matching the old behaviour
// (every PDF's issue date was "today").

import { invoiceIssueDate } from "../utils/pdfTemplates";

const TIMESTAMP_MS = 1700000000000; // 2023-11-14T22:13:20.000Z
const TIMESTAMP_ISO = new Date(TIMESTAMP_MS).toISOString();
const NOW = new Date("2026-07-29T12:00:00.000Z");

describe("invoiceIssueDate", () => {
  test("an inv<timestamp> id returns that timestamp's date", () => {
    expect(invoiceIssueDate(`inv${TIMESTAMP_MS}`)).toBe(TIMESTAMP_ISO);
  });

  test("a bare <timestamp> id (AddInvoiceScreen shape) returns that timestamp's date", () => {
    expect(invoiceIssueDate(String(TIMESTAMP_MS))).toBe(TIMESTAMP_ISO);
  });

  test("a sample-style id falls back to the injected now", () => {
    expect(invoiceIssueDate("1-1a2b3c", NOW)).toBe(NOW.toISOString());
  });

  test("an all-digit but implausible id falls back to the injected now (regression guard)", () => {
    // A naive parseInt/Number(id) would treat "1" as 1ms after the epoch and
    // render an issue date of 1 January 1970 — the range guard must catch this.
    expect(invoiceIssueDate("1", NOW)).toBe(NOW.toISOString());
  });

  test("an empty-string id falls back to the injected now", () => {
    expect(invoiceIssueDate("", NOW)).toBe(NOW.toISOString());
  });
});
