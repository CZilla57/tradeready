// types/models.ts
// Canonical data-shape definitions for TradeReady's persisted domain objects.
//
// These describe the JSON that utils/storage.js reads/writes to AsyncStorage
// (the single source of truth for shapes) plus the settings kept in
// AsyncStorage + SecureStore. This file is types-only — it emits nothing at
// runtime and is safe to import from anywhere with `import type`.
//
// As modules are converted to TypeScript (roadmap items #2–#8), replace their
// implicit shapes with these, e.g.:
//   import type { Job, Invoice, Settings } from "../types/models";

/* ------------------------------------------------------------------ */
/* Enums / unions                                                      */
/* ------------------------------------------------------------------ */

/** Keys of JOB_STATUSES in utils/pricingEngine.js — the job lifecycle. */
export type JobStatus =
  | "lead"
  | "estimate_sent"
  | "approved"
  | "scheduled"
  | "in_progress"
  | "complete"
  | "invoiced"
  | "paid"
  | "declined";

/** `id` values in TRADE_TYPES (utils/pricingEngine.js). */
export type TradeId =
  | "plumbing"
  | "electrical"
  | "hvac"
  | "carpenter"
  | "bricklayer"
  | "plasterer"
  | "landscaping"
  | "cleaning"
  | "painting"
  | "handyman"
  | "other";

/** `id` values in EXPENSE_CATEGORIES (utils/moneyUtils.js). */
export type ExpenseCategoryId =
  "materials" | "tools" | "fuel" | "labor" | "insurance" | "software" | "marketing" | "other";

/**
 * Payment providers understood by invoiceHelpers.buildPaymentLink. The union
 * documents the branches that exist; custom-URL providers fall through to the
 * default branch, so any other string is also technically valid.
 */
export type PaymentProvider =
  "stripe" | "square" | "paypal" | "venmo" | (string & {});

/** A date as an ISO string — usually "YYYY-MM-DD", sometimes a full timestamp. */
export type DateString = string;

/**
 * The IRS lets a self-employed filer deduct vehicle costs by standard mileage
 * OR actual expenses, never both in the same year. Persisted on Settings for
 * the tax set-aside estimate (utils/taxEstimate.ts owns the math).
 */
export type VehicleDeductionMethod = "mileage" | "actual";

/** A "HH:MM" 24-hour clock time. */
export type TimeString = string;

/* ------------------------------------------------------------------ */
/* Domain objects                                                      */
/* ------------------------------------------------------------------ */

/**
 * A line item on a job estimate. quantity/unitCost are numbers once persisted,
 * but form inputs may hand in numeric strings — pricingEngine parseFloat-s them
 * defensively.
 */
export interface Material {
  id: string;
  name: string;
  quantity: number;
  unitCost: number;
}

export interface TimeSession {
  start: string;
  end: string | null;
}

/**
 * Estimate-approval record. Absent until the estimate is "sent for approval".
 * `snapshot` freezes the estimate as sent so the customer approves exactly what
 * they saw and the backend never re-runs pricing math. `decision`/`consentAt`/
 * signature fields are written SERVER-SIDE (service role) when the customer acts;
 * the device only reads them and performs the status transition locally.
 */
export interface EstimateApprovalSnapshot {
  businessName: string;
  customerName: string;
  jobTitle: string;
  lineItems: { label: string; amount: number }[];
  total: number;
  currency: string;
}

export interface EstimateApproval {
  token: string;
  sentAt: DateString;
  snapshot: EstimateApprovalSnapshot;
  decision?: "approved" | "declined";
  consentAt?: DateString;
  signerName?: string;
  declineReason?: string;
  ip?: string;
  userAgent?: string;
}

/** Device-written record of an on-site (verbal) change-order decision. */
export interface ChangeOrderDecision {
  decision: "approved" | "declined";
  decidedAt: DateString;   // local "YYYY-MM-DD", device clock
  note?: string;           // e.g. "verbal OK on site"
}

/**
 * A documented scope change on a job (2026-08-05 spec). Approved change
 * orders raise the job's billable total (utils/changeOrders.ts
 * jobBillableTotal); job.estimateTotal is NEVER mutated — it stays the
 * as-approved baseline that computeEstimateBreakdown's residual math
 * depends on. Status is DERIVED by changeOrderStatus(), never stored.
 */
