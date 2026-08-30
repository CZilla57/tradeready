import { Link } from 'react-router-dom';
import { useData } from '../lib/DataContext';
import { Card, PageHead, Stat, Empty, Badge } from '../ui/components';
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

function timeKey(j: Job): string {
  return j.scheduledStartTime ?? '99:99';
}

export default function TodayScreen() {
  const { jobs, invoices, settings, loading, error } = useData();
  const today = getTodayDateString();

  if (loading) return <Empty>Loading your day…</Empty>;
  if (error) return <Empty>Couldn’t load data: {error}</Empty>;

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
      />

      <div className="grid grid-3" style={{ marginBottom: 16 }}>
        <Stat
          label="Jobs today"
          value={String(todaysJobs.length)}
          hint={todaysJobs.length === 1 ? '1 scheduled' : 'scheduled'}
        />
        <Stat
          label="Expected today"
          value={formatMoney(expectedEarnings)}
          hint="from scheduled jobs"
        />
        <Stat
          label="Outstanding"
          value={formatMoney(outstanding)}
          tone={outstanding > 0 ? 'neg' : undefined}
          hint={`${openInvoices.length} open invoice${openInvoices.length === 1 ? '' : 's'}`}
        />
      </div>

      <Card>
        <div className="section-label">Today’s schedule</div>
        {todaysJobs.length === 0 ? (
          <Empty>Nothing scheduled for today.</Empty>
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
    </>
  );
}
