// utils/storage/index.ts
// Public facade for the storage layer. The god-module that used to be
// utils/storage.js is now split into focused concerns (collections, settings,
// the customer registry, app-lifecycle ops, and the Today-tab derived reads);
// this barrel re-exports their public API so every consumer keeps importing from
// "../utils/storage" unchanged.
//
// collections / customers / lifecycle / dailyOps export exactly their public
// surface, so they're re-exported wholesale. defaults keeps internal members
// (the collection seeds), so it's re-exported by name — as is settings, and
// keys (KEYS + SECURE_FIELDS) is layer-internal and not re-exported at all.

export * from "./collections";
export * from "./customers";
export * from "./lifecycle";
export * from "./dailyOps";

export { loadSettings, saveSettings, scrubLegacySquareToken } from "./settings";
export { defaultSettings, defaultInvoices } from "./defaults";
export { migrateSampleDataIds } from "./sampleMigration";
export { loadRecurringJobs, saveRecurringJobs } from "./recurringJobs";
export { loadRecurringInvoices, saveRecurringInvoices } from "./recurringInvoices";
export { loadTrips, saveTrips } from "./trips";
export { loadBookingRequests, saveBookingRequests } from "./bookingRequests";
export { loadJobPhotos, saveJobPhotos } from "./jobPhotos";
export { loadPricebook, savePricebook } from "./pricebook";
export { applyEstimateDecisions } from "./estimateApprovals";
export { applyBookingRequests } from "./bookingConversion";
