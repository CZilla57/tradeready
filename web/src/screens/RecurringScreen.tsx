import { useData, useResources } from '../lib/DataContext';
import { Card, PageHead, Empty, Badge, ErrorState } from '../ui/components';
import { formatMoney } from '@shared/utils/format';
import { formatDisplayDate } from '@shared/utils/dateHelpers';
import type { RecurrenceCadence } from '@shared/types/models';

const CADENCE_LABEL: Record<RecurrenceCadence, string> = {
  daily: 'Daily',
  weekly: 'Weekly',
  monthly: 'Monthly',
  quarterly: 'Quarterly',
  annually: 'Annually',
};

function cadence(c: RecurrenceCadence): string {
  return CADENCE_LABEL[c] ?? c;
}

export default function RecurringScreen() {
  const { recurringJobs, recurringInvoices } = useData();
  const state = useResources('recurringJobs', 'recurringInvoices');

  if (state.loading) return <Empty>Loading recurring work…</Empty>;
  if (state.error)
    return (
      <ErrorState
        message={`Couldn’t load recurring work: ${state.error}`}
        onRetry={state.retry}
      />
    );

  const jobs = [...recurringJobs].sort((a, b) =>
    (a.nextDueDate || '').localeCompare(b.nextDueDate || ''),
  );
  const plans = [...recurringInvoices].sort((a, b) =>
    (a.nextDueDate || '').localeCompare(b.nextDueDate || ''),
  );

  return (
    <>
      <PageHead
        title="Recurring"
        sub="Repeating jobs and maintenance plans"
      />

      <Card>
        <div className="section-label">Recurring jobs ({jobs.length})</div>
        {jobs.length === 0 ? (
          <Empty>No recurring jobs.</Empty>
        ) : (
          <div className="list">
            {jobs.map((r) => (
              <div key={r.id} className="row">
                <div className="grow">
                  <div className="title">
                    {r.title || r.customerName || 'Recurring job'}
                  </div>
                  <div className="meta">
                    {cadence(r.cadence)}
                    {r.customerName ? ` · ${r.customerName}` : ''}
                    {r.nextDueDate
                      ? ` · next ${formatDisplayDate(r.nextDueDate)}`
                      : ''}
                  </div>
                </div>
                <Badge color={r.isActive ? 'green' : 'slate'}>
                  {r.isActive ? 'Active' : 'Paused'}
                </Badge>
                <span className="amt">{formatMoney(r.estimateTotal || 0)}</span>
              </div>
            ))}
          </div>
        )}
      </Card>

      <Card style={{ marginTop: 16 }}>
        <div className="section-label">
          Maintenance plans ({plans.length})
        </div>
        {plans.length === 0 ? (
          <Empty>No maintenance plans.</Empty>
        ) : (
          <div className="list">
            {plans.map((r) => (
              <div key={r.id} className="row">
                <div className="grow">
                  <div className="title">
                    {r.customerName || 'Maintenance plan'}
                  </div>
                  <div className="meta">
                    {cadence(r.cadence)} · net {r.dueDays}d
                    {r.nextDueDate
                      ? ` · next ${formatDisplayDate(r.nextDueDate)}`
                      : ''}
                    {r.autoSendEnabled ? ' · auto-send' : ''}
                  </div>
                </div>
                <Badge color={r.isActive ? 'green' : 'slate'}>
                  {r.isActive ? 'Active' : 'Paused'}
                </Badge>
                <span className="amt">{formatMoney(r.amount || 0)}</span>
              </div>
            ))}
          </div>
        )}
      </Card>
    </>
  );
}
