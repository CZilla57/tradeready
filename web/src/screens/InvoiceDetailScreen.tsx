import { useCallback, useState } from 'react';
import { Link, useNavigate, useParams } from 'react-router-dom';
import { useData, useResources } from '../lib/DataContext';
import { Card, Empty, Badge, KV, ErrorState } from '../ui/components';
import { invoiceStatusBadge } from '../ui/status';
import { formatMoney } from '@shared/utils/format';
import { formatDisplayDate, getTodayDateString } from '@shared/utils/dateHelpers';
import {
  amountPaid,
  balanceDue,
  effectivePayments,
  isFullyPaid,
} from '@shared/utils/invoicePayments';
import type { Invoice, PaymentMethod } from '@shared/types/models';
import {
  recordInvoicePayment,
  markInvoicePaid,
  voidInvoicePayment,
  saveInvoice,
  deleteInvoice,
} from '../lib/writeRepository';

// Manual entry never offers "stripe" — those payments arrive only from the
// Stripe Connect webhook (see utils/sync.ts). A person recording money by hand
// took cash, a check, or a card.
const PAYMENT_METHODS: { value: PaymentMethod; label: string }[] = [
  { value: 'cash', label: 'Cash' },
  { value: 'check', label: 'Check' },
  { value: 'card', label: 'Card' },
  { value: 'other', label: 'Other' },
];

function errorMessage(err: unknown): string {
  return err instanceof Error ? err.message : 'Something went wrong';
}

/**
 * The invoice's write actions (roadmap P0.1 wired to the UI): record a payment,
 * mark the balance paid, void a payment. Every action goes through the typed
 * write module, then re-pulls invoices from the server (the source of truth) so
 * the screen reflects exactly what was persisted — including any Stripe payment
 * the write unioned in.
 */
function PaymentActions({ invoice }: { invoice: Invoice }) {
  const { retry } = useData();
  const refresh = useCallback(() => retry(['invoices']), [retry]);

  const [open, setOpen] = useState(false);
  const [amount, setAmount] = useState('');
  const [date, setDate] = useState(getTodayDateString());
  const [method, setMethod] = useState<PaymentMethod>('cash');
  const [note, setNote] = useState('');
  const [busy, setBusy] = useState<'record' | 'mark' | null>(null);
  const [error, setError] = useState<string | null>(null);

  const settled = isFullyPaid(invoice);

  function resetForm() {
    setAmount('');
    setDate(getTodayDateString());
    setMethod('cash');
    setNote('');
    setError(null);
  }

  async function submitPayment(e: React.FormEvent) {
    e.preventDefault();
    if (busy) return; // double-submit guard
    const parsed = parseFloat(amount);
    if (!(parsed > 0)) {
      setError('Enter a payment amount greater than zero.');
      return;
    }
    setBusy('record');
    setError(null);
    try {
      await recordInvoicePayment(invoice.id, {
        amount: parsed,
        date,
        method,
        ...(note.trim() ? { note: note.trim() } : {}),
      });
      refresh();
      setOpen(false);
      resetForm();
    } catch (err) {
      setError(errorMessage(err));
    } finally {
      setBusy(null);
    }
  }

  async function onMarkPaid() {
    if (busy) return;
    setBusy('mark');
    setError(null);
    try {
      await markInvoicePaid(invoice.id, getTodayDateString());
      refresh();
    } catch (err) {
      setError(errorMessage(err));
    } finally {
      setBusy(null);
    }
  }

  return (
    <Card pad>
      <div className="section-label" style={{ padding: '0 0 10px' }}>
        Record payment
      </div>

      {error && !open && (
        <div className="inline-alert error" role="alert">
          {error}
        </div>
      )}

      {settled ? (
        <div className="muted">This invoice is fully paid.</div>
      ) : (
        <div className="btn-row">
          <button
            type="button"
            className="btn primary"
            onClick={() => {
              setOpen((v) => !v);
              setError(null);
            }}
            aria-expanded={open}
          >
            {open ? 'Cancel' : 'Record a payment'}
          </button>
          <button
            type="button"
            className="btn"
            onClick={onMarkPaid}
            disabled={busy !== null}
          >
            {busy === 'mark'
              ? 'Saving…'
              : `Mark paid (${formatMoney(balanceDue(invoice))})`}
          </button>
        </div>
      )}

      {open && !settled && (
        <form className="pay-form" onSubmit={submitPayment}>
          {error && (
            <div className="inline-alert error" role="alert">
              {error}
            </div>
          )}
          <label className="field">
            <span>Amount</span>
            <input
              className="field-input"
              inputMode="decimal"
              type="number"
              step="0.01"
              min="0"
              placeholder={formatMoney(balanceDue(invoice))}
              value={amount}
              onChange={(e) => setAmount(e.target.value)}
              autoFocus
            />
          </label>
          <label className="field">
            <span>Date received</span>
            <input
              className="field-input"
              type="date"
              value={date}
              onChange={(e) => setDate(e.target.value)}
            />
          </label>
          <label className="field">
            <span>Method</span>
            <select
              className="field-input"
              value={method}
              onChange={(e) => setMethod(e.target.value as PaymentMethod)}
            >
              {PAYMENT_METHODS.map((m) => (
                <option key={m.value} value={m.value}>
                  {m.label}
                </option>
              ))}
            </select>
          </label>
          <label className="field">
            <span>Note (optional)</span>
            <input
              className="field-input"
              type="text"
              value={note}
              onChange={(e) => setNote(e.target.value)}
            />
          </label>
          <button
            type="submit"
            className="btn primary"
            disabled={busy !== null}
          >
            {busy === 'record' ? 'Saving…' : 'Save payment'}
          </button>
        </form>
      )}
    </Card>
  );
}

