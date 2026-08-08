// utils/accountingPackage.ts
// Pure builders for the accountant-package ZIP. No I/O, no Settings, no secrets.
// Spec: docs/superpowers/specs/2026-08-07-accountant-package-design.md
import type { Customer, Expense, Invoice, Trip } from "../types/models";
import { buildIncomeCsv, buildTripsCsv, toCsv } from "./csvExport";
import {
  amountPaid, balanceDue, collectedInRange, isFullyPaid, isPartlyPaid,
  overpaidAmount, paymentsInRange, toAmount,
} from "./invoicePayments";
import { EXPENSE_CATEGORIES, isInRange } from "./moneyUtils";
import { buildZip, utf8Encode, type ZipEntry } from "./zipStore";

/** buildActivePaymentsCsv mirrors buildIncomeCsv exactly (non-voided payments,
 *  legacy method blank) — reuse that shape rather than duplicate its logic. */
export { buildIncomeCsv as buildActivePaymentsCsv } from "./csvExport";

/** Recover the "YYYY-MM-DD" issue date from an invoice id's ms timestamp, or
 *  null when the id is not a plausible timestamp (sample/legacy rows). Unlike
 *  pdfTemplates.invoiceIssueDate this NEVER falls back to the wall clock — an
 *  accounting export must be deterministic, so unrecoverable stays blank. */
export function recoverIssueDate(id: string): string | null {
  const raw = id.replace(/^inv/, "");
  if (!/^\d+$/.test(raw)) return null;
  const ms = Number(raw);
  const d = new Date(ms);
  const y = d.getUTCFullYear();
  if (!(y >= 2000 && y <= 2100)) return null;
  const pad = (n: number) => String(n).padStart(2, "0");
  return `${y}-${pad(d.getUTCMonth() + 1)}-${pad(d.getUTCDate())}`;
}

/** An invoice is in scope for a range if its issue date (recovered from the id)
 *  falls in range, OR it has at least one non-voided in-range payment. Shared
 *  by buildInvoicesCsv, buildLineItemsCsv, collectWarnings and buildSummary so
 *  the "in scope" definition exists exactly once. */
export function isInvoiceInScope(i: Invoice, start: Date, end: Date): boolean {
  const issue = recoverIssueDate(i.id);
  return (issue !== null && isInRange(issue, start, end)) ||
    paymentsInRange(i, start, end).some((p) => !p.voidedAt);
}

export function paymentSource(id: string): "device" | "stripe" | "legacy" {
  if (id.startsWith("stripe_")) return "stripe";
  if (id.startsWith("legacy_")) return "legacy";
  return "device";
}

const byCode = (a: string, b: string) => (a === b ? 0 : a < b ? -1 : 1);
const money = (v: unknown) => toAmount(v).toFixed(2);

function invoiceStatus(i: Invoice): string {
  if (isFullyPaid(i)) return "paid";
  if (isPartlyPaid(i)) return "partly_paid";
  return "unpaid";
}

const INVOICES_HEADER = ["Invoice #", "Issue Date", "Customer", "Email", "Phone",
  "Description", "Amount", "Amount Paid", "Balance Due", "Status", "Due Date", "Paid At", "Job ID"];

export function buildInvoicesCsv(invoices: Invoice[], start: Date, end: Date): string {
  const rows = invoices
    .map((i) => ({ i, issue: recoverIssueDate(i.id) }))
    .filter(({ i }) => isInvoiceInScope(i, start, end))
    .sort((a, b) => {
      if (a.issue === b.issue) return byCode(a.i.number || "", b.i.number || "") || byCode(a.i.id, b.i.id);
      if (a.issue === null) return 1;
      if (b.issue === null) return -1;
      return byCode(a.issue, b.issue);
    })
    .map(({ i, issue }) => [
      i.number || "", issue || "", i.customer || "", i.email || "", i.phone || "",
      i.desc || "", money(i.amount), money(amountPaid(i)), money(balanceDue(i)),
      invoiceStatus(i), i.due || "", i.paidAt || "", i.jobId || "",
    ]);
  return toCsv(INVOICES_HEADER, rows);
}

