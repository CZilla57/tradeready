// utils/mileageUtils.ts
// Pure math + constants for the mileage tax-deduction log. No I/O, no React —
// mirrors the formula-utility style of pricingEngine / invoiceStats so it is
// unit-testable in isolation.

import type { Trip } from '../types/models';
import { isInRange } from './moneyUtils';

/** IRS standard mileage rate default ($/mile). User overrides per tax year in Settings. */
export const DEFAULT_MILEAGE_RATE = 0.70;

/** Label used when a trip endpoint is the user's base rather than a job. */
export const HOME_LABEL = 'Home / Shop';

export interface MileageSummary {
  tripCount: number;
  totalMiles: number;
  deduction: number;
}

/** Miles for one trip: end − start, never negative, rounded to 0.1. */
export function computeTripMiles(start: number, end: number): number {
  const raw = (Number(end) || 0) - (Number(start) || 0);
  return Math.round(Math.max(0, raw) * 10) / 10;
}

/** Total miles + dollar deduction for trips whose date falls within [start, end]. */
export function mileageSummary(
  trips: Trip[],
  start: Date,
  end: Date,
  rate: number,
): MileageSummary {
  const inRange = trips.filter((t) => isInRange(t.date, start, end));
  const totalMiles =
    Math.round(inRange.reduce((sum, t) => sum + (Number(t.miles) || 0), 0) * 10) / 10;
  const deduction = Math.round(totalMiles * (Number(rate) || 0) * 100) / 100;
  return { tripCount: inRange.length, totalMiles, deduction };
}

/** Display miles as "12.0 mi". */
export function formatMiles(miles: number): string {
  return `${(Number(miles) || 0).toFixed(1)} mi`;
}

/** Collision-resistant local id, matching generateExpenseId's style. */
export function generateTripId(): string {
  return Date.now().toString() + Math.random().toString(36).slice(2, 7);
}