/**
 * Edit an invoice's own scalar fields and delete it (roadmap P3 stage 1).
 *
 * Scope matches the mobile "Edit Invoice" screen's invoice-LOCAL fields —
 * number, amount, due, description, contact email/phone. It intentionally does
 * NOT edit line items (an immutable snapshot from the job estimate) or the
 * customer name/link (a customer-domain concern, roadmap stage 2). The write
 * goes through `saveInvoice`, which preserves the server payment ledger and
 * re-derives paid/paidAt from the (possibly new) amount — the same reconcile the
 * mobile edit does.
 */
function InvoiceEditor({ invoice }: { invoice: Invoice }) {
  const { retry } = useData();
  const navigate = useNavigate();

  const [open, setOpen] = useState(false);
  const [number, setNumber] = useState(invoice.number ?? '');
  const [amount, setAmount] = useState(String(invoice.amount ?? ''));
  const [due, setDue] = useState(invoice.due ?? '');
  const [desc, setDesc] = useState(invoice.desc ?? '');
  const [email, setEmail] = useState(invoice.email ?? '');
  const [phone, setPhone] = useState(invoice.phone ?? '');
  const [busy, setBusy] = useState<'save' | 'delete' | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [confirmDelete, setConfirmDelete] = useState(false);

  // Reset the form to the invoice's current values whenever it opens, so a
  // cancelled edit followed by a re-open never shows stale input.
  function openEditor() {
    setNumber(invoice.number ?? '');
    setAmount(String(invoice.amount ?? ''));
    setDue(invoice.due ?? '');
    setDesc(invoice.desc ?? '');
    setEmail(invoice.email ?? '');
    setPhone(invoice.phone ?? '');
    setError(null);
    setConfirmDelete(false);
    setOpen(true);
  }

  async function onSave(e: React.FormEvent) {
    e.preventDefault();
    if (busy) return;
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
    setBusy('save');
    setError(null);
    try {
      await saveInvoice({
        ...invoice,
        number: number.trim(),
        amount: parsed,
        due,
        desc: desc.trim(),
        email: email.trim(),
        phone: phone.trim(),
      });
      retry(['invoices']);
      setOpen(false);
    } catch (err) {
      setError(errorMessage(err));
    } finally {
      setBusy(null);
    }
  }

  async function onDelete() {
    if (busy) return;
    setBusy('delete');
    setError(null);
    try {
      await deleteInvoice(invoice.id);
      // The row is now a tombstone; leave the (gone) detail view for the list.
      navigate('/invoices');
    } catch (err) {
      setError(errorMessage(err));
      setBusy(null); // stay on the page so the error is visible
    }
  }

  if (!open) {
    return (
      <Card pad>
        <button type="button" className="btn" onClick={openEditor}>
          Edit details
        </button>
      </Card>
    );
  }

  return (
    <Card pad>
      <div className="section-label" style={{ padding: '0 0 10px' }}>
        Edit invoice
      </div>
      {error && (
        <div className="inline-alert error" role="alert">
          {error}
        </div>
      )}
      <form className="pay-form" style={{ marginTop: 0, borderTop: 0, paddingTop: 0 }} onSubmit={onSave}>
        <label className="field">
          <span>Invoice #</span>
          <input
            className="field-input"
            type="text"
            value={number}
            onChange={(e) => setNumber(e.target.value)}
          />
        </label>
        <label className="field">
          <span>Amount</span>
          <input
            className="field-input"
            inputMode="decimal"
            type="number"
            step="0.01"
            min="0"
            value={amount}
            onChange={(e) => setAmount(e.target.value)}
          />
        </label>
        {invoice.lineItems && invoice.lineItems.length > 0 && (
          <div className="meta">
            This invoice has itemized line items; editing the total here doesn’t
            change them.
          </div>
        )}
        <label className="field">
          <span>Due date</span>
          <input
            className="field-input"
            type="date"
            value={due}
            onChange={(e) => setDue(e.target.value)}
          />
        </label>
        <label className="field">
          <span>Description</span>
          <input
            className="field-input"
            type="text"
            value={desc}
            onChange={(e) => setDesc(e.target.value)}
          />
        </label>
        <label className="field">
          <span>Customer email</span>
          <input
            className="field-input"
            type="email"
            value={email}
            onChange={(e) => setEmail(e.target.value)}
          />
        </label>
        <label className="field">
          <span>Customer phone</span>
          <input
            className="field-input"
            type="tel"
            value={phone}
            onChange={(e) => setPhone(e.target.value)}
          />
        </label>
        <div className="btn-row">
          <button type="submit" className="btn primary" disabled={busy !== null}>
            {busy === 'save' ? 'Saving…' : 'Save changes'}
          </button>
          <button
            type="button"
            className="btn ghost"
            onClick={() => setOpen(false)}
            disabled={busy !== null}
          >
            Cancel
          </button>
        </div>
      </form>

      <div className="danger-zone">
        {confirmDelete ? (
          <div className="btn-row">
            <span className="meta">Delete this invoice?</span>
            <button
              type="button"
              className="btn danger sm"
              onClick={onDelete}
              disabled={busy !== null}
            >
              {busy === 'delete' ? 'Deleting…' : 'Delete'}
            </button>
            <button
              type="button"
              className="btn ghost sm"
              onClick={() => setConfirmDelete(false)}
              disabled={busy !== null}
            >
              Cancel
            </button>
          </div>
        ) : (
          <button
            type="button"
            className="btn ghost sm danger-text"
            onClick={() => setConfirmDelete(true)}
          >
            Delete invoice
          </button>
        )}
      </div>
    </Card>
  );
}