export interface ChangeOrder {
  id: string;              // co<timestamp>_<counter>
  title: string;
  description?: string;
  /** Dollars. Negative = descope credit. */
  amount: number;
  createdAt: DateString;
  /**
   * Link-based approval — reuses EstimateApproval verbatim. decision/
   * consentAt/signer fields are written SERVER-SIDE only (change-respond),
   * exactly like Job.approval.
   */
  approval?: EstimateApproval;
  /** On-site decision — device-written. Separate field from `approval` so
      the device never writes into the server-owned object. */
  manualDecision?: ChangeOrderDecision;
  /**
   * One-way cancel stamp (mirrors Payment.voidedAt): cancelled COs stay in
   * the list as data, excluded from billable totals. Nothing may clear it.
   */
  cancelledAt?: DateString;
}

export interface Job {
  id: string;
  /**
   * FK to Customer.id. Can be "" on jobs created via manual entry before a
   * customer link existed — the orphan-customer bug (roadmap #5).
   */
  customerId: string;
  /** Denormalized copy of the customer name (jobs render this directly). */
  customerName: string;
  title: string;
  description: string;
  status: JobStatus;
  scheduledDate: DateString | null;
  scheduledStartTime: TimeString | null;
  scheduledEndTime: TimeString | null;
  address: string;
  estimateTotal: number;
  laborHours: number;
  laborRate: number;
  materials: Material[];
  materialMarkup: number;
  /**
   * NOTE: jobs persist `overhead`/`margin`, but pricingEngine.calculateEstimate
   * expects `overheadPercent`/`marginPercent`. Reconcile in roadmap #3 so the
   * stored shape and the math agree.
   */
  overhead: number;
  margin: number;
  notes: string;
  invoiceId: string | null;
  createdAt: DateString;
  /**
   * LEGACY (pre-2026-08-06): absolute device-local photo URIs. Superseded by
   * the synced `jobPhotos` collection (JobPhoto records keyed by jobId). Kept
   * optional so old records still parse; the sign-in adoption migration
   * (utils/photoSync.ts) drains any remaining URIs into JobPhoto records.
   * Do NOT write new entries here — attach photos via saveJobPhotos.
   */
  photos?: string[];
  timeSessions?: TimeSession[];
  recurringJobId?: string;
  occurrenceNumber?: number;
  /**
   * Local "YYYY-MM-DD" date the estimate was last sent (any send path:
   * mark-as-sent, approval link, revise-and-resend). Absent on jobs sent
   * before 2026-08 — those never get a follow-up nudge (estimateSentDate in
   * utils/estimateFollowUps.ts falls back to approval.sentAt, then gives up).
   * Re-stamped on every re-send, which deliberately re-arms the one-shot nudge.
   */
  estimateSentAt?: DateString;
  approval?: EstimateApproval;
  /**
   * Scope changes (2026-08-05 spec). OPTIONAL and additive — ABSENT on every
   * pre-feature job, deliberate; utils/changeOrders.ts treats absent as [].
   */
  changeOrders?: ChangeOrder[];
  /**
   * Soft archive (utils/archive.ts): local "YYYY-MM-DD" the job was archived.
   * OPTIONAL and additive — absent means active. Archived jobs hide from the
   * Jobs list (except its Archived tab) and global search; money/invoice
   * history still counts them.
   */
  archivedAt?: DateString;
  /**
   * FK to the CSV import batch that created this record (2026-08 CSV-import
   * spec). OPTIONAL and additive — absent on every record created by any other
   * path (manual entry, booking conversion, sync pull). Stamped ONLY on records
   * a batch created (never on merge-matched existing customers), so "Undo import"
   * — which deletes every record carrying the batch id — cannot remove
   * pre-existing data. JSON-blob sync ⇒ no backend migration.
   */
  importBatchId?: string;
}

/**
 * A single job photo, synced cross-device via the `jobPhotos` collection
 * (2026-08-06 job-photo R2 sync spec). Per-photo records make each photo its
 * own last-write-wins unit, so two devices attaching photos to the same job
 * offline never clobber each other's lists (the whole-Job LWW hazard that made
 * Job.photos legacy). The local file is deterministic —
 * `${documentDirectory}job-photos/${id}.jpg` — and the R2 key is derived
 * server-side as `${userId}/${id}.jpg`, so neither path is stored here.
 */
