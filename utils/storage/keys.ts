// utils/storage/keys.ts
// AsyncStorage keys for the plain-storage collections. Sensitive settings
// fields (API keys, payment tokens) live in SecureStore instead — see
// SECURE_FIELDS in ./settings.

export const KEYS = {
  invoices: "invoices",
  jobs: "jobs",
  customers: "customers",
  settings: "settings",
  expenses: "expenses",
  customerNotes: "customerNotes",
  recurringJobs: "recurringJobs",
  trips: "trips",
} as const;