/** The payments ledger with a per-row void action. */
function PaymentsCard({ invoice }: { invoice: Invoice }) {
  const { retry } = useData();
  const payments = effectivePayments(invoice).filter((p) => !p.voidedAt);

  const [confirmId, setConfirmId] = useState<string | null>(null);
  const [busyId, setBusyId] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  async function onVoid(paymentId: string) {
    if (busyId) return;
    setBusyId(paymentId);
    setError(null);
    try {
      await voidInvoicePayment(invoice.id, paymentId, getTodayDateString());
      retry(['invoices']);
      setConfirmId(null);
    } catch (err) {
      setError(errorMessage(err));
    } finally {
      setBusyId(null);
    }
  }

  return (
    <Card>
      <div className="section-label">Payments</div>
      {error && (
        <div className="inline-alert error" role="alert" style={{ margin: '0 16px 8px' }}>
          {error}
        </div>
      )}
      {payments.length === 0 ? (
        <Empty>No payments recorded.</Empty>
      ) : (
        <div className="list">
          {payments.map((p) => (
            <div key={p.id} className="row">
              <div className="grow">
                <div className="title">{formatMoney(p.amount || 0)}</div>
                <div className="meta">
                  {p.method}
                  {p.date ? ` · ${formatDisplayDate(p.date)}` : ''}
                  {p.note ? ` · ${p.note}` : ''}
                </div>
              </div>
              {confirmId === p.id ? (
                <div className="btn-row">
                  <button
                    type="button"
                    className="btn danger sm"
                    onClick={() => onVoid(p.id)}
                    disabled={busyId !== null}
                  >
                    {busyId === p.id ? 'Voiding…' : 'Void'}
                  </button>
                  <button
                    type="button"
                    className="btn ghost sm"
                    onClick={() => setConfirmId(null)}
                    disabled={busyId !== null}
                  >
                    Cancel
                  </button>
                </div>
              ) : (
                <button
                  type="button"
                  className="btn ghost sm"
                  onClick={() => {
                    setConfirmId(p.id);
                    setError(null);
                  }}
                >
                  Void
                </button>
              )}
            </div>
          ))}
        </div>
      )}
    </Card>
  );
}

