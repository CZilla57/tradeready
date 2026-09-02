import { useMemo, useState } from 'react';
import { Link, useNavigate } from 'react-router-dom';
import { useData, useResources } from '../lib/DataContext';
import { Card, PageHead, Empty, Badge, Stat, ErrorState } from '../ui/components';
import { invoiceStatusBadge } from '../ui/status';
import { formatMoney } from '@shared/utils/format';
import { formatDisplayDate, getTodayDateString } from '@shared/utils/dateHelpers';
import { nextInvoiceNumber } from '@shared/utils/invoiceNumber';
import { summarizeInvoices, isOverdue } from '../ui/invoiceMath';
import { isFullyPaid } from '@shared/utils/invoicePayments';
import type { Customer, Invoice, Settings } from '@shared/types/models';
import { createInvoice } from '../lib/writeRepository';

function errorMessage(err: unknown): string {
  return err instanceof Error ? err.message : 'Something went wrong';
}

/**
 * The "New invoice" form (roadmap P3 stage 5c — creation flows). Creates a
 * standalone MANUAL invoice via `createInvoice` and navigates to it on success.
 * A customer is picked from existing records (setting both the denormalized name
 * and the id link; inline customer creation stays on the Customers screen). The
 * number defaults to the shared `nextInvoiceNumber` (Settings prefix/start),
 * overridable. Line items are not authored here (an estimate-snapshot concern).
 * Validation mirrors the InvoiceEditor: amount > 0, a due date, a number.
 * Follows the InvoiceDetailScreen UX: in-flight disable, a failed write stays
 * open with the error.
 */
function NewInvoiceForm({
  customers,
  invoices,
  settings,
  onClose,
}: {
  customers: Customer[];
  invoices: Invoice[];
  settings: Settings | null;
  onClose: () => void;
}) {
  const navigate = useNavigate();
  const pickable = customers
    .filter((c) => !c.archivedAt)
    .sort((a, b) => (a.name || '').localeCompare(b.name || ''));
  const [customerId, setCustomerId] = useState('');
  const [number, setNumber] = useState(() =>
    nextInvoiceNumber(invoices, settings ?? undefined),
  );
  const [amount, setAmount] = useState('');
  const [due, setDue] = useState(getTodayDateString());
  const [email, setEmail] = useState('');
  const [phone, setPhone] = useState('');
  const [desc, setDesc] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  // Pick a customer → adopt its name + contact snapshot (mobile denormalizes the
  // contact at creation); the fields stay editable.
  function onPickCustomer(id: string) {
    setCustomerId(id);
    const c = pickable.find((x) => x.id === id);
    if (c) {
      if (!email) setEmail(c.email ?? '');
      if (!phone) setPhone(c.phone ?? '');
    }
  }

  async function onSave(e: React.FormEvent) {
    e.preventDefault();
    if (busy) return;
    const customer = pickable.find((c) => c.id === customerId);
    if (!customer) {
      setError('Choose a customer.');
      return;
    }
    const parsed = parseFloat(amount);
    if (!(parsed > 0)) {
      setError('Enter an invoice amount greater than zero.');
      return;
    }
    if (!/^\d{4}-\d{2}-\d{2}$/.test(due)) {
      setError('Enter a due date.');
      return;
    }
    if (!number.trim()) {
      setError('Enter an invoice number.');
      return;
    }
    setBusy(true);
    setError(null);
    try {
      const created = await createInvoice({
        customer: customer.name,
        customerId: customer.id,
        number: number.trim(),
        amount: parsed,
        due,
        email: email.trim(),
        phone: phone.trim(),
        desc: desc.trim(),
      });
      navigate(`/invoices/${created.id}`);
    } catch (err) {
      setError(errorMessage(err));
      setBusy(false);
    }
  }

  return (
    <Card pad>
      <div className="section-label" style={{ padding: '0 0 10px' }}>
        New invoice
      </div>
      {error && (
        <div className="inline-alert error" role="alert">
          {error}
        </div>
      )}
      {pickable.length === 0 ? (
        <div className="muted" style={{ fontSize: 13 }}>
          Add a customer first — an invoice bills an existing customer.
          <div className="btn-row" style={{ marginTop: 10 }}>
            <button type="button" className="btn ghost sm" onClick={onClose}>
              Close
            </button>
          </div>
        </div>
      ) : (
        <form className="pay-form" style={{ marginTop: 0, borderTop: 0, paddingTop: 0 }} onSubmit={onSave}>
          <label className="field">
            <span>Customer</span>
            <select className="field-input" value={customerId} onChange={(e) => onPickCustomer(e.target.value)}>
              <option value="">Select a customer…</option>
              {pickable.map((c) => (
                <option key={c.id} value={c.id}>
                  {c.name || 'Unnamed'}
                </option>
              ))}
            </select>
          </label>
          <div className="btn-row">
            <label className="field" style={{ flex: 1 }}>
              <span>Number</span>
              <input className="field-input" type="text" value={number} onChange={(e) => setNumber(e.target.value)} />
            </label>
            <label className="field" style={{ flex: 1 }}>
              <span>Amount ($)</span>
              <input className="field-input" type="number" step="0.01" min="0" inputMode="decimal" value={amount} onChange={(e) => setAmount(e.target.value)} />
            </label>
          </div>
          <label className="field">
            <span>Due date</span>
            <input className="field-input" type="date" value={due} onChange={(e) => setDue(e.target.value)} />
          </label>
          <div className="btn-row">
            <label className="field" style={{ flex: 1 }}>
              <span>Email</span>
              <input className="field-input" type="email" value={email} onChange={(e) => setEmail(e.target.value)} />
            </label>
            <label className="field" style={{ flex: 1 }}>
              <span>Phone</span>
              <input className="field-input" type="tel" value={phone} onChange={(e) => setPhone(e.target.value)} />
            </label>
          </div>
          <label className="field">
            <span>Description of work</span>
            <input className="field-input" type="text" value={desc} onChange={(e) => setDesc(e.target.value)} />
          </label>
          <div className="btn-row">
            <button type="submit" className="btn primary" disabled={busy}>
              {busy ? 'Creating…' : 'Create invoice'}
            </button>
            <button type="button" className="btn ghost" onClick={onClose} disabled={busy}>
              Cancel
            </button>
          </div>
        </form>
      )}
    </Card>
  );
}

