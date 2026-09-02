import { useMemo, useState } from 'react';
import { useData, useResources } from '../lib/DataContext';
import { Card, PageHead, Empty, Stat, ErrorState } from '../ui/components';
import { formatMoney } from '@shared/utils/format';
import { summarizeInvoices } from '../ui/invoiceMath';
import { effectivePayments } from '@shared/utils/invoicePayments';
import { formatDisplayDate, getTodayDateString } from '@shared/utils/dateHelpers';
import { EXPENSE_CATEGORIES, stampExpense } from '@shared/utils/moneyUtils';
import type {
  Invoice,
  Expense,
  ExpenseCategoryId,
} from '@shared/types/models';
import { saveExpense, deleteExpense } from '../lib/writeRepository';

function errorMessage(err: unknown): string {
  return err instanceof Error ? err.message : 'Something went wrong';
}

const CATEGORY_LABEL: Record<string, string> = Object.fromEntries(
  EXPENSE_CATEGORIES.map((c) => [c.id, c.label]),
);

function monthKey(dateStr: string): string {
  // Dates are stored as "YYYY-MM-DD"; take the leading "YYYY-MM".
  return (dateStr || '').slice(0, 7);
}

function last6Months(now = new Date()): string[] {
  const keys: string[] = [];
  for (let i = 5; i >= 0; i--) {
    const d = new Date(now.getFullYear(), now.getMonth() - i, 1);
    keys.push(
      `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}`,
    );
  }
  return keys;
}

function monthLabel(key: string): string {
  const [y, m] = key.split('-').map(Number);
  return new Date(y, m - 1, 1).toLocaleString('en-US', { month: 'short' });
}

function revenueByMonth(invoices: Invoice[]): Map<string, number> {
  const map = new Map<string, number>();
  for (const inv of invoices) {
    for (const p of effectivePayments(inv)) {
      if (p.voidedAt) continue;
      const key = monthKey(p.date);
      if (!key) continue;
      map.set(key, (map.get(key) ?? 0) + (Number(p.amount) || 0));
    }
  }
  return map;
}

function expensesByMonth(expenses: Expense[]): Map<string, number> {
  const map = new Map<string, number>();
  for (const e of expenses) {
    const key = monthKey(e.date || e.createdAt);
    if (!key) continue;
    map.set(key, (map.get(key) ?? 0) + (Number(e.amount) || 0));
  }
  return map;
}

/**
 * Add, edit, and delete expenses (roadmap P3 stage 4). A plain last-write-wins
 * blob; new records are stamped with the shared `stampExpense` so the id format
 * matches the mobile app. Edits spread onto the existing record so fields the
 * form doesn't show (receiptUri, jobId, importBatchId, createdAt) round-trip.
 */
