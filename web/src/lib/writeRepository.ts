import { supabase } from './supabase';
import type {
  DateString,
  Invoice,
  Payment,
  PaymentDraft,
} from '@shared/types/models';
import {
  applyPayment,
  mergePaymentLedgers,
  newPaymentId,
  reconcilePaidFields,
  settleRemaining,
  toAmount,
  voidPayment as voidPaymentEntry,
} from '@shared/utils/invoicePayments';

// The web portal's ONLY business-data write path.
//
// Reads live in `repository.ts`; this module is the single place a Supabase
// business-data mutation may exist. The read-only architecture guard
// (`readOnly.arch.test.ts`) allow-lists exactly this file and fails the build
// if a mutation appears anywhere else — so read-only screens still cannot
// import a write path by accident.
//
// The cloud model is a set of owner-scoped blob rows
//   { id, user_id, data jsonb, updated_at, deleted }
// with RLS `for all … using/with check (auth.uid() = user_id)`. Writes are
// whole-blob upserts, exactly as the mobile sync layer performs them
// (../../utils/sync.ts → pushQueue). Every constraint below mirrors a rule the
// mobile push/pull loop already depends on; see web/EDITING_ROADMAP.md.
//
// This module implements roadmap P0.1 (ledger-preserving invoice writes). Other
// domains (jobs, customers, settings, …) will get their own typed operations
// here as later phases land.

/** Raised when an invoice write targets a row that isn't visible to this user. */
export class InvoiceNotFoundError extends Error {
  constructor(public readonly invoiceId: string) {
    super(`Invoice not found: ${invoiceId}`);
    this.name = 'InvoiceNotFoundError';
  }
}

/** Raised when a caller hands in a payment that fails validation (P1.3). */
export class PaymentValidationError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'PaymentValidationError';
  }
}

async function currentUserId(): Promise<string> {
  const { data, error } = await supabase.auth.getUser();
  if (error) throw error;
  const id = data.user?.id;
  if (!id) throw new Error('Not signed in');
  return id;
}

// P0.3 — the single source of a write's `updated_at`.
//
// Device pulls filter on `gt('updated_at', since)` (../../utils/sync.ts). A
// write that omits `updated_at` leaves the column untouched on the UPDATE side
// of the upsert, so the edit would never cross the watermark and never reach a
// phone; a backdated stamp is invisible the same way. We stamp the client clock
// here, matching mobile's `pushedAt = new Date()`, so web and mobile behave
// identically today.
//
// Residual (roadmap P0.3): this trusts the browser clock, which is less
// reliable than a device's. The durable fix is the server-side `set_updated_at`
// trigger in supabase/migrations/20260831_updated_at_server_authority.sql, which
// overrides `updated_at` with the DB clock on every write. That trigger is
// backward-compatible — this stamp is simply replaced server-side — so once it
// is confirmed applied in production, sending `updated_at` here becomes optional
// cleanup rather than a correctness requirement. Centralised here so that swap
// is one edit.
function writeTimestamp(): string {
  return new Date().toISOString();
}

/**
 * Load the current server copy of an invoice by id.
 *
 * P0.1/P0.2: every invoice write starts from the AUTHORITATIVE server blob, not
 * from whatever the screen last rendered. The payment ledger legitimately grows
 * server-side (the Stripe webhook appends) between a page load and a save;
 * building the write on the freshly-fetched row is what keeps a concurrently
 * recorded payment from being clobbered by a whole-blob replace.
 */
async function loadInvoice(id: string): Promise<Invoice> {
  const invoice = await tryLoadInvoice(id);
  if (!invoice) throw new InvoiceNotFoundError(id);
  return invoice;
}

/** Like `loadInvoice`, but returns null for a not-yet-existing row (a create). */
async function tryLoadInvoice(id: string): Promise<Invoice | null> {
  const { data, error } = await supabase
    .from('invoices')
    .select('data, deleted')
    .eq('id', id)
    .maybeSingle();
  if (error) throw error;
  if (!data || data.deleted || !data.data) return null;
  return data.data as Invoice;
}

/**
 * Whole-blob upsert of an invoice, stamped exactly as the mobile push does:
 * fresh `updated_at`, `deleted: false`, `user_id = auth.uid()`. The only place
 * this module touches `supabase.from('invoices')` with a mutation.
 */
async function persistInvoice(invoice: Invoice): Promise<Invoice> {
  const user_id = await currentUserId();
  const { error } = await supabase.from('invoices').upsert({
    id: invoice.id,
    user_id,
    data: invoice,
    updated_at: writeTimestamp(),
    deleted: false,
  });
  if (error) throw error;
  return invoice;
}

