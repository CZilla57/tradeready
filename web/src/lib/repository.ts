import { supabase } from './supabase';
import type {
  Job,
  Invoice,
  Customer,
  Expense,
  Settings,
  CustomerNotes,
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

/**
 * Write helper matching the blob shape the mobile sync layer upserts
 * (../../utils/sync.ts). Read-first MVP screens do not call this yet; it exists
 * so the editing surface that follows can persist through the same contract.
 */
export async function upsertRecord(
  table: string,
  id: string,
  data: unknown,
): Promise<void> {
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) throw new Error('Not signed in');
  const { error } = await supabase.from(table).upsert({
    id,
    user_id: user.id,
    data,
    updated_at: new Date().toISOString(),
    deleted: false,
  });
  if (error) throw error;
}