function ExpensesSection({ expenses }: { expenses: Expense[] }) {
  const { retry } = useData();
  // null = list view; 'add' = new; otherwise the id of the expense being edited.
  const [mode, setMode] = useState<null | 'add' | string>(null);
  const [description, setDescription] = useState('');
  const [amount, setAmount] = useState('');
  const [category, setCategory] = useState<ExpenseCategoryId>('other');
  const [date, setDate] = useState(getTodayDateString());
  const [notes, setNotes] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [confirmDeleteId, setConfirmDeleteId] = useState<string | null>(null);

  const sorted = useMemo(
    () =>
      [...expenses].sort((a, b) =>
        (b.date || b.createdAt || '').localeCompare(a.date || a.createdAt || ''),
      ),
    [expenses],
  );

  function startAdd() {
    setDescription('');
    setAmount('');
    setCategory('other');
    setDate(getTodayDateString());
    setNotes('');
    setError(null);
    setMode('add');
  }

  function startEdit(e: Expense) {
    setDescription(e.description ?? '');
    setAmount(String(e.amount ?? ''));
    setCategory(e.category ?? 'other');
    setDate(e.date ?? getTodayDateString());
    setNotes(e.notes ?? '');
    setError(null);
    setMode(e.id);
  }

  async function onSubmit(ev: React.FormEvent) {
    ev.preventDefault();
    if (busy) return;
    const parsed = parseFloat(amount);
    if (!description.trim()) {
      setError('Enter a description.');
      return;
    }
    if (!(parsed > 0)) {
      setError('Enter an amount greater than zero.');
      return;
    }
    setBusy(true);
    setError(null);
    try {
      if (mode === 'add') {
        await saveExpense(
          stampExpense({
            description: description.trim(),
            amount: parsed,
            category,
            date,
            notes: notes.trim(),
            receiptUri: null,
          }),
        );
      } else {
        const existing = expenses.find((e) => e.id === mode);
        if (!existing) throw new Error('Expense no longer exists');
        await saveExpense(
          {
            ...existing,
            description: description.trim(),
            amount: parsed,
            category,
            date,
            notes: notes.trim(),
          },
          existing,
        );
      }
      retry(['expenses']);
      setMode(null);
    } catch (err) {
      setError(errorMessage(err));
    } finally {
      setBusy(false);
    }
  }

  async function onDelete(id: string) {
    if (busy) return;
    setBusy(true);
    setError(null);
    try {
      await deleteExpense(id);
      retry(['expenses']);
      setConfirmDeleteId(null);
    } catch (err) {
      setError(errorMessage(err));
    } finally {
      setBusy(false);
    }
  }

  const editing = mode !== null;

  return (
    <Card style={{ marginTop: 16 }}>
      <div
        className="btn-row"
        style={{ justifyContent: 'space-between', padding: '16px 20px 4px' }}
      >
        <div className="section-label" style={{ padding: 0 }}>
          Expenses
        </div>
        {!editing && (
          <button type="button" className="btn sm" onClick={startAdd}>
            Add expense
          </button>
        )}
      </div>

      {error && !editing && (
        <div className="inline-alert error" role="alert" style={{ margin: '0 20px 8px' }}>
          {error}
        </div>
      )}

      {editing && (
        <form className="pay-form" style={{ margin: '4px 20px 12px', paddingTop: 0, borderTop: 0 }} onSubmit={onSubmit}>
          {error && (
            <div className="inline-alert error" role="alert">
              {error}
            </div>
          )}
          <label className="field">
            <span>Description</span>
            <input className="field-input" type="text" value={description} onChange={(e) => setDescription(e.target.value)} autoFocus />
          </label>
          <div className="btn-row">
            <label className="field" style={{ flex: 1 }}>
              <span>Amount</span>
              <input className="field-input" type="number" step="0.01" min="0" inputMode="decimal" value={amount} onChange={(e) => setAmount(e.target.value)} />
            </label>
            <label className="field" style={{ flex: 1 }}>
              <span>Date</span>
              <input className="field-input" type="date" value={date} onChange={(e) => setDate(e.target.value)} />
            </label>
          </div>
          <label className="field">
            <span>Category</span>
            <select className="field-input" value={category} onChange={(e) => setCategory(e.target.value as ExpenseCategoryId)}>
              {EXPENSE_CATEGORIES.map((c) => (
                <option key={c.id} value={c.id}>
                  {c.label}
                </option>
              ))}
            </select>
          </label>
          <label className="field">
            <span>Notes (optional)</span>
            <input className="field-input" type="text" value={notes} onChange={(e) => setNotes(e.target.value)} />
          </label>
          <div className="btn-row">
            <button type="submit" className="btn primary" disabled={busy}>
              {busy ? 'Saving…' : mode === 'add' ? 'Add expense' : 'Save changes'}
            </button>
            <button type="button" className="btn ghost" onClick={() => setMode(null)} disabled={busy}>
              Cancel
            </button>
          </div>
        </form>
      )}

      {!editing &&
        (sorted.length === 0 ? (
          <Empty>No expenses recorded.</Empty>
        ) : (
          <div className="list">
            {sorted.map((e) => (
              <div key={e.id} className="row">
                <div className="grow">
                  <div className="title">{e.description || 'Expense'}</div>
                  <div className="meta">
                    {CATEGORY_LABEL[e.category] ?? e.category}
                    {e.date ? ` · ${formatDisplayDate(e.date)}` : ''}
                  </div>
                </div>
                <span className="amt">{formatMoney(e.amount || 0)}</span>
                {confirmDeleteId === e.id ? (
                  <div className="btn-row">
                    <button type="button" className="btn danger sm" onClick={() => onDelete(e.id)} disabled={busy}>
                      Delete
                    </button>
                    <button type="button" className="btn ghost sm" onClick={() => setConfirmDeleteId(null)} disabled={busy}>
                      Cancel
                    </button>
                  </div>
                ) : (
                  <div className="btn-row">
                    <button type="button" className="btn ghost sm" onClick={() => startEdit(e)}>
                      Edit
                    </button>
                    <button type="button" className="btn ghost sm danger-text" onClick={() => setConfirmDeleteId(e.id)}>
                      Delete
                    </button>
                  </div>
                )}
              </div>
            ))}
          </div>
        ))}
    </Card>
  );
}

