// utils/globalSearch.ts
// Cross-entity search behind Today's global search screen. Pure — the screen
// loads the collections and owns navigation; this owns matching and ordering.

import type { Customer, Invoice, Job } from "../types/models";

export interface SectionResult<T> {
  /** Up to `limit` matches, in the section's display order. */
  items: T[];
  /** Total matches, so the screen can render a "+N more" hint. */
  total: number;
}

export interface GlobalSearchResults {
  jobs: SectionResult<Job>;
  customers: SectionResult<Customer>;
  invoices: SectionResult<Invoice>;
  total: number;
}

export const GLOBAL_SEARCH_SECTION_LIMIT = 8;

const contains = (field: string | null | undefined, q: string): boolean =>
  Boolean(field) && (field as string).toLowerCase().includes(q);

export function jobMatches(job: Job, q: string): boolean {
  return (
    contains(job.title, q) ||
    contains(job.customerName, q) ||
    contains(job.address, q) ||
    contains(job.description, q) ||
    contains(job.notes, q)
  );
}

export function customerMatches(customer: Customer, q: string): boolean {
  return (
    contains(customer.name, q) ||
    contains(customer.phone, q) ||
    contains(customer.email, q) ||
    contains(customer.address, q) ||
    contains(customer.notes, q)
  );
}

export function invoiceMatches(invoice: Invoice, q: string): boolean {
  return (
    contains(invoice.number, q) ||
    contains(invoice.customer, q) ||
    contains(invoice.desc, q)
  );
}

function section<T>(matches: T[], limit: number): SectionResult<T> {
  return { items: matches.slice(0, limit), total: matches.length };
}

const EMPTY: GlobalSearchResults = {
  jobs: { items: [], total: 0 },
  customers: { items: [], total: 0 },
  invoices: { items: [], total: 0 },
  total: 0,
};

export function searchAll(
  data: { jobs: Job[]; customers: Customer[]; invoices: Invoice[] },
  query: string,
  limit: number = GLOBAL_SEARCH_SECTION_LIMIT,
): GlobalSearchResults {
  const q = query.trim().toLowerCase();
  if (!q) return EMPTY;

  // Newest work first; customers read best alphabetically.
  const jobs = data.jobs
    .filter((j) => jobMatches(j, q))
    .sort((a, b) => (b.createdAt || "").localeCompare(a.createdAt || ""));
  const customers = data.customers
    .filter((c) => customerMatches(c, q))
    .sort((a, b) => (a.name || "").localeCompare(b.name || ""));
  const invoices = data.invoices
    .filter((i) => invoiceMatches(i, q))
    .sort((a, b) => (b.due || "").localeCompare(a.due || ""));

  return {
    jobs: section(jobs, limit),
    customers: section(customers, limit),
    invoices: section(invoices, limit),
    total: jobs.length + customers.length + invoices.length,
  };
}
