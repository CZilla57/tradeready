// utils/taxEstimate.ts
// Pure math for the quarterly tax set-aside estimate. No I/O, no React —
// mirrors the formula-utility style of pricingEngine / invoiceStats /
// mileageUtils so every rule here is unit-testable in isolation.
//
// WHAT THIS IS: a set-aside ESTIMATE (self-employment tax + a user-set
// effective income-tax rate), not a tax return. The UI must always carry the
// disclaimer; the AI coach may cite the figures but not give filing advice.
//
// ANNUAL MAINTENANCE OBLIGATION: SS_WAGE_BASE needs the new year's value every
// January (and the SE rates re-checked). Recorded on
// docs/ops-monthly-checklist.md. An unknown year computes with the latest
// known base and flags `ratesKnown: false` rather than going blank — the base
// only matters above the wage cap, so the figure stays useful for the target
// user while the notice nudges an update.
//
// Constants verified against IRS primary sources 2026-07-18
// (irs.gov/taxtopics/tc751, 2026 Schedule SE):
//   Social Security 12.4% up to the annual wage base; Medicare 2.9% uncapped;
//   net earnings = 92.35% of net profit; half of SE tax deducts against
//   income. The 0.9% Additional Medicare surtax is deliberately NOT modeled
//   (needs filing status; bites above $200k net — disclosed, not computed).

import type { Expense, Invoice, Settings, Trip, VehicleDeductionMethod } from "../types/models";
import { isInRange } from "./moneyUtils";
import { collectedInRange } from "./invoicePayments";
import { mileageSummary, DEFAULT_MILEAGE_RATE } from "./mileageUtils";

export const SE_NET_EARNINGS_FACTOR = 0.9235;
export const SOCIAL_SECURITY_RATE = 0.124;
export const MEDICARE_RATE = 0.029;

/**
 * Social Security wage base by tax year. VERSIONED on purpose: the value
 * changes every year, and silently reusing an old one would be a wrong answer
 * that looks right. Add January's announcement here each year.
 */
export const SS_WAGE_BASE: Record<number, number> = {
  2025: 176100,
  2026: 184500,
};

const LATEST_KNOWN_YEAR = Math.max(...Object.keys(SS_WAGE_BASE).map(Number));

/* ------------------------------------------------------------------ */
/* IRS estimated-payment periods                                       */
/* ------------------------------------------------------------------ */

export interface TaxPeriod {
  quarter: 1 | 2 | 3 | 4;
  /** The tax year the income belongs to (Q4's deadline falls in year+1). */
  year: number;
  start: Date;
  /** Inclusive last day of the period, local midnight. */
  end: Date;
  /** The estimated-payment deadline, weekend-shifted to the next Monday. */
  due: Date;
}

/**
 * Shift a deadline landing on a weekend to the following Monday — the real
 * IRS rule ("next business day"). Federal legal holidays are deliberately NOT
 * modeled (owner decision): a holiday-shifted deadline shown one business day
 * early is harmless; a holiday table that goes stale is not.
 */
function shiftOffWeekend(d: Date): Date {
  const day = d.getDay();
  if (day === 6) return new Date(d.getFullYear(), d.getMonth(), d.getDate() + 2);
  if (day === 0) return new Date(d.getFullYear(), d.getMonth(), d.getDate() + 1);
  return d;
}

/**
 * The four estimated-payment periods for a tax year. UNEVEN by law — 3/2/3/4
 * months, NOT calendar quarters. Encoding them as even quarters is a silent
 * wrong answer (June income belongs to Q3, due September, not Q2).
 */
export function taxPeriodsForYear(year: number): TaxPeriod[] {
  return [
    { quarter: 1, year, start: new Date(year, 0, 1), end: new Date(year, 2, 31), due: shiftOffWeekend(new Date(year, 3, 15)) },
    { quarter: 2, year, start: new Date(year, 3, 1), end: new Date(year, 4, 31), due: shiftOffWeekend(new Date(year, 5, 15)) },
    { quarter: 3, year, start: new Date(year, 5, 1), end: new Date(year, 7, 31), due: shiftOffWeekend(new Date(year, 8, 15)) },
    { quarter: 4, year, start: new Date(year, 8, 1), end: new Date(year, 11, 31), due: shiftOffWeekend(new Date(year + 1, 0, 15)) },
  ];
}

