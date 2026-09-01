import { useState } from 'react';
import type { ReactNode } from 'react';
import { useData, useResources } from '../lib/DataContext';
import { Card, PageHead, Empty, Badge, ErrorState } from '../ui/components';
import { formatMoney } from '@shared/utils/format';
import { formatDisplayDate, getTodayDateString } from '@shared/utils/dateHelpers';
import type {
  RecurrenceCadence,
  RecurrenceEndCondition,
  RecurringInvoice,
} from '@shared/types/models';
import {
  setRecurringJobActive,
  setRecurringInvoiceActive,
  updateRecurringInvoiceRule,
  deleteRecurringJob,
  deleteRecurringInvoice,
} from '../lib/writeRepository';

const CADENCES: RecurrenceCadence[] = [
  'daily',
  'weekly',
  'monthly',
  'quarterly',
  'annually',
];
const CADENCE_LABEL: Record<RecurrenceCadence, string> = {
  daily: 'Daily',
  weekly: 'Weekly',
  monthly: 'Monthly',
  quarterly: 'Quarterly',
  annually: 'Annually',
};

const END_CONDITIONS: RecurrenceEndCondition[] = ['never', 'count', 'date'];
const END_LABEL: Record<RecurrenceEndCondition, string> = {
  never: 'Never',
  count: 'After N',
  date: 'By date',
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
  renderEditor,
}: {
  title: string;
  meta: string;
  amount: number;
  isActive: boolean;
  deleteLabel: string;
  onToggle: (active: boolean) => Promise<void>;
  onDelete: () => Promise<void>;
  /** When provided, the row shows an Edit button that swaps in this form. */
  renderEditor?: (close: () => void) => ReactNode;
}) {
  const [busy, setBusy] = useState(false);
  const [confirmDelete, setConfirmDelete] = useState(false);
  const [editing, setEditing] = useState(false);
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

  if (editing && renderEditor) {
    return <div className="row" style={{ flexWrap: 'wrap' }}>{renderEditor(() => setEditing(false))}</div>;
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
          {renderEditor && (
            <button type="button" className="btn ghost sm" onClick={() => setEditing(true)} disabled={busy}>
              Edit
            </button>
          )}
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

/**
 * Inline editor for a maintenance-plan rule (roadmap P3 stage 5b). Edits the
 * direct-value rule fields — description, amount, net terms, cadence, end
 * condition, next date, auto-send — through `updateRecurringInvoiceRule`, which
 * preserves the plan's generation history. Validation mirrors the mobile
 * AddRecurringInvoiceScreen (amount > 0, net ≥ 0, a positive end count, an end
 * date when required). Customer re-linking is deliberately not offered here.
 */
function PlanEditor({
  plan,
  onClose,
  onSaved,
}: {
  plan: RecurringInvoice;
  onClose: () => void;
  onSaved: () => void;
}) {
  const [description, setDescription] = useState(plan.description ?? '');
  const [amount, setAmount] = useState(String(plan.amount ?? ''));
  const [dueDays, setDueDays] = useState(String(plan.dueDays ?? 30));
  const [cad, setCad] = useState<RecurrenceCadence>(plan.cadence);
  const [endCondition, setEndCondition] = useState<RecurrenceEndCondition>(plan.endCondition);
  const [endCount, setEndCount] = useState(plan.endCount != null ? String(plan.endCount) : '');
  const [endDate, setEndDate] = useState(plan.endDate ?? '');
  const [nextDueDate, setNextDueDate] = useState(plan.nextDueDate || getTodayDateString());
  const [autoSend, setAutoSend] = useState(!!plan.autoSendEnabled);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function onSave(e: React.FormEvent) {
    e.preventDefault();
    if (busy) return;
    const amt = Number(amount.trim());
    if (!(amt > 0)) {
      setError('Enter an invoice amount greater than zero.');
      return;
    }
    const net = Number(dueDays.trim());
    if (!Number.isInteger(net) || net < 0) {
      setError('Net terms must be zero or a positive whole number of days.');
      return;
    }
    let endCountValue: number | undefined;
    if (endCondition === 'count') {
      endCountValue = Number(endCount.trim());
      if (!Number.isInteger(endCountValue) || endCountValue < 1) {
        setError('Enter a number of invoices greater than zero.');
        return;
      }
    }
    if (endCondition === 'date' && !endDate) {
      setError('Pick an end date for the plan.');
      return;
    }
    if (!nextDueDate) {
      setError('Pick the next invoice date.');
      return;
    }
    setBusy(true);
    setError(null);
    try {
      await updateRecurringInvoiceRule(plan.id, {
        description: description.trim(),
        amount: amt,
        dueDays: net,
        cadence: cad,
        endCondition,
        endCount: endCountValue,
        endDate: endCondition === 'date' ? endDate : undefined,
        nextDueDate,
        autoSendEnabled: autoSend,
      });
      onSaved();
    } catch (err) {
      setError(errorMessage(err));
      setBusy(false);
    }
  }

  return (
    <div className="grow" style={{ minWidth: 240 }}>
      <div className="title">{plan.customerName || 'Maintenance plan'}</div>
      {error && (
        <div className="inline-alert error" role="alert" style={{ marginTop: 6 }}>
          {error}
        </div>
      )}
      <form className="pay-form" style={{ marginTop: 8, borderTop: 0, paddingTop: 0 }} onSubmit={onSave}>
        <label className="field">
          <span>Description</span>
          <input className="field-input" type="text" value={description} onChange={(e) => setDescription(e.target.value)} />
        </label>
        <div className="btn-row">
          <label className="field" style={{ flex: 1 }}>
            <span>Amount ($)</span>
            <input className="field-input" type="number" step="0.01" min="0" inputMode="decimal" value={amount} onChange={(e) => setAmount(e.target.value)} />
          </label>
          <label className="field" style={{ flex: 1 }}>
            <span>Net (days)</span>
            <input className="field-input" type="number" step="1" min="0" inputMode="numeric" value={dueDays} onChange={(e) => setDueDays(e.target.value)} />
          </label>
        </div>
        <div className="field">
          <span>Repeats</span>
          <div className="chip-row" role="group" aria-label="Repeats">
            {CADENCES.map((c) => (
              <button
                key={c}
                type="button"
                className={`chip${cad === c ? ' selected' : ''}`}
                aria-pressed={cad === c}
                onClick={() => setCad(c)}
              >
                {CADENCE_LABEL[c]}
              </button>
            ))}
          </div>
        </div>
        <label className="field">
          <span>Next invoice date</span>
          <input className="field-input" type="date" value={nextDueDate} onChange={(e) => setNextDueDate(e.target.value)} />
        </label>
        <div className="field">
          <span>Ends</span>
          <div className="chip-row" role="group" aria-label="Ends">
            {END_CONDITIONS.map((ec) => (
              <button
                key={ec}
                type="button"
                className={`chip${endCondition === ec ? ' selected' : ''}`}
                aria-pressed={endCondition === ec}
                onClick={() => setEndCondition(ec)}
              >
                {END_LABEL[ec]}
              </button>
            ))}
          </div>
        </div>
        {endCondition === 'count' && (
          <label className="field">
            <span>Number of invoices</span>
            <input className="field-input" type="number" step="1" min="1" inputMode="numeric" value={endCount} onChange={(e) => setEndCount(e.target.value)} />
          </label>
        )}
        {endCondition === 'date' && (
          <label className="field">
            <span>End date</span>
            <input className="field-input" type="date" value={endDate} onChange={(e) => setEndDate(e.target.value)} />
          </label>
        )}
        <label className="field checkbox-field">
          <input type="checkbox" checked={autoSend} onChange={(e) => setAutoSend(e.target.checked)} />
          <span>Auto-send each invoice by email</span>
        </label>
        <div className="btn-row">
          <button type="submit" className="btn primary sm" disabled={busy}>
            {busy ? 'Saving…' : 'Save changes'}
          </button>
          <button type="button" className="btn ghost sm" onClick={onClose} disabled={busy}>
            Cancel
          </button>
        </div>
      </form>
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
                renderEditor={(close) => (
                  <PlanEditor
                    plan={r}
                    onClose={close}
                    onSaved={() => {
                      retry(['recurringInvoices']);
                      close();
                    }}
                  />
                )}
              />
            ))}
          </div>
        )}
      </Card>
    </>
  );
}
