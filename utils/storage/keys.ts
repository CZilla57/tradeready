// utils/storage/keys.ts
// AsyncStorage keys for the plain-storage collections, plus SECURE_FIELDS —
// the settings fields that live in SecureStore instead (./settings owns the
// load/save split). Both live here because this module is deliberately
// dependency-free: utils/sync.ts must strip SECURE_FIELDS from the legacy
// settings blob it pushes directly, and importing them from ./settings there
// would close a storage → sync → storage import cycle.

export const KEYS = {
  invoices: "invoices",
  jobs: "jobs",
  customers: "customers",
  settings: "settings",
  expenses: "expenses",
  customerNotes: "customerNotes",
  recurringJobs: "recurringJobs",
  recurringInvoices: "recurringInvoices",
  trips: "trips",
  pricebook: "pricebook",
  bookingRequests: "bookingRequests",
  jobPhotos: "jobPhotos",
} as const;

// Fields that must live in SecureStore rather than plain AsyncStorage — and
// must therefore never enter the sync queue or reach Supabase. Every consumer
// must iterate THIS constant, never name the fields inline: sync.ts once
// hand-stripped providerKey/anthropicKey and silently missed groqKey
// (2026-08-02 security audit, item 10a).
export const SECURE_FIELDS = ["providerKey", "anthropicKey", "groqKey"] as const;

// One-shot flag for the contextual invoice-reminder permission prompt
// (utils/notifications.ts). Defined here — not in notifications.ts — so
// lifecycle.ts can put it on the sign-out wipe list without depending on the
// notifications module (which tests routinely partial-mock; importing the
// constant from there would silently turn the wiped key into undefined).
export const REMINDER_PROMPT_KEY = "invoiceReminderPromptShown";

// Sync-layer constants shared with the native-run guard (utils/nativeRunGuard,
// utils/nativeRunRuntime). They live in this dependency-free module so the
// guard can name them without importing utils/sync (which imports the guard).
export const SYNC_QUEUE_KEY = "__syncQueue";
export const SYNC_LAST_SYNCED_KEY = "__lastSyncedAt";
export const SYNC_CURSOR_VERSION = 2 as const;

// Every collection the pull replaces, in pull order (was private to sync.ts).
export const SYNCED_COLLECTION_TABLES = [
  "jobs", "invoices", "customers", "expenses", "pricebook",
  "recurringJobs", "recurringInvoices", "trips", "bookingRequests", "jobPhotos",
] as const;
