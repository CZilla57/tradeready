// Pure per-entity builders for CSV import. Given parsed rows + a column→field
// mapping + the current collection, each builder returns the FULL next array to
// save plus per-row outcomes and counts. NO I/O, NO network — the screen does
// load/save. Customers are created ONLY through upsertCustomerInList so the
// normalized-name join + blank-field backfill rules are never bypassed.

import { upsertCustomerInList } from "./storage/customers";
import type { Customer } from "../types/models";

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
