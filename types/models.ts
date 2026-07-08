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
  | "paid";

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
  recurringJobId?: string;
  occurrenceNumber?: number;
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
  email: string;
  phone: string;
  desc: string;
  paid: boolean;
  /** ISO date the invoice was marked paid; absent on pre-paidAt invoices (fall back to `due`). */
  paidAt?: DateString;
  /** Cached payment link + the amount it was generated for (invoiceHelpers). */
  paymentLinkUrl?: string;
  paymentLinkAmount?: number;
  // NOTE: pdfTemplates references `invoice.created`, which is NOT a field here —
  // that is why the generated PDF's issue date always renders as "today".
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

export interface Settings {
  // Business info
  businessName: string;
  contactName: string;
  phone: string;
  email: string;
  address: string;
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

  // Payment
  paymentNotes: string;
  provider: PaymentProvider;
  /** BACKEND_API_TOKEN for Stripe Connect. SecureStore. */
  providerKey: string;
  /** Per-provider credentials keyed by provider id (all non-Stripe providers). AsyncStorage. */
  providerKeys: Record<string, string>;

  // Notifications
  rules: ReminderRule[];

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
