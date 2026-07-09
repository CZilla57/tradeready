import type { Expense } from '../types/models';

const MONTH_NAMES = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];

export interface MonthlyExpense {
  label: string;
  month: number;
  year: number;
  total: number;
  momChangePct: number | null;
}

export interface ExpenseTrendsResult {
  months: MonthlyExpense[];
  trailingTotal: number;
  avgMonthly: number;
  overallTrend: number | null;
}

function expensesInMonth(expenses: Expense[], year: number, month: number): number {
  let total = 0;
  for (const exp of expenses) {
    if (!exp.date) continue;
    const d = new Date(exp.date);
    if (d.getFullYear() === year && d.getMonth() === month) {
      total += exp.amount || 0;
    }
  }
  return total;
}

export function computeExpenseTrends(
  expenses: Expense[],
  now: Date = new Date(),
): ExpenseTrendsResult {
  const months: MonthlyExpense[] = [];
  let trailingTotal = 0;

  for (let i = 11; i >= 0; i--) {
    const d = new Date(now.getFullYear(), now.getMonth() - i, 1);
    const year = d.getFullYear();
    const month = d.getMonth();
    const total = expensesInMonth(expenses, year, month);
    trailingTotal += total;

    months.push({
      label: MONTH_NAMES[month],
      month,
      year,
      total,
      momChangePct: null,
    });
  }

  for (let i = 1; i < months.length; i++) {
    const prior = months[i - 1].total;
    const current = months[i].total;
    if (prior > 0) {
      months[i].momChangePct = Math.round(((current - prior) / prior) * 100);
    }
  }

  const oldest = months[0].total;
  const newest = months[months.length - 1].total;
  const overallTrend = oldest > 0
    ? Math.round(((newest - oldest) / oldest) * 100)
    : null;

  return {
    months,
    trailingTotal,
    avgMonthly: Math.round(trailingTotal / 12),
    overallTrend,
  };
}
