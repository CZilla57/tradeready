import { supabase } from './supabase';
import type {
  Customer,
  DateString,
  Expense,
  Invoice,
  Job,
  JobCost,
  JobStatus,
  Material,
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
import {
  buildInvoiceLineItems,
  computeBillableBreakdown,
  defaultDueDate,
  invoiceFromJobMode,
} from '../ui/billableMath';
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

/** Raised when estimate pricing is changed after the customer has responded. */
export class JobEstimateApprovalLockedError extends Error {
  constructor(public readonly decision?: string) {
    super(
      decision
        ? `Estimate pricing is locked because the customer has ${decision} it.`
        : 'Estimate pricing is locked because the customer has already responded.',
    );
    this.name = 'JobEstimateApprovalLockedError';
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

/**
 * Raised by the field-scoped optimistic-concurrency guard (roadmap P2.1) when a
 * field the user actually edited was ALSO changed on the server since the editor
 * opened. The message is user-facing — the edit screens surface `err.message`
 * directly, so it tells the user their view is stale and what to do about it.
 */
export class StaleWriteError extends Error {
  constructor(
    public readonly collection: string,
    public readonly id: string,
    /** The first conflicting field, for diagnostics/tests. */
    public readonly field: string,
  ) {
    super(
      'This record was changed somewhere else while you were editing it. ' +
        'Reload to see the latest version, then reapply your change.',
    );
    this.name = 'StaleWriteError';
  }
}

async function currentUserId(): Promise<string> {
  const { data, error } = await supabase.auth.getUser();
  if (error) throw error;
  const id = data.user?.id;
  if (!id) throw new Error('Not signed in');
  return id;
}

// P0.3 — `updated_at` is DB-authoritative; the portal never sends it.
//
// Device pulls filter on `gt('updated_at', since)` (../../utils/sync.ts), so the
// column has to be monotonic and comparable across every writer. The server-side
// `set_updated_at` trigger
// (supabase/migrations/20260831_updated_at_server_authority.sql) — a BEFORE
// INSERT OR UPDATE trigger on all sync tables — stamps `now()` (the DB clock) on
// every write, overriding whatever a client sends. So a client-sent `updated_at`
// is redundant: it is replaced server-side on both the insert and update paths.
//
// This module therefore OMITS `updated_at` from its writes entirely (the P0.3
// optional cleanup), letting the one authoritative clock own it and keeping the
// browser clock out of the watermark. Do not reintroduce an `updated_at` field
// to any write below: it would be silently overwritten, and sending it invites
// the false impression that the client clock matters here.

// ---------------------------------------------------------------------------
// Field-scoped optimistic-concurrency guard (roadmap P2.1)
//
// Every edit op already refetches the authoritative server row before writing
// and merges the user's change onto it, so a field the portal never touches —
// including one a concurrent server writer appended (the Stripe payment ledger,
// a customer's estimate approval, a recurring rule's advancing generation
// cursor) — is preserved, never clobbered. That is the "refetch-before-write"
// minimum. What refetch+merge alone does NOT catch is a LOST UPDATE: the user
// opens an editor showing a field, someone else changes that same field, and the
// user saves their now-stale value over the change without ever seeing it.
//
// The guard closes that gap without regressing the merge. It is a three-way
// compare — the classic merge triangle:
//
//   * baseline  — the field as the editor rendered it (the common ancestor),
//   * submitted — the field the user is about to write,
//   * server    — the field on the freshly re-fetched row.
//
// A conflict exists ONLY when the user changed a field (submitted != baseline)
// that the server also moved to a different value (server != baseline, and
// server != submitted). A field only the server changed keeps merging; a field
// only the user changed applies; a field both changed to the SAME value is no
// conflict. So a benign concurrent append (which never touches a field the user
// is editing) never trips the guard — only a genuine collision does.
// ---------------------------------------------------------------------------

/** Structural equality for the JSON-shaped values a blob field can hold
 *  (scalars, arrays, plain objects). Enough for comparing edited fields; the
 *  blobs are plain JSON with no class instances, cycles, or functions. */
function deepEqual(a: unknown, b: unknown): boolean {
  if (a === b) return true;
  if (typeof a !== typeof b) return false;
  if (a === null || b === null) return a === b;
  if (Array.isArray(a) || Array.isArray(b)) {
    if (!Array.isArray(a) || !Array.isArray(b) || a.length !== b.length) {
      return false;
    }
    return a.every((v, i) => deepEqual(v, b[i]));
  }
  if (typeof a === 'object' && typeof b === 'object') {
    const ak = Object.keys(a as object);
    const bk = Object.keys(b as object);
    if (ak.length !== bk.length) return false;
    return ak.every((k) =>
      deepEqual(
        (a as Record<string, unknown>)[k],
        (b as Record<string, unknown>)[k],
      ),
    );
  }
  return false;
}

/**
 * Reject the write if any of `fields` is a lost update — changed by the user AND
 * moved on the server to a different value since the editor rendered `baseline`.
 * Fields the user didn't touch, and fields only the server changed, pass through
 * (the caller's refetch+merge handles them). Throws `StaleWriteError` on the
 * first conflict; returns normally when the edit is safe to apply.
 */
function guardConcurrentEdit<
  B,
  S extends Partial<Record<keyof B, unknown>>,
  U extends Partial<Record<keyof B, unknown>>,
>(
  collection: string,
  id: string,
  baseline: B,
  server: S,
  submitted: U,
  fields: (keyof B)[],
): void {
  for (const f of fields) {
    const base = baseline[f];
    const next = (submitted as Record<keyof B, unknown>)[f];
    const now = (server as Record<keyof B, unknown>)[f];
    const userChanged = !deepEqual(next, base);
    if (!userChanged) continue;
    const serverMoved = !deepEqual(now, base);
    if (serverMoved && !deepEqual(next, now)) {
      throw new StaleWriteError(collection, id, String(f));
    }
  }
}

/** Load one owner-scoped blob row's `data` by id, or null for a missing/deleted
 *  row. The read half of the whole-blob guard below. */
async function loadBlobRow<T>(
  collection: string,
  id: string,
): Promise<T | null> {
  const { data, error } = await supabase
    .from(collection)
    .select('data, deleted')
    .eq('id', id)
    .maybeSingle();
  if (error) throw error;
  if (!data || data.deleted || !data.data) return null;
  return data.data as T;
}

/**
 * Guard + merge for the whole-blob edit ops (customers, pricebook, expenses).
 *
 * Unlike the patch ops — which carry only the user's fields and spread them onto
 * a fresh server row — a whole-blob op is handed the entire edited record. So
 * this refetches the current server blob, rejects a lost update on any
 * `guardedFields` (P2.1), then rebuilds the write by applying ONLY the fields the
 * user actually changed (submitted != baseline) onto the fresh server row — so a
 * field another client changed but this user didn't touch survives, and derived
 * fields the caller recomputed (e.g. a pricebook `estimateTotal`) and the blob's
 * own `updatedAt` bump ride along because they, too, differ from baseline.
 *
 * If the row is gone (deleted or never existed), there's nothing to conflict
 * with; the submitted blob is written as-is, matching the ops' prior upsert.
 */
async function guardedBlobMerge<T extends object>(
  collection: string,
  id: string,
  baseline: T,
  submitted: T,
  guardedFields: (keyof T)[],
): Promise<T> {
  const server = await loadBlobRow<T>(collection, id);
  if (!server) return submitted;
  guardConcurrentEdit(collection, id, baseline, server, submitted, guardedFields);
  const merged = { ...server } as Record<string, unknown>;
  const sub = submitted as Record<string, unknown>;
  const base = baseline as Record<string, unknown>;
  for (const k of Object.keys(sub)) {
    if (!deepEqual(sub[k], base[k])) merged[k] = sub[k];
  }
  return merged as T;
}

// ---------------------------------------------------------------------------
// Payload validation (roadmap P1.3)
//
// The screens validate their inputs and give inline UX, but the write module is
// the SINGLE mutation boundary (readOnly.arch.test.ts), so it is also the last
// line that keeps a malformed blob out of the cloud — where a bad value would
// sync to every device and corrupt derived math (an NaN `estimateTotal`, a
// negative amount) or break the generation engine (an unknown cadence, a
// count-ended rule with no count). These helpers re-assert each op's invariants
// on the already-typed values it receives, so a buggy or non-screen caller can't
// bypass the screen checks. Payment drafts keep their own `PaymentValidationError`
// (already shipped); everything else raises `ValidationError`.
// ---------------------------------------------------------------------------

/** Raised when an op's payload violates a data-integrity invariant (P1.3). */
export class ValidationError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'ValidationError';
  }
}

/** A finite number (rejects NaN/Infinity — either would corrupt derived math). */
function requireFinite(n: number, label: string): void {
  if (typeof n !== 'number' || !Number.isFinite(n)) {
    throw new ValidationError(`${label} must be a number.`);
  }
}

/** Finite and >= 0. */
function requireNonNegative(n: number, label: string): void {
  requireFinite(n, label);
  if (n < 0) throw new ValidationError(`${label} must be zero or greater.`);
}

/** Finite and > 0. */
function requirePositive(n: number, label: string): void {
  requireFinite(n, label);
  if (!(n > 0)) throw new ValidationError(`${label} must be greater than zero.`);
}

/** A non-blank string (after trimming). */
function requireNonEmpty(s: string, label: string): void {
  if (typeof s !== 'string' || s.trim() === '') {
    throw new ValidationError(`${label} is required.`);
  }
}

/** A `YYYY-MM-DD` date string. */
function requireDate(s: string, label: string): void {
  if (typeof s !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(s)) {
    throw new ValidationError(`${label} must be a valid date.`);
  }
}

/** The five pricing inputs shared by jobs, pricebook entries, and recurring
 *  jobs — each must be a non-negative number or the estimate math breaks. */
function requirePricingInputs(p: {
  laborHours: number;
  laborRate: number;
  materialMarkup: number;
  overhead: number;
  margin: number;
}): void {
  requireNonNegative(p.laborHours, 'Labor hours');
  requireNonNegative(p.laborRate, 'Labor rate');
  requireNonNegative(p.materialMarkup, 'Material markup');
  requireNonNegative(p.overhead, 'Overhead');
  requireNonNegative(p.margin, 'Margin');
}

/** Every material line's quantity and unit cost must be non-negative numbers. */
function requireMaterials(materials: Material[]): void {
  for (const m of materials) {
    requireNonNegative(m.quantity, `Material "${m.name || m.id}" quantity`);
    requireNonNegative(m.unitCost, `Material "${m.name || m.id}" unit cost`);
  }
}

/** Every direct-cost line's quantity, unit cost, and handling markup must be
 *  non-negative numbers — the same inputs `computeDirectCosts` prices from, so a
 *  malformed value would corrupt the derived `estimateTotal`. Authored via the
 *  shared JobCostsEditor across jobs, pricebook entries, and recurring jobs. */
function requireJobCosts(jobCosts: JobCost[] = []): void {
  for (const c of jobCosts) {
    const name = c.label || c.category || c.id;
    requireNonNegative(c.quantity, `Cost "${name}" quantity`);
    requireNonNegative(c.unitCost, `Cost "${name}" unit cost`);
    requireNonNegative(c.markupPercent, `Cost "${name}" markup`);
  }
}

const RECURRENCE_CADENCES: readonly RecurrenceCadence[] = [
  'daily',
  'weekly',
  'monthly',
  'quarterly',
  'annually',
];

/** A recurring rule's cadence and end bounds — the generation engine relies on
 *  a known cadence and, for a bounded rule, a present count/date. */
function requireRecurrenceBounds(rule: {
  cadence: RecurrenceCadence;
  endCondition: RecurrenceEndCondition;
  endCount?: number;
  endDate?: DateString;
}): void {
  if (!RECURRENCE_CADENCES.includes(rule.cadence)) {
    throw new ValidationError(`Unknown cadence "${rule.cadence}".`);
  }
  if (rule.endCondition === 'count') {
    if (rule.endCount === undefined || !Number.isInteger(rule.endCount) || rule.endCount < 1) {
      throw new ValidationError('End after a whole number of occurrences greater than zero.');
    }
  } else if (rule.endCondition === 'date') {
    if (rule.endDate === undefined) throw new ValidationError('Pick an end date.');
    requireDate(rule.endDate, 'End date');
  } else if (rule.endCondition !== 'never') {
    throw new ValidationError(`Unknown end condition "${rule.endCondition}".`);
  }
}

// The numeric settings fields the portal edits — each must be non-negative if
// the patch carries it (an absent key is untouched, so it isn't checked).
const NON_NEGATIVE_SETTINGS_KEYS: readonly (keyof Settings)[] = [
  'laborRate',
  'materialMarkup',
  'overheadPercent',
  'marginPercent',
  'minimumJobFee',
  'travelFeePerMile',
  'mileageRate',
];

/** Validate a settings patch (P1.3): every numeric pricing field it carries must
 *  be non-negative, and an invoice start number (when set) a whole number >= 1. */
function requireSettingsPatch(patch: Partial<Settings>): void {
  for (const key of NON_NEGATIVE_SETTINGS_KEYS) {
    const value = patch[key];
    if (value !== undefined) requireNonNegative(value as number, key);
  }
  const start = patch.invoiceStartNumber;
  if (start !== undefined && start !== null) {
    if (!Number.isInteger(start) || start < 1) {
      throw new ValidationError('Invoice start number must be a whole number of 1 or more.');
    }
  }
}

/** Validate a schedule patch (P1.3): a working window that opens before it
 *  closes, at least one work day, and non-negative minute durations — the shape
 *  `resolveSchedule` expects. Only the fields the patch carries are checked. */
function requireSchedulePatch(patch: Partial<ScheduleConfig>): void {
  if (patch.workDays !== undefined && patch.workDays.length === 0) {
    throw new ValidationError('Choose at least one working day.');
  }
  if (
    patch.workDayStart !== undefined &&
    patch.workDayEnd !== undefined &&
    patch.workDayStart >= patch.workDayEnd
  ) {
    throw new ValidationError('The work day must start before it ends.');
  }
  if (patch.defaultDurationMinutes !== undefined) {
    requireNonNegative(patch.defaultDurationMinutes, 'Appointment length');
  }
  if (patch.bufferMinutes !== undefined) {
    requireNonNegative(patch.bufferMinutes, 'Buffer');
  }
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
 * Whole-blob upsert of one owner-scoped collection row: `deleted: false`,
 * `user_id = auth.uid()`. `updated_at` is left to the DB trigger (P0.3). The
 * single low-level write primitive the typed operations build on.
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
// Deletes are recorded as a TOMBSTONE — `deleted: true`, never a row removal,
// exactly as the mobile push does (../../utils/sync.ts → the `op === 'delete'`
// branch). A hard `DELETE` would leave every other device with no record that the
// row is gone, so the next pull that predates the delete would treat the row as
// new and resurrect it. The DB trigger stamps a fresh `updated_at` on this UPDATE
// (P0.3), which is what carries the tombstone across each device's
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
    .update({ deleted: true })
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
  // exactly as the mobile push does (../../utils/sync.ts). `updated_at` is left
  // to the DB trigger (P0.3); `settings` is one of its covered tables.
  const { error } = await supabase.from('settings').upsert({
    user_id,
    data: safe,
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
export async function saveSettings(
  patch: Partial<Settings>,
  baseline: Settings,
): Promise<Settings> {
  requireSettingsPatch(patch); // P1.3
  const current = await loadSettings();
  // P2.1: reject only if a settings field this editor's patch touches was
  // changed on the server since the editor opened (another surface — or another
  // tab — saved meanwhile). Fields outside the patch keep merging via
  // persistSettings. Skipped when no row exists yet (a first write can't race).
  if (current) {
    guardConcurrentEdit(
      'settings',
      'settings',
      baseline,
      current,
      patch,
      Object.keys(patch) as (keyof Settings)[],
    );
  }
  return persistSettings({ ...(current ?? ({} as Settings)), ...patch });
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
  baseline: Settings,
): Promise<Settings> {
  requireSchedulePatch(patch); // P1.3
  const current = await loadSettings();
  // P2.1: reject only if a schedule field this patch touches moved on the server
  // since the editor opened. The compare is one level down, on the schedule
  // sub-blob — the same level persistSettings deep-merges — so the booking-only
  // slot fields (written by the mobile Booking screen) never enter this compare.
  if (current) {
    guardConcurrentEdit(
      'schedule',
      'schedule',
      baseline.schedule ?? {},
      current.schedule ?? {},
      patch,
      Object.keys(patch) as (keyof ScheduleConfig)[],
    );
  }
  return persistSettings({
    ...(current ?? ({} as Settings)),
    schedule: { ...((current ?? ({} as Settings)).schedule ?? {}), ...patch },
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
export async function saveCustomer(
  customer: Customer,
  baseline: Customer,
): Promise<Customer> {
  requireNonEmpty(customer.name, 'Customer name'); // P1.3
  // P2.1: refetch and reject a lost update on any field the CustomerEditor
  // edits, then merge the user's changed fields onto the fresh server row.
  // `archivedAt` is deliberately NOT guarded: archive/unarchive is a boolean
  // toggle whose timestamp legitimately differs per client, so comparing it
  // would flag a false conflict when two clients archive. It still merges (it's
  // a changed field), so the toggle applies while a concurrent name/email edit
  // on the same row survives.
  const merged = await guardedBlobMerge('customers', customer.id, baseline, customer, [
    'name',
    'email',
    'phone',
    'address',
    'notes',
  ]);
  await upsertBlobRow('customers', customer.id, merged);
  return merged;
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
  requireNonEmpty(fields.name, 'Customer name'); // P1.3
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
  baseline: Job,
): Promise<Job> {
  requireNonEmpty(edit.title, 'Job title'); // P1.3
  const server = await loadJob(jobId);
  // P2.1: reject only if an operational field the user edited was changed on the
  // server since the editor opened. Consent/workflow fields (approval,
  // changeOrders, timeSessions, …) are preserved by the spread below either way.
  guardConcurrentEdit('jobs', jobId, baseline, server, edit, [
    'title',
    'description',
    'address',
    'scheduledDate',
    'scheduledStartTime',
    'scheduledEndTime',
    'notes',
  ]);
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
  baseline: Job,
): Promise<Job> {
  // P1.3: a set date must be well-formed; an end time needs a start and must
  // follow it (a null date is a valid "unschedule").
  if (edit.scheduledDate !== null) requireDate(edit.scheduledDate, 'Scheduled date');
  if (edit.scheduledEndTime && !edit.scheduledStartTime) {
    throw new ValidationError('Set a start time as well as an end time.');
  }
  if (
    edit.scheduledStartTime &&
    edit.scheduledEndTime &&
    edit.scheduledEndTime <= edit.scheduledStartTime
  ) {
    throw new ValidationError('End time must be after the start time.');
  }
  const server = await loadJob(jobId);
  // P2.1: reject only if the schedule the user is assigning was changed on the
  // server since the row rendered (e.g. a phone scheduled it meanwhile) — don't
  // silently move an appointment someone else already set.
  guardConcurrentEdit('jobs', jobId, baseline, server, edit, [
    'scheduledDate',
    'scheduledStartTime',
    'scheduledEndTime',
  ]);
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
// Job estimate / pricing (roadmap P3 stage 3b — estimate authoring)
//
// The portal authors a job's estimate — the pricing inputs, its materials, and
// the derived `estimateTotal` — exactly as the mobile PricingCalculator's
// `saveToJob` does: spread the CURRENT job and overwrite ONLY the pricing fields,
// leaving status, approval, invoiceId, changeOrders, and timeSessions untouched.
// `laborBreakdown` is preserved only while its canonical
// `laborHours` total is unchanged; changing the total clears the now-stale split.
// Applied onto a FRESHLY re-fetched server row
// (`loadJob`), so a customer's estimate action or a mobile workflow write landing
// between page load and save is never clobbered (same guarantee as
// `updateJobDetails`).
//
// `estimateTotal` is DERIVED: the caller recomputes it with the pricingMath port
// over the edited inputs, materials, and direct-cost lines, matching the mobile
// save, and hands it in.
//
// CONSENT GATE (P0.1 spirit): once a customer has made a frozen approval decision
// (`job.approval.decision`), the estimate is the price they signed — re-pricing it
// silently would diverge from that consent. The UI hides the editor in that case,
// but this operation also checks the fresh row and makes the UPDATE conditional on
// the JSON decision still being null. That database-side predicate closes the
// remaining race if the customer responds after `loadJob` but before the write.
// ---------------------------------------------------------------------------

/** The pricing fields the portal authors on a job. `laborBreakdown` is preserved
 *  from the server row only when `laborHours` is unchanged (the portal does not
 *  author the split); `estimateTotal` is the caller's pricingMath recompute over
 *  the inputs + materials + jobCosts. */
export interface JobPricingEdit {
  laborHours: number;
  laborRate: number;
  materials: Material[];
  jobCosts: JobCost[];
  materialMarkup: number;
  overhead: number;
  margin: number;
  estimateTotal: number;
}

export async function updateJobPricing(
  jobId: string,
  edit: JobPricingEdit,
  baseline: Job,
): Promise<Job> {
  requirePricingInputs(edit); // P1.3
  requireMaterials(edit.materials);
  requireJobCosts(edit.jobCosts);
  const server = await loadJob(jobId);
  if (server.approval?.decision) {
    throw new JobEstimateApprovalLockedError(server.approval.decision);
  }
  // P2.1: reject only if a pricing input the user edited was changed on the
  // server since the editor opened (someone re-priced the estimate meanwhile).
  // `estimateTotal` is DERIVED, not compared. The approval lock above and its
  // atomic DB predicate below guard the distinct consent race.
  guardConcurrentEdit('jobs', jobId, baseline, server, edit, [
    'laborHours',
    'laborRate',
    'materials',
    'jobCosts',
    'materialMarkup',
    'overhead',
    'margin',
  ]);
  const next: Job = {
    ...server,
    laborHours: edit.laborHours,
    laborRate: edit.laborRate,
    materials: edit.materials,
    jobCosts: edit.jobCosts,
    materialMarkup: edit.materialMarkup,
    overhead: edit.overhead,
    margin: edit.margin,
    estimateTotal: edit.estimateTotal,
  };
  if (edit.laborHours !== server.laborHours) delete next.laborBreakdown;
  const user_id = await currentUserId();
  const { data, error } = await supabase
    .from('jobs')
    .update({
      data: next,
      deleted: false,
    })
    .eq('id', jobId)
    .eq('user_id', user_id)
    .eq('deleted', false)
    .is('data->approval->>decision', null)
    .select('id')
    .maybeSingle();
  if (error) throw error;
  if (!data) throw new JobEstimateApprovalLockedError();
  return next;
}

// ---------------------------------------------------------------------------
// New job (roadmap P3 stage 5c — creation flows)
//
// A net-new job is a pure INSERT (fresh client id, no server row to preserve),
// so none of the fresh-row merge machinery the edit path needs applies here.
// The portal creates only an UNPRICED LEAD — status `lead`, estimateTotal 0, no
// materials, no invoice — exactly the shape mobile's AddJobScreen writes for a
// plain new job. The estimate/pricing inputs (labor hours, materials, the priced
// total) are authored later; that surface is the still-deferred part of 3b, so
// creation stops at the operational shell (customer link, title, schedule, …).
//
// The four rate fields (laborRate/materialMarkup/overhead/margin) are SEEDED
// from the owner's business defaults so the eventual estimate uses the right
// rates; the caller reads them from Settings and passes them in (like
// createPricebookEntry), keeping this op a pure builder. Mobile maps
// settings.overheadPercent/marginPercent onto the job's overhead/margin — the
// caller does the same before calling.
// ---------------------------------------------------------------------------

// Mobile mints a job id as `j<Date.now()>` (screens/AddJobScreen.tsx). Same
// shape, monotonic-guarded so a same-ms burst can't collide on the id. P1.4.
let _jobLastMs = 0;
function newJobId(): string {
  let ms = Date.now();
  if (ms <= _jobLastMs) ms = _jobLastMs + 1;
  _jobLastMs = ms;
  return `j${ms}`;
}

/** The fields a new lead job is created from. The four rate fields are the
 *  Settings-seeded pricing defaults (estimate authoring is deferred, so the job
 *  starts unpriced with these rates ready for a later estimate). */
export interface NewJobFields {
  customerId: string;
  customerName: string;
  title: string;
  description: string;
  address: string;
  scheduledDate: DateString | null;
  scheduledStartTime: TimeString | null;
  scheduledEndTime: TimeString | null;
  notes: string;
  laborRate: number;
  materialMarkup: number;
  overhead: number;
  margin: number;
}

/**
 * Create a new unpriced lead job (roadmap P3 stage 5c — creation flows).
 *
 * Mints a mobile-format id and stamps `status: 'lead'`, `createdAt` (today),
 * `invoiceId: null`, and the unpriced seed (estimateTotal 0, laborHours 0, empty
 * materials) — the exact fresh-record shape mobile's AddJobScreen writes for a
 * plain new job. A brand-new id means this is a pure insert, no server row to
 * preserve.
 */
export async function createJob(fields: NewJobFields): Promise<Job> {
  requireNonEmpty(fields.title, 'Job title'); // P1.3
  requireNonEmpty(fields.customerId, 'Customer');
  requireNonNegative(fields.laborRate, 'Labor rate');
  requireNonNegative(fields.materialMarkup, 'Material markup');
  requireNonNegative(fields.overhead, 'Overhead');
  requireNonNegative(fields.margin, 'Margin');
  const job: Job = {
    id: newJobId(),
    customerId: fields.customerId,
    customerName: fields.customerName,
    title: fields.title,
    description: fields.description,
    status: 'lead',
    scheduledDate: fields.scheduledDate,
    scheduledStartTime: fields.scheduledStartTime,
    scheduledEndTime: fields.scheduledEndTime,
    address: fields.address,
    estimateTotal: 0,
    laborHours: 0,
    laborRate: fields.laborRate,
    materials: [],
    materialMarkup: fields.materialMarkup,
    overhead: fields.overhead,
    margin: fields.margin,
    notes: fields.notes,
    invoiceId: null,
    createdAt: getTodayDateString(),
  };
  await upsertBlobRow('jobs', job.id, job);
  return job;
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
  baseline: PricebookEntry,
): Promise<PricebookEntry> {
  requireNonEmpty(entry.name, 'Service name'); // P1.3
  requirePricingInputs(entry);
  requireMaterials(entry.materials);
  requireJobCosts(entry.jobCosts);
  // Bump the blob's own updatedAt, matching the mobile save (distinct from the
  // row's server-authoritative updated_at column).
  const next: PricebookEntry = { ...entry, updatedAt: new Date().toISOString() };
  // P2.1: refetch and reject a lost update on any field the PricebookEditor
  // edits, then merge the user's changed fields onto the fresh server row. The
  // recomputed `estimateTotal` and the `updatedAt` bump ride along (they differ
  // from baseline); a `estimateTotal` is not guarded — it's derived, not edited.
  const merged = await guardedBlobMerge('pricebook', entry.id, baseline, next, [
    'name',
    'category',
    'description',
    'laborHours',
    'laborRate',
    'materials',
    'jobCosts',
    'materialMarkup',
    'overhead',
    'margin',
  ]);
  await upsertBlobRow('pricebook', entry.id, merged);
  return merged;
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
 *  the caller recomputes it with the pricingMath port (P0.6), like the edit.
 *  `materials` and `jobCosts` (direct-cost lines) are authored via the shared
 *  MaterialsEditor / JobCostsEditor (default none). */
export interface NewPricebookFields {
  name: string;
  category: string;
  description: string;
  laborHours: number;
  laborRate: number;
  materials: Material[];
  jobCosts: JobCost[];
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
  requireNonEmpty(fields.name, 'Service name'); // P1.3
  requirePricingInputs(fields);
  requireMaterials(fields.materials);
  requireJobCosts(fields.jobCosts);
  const now = new Date().toISOString();
  const entry: PricebookEntry = {
    id: newPricebookId(),
    name: fields.name,
    category: fields.category || undefined,
    description: fields.description || undefined,
    laborHours: fields.laborHours,
    laborRate: fields.laborRate,
    materials: fields.materials,
    // Omit an empty direct-cost list, matching the mobile fresh-record shape.
    ...(fields.jobCosts.length > 0 ? { jobCosts: fields.jobCosts } : {}),
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

export async function saveExpense(
  expense: Expense,
  baseline?: Expense,
): Promise<Expense> {
  requireNonEmpty(expense.description, 'Description'); // P1.3
  requirePositive(expense.amount, 'Amount');
  // saveExpense doubles as create (add mode) and edit. A create passes no
  // baseline — there is nothing to conflict with — and writes straight through.
  // An edit passes the record it started from, so P2.1 refetches and rejects a
  // lost update on any field the editor touches, then merges the user's changes
  // onto the fresh server row.
  const merged = baseline
    ? await guardedBlobMerge('expenses', expense.id, baseline, expense, [
        'description',
        'amount',
        'category',
        'date',
        'notes',
      ])
    : expense;
  await upsertBlobRow('expenses', expense.id, merged);
  return merged;
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
 *  inputs + materials + jobCosts, P0.6). Customer re-linking is out of scope, like
 *  the plan editor. `materials` and `jobCosts` (direct-cost lines) are authored
 *  via the shared MaterialsEditor / JobCostsEditor and replace the server lists. */
export interface RecurringJobRuleEdit {
  title: string;
  description: string;
  laborHours: number;
  laborRate: number;
  materials: Material[];
  jobCosts: JobCost[];
  materialMarkup: number;
  overhead: number;
  margin: number;
  estimateTotal: number;
  cadence: RecurrenceCadence;
  endCondition: RecurrenceEndCondition;
  endCount?: number;
  endDate?: DateString;
  /** Date shown when the editor opened, used to distinguish an intentional
   * schedule change from stale form state after generation advances the row. */
  originalNextDueDate: DateString;
  nextDueDate: DateString;
}

/**
 * Preserve generation's freshly advanced date unless the user actually edited
 * the date field. Comparing against the editor's original value avoids rolling
 * the server cursor backward when an occurrence is generated while the form is
 * open, without preventing an intentional schedule reset.
 */
function resolveNextDueDate(
  serverNextDueDate: DateString,
  originalNextDueDate: DateString,
  editedNextDueDate: DateString,
): DateString {
  return editedNextDueDate === originalNextDueDate
    ? serverNextDueDate
    : editedNextDueDate;
}

/**
 * Edit a recurring job's rule (roadmap P3 stage 5b).
 *
 * Mirrors `updateRecurringInvoiceRule`: applies the edited rule fields onto a
 * FRESHLY re-fetched server row, so the series' history — id, customerId/Name,
 * jobCosts, occurrenceCount, lastGeneratedDate, isActive, createdAt — is
 * preserved (never rolled back), and normalises endCount/endDate to the chosen
 * endCondition. The DERIVED `estimateTotal` is recomputed by the caller with the
 * pricingMath port over the edited pricing inputs AND materials (matching the
 * mobile save); the edited `materials` are written in place of the server list.
 */
export async function updateRecurringJobRule(
  id: string,
  edit: RecurringJobRuleEdit,
  baseline: RecurringJob,
): Promise<RecurringJob> {
  requireNonEmpty(edit.title, 'Job title'); // P1.3
  requirePricingInputs(edit);
  requireMaterials(edit.materials);
  requireJobCosts(edit.jobCosts);
  requireRecurrenceBounds(edit);
  requireDate(edit.nextDueDate, 'Next date');
  const server = await loadRecurringJob(id);
  // P2.1: reject only if a rule field the user edited moved on the server since
  // the editor opened. `estimateTotal` is DERIVED and `nextDueDate` has its own
  // generation-race handling (`resolveNextDueDate`), so neither is compared here.
  guardConcurrentEdit('recurringJobs', id, baseline, server, edit, [
    'title',
    'description',
    'laborHours',
    'laborRate',
    'materials',
    'jobCosts',
    'materialMarkup',
    'overhead',
    'margin',
    'cadence',
    'endCondition',
  ]);
  const next: RecurringJob = {
    ...server,
    title: edit.title,
    description: edit.description,
    laborHours: edit.laborHours,
    laborRate: edit.laborRate,
    materials: edit.materials,
    jobCosts: edit.jobCosts,
    materialMarkup: edit.materialMarkup,
    overhead: edit.overhead,
    margin: edit.margin,
    estimateTotal: edit.estimateTotal,
    cadence: edit.cadence,
    endCondition: edit.endCondition,
    endCount: edit.endCondition === 'count' ? edit.endCount : undefined,
    endDate: edit.endCondition === 'date' ? edit.endDate : undefined,
    nextDueDate: resolveNextDueDate(
      server.nextDueDate,
      edit.originalNextDueDate,
      edit.nextDueDate,
    ),
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
  requireNonEmpty(fields.customerId, 'Customer'); // P1.3
  requirePositive(fields.amount, 'Amount');
  requireNonNegative(fields.dueDays, 'Net terms');
  requireRecurrenceBounds(fields);
  requireDate(fields.nextDueDate, 'First date');
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

// Mobile mints a recurring-job id as `rj_<Date.now()>` (screens/AddJobScreen.tsx).
// Same shape, monotonic-guarded so a same-ms burst can't collide. P1.4.
let _rjLastMs = 0;
function newRecurringJobId(): string {
  let ms = Date.now();
  if (ms <= _rjLastMs) ms = _rjLastMs + 1;
  _rjLastMs = ms;
  return `rj_${ms}`;
}

/** The fields a new recurring-job rule is created from. `estimateTotal` is
 *  DERIVED — the caller recomputes it with the pricingMath port (P0.6), like the
 *  rule edit. `materials` and `jobCosts` (direct-cost lines) are authored via the
 *  shared MaterialsEditor / JobCostsEditor (default none). The customer is picked
 *  from existing records, so both id and denormalized name are supplied. */
export interface NewRecurringJobFields {
  customerId: string;
  customerName: string;
  title: string;
  description: string;
  laborHours: number;
  laborRate: number;
  materials: Material[];
  jobCosts: JobCost[];
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
 * Create a new recurring-job rule (roadmap P3 stage 5c — creation flows).
 *
 * DECISION — fresh series, no eager first occurrence. Mobile's recurring-job
 * create spawns a first Job (occurrenceNumber 1) alongside the rule. The portal
 * instead initialises a FRESH series (occurrenceCount 0, lastGeneratedDate null,
 * isActive true) and lets the generation engine (utils/recurringJobs.ts) emit
 * the first occurrence on its next run from `nextDueDate` — exactly the choice
 * `createRecurringInvoice` already made for maintenance plans. This keeps the op
 * a single-entity insert (no coupled two-blob write that could half-fail) and
 * keeps both recurring creates consistent.
 *
 * Mirrors the rule shape `updateRecurringJobRule` writes: the pricing inputs and
 * authored materials plus the caller-recomputed `estimateTotal`, with
 * endCount/endDate normalised to the chosen condition. `address`/`notes` start
 * blank — they aren't in the portal's recurring-job editable surface.
 */
export async function createRecurringJob(
  fields: NewRecurringJobFields,
): Promise<RecurringJob> {
  requireNonEmpty(fields.customerId, 'Customer'); // P1.3
  requireNonEmpty(fields.title, 'Job title');
  requirePricingInputs(fields);
  requireMaterials(fields.materials);
  requireJobCosts(fields.jobCosts);
  requireRecurrenceBounds(fields);
  requireDate(fields.nextDueDate, 'First date');
  const rule: RecurringJob = {
    id: newRecurringJobId(),
    customerId: fields.customerId,
    customerName: fields.customerName,
    title: fields.title,
    description: fields.description,
    address: '',
    notes: '',
    estimateTotal: fields.estimateTotal,
    laborHours: fields.laborHours,
    laborRate: fields.laborRate,
    materials: fields.materials,
    // Omit an empty direct-cost list, matching the mobile fresh-record shape.
    ...(fields.jobCosts.length > 0 ? { jobCosts: fields.jobCosts } : {}),
    materialMarkup: fields.materialMarkup,
    overhead: fields.overhead,
    margin: fields.margin,
    cadence: fields.cadence,
    endCondition: fields.endCondition,
    endCount: fields.endCondition === 'count' ? fields.endCount : undefined,
    endDate: fields.endCondition === 'date' ? fields.endDate : undefined,
    occurrenceCount: 0,
    lastGeneratedDate: null,
    nextDueDate: fields.nextDueDate,
    isActive: true,
    createdAt: getTodayDateString(),
  };
  await upsertBlobRow('recurringJobs', rule.id, rule);
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
  /** Date shown when the editor opened; see `resolveNextDueDate`. */
  originalNextDueDate: DateString;
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
  baseline: RecurringInvoice,
): Promise<RecurringInvoice> {
  // P1.3 — a plan's description is optional in the UI, so it isn't required here.
  requirePositive(edit.amount, 'Amount');
  requireNonNegative(edit.dueDays, 'Net terms');
  requireRecurrenceBounds(edit);
  requireDate(edit.nextDueDate, 'Next date');
  const server = await loadRecurringInvoice(id);
  // P2.1: reject only if a rule field the user edited moved on the server since
  // the editor opened. `nextDueDate` has its own generation-race handling
  // (`resolveNextDueDate`), so it is not compared here.
  guardConcurrentEdit('recurringInvoices', id, baseline, server, edit, [
    'description',
    'amount',
    'dueDays',
    'cadence',
    'endCondition',
    'autoSendEnabled',
  ]);
  const next: RecurringInvoice = {
    ...server,
    description: edit.description,
    amount: edit.amount,
    dueDays: edit.dueDays,
    cadence: edit.cadence,
    endCondition: edit.endCondition,
    endCount: edit.endCondition === 'count' ? edit.endCount : undefined,
    endDate: edit.endCondition === 'date' ? edit.endDate : undefined,
    nextDueDate: resolveNextDueDate(
      server.nextDueDate,
      edit.originalNextDueDate,
      edit.nextDueDate,
    ),
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

/** The invoice-local scalar fields owned by the portal's detail editor. */
export interface InvoiceDetailsEdit {
  number: string;
  amount: number;
  due: DateString;
  desc: string;
  email: string;
  phone: string;
}

/**
 * Update only the detail editor's owned fields on the authoritative server
 * invoice, preserving every unrendered/server-owned field (P0.1/P0.2).
 *
 * Deposit requests, payment links, delivery state, line items, job/recurrence
 * links, import metadata, and customer identity can all change after the page
 * renders. Accepting a typed patch instead of a stale full Invoice prevents the
 * editor from replacing any of them. `mergePaymentLedgers` then preserves the
 * ledger and re-derives paid/paidAt against a possibly edited amount.
 */
export async function updateInvoiceDetails(
  id: string,
  edit: InvoiceDetailsEdit,
  baseline: Invoice,
): Promise<Invoice> {
  requireNonEmpty(edit.number, 'Invoice number'); // P1.3
  requirePositive(edit.amount, 'Amount');
  requireDate(edit.due, 'Due date');
  const server = await loadInvoice(id);
  // P2.1: reject only if a scalar the user edited was changed on the server
  // since the editor opened. The payment ledger is preserved by
  // `mergePaymentLedgers` below regardless, so a concurrent Stripe payment never
  // trips this — only a real collision on an owned field does.
  guardConcurrentEdit('invoices', id, baseline, server, edit, [
    'number',
    'amount',
    'due',
    'desc',
    'email',
    'phone',
  ]);
  // Assign every owned field explicitly. TypeScript's excess-property checks
  // are compile-time only; spreading `edit` would let an untyped/dynamic caller
  // smuggle stale hidden fields into the blob at runtime.
  const patched: Invoice = {
    ...server,
    number: edit.number,
    amount: edit.amount,
    due: edit.due,
    desc: edit.desc,
    email: edit.email,
    phone: edit.phone,
  };
  return persistInvoice(mergePaymentLedgers(server, patched));
}

// ---------------------------------------------------------------------------
// New invoice (roadmap P3 stage 5c — creation flows)
//
// A standalone MANUAL invoice, matching mobile's AddInvoiceScreen (NOT the
// create-from-job path, which snapshots the estimate's line items). It is a pure
// insert with a fresh client id, so there is no server ledger to preserve — a
// brand-new invoice starts with no payments and `paid: false`. `lineItems` and
// `jobId` are deliberately absent: manual invoices carry neither (line items are
// an estimate snapshot, authored with the deferred estimate surface).
//
// The `number` is resolved by the CALLER via the shared `nextInvoiceNumber`
// (max existing digit + 1, honouring the Settings prefix/start), with an
// optional user override — exactly as the mobile screen does — so the numbering
// rule stays single-sourced. The customer is picked from existing records, so
// both the denormalised `customer` name and the `customerId` link are set (the
// invoice keys off the name; the id link mirrors mobile's getOrCreateCustomer).
// ---------------------------------------------------------------------------

// Mobile mints a manual invoice id as `String(Date.now())` (AddInvoiceScreen).
// Same bare-numeric shape, monotonic-guarded so a same-ms burst can't collide. P1.4.
let _invLastMs = 0;
function newInvoiceId(): string {
  let ms = Date.now();
  if (ms <= _invLastMs) ms = _invLastMs + 1;
  _invLastMs = ms;
  return String(ms);
}

/** The fields a new manual invoice is created from. `number` is pre-resolved by
 *  the caller (shared `nextInvoiceNumber`, or a user override). */
export interface NewInvoiceFields {
  customer: string;
  customerId: string;
  number: string;
  amount: number;
  due: DateString;
  email: string;
  phone: string;
  desc: string;
}

/**
 * Create a new manual invoice (roadmap P3 stage 5c — creation flows).
 *
 * Mints a mobile-format id and writes the fresh-record shape AddInvoiceScreen
 * writes: `paid: false`, no ledger, no line items. A brand-new id means a pure
 * insert — no server row to merge.
 */
export async function createInvoice(fields: NewInvoiceFields): Promise<Invoice> {
  requireNonEmpty(fields.customer, 'Customer'); // P1.3
  requireNonEmpty(fields.number, 'Invoice number');
  requirePositive(fields.amount, 'Amount');
  requireDate(fields.due, 'Due date');
  const invoice: Invoice = {
    id: newInvoiceId(),
    customer: fields.customer,
    customerId: fields.customerId,
    number: fields.number,
    amount: fields.amount,
    due: fields.due,
    email: fields.email,
    phone: fields.phone,
    desc: fields.desc,
    paid: false,
  };
  return persistInvoice(invoice);
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

// ---------------------------------------------------------------------------
// Create an invoice from a job (roadmap: estimate & invoice workflow —
// create-from-job)
//
// Ports the manual create/requestDeposit paths of the mobile
// CreateInvoiceFromJobScreen (utils/autoInvoice derivation via
// web/src/ui/billableMath). It bills the job's estimate lines, its tracked
// timer hours (finished jobs only, hourly-priced only), and its approved change
// orders, then advances the job the same way mobile does.
//
// Deliberately NARROWER than mobile:
//   * No editable amount — the amount and line items are derived from the FRESH
//     server job so what persists always reconciles with the review the screen
//     showed. (Mobile lets the owner hand-edit the amount; that can diverge from
//     the derived line items, a foot-gun we don't reproduce here.)
//   * "finalize" (a job that already has a deposit invoice) is refused. That is
//     an edit-existing-invoice flow with its own ledger reconcile; it is not a
//     creation and stays out of this op. The mobile app still handles it.
//   * No getOrCreateCustomer side effect — the job already carries its
//     denormalized `customerName` and `customerId`; contact fields are prefilled
//     by the caller from the loaded customer record (email/phone stay editable
//     on the invoice afterwards).
// ---------------------------------------------------------------------------

/** Raised when a job can't be turned into an invoice in its current state
 *  (still a lead/quoted, its estimate unapproved, or it already has an invoice).
 *  Distinct from `ValidationError` so the screen can message the state clearly. */
export class InvoiceFromJobStateError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'InvoiceFromJobStateError';
  }
}

/** Contact/number prefill the caller resolves from its loaded data. `number` is
 *  the shared `nextInvoiceNumber` (or a user override), exactly as the manual
 *  `createInvoice` path expects; `email`/`phone` come from the job's customer
 *  record; `due` defaults to 30 days out when omitted. */
export interface InvoiceFromJobDraft {
  number: string;
  email?: string;
  phone?: string;
  due?: DateString;
}

/**
 * Create a new invoice from a job's estimate, tracked time, and approved change
 * orders, then advance the job.
 *
 * Loads the AUTHORITATIVE server job (not the screen's snapshot) and derives the
 * amount + line items from it, so a concurrent estimate edit or a landed timer
 * session is billed correctly. Refuses a job whose status can't be invoiced yet
 * and a job that already has an invoice. A brand-new invoice id means the invoice
 * write is a pure insert; the job write assigns only the two fields this action
 * owns (`invoiceId`, and `status` for the final-bill path) onto the fresh row, so
 * pricing/approval/time-sessions/change-orders survive.
 */
export async function createInvoiceFromJob(
  jobId: string,
  draft: InvoiceFromJobDraft,
): Promise<Invoice> {
  requireNonEmpty(draft.number, 'Invoice number'); // P1.3
  const due = draft.due ?? defaultDueDate();
  requireDate(due, 'Due date');

  const job = await loadJob(jobId);
  const mode = invoiceFromJobMode(job.status, !!job.invoiceId);
  if (mode === 'finalize') {
    throw new InvoiceFromJobStateError(
      'This job already has an invoice. Open it from the Invoices tab to finalize it.',
    );
  }
  if (mode === null) {
    throw new InvoiceFromJobStateError(
      "This job can't be invoiced yet — it needs an approved estimate first.",
    );
  }

  const amount = computeBillableBreakdown(job).total;
  requirePositive(amount, 'Invoice amount'); // nothing billable → nothing to invoice
  const lineItems = buildInvoiceLineItems(job);

  const invoice: Invoice = {
    id: newInvoiceId(),
    customer: (job.customerName || '').trim(),
    customerId: job.customerId ?? '',
    number: draft.number.trim(),
    amount,
    due,
    email: (draft.email ?? '').trim(),
    phone: (draft.phone ?? '').trim(),
    desc: (job.title || '').trim(),
    paid: false,
    jobId,
    ...(lineItems.length > 0 ? { lineItems } : {}),
  };
  await persistInvoice(invoice);

  // Advance the job the same way jobStatus.jobChangesAfterInvoiceSave does: the
  // final bill ("create") moves complete → invoiced; a deposit request holds the
  // job's status and only links the invoice. Only these owned fields change; the
  // rest of the freshly-loaded blob is preserved.
  const jobChanges =
    mode === 'create'
      ? { status: 'invoiced' as JobStatus, invoiceId: invoice.id }
      : { invoiceId: invoice.id };
  await upsertBlobRow('jobs', jobId, { ...job, ...jobChanges });

  return invoice;
}

/** Optional overrides for a finalize. `due` restarts payment terms (defaults to
 *  30 days out, the way mobile reissues the bill); the rest of the invoice's
 *  identity is kept from the existing deposit record. */
export interface FinalizeInvoiceFromJobDraft {
  due?: DateString;
}

/**
 * Finalize a completed job's deposit invoice — the "finalize" mode of the mobile
 * CreateInvoiceFromJobScreen. A deposit was requested earlier (the job is
 * `complete` and already carries an `invoiceId`); this turns that invoice into
 * the full job bill and advances the job.
 *
 * Unlike `createInvoiceFromJob`, this EDITS an existing invoice, so it starts
 * from the authoritative server row and merges — a deposit payment recorded on
 * it (a Stripe webhook, another device) is carried forward, never clobbered. The
 * amount and line items are re-derived from the fresh job (full billable total,
 * including tracked time and approved change orders); the invoice's own identity
 * fields (number, customer, contact, description) and its payment ledger are
 * preserved. `reconcilePaidFields` re-derives paid/paidAt because the amount just
 * changed, and the job advances to `paid` when the ledger already covers the new
 * total, else to `invoiced` — mirroring `jobStatus.jobChangesAfterInvoiceSave`.
 *
 * Refuses a job that is not awaiting finalize: a completed job with no invoice
 * belongs to `createInvoiceFromJob`, and any other status can't be finalized.
 */
export async function finalizeInvoiceFromJob(
  jobId: string,
  draft: FinalizeInvoiceFromJobDraft = {},
): Promise<Invoice> {
  const job = await loadJob(jobId);
  if (invoiceFromJobMode(job.status, !!job.invoiceId) !== 'finalize') {
    throw new InvoiceFromJobStateError(
      job.status === 'complete'
        ? "This job has no deposit invoice to finalize — create its invoice instead."
        : "This job isn't ready to finalize — only a completed job with a deposit invoice can be.",
    );
  }
  const due = draft.due ?? defaultDueDate();
  requireDate(due, 'Due date');

  // `invoiceId` is present (the mode check proves it); load the authoritative row.
  const existing = await loadInvoice(job.invoiceId as string);

  const amount = computeBillableBreakdown(job).total;
  requirePositive(amount, 'Invoice amount');
  const lineItems = buildInvoiceLineItems(job);

  const updated = reconcilePaidFields({
    ...existing,
    amount,
    due,
    lineItems: lineItems.length > 0 ? lineItems : existing.lineItems,
  });
  await persistInvoice(updated);

  const nextStatus: JobStatus = updated.paid ? 'paid' : 'invoiced';
  await upsertBlobRow('jobs', jobId, {
    ...job,
    status: nextStatus,
    invoiceId: updated.id,
  });

  return updated;
}
