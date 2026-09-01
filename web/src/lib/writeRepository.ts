import { supabase } from './supabase';
import type {
  Customer,
  DateString,
  Expense,
  Invoice,
  Job,
  Payment,
  PaymentDraft,
  PricebookEntry,
  RecurrenceCadence,
  RecurrenceEndCondition,
  RecurringInvoice,
  RecurringJob,
  ScheduleConfig,
  Settings,
  TimeString,
} from '@shared/types/models';
import { OPERATIONAL_STATUS_ADVANCE } from '../ui/status';
import { SECURE_FIELDS } from '@shared/utils/storage/keys';
import { withArchived } from '@shared/utils/archive';
import { getTodayDateString } from '@shared/utils/dateHelpers';
import { calculateNextDate, isEndConditionMet } from '@shared/utils/recurrence';
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

/** Raised when a job write targets a row that isn't visible to this user. */
export class JobNotFoundError extends Error {
  constructor(public readonly jobId: string) {
    super(`Job not found: ${jobId}`);
    this.name = 'JobNotFoundError';
  }
}

/**
 * Raised when a status advance is attempted from a status the portal isn't
 * allowed to advance from — either a status with no sanctioned operational
 * transition, or one that raced ahead on the server between the screen render
 * and the write (the fresh-row re-check below catches that too).
 */