export interface JobPhoto {
  /** `p<timestamp>_<base36-rand>` — IS the local filename and the R2 object name. */
  id: string;
  /** FK to Job.id this photo belongs to. */
  jobId: string;
  /** ISO timestamp the photo was captured/attached. */
  createdAt: string;
  /**
   * ISO timestamp stamped after a confirmed R2 PUT. ABSENT = still pending
   * upload on the origin device; a second device seeing this with no local
   * file renders an "uploading from another device" placeholder (not a bug).
   */
  uploadedAt?: string;
  /**
   * TRUE = the owner explicitly marked this photo visible on the customer
   * portal (Phase 12B). ABSENT MEANS HIDDEN — every consumer checks
   * `=== true`, so old records and new captures are private by default.
   */
  customerVisible?: boolean;
  /** Pixel dimensions after client compression (optional, for layout hints). */
  width?: number;
  height?: number;
}

export interface PricebookEntry {
  id: string;
  name: string;
  description?: string;
  category?: string;
  laborHours: number;
  laborRate: number;
  materials: Material[];
  materialMarkup: number;
  overhead: number;
  margin: number;
  estimateTotal: number;
  createdAt: string;
  updatedAt: string;
}

export interface AIPricingSuggestion {
  laborHours?: { suggested: number; reasoning: string };
  laborRate?: { suggested: number; reasoning: string };
  materials?: {
    name: string;
    suggestedUnitCost: number;
    reasoning: string;
  }[];
  overallRange?: {
    low: number;
    mid: number;
    high: number;
    reasoning: string;
  };
}

export type InvoiceLineCategory = 'labor' | 'materials' | 'overhead' | 'travel' | 'other';

export interface InvoiceLineItem {
  description: string;
  amount: number;
  category: InvoiceLineCategory;
}

/** How a payment reached the tradesperson. */
export type PaymentMethod = 'stripe' | 'cash' | 'check' | 'card' | 'other';

/**
 * A single payment against an invoice. Invoices may be settled in any number
 * of partial payments (a deposit up front, progress draws, a final balance).
 *
 * `id` is `p<timestamp>_<counter>` for payments recorded on the device, and
 * `stripe_<checkout_session_id>` for payments appended by the Stripe Connect
 * webhook. The two id spaces cannot collide, which is what lets pullRemote
 * union the two sides' ledgers deterministically (see utils/sync.ts).
 */
export interface Payment {
  id: string;
  amount: number;
  /** The date money was actually received — "YYYY-MM-DD". Drives revenue bucketing. */
  date: DateString;
  method: PaymentMethod;
  note?: string;
  /**
   * Present only on webhook-created payments. Informational/traceability
   * only — nothing reads it. The idempotency key is this Payment's own `id`
   * field, which the webhook sets to `stripe_<checkout_session_id>` (see
   * backend/api/stripe/webhook.js); a repeated Stripe delivery for the same
   * session produces the same `id` and is collapsed by the ledger union.
   */
  stripeSessionId?: string;
  /**
   * Set when this payment is voided. Voided entries STAY in the ledger and are
   * skipped by amountPaid — deletion is recorded as DATA, not absence, so a
   * server-side union cannot resurrect it.
   *
   * Void is IRREVERSIBLE. Nothing may clear this field. That one-way property
   * is what makes the ledger union commutative: whichever copy carries the
   * void is unambiguously the later state, regardless of arrival order. To
   * correct a mistaken void, record a new payment.
   */
  voidedAt?: DateString;
}

/**
 * The fields the record-payment form collects, before `id` is stamped.
 * Mirrors the existing ExpenseDraft pattern. `voidedAt` and `stripeSessionId`
 * are excluded deliberately: a form can never create a voided payment, and
 * `stripeSessionId` belongs only to webhook-created entries.
 */
export type PaymentDraft = Omit<Payment, "id" | "voidedAt" | "stripeSessionId">;

/**
 * An up-front amount requested from the customer, set on the Outreach screen.
 * Recorded so the UI can show "Deposit requested: $500 — unpaid" and reuse the
 * same payment link rather than minting a new one each render.
 */
export interface DepositRequest {
  /** The resolved dollar amount, even when the user chose a percentage. */
  amount: number;
  /** Set only when the user picked a percentage rather than a fixed amount. */
  percent?: number;
  requestedAt: DateString;
}

