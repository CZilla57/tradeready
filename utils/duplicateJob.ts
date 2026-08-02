// utils/duplicateJob.ts
// Pure helpers behind the "Duplicate job" action (JobDetail → AddJob).
// A duplicate is NEW work for the same customer: it carries the descriptive
// fields and the priced estimate, but not the schedule, pipeline status,
// invoice link, estimate/approval stamps, photos, or time sessions — those
// belong to the original job's lifecycle, not the new one's.

import type { Job, Material } from "../types/models";

/** Form fields AddJobScreen prefills when opened with duplicateFromJobId. */
export interface DuplicateJobPrefill {
  customerId: string;
  customerName: string;
  title: string;
  description: string;
  address: string;
  notes: string;
}

/** Pricing fields carried onto the new job so the estimate needn't be rebuilt. */
export interface DuplicateJobPricing {
  estimateTotal: number;
  laborHours: number;
  laborRate: number;
  materials: Material[];
  materialMarkup: number;
  overhead: number;
  margin: number;
}

export function buildDuplicatePrefill(source: Job): DuplicateJobPrefill {
  return {
    customerId: source.customerId || "",
    customerName: source.customerName || "",
    title: source.title || "",
    description: source.description || "",
    address: source.address || "",
    notes: source.notes || "",
  };
}

export function buildDuplicatePricing(source: Job): DuplicateJobPricing {
  return {
    estimateTotal: source.estimateTotal || 0,
    laborHours: source.laborHours || 0,
    laborRate: source.laborRate || 0,
    // Copy each material so edits to the duplicate never mutate the original.
    materials: (source.materials || []).map((m) => ({ ...m })),
    materialMarkup: source.materialMarkup || 0,
    overhead: source.overhead || 0,
    margin: source.margin || 0,
  };
}
