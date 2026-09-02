import { Link } from 'react-router-dom';
import { useData, useResources } from '../lib/DataContext';
import { Card, PageHead, Stat, Empty, Badge, ErrorState } from '../ui/components';
import { jobStatusBadge } from '../ui/status';
import { formatMoney } from '@shared/utils/format';
import { balanceDue, isFullyPaid } from '@shared/utils/invoicePayments';
import {
  getTodayDateString,
  getGreeting,
  formatTimeRange,
  formatDisplayDate,
} from '@shared/utils/dateHelpers';
import type { Job } from '@shared/types/models';
import { Icon } from '../ui/Icon';

function timeKey(j: Job): string {
  return j.scheduledStartTime ?? '99:99';
}

export default function TodayScreen() {
  const { jobs, invoices, settings } = useData();
  // Today needs jobs + invoices; settings only supplies a greeting name, so a
  // settings failure must not blank the day.
  const state = useResources('jobs', 'invoices');
  const today = getTodayDateString();

  if (state.loading) return <Empty>Loading your day…</Empty>;
  if (state.error)
    return (
      <ErrorState
        message={`Couldn’t load your day: ${state.error}`}
        onRetry={state.retry}
      />
    );

  const todaysJobs = jobs
    .filter((j) => j.scheduledDate === today && !j.archivedAt)
    .sort((a, b) => timeKey(a).localeCompare(timeKey(b)));

  const expectedEarnings = todaysJobs.reduce(
    (sum, j) => sum + (Number(j.estimateTotal) || 0),
    0,
  );

  // Mirror the Invoices/Money screens' roll-up (see ui/invoiceMath.ts): an
  // invoice is "open" when it still has a remaining balance, and Outstanding
  // sums that remaining balance — so partial payments and the payment-derived
  // paid status are respected, rather than the raw `paid` flag and full amount.
  const openInvoices = invoices.filter((i) => !isFullyPaid(i));
  const outstanding = openInvoices.reduce((sum, i) => sum + balanceDue(i), 0);

  const name = settings?.contactName?.trim() || settings?.businessName?.trim();

  return (
    <>
      <PageHead
        title={`${getGreeting()}${name ? `, ${name.split(' ')[0]}` : ''}`}
        sub={formatDisplayDate(today)}
        right={
          <Link className="btn primary" to="/calendar">
            Plan the day
          </Link>
        }
      />

      <div className="grid grid-3 stats-grid">
        <Stat
          label="Jobs today"
          value={String(todaysJobs.length)}
          hint={todaysJobs.length === 1 ? '1 scheduled' : 'scheduled'}
          icon="hammer"
        />
        <Stat
          label="Expected today"
          value={formatMoney(expectedEarnings)}
          hint="from scheduled jobs"
          icon="cash"
        />
        <Stat
          label="Outstanding"
          value={formatMoney(outstanding)}
          tone={outstanding > 0 ? 'neg' : undefined}
          hint={`${openInvoices.length} open invoice${openInvoices.length === 1 ? '' : 's'}`}
          icon="receipt"
        />
      </div>

      <Card>
        <div className="section-head">
          <div>
            <div className="section-kicker">Your workday</div>
            <h2>Today’s schedule</h2>
          </div>
          <Link className="section-action" to="/calendar">
            Open calendar
          </Link>
        </div>
        {todaysJobs.length === 0 ? (
          <div className="today-empty">
            <span className="today-empty-icon" aria-hidden="true">
              <Icon name="calendar" size={28} />
            </span>
            <div>
              <h3>Your day is wide open</h3>
              <p>Schedule a job or review upcoming work while you have room.</p>
            </div>
            <div className="today-empty-actions">
              <Link className="btn primary" to="/calendar">Open calendar</Link>
              <Link className="btn" to="/jobs">View jobs</Link>
            </div>
          </div>
        ) : (
          <div className="list">
            {todaysJobs.map((j) => {
              const badge = jobStatusBadge(j.status);
              return (
                <Link key={j.id} to={`/jobs/${j.id}`} className="row">
                  <div className="grow">
                    <div className="title">
                      {j.title || j.customerName || 'Job'}
                    </div>
                    <div className="meta">
                      {formatTimeRange(
                        j.scheduledStartTime,
                        j.scheduledEndTime,
                      ) || 'Unscheduled time'}
                      {j.customerName ? ` · ${j.customerName}` : ''}
                    </div>
                  </div>
                  <Badge color={badge.color}>{badge.label}</Badge>
                  <span className="amt">{formatMoney(j.estimateTotal || 0)}</span>
                  <span className="chev">›</span>
                </Link>
              );
            })}
          </div>
        )}
      </Card>

      <div className="quick-actions" aria-label="Quick links">
        <Link to="/jobs">
          <span className="quick-action-icon" aria-hidden="true"><Icon name="hammer" size={20} /></span>
          <span className="quick-action-copy"><small>Jobs</small><strong>Keep work moving</strong></span>
          <b aria-hidden="true">›</b>
        </Link>
        <Link to="/invoices">
          <span className="quick-action-icon" aria-hidden="true"><Icon name="receipt" size={20} /></span>
          <span className="quick-action-copy"><small>Invoices</small><strong>Follow up & get paid</strong></span>
          <b aria-hidden="true">›</b>
        </Link>
        <Link to="/customers">
          <span className="quick-action-icon" aria-hidden="true"><Icon name="people" size={20} /></span>
          <span className="quick-action-copy"><small>Customers</small><strong>Open customer records</strong></span>
          <b aria-hidden="true">›</b>
        </Link>
      </div>
    </>
  );
}