const LINE_ITEMS_HEADER = ["Invoice #", "Description", "Category", "Amount"];
export function buildLineItemsCsv(invoices: Invoice[], start: Date, end: Date): string {
  const rows: string[][] = [];
  const inScope = invoices
    .filter((i) => isInvoiceInScope(i, start, end))
    .sort((a, b) => byCode(a.number || "", b.number || "") || byCode(a.id, b.id));
  for (const i of inScope) {
    for (const li of i.lineItems || []) {
      rows.push([i.number || "", li.description || "", li.category, money(li.amount)]);
    }
  }
  return toCsv(LINE_ITEMS_HEADER, rows);
}

const ACTIVITY_HEADER = ["Date", "Customer", "Invoice #", "Method", "Note", "Amount", "Voided", "Voided At", "Source"];
export function buildPaymentActivityCsv(invoices: Invoice[], start: Date, end: Date): string {
  const rows: { date: string; id: string; fields: string[] }[] = [];
  for (const invoice of invoices) {
    for (const p of paymentsInRange(invoice, start, end)) {
      const legacy = p.id.startsWith("legacy_");
      rows.push({ date: p.date, id: p.id, fields: [
        p.date, invoice.customer || "", invoice.number || "",
        legacy ? "" : p.method, p.note || "", money(p.amount),
        p.voidedAt ? "Yes" : "No", p.voidedAt || "", paymentSource(p.id),
      ]});
    }
  }
  rows.sort((a, b) => byCode(a.date, b.date) || byCode(a.id, b.id));
  return toCsv(ACTIVITY_HEADER, rows.map((r) => r.fields));
}

const EXPENSES2_HEADER = ["Date", "Description", "Category", "Amount", "Notes", "Job", "Has Receipt"];
export function buildExpensesCsv2(
  expenses: Expense[], start: Date, end: Date, jobNameById: Record<string, string>,
): string {
  const rows = expenses
    .filter((e) => isInRange(e.date, start, end))
    .sort((a, b) => byCode(a.date, b.date) || byCode(a.id, b.id))
    .map((e) => {
      const category = EXPENSE_CATEGORIES.find((c) => c.id === e.category) || EXPENSE_CATEGORIES[7];
      const job = e.jobId ? jobNameById[e.jobId] || "" : "";
      return [e.date, e.description || "", category.label, money(e.amount), e.notes || "", job, e.receiptUri ? "Yes" : "No"];
    });
  return toCsv(EXPENSES2_HEADER, rows);
}

const CUSTOMERS_HEADER = ["Name", "Email", "Phone", "Address", "Notes", "Created", "Archived"];
export function buildCustomersCsv(customers: Customer[]): string {
  const rows = [...customers]
    .sort((a, b) => byCode(a.name || "", b.name || "") || byCode(a.id, b.id))
    .map((c) => [c.name || "", c.email || "", c.phone || "", c.address || "", c.notes || "", c.createdAt || "", c.archivedAt || ""]);
  return toCsv(CUSTOMERS_HEADER, rows);
}

const CATEGORY_HEADER = ["Category ID", "Label"];
export function buildCategoryMappingCsv(): string {
  return toCsv(CATEGORY_HEADER, EXPENSE_CATEGORIES.map((c) => [c.id, c.label]));
}

export type ExportWarning = { code: string; severity: "warn" | "info"; subject: string; detail: string };
export type PackageInput = {
  invoices: Invoice[]; expenses: Expense[]; trips: Trip[];
  customers: Customer[]; jobNameById: Record<string, string>;
};