export interface Invoice {
  id: string;
  /**
   * Customer NAME, not an id — invoices key off the name string, unlike Job's
   * customerId. This split is the dual-identity model (roadmap #5).
   */
  customer: string;
  /**
   * FK to Customer.id, stamped by the creation paths + migrateCustomerIdentity
   * (roadmap #5). Optional because pre-#5 invoices predate it until the
   * idempotent migration backfills them; `customer` (the name) stays the
   * denormalized display copy.
   */
  customerId?: string;
  number: string;
  amount: number;
  due: DateString;
  /**
   * Denormalized snapshot of the customer's contact info at creation. Blank
   * fields are backfilled from the linked customer by
   * backfillInvoiceContacts (customers.ts) — via migrateCustomerIdentity on
   * sign-in and on customer save. Non-blank values are never overwritten.
   */
  email: string;
  phone: string;
  desc: string;
  paid: boolean;
  /** ISO date the invoice was marked paid; absent on pre-paidAt invoices (fall back to `due`). */
  paidAt?: DateString;
  /**
   * The payment ledger. ABSENT on every invoice created before this feature —
   * that is deliberate, not an oversight. utils/invoicePayments.ts falls back
   * to `paid`/`amount`/`paidAt` when this is absent, so legacy invoices derive
   * exactly as they always did and no migration is required.
   *
   * `paid` above is now maintained as `balanceDue(inv) <= 0.005`. It is kept
   * because the PDF template, the backend reminder selector, and any client
   * running older code still read it.
   */
  payments?: Payment[];
  /** An up-front amount requested from the customer; set on the Outreach screen. */
  depositRequest?: DepositRequest;
  /** Cached payment link + the amount it was generated for (invoiceHelpers). */
  paymentLinkUrl?: string;
  paymentLinkAmount?: number;
  /**
   * ISO timestamp stamped by createAutoInvoiceForJob when the owner opted in
   * to fully-automatic emailing (Settings.autoEmailInvoiceOnComplete) and the
   * customer had an email at creation. The backend's 15-minute sweep emails
   * stamped invoices once (auto_invoice_email_log one-and-done) while the
   * stamp is ≤7 days old; a manual send from Outreach clears it. Absent =
   * never requested. 2026-08-06 spec.
   */
  autoEmailRequestedAt?: string;
  /** Itemised breakdown from the job estimate; absent on manually-created invoices. */
  lineItems?: InvoiceLineItem[];
  /**
   * FK to Job.id when this invoice was created from a job — both
   * CreateInvoiceFromJobScreen paths ("create at complete" and "request
   * deposit early") set this; manually-added invoices (AddInvoiceScreen) have
   * none. Written since this field's creation paths existed but never read
   * until isJobDunningEligible (utils/jobStatus.ts) needed it to keep an
   * unpaid pre-work deposit on an unfinished job out of overdue dunning.
   */
  jobId?: string;
  /**
   * FK to RecurringInvoice.id when this invoice was generated by a
   * maintenance-plan rule (utils/recurringInvoices.ts). Mirrors
   * Job.recurringJobId. Additive-optional — absent on every other invoice;
   * JSON-blob sync means no backend migration (storage-and-sync recipe).
   */
  recurringInvoiceId?: string;
  /** 1-based occurrence index within the rule (mirrors Job.occurrenceNumber). */
  occurrenceNumber?: number;
  // NOTE: there is no `created` field. The PDF's issue date is recovered from the
  // ms timestamp both creation paths embed in `id` (see invoiceIssueDate in
  // pdfTemplates); sample and legacy rows with non-timestamp ids render as "today".
  /**
   * FK to the CSV import batch that created this record (2026-08 CSV-import
   * spec). OPTIONAL and additive — absent on every record created by any other
   * path (manual entry, booking conversion, sync pull). Stamped ONLY on records
   * a batch created (never on merge-matched existing customers), so "Undo import"
   * — which deletes every record carrying the batch id — cannot remove
   * pre-existing data. JSON-blob sync ⇒ no backend migration.
   */
  importBatchId?: string;
}

