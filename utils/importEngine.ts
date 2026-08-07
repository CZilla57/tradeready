// Pure per-entity builders for CSV import. Given parsed rows + a column→field
// mapping + the current collection, each builder returns the FULL next array to
// save plus per-row outcomes and counts. NO I/O, NO network — the screen does
// load/save. Customers are created ONLY through upsertCustomerInList so the
// normalized-name join + blank-field backfill rules are never bypassed.

import { upsertCustomerInList } from "./storage/customers";
import { getTodayDateString } from "./dateHelpers";
import { parseImportDate, type DateFormat } from "./importMapping";
import { nextInvoiceNumber, type InvoiceNumberOptions } from "./invoiceNumber";
import { EXPENSE_CATEGORIES } from "./moneyUtils";
import type { Customer, Expense, ExpenseCategoryId, Invoice, Job, JobStatus } from "../types/models";

export interface RowOutcome {
  rowIndex: number;
  status: "ok" | "skip" | "flag";
  reason?: string;
}

export interface ImportCounts {
  ok: number;
  skip: number;
  flag: number;
  created: number;
  matched: number;
}

/** Pull the first non-empty cell whose column maps to `key`, joining `name`. */
function fieldValue(row: string[], mapping: (string | null)[], key: string): string {
  const parts: string[] = [];
  for (let i = 0; i < mapping.length; i += 1) {
    if (mapping[i] === key) {
      const v = (row[i] ?? "").trim();
      if (v) parts.push(v);
    }
  }
  return parts.join(" ");
}

const normName = (s: string) => s.trim().toLowerCase();

export interface CustomerImportResult {
  records: Customer[];
  outcomes: RowOutcome[];
  counts: ImportCounts;
}

export function buildCustomerImport(
  rows: string[][],
  mapping: (string | null)[],
  existing: Customer[],
  batchId: string,
): CustomerImportResult {
  let acc = existing;
  const outcomes: RowOutcome[] = [];
  const counts: ImportCounts = { ok: 0, skip: 0, flag: 0, created: 0, matched: 0 };

  rows.forEach((row, rowIndex) => {
    const name = fieldValue(row, mapping, "name");
    if (!name) {
      outcomes.push({ rowIndex, status: "skip", reason: "No customer name" });
      counts.skip += 1;
      return;
    }
    const notes = fieldValue(row, mapping, "notes");
    const existedBefore = acc.some((c) => normName(c.name) === normName(name));
    const { customer, customers: next, changed } = upsertCustomerInList(acc, {
      name,
      email: fieldValue(row, mapping, "email"),
      phone: fieldValue(row, mapping, "phone"),
      address: fieldValue(row, mapping, "address"),
    });
    if (!customer) {
      outcomes.push({ rowIndex, status: "skip", reason: "No customer name" });
      counts.skip += 1;
      return;
    }
    if (existedBefore) {
      acc = next;                       // backfill applied (if changed); never stamped, notes untouched
      counts.matched += 1;
    } else {
      // Newly created — stamp importBatchId and mapped notes on that record only.
      acc = next.map((c) => (c.id === customer.id ? { ...c, importBatchId: batchId, notes: notes || c.notes } : c));
      counts.created += 1;
    }
    outcomes.push({ rowIndex, status: "ok" });
    counts.ok += 1;
    void changed;
  });

  return { records: acc, outcomes, counts };
}

/** Undo helper: drop every record created by a batch (pure; screen saves result). */
export function stripBatch<T extends { importBatchId?: string }>(records: T[], batchId: string): T[] {
  return records.filter((r) => r.importBatchId !== batchId);
}

// Keyword table for mapping foreign CSV status text onto our JobStatus union.
// Jobs are HISTORICAL records on import — status is assigned DIRECTLY here,
// never walked through JOB_STATUSES.next. Unrecognized text falls back to
// "lead" and the row is flagged (not skipped) so the import still proceeds.
const STATUS_KEYWORDS: { status: JobStatus; words: string[] }[] = [
  { status: "estimate_sent", words: ["estimate sent", "quote sent", "quoted", "estimate", "quote"] },
  { status: "in_progress", words: ["in progress", "started", "working", "active"] },
  { status: "declined", words: ["declined", "lost", "cancelled", "canceled", "rejected"] },
  { status: "scheduled", words: ["scheduled", "booked", "upcoming"] },
  { status: "approved", words: ["approved", "won", "accepted"] },
  { status: "complete", words: ["complete", "completed", "done", "closed", "finished"] },
  { status: "invoiced", words: ["invoiced", "billed"] },
  { status: "paid", words: ["paid"] },
  { status: "lead", words: ["lead", "new", "inquiry", "enquiry", "prospect"] },
];

