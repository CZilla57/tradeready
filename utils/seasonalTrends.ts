import type { Invoice } from "../types/models";

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

function incomeInMonth(invoices: Invoice[], year: number, month: number): number {
  let total = 0;
  for (const inv of invoices) {
    if (!inv.paid) continue;
    const dateStr = inv.paidAt ?? inv.due;
    if (!dateStr) continue;
    const d = new Date(dateStr);
    if (d.getFullYear() === year && d.getMonth() === month) {
      total += inv.amount || 0;
    }
  }
  return total;
}

export function computeSeasonalTrends(
  invoices: Invoice[],
  now: Date = new Date(),
): SeasonalTrendsResult {
  const months: MonthlyTrend[] = [];
  let thisYearTotal = 0;
  let lastYearTotal = 0;

  for (let i = 11; i >= 0; i--) {
    const d = new Date(now.getFullYear(), now.getMonth() - i, 1);
    const year = d.getFullYear();
    const month = d.getMonth();
    const thisYear = incomeInMonth(invoices, year, month);
    const lastYear = incomeInMonth(invoices, year - 1, month);

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
