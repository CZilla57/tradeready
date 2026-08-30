import { useMemo, useState } from 'react';
import { Link } from 'react-router-dom';
import { useData } from '../lib/DataContext';
import { Card, PageHead, Empty, Badge, Stat } from '../ui/components';
import { invoiceStatusBadge } from '../ui/status';
import { formatMoney } from '@shared/utils/format';
import { formatDisplayDate } from '@shared/utils/dateHelpers';
import { summarizeInvoices, isOverdue } from '../ui/invoiceMath';
import { isFullyPaid } from '@shared/utils/invoicePayments';
import type { Invoice } from '@shared/types/models';

type Filter = 'open' | 'overdue' | 'paid' | 'all';

function matches(inv: Invoice, filter: Filter): boolean {
  switch (filter) {
    case 'open':
      return !isFullyPaid(inv);
    case 'overdue':
      return isOverdue(inv);
    case 'paid':
      return isFullyPaid(inv);
    default:
      return true;
  }
}

const FILTERS: { key: Filter; label: string }[] = [
  { key: 'open', label: 'Open' },
  { key: 'overdue', label: 'Overdue' },
  { key: 'paid', label: 'Paid' },
  { key: 'all', label: 'All' },
];

export default function InvoicesScreen() {
  const { invoices, loading, error } = useData();
  const [filter, setFilter] = useState<Filter>('open');
  const [q, setQ] = useState('');

  const active = invoices;
  const summary = useMemo(() => summarizeInvoices(active), [active]);

  const rows = useMemo(() => {
    const term = q.trim().toLowerCase();
    return active
      .filter((i) => matches(i, filter))
      .filter(
        (i) =>
          !term ||
          i.customer?.toLowerCase().includes(term) ||
          i.number?.toLowerCase().includes(term),
      )
      .sort((a, b) => (b.due || '').localeCompare(a.due || ''));
  }, [active, filter, q]);

  if (loading) return <Empty>Loading invoices…</Empty>;
  if (error) return <Empty>Couldn’t load invoices: {error}</Empty>;

  return (
    <>
      <PageHead title="Invoices" />

      <div className="grid grid-3" style={{ marginBottom: 16 }}>
        <Stat
          label="Outstanding"
          value={formatMoney(summary.outstanding)}
          tone={summary.outstanding > 0 ? 'neg' : undefined}
        />
        <Stat label="Collected" value={formatMoney(summary.collected)} tone="pos" />
        <Stat label="Overdue" value={String(summary.overdueCount)} />
      </div>

      <input
        className="search"
        placeholder="Search by customer or invoice number…"
        value={q}
        onChange={(e) => setQ(e.target.value)}
      />
      <div className="pills">
        {FILTERS.map((f) => (
          <button
            key={f.key}
            className={`pill ${filter === f.key ? 'active' : ''}`.trim()}
            onClick={() => setFilter(f.key)}
          >
            {f.label}
          </button>
        ))}
      </div>

      <Card>
        {rows.length === 0 ? (
          <Empty>No invoices match.</Empty>
        ) : (
          <div className="list">
            {rows.map((inv) => {
              const badge = invoiceStatusBadge(inv);
              return (
                <Link key={inv.id} to={`/invoices/${inv.id}`} className="row">
                  <div className="grow">
                    <div className="title">{inv.customer || 'No customer'}</div>
                    <div className="meta">
                      {inv.number ? `#${inv.number} · ` : ''}
                      Due {inv.due ? formatDisplayDate(inv.due) : '—'}
                    </div>
                  </div>
                  <Badge color={badge.color}>{badge.label}</Badge>
                  <span className="amt">{formatMoney(inv.amount || 0)}</span>
                  <span className="chev">›</span>
                </Link>
              );
            })}
          </div>
        )}
      </Card>
    </>
  );
}
