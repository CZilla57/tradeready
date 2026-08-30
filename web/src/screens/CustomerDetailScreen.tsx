import { Link, useParams } from 'react-router-dom';
import { useData } from '../lib/DataContext';
import { Card, Empty, Badge, KV } from '../ui/components';
import { jobStatusBadge, invoiceStatusBadge } from '../ui/status';
import { formatMoney } from '@shared/utils/format';
import { formatDisplayDate } from '@shared/utils/dateHelpers';
import { amountPaid, balanceDue } from '@shared/utils/invoicePayments';

export default function CustomerDetailScreen() {
  const { id } = useParams();
  const { customers, jobs, invoices, notes, loading } = useData();

  if (loading) return <Empty>Loading…</Empty>;
  const customer = customers.find((c) => c.id === id);
  if (!customer) return <Empty>Customer not found.</Empty>;

  const custJobs = jobs
    .filter((j) => j.customerId === customer.id && !j.archivedAt)
    .sort((a, b) => (b.createdAt || '').localeCompare(a.createdAt || ''));
  const custInvoices = invoices
    .filter(
      (i) => i.customerId === customer.id || i.customer === customer.name,
    )
    .sort((a, b) => (b.due || '').localeCompare(a.due || ''));

  const collected = custInvoices.reduce((s, i) => s + amountPaid(i), 0);
  const owed = custInvoices.reduce((s, i) => s + balanceDue(i), 0);
  const note = notes[customer.id] || customer.notes;

  return (
    <>
      <Link to="/customers" className="back-link">
        ‹ Customers
      </Link>

      <div className="page-head">
        <div>
          <h1>{customer.name || 'Customer'}</h1>
          <div className="sub">
            {[customer.phone, customer.email].filter(Boolean).join(' · ') ||
              'No contact info'}
          </div>
        </div>
      </div>

      <div className="grid grid-3" style={{ marginBottom: 16 }}>
        <Card className="stat">
          <div className="label">Revenue</div>
          <div className="value pos">{formatMoney(collected)}</div>
        </Card>
        <Card className="stat">
          <div className="label">Owed</div>
          <div className={`value ${owed > 0 ? 'neg' : ''}`.trim()}>
            {formatMoney(owed)}
          </div>
        </Card>
        <Card className="stat">
          <div className="label">Jobs</div>
          <div className="value">{custJobs.length}</div>
        </Card>
      </div>

      <div className="grid" style={{ gridTemplateColumns: '1fr 1fr' }}>
        <Card>
          <div className="section-label">Jobs</div>
          {custJobs.length === 0 ? (
            <Empty>No jobs yet.</Empty>
          ) : (
            <div className="list">
              {custJobs.map((j) => {
                const b = jobStatusBadge(j.status);
                return (
                  <Link key={j.id} to={`/jobs/${j.id}`} className="row">
                    <div className="grow">
                      <div className="title">{j.title || 'Job'}</div>
                      <div className="meta">
                        {j.scheduledDate
                          ? formatDisplayDate(j.scheduledDate)
                          : 'Unscheduled'}
                      </div>
                    </div>
                    <Badge color={b.color}>{b.label}</Badge>
                    <span className="amt">
                      {formatMoney(j.estimateTotal || 0)}
                    </span>
                  </Link>
                );
              })}
            </div>
          )}
        </Card>

        <Card>
          <div className="section-label">Invoices</div>
          {custInvoices.length === 0 ? (
            <Empty>No invoices yet.</Empty>
          ) : (
            <div className="list">
              {custInvoices.map((inv) => {
                const b = invoiceStatusBadge(inv);
                return (
                  <Link
                    key={inv.id}
                    to={`/invoices/${inv.id}`}
                    className="row"
                  >
                    <div className="grow">
                      <div className="title">
                        {inv.number ? `#${inv.number}` : 'Invoice'}
                      </div>
                      <div className="meta">
                        Due {inv.due ? formatDisplayDate(inv.due) : '—'}
                      </div>
                    </div>
                    <Badge color={b.color}>{b.label}</Badge>
                    <span className="amt">{formatMoney(inv.amount || 0)}</span>
                  </Link>
                );
              })}
            </div>
          )}
        </Card>
      </div>

      {(customer.address || note) && (
        <Card pad style={{ marginTop: 16 }}>
          {customer.address && <KV k="Address" v={customer.address} />}
          {note && <KV k="Notes" v={note} />}
        </Card>
      )}
    </>
  );
}