/** The period whose [start, end] contains `now` — the money being earned now. */
export function currentTaxPeriod(now: Date): TaxPeriod {
  const periods = taxPeriodsForYear(now.getFullYear());
  const t = new Date(now.getFullYear(), now.getMonth(), now.getDate()).getTime();
  const found = periods.find((p) => t >= p.start.getTime() && t <= p.end.getTime());
  // Every date falls in one of the four periods; the fallback is unreachable
  // but keeps the return type honest.
  return found ?? periods[3];
}

/** "Jun 1 – Aug 31" */
export function formatPeriodRange(period: TaxPeriod): string {
  const fmt = (d: Date) => d.toLocaleDateString("en-US", { month: "short", day: "numeric" });
  return `${fmt(period.start)} – ${fmt(period.end)}`;
}

/** "Sep 15" (with the year when it differs from the period's, e.g. Q4). */
export function formatDeadline(period: TaxPeriod): string {
  const sameYear = period.due.getFullYear() === period.year;
  return period.due.toLocaleDateString(
    "en-US",
    sameYear ? { month: "short", day: "numeric" } : { month: "short", day: "numeric", year: "numeric" },
  );
}

/* ------------------------------------------------------------------ */
/* Deduction inputs                                                    */
/* ------------------------------------------------------------------ */

/** Coerce a persisted amount; malformed contributes zero, never NaN. */
function toAmount(value: unknown): number {
  const n = typeof value === "number" ? value : parseFloat(String(value));
  return Number.isFinite(n) ? n : 0;
}

export interface ExpenseSplit {
  /** Deductible business expenses EXCLUDING the fuel category. */
  nonVehicle: number;
  /** The `fuel` category — only deductible under the 'actual' method. */
  fuel: number;
}

/**
 * Split window expenses into vehicle (fuel) and everything else. Fuel is held
 * apart because the IRS allows standard mileage OR actual vehicle costs,
 * never both — the caller resolves which side counts via
 * resolveVehicleDeduction.
 */
export function splitDeductibleExpenses(expenses: Expense[], start: Date, end: Date): ExpenseSplit {
  let nonVehicle = 0;
  let fuel = 0;
  for (const exp of expenses) {
    if (!isInRange(exp.date, start, end)) continue;
    if (exp.category === "fuel") fuel += toAmount(exp.amount);
    else nonVehicle += toAmount(exp.amount);
  }
  return { nonVehicle, fuel };
}

export interface VehicleDeductionResult {
  deduction: number;
  /**
   * True when vehicle inputs exist (miles or fuel expenses) but no method has
   * been chosen. The estimate then deducts NEITHER — over-reserving, the safe
   * failure direction — and the UI prompts for the election. The app never
   * auto-picks: which method to use is a real tax election, not a default.
   */
  needsChoice: boolean;
}

export function resolveVehicleDeduction(args: {
  method: VehicleDeductionMethod | undefined;
  miles: number;
  mileageRate: number;
  fuelExpenses: number;
}): VehicleDeductionResult {
  const { method, miles, mileageRate, fuelExpenses } = args;
  if (method === "mileage") {
    return { deduction: Math.round(toAmount(miles) * toAmount(mileageRate) * 100) / 100, needsChoice: false };
  }
  if (method === "actual") {
    return { deduction: toAmount(fuelExpenses), needsChoice: false };
  }
  return { deduction: 0, needsChoice: toAmount(miles) > 0 || toAmount(fuelExpenses) > 0 };
}

/* ------------------------------------------------------------------ */
/* The reserve estimate                                                */
/* ------------------------------------------------------------------ */

export interface TaxEstimateInput {
  collectedIncome: number;
  /** Non-vehicle deductible expenses for the window. */
  deductibleExpenses: number;
  /** Resolved vehicle deduction (0 when the method is unset). */
  vehicleDeduction: number;
  /** User's effective income-tax rate in percent (0 when unset). */
  incomeRatePercent: number;
  /** Tax year, for the wage-base lookup. */
  year: number;
}

export interface TaxEstimate {
  netProfit: number;
  seTax: number;
  incomeTax: number;
  /** seTax + incomeTax — the dollars to put aside for this window. */
  reserve: number;
  /** False when SS_WAGE_BASE lacks `year` (computed with the latest known). */
  ratesKnown: boolean;
}