export function mapJobStatus(raw: string): { status: JobStatus; recognized: boolean } {
  const s = (raw || "").trim().toLowerCase();
  if (!s) return { status: "lead", recognized: false };
  for (const entry of STATUS_KEYWORDS) {
    if (entry.words.some((w) => s.includes(w))) return { status: entry.status, recognized: true };
  }
  return { status: "lead", recognized: false };
}

export interface JobImportResult {
  customers: Customer[];
  jobs: Job[];
  outcomes: RowOutcome[];
  counts: ImportCounts;
}

let _jobSeq = 0;
function newJobId(): string {
  _jobSeq += 1;
  return `j${Date.now()}_${_jobSeq}`;
}

export function buildJobImport(
  rows: string[][],
  mapping: (string | null)[],
  existingCustomers: Customer[],
  existingJobs: Job[],
  batchId: string,
  dateFormat: DateFormat | null,
): JobImportResult {
  let customers = existingCustomers;
  const jobs: Job[] = [...existingJobs];
  const outcomes: RowOutcome[] = [];
  const counts: ImportCounts = { ok: 0, skip: 0, flag: 0, created: 0, matched: 0 };

  rows.forEach((row, rowIndex) => {
    const title = fieldValue(row, mapping, "title");
    const customerName = fieldValue(row, mapping, "customerName");
    if (!title || !customerName) {
      outcomes.push({ rowIndex, status: "skip", reason: "Missing job title or customer" });
      counts.skip += 1;
      return;
    }

    // Join or create the customer within this same batch.
    const existedBefore = customers.some((c) => normName(c.name) === normName(customerName));
    const up = upsertCustomerInList(customers, { name: customerName });
    const customer = up.customer!;
    customers = existedBefore
      ? up.customers
      : up.customers.map((c) => (c.id === customer.id ? { ...c, importBatchId: batchId } : c));

    const statusRaw = fieldValue(row, mapping, "status");
    const { status, recognized } = mapJobStatus(statusRaw);
    const scheduledDate = parseImportDate(fieldValue(row, mapping, "scheduledDate"), dateFormat);
    const estimateTotal = Number(fieldValue(row, mapping, "estimateTotal").replace(/[^0-9.-]/g, "")) || 0;

    const job: Job = {
      id: newJobId(),
      customerId: customer.id,
      customerName: customer.name,
      title,
      description: fieldValue(row, mapping, "description"),
      status,
      scheduledDate,
      scheduledStartTime: null,
      scheduledEndTime: null,
      address: fieldValue(row, mapping, "address"),
      estimateTotal,
      laborHours: 0,
      laborRate: 0,
      materials: [],
      materialMarkup: 0,
      overhead: 0,
      margin: 0,
      notes: fieldValue(row, mapping, "notes"),
      invoiceId: null,
      createdAt: getTodayDateString(),
      importBatchId: batchId,
      // estimateSentAt deliberately absent → no follow-up nudge on imports.
    };
    jobs.push(job);

    if (statusRaw && !recognized) {
      outcomes.push({ rowIndex, status: "flag", reason: `Unknown status "${statusRaw}" → lead` });
      counts.flag += 1;
    } else {
      outcomes.push({ rowIndex, status: "ok" });
      counts.ok += 1;
    }
  });

  return { customers, jobs, outcomes, counts };
}

// ---------------------------------------------------------------------------
// Invoices (Phase 4 — the MONEY phase). Historical invoices, including
// already-paid ones, are joined against the same customer registry as
// customers/jobs. See utils/invoicePayments.ts for why a paid invoice here
// never gets a fabricated `payments` ledger: amountPaid/balanceDue already
// derive correctly from `paid`/`amount`/`paidAt` for legacy (ledger-less)
// invoices, so inventing ledger entries would just be redundant risk.

