// utils/accountingPackage.ts
// Pure builders for the accountant-package ZIP. No I/O, no Settings, no secrets.
// Spec: docs/superpowers/specs/2026-08-07-accountant-package-design.md
import type { Customer, Expense, Invoice, Trip } from "../types/models";
import { buildIncomeCsv, toCsv } from "./csvExport";
import {
  amountPaid, balanceDue, isFullyPaid, isPartlyPaid,
  overpaidAmount, paymentsInRange, toAmount,
} from "./invoicePayments";
import { EXPENSE_CATEGORIES, isInRange } from "./moneyUtils";

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
    .filter(({ i, issue }) =>
      (issue !== null && isInRange(issue, start, end)) ||
      paymentsInRange(i, start, end).some((p) => !p.voidedAt))
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
    .map((i) => ({ i, issue: recoverIssueDate(i.id) }))
    .filter(({ i, issue }) =>
      (issue !== null && isInRange(issue, start, end)) ||
      paymentsInRange(i, start, end).some((p) => !p.voidedAt))
    .sort((a, b) => byCode(a.i.number || "", b.i.number || "") || byCode(a.i.id, b.i.id));
  for (const { i } of inScope) {
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

  const inScopeInvoices = input.invoices.filter((i) => {
    const issue = recoverIssueDate(i.id);
    return (issue !== null && isInRange(issue, start, end)) ||
      paymentsInRange(i, start, end).some((p) => !p.voidedAt);
  });

  const activeRows = buildIncomeCsv(input.invoices, start, end).trim().split("\r\n").length - 1;
  const expenseRows = input.expenses.filter((e) => isInRange(e.date, start, end)).length;
  const tripRows = input.trips.filter((t) => isInRange(t.date, start, end)).length;

  for (const i of inScopeInvoices) {
    if (recoverIssueDate(i.id) === null)
      push("missing_issue_date", "warn", i.number || i.id, "Issue date could not be recovered; left blank.");
    if (!i.lineItems || i.lineItems.length === 0)
      push("missing_line_items", "info", i.number || i.id, "Invoice has no itemised breakdown.");
    if ((!i.payments || i.payments.length === 0) && i.paid)
      push("legacy_invoice_no_ledger", "info", i.number || i.id, "Paid before payment history existed; derived from the paid flag.");
    if (overpaidAmount(i) > 0)
      push("overpayment_present", "warn", i.number || i.id, `Overpaid by ${overpaidAmount(i).toFixed(2)}.`);
    if (paymentsInRange(i, start, end).some((p) => p.voidedAt))
      push("voided_payments_present", "info", i.number || i.id, "Contains voided payments (see payment-activity.csv).");
  }

  for (const e of input.expenses) {
    if (isInRange(e.date, start, end) && !EXPENSE_CATEGORIES.some((c) => c.id === e.category))
      push("unknown_expense_category", "warn", e.description || e.id, `Unknown category "${e.category}"; mapped to Other.`);
  }

  if (tripRows > 0)
    push("mileage_is_device_local", "info", "mileage.csv", "Trips are stored on this device only; another device may hold others.");

  if (activeRows === 0 && expenseRows === 0 && tripRows === 0 && inScopeInvoices.length === 0 && input.customers.length === 0)
    push("no_records_in_range", "info", "range", "No records fell in the selected date range.");

  return w;
}

const WARNINGS_HEADER = ["Code", "Severity", "Subject", "Detail"];
export function buildWarningsCsv(warnings: ExportWarning[]): string {
  return toCsv(WARNINGS_HEADER, warnings.map((x) => [x.code, x.severity, x.subject, x.detail]));
}
