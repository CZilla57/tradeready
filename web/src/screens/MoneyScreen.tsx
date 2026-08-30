import { useMemo } from 'react';
import { useData, useResources } from '../lib/DataContext';
import { Card, PageHead, Empty, Stat, ErrorState } from '../ui/components';
import { formatMoney } from '@shared/utils/format';
import { summarizeInvoices } from '../ui/invoiceMath';
import { effectivePayments } from '@shared/utils/invoicePayments';
import type { Invoice, Expense } from '@shared/types/models';

function monthKey(dateStr: string): string {
  // Dates are stored as "YYYY-MM-DD"; take the leading "YYYY-MM".
  return (dateStr || '').slice(0, 7);
}

function last6Months(now = new Date()): string[] {
  const keys: string[] = [];
  for (let i = 5; i >= 0; i--) {
    const d = new Date(now.getFullYear(), now.getMonth() - i, 1);
    keys.push(
      `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}`,
    );
  }
  return keys;
}

function monthLabel(key: string): string {
  const [y, m] = key.split('-').map(Number);
  return new Date(y, m - 1, 1).toLocaleString('en-US', { month: 'short' });
}

function revenueByMonth(invoices: Invoice[]): Map<string, number> {
  const map = new Map<string, number>();
  for (const inv of invoices) {
    for (const p of effectivePayments(inv)) {
      if (p.voidedAt) continue;
      const key = monthKey(p.date);
      if (!key) continue;
      map.set(key, (map.get(key) ?? 0) + (Number(p.amount) || 0));
    }
  }
  return map;
}

function expensesByMonth(expenses: Expense[]): Map<string, number> {
  const map = new Map<string, number>();
  for (const e of expenses) {
    const key = monthKey(e.date || e.createdAt);
    if (!key) continue;
    map.set(key, (map.get(key) ?? 0) + (Number(e.amount) || 0));
  }
  return map;
}

export default function MoneyScreen() {
  const { invoices, expenses } = useData();
  const state = useResources('invoices', 'expenses');

  const summary = useMemo(() => summarizeInvoices(invoices), [invoices]);
  const months = useMemo(() => last6Months(), []);
  const revMap = useMemo(() => revenueByMonth(invoices), [invoices]);
  const expMap = useMemo(() => expensesByMonth(expenses), [expenses]);

  const thisMonth = months[months.length - 1];
  const revThisMonth = revMap.get(thisMonth) ?? 0;
  const expThisMonth = expMap.get(thisMonth) ?? 0;

  const maxRev = Math.max(1, ...months.map((m) => revMap.get(m) ?? 0));

  if (state.loading) return <Empty>Loading finances…</Empty>;
  if (state.error)
    return (
      <ErrorState
        message={`Couldn’t load finances: ${state.error}`}
        onRetry={state.retry}
      />
    );

  return (
    <>
      <PageHead title="Money" sub="Last 6 months" />

      <div className="grid grid-4" style={{ marginBottom: 16 }}>
        <Stat
          label="Collected (mo)"
          value={formatMoney(revThisMonth)}
          tone="pos"
        />
        <Stat
          label="Expenses (mo)"
          value={formatMoney(expThisMonth)}
          tone={expThisMonth > 0 ? 'neg' : undefined}
        />
        <Stat
          label="Net (mo)"
          value={formatMoney(revThisMonth - expThisMonth)}
          tone={revThisMonth - expThisMonth >= 0 ? 'pos' : 'neg'}
        />
        <Stat
          label="Outstanding"
          value={formatMoney(summary.outstanding)}
          tone={summary.outstanding > 0 ? 'neg' : undefined}
          hint={`${summary.overdueCount} overdue`}
        />
      </div>

      <Card pad>
        <div className="section-label" style={{ padding: '0 0 4px' }}>
          Revenue collected
        </div>
        <div className="bars">
          {months.map((m) => {
            const val = revMap.get(m) ?? 0;
            const h = Math.round((val / maxRev) * 100);
            return (
              <div key={m} className="bar-col">
                <div className="bar-val">{val ? formatMoney(val) : ''}</div>
                <div
                  className="bar"
                  style={{ height: `${Math.max(val ? 4 : 0, h)}%` }}
                />
                <div className="bar-label">{monthLabel(m)}</div>
              </div>
            );
          })}
        </div>
      </Card>

      <Card style={{ marginTop: 16 }}>
        <div className="section-label">Monthly breakdown</div>
        <div className="list">
          {[...months].reverse().map((m) => {
            const rev = revMap.get(m) ?? 0;
            const exp = expMap.get(m) ?? 0;
            return (
              <div key={m} className="row">
                <div className="grow">
                  <div className="title">{monthLabel(m)}</div>
                  <div className="meta">
                    Collected {formatMoney(rev)} · Expenses {formatMoney(exp)}
                  </div>
                </div>
                <span
                  className="amt"
                  style={{ color: rev - exp >= 0 ? 'var(--green)' : 'var(--red)' }}
                >
                  {formatMoney(rev - exp)}
                </span>
              </div>
            );
          })}
        </div>
      </Card>
    </>
  );
}
