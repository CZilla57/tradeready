// utils/accountingPackage.ts
// Pure builders for the accountant-package ZIP. No I/O, no Settings, no secrets.
// Spec: docs/superpowers/specs/2026-08-07-accountant-package-design.md
import type { Customer, Expense, Invoice } from "../types/models";
import { toCsv } from "./csvExport";
import {
  amountPaid, balanceDue, isFullyPaid, isPartlyPaid,
  paymentsInRange, toAmount,
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
