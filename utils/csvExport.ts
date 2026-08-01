// utils/csvExport.ts
// The accounting export (roadmap #7): pure CSV builders + the share tail.
// Builders do NO I/O — everything above shareCsv is unit-testable strings.
// Spec: docs/superpowers/specs/2026-07-31-csv-export-design.md

import type { Invoice, Expense, Trip } from "../types/models";
import { paymentsInRange, toAmount } from "./invoicePayments";
import type { DateRange } from "./moneyUtils";
import { EXPENSE_CATEGORIES, isInRange } from "./moneyUtils";

/**
 * RFC-4180 field escaping: quote when the value contains a comma, quote,
 * or line break; double embedded quotes. Everything else passes through
 * so accented customer names stay readable in the file.
 */
export function escapeCsvField(value: string): string {
  if (/[",\r\n]/.test(value)) {
    return '"' + value.replace(/"/g, '""') + '"';
  }
  return value;
}

/**
 * Assemble a CSV document: header + rows, CRLF line endings (Excel's
 * expectation), trailing newline. No totals rows — they poison imports.
 */
export function toCsv(header: string[], rows: string[][]): string {
  const lines = [header, ...rows].map((fields) =>
    fields.map(escapeCsvField).join(",")
  );
  return lines.join("\r\n") + "\r\n";
}

const INCOME_HEADER = [
  "Date",
  "Customer",
  "Invoice #",
  "Invoice Description",
  "Method",
  "Note",
  "Amount",
];

/**
 * Income rows are PAYMENTS, not invoices — deposits and partials export on
 * the date the money actually arrived. Semantics match collectedInRange
 * exactly (there is a sum-equivalence test): voided entries excluded, legacy
 * paid invoices contribute their one implicit entry (dated paidAt ?? due via
 * materializeLegacyLedger), amounts coerced through the same toAmount.
 *
 * The implicit legacy entry carries the deterministic id `legacy_<id>` and
 * method "other" — the export blanks the method for those rows (spec §2):
 * "other" would misreport how money arrived when all we know is that it did.
 */
export function buildIncomeCsv(invoices: Invoice[], start: Date, end: Date): string {
  const rows: { date: string; fields: string[] }[] = [];
  for (const invoice of invoices) {
    for (const p of paymentsInRange(invoice, start, end)) {
      if (p.voidedAt) continue;
      const legacy = p.id.startsWith("legacy_");
      rows.push({
        date: p.date,
        fields: [
          p.date,
          invoice.customer || "",
          invoice.number || "",
          invoice.desc || "",
          legacy ? "" : p.method,
          p.note || "",
          toAmount(p.amount).toFixed(2),
        ],
      });
    }
  }
  // Code-unit comparison, NOT localeCompare (Hermes ICU variance — see
  // comparePayments in invoicePayments.ts). "YYYY-MM-DD" sorts chronologically.
  rows.sort((a, b) => (a.date === b.date ? 0 : a.date < b.date ? -1 : 1));
  return toCsv(INCOME_HEADER, rows.map((r) => r.fields));
}

const EXPENSE_HEADER = ["Date", "Description", "Category", "Amount", "Notes", "Has Receipt"];

/** Category exports the LABEL; unknown ids fall back to Other exactly like ExpenseRow. */
export function buildExpensesCsv(expenses: Expense[], start: Date, end: Date): string {
  const rows = expenses
    .filter((e) => isInRange(e.date, start, end))
    .sort((a, b) => (a.date === b.date ? 0 : a.date < b.date ? -1 : 1))
    .map((e) => {
      const category =
        EXPENSE_CATEGORIES.find((c) => c.id === e.category) || EXPENSE_CATEGORIES[7];
      return [
        e.date,
        e.description || "",
        category.label,
        toAmount(e.amount).toFixed(2),
        e.notes || "",
        e.receiptUri ? "Yes" : "No",
      ];
    });
  return toCsv(EXPENSE_HEADER, rows);
}

const TRIP_HEADER = ["Date", "From", "To", "Purpose", "Odometer Start", "Odometer End", "Miles"];

/** Raw trip data; miles are not money, so no decimal padding — the accountant applies the rate. */
export function buildTripsCsv(trips: Trip[], start: Date, end: Date): string {
  const rows = trips
    .filter((t) => isInRange(t.date, start, end))
    .sort((a, b) => (a.date === b.date ? 0 : a.date < b.date ? -1 : 1))
    .map((t) => [
      t.date,
      t.fromLabel || "",
      t.toLabel || "",
      t.purpose || "",
      String(t.odometerStart),
      String(t.odometerEnd),
      String(t.miles),
    ]);
  return toCsv(TRIP_HEADER, rows);
}

export type ExportRangeId =
  | "this_month"
  | "this_quarter"
  | "this_year"
  | "last_year"
  | "all_time";

/**
 * Export presets. Same local-time construction as moneyUtils.getDateRange —
 * implemented here rather than delegated because the export needs an
 * injectable `now` for deterministic tests (getDateRange reads the real
 * clock) and two presets (quarter, last year) getDateRange doesn't have.
 */
export function exportDateRange(id: ExportRangeId, now: Date = new Date()): DateRange {
  const y = now.getFullYear();
  const m = now.getMonth();
  switch (id) {
    case "this_month":
      return { start: new Date(y, m, 1), end: new Date(y, m + 1, 0, 23, 59, 59) };
    case "this_quarter": {
      const q = Math.floor(m / 3) * 3;
      return { start: new Date(y, q, 1), end: new Date(y, q + 3, 0, 23, 59, 59) };
    }
    case "this_year":
      return { start: new Date(y, 0, 1), end: new Date(y, 11, 31, 23, 59, 59) };
    case "last_year":
      return { start: new Date(y - 1, 0, 1), end: new Date(y - 1, 11, 31, 23, 59, 59) };
    case "all_time":
      return { start: new Date(0), end: new Date(9999, 11, 31) };
  }
}

// LOCAL date for filenames — toISOString would UTC-shift west-of-UTC users
// onto the previous day (same trap parseLocalDate exists for).
function ymdLocal(d: Date): string {
  const pad = (n: number) => String(n).padStart(2, "0");
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
}

/** No user text in filenames, so no sanitizer needed (unlike invoicePdfFilename). */
export function csvFilename(
  dataset: "income" | "expenses" | "mileage",
  range: DateRange,
  rangeId: ExportRangeId | "custom"
): string {
  if (rangeId === "all_time") return `tradeready-${dataset}_all-time.csv`;
  return `tradeready-${dataset}_${ymdLocal(range.start)}_${ymdLocal(range.end)}.csv`;
}

/** Data rows in a built CSV (excludes the header) — drives the screen's counts. */
export function csvRowCount(csv: string): number {
  return csv.split("\r\n").filter((line) => line.length > 0).length - 1;
}