export interface Customer {
  id: string;
  name: string;
  email: string;
  phone: string;
  address: string;
  notes: string;
  /**
   * ISO timestamp stamped when a record is created via upsertCustomerInList
   * (roadmap #5). Optional because the seed/sample customers and pre-#5 records
   * don't carry it.
   */
  createdAt?: DateString;
  /**
   * Customer-portal capability link (2026-08-04 portal spec). OPTIONAL and
   * additive. Device-written ONLY (CustomerDetail); the backend resolves
   * token → customer by READING the customers table, never writing it.
   * Public-by-design token (it's in the shared URL) — not secret data.
   */
  portal?: { token: string; enabled: boolean };
  /**
   * Soft archive (utils/archive.ts): local "YYYY-MM-DD" the customer was
   * archived. OPTIONAL and additive — absent means active. Archived customers
   * hide from the Customers list (except its Archived toggle) and global
   * search; their invoices/jobs keep working normally.
   */
  archivedAt?: DateString;
  /**
   * FK to the CSV import batch that created this record (2026-08 CSV-import
   * spec). OPTIONAL and additive — absent on every record created by any other
   * path (manual entry, booking conversion, sync pull). Stamped ONLY on records
   * a batch created (never on merge-matched existing customers), so "Undo import"
   * — which deletes every record carrying the batch id — cannot remove
   * pre-existing data. JSON-blob sync ⇒ no backend migration.
   */
  importBatchId?: string;
}

export interface Expense {
  /** id + createdAt are stamped by hooks/useMoneyData; the modal omits them. */
  id: string;
  createdAt: DateString;
  description: string;
  amount: number;
  category: ExpenseCategoryId;
  date: DateString;
  notes: string;
  receiptUri: string | null;
  /**
   * FK to the CSV import batch that created this record (2026-08 CSV-import
   * spec). OPTIONAL and additive — absent on every record created by any other
   * path (manual entry, booking conversion, sync pull). Stamped ONLY on records
   * a batch created (never on merge-matched existing customers), so "Undo import"
   * — which deletes every record carrying the batch id — cannot remove
   * pre-existing data. JSON-blob sync ⇒ no backend migration.
   */
  importBatchId?: string;
}

/** The fields AddExpenseModal hands to onSave, before id/createdAt are stamped. */
export type ExpenseDraft = Omit<Expense, "id" | "createdAt">;

/**
 * A logged business drive for mileage tax deduction. LOCAL-ONLY (like
 * RecurringJob): stored in AsyncStorage, cleared on sign-out, NOT synced to
 * Supabase. Either endpoint may be a linked job (fromJobId/toJobId set) or
 * "Home / Shop" (null). Labels are denormalized for display, matching the
 * Job.customerName pattern.
 */
export interface Trip {
  id: string;
  date: DateString;              // "YYYY-MM-DD"
  odometerStart: number;
  odometerEnd: number;
  miles: number;                 // derived + stored: max(0, end - start)
  fromJobId: string | null;      // null = "Home / Shop"
  fromLabel: string;
  toJobId: string | null;        // null = "Home / Shop"
  toLabel: string;
  purpose: string;
  createdAt: DateString;
}

/**
 * Booking-request lifecycle. "new"/"converted" are the original free-text
 * request states. The Phase 11 states (2026-08-07 spec §3c): "booked" is a
 * slot reservation (stays "booked" after device conversion — the customer
 * manage page keeps reading it; `convertedJobId` is the done marker);
 * "confirmed"/"reschedule_requested"/"cancelled"/"declined" are written
 * SERVER-side by the Phase D manage/respond endpoints. Additive union:
 * OTA-old clients skip everything that isn't "new" (bookingConversion
 * matches statuses explicitly), so unknown states are inert, never corrupted.
 */
export type BookingRequestStatus =
  | "new"
  | "converted"
  | "booked"
  | "confirmed"
  | "reschedule_requested"
  | "cancelled"
  | "declined";

/** One auditable state change on a booking (SERVER-written, append-only). */
export interface BookingHistoryEntry {
  at: string; // ISO timestamp, server clock
  actor: "customer" | "owner" | "system";
  event: string;
  note?: string;
}

/**
 * A public request-a-quote submission (booking link, 2026-08-04 spec).
 * Rows are INSERTED server-side only (backend/lib/booking/); the device's
 * applyBookingRequests converts status "new" → Customer + lead Job and flips
 * status to "converted", and kind "booked" → Customer + lead Job carrying
 * the slot's schedule fields (status preserved). Synced like any collection.
 */