type Filter = 'open' | 'overdue' | 'paid' | 'all';

function matches(inv: Invoice, filter: Filter): boolean {
  switch (filter) {
    case 'open':
      return !isFullyPaid(inv);
    case 'overdue':
      return isOverdue(inv);
    case 'paid':
      return isFullyPaid(inv);
    default:
      return true;
  }
}

const FILTERS: { key: Filter; label: string }[] = [
  { key: 'open', label: 'Open' },
  { key: 'overdue', label: 'Overdue' },
  { key: 'paid', label: 'Paid' },
  { key: 'all', label: 'All' },
];

export default function InvoicesScreen() {
  const { invoices, customers, settings } = useData();
  const state = useResources('invoices');
  const [filter, setFilter] = useState<Filter>('open');
  const [q, setQ] = useState('');
  const [creating, setCreating] = useState(false);

  const active = invoices;
  const summary = useMemo(() => summarizeInvoices(active), [active]);

  const rows = useMemo(() => {
    const term = q.trim().toLowerCase();
    return active
      .filter((i) => matches(i, filter))
      .filter(
        (i) =>
          !term ||
          i.customer?.toLowerCase().includes(term) ||
          i.number?.toLowerCase().includes(term),
      )
      .sort((a, b) => (b.due || '').localeCompare(a.due || ''));
  }, [active, filter, q]);

  if (state.loading) return <Empty>Loading invoices…</Empty>;
  if (state.error)
    return (
      <ErrorState
        message={`Couldn’t load invoices: ${state.error}`}
        onRetry={state.retry}
      />
    );

  return (
    <>
      <PageHead
        title="Invoices"
        right={
          !creating && (
            <button type="button" className="btn sm" onClick={() => setCreating(true)}>
              New invoice
            </button>
          )
        }
      />

      {creating && (
        <NewInvoiceForm
          customers={customers}
          invoices={invoices}
          settings={settings}
          onClose={() => setCreating(false)}
        />
      )}

      <div className="grid grid-3" style={{ marginBottom: 16 }}>
        <Stat
          label="Outstanding"
          value={formatMoney(summary.outstanding)}
          tone={summary.outstanding > 0 ? 'neg' : undefined}
          icon="document-text"
        />
        <Stat label="Collected" value={formatMoney(summary.collected)} tone="pos" icon="cash" />
        <Stat label="Overdue" value={String(summary.overdueCount)} icon="receipt" />
      </div>

      <input
        className="search"
        placeholder="Search by customer or invoice number…"
        value={q}
        onChange={(e) => setQ(e.target.value)}
      />
      <div className="pills">
        {FILTERS.map((f) => (
          <button
            key={f.key}
            className={`pill ${filter === f.key ? 'active' : ''}`.trim()}
            onClick={() => setFilter(f.key)}
          >
            {f.label}
          </button>
        ))}
      </div>

      <Card>
        {rows.length === 0 ? (
          <Empty>No invoices match.</Empty>
        ) : (
          <div className="list">
            {rows.map((inv) => {
              const badge = invoiceStatusBadge(inv);
              return (
                <Link key={inv.id} to={`/invoices/${inv.id}`} className="row">
                  <div className="grow">
                    <div className="title">{inv.customer || 'No customer'}</div>
                    <div className="meta">
                      {inv.number ? `#${inv.number} · ` : ''}
                      Due {inv.due ? formatDisplayDate(inv.due) : '—'}
                    </div>
                  </div>
                  <Badge color={badge.color}>{badge.label}</Badge>
                  <span className="amt">{formatMoney(inv.amount || 0)}</span>
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