export function collectWarnings(input: PackageInput, start: Date, end: Date): ExportWarning[] {
  const w: ExportWarning[] = [];
  const push = (code: string, severity: "warn" | "info", subject: string, detail: string) =>
    w.push({ code, severity, subject, detail });

  const inScopeInvoices = input.invoices.filter((i) => isInvoiceInScope(i, start, end));

  const activeRows = buildIncomeCsv(input.invoices, start, end).trim().split("\r\n").length - 1;
  const expenseRows = input.expenses.filter((e) => isInRange(e.date, start, end)).length;
  const tripRows = input.trips.filter((t) => isInRange(t.date, start, end)).length;
  const hasPaymentActivity = input.invoices.some((i) => paymentsInRange(i, start, end).length > 0);

  for (const i of inScopeInvoices) {
    if (recoverIssueDate(i.id) === null)
      push("missing_issue_date", "warn", i.number || i.id, "Issue date could not be recovered; left blank.");
    if (!i.lineItems || i.lineItems.length === 0)
      push("missing_line_items", "info", i.number || i.id, "Invoice has no itemised breakdown.");
    if ((!i.payments || i.payments.length === 0) && i.paid)
      push("legacy_invoice_no_ledger", "info", i.number || i.id, "Paid before payment history existed; derived from the paid flag.");
    if (overpaidAmount(i) > 0)
      push("overpayment_present", "warn", i.number || i.id, `Overpaid by ${overpaidAmount(i).toFixed(2)}.`);
  }

  for (const i of input.invoices) {
    if (paymentsInRange(i, start, end).some((p) => p.voidedAt))
      push("voided_payments_present", "info", i.number || i.id, "Contains voided payments (see payment-activity.csv).");
  }

  for (const e of input.expenses) {
    if (isInRange(e.date, start, end) && !EXPENSE_CATEGORIES.some((c) => c.id === e.category))
      push("unknown_expense_category", "warn", e.description || e.id, `Unknown category "${e.category}"; mapped to Other.`);
  }

  if (tripRows > 0)
    push("mileage_is_device_local", "info", "mileage.csv", "Trips are stored on this device only; another device may hold others.");

  if (activeRows === 0 && expenseRows === 0 && tripRows === 0 && inScopeInvoices.length === 0 &&
      input.customers.length === 0 && !hasPaymentActivity)
    push("no_records_in_range", "info", "range", "No records fell in the selected date range.");

  return w;
}

const WARNINGS_HEADER = ["Code", "Severity", "Subject", "Detail"];
export function buildWarningsCsv(warnings: ExportWarning[]): string {
  return toCsv(WARNINGS_HEADER, warnings.map((x) => [x.code, x.severity, x.subject, x.detail]));
}

function ymdLocal(d: Date): string {
  const pad = (n: number) => String(n).padStart(2, "0");
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
}
export function ymdLocalRange(start: Date, end: Date) {
  return { start: ymdLocal(start), end: ymdLocal(end) };
}

export type PackageSummary = {
  range_start: string; range_end: string;
  cash_collected: number; voided_amount: number; expenses_total: number;
  net_cash: number; net_cash_basis: string;
  invoices_count: number; customers_count: number;
  mileage_trips_count: number; mileage_miles_total: number; warnings_count: number;
};

const round2 = (n: number) => Math.round(n * 100) / 100;

export function buildSummary(input: PackageInput, start: Date, end: Date): PackageSummary {
  const cash = collectedInRange(input.invoices, start, end);
  let voided = 0;
  for (const i of input.invoices)
    for (const p of paymentsInRange(i, start, end)) if (p.voidedAt) voided += toAmount(p.amount);
  const expensesTotal = input.expenses
    .filter((e) => isInRange(e.date, start, end))
    .reduce((s, e) => s + toAmount(e.amount), 0);
  const inScopeInvoices = input.invoices.filter((i) => isInvoiceInScope(i, start, end));
  const trips = input.trips.filter((t) => isInRange(t.date, start, end));
  const r = ymdLocalRange(start, end);
  const cashCollected = round2(cash);
  const expensesTotalRounded = round2(expensesTotal);
  return {
    range_start: r.start, range_end: r.end,
    cash_collected: cashCollected, voided_amount: round2(voided), expenses_total: expensesTotalRounded,
    net_cash: round2(cashCollected - expensesTotalRounded), net_cash_basis: "cash basis; before owner labor",
    invoices_count: inScopeInvoices.length, customers_count: input.customers.length,
    mileage_trips_count: trips.length, mileage_miles_total: round2(trips.reduce((s, t) => s + toAmount(t.miles), 0)),
    warnings_count: collectWarnings(input, start, end).length,
  };
}

