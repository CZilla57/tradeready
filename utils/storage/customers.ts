// utils/storage/customers.ts
// The unified customer registry (roadmap #5). Every customer is a real record in
// the `customers` collection with a stable id; jobs (customerId) and invoices
// (customerId) both link to it, while `customer`/`customerName` stay as
// denormalized display copies. The de-facto join key is the normalized (trimmed
// + lowercased) name — that's how an invoice's typed name is matched to (or
// promoted into) a real record.

import AsyncStorage from "@react-native-async-storage/async-storage";
import { KEYS } from "./keys";
import {
  loadInvoices, saveInvoices,
  loadJobs, saveJobs,
  loadCustomers, saveCustomers,
} from "./collections";
import type { Customer, CustomerNotes, Invoice } from "../../types/models";

// --- Customer Notes (legacy) ---
// Notes now live on the customer record's `notes` field. The old flat
// { [normalizedName]: note } map is kept read-only so migrateCustomerIdentity
// can fold any pre-#5 notes into the records; nothing writes to it anymore, so
// the customer_notes sync table is dormant.

export async function loadCustomerNotes(): Promise<CustomerNotes> {
  try {
    const raw = await AsyncStorage.getItem(KEYS.customerNotes);
    return raw ? JSON.parse(raw) : {};
  } catch {
    return {};
  }
}

const normalizeName = (name: string | null | undefined): string =>
  (name || "").trim().toLowerCase();

// Monotonic within a run so a migration creating many records in the same
// millisecond can't collide on `c<Date.now()>`.
let _cidCounter = 0;
function newCustomerId(): string {
  _cidCounter += 1;
  return `c${Date.now()}_${_cidCounter}`;
}

/** Contact fields accepted by the customer creation/upsert paths. */
export interface CustomerFields {
  name?: string;
  email?: string;
  phone?: string;
  address?: string;
}

export interface UpsertCustomerResult {
  customer: Customer | null;
  customers: Customer[];
  changed: boolean;
}

// Pure core: find a record by normalized name (backfilling only *blank* contact
// fields — never clobbering existing data) or append a fresh record. Returns
// { customer, customers: nextArray, changed }. Does no I/O so a migration can
// batch many upserts over one in-memory array and save once.
export function upsertCustomerInList(
  customers: Customer[],
  { name, email = "", phone = "", address = "" }: CustomerFields = {},
): UpsertCustomerResult {
  const key = normalizeName(name);
  if (!key) return { customer: null, customers, changed: false };

  const idx = customers.findIndex((c) => normalizeName(c.name) === key);
  if (idx >= 0) {
    const existing = customers[idx];
    const merged: Customer = {
      ...existing,
      email:   existing.email   || email   || "",
      phone:   existing.phone   || phone   || "",
      address: existing.address || address || "",
    };
    const changed =
      merged.email !== existing.email ||
      merged.phone !== existing.phone ||
      merged.address !== existing.address;
    return {
      customer: merged,
      customers: changed ? customers.map((c, i) => (i === idx ? merged : c)) : customers,
      changed,
    };
  }

  const customer: Customer = {
    id: newCustomerId(),
    name: (name || "").trim(),
    email: email || "",
    phone: phone || "",
    address: address || "",
    notes: "",
    createdAt: new Date().toISOString(),
  };
  return { customer, customers: [...customers, customer], changed: true };
}

// Resolve a job/invoice's linked customer: by id when the link is intact, else
// by normalized display name. Ids can dangle — e.g. a recurring rule created
// before a sample-id remap keeps the old customerId — and the name is the
// registry's de-facto join key, so a name hit is the same person. Returns null
// only when neither resolves.
export function resolveCustomer(
  customers: Customer[],
  link: { customerId?: string | null; customerName?: string | null },
): Customer | null {
  if (link.customerId) {
    const byId = customers.find((c) => c.id === link.customerId);
    if (byId) return byId;
  }
  const key = normalizeName(link.customerName);
  if (!key) return null;
  return customers.find((c) => normalizeName(c.name) === key) ?? null;
}

// Async wrapper for the single-customer creation paths (invoice/job/manual add).
// Loads the collection, upserts, persists only if something changed, and returns
// the record (or null when no usable name was given).
export async function getOrCreateCustomer(fields: CustomerFields = {}): Promise<Customer | null> {
  const customers = await loadCustomers();
  const { customer, customers: next, changed } = upsertCustomerInList(customers, fields);
  if (customer && changed) await saveCustomers(next);
  return customer;
}