export class JobStatusTransitionError extends Error {
  constructor(public readonly status: string) {
    super(`No operational status advance is available from "${status}"`);
    this.name = 'JobStatusTransitionError';
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
 * Whole-blob upsert of one owner-scoped collection row, stamped exactly as the
 * mobile push does: fresh `updated_at`, `deleted: false`, `user_id = auth.uid()`.
 * The single low-level write primitive the typed operations build on.
 */
async function upsertBlobRow(
  collection:
    | 'invoices'
    | 'customers'
    | 'jobs'
    | 'pricebook'
    | 'expenses'
    | 'recurringJobs'
    | 'recurringInvoices',
  id: string,
  data: unknown,
): Promise<void> {
  const user_id = await currentUserId();
  const { error } = await supabase.from(collection).upsert({
    id,
    user_id,
    data,
    updated_at: writeTimestamp(),
    deleted: false,
  });
  if (error) throw error;
}

async function persistInvoice(invoice: Invoice): Promise<Invoice> {
  await upsertBlobRow('invoices', invoice.id, invoice);
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

// ---------------------------------------------------------------------------
// Settings (roadmap P0.5)
//
// The settings row is a single wide blob keyed by user_id (no id, no `deleted`).
// A write has TWO non-negotiable invariants:
//
//   * Preserve unrendered fields (P0.2). The portal displays only some settings;
//     a write must merge onto the FULL current server blob, never a partial the
//     UI reconstructed, or a field the portal doesn't render is lost.
//
//   * Never write a credential field (P0.5). providerKey / anthropicKey /
//     groqKey live in the device SecureStore and must never enter the cloud
//     blob. A legacy blob written before that split can still carry them inline
//     (the exact case mobile's pushAllLocalToCloud strips for), so we strip on
//     the way out — iterating SECURE_FIELDS, never hand-naming (hand-naming is
//     how groqKey once went unstripped: utils/storage/keys.ts).
// ---------------------------------------------------------------------------

async function loadSettings(): Promise<Settings | null> {
  const { data, error } = await supabase
    .from('settings')
    .select('data')
    .maybeSingle();
  if (error) throw error;
  return (data?.data as Settings) ?? null;
}

/** Remove every credential field, by iterating the shared constant. */
function stripSecureFields(settings: Settings): Settings {
  const safe = { ...settings } as Record<string, unknown>;
  for (const field of SECURE_FIELDS) delete safe[field];
  return safe as unknown as Settings;
}

/** Strip credentials and upsert a fully-merged settings blob. The single write
 *  point both settings ops share, so the P0.5 invariants live in one place. */
async function persistSettings(merged: Settings): Promise<Settings> {
  const safe = stripSecureFields(merged);
  const user_id = await currentUserId();
  // The settings row has no `id` / `deleted` — upsert conflicts on user_id,
  // exactly as the mobile push does (../../utils/sync.ts).
  const { error } = await supabase.from('settings').upsert({
    user_id,
    data: safe,
    updated_at: writeTimestamp(),
  });
  if (error) throw error;
  return safe;
}

/**
 * Apply a patch to the user's settings.
 *
 * Merges the patch onto the current server blob (preserving fields the portal
 * never renders), strips any credential field — whether it rode in on a legacy
 * server blob or was mistakenly included in the patch — and upserts. Finer-
 * grained typed operations (e.g. updateBusinessProfile) can wrap this as the
 * settings edit UI defines its sections; the two invariants live here so every
 * such wrapper inherits them.
 */
export async function saveSettings(patch: Partial<Settings>): Promise<Settings> {
  const current = (await loadSettings()) ?? ({} as Settings);
  return persistSettings({ ...current, ...patch });
}

/**
 * Apply a patch to the owner's schedule config (roadmap P3 stage 4).
 *
 * `settings.schedule` is a NESTED sub-blob, and its slot-booking fields
 * (`bookableSlotsEnabled`, `slotLeadHours`, `slotWindowDays`, `timeZone`) are
 * written by a DIFFERENT surface — the mobile Booking screen — than the working
 * hours / days / appointment / time-off fields the portal edits. A flat
 * `saveSettings({ schedule })` would replace the whole sub-object and drop those
 * booking fields. So this deep-merges the patch onto the FRESHLY-loaded server
 * `schedule` (P0.2 applied one level down): every schedule field the portal
 * doesn't set is preserved from the authoritative server copy. Callers should
 * pass values already normalised the way `resolveSchedule` expects (explicit
 * `workDayStart < workDayEnd`, ≥1 work day, non-negative minutes).
 */
export async function saveSchedule(
  patch: Partial<ScheduleConfig>,
): Promise<Settings> {
  const current = (await loadSettings()) ?? ({} as Settings);
  return persistSettings({
    ...current,
    schedule: { ...(current.schedule ?? {}), ...patch },
  });
}

// ---------------------------------------------------------------------------
// Customers (roadmap P3 stage 2)
//
// A Customer is a plain last-write-wins blob — it has no server-appended field
// (unlike the invoice ledger), so a whole-blob write is correct, matching the
// mobile `saveCustomers` path. Notes now live on the record itself
// (`customer.notes`); the legacy `customer_notes` table is being retired
// (utils/storage/customers.ts) and the portal never writes it. Archiving is just
// this same write with `archivedAt` set/cleared (the caller uses the shared
// `withArchived` helper), so it needs no separate op; hard delete goes through
// `deleteCustomer` (soft-delete tombstone) above.
// ---------------------------------------------------------------------------

/**
 * Save a customer record. The caller passes the FULL blob with its edits
 * applied, so fields the portal doesn't render (portal token, archivedAt,
 * importBatchId, …) are preserved (P0.2).
 */
export async function saveCustomer(customer: Customer): Promise<Customer> {
  await upsertBlobRow('customers', customer.id, customer);
  return customer;
}

// New client-generated ids must match the format mobile creates (P1.4). The
// mobile customer id is `c<Date.now()>_<counter>` (utils/storage/customers.ts
// `newCustomerId`), the counter making ids unique within a burst that shares a
// millisecond. Reproduced here so a portal-created customer is indistinguishable
// from a phone-created one.
let _cidCounter = 0;
function newCustomerId(): string {
  _cidCounter += 1;
  return `c${Date.now()}_${_cidCounter}`;
}

/** The fields a new customer is created from. */
export interface NewCustomerFields {
  name: string;
  email: string;
  phone: string;
  address: string;
  notes: string;
}

/**
 * Create a new customer (roadmap P3 stage 5 — creation flows).
 *
 * Mints a mobile-format id and stamps `createdAt`, producing the same
 * fresh-record shape mobile's `upsertCustomerInList` writes, then upserts by id.
 * Name-dedupe (mobile merges a same-name entry rather than duplicating) is a
 * DISPLAY-layer decision here: the caller checks the loaded list and blocks a
 * duplicate, so the portal never silently merges into a record the user can't
 * see. A brand-new id means this is a pure insert — no server row to preserve.
 */
export async function createCustomer(
  fields: NewCustomerFields,
): Promise<Customer> {
  const customer: Customer = {
    id: newCustomerId(),
    name: fields.name,
    email: fields.email,
    phone: fields.phone,
    address: fields.address,
    notes: fields.notes,
    createdAt: new Date().toISOString(),
  };
  await upsertBlobRow('customers', customer.id, customer);
  return customer;
}

// ---------------------------------------------------------------------------
// Jobs (roadmap P3 stage 3)
//
// A Job is NOT a safe whole-blob overwrite target. The Cloudflare Worker backend
// writes to the jobs table server-side when a customer acts on the estimate
// portal: `approval` (estimate approve/decline — consent is frozen once
// approved) and `changeOrders[].approval` (change-order responses). The mobile
// app also appends `timeSessions` and stamps `invoiceId`/`status` from its own
// workflow actions. A stale whole-blob push from the browser would clobber any
// of these — including a customer's just-submitted consent.
//
// So the portal edits ONLY operational fields, and applies them onto a FRESHLY
// re-fetched server row: everything the browser doesn't explicitly set (approval,
// changeOrders, timeSessions, status, invoiceId, pricing) is taken from the
// authoritative server copy and can't be lost. The residual — a customer action
// landing between the re-fetch and the write — is the same narrow window the
// invoice ledger and booking history carry (ARCHITECTURE.md).
//
// Status transitions, estimate/pricing, and approval/change-order editing are
// intentionally NOT here: they are cross-entity-coupled (status ↔ invoice,
// approval consent) and belong to a later, guarded step.
// ---------------------------------------------------------------------------

/** The operational job fields the portal may edit — none are consent- or
 *  cross-entity-coupled. */
export interface JobDetailsEdit {
  title: string;
  description: string;
  address: string;
  scheduledDate: DateString | null;
  scheduledStartTime: TimeString | null;
  scheduledEndTime: TimeString | null;
  notes: string;
}

async function loadJob(id: string): Promise<Job> {
  const { data, error } = await supabase
    .from('jobs')
    .select('data, deleted')
    .eq('id', id)
    .maybeSingle();
  if (error) throw error;
  if (!data || data.deleted || !data.data) throw new JobNotFoundError(id);
  return data.data as Job;
}

/**
 * Apply an operational-field edit to a job.
 *
 * Fetches the current server row and spreads the edit onto it, so every field
 * the portal does not set — notably `approval`, `changeOrders`, `timeSessions`,
 * `status`, `invoiceId`, and pricing — is preserved from the authoritative
 * server copy rather than a stale in-memory blob.
 */
export async function updateJobDetails(
  jobId: string,
  edit: JobDetailsEdit,
): Promise<Job> {
  const server = await loadJob(jobId);
  const next: Job = { ...server, ...edit };
  await upsertBlobRow('jobs', jobId, next);
  return next;
}

/** The schedule fields the calendar may assign/move. A null `scheduledDate`
 *  unschedules the job (sends it back to the "needs scheduling" pile). */
export interface JobScheduleEdit {
  scheduledDate: DateString | null;
  scheduledStartTime: TimeString | null;
  scheduledEndTime: TimeString | null;
}

// The ONE automatic, schedule-driven status transition, reimplemented web-side
// from utils/jobStatus.ts `advanceStatusForSchedule` (that module reaches
// JOB_STATUSES in pricingEngine, which pulls an RN component type and isn't
// web-importable — same reason invoiceMath/status.ts are reimplemented here).
// Assigning a date advances an `approved` job to `scheduled` (its pipeline
// `.next`); every other status is returned unchanged so later statuses never
// regress and earlier ones don't skip approval. Kept in lockstep with the
// shared helper (`web/src/ui/status.ts` JOB_PIPELINE pins the same order).
function advanceStatusForSchedule(
  status: Job['status'],
  hasSchedule: boolean,
): Job['status'] {
  return hasSchedule && status === 'approved' ? 'scheduled' : status;
}

/**
 * Assign, move, or clear a job's schedule from the calendar (roadmap P3 stage
 * 5b) — the "saveJob" the schedule flow needs.
 *
 * Applies onto a FRESHLY re-fetched server row (like `updateJobDetails`), so
 * consent/workflow fields the portal never sets (approval, changeOrders,
 * timeSessions, invoiceId, pricing) are preserved. Unlike `updateJobDetails`,
 * this DOES reconcile the one schedule-coupled derived field: gaining a date
 * advances an approved job to `scheduled`, matching the mobile scheduling
 * action (P0.6). Clearing the date never regresses a later status.
 */
export async function scheduleJob(
  jobId: string,
  edit: JobScheduleEdit,
): Promise<Job> {
  const server = await loadJob(jobId);
  const next: Job = {
    ...server,
    ...edit,
    status: advanceStatusForSchedule(server.status, !!edit.scheduledDate),
  };
  await upsertBlobRow('jobs', jobId, next);
  return next;
}

/** Archive or unarchive a job (the model's safe soft-removal). Operates on the
 *  fresh server row, so it never clobbers concurrent consent/workflow writes. */
export async function setJobArchived(
  jobId: string,
  archived: boolean,
): Promise<Job> {
  const server = await loadJob(jobId);
  const next = withArchived(server, archived, getTodayDateString());
  await upsertBlobRow('jobs', jobId, next);
  return next;
}

// ---------------------------------------------------------------------------
// Job status advance (roadmap P3 stage 3b — operational subset)
//
// The portal may fire ONLY the two purely-operational forward transitions that
// couple to nothing it doesn't own — scheduled→in_progress and
// in_progress→complete (`OPERATIONAL_STATUS_ADVANCE`, mirrored from the mobile
// pipeline `JOB_STATUSES[...].next`). Estimate approval (a customer-consent
// step), invoice creation (complete→invoiced), and payment (invoiced→paid) are
// deliberately excluded: the portal reflects those from the invoice ledger and
// the approval/change-order flows, it does not drive them here.
//
// The guard is authoritative on the FRESH server row, not the client's stale
// status: if the job already advanced elsewhere (a phone marked it complete, an
// invoice moved it to invoiced) the re-fetched status no longer maps and the
// write is rejected with JobStatusTransitionError rather than clobbering the
// further-along state — a concrete instance of the roadmap's refetch-before-
// write concurrency rule (P2.1). Every other field (approval, changeOrders,
// timeSessions, invoiceId, pricing) rides through untouched from the server copy.
//
// Unlike the mobile "mark complete", this does NOT run the opt-in auto-invoice
// or schedule a review request — those are separate flows the portal doesn't
// surface. The bare status change is safe and internally consistent on its own.
// ---------------------------------------------------------------------------

export async function advanceJobStatus(jobId: string): Promise<Job> {
  const server = await loadJob(jobId);
  const transition = OPERATIONAL_STATUS_ADVANCE[server.status];
  if (!transition) throw new JobStatusTransitionError(server.status);
  const next: Job = { ...server, status: transition.next };
  await upsertBlobRow('jobs', jobId, next);
  return next;
}

// ---------------------------------------------------------------------------
// Pricebook (roadmap P3 stage 4)
//
// A saved service is a plain last-write-wins blob. NOTE: `estimateTotal` is a
// DERIVED price (pricingEngine.calculateEstimate over labor/materials/markup/
// overhead/margin). The shared engine isn't cleanly web-importable (it pulls a
// type from an RN component module), so the portal edits only the metadata
// fields that don't affect the price — name, category, description. Editing the
// pricing inputs needs the recompute and is deferred (like invoice line items
// and job pricing). The caller passes the FULL entry with edits applied, so the
// untouched pricing fields round-trip (P0.2).
// ---------------------------------------------------------------------------

export async function savePricebookEntry(
  entry: PricebookEntry,
): Promise<PricebookEntry> {
  // Bump the blob's own updatedAt, matching the mobile save (distinct from the
  // row's server-authoritative updated_at column).
  const next: PricebookEntry = { ...entry, updatedAt: new Date().toISOString() };
  await upsertBlobRow('pricebook', entry.id, next);
  return next;
}

// Mobile mints a pricebook id as `pb-<Date.now()>` (screens/PricebookEntryScreen
// .tsx). We keep that exact shape but bump a monotonic guard so two creates in
// the same millisecond can't collide on the id (the mobile screen creates one at
// a time and doesn't guard; the portal shouldn't regress on uniqueness). P1.4.
let _pbLastMs = 0;
function newPricebookId(): string {
  let ms = Date.now();
  if (ms <= _pbLastMs) ms = _pbLastMs + 1;
  _pbLastMs = ms;
  return `pb-${ms}`;
}

/** The fields a new saved service is created from. `estimateTotal` is DERIVED —
 *  the caller recomputes it with the pricingMath port (P0.6), like the edit. New
 *  entries start with no materials/jobCosts (line-item authoring is deferred). */
export interface NewPricebookFields {
  name: string;
  category: string;
  description: string;
  laborHours: number;
  laborRate: number;
  materialMarkup: number;
  overhead: number;
  margin: number;
  estimateTotal: number;
}

/**
 * Create a new saved service (roadmap P3 stage 5 — creation flows).
 *
 * Mints a mobile-format id and stamps createdAt/updatedAt, producing the same
 * fresh-record shape the mobile PricebookEntryScreen writes, then upserts. Blank
 * category/description collapse to `undefined` (mobile stores them that way).
 */
export async function createPricebookEntry(
  fields: NewPricebookFields,
): Promise<PricebookEntry> {
  const now = new Date().toISOString();
  const entry: PricebookEntry = {
    id: newPricebookId(),
    name: fields.name,
    category: fields.category || undefined,
    description: fields.description || undefined,
    laborHours: fields.laborHours,
    laborRate: fields.laborRate,
    materials: [],
    materialMarkup: fields.materialMarkup,
    overhead: fields.overhead,
    margin: fields.margin,
    estimateTotal: fields.estimateTotal,
    createdAt: now,
    updatedAt: now,
  };
  await upsertBlobRow('pricebook', entry.id, entry);
  return entry;
}

// ---------------------------------------------------------------------------
// Expenses (roadmap P3 stage 4)
//
// A plain last-write-wins blob. New records are stamped with the shared
// `stampExpense` (id + createdAt) so their id format matches the mobile app
// exactly; the caller does that and hands the full Expense here. Delete goes
// through `deleteExpense` (soft-delete tombstone) above.
// ---------------------------------------------------------------------------

export async function saveExpense(expense: Expense): Promise<Expense> {
  await upsertBlobRow('expenses', expense.id, expense);
  return expense;
}

// ---------------------------------------------------------------------------
// Recurring rules (roadmap P3 stage 5)
//
// RecurringJob / RecurringInvoice blobs carry ADVANCING generation state —
// lastGeneratedDate, occurrenceCount, nextDueDate — stamped by the generation
// engines (utils/recurringJobs.ts / recurringInvoices.ts) as occurrences are
// created. A whole-blob web write built from stale in-memory state would roll
// that back. So pause/resume re-fetches the current server row (P0.2) and
// changes ONLY isActive (plus, on invoice resume, the nextDueDate fast-forward
// the mobile Resume performs), preserving every generation field.
//
// Resume asymmetry — do NOT "unify" the two: a recurring INVOICE fast-forwards
// nextDueDate past today so a paused plan never back-bills the occurrences that
// elapsed while paused (utils/recurringInvoices.ts, owner decision 2026-08-01).
// A recurring JOB deliberately KEEPS back-fill on resume (a job card is a to-do,
// not a receivable), so its resume just flips the flag.
//
// Editing the rule itself (cadence, amounts, end condition, nextDueDate) is
// deferred — it recomputes generation state and belongs with a later guarded
// step, like job status transitions (3b). Hard delete goes through
// deleteRecurringJob / deleteRecurringInvoice (soft-delete tombstones) above.
// ---------------------------------------------------------------------------

/** The engine's own `today` frame (UTC), matched exactly so the invoice resume
 *  fast-forward can't land off-by-one from checkAndGenerateRecurringInvoices. */
function engineToday(): DateString {
  return new Date().toISOString().split('T')[0] as DateString;
}

/**
 * A plan's nextDueDate advanced past `today`, for Resume — a web-safe copy of
 * utils/recurringInvoices.ts `fastForwardedNextDueDate` (that module pulls the
 * storage/network layer and isn't importable here). An already-ended plan is
 * returned unchanged, exactly as the shared helper does.
 */
function fastForwardedNextDueDate(
  rule: RecurringInvoice,
  today: DateString,
): DateString {
  if (isEndConditionMet(rule)) return rule.nextDueDate;
  let next = rule.nextDueDate;
  while (next <= today) next = calculateNextDate(next, rule.cadence);
  return next;
}

async function loadRecurringJob(id: string): Promise<RecurringJob> {
  const { data, error } = await supabase
    .from('recurringJobs')
    .select('data, deleted')
    .eq('id', id)
    .maybeSingle();
  if (error) throw error;
  if (!data || data.deleted || !data.data)
    throw new Error(`Recurring job not found: ${id}`);
  return data.data as RecurringJob;
}

async function loadRecurringInvoice(id: string): Promise<RecurringInvoice> {
  const { data, error } = await supabase
    .from('recurringInvoices')
    .select('data, deleted')
    .eq('id', id)
    .maybeSingle();
  if (error) throw error;
  if (!data || data.deleted || !data.data)
    throw new Error(`Recurring plan not found: ${id}`);
  return data.data as RecurringInvoice;
}

/** Pause or resume a recurring job. Resume keeps back-fill (no fast-forward),
 *  matching the mobile Pause/Resume; both operate on the fresh server row. */
export async function setRecurringJobActive(
  id: string,
  active: boolean,
): Promise<RecurringJob> {
  const server = await loadRecurringJob(id);
  const next: RecurringJob = { ...server, isActive: active };
  await upsertBlobRow('recurringJobs', id, next);
  return next;
}

/** The recurring-job rule fields the portal edits. `estimateTotal` is DERIVED
 *  (recomputed by the caller via `web/src/ui/pricingMath.ts` from the pricing
 *  inputs + the rule's existing materials/jobCosts, P0.6). Customer re-linking
 *  and material line-item editing are out of scope, like the plan editor. */
export interface RecurringJobRuleEdit {
  title: string;
  description: string;
  laborHours: number;
  laborRate: number;
  materialMarkup: number;
  overhead: number;
  margin: number;
  estimateTotal: number;
  cadence: RecurrenceCadence;
  endCondition: RecurrenceEndCondition;
  endCount?: number;
  endDate?: DateString;
  nextDueDate: DateString;
}

/**
 * Edit a recurring job's rule (roadmap P3 stage 5b).
 *
 * Mirrors `updateRecurringInvoiceRule`: applies the edited rule fields onto a
 * FRESHLY re-fetched server row, so the series' history — id, customerId/Name,
 * materials, jobCosts, occurrenceCount, lastGeneratedDate, isActive, createdAt —
 * is preserved (never rolled back), and normalises endCount/endDate to the
 * chosen endCondition. The one extra concern over the plan is the DERIVED
 * `estimateTotal`: unlike a plan's flat `amount`, a job's total is a
 * `calculateEstimate` derivation, so the caller recomputes it with the
 * pricingMath port (matching the mobile save) and hands it in here.
 */
export async function updateRecurringJobRule(
  id: string,
  edit: RecurringJobRuleEdit,
): Promise<RecurringJob> {
  const server = await loadRecurringJob(id);
  const next: RecurringJob = {
    ...server,
    title: edit.title,
    description: edit.description,
    laborHours: edit.laborHours,
    laborRate: edit.laborRate,
    materialMarkup: edit.materialMarkup,
    overhead: edit.overhead,
    margin: edit.margin,
    estimateTotal: edit.estimateTotal,
    cadence: edit.cadence,
    endCondition: edit.endCondition,
    endCount: edit.endCondition === 'count' ? edit.endCount : undefined,
    endDate: edit.endCondition === 'date' ? edit.endDate : undefined,
    nextDueDate: edit.nextDueDate,
  };
  await upsertBlobRow('recurringJobs', id, next);
  return next;
}

/** Pause or resume a maintenance plan. Resume fast-forwards nextDueDate past
 *  today so elapsed occurrences aren't back-billed; pause only flips the flag. */
export async function setRecurringInvoiceActive(
  id: string,
  active: boolean,
): Promise<RecurringInvoice> {
  const server = await loadRecurringInvoice(id);
  const next: RecurringInvoice = active
    ? { ...server, isActive: true, nextDueDate: fastForwardedNextDueDate(server, engineToday()) }
    : { ...server, isActive: false };
  await upsertBlobRow('recurringInvoices', id, next);
  return next;
}

// Mobile mints a maintenance-plan id as `ri<Date.now()>` (AddRecurringInvoice
// Screen). Same shape, monotonic-guarded so a same-ms burst can't collide. P1.4.
let _riLastMs = 0;
function newRecurringInvoiceId(): string {
  let ms = Date.now();
  if (ms <= _riLastMs) ms = _riLastMs + 1;
  _riLastMs = ms;
  return `ri${ms}`;
}

/** The fields a new maintenance plan is created from. The customer must be an
 *  existing record (the portal picks one), so both id and denormalized name are
 *  supplied — no inline customer creation here. */
export interface NewRecurringInvoiceFields {
  customerId: string;
  customerName: string;
  description: string;
  amount: number;
  dueDays: number;
  cadence: RecurrenceCadence;
  endCondition: RecurrenceEndCondition;
  endCount?: number;
  endDate?: DateString;
  nextDueDate: DateString;
  autoSendEnabled: boolean;
}

/**
 * Create a new maintenance plan (roadmap P3 stage 5 — creation flows).
 *
 * A standalone insert: unlike a recurring JOB (whose creation also spawns a
 * first job occurrence), a plan creates no invoice — the generation engine emits
 * on its next run from `nextDueDate`. Initialises the generation state to a fresh
 * series (occurrenceCount 0, lastGeneratedDate null, isActive true), matching the
 * mobile AddRecurringInvoiceScreen create, and normalises endCount/endDate to the
 * chosen condition.
 */
export async function createRecurringInvoice(
  fields: NewRecurringInvoiceFields,
): Promise<RecurringInvoice> {
  const rule: RecurringInvoice = {
    id: newRecurringInvoiceId(),
    customerId: fields.customerId,
    customerName: fields.customerName,
    description: fields.description,
    amount: fields.amount,
    dueDays: fields.dueDays,
    cadence: fields.cadence,
    endCondition: fields.endCondition,
    endCount: fields.endCondition === 'count' ? fields.endCount : undefined,
    endDate: fields.endCondition === 'date' ? fields.endDate : undefined,
    occurrenceCount: 0,
    lastGeneratedDate: null,
    nextDueDate: fields.nextDueDate,
    isActive: true,
    createdAt: getTodayDateString(),
    autoSendEnabled: fields.autoSendEnabled,
  };
  await upsertBlobRow('recurringInvoices', rule.id, rule);
  return rule;
}

/** The maintenance-plan rule fields the portal edits. Excludes customer
 *  re-linking (customerId/customerName — a customer-domain concern, deferred
 *  like invoice customer editing) and every generation-state field. */
export interface RecurringInvoiceRuleEdit {
  description: string;
  amount: number;
  dueDays: number;
  cadence: RecurrenceCadence;
  endCondition: RecurrenceEndCondition;
  endCount?: number;
  endDate?: DateString;
  nextDueDate: DateString;
  autoSendEnabled: boolean;
}

/**
 * Edit a maintenance plan's rule (roadmap P3 stage 5b).
 *
 * Applies the edited rule fields onto a FRESHLY re-fetched server row, so the
 * plan's history — id, customerId/customerName, occurrenceCount,
 * lastGeneratedDate, isActive, createdAt — is preserved exactly as the mobile
 * edit does (`{ ...r, ...shared }`), never rolled back by a stale whole-blob
 * write. endCount/endDate are normalised to the chosen endCondition so a stale
 * bound can't linger (e.g. switching 'count' → 'never' clears endCount). Unlike
 * a RecurringJob, the plan's `amount` is a flat entered value (no pricingEngine
 * estimate), so there is no derived pricing to recompute. autoSend gating on a
 * valid customer email is enforced at GENERATION time (Phase 6), so enabling it
 * here without an email is harmless — it simply won't send until one exists.
 */
export async function updateRecurringInvoiceRule(
  id: string,
  edit: RecurringInvoiceRuleEdit,
): Promise<RecurringInvoice> {
  const server = await loadRecurringInvoice(id);
  const next: RecurringInvoice = {
    ...server,
    description: edit.description,
    amount: edit.amount,
    dueDays: edit.dueDays,
    cadence: edit.cadence,
    endCondition: edit.endCondition,
    endCount: edit.endCondition === 'count' ? edit.endCount : undefined,
    endDate: edit.endCondition === 'date' ? edit.endDate : undefined,
    nextDueDate: edit.nextDueDate,
    autoSendEnabled: edit.autoSendEnabled,
  };
  await upsertBlobRow('recurringInvoices', id, next);
  return next;
}

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
