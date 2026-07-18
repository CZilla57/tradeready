import type { Invoice } from "../types/models";
import { collectedByPeriod } from "./invoicePayments";

const MONTH_NAMES = ["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"];

export interface MonthlyTrend {
  label: string;
  month: number;
  year: number;
  thisYear: number;
  lastYear: number;
}

export interface SeasonalTrendsResult {
  months: MonthlyTrend[];
  thisYearTotal: number;
  lastYearTotal: number;
  yoyChangePct: number | null;
}

export function computeSeasonalTrends(
  invoices: Invoice[],
  now: Date = new Date(),
): SeasonalTrendsResult {
  const months: MonthlyTrend[] = [];
  let thisYearTotal = 0;
  let lastYearTotal = 0;

  // Build this-year and last-year windows for all 12 months, then collect once.
  const windows: { start: Date; end: Date }[] = [];
  const monthMeta: { year: number; month: number }[] = [];
  for (let i = 11; i >= 0; i--) {
    const d = new Date(now.getFullYear(), now.getMonth() - i, 1);
    const year = d.getFullYear();
    const month = d.getMonth();
    monthMeta.push({ year, month });
    windows.push({ start: new Date(year, month, 1), end: new Date(year, month + 1, 0) });
    windows.push({ start: new Date(year - 1, month, 1), end: new Date(year - 1, month + 1, 0) });
  }
  const totals = collectedByPeriod(invoices, windows);

  for (let k = 0; k < monthMeta.length; k++) {
    const { year, month } = monthMeta[k];
    // totals[2*k] is month k this year; totals[2*k + 1] is the same month last year.
    const thisYear = totals[2 * k];
    const lastYear = totals[2 * k + 1];

    thisYearTotal += thisYear;
    lastYearTotal += lastYear;

    months.push({
      label: MONTH_NAMES[month],
      month,
      year,
      thisYear,
      lastYear,
    });
  }

  const yoyChangePct =
    lastYearTotal > 0
      ? Math.round(((thisYearTotal - lastYearTotal) / lastYearTotal) * 100)
      : null;

  return { months, thisYearTotal, lastYearTotal, yoyChangePct };
}