// Set a customer's notes on their record — the single home for notes since #5.
// Promotes an invoice-derived customer (still keyed by name, no record yet) into
// a real record first. Returns the record id, or null if there's no usable name.
export async function updateCustomerNotes(
  customer: Partial<Customer> | null | undefined,
  note: string,
): Promise<string | null> {
  const customers = await loadCustomers();
  const idx = customers.findIndex((c) => c.id === customer?.id);
  if (idx >= 0) {
    await saveCustomers(customers.map((c, i) => (i === idx ? { ...c, notes: note } : c)));
    return customers[idx].id;
  }
  const { customer: rec, customers: next } = upsertCustomerInList(customers, {
    name: customer?.name,
    email: customer?.email,
    phone: customer?.phone,
  });
  if (!rec) return null;
  await saveCustomers(next.map((c) => (c.id === rec.id ? { ...c, notes: note } : c)));
  return rec.id;
}

// Backfill blank invoice contact fields (email/phone) from the linked customer —
// the customer→invoice half of the denormalization sync. Pure, no I/O. Mirrors
// upsertCustomerInList's "backfill blank, never clobber" rule. Matches the
// invoice's customer by customerId first, then by normalized name.
export function backfillInvoiceContacts(
  invoices: Invoice[],
  customers: Customer[],
): { invoices: Invoice[]; changed: boolean } {
  const byId = new Map(customers.map((c) => [c.id, c]));
  const byName = new Map<string, Customer>();
  for (const c of customers) {
    const key = normalizeName(c.name);
    if (key && !byName.has(key)) byName.set(key, c);
  }

  let changed = false;
  const next = invoices.map((inv) => {
    const cust: Customer | undefined =
      (inv.customerId ? byId.get(inv.customerId) : undefined) ||
      byName.get(normalizeName(inv.customer));
    if (!cust) return inv;

    const email = !inv.email && cust.email ? cust.email : inv.email;
    const phone = !inv.phone && cust.phone ? cust.phone : inv.phone;
    if (email === inv.email && phone === inv.phone) return inv;

    changed = true;
    return { ...inv, email, phone };
  });

  return { invoices: changed ? next : invoices, changed };
}

export interface MigrationResult {
  customersChanged: boolean;
  invoicesChanged: boolean;
  jobsChanged: boolean;
}

// One-time (but idempotent + flag-free) backfill of the unified model over any
// data that predates it — including cloud records that sync pulls in later, which
// is why there's no permanent "already ran" flag. It only writes a collection
// when it actually changed, so once stable it's a cheap read-only scan.
export async function migrateCustomerIdentity(): Promise<MigrationResult> {
  const [invoices, jobs, customers, notesMap] = await Promise.all([
    loadInvoices(),
    loadJobs(),
    loadCustomers(),
    loadCustomerNotes(),
  ]);

  let nextCustomers = customers;
  let customersChanged = false;

  // 1. Stamp customerId on invoices, creating records for invoice-only customers.
  let invoicesChanged = false;
  let nextInvoices = invoices.map((inv) => {
    if (inv.customerId || !inv.customer?.trim()) return inv;
    const { customer, customers: c2, changed } = upsertCustomerInList(nextCustomers, {
      name: inv.customer,
      email: inv.email,
      phone: inv.phone,
    });
    if (changed) { nextCustomers = c2; customersChanged = true; }
    if (!customer) return inv;
    invoicesChanged = true;
    return { ...inv, customerId: customer.id };
  });

  // 2. Stamp customerId on orphan jobs (typed name, no id) — folds in defect #3.
  let jobsChanged = false;
  const nextJobs = jobs.map((job) => {
    if (job.customerId || !job.customerName?.trim()) return job;
    const { customer, customers: c2, changed } = upsertCustomerInList(nextCustomers, {
      name: job.customerName,
    });
    if (changed) { nextCustomers = c2; customersChanged = true; }
    if (!customer) return job;
    jobsChanged = true;
    return { ...job, customerId: customer.id };
  });

  // 3. Merge the legacy customerNotes map into record.notes (record wins if it
  //    already has notes). The map is retired in a later step; until then a note
  //    cleared to empty could refill on the next run — acceptable interim.
  if (Object.keys(notesMap).length) {
    nextCustomers = nextCustomers.map((c) => {
      if (c.notes && c.notes.trim()) return c;
      const note = notesMap[normalizeName(c.name)];
      if (note && note.trim()) { customersChanged = true; return { ...c, notes: note }; }
      return c;
    });
  }

  // 4. Backfill blank invoice contact fields (email/phone) from the linked
  //    customer — the customer→invoice direction steps 1–3 don't cover (step 1
  //    only flows invoice→customer, then freezes the invoice once it has a
  //    customerId). Runs after customerId stamping so invoices are linked.
  const backfilled = backfillInvoiceContacts(nextInvoices, nextCustomers);
  if (backfilled.changed) {
    nextInvoices = backfilled.invoices;
    invoicesChanged = true;
  }

  if (customersChanged) await saveCustomers(nextCustomers);
  if (invoicesChanged) await saveInvoices(nextInvoices);
  if (jobsChanged) await saveJobs(nextJobs);

  return { customersChanged, invoicesChanged, jobsChanged };
}
