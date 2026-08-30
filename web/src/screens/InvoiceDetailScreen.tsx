import { Link, useParams } from 'react-router-dom';
import { useData } from '../lib/DataContext';
import { Card, Empty, Badge, KV } from '../ui/components';
import { invoiceStatusBadge } from '../ui/status';
import { formatMoney } from '@shared/utils/format';
import { formatDisplayDate } from '@shared/utils/dateHelpers';
import {
  amountPaid,
  balanceDue,
  effectivePayments,
} from '@shared/utils/invoicePayments';

export default function InvoiceDetailScreen() {
  const { id } = useParams();
  const { invoices, customers, loading } = useData();

  if (loading) return <Empty>Loading…</Empty>;
  const inv = invoices.find((i) => i.id === id);
  if (!inv) return <Empty>Invoice not found.</Empty>;

  const badge = invoiceStatusBadge(inv);
  const customer =
    (inv.customerId && customers.find((c) => c.id === inv.customerId)) ||
    customers.find((c) => c.name === inv.customer);
  const payments = effectivePayments(inv).filter((p) => !p.voidedAt);
  const lineItems = inv.lineItems ?? [];

  return (
    <>
      <Link to="/invoices" className="back-link">
        ‹ Invoices
      </Link>

      <div className="page-head">
        <div>
          <h1>{inv.customer || 'Invoice'}</h1>
          <div className="sub">
            {inv.number ? `Invoice #${inv.number} · ` : ''}
            Due {inv.due ? formatDisplayDate(inv.due) : '—'}
          </div>
        </div>
        <Badge color={badge.color}>{badge.label}</Badge>
      </div>

      <div className="grid" style={{ gridTemplateColumns: '1.4fr 1fr' }}>
        <div className="stack">
          {inv.desc && (
            <Card pad>
              <div className="section-label" style={{ padding: '0 0 8px' }}>
                Description
              </div>
              <div className="muted">{inv.desc}</div>
            </Card>
          )}

          {lineItems.length > 0 && (
            <Card>
              <div className="section-label">Line items</div>
              <div className="list">
                {lineItems.map((li, i) => (
                  <div key={i} className="row">
                    <div className="grow">
                      <div className="title">{li.description || 'Item'}</div>
                    </div>
                    <span className="amt">{formatMoney(li.amount || 0)}</span>
                  </div>
                ))}
              </div>
            </Card>
          )}

          <Card>
            <div className="section-label">Payments</div>
            {payments.length === 0 ? (
              <Empty>No payments recorded.</Empty>
            ) : (
              <div className="list">
                {payments.map((p) => (
                  <div key={p.id} className="row">
                    <div className="grow">
                      <div className="title">{formatMoney(p.amount || 0)}</div>
                      <div className="meta">
                        {p.method}
                        {p.date ? ` · ${formatDisplayDate(p.date)}` : ''}
                        {p.note ? ` · ${p.note}` : ''}
                      </div>
                    </div>
                  </div>
                ))}
              </div>
            )}
          </Card>
        </div>

        <div className="stack">
          <Card pad>
            <div className="section-label" style={{ padding: '0 0 8px' }}>
              Summary
            </div>
            <KV k="Invoice total" v={formatMoney(inv.amount || 0)} />
            <KV k="Paid" v={formatMoney(amountPaid(inv))} />
            <KV k="Balance due" v={formatMoney(balanceDue(inv))} />
            {inv.paidAt && <KV k="Paid on" v={formatDisplayDate(inv.paidAt)} />}
          </Card>

          {(inv.email || inv.phone || customer) && (
            <Card pad>
              <div className="section-label" style={{ padding: '0 0 8px' }}>
                Customer
              </div>
              {customer ? (
                <Link to={`/customers/${customer.id}`} className="title">
                  {customer.name}
                </Link>
              ) : (
                <div className="title">{inv.customer}</div>
              )}
              {(inv.phone || customer?.phone) && (
                <div className="meta">{inv.phone || customer?.phone}</div>
              )}
              {(inv.email || customer?.email) && (
                <div className="meta">{inv.email || customer?.email}</div>
              )}
            </Card>
          )}
        </div>
      </div>
    </>
  );
}