/** Strip everything but digits/./- and parse; null on empty or NaN input. */
function parseMoney(raw: string): number | null {
  const cleaned = (raw || "").replace(/[^0-9.\-]/g, "");
  if (!cleaned) return null;
  const n = Number(cleaned);
  return Number.isFinite(n) ? n : null;
}

/**
 * Build a UNIQUE invoice id whose embedded ms decodes (via invoiceIssueDate's
 * UTC reader in utils/pdfTemplates.ts) back to the source issue date. UTC is
 * deliberate here — it round-trips through invoiceIssueDate's getUTCFullYear /
 * toISOString; the invoice's due/paidAt fields stay local YYYY-MM-DD strings
 * (FA-039). The intra-day offset keeps every id on the correct UTC calendar day
 * (1..86_399_999 ms after UTC midnight) while making same-date rows unique
 * within a batch (row index) and across batches/sessions (real-clock nowMs).
 */
function importInvoiceId(dateStr: string | null, index: number, nowMs: number): string {
  let dayFloor: number;
  if (dateStr) {
    const [y, m, d] = dateStr.split("-").map(Number);
    dayFloor = Date.UTC(y, m - 1, d);          // 00:00:00.000Z of the source date
  } else {
    dayFloor = nowMs - (nowMs % 86_400_000);   // UTC midnight of today
  }
  const slot = 1 + (((nowMs % 86_400_000) + index) % 86_399_998);
  return String(dayFloor + slot);
}

export interface InvoiceImportResult {
  customers: Customer[];
  invoices: Invoice[];
  outcomes: RowOutcome[];
  counts: ImportCounts;
}

/**
 * Regex for a paid CLAIM in a text cell that failed to parse as a date — e.g.
 * "Yes" / "Paid" / "True". Never used to infer a date, only to decide whether
 * a blank/unparseable paid-date column should be flagged (vs. silently
 * treated as an ordinary open invoice with no paid claim at all).
 */
const PAID_CLAIM_RE = /paid|yes|true/i;

export function buildInvoiceImport(
  rows: string[][],
  mapping: (string | null)[],
  existingCustomers: Customer[],
  existingInvoices: Invoice[],
  batchId: string,
  dateFormat: DateFormat | null,
  numberOptions: InvoiceNumberOptions | undefined,
  nowMs: number,
): InvoiceImportResult {
  let customers = existingCustomers;
  const invoices: Invoice[] = [...existingInvoices];
  const outcomes: RowOutcome[] = [];
  const counts: ImportCounts = { ok: 0, skip: 0, flag: 0, created: 0, matched: 0 };

  rows.forEach((row, rowIndex) => {
    const customerName = fieldValue(row, mapping, "customer");
    const amount = parseMoney(fieldValue(row, mapping, "amount"));
    if (!customerName || amount == null) {
      outcomes.push({ rowIndex, status: "skip", reason: "Missing customer or amount" });
      counts.skip += 1;
      return;
    }

    // Join or create the customer within this same batch — customers are
    // created ONLY through upsertCustomerInList (module-header invariant).
    const existedBefore = customers.some((c) => normName(c.name) === normName(customerName));
    const up = upsertCustomerInList(customers, {
      name: customerName,
      email: fieldValue(row, mapping, "email"),
      phone: fieldValue(row, mapping, "phone"),
    });
    const customer = up.customer!;
    if (existedBefore) {
      customers = up.customers;               // backfill only; never stamped
      counts.matched += 1;
    } else {
      customers = up.customers.map((c) => (c.id === customer.id ? { ...c, importBatchId: batchId } : c));
      counts.created += 1;
    }

    const dueParsed = parseImportDate(fieldValue(row, mapping, "due"), dateFormat);
    const paidAtCell = fieldValue(row, mapping, "paidAt");
    const paidAtParsed = parseImportDate(paidAtCell, dateFormat);
    const paid = !!paidAtParsed;                // paid ONLY if a real paid date parses
    const claimedPaid = !paidAtParsed && PAID_CLAIM_RE.test(paidAtCell.trim());

    const due = dueParsed ?? getTodayDateString();
    const idDateStr = dueParsed ?? paidAtParsed ?? null;
    const id = importInvoiceId(idDateStr, rowIndex, nowMs);

    const mappedNumber = fieldValue(row, mapping, "number");
    const number = mappedNumber || nextInvoiceNumber(invoices, numberOptions);

    const inv: Invoice = {
      id,
      customer: customer.name,
      customerId: customer.id,
      number,
      amount,
      due,
      email: fieldValue(row, mapping, "email") || customer.email || "",
      phone: fieldValue(row, mapping, "phone") || customer.phone || "",
      desc: fieldValue(row, mapping, "desc"),
      paid,
      importBatchId: batchId,
      ...(paid ? { paidAt: paidAtParsed! } : {}),
    };
    invoices.push(inv);

    if (claimedPaid) {
      outcomes.push({ rowIndex, status: "flag", reason: "Marked paid but no paid date → imported outstanding" });
      counts.flag += 1;
    } else {
      outcomes.push({ rowIndex, status: "ok" });
      counts.ok += 1;
    }
  });

  return { customers, invoices, outcomes, counts };
}