// ---------------------------------------------------------------------------
// Soft-delete (roadmap P0.4)
//
// Deletes are recorded as a TOMBSTONE — `deleted: true` plus a fresh
// `updated_at` — never a row removal, exactly as the mobile push does
// (../../utils/sync.ts → the `op === 'delete'` branch). A hard `DELETE` would
// leave every other device with no record that the row is gone, so the next
// pull that predates the delete would treat the row as new and resurrect it.
// The fresh `updated_at` is what carries the tombstone across each device's
// `gt('updated_at', since)` pull filter.
//
// This is only the persistence primitive: cross-entity consequences (an invoice
// that references a deleted customer, a job's linked records) are DOMAIN logic
// that belongs with each delete's UI, not here. Add that per entity when a
// delete surface lands — this function just guarantees the write itself is a
// correct, propagating tombstone.
// ---------------------------------------------------------------------------

/** The owner-scoped blob collections that carry a `deleted` tombstone column. */
type DeletableCollection =
  | 'jobs'
  | 'invoices'
  | 'customers'
  | 'expenses'
  | 'pricebook'
  | 'recurringJobs'
  | 'recurringInvoices';

async function softDelete(
  collection: DeletableCollection,
  id: string,
): Promise<void> {
  const user_id = await currentUserId();
  // Scope by id AND user_id to mirror the mobile delete exactly; RLS already
  // restricts this to the owner's rows, so the user_id filter is belt-and-braces.
  const { error } = await supabase
    .from(collection)
    .update({ deleted: true, updated_at: writeTimestamp() })
    .eq('id', id)
    .eq('user_id', user_id);
  if (error) throw error;
}

export const deleteJob = (id: string) => softDelete('jobs', id);
export const deleteInvoice = (id: string) => softDelete('invoices', id);
export const deleteCustomer = (id: string) => softDelete('customers', id);
export const deleteExpense = (id: string) => softDelete('expenses', id);
export const deletePricebookEntry = (id: string) => softDelete('pricebook', id);
export const deleteRecurringJob = (id: string) =>
  softDelete('recurringJobs', id);
export const deleteRecurringInvoice = (id: string) =>
  softDelete('recurringInvoices', id);

function validatePaymentDraft(draft: PaymentDraft): void {
  const amount = toAmount(draft.amount);
  if (!(amount > 0)) {
    throw new PaymentValidationError('Payment amount must be a positive number');
  }
  if (!/^\d{4}-\d{2}-\d{2}$/.test(draft.date)) {
    throw new PaymentValidationError('Payment date must be "YYYY-MM-DD"');
  }
}

/**
 * Save an edited invoice, preserving the server-side payment ledger (P0.1/P0.2).
 *
 * The caller's `edited` blob may carry a ledger that is already stale relative
 * to the cloud, so we re-fetch the current row and union the two ledgers while
 * keeping the caller's scalar edits. `mergePaymentLedgers(server, edited)` does
 * exactly that: it takes the REMOTE (here: `edited`) scalars, unions payments by
 * id, then re-derives `paid`/`paidAt` from the union — so an edit to `amount`
 * can never leave the paid flag drifting from the money actually collected.
 *
 * A brand-new invoice (no server row yet) has no ledger to preserve;
 * `reconcilePaidFields` normalises its paid/paidAt without re-entering the
 * legacy fallback.
 */
export async function saveInvoice(edited: Invoice): Promise<Invoice> {
  const server = await tryLoadInvoice(edited.id);
  const next = server
    ? mergePaymentLedgers(server, edited)
    : reconcilePaidFields(edited);
  return persistInvoice(next);
}

/**
 * Record a payment against an invoice.
 *
 * Starts from the authoritative server ledger, so any payment appended
 * elsewhere (a Stripe webhook, another device) is carried forward rather than
 * overwritten. `applyPayment` is idempotent by payment id and re-derives
 * paid/paidAt, so a retried save can't double-count.
 */
export async function recordInvoicePayment(
  invoiceId: string,
  draft: PaymentDraft,
): Promise<Invoice> {
  validatePaymentDraft(draft);
  const server = await loadInvoice(invoiceId);
  const payment: Payment = { id: newPaymentId(), ...draft };
  return persistInvoice(applyPayment(server, payment));
}

/**
 * Mark an invoice paid by recording a single payment for the remaining balance.
 *
 * Goes through the ledger (`settleRemaining`) rather than flipping `paid: true`
 * directly — a bare flag write is discarded by the ledger merge on the next sync
 * once an invoice has any recorded payment. A no-op on an already-settled
 * invoice.
 */
export async function markInvoicePaid(
  invoiceId: string,
  date: DateString,
): Promise<Invoice> {
  const server = await loadInvoice(invoiceId);
  return persistInvoice(settleRemaining(server, date));
}

/**
 * Void a payment on an invoice.
 *
 * Voiding keeps the entry and stamps `voidedAt` (deletion recorded as data, so a
 * server-side union can't resurrect it) and re-derives paid/paidAt. Irreversible
 * by design — to correct a mistaken void, record a new payment.
 */
export async function voidInvoicePayment(
  invoiceId: string,
  paymentId: string,
  voidedAt: DateString,
): Promise<Invoice> {
  const server = await loadInvoice(invoiceId);
  return persistInvoice(voidPaymentEntry(server, paymentId, voidedAt));
}
