import { supabase } from './supabase';
import type {
  Job,
  Invoice,
  Customer,
  Expense,
  Settings,
  CustomerNotes,
  PricebookEntry,
  RecurringJob,
  RecurringInvoice,
} from '@shared/types/models';

// The cloud data model is a set of owner-scoped blob tables:
//   { id, user_id, data jsonb, updated_at, deleted }
// with RLS on auth.uid() = user_id. This mirrors the mobile app's pull loop
// (../../utils/sync.ts). We read `data` and drop soft-deleted rows, exactly as
// the app does, so the web portal shows the same records.

type BlobRow<T> = { id: string; data: T; deleted: boolean | null };

async function fetchCollection<T>(table: string): Promise<T[]> {
  const { data, error } = await supabase
    .from(table)
    .select('id, data, deleted');
  if (error) throw error;
  return (data as BlobRow<T>[] | null ?? [])
    .filter((row) => !row.deleted && row.data)
    .map((row) => row.data);
}

export const fetchJobs = () => fetchCollection<Job>('jobs');
export const fetchInvoices = () => fetchCollection<Invoice>('invoices');
export const fetchCustomers = () => fetchCollection<Customer>('customers');
export const fetchExpenses = () => fetchCollection<Expense>('expenses');
export const fetchPricebook = () => fetchCollection<PricebookEntry>('pricebook');
// camelCase table names are quoted identifiers in Postgres — supabase-js
// resolves .from('recurringJobs') case-sensitively (see the migration
// 20260803_local_collections_sync.sql).
export const fetchRecurringJobs = () =>
  fetchCollection<RecurringJob>('recurringJobs');
export const fetchRecurringInvoices = () =>
  fetchCollection<RecurringInvoice>('recurringInvoices');

export async function fetchSettings(): Promise<Settings | null> {
  const { data, error } = await supabase
    .from('settings')
    .select('data')
    .maybeSingle();
  if (error) throw error;
  return (data?.data as Settings) ?? null;
}

export async function fetchCustomerNotes(): Promise<CustomerNotes> {
  const { data, error } = await supabase
    .from('customer_notes')
    .select('customer_key, note');
  if (error) throw error;
  const notes: CustomerNotes = {};
  for (const row of (data as { customer_key: string; note: string }[] | null) ??
    []) {
    notes[row.customer_key] = row.note;
  }
  return notes;
}

// This module is read-only by design: it exposes owner-scoped `fetch*` readers
// only. It intentionally contains no business-data write path (no insert /
// update / upsert / delete). When editing is introduced it belongs in a
// separate write module exposing typed, domain-specific operations that
// validate their payloads — not a generic `write(table, id, data)` — while
// Supabase RLS (auth.uid() = user_id) remains the ownership boundary. See
// `web/README.md` ("A note on the future editing surface") and the read-only
// architecture guard in `readOnly.arch.test.ts`.
