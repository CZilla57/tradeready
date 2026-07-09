import { computeExpenseTrends } from '../utils/expenseTrends';

const NOW = new Date(2026, 6, 9); // July 9 2026 — window = Aug 2025 → Jul 2026

function makeExpense(date, amount) {
  return { id: '1', createdAt: date, description: 'test', amount, category: 'other', date, notes: '', receiptUri: null };
}

describe('computeExpenseTrends', () => {
  it('returns 12 months of zeroes for empty expenses', () => {
    const result = computeExpenseTrends([], NOW);
    expect(result.months).toHaveLength(12);
    expect(result.trailingTotal).toBe(0);
    expect(result.avgMonthly).toBe(0);
    expect(result.overallTrend).toBeNull();
    result.months.forEach(m => expect(m.total).toBe(0));
  });

  it('sums expenses in the correct month', () => {
    const expenses = [
      makeExpense('2026-03-10', 200),
      makeExpense('2026-03-20', 100),
      makeExpense('2026-04-05', 50),
    ];
    const result = computeExpenseTrends(expenses, NOW);
    const mar = result.months.find(m => m.label === 'Mar' && m.year === 2026);
    const apr = result.months.find(m => m.label === 'Apr' && m.year === 2026);
    expect(mar.total).toBe(300);
    expect(apr.total).toBe(50);
    expect(result.trailingTotal).toBe(350);
  });

  it('computes MoM change percentage', () => {
    const expenses = [
      makeExpense('2026-03-10', 200),
      makeExpense('2026-04-10', 300),
    ];
    const result = computeExpenseTrends(expenses, NOW);
    const apr = result.months.find(m => m.label === 'Apr' && m.year === 2026);
    expect(apr.momChangePct).toBe(50); // (300-200)/200 * 100
  });

  it('returns null MoM when prior month is zero', () => {
    const expenses = [
      makeExpense('2026-05-10', 100),
    ];
    const result = computeExpenseTrends(expenses, NOW);
    const may = result.months.find(m => m.label === 'May' && m.year === 2026);
    expect(may.momChangePct).toBeNull();
  });

  it('returns null MoM for the earliest month', () => {
    const expenses = [
      makeExpense('2025-08-15', 500),
    ];
    const result = computeExpenseTrends(expenses, NOW);
    expect(result.months[0].momChangePct).toBeNull();
  });

  it('excludes expenses outside the 12-month window', () => {
    const expenses = [
      makeExpense('2025-07-01', 999), // before Aug 2025 window start
      makeExpense('2026-01-15', 100), // inside window
    ];
    const result = computeExpenseTrends(expenses, NOW);
    expect(result.trailingTotal).toBe(100);
  });

  it('computes overallTrend as change from oldest to newest month', () => {
    const expenses = [
      makeExpense('2025-08-10', 100), // oldest month in window
      makeExpense('2026-07-05', 150), // newest month in window
    ];
    const result = computeExpenseTrends(expenses, NOW);
    expect(result.overallTrend).toBe(50); // (150-100)/100 * 100
  });

  it('returns null overallTrend when oldest month is zero', () => {
    const expenses = [
      makeExpense('2026-07-05', 150),
    ];
    const result = computeExpenseTrends(expenses, NOW);
    expect(result.overallTrend).toBeNull();
  });

  it('computes avgMonthly as trailingTotal / 12', () => {
    const expenses = [
      makeExpense('2026-01-10', 120),
      makeExpense('2026-02-10', 240),
    ];
    const result = computeExpenseTrends(expenses, NOW);
    expect(result.avgMonthly).toBe(30); // 360 / 12
  });
});
