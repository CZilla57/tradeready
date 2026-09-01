import { useState } from 'react';
import { useData, useResources } from '../lib/DataContext';
import { Card, PageHead, Empty, Badge, ErrorState } from '../ui/components';
import { formatMoney } from '@shared/utils/format';
import { formatDisplayDate } from '@shared/utils/dateHelpers';
import type { RecurrenceCadence } from '@shared/types/models';
import {
  setRecurringJobActive,
  setRecurringInvoiceActive,
  deleteRecurringJob,
  deleteRecurringInvoice,
} from '../lib/writeRepository';

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

function errorMessage(err: unknown): string {
  return err instanceof Error ? err.message : 'Something went wrong';
}

/**
 * One recurring rule row with its pause/resume + delete controls (roadmap P3
 * stage 5). The write ops (`onToggle`, `onDelete`) re-fetch the server row and
 * preserve advancing generation state; this component only owns the per-row
 * in-flight/confirm/error UX (P2.2): a control disabled while in flight, a
 * failed write that surfaces the error and leaves the row unchanged, and a
 * server re-pull on success (handled by the op's caller via `retry`).
 */
function RecurringRow({
  title,
  meta,
  amount,
  isActive,
  deleteLabel,
  onToggle,
  onDelete,
}: {
  title: string;
  meta: string;
  amount: number;
  isActive: boolean;
  deleteLabel: string;
  onToggle: (active: boolean) => Promise<void>;
  onDelete: () => Promise<void>;
}) {
  const [busy, setBusy] = useState(false);
  const [confirmDelete, setConfirmDelete] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function run(fn: () => Promise<void>) {
    if (busy) return;
    setBusy(true);
    setError(null);
    try {
      await fn();
    } catch (err) {
      setError(errorMessage(err));
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="row" style={{ flexWrap: 'wrap' }}>
      <div className="grow">
        <div className="title">{title}</div>
        <div className="meta">{meta}</div>
        {error && (
          <div className="inline-alert error" role="alert" style={{ marginTop: 6 }}>
            {error}
          </div>
        )}
      </div>
      <Badge color={isActive ? 'green' : 'slate'}>{isActive ? 'Active' : 'Paused'}</Badge>
      <span className="amt">{formatMoney(amount || 0)}</span>
      {confirmDelete ? (
        <div className="btn-row">
          <button type="button" className="btn danger sm" onClick={() => run(onDelete)} disabled={busy}>
            {busy ? 'Deleting…' : deleteLabel}
          </button>
          <button type="button" className="btn ghost sm" onClick={() => setConfirmDelete(false)} disabled={busy}>
            Cancel
          </button>
        </div>
      ) : (
        <div className="btn-row">
          <button
            type="button"
            className="btn sm"
            onClick={() => run(() => onToggle(!isActive))}
            disabled={busy}
          >
            {busy ? 'Saving…' : isActive ? 'Pause' : 'Resume'}
          </button>
          <button
            type="button"
            className="btn ghost sm"
            onClick={() => setConfirmDelete(true)}
            disabled={busy}
          >
            Delete
          </button>
        </div>
      )}
    </div>
  );
}

export default function RecurringScreen() {
  const { recurringJobs, recurringInvoices, retry } = useData();
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
              <RecurringRow
                key={r.id}
                title={r.title || r.customerName || 'Recurring job'}
                meta={
                  cadence(r.cadence) +
                  (r.customerName ? ` · ${r.customerName}` : '') +
                  (r.nextDueDate ? ` · next ${formatDisplayDate(r.nextDueDate)}` : '')
                }
                amount={r.estimateTotal || 0}
                isActive={r.isActive}
                deleteLabel="Delete series"
                onToggle={async (active) => {
                  await setRecurringJobActive(r.id, active);
                  retry(['recurringJobs']);
                }}
                onDelete={async () => {
                  await deleteRecurringJob(r.id);
                  retry(['recurringJobs']);
                }}
              />
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
              <RecurringRow
                key={r.id}
                title={r.customerName || 'Maintenance plan'}
                meta={
                  `${cadence(r.cadence)} · net ${r.dueDays}d` +
                  (r.nextDueDate ? ` · next ${formatDisplayDate(r.nextDueDate)}` : '') +
                  (r.autoSendEnabled ? ' · auto-send' : '')
                }
                amount={r.amount || 0}
                isActive={r.isActive}
                deleteLabel="Delete plan"
                onToggle={async (active) => {
                  await setRecurringInvoiceActive(r.id, active);
                  retry(['recurringInvoices']);
                }}
                onDelete={async () => {
                  await deleteRecurringInvoice(r.id);
                  retry(['recurringInvoices']);
                }}
              />
            ))}
          </div>
        )}
      </Card>
    </>
  );
}