export interface BookingRequest {
  id: string;            // server-minted: bk<epoch-ms>_<6 hex>
  status: BookingRequestStatus;
  name: string;
  phone: string;
  email: string;
  address: string;
  details: string;
  preferredTiming: string;
  createdAt: string;     // ISO timestamp, server clock
  convertedJobId?: string;
  convertedCustomerId?: string;
  /** Absent = legacy free-text request (pre-Phase-11 rows). */
  kind?: "request" | "booked";
  /**
   * The reserved slot (kind "booked" only). Owner-naive date/start/end are
   * authoritative for what lands on the Job; the UTC instants exist for the
   * server's uniqueness + customer display.
   */
  slot?: {
    date: DateString;
    start: TimeString;
    end: TimeString;
    timeZone: string;
    startUtc: string;
    endUtc: string;
  };
  /** Phase D customer-manage capability token — public-by-design (it lives
   *  in the confirmation link), like Customer.portal.token. */
  manageToken?: string;
  /** Append-only audit trail, SERVER-written (mirrors EstimateApproval's
   *  server-side-write discipline). */
  history?: BookingHistoryEntry[];
}

/** A reminder rule: notify N days after an invoice's due date. */
export interface ReminderRule {
  days: number;
}

/** An optional installment offer woven into outreach messages (invoiceHelpers). */
export type PaymentPlan =
  | { enabled: true; installments: number | string; frequency: string }
  | { enabled: false };

export type RecurrenceCadence = 'daily' | 'weekly' | 'monthly' | 'quarterly' | 'annually';
export type RecurrenceEndCondition = 'never' | 'count' | 'date';

export interface RecurringJob {
  id: string;
  customerId: string;
  customerName: string;
  title: string;
  description: string;
  address: string;
  notes: string;
  estimateTotal: number;
  laborHours: number;
  laborRate: number;
  materials: Material[];
  materialMarkup: number;
  overhead: number;
  margin: number;
  cadence: RecurrenceCadence;
  endCondition: RecurrenceEndCondition;
  endCount?: number;
  endDate?: DateString;
  occurrenceCount: number;
  lastGeneratedDate: DateString | null;
  nextDueDate: DateString;
  isActive: boolean;
  createdAt: DateString;
}

/**
 * A recurring-invoice rule (maintenance plan). LOCAL-ONLY, like RecurringJob
 * and Trip: stored under the `recurringInvoices` AsyncStorage key, NOT synced
 * (not in COLLECTION_TABLES), cleared on sign-out by clearAllUserData, lost on
 * device change — the same accepted limitation recurring jobs carry. The
 * invoices it generates are normal records and sync like any other invoice.
 */
export interface RecurringInvoice {
  id: string;                       // ri<timestamp>
  customerId: string;
  /** Denormalized display copy (Job.customerName pattern). */
  customerName: string;
  /** Becomes invoice.desc on each generated invoice. */
  description: string;
  amount: number;
  /** Net terms in days; default 30 (= AddInvoiceScreen defaultDueDate). */
  dueDays: number;
  cadence: RecurrenceCadence;
  endCondition: RecurrenceEndCondition;
  endCount?: number;
  endDate?: DateString;
  occurrenceCount: number;
  lastGeneratedDate: DateString | null;
  /** Next occurrence (generation) date, "YYYY-MM-DD". */
  nextDueDate: DateString;
  isActive: boolean;
  createdAt: DateString;
}

/** A whole-day time-off period (Phase 11). start/end are inclusive local "YYYY-MM-DD". */
export interface ScheduleBlackout {
  id: string;
  start: DateString;
  end: DateString;
  reason?: string;
}

/**
 * Owner scheduling config (Phase 11 calendar/availability, 2026-08-07 spec).
 * OPTIONAL and additive — absent reproduces pre-Phase-11 behavior exactly
 * (fixed 08:00–17:00 window, Mon–Sat, no buffers, no blackouts, no public
 * slots). utils/scheduleConfig.ts resolveSchedule() is the ONLY sanctioned
 * reader — it sanitizes and fills defaults; consumers never read these raw.
 */
export interface ScheduleConfig {
  /** IANA zone (e.g. "America/Chicago"), stamped when slot booking is enabled. */
  timeZone?: string;
  /** ISO weekdays 1–7 (Mon=1). */
  workDays?: number[];
  workDayStart?: TimeString;
  workDayEnd?: TimeString;
  defaultDurationMinutes?: number;
  /** Explicit gap between appointments. Config only — travel time is NEVER inferred. */
  bufferMinutes?: number;
  /** Minimum notice before the earliest publicly bookable slot. */
  slotLeadHours?: number;
  /** Bookable horizon in days. */
  slotWindowDays?: number;
  blackouts?: ScheduleBlackout[];
  /** Phase C master switch AND the ship feature flag. Absent → off. */
  bookableSlotsEnabled?: boolean;
}

