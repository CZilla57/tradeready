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
