import { useMemo, useState } from 'react';
import { Link, useNavigate } from 'react-router-dom';
import { useData, useResources } from '../lib/DataContext';
import { Card, PageHead, Empty, ErrorState } from '../ui/components';
import { formatMoney } from '@shared/utils/format';
import { amountPaid } from '@shared/utils/invoicePayments';
import type { Customer } from '@shared/types/models';
import { createCustomer } from '../lib/writeRepository';

function errorMessage(err: unknown): string {
  return err instanceof Error ? err.message : 'Something went wrong';
}

const normalizeName = (name: string | null | undefined): string =>
  (name || '').trim().toLowerCase();

/**
 * The "New customer" form (roadmap P3 stage 5 — creation flows). Creates a
 * record through `createCustomer` (mobile-format id + createdAt) and navigates
 * to it on success. Name is required; a case-insensitive name clash with an
 * existing (non-archived) customer is blocked here rather than silently merged,
 * so the portal never creates a hidden duplicate — the same name key mobile's
 * `upsertCustomerInList` dedupes on. Follows the InvoiceDetailScreen UX:
 * in-flight disable, a failed write that stays open with the error.
 */
function NewCustomerForm({
  existing,
  onClose,
}: {
  existing: Customer[];
  onClose: () => void;
}) {
  const navigate = useNavigate();
  const [name, setName] = useState('');
  const [email, setEmail] = useState('');
  const [phone, setPhone] = useState('');
  const [address, setAddress] = useState('');
  const [notes, setNotes] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function onSave(e: React.FormEvent) {
    e.preventDefault();
    if (busy) return;
    const trimmed = name.trim();
    if (!trimmed) {
      setError('Customer name is required.');
      return;
    }
    const key = normalizeName(trimmed);
    const clash = existing.find(
      (c) => !c.archivedAt && normalizeName(c.name) === key,
    );
    if (clash) {
      setError(`A customer named “${clash.name}” already exists.`);
      return;
    }
    setBusy(true);
    setError(null);
    try {
      const created = await createCustomer({
        name: trimmed,
        email: email.trim(),
        phone: phone.trim(),
        address: address.trim(),
        notes: notes.trim(),
      });
      navigate(`/customers/${created.id}`);
    } catch (err) {
      setError(errorMessage(err));
      setBusy(false);
    }
  }

  return (
    <Card pad>
      <div className="section-label" style={{ padding: '0 0 10px' }}>
        New customer
      </div>
      {error && (
        <div className="inline-alert error" role="alert">
          {error}
        </div>
      )}
      <form className="pay-form" style={{ marginTop: 0, borderTop: 0, paddingTop: 0 }} onSubmit={onSave}>
        <label className="field">
          <span>Name</span>
          <input className="field-input" type="text" value={name} onChange={(e) => setName(e.target.value)} autoFocus />
        </label>
        <div className="btn-row">
          <label className="field" style={{ flex: 1 }}>
            <span>Phone</span>
            <input className="field-input" type="tel" value={phone} onChange={(e) => setPhone(e.target.value)} />
          </label>
          <label className="field" style={{ flex: 1 }}>
            <span>Email</span>
            <input className="field-input" type="email" value={email} onChange={(e) => setEmail(e.target.value)} />
          </label>
        </div>
        <label className="field">
          <span>Address</span>
          <input className="field-input" type="text" value={address} onChange={(e) => setAddress(e.target.value)} />
        </label>
        <label className="field">
          <span>Notes</span>
          <textarea className="field-input" rows={2} value={notes} onChange={(e) => setNotes(e.target.value)} />
        </label>
        <div className="btn-row">
          <button type="submit" className="btn primary" disabled={busy}>
            {busy ? 'Creating…' : 'Create customer'}
          </button>
          <button type="button" className="btn ghost" onClick={onClose} disabled={busy}>
            Cancel
          </button>
        </div>
      </form>
    </Card>
  );
}

export default function CustomersScreen() {
  const { customers, invoices } = useData();
  const [creating, setCreating] = useState(false);
  // Blocks on customers; invoices only feed the revenue column, so an invoice
  // failure still lists customers (revenue reads 0 until it recovers).
  const state = useResources('customers');
  const [q, setQ] = useState('');

  const revenueByName = useMemo(() => {
    const map = new Map<string, number>();
    for (const inv of invoices) {
      const key = inv.customer || '';
      map.set(key, (map.get(key) ?? 0) + amountPaid(inv));
    }
    return map;
  }, [invoices]);

  const rows = useMemo(() => {
    const term = q.trim().toLowerCase();
    return customers
      .filter((c) => !c.archivedAt)
      .filter(
        (c) =>
          !term ||
          c.name?.toLowerCase().includes(term) ||
          c.email?.toLowerCase().includes(term) ||
          c.phone?.toLowerCase().includes(term),
      )
      .sort((a, b) => (a.name || '').localeCompare(b.name || ''));
  }, [customers, q]);

  if (state.loading) return <Empty>Loading customers…</Empty>;
  if (state.error)
    return (
      <ErrorState
        message={`Couldn’t load customers: ${state.error}`}
        onRetry={state.retry}
      />
    );

  return (
    <>
      <PageHead
        title="Customers"
        sub={`${rows.length} shown`}
        right={
          !creating && (
            <button type="button" className="btn sm" onClick={() => setCreating(true)}>
              New customer
            </button>
          )
        }
      />
      {creating && (
        <NewCustomerForm existing={customers} onClose={() => setCreating(false)} />
      )}
      <input
        className="search"
        placeholder="Search by name, email, phone…"
        value={q}
        onChange={(e) => setQ(e.target.value)}
      />
      <Card>
        {rows.length === 0 ? (
          <Empty>No customers match.</Empty>
        ) : (
          <div className="list">
            {rows.map((c) => (
              <Link key={c.id} to={`/customers/${c.id}`} className="row">
                <div className="grow">
                  <div className="title">{c.name || 'Unnamed'}</div>
                  <div className="meta">
                    {[c.phone, c.email].filter(Boolean).join(' · ') ||
                      c.address ||
                      'No contact info'}
                  </div>
                </div>
                <span className="amt">
                  {formatMoney(revenueByName.get(c.name) ?? 0)}
                </span>
                <span className="chev">›</span>
              </Link>
            ))}
          </div>
        )}
      </Card>
    </>
  );
}