export interface Settings {
  // Business info
  businessName: string;
  contactName: string;
  phone: string;
  email: string;
  address: string;
  region?: string;
  logoPhoto?: string;
  trade: TradeId;

  // Pricing defaults — set once, applied to every estimate.
  laborRate: number;
  materialMarkup: number;
  overheadPercent: number;
  marginPercent: number;
  minimumJobFee: number;
  travelFeePerMile: number;
  emergencyMultiplier: number;
  /** $ per mile for the mileage tax-deduction estimate (Money → Mileage). */
  mileageRate: number;
  /**
   * Effective income-tax rate (%) for the tax set-aside estimate (Money → Tax
   * set-aside card). OPTIONAL and additive — absent on every pre-existing
   * settings blob. Unset computes the SE-tax component only, with an in-card
   * prompt to set it; the app never invents a rate.
   */
  taxIncomeRate?: number;
  /**
   * IRS vehicle-deduction election for the tax estimate: standard mileage OR
   * actual (fuel-category) expenses — never both. OPTIONAL and additive.
   * Unset deducts NEITHER (over-reserving, the safe direction) until the user
   * explicitly chooses; the app never auto-picks a tax election.
   */
  vehicleDeductionMethod?: VehicleDeductionMethod;
  /**
   * Public booking link (request-a-quote). OPTIONAL and additive — absent
   * means no link minted. Device-written ONLY (Settings screen); the backend
   * resolves token → user by READING the settings blob, never writing it.
   * Public-by-design (the token is in the shared URL) — not a SECURE_FIELD.
   */
  bookingLink?: { token: string; enabled: boolean };
  /**
   * Expo push token for owner alerts. OPTIONAL and additive. Device-written
   * by utils/pushToken.ts (only-on-change); read server-side to send booking
   * alerts. Not a secret credential — not a SECURE_FIELD.
   */
  pushToken?: { token: string; platform: "ios" | "android"; updatedAt: string };
  /** Owner scheduling config (Phase 11). OPTIONAL and additive — see ScheduleConfig. */
  schedule?: ScheduleConfig;

  // Invoicing
  /**
   * Invoice-number prefix, rendered `${prefix}-0001`. OPTIONAL and additive —
   * absent/blank on pre-existing settings blobs → "INV"
   * (utils/invoiceNumber.ts owns the rule).
   */
  invoicePrefix?: string;
  /**
   * Floor for the next auto-generated invoice number:
   * next = max(maxExisting + 1, this). OPTIONAL and additive — absent → 1.
   * Lets a user start at e.g. 500 so their first invoice isn't #1; once the
   * sequence grows past it, it has no effect.
   */
  invoiceStartNumber?: number;

  // Payment
  paymentNotes: string;
  provider: PaymentProvider;
  /** BACKEND_API_TOKEN for Stripe Connect. SecureStore. */
  providerKey: string;
  /**
   * Per-provider payment handles keyed by provider id (all non-Stripe
   * providers): PayPal.Me/Venmo usernames, Square/custom payment-page URLs.
   * These are PUBLIC values embedded in customer-facing payment links —
   * never store a credential here (pre-2026-08 builds asked for a Square
   * Access Token; buildPaymentLink refuses to emit token-shaped values).
   * AsyncStorage.
   */
  providerKeys: Record<string, string>;

  // Notifications
  rules: ReminderRule[];
  /**
   * When true, overdue-invoice notifications become actionable: tapping one
   * opens a pre-filled outreach message (App.tsx routes to Invoices → Outreach).
   * Opt-in; absent on settings persisted before this field shipped → treated as false.
   */
  autoOutreachEnabled: boolean;

  /**
   * When true, the backend automatically EMAILS a one-and-done payment reminder
   * for an overdue invoice once it passes the earliest reminder age (Phase 2 —
   * Vercel Cron + Resend). Opt-in; independent of autoOutreachEnabled.
   */
  autoSendEmailEnabled: boolean;