export default function InvoiceDetailScreen() {
  const { id } = useParams();
  const { invoices, customers } = useData();
  const state = useResources('invoices');

  if (state.loading) return <Empty>Loading…</Empty>;
  if (state.error)
    return (
      <ErrorState
        message={`Couldn’t load this invoice: ${state.error}`}
        onRetry={state.retry}
      />
    );
  const inv = invoices.find((i) => i.id === id);
  if (!inv) return <Empty>Invoice not found.</Empty>;

  const badge = invoiceStatusBadge(inv);
  const customer =
    (inv.customerId && customers.find((c) => c.id === inv.customerId)) ||
    customers.find((c) => c.name === inv.customer);
  const lineItems = inv.lineItems ?? [];

  return (
    <>
      <Link to="/invoices" className="back-link">
        ‹ Invoices
      </Link>

      <div className="page-head">
        <div>
          <h1>{inv.customer || 'Invoice'}</h1>
          <div className="sub">
            {inv.number ? `Invoice #${inv.number} · ` : ''}
            Due {inv.due ? formatDisplayDate(inv.due) : '—'}
          </div>
        </div>
        <Badge color={badge.color}>{badge.label}</Badge>
      </div>

      <div className="detail-grid wide-main">
        <div className="stack">
          {inv.desc && (
            <Card pad>
              <div className="section-label" style={{ padding: '0 0 8px' }}>
                Description
              </div>
              <div className="muted">{inv.desc}</div>
            </Card>
          )}

          {lineItems.length > 0 && (
            <Card>
              <div className="section-label">Line items</div>
              <div className="list">
                {lineItems.map((li, i) => (
                  <div key={i} className="row">
                    <div className="grow">
                      <div className="title">{li.description || 'Item'}</div>
                    </div>
                    <span className="amt">{formatMoney(li.amount || 0)}</span>
                  </div>
                ))}
              </div>
            </Card>
          )}

          <PaymentsCard invoice={inv} />
        </div>

        <div className="stack">
          <Card pad>
            <div className="section-label" style={{ padding: '0 0 8px' }}>
              Summary
            </div>
            <KV k="Invoice total" v={formatMoney(inv.amount || 0)} />
            <KV k="Paid" v={formatMoney(amountPaid(inv))} />
            <KV k="Balance due" v={formatMoney(balanceDue(inv))} />
            {inv.paidAt && <KV k="Paid on" v={formatDisplayDate(inv.paidAt)} />}
          </Card>

          <PaymentActions invoice={inv} />

          <InvoiceEditor invoice={inv} />

          {(inv.email || inv.phone || customer) && (
            <Card pad>
              <div className="section-label" style={{ padding: '0 0 8px' }}>
                Customer
              </div>
              {customer ? (
                <Link to={`/customers/${customer.id}`} className="title">
                  {customer.name}
                </Link>
              ) : (
                <div className="title">{inv.customer}</div>
              )}
              {(inv.phone || customer?.phone) && (
                <div className="meta">{inv.phone || customer?.phone}</div>
              )}
              {(inv.email || customer?.email) && (
                <div className="meta">{inv.email || customer?.email}</div>
              )}
            </Card>
          )}
        </div>
      </div>
    </>
  );
}
