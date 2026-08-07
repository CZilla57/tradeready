// utils/importMapping.ts
// Deterministic column→field mapping for CSV import. Header-vocabulary tables
// (Jobber / Housecall Pro / QuickBooks + generic synonyms) propose a mapping;
// the UI lets the user override. NO AI, NO network. Date parsing lands local
// "YYYY-MM-DD" strings (FA-039) via dateHelpers.toDateString — never toISOString.

import { toDateString } from "./dateHelpers";

export type ImportEntity = "customers" | "jobs" | "invoices" | "expenses";

export interface FieldDef {
  key: string;
  label: string;
  required: boolean;
}

export const FIELD_DEFS: Record<ImportEntity, FieldDef[]> = {
  customers: [
    { key: "name", label: "Name", required: true },
    { key: "email", label: "Email", required: false },
    { key: "phone", label: "Phone", required: false },
    { key: "address", label: "Address", required: false },
    { key: "notes", label: "Notes", required: false },
  ],
  jobs: [
    { key: "title", label: "Job title", required: true },
    { key: "customerName", label: "Customer name", required: true },
    { key: "status", label: "Status", required: false },
    { key: "scheduledDate", label: "Scheduled date", required: false },
    { key: "address", label: "Address", required: false },
    { key: "description", label: "Description", required: false },
    { key: "estimateTotal", label: "Estimate total", required: false },
    { key: "notes", label: "Notes", required: false },
  ],
  invoices: [
    { key: "customer", label: "Customer name", required: true },
    { key: "amount", label: "Amount", required: true },
    { key: "number", label: "Invoice number", required: false },
    { key: "due", label: "Due date", required: false },
    { key: "paidAt", label: "Paid date", required: false },
    { key: "desc", label: "Description", required: false },
    { key: "email", label: "Email", required: false },
    { key: "phone", label: "Phone", required: false },
  ],
  expenses: [
    { key: "amount", label: "Amount", required: true },
    { key: "date", label: "Date", required: true },
    { key: "description", label: "Description", required: false },
    { key: "category", label: "Category", required: false },
    { key: "notes", label: "Notes", required: false },
  ],
};

// Synonym tables: field key → lowercase header phrases that should map to it.
// Order within an entity matters only for readability; matching is longest-first
// so "estimate total" wins over "total".
const SYNONYMS: Record<ImportEntity, Record<string, string[]>> = {
  customers: {
    name: ["name", "full name", "customer", "client", "contact", "customer name", "first name", "last name"],
    email: ["email", "email address", "e-mail"],
    phone: ["phone", "phone number", "mobile", "cell", "telephone", "mobile phone"],
    address: ["address", "street address", "billing address", "street", "location"],
    notes: ["notes", "note", "comments", "description"],
  },
  jobs: {
    title: ["title", "job title", "job name", "service", "job"],
    customerName: ["customer", "customer name", "client", "client name", "contact"],
    status: ["status", "stage", "job status"],
    scheduledDate: ["scheduled date", "date", "start date", "appointment date", "scheduled"],
    address: ["address", "job address", "service address", "location", "street address"],
    description: ["description", "details", "scope"],
    estimateTotal: ["estimate total", "estimate", "quote", "quoted", "total"],
    notes: ["notes", "note", "comments"],
  },
  invoices: {
    customer: ["customer", "customer name", "client", "client name", "bill to", "contact"],
    amount: ["amount", "total", "invoice total", "amount due", "balance"],
    number: ["number", "invoice #", "invoice number", "invoice no", "inv #", "doc number"],
    due: ["due", "due date", "date due"],
    paidAt: ["paid on", "paid date", "date paid", "payment date"],
    desc: ["description", "memo", "details", "line item", "notes"],
    email: ["email", "email address"],
    phone: ["phone", "mobile", "cell", "telephone"],
  },
  expenses: {
    amount: ["amount", "total", "cost", "price", "debit"],
    date: ["date", "transaction date", "posted date", "purchase date"],
    description: ["description", "memo", "payee", "vendor", "merchant", "details"],
    category: ["category", "type", "account", "expense category"],
    notes: ["notes", "note", "comments"],
  },
};

function normHeader(h: string): string {
  return h.trim().toLowerCase().replace(/[_\-]+/g, " ").replace(/\s+/g, " ");
}

export interface DetectedMapping {
  mapping: (string | null)[];
  dateFormat: DateFormat | null;
}

export function detectMapping(entity: ImportEntity, headers: string[]): DetectedMapping {
  const table = SYNONYMS[entity];
  // Build a longest-first lookup so multi-word synonyms beat single words.
  const entries: { phrase: string; key: string }[] = [];
  for (const key of Object.keys(table)) {
    for (const phrase of table[key]) entries.push({ phrase, key });
  }
  entries.sort((a, b) => b.phrase.length - a.phrase.length);

  const mapping = headers.map((h) => {
    const nh = normHeader(h);
    const exact = entries.find((e) => e.phrase === nh);
    if (exact) return exact.key;
    const partial = entries.find((e) => nh.includes(e.phrase));
    return partial ? partial.key : null;
  });

  // Detected date format is filled in later by the engine/screen from sample
  // cells of whichever column mapped to a date field; default null here.
  return { mapping, dateFormat: null };
}

export type DateFormat = "MDY" | "DMY" | "YMD";

const ISO_RE = /^(\d{4})-(\d{1,2})-(\d{1,2})$/;
const NUM_RE = /^(\d{1,4})[/\-.](\d{1,2})[/\-.](\d{1,4})$/;

export function detectDateFormat(samples: string[]): DateFormat | null {
  let sawNumeric = false;
  let firstSlotOver12 = false;
  let secondSlotOver12 = false;
  for (const raw of samples) {
    const s = (raw || "").trim();
    if (!s) continue;
    if (ISO_RE.test(s)) return "YMD";
    const m = NUM_RE.exec(s);
    if (!m) continue;
    sawNumeric = true;
    const a = Number(m[1]);
    const b = Number(m[2]);
    if (m[1].length === 4) return "YMD";
    if (a > 12) firstSlotOver12 = true;
    if (b > 12) secondSlotOver12 = true;
  }
  if (!sawNumeric) return null;
  if (firstSlotOver12 && !secondSlotOver12) return "DMY";
  return "MDY"; // US default when ambiguous
}

export function parseImportDate(raw: string, format: DateFormat | null): string | null {
  const s = (raw || "").trim();
  if (!s) return null;

  let y: number, mo: number, d: number;
  const iso = ISO_RE.exec(s);
  if (iso) {
    y = Number(iso[1]); mo = Number(iso[2]); d = Number(iso[3]);
  } else {
    const m = NUM_RE.exec(s);
    if (!m) return null;
    const p1 = Number(m[1]), p2 = Number(m[2]), p3 = Number(m[3]);
    const fmt = format ?? "MDY";
    if (fmt === "YMD" || m[1].length === 4) { y = p1; mo = p2; d = p3; }
    else if (fmt === "DMY") { d = p1; mo = p2; y = p3; }
    else { mo = p1; d = p2; y = p3; }
    if (y < 100) y += 2000;
  }

  if (mo < 1 || mo > 12 || d < 1 || d > 31) return null;
  const dt = new Date(y, mo - 1, d);                 // local-frame construction
  if (dt.getFullYear() !== y || dt.getMonth() !== mo - 1 || dt.getDate() !== d) return null;
  return toDateString(dt);                            // FA-039-safe formatting
}
