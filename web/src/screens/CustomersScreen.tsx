import { useMemo, useState } from 'react';
import { Link } from 'react-router-dom';
import { useData } from '../lib/DataContext';
import { Card, PageHead, Empty } from '../ui/components';
import { formatMoney } from '@shared/utils/format';
import { amountPaid } from '@shared/utils/invoicePayments';

export default function CustomersScreen() {
  const { customers, invoices, loading, error } = useData();
  const [q, setQ] = useState('');

  const revenueByName = useMemo(() => {
    const map = new Map<string, number>();
    for (const inv of invoices) {
      const key = inv.customer || '';
      map.set(key, (map.get(key) ?? 0) + amountPaid(inv));
    }
    return map;
  }, [invoices]);

  const rows = useMemo(() => {
    const term = q.trim().toLowerCase();
    return customers
      .filter((c) => !c.archivedAt)
      .filter(
        (c) =>
          !term ||
          c.name?.toLowerCase().includes(term) ||
          c.email?.toLowerCase().includes(term) ||
          c.phone?.toLowerCase().includes(term),
      )
      .sort((a, b) => (a.name || '').localeCompare(b.name || ''));
  }, [customers, q]);

  if (loading) return <Empty>Loading customers…</Empty>;
  if (error) return <Empty>Couldn’t load customers: {error}</Empty>;

  return (
    <>
      <PageHead title="Customers" sub={`${rows.length} shown`} />
      <input
        className="search"
        placeholder="Search by name, email, phone…"
        value={q}
        onChange={(e) => setQ(e.target.value)}
      />
      <Card>
        {rows.length === 0 ? (
          <Empty>No customers match.</Empty>
        ) : (
          <div className="list">
            {rows.map((c) => (
              <Link key={c.id} to={`/customers/${c.id}`} className="row">
                <div className="grow">
                  <div className="title">{c.name || 'Unnamed'}</div>
                  <div className="meta">
                    {[c.phone, c.email].filter(Boolean).join(' · ') ||
                      c.address ||
                      'No contact info'}
                  </div>
                </div>
                <span className="amt">
                  {formatMoney(revenueByName.get(c.name) ?? 0)}
                </span>
                <span className="chev">›</span>
              </Link>
            ))}
          </div>
        )}
      </Card>
    </>
  );
}