export default function MoneyScreen() {
  const { invoices, expenses } = useData();
  const state = useResources('invoices', 'expenses');

  const summary = useMemo(() => summarizeInvoices(invoices), [invoices]);
  const months = useMemo(() => last6Months(), []);
  const revMap = useMemo(() => revenueByMonth(invoices), [invoices]);
  const expMap = useMemo(() => expensesByMonth(expenses), [expenses]);

  const thisMonth = months[months.length - 1];
  const revThisMonth = revMap.get(thisMonth) ?? 0;
  const expThisMonth = expMap.get(thisMonth) ?? 0;

  const maxRev = Math.max(1, ...months.map((m) => revMap.get(m) ?? 0));

  if (state.loading) return <Empty>Loading finances…</Empty>;
  if (state.error)
    return (
      <ErrorState
        message={`Couldn’t load finances: ${state.error}`}
        onRetry={state.retry}
      />
    );

  return (
    <>
      <PageHead title="Money" sub="Last 6 months" />

      <div className="grid grid-4" style={{ marginBottom: 16 }}>
        <Stat
          label="Collected (mo)"
          value={formatMoney(revThisMonth)}
          tone="pos"
          icon="cash"
        />
        <Stat
          label="Expenses (mo)"
          value={formatMoney(expThisMonth)}
          tone={expThisMonth > 0 ? 'neg' : undefined}
          icon="receipt"
        />
        <Stat
          label="Net (mo)"
          value={formatMoney(revThisMonth - expThisMonth)}
          tone={revThisMonth - expThisMonth >= 0 ? 'pos' : 'neg'}
          icon="cash"
        />
        <Stat
          label="Outstanding"
          value={formatMoney(summary.outstanding)}
          tone={summary.outstanding > 0 ? 'neg' : undefined}
          hint={`${summary.overdueCount} overdue`}
          icon="document-text"
        />
      </div>

      <Card pad>
        <div className="section-label" style={{ padding: '0 0 4px' }}>
          Revenue collected
        </div>
        <div className="bars">
          {months.map((m) => {
            const val = revMap.get(m) ?? 0;
            const h = Math.round((val / maxRev) * 100);
            return (
              <div key={m} className="bar-col">
                <div className="bar-val">{val ? formatMoney(val) : ''}</div>
                <div
                  className="bar"
                  style={{ height: `${Math.max(val ? 4 : 0, h)}%` }}
                />
                <div className="bar-label">{monthLabel(m)}</div>
              </div>
            );
          })}
        </div>
      </Card>

      <Card style={{ marginTop: 16 }}>
        <div className="section-label">Monthly breakdown</div>
        <div className="list">
          {[...months].reverse().map((m) => {
            const rev = revMap.get(m) ?? 0;
            const exp = expMap.get(m) ?? 0;
            return (
              <div key={m} className="row">
                <div className="grow">
                  <div className="title">{monthLabel(m)}</div>
                  <div className="meta">
                    Collected {formatMoney(rev)} · Expenses {formatMoney(exp)}
                  </div>
                </div>
                <span
                  className="amt"
                  style={{ color: rev - exp >= 0 ? 'var(--green)' : 'var(--red)' }}
                >
                  {formatMoney(rev - exp)}
                </span>
              </div>
            );
          })}
        </div>
      </Card>

      <ExpensesSection expenses={expenses} />
    </>
  );
}
