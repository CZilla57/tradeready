// Pure per-entity builders for CSV import. Given parsed rows + a column→field
// mapping + the current collection, each builder returns the FULL next array to
// save plus per-row outcomes and counts. NO I/O, NO network — the screen does
// load/save. Customers are created ONLY through upsertCustomerInList so the
// normalized-name join + blank-field backfill rules are never bypassed.

import { upsertCustomerInList } from "./storage/customers";
import { getTodayDateString } from "./dateHelpers";
import { parseImportDate, type DateFormat } from "./importMapping";
import type { Customer, Job, JobStatus } from "../types/models";

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