// ---------------------------------------------------------------------------
// Expenses (Phase 5 — the final entity). No customer join — expenses are
// business overhead, not tied to a client. Category is keyword-mapped onto
// the canonical EXPENSE_CATEGORIES ids; anything unrecognized falls back to
// the "other" catch-all and the row is flagged (not skipped) so the import
// still proceeds, mirroring the jobs status fallback above.

export function mapExpenseCategory(raw: string): { id: ExpenseCategoryId; recognized: boolean } {
  const s = (raw || "").trim().toLowerCase();
  if (!s) return { id: "other", recognized: false };
  // Match against the canonical labels/ids first.
  for (const c of EXPENSE_CATEGORIES) {
    if (c.id === s || c.label.toLowerCase() === s || s.includes(c.id)) {
      return { id: c.id, recognized: true };
    }
  }
  const extra: { id: ExpenseCategoryId; words: string[] }[] = [
    { id: "fuel", words: ["gas", "fuel", "mileage", "transport"] },
    { id: "tools", words: ["tool", "equipment", "rental"] },
    { id: "labor", words: ["subcontractor", "sub", "labour", "labor", "crew"] },
    { id: "marketing", words: ["ad", "advertis", "marketing"] },
    { id: "software", words: ["software", "subscription", "app"] },
    { id: "insurance", words: ["insurance"] },
    { id: "materials", words: ["material", "supply", "supplies", "lumber"] },
  ];
  for (const e of extra) if (e.words.some((w) => s.includes(w))) return { id: e.id, recognized: true };
  return { id: "other", recognized: false };
}

export interface ExpenseImportResult {
  expenses: Expense[];
  outcomes: RowOutcome[];
  counts: ImportCounts;
}

let _expSeq = 0;
function newExpenseId(): string {
  _expSeq += 1;
  return `e${Date.now()}_${_expSeq}`;
}

export function buildExpenseImport(
  rows: string[][],
  mapping: (string | null)[],
  existingExpenses: Expense[],
  batchId: string,
  dateFormat: DateFormat | null,
): ExpenseImportResult {
  const expenses: Expense[] = [...existingExpenses];
  const outcomes: RowOutcome[] = [];
  const counts: ImportCounts = { ok: 0, skip: 0, flag: 0, created: 0, matched: 0 };

  rows.forEach((row, rowIndex) => {
    const amount = parseMoney(fieldValue(row, mapping, "amount"));
    const date = parseImportDate(fieldValue(row, mapping, "date"), dateFormat);
    if (amount == null || !date) {
      outcomes.push({ rowIndex, status: "skip", reason: amount == null ? "Missing amount" : "Unparseable date" });
      counts.skip += 1;
      return;
    }
    const catRaw = fieldValue(row, mapping, "category");
    const { id: category, recognized } = mapExpenseCategory(catRaw);
    expenses.push({
      id: newExpenseId(),
      createdAt: getTodayDateString(),
      description: fieldValue(row, mapping, "description"),
      amount,
      category,
      date,
      notes: fieldValue(row, mapping, "notes"),
      receiptUri: null,
      importBatchId: batchId,
    });
    if (catRaw && !recognized) {
      outcomes.push({ rowIndex, status: "flag", reason: `Unknown category "${catRaw}" → Other` });
      counts.flag += 1;
    } else {
      outcomes.push({ rowIndex, status: "ok" });
      counts.ok += 1;
    }
  });

  return { expenses, outcomes, counts };
}