  /**
   * When true, a local notification fires at 5pm the day before a scheduled
   * job, reminding the tradesperson to send the customer a confirmation.
   * Opt-in; absent on settings persisted before this field shipped → false.
   */
  appointmentRemindersEnabled: boolean;
  /** Editable day-before confirmation template. Blank/absent → DEFAULT_CONFIRM_TEMPLATE. */
  appointmentConfirmTemplate: string;
  /** Editable "on my way" template. Blank/absent → DEFAULT_ON_MY_WAY_TEMPLATE. */
  onMyWayTemplate: string;
  /**
   * When false, suppresses estimate follow-up nudges — both the est_ local
   * notification and Today's "awaiting response" row. ⚠️ ABSENT MEANS ON,
   * the REVERSE of appointmentRemindersEnabled above: read sites must check
   * `settings.estimateFollowUpsEnabled !== false`, never truthiness, so users
   * whose persisted settings predate this field get the feature (default-on
   * was an explicit owner decision, 2026-08-01 spec). Do not "unify" the two
   * conventions.
   */
  estimateFollowUpsEnabled: boolean;
  /**
   * When true, marking a job complete auto-creates its invoice (billing
   * tracked timer hours when the timer was used) and opens the send screen.
   * Opt-in; absent on settings persisted before this field shipped → false
   * (same truthy-read convention as appointmentRemindersEnabled).
   */
  autoInvoiceOnComplete: boolean;
  /**
   * When true (and autoInvoiceOnComplete is on), the auto-created invoice is
   * emailed to the customer by the backend sweep within ~15 minutes instead
   * of opening the send screen; with no customer email on file the send
   * screen opens as before. Opt-in; absent → false (same truthy-read
   * convention as autoInvoiceOnComplete). 2026-08-06 spec.
   */
  autoEmailInvoiceOnComplete: boolean;

  // AI — both stored in SecureStore, stripped from AsyncStorage on save.
  anthropicKey: string;
  groqKey: string;

  // Review requests — auto-ask customers for Google reviews after job completion.
  reviewRequestEnabled: boolean;
  reviewRequestTemplate: string;
  googleReviewLink: string;
  reviewRequestDelayHours: number;
}

/** Persisted customer-notes map: normalized (trimmed + lowercased) name → note. */
export type CustomerNotes = Record<string, string>;

/* ------------------------------------------------------------------ */
/* Pricing engine I/O (utils/pricingEngine.js)                         */
/* ------------------------------------------------------------------ */

/**
 * A material line as accepted by the estimate *inputs* (live calculator fields).
 * quantity/unitCost may arrive as numeric strings from TextInputs — the engine
 * parseFloat-s them. Persisted job materials use the stricter `Material`.
 */
export interface EstimateMaterialInput {
  id?: string;
  name?: string;
  quantity: number | string;
  unitCost: number | string;
}

/** Parameters accepted by calculateEstimate (all optional; defaults applied). */
export interface EstimateInput {
  laborHours?: number;
  laborRate?: number;
  materials?: EstimateMaterialInput[];
  materialMarkup?: number;
  overheadPercent?: number;
  marginPercent?: number;
  travelMiles?: number;
  travelFeePerMile?: number;
  isEmergency?: boolean;
  emergencyMultiplier?: number;
  minimumJobFee?: number;
  taxPercent?: number;
}

/** The fully-rounded breakdown returned by calculateEstimate. */
export interface EstimateBreakdown {
  laborCost: number;
  materialBaseCost: number;
  materialMarkupAmount: number;
  materialCost: number;
  travelCost: number;
  subtotal: number;
  overheadCost: number;
  profit: number;
  preTaxTotal: number;
  totalBeforeTax: number;
  taxAmount: number;
  total: number;
  effectiveHourlyRate: number;
  hitMinimum: boolean;
}

/** Low / recommended / high spread returned by calculatePriceRange. */
export interface PriceRange {
  low: number;
  recommended: number;
  high: number;
  breakdown: EstimateBreakdown;
}

/**
 * The line-item breakdown derived from a *saved* job, where overhead is the
 * residual (estimateTotal − labor − material) so the parts always sum to the
 * stored total. Returned by pricingEngine.computeEstimateBreakdown — the single
 * home for the estimate-breakdown math that JobDetail, SendEstimate, the
 * estimate messages, and the estimate PDF all render (roadmap #3).
 */
export interface JobEstimateBreakdown {
  laborCost: number;
  materialBaseCost: number;
  materialCost: number;
  overheadLine: number;
  estimateTotal: number;
  hasMaterials: boolean;
}