/**
 * The set-aside estimate for one window.
 *
 * KNOWN SIMPLIFICATION (documented, accepted): the Social Security cap is
 * applied to each computed window independently rather than reconciled across
 * the year. That only overstates SE tax once net earnings pass the wage base
 * (~$184.5k), where the card's "assumes net profit under $200k" disclosure
 * already applies.
 */
export function estimateTaxReserve(input: TaxEstimateInput): TaxEstimate {
  const ratesKnown = input.year in SS_WAGE_BASE;
  const wageBase = SS_WAGE_BASE[ratesKnown ? input.year : LATEST_KNOWN_YEAR];

  const netProfit =
    toAmount(input.collectedIncome) -
    toAmount(input.deductibleExpenses) -
    toAmount(input.vehicleDeduction);

  const seBase = Math.max(0, netProfit * SE_NET_EARNINGS_FACTOR);
  const seTax = Math.min(seBase, wageBase) * SOCIAL_SECURITY_RATE + seBase * MEDICARE_RATE;

  const ratePct = Math.max(0, toAmount(input.incomeRatePercent));
  const incomeTax = Math.max(0, netProfit - seTax / 2) * (ratePct / 100);

  const round2 = (n: number) => Math.round(n * 100) / 100;
  return {
    netProfit: round2(netProfit),
    seTax: round2(seTax),
    incomeTax: round2(incomeTax),
    reserve: round2(seTax + incomeTax),
    ratesKnown,
  };
}

/* ------------------------------------------------------------------ */
/* The one aggregator the card and the AI snapshot share               */
/* ------------------------------------------------------------------ */

export interface TaxWindowSummary {
  period: TaxPeriod;
  /** Reserve for the current payment period. */
  current: TaxEstimate;
  /** Reserve for Jan 1 → today. */
  ytd: TaxEstimate;
  /** Vehicle inputs exist but no method is chosen (YTD window). */
  needsVehicleChoice: boolean;
  /** Whether the user has set an income-tax rate (false = SE tax only). */
  incomeRateSet: boolean;
  /** Trips contributing to the YTD mileage figure — for the local-only disclosure. */
  ytdTripCount: number;
}

/**
 * Everything the tax card and the coach snapshot need, from raw collections.
 * Pure — pass `now` for deterministic tests. Income is the payment ledger
 * (cash basis) via collectedInRange; expenses bucket by exp.date; mileage by
 * trip date at settings.mileageRate.
 */
export function summarizeTaxWindow(args: {
  invoices: Invoice[];
  expenses: Expense[];
  trips: Trip[];
  settings: Partial<Settings>;
  now?: Date;
}): TaxWindowSummary {
  const { invoices, expenses, trips, settings } = args;
  const now = args.now ?? new Date();

  const period = currentTaxPeriod(now);
  const ytdStart = new Date(now.getFullYear(), 0, 1);
  const today = new Date(now.getFullYear(), now.getMonth(), now.getDate());

  const method = settings.vehicleDeductionMethod;
  const rate = settings.mileageRate ?? DEFAULT_MILEAGE_RATE;
  const incomeRatePercent = settings.taxIncomeRate ?? 0;

  function estimateFor(start: Date, end: Date): { estimate: TaxEstimate; vehicle: VehicleDeductionResult; tripCount: number } {
    const split = splitDeductibleExpenses(expenses, start, end);
    const miles = mileageSummary(trips, start, end, rate);
    const vehicle = resolveVehicleDeduction({
      method,
      miles: miles.totalMiles,
      mileageRate: rate,
      fuelExpenses: split.fuel,
    });
    const estimate = estimateTaxReserve({
      collectedIncome: collectedInRange(invoices, start, end),
      deductibleExpenses: split.nonVehicle,
      vehicleDeduction: vehicle.deduction,
      incomeRatePercent,
      year: start.getFullYear(),
    });
    return { estimate, vehicle, tripCount: miles.tripCount };
  }

  const current = estimateFor(period.start, period.end);
  const ytd = estimateFor(ytdStart, today);

  return {
    period,
    current: current.estimate,
    ytd: ytd.estimate,
    needsVehicleChoice: ytd.vehicle.needsChoice,
    incomeRateSet: settings.taxIncomeRate !== undefined && settings.taxIncomeRate !== null,
    ytdTripCount: ytd.tripCount,
  };
}
