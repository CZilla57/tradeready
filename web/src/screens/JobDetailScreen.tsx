import { Link, useParams } from 'react-router-dom';
import { useData } from '../lib/DataContext';
import { Card, Empty, Badge, KV } from '../ui/components';
import { jobStatusBadge, JOB_PIPELINE } from '../ui/status';
import { formatMoney } from '@shared/utils/format';
import { formatDisplayDate, formatTimeRange } from '@shared/utils/dateHelpers';

export default function JobDetailScreen() {
  const { id } = useParams();
  const { jobs, customers, invoices, loading } = useData();

  if (loading) return <Empty>Loading…</Empty>;
  const job = jobs.find((j) => j.id === id);
  if (!job) return <Empty>Job not found.</Empty>;

  const badge = jobStatusBadge(job.status);
  const customer = customers.find((c) => c.id === job.customerId);
  const invoice = job.invoiceId
    ? invoices.find((i) => i.id === job.invoiceId)
    : undefined;

  const currentIdx = JOB_PIPELINE.indexOf(job.status);
  const materials = job.materials ?? [];

  return (
    <>
      <Link to="/jobs" className="back-link">
        ‹ Jobs
      </Link>

      <div className="page-head">
        <div>
          <h1>{job.title || job.customerName || 'Job'}</h1>
          <div className="sub">
            {job.customerName || 'No customer'}
            {job.scheduledDate ? ` · ${formatDisplayDate(job.scheduledDate)}` : ''}
          </div>
        </div>
        <Badge color={badge.color}>{badge.label}</Badge>
      </div>

      <div className="grid" style={{ gridTemplateColumns: '1.4fr 1fr' }}>
        <div className="stack">
          {job.description && (
            <Card pad>
              <div className="section-label" style={{ padding: '0 0 8px' }}>
                Description
              </div>
              <div className="muted">{job.description}</div>
            </Card>
          )}

          <Card pad>
            <div className="section-label" style={{ padding: '0 0 12px' }}>
              Status
            </div>
            <div className="timeline">
              {JOB_PIPELINE.map((s, idx) => {
                const state =
                  idx < currentIdx
                    ? 'done'
                    : idx === currentIdx
                      ? 'current'
                      : '';
                return (
                  <div key={s} className={`tl-step ${state}`.trim()}>
                    <span className="tl-dot" />
                    <span className="tl-label">
                      {jobStatusBadge(s).label}
                    </span>
                  </div>
                );
              })}
            </div>
          </Card>

          {materials.length > 0 && (
            <Card>
              <div className="section-label">Materials</div>
              <div className="list">
                {materials.map((m) => (
                  <div key={m.id} className="row">
                    <div className="grow">
                      <div className="title">{m.name || 'Material'}</div>
                      <div className="meta">
                        Qty {m.quantity ?? 0} · {formatMoney(m.unitCost || 0)} ea
                      </div>
                    </div>
                    <span className="amt">
                      {formatMoney((m.quantity || 0) * (m.unitCost || 0))}
                    </span>
                  </div>
                ))}
              </div>
            </Card>
          )}
        </div>

        <div className="stack">
          <Card pad>
            <div className="section-label" style={{ padding: '0 0 8px' }}>
              Overview
            </div>
            <KV k="Estimate total" v={formatMoney(job.estimateTotal || 0)} />
            <KV k="Labor hours" v={String(job.laborHours ?? 0)} />
            {job.laborRate ? (
              <KV k="Labor rate" v={`${formatMoney(job.laborRate)}/hr`} />
            ) : null}
            {job.scheduledStartTime && (
              <KV
                k="Scheduled time"
                v={formatTimeRange(
                  job.scheduledStartTime,
                  job.scheduledEndTime,
                )}
              />
            )}
            {job.address && <KV k="Address" v={job.address} />}
          </Card>

          {customer && (
            <Card pad>
              <div className="section-label" style={{ padding: '0 0 8px' }}>
                Customer
              </div>
              <Link to={`/customers/${customer.id}`} className="title">
                {customer.name}
              </Link>
              {customer.phone && <div className="meta">{customer.phone}</div>}
              {customer.email && <div className="meta">{customer.email}</div>}
            </Card>
          )}

          {invoice && (
            <Card pad>
              <div className="section-label" style={{ padding: '0 0 8px' }}>
                Linked invoice
              </div>
              <Link to={`/invoices/${invoice.id}`} className="title">
                Invoice {invoice.number || invoice.id.slice(0, 6)}
              </Link>
              <div className="meta">{formatMoney(invoice.amount || 0)}</div>
            </Card>
          )}

          {job.notes && (
            <Card pad>
              <div className="section-label" style={{ padding: '0 0 8px' }}>
                Notes
              </div>
              <div className="muted">{job.notes}</div>
            </Card>
          )}
        </div>
      </div>
    </>
  );
}