export function buildSummaryJson(summary: PackageSummary): string {
  return JSON.stringify(summary, null, 2);
}

export function buildReadme(summary: PackageSummary): string {
  return [
    `TradeReady accounting export`,
    `Date range: ${summary.range_start} to ${summary.range_end}`,
    ``,
    `Income is reported on a cash basis: a payment appears on the date the money`,
    `was actually received, so deposits and partial payments land in the right period.`,
    ``,
    `Files:`,
    `  invoices.csv            One row per invoice (issue date, amount, paid, balance, status).`,
    `  invoice-line-items.csv  Itemised breakdown; absent for manually-created invoices.`,
    `  active-payments.csv     Money received (voided payments excluded). Cash-basis income.`,
    `  payment-activity.csv    Every payment including voided ones, with void dates.`,
    `  expenses.csv            Business expenses; Job column links to a job when set.`,
    `  mileage.csv             Logged drives (raw miles; apply your own rate).`,
    `  customers.csv           Customer contact details.`,
    `  category-mapping.csv    Expense category id -> label reference.`,
    `  export-warnings.csv     Anything the export could not fully determine.`,
    `  summary.json            Control totals for reconciliation.`,
    ``,
    `Notes:`,
    `  - No values are inferred. Unknown fields are left blank and flagged in export-warnings.csv.`,
    `  - There is no refund concept in the app; only voids are recorded.`,
    `  - Mileage and receipts are stored on the device only and may differ between devices.`,
    `  - net_cash in summary.json is cash collected minus expenses (before paying yourself).`,
    ``,
  ].join("\n");
}

export function packageFilename(start: Date, end: Date, allTime: boolean): string {
  if (allTime) return "TradeReady-Accounting_all-time.zip";
  const r = ymdLocalRange(start, end);
  return `TradeReady-Accounting_${r.start}_${r.end}.zip`;
}

export function buildAccountingPackage(
  input: PackageInput, start: Date, end: Date,
): { filename: string; bytes: Uint8Array } {
  const summary = buildSummary(input, start, end);
  const warnings = collectWarnings(input, start, end);
  const csv = (name: string, body: string): ZipEntry => ({ name, bytes: utf8Encode("\uFEFF" + body) });
  const text = (name: string, body: string): ZipEntry => ({ name, bytes: utf8Encode(body) });

  const entries: ZipEntry[] = [
    csv("invoices.csv", buildInvoicesCsv(input.invoices, start, end)),
    csv("invoice-line-items.csv", buildLineItemsCsv(input.invoices, start, end)),
    csv("active-payments.csv", buildIncomeCsv(input.invoices, start, end)),
    csv("payment-activity.csv", buildPaymentActivityCsv(input.invoices, start, end)),
    csv("expenses.csv", buildExpensesCsv2(input.expenses, start, end, input.jobNameById)),
    csv("mileage.csv", buildTripsCsv(input.trips, start, end)),
    csv("customers.csv", buildCustomersCsv(input.customers)),
    csv("category-mapping.csv", buildCategoryMappingCsv()),
    csv("export-warnings.csv", buildWarningsCsv(warnings)),
    text("summary.json", buildSummaryJson(summary)),
    text("README.txt", buildReadme(summary)),
  ];
  const allTime = start.getTime() === 0;
  return { filename: packageFilename(start, end, allTime), bytes: buildZip(entries) };
}
