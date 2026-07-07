// utils/storage/index.ts
// Public facade for the storage layer. The god-module that used to be
// utils/storage.js is now split into focused concerns (collections, settings,
// the customer registry, app-lifecycle ops, and the Today-tab derived reads);
// this barrel re-exports their public API so every consumer keeps importing from
// "../utils/storage" unchanged.
//
// collections / customers / lifecycle / dailyOps export exactly their public
// surface, so they're re-exported wholesale. settings and defaults each keep an
// internal member (SECURE_FIELDS, the collection seeds) that isn't part of the
// public API, so those two are re-exported by name.

export * from "./collections";
export * from "./customers";
export * from "./lifecycle";
export * from "./dailyOps";

export { loadSettings, saveSettings } from "./settings";
export { defaultSettings } from "./defaults";
