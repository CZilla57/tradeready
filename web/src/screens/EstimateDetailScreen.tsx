import { Link, useParams } from 'react-router-dom';
import { useData, useResources } from '../lib/DataContext';
import { Card, Empty, Badge, KV, ErrorState } from '../ui/components';
import { estimateStatusBadge } from '../ui/status';
import { formatMoney } from '@shared/utils/format';
import { formatDisplayDate } from '@shared/utils/dateHelpers';
import {
  jobBillableTotal,
  approvedChangeOrderTotal,
  changeOrderStatus,
} from '../ui/changeOrderMath';

export default function EstimateDetailScreen() {
  const { id } = useParams();
  const { jobs, customers } = useData();
  const state = useResources('jobs');

  if (state.loading) return <Empty>Loading…</Empty>;
  if (state.error)
    return (
      <ErrorState
        message={`Couldn’t load this estimate: ${state.error}`}
        onRetry={state.retry}
      />
    );
  const job = jobs.find((j) => j.id === id);
  if (!job) return <Empty>Estimate not found.</Empty>;

  const badge = estimateStatusBadge(job);
  const customer = customers.find((c) => c.id === job.customerId);
  const approval = job.approval;
  const snapshotLines = approval?.snapshot?.lineItems ?? [];
  const changeOrders = (job.changeOrders ?? []).filter((co) => !co.cancelledAt);
  const coTotal = approvedChangeOrderTotal(job);
  const billable = jobBillableTotal(job);

  return (
    <>
      <Link to="/estimates" className="back-link">
        ‹ Estimates
      </Link>

      <div className="page-head">
        <div>
          <h1>{job.title || job.customerName || 'Estimate'}</h1>
          <div className="sub">
            {job.customerName || 'No customer'}
            {job.estimateSentAt
              ? ` · sent ${formatDisplayDate(job.estimateSentAt)}`
              : ''}
          </div>
        </div>
        <Badge color={badge.color}>{badge.label}</Badge>
      </div>

      <div className="detail-grid wide-main">
        <div className="stack">
          {job.description && (
            <Card pad>
              <div className="section-label" style={{ padding: '0 0 8px' }}>
                Scope
              </div>
              <div className="muted">{job.description}</div>
            </Card>
          )}

          {snapshotLines.length > 0 && (
            <Card>
              <div className="section-label">Line items (as sent)</div>
              <div className="list">
                {snapshotLines.map((li, i) => (
                  <div key={i} className="row">
                    <div className="grow">
                      <div className="title">{li.label}</div>
                    </div>
                    <span className="amt">{formatMoney(li.amount || 0)}</span>
                  </div>
                ))}
                <div className="row">
                  <div className="grow">
                    <div className="title">Total</div>
                  </div>
                  <span className="amt">
                    {formatMoney(approval?.snapshot?.total ?? job.estimateTotal)}
                  </span>
                </div>
              </div>
            </Card>
          )}

          {changeOrders.length > 0 && (
            <Card>
              <div className="section-label">Change orders</div>
              <div className="list">
                {changeOrders.map((co) => {
                  const st = changeOrderStatus(co);
                  const color =
                    st === 'approved'
                      ? 'green'
                      : st === 'declined'
                        ? 'red'
                        : 'amber';
                  return (
                    <div key={co.id} className="row">
                      <div className="grow">
                        <div className="title">{co.title}</div>
                        <div className="meta">
                          {formatDisplayDate(co.createdAt)}
                        </div>
                      </div>
                      <Badge color={color}>{st}</Badge>
                      <span className="amt">{formatMoney(co.amount || 0)}</span>
                    </div>
                  );
                })}
              </div>
            </Card>
          )}
        </div>

        <div className="stack">
          <Card pad>
            <div className="section-label" style={{ padding: '0 0 8px' }}>
              Totals
            </div>
            <KV k="Estimate" v={formatMoney(job.estimateTotal || 0)} />
            {coTotal !== 0 && (
              <KV k="Approved change orders" v={formatMoney(coTotal)} />
            )}
            <KV k="Billable total" v={formatMoney(billable)} />
            <KV k="Labor hours" v={String(job.laborHours ?? 0)} />
          </Card>

          {approval && (
            <Card pad>
              <div className="section-label" style={{ padding: '0 0 8px' }}>
                Approval
              </div>
              <KV
                k="Status"
                v={
                  approval.decision
                    ? approval.decision === 'approved'
                      ? 'Approved'
                      : 'Declined'
                    : 'Awaiting response'
                }
              />
              {approval.sentAt && (
                <KV k="Sent" v={formatDisplayDate(approval.sentAt)} />
              )}
              {approval.consentAt && (
                <KV k="Responded" v={formatDisplayDate(approval.consentAt)} />
              )}
              {approval.signerName && <KV k="Signed by" v={approval.signerName} />}
              {approval.declineReason && (
                <KV k="Reason" v={approval.declineReason} />
              )}
            </Card>
          )}

          <Card pad>
            <div className="section-label" style={{ padding: '0 0 8px' }}>
              Job
            </div>
            <Link to={`/jobs/${job.id}`} className="title">
              Open full job ›
            </Link>
            {customer && (
              <div className="meta" style={{ marginTop: 6 }}>
                <Link to={`/customers/${customer.id}`}>{customer.name}</Link>
              </div>
            )}
          </Card>
        </div>
      </div>
    </>
  );
}
