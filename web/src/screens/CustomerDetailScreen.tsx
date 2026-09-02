import { useState } from 'react';
import { Link, useNavigate, useParams } from 'react-router-dom';
import { useData, useResources } from '../lib/DataContext';
import { Card, Empty, Badge, KV, ErrorState } from '../ui/components';
import { jobStatusBadge, invoiceStatusBadge } from '../ui/status';
import { formatMoney } from '@shared/utils/format';
import { formatDisplayDate, getTodayDateString } from '@shared/utils/dateHelpers';
import { amountPaid, balanceDue } from '@shared/utils/invoicePayments';
import { isArchived, withArchived } from '@shared/utils/archive';
import type { Customer } from '@shared/types/models';
import { saveCustomer, deleteCustomer } from '../lib/writeRepository';

function errorMessage(err: unknown): string {
  return err instanceof Error ? err.message : 'Something went wrong';
}

/**
 * Edit a customer's fields and notes, archive/unarchive, or delete (roadmap P3
 * stage 2). A Customer is a plain last-write-wins blob, so the caller hands the
 * FULL record with edits applied to `saveCustomer` (preserving unrendered fields
 * like the portal token). Notes are the record's own `notes` field — the legacy
 * customer_notes table is retired. Archiving is the model's safe soft-removal
 * (invoices/jobs keep working); hard delete is offered too, with the same
 * "invoices and jobs stay but unlinked" warning the mobile app shows.
 */
function CustomerEditor({ customer }: { customer: Customer }) {
  const { retry } = useData();
  const navigate = useNavigate();
  const archived = isArchived(customer);

  const [open, setOpen] = useState(false);
  const [name, setName] = useState(customer.name ?? '');
  const [email, setEmail] = useState(customer.email ?? '');
  const [phone, setPhone] = useState(customer.phone ?? '');
  const [address, setAddress] = useState(customer.address ?? '');
  const [notes, setNotes] = useState(customer.notes ?? '');
  const [busy, setBusy] = useState<'save' | 'archive' | 'delete' | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [confirmDelete, setConfirmDelete] = useState(false);

  function openEditor() {
    setName(customer.name ?? '');
    setEmail(customer.email ?? '');
    setPhone(customer.phone ?? '');
    setAddress(customer.address ?? '');
    setNotes(customer.notes ?? '');
    setError(null);
    setConfirmDelete(false);
    setOpen(true);
  }

  async function onSave(e: React.FormEvent) {
    e.preventDefault();
    if (busy) return;
    if (!name.trim()) {
      setError('Customer name is required.');
      return;
    }
    setBusy('save');
    setError(null);
    try {
      await saveCustomer(
        {
          ...customer,
          name: name.trim(),
          email: email.trim(),
          phone: phone.trim(),
          address: address.trim(),
          notes: notes.trim(),
        },
        customer,
      );
      retry(['customers']);
      setOpen(false);
    } catch (err) {
      setError(errorMessage(err));
    } finally {
      setBusy(null);
    }
  }

  async function onToggleArchive() {
    if (busy) return;
    setBusy('archive');
    setError(null);
    try {
      await saveCustomer(
        withArchived(customer, !archived, getTodayDateString()),
        customer,
      );
      retry(['customers']);
      // Archiving removes the customer from the active list — leave the detail
      // view. Unarchiving keeps them here.
      if (!archived) navigate('/customers');
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
      await deleteCustomer(customer.id);
      navigate('/customers');
    } catch (err) {
      setError(errorMessage(err));
      setBusy(null);
    }
  }

  if (!open) {
    return (
      <Card pad style={{ marginTop: 16 }}>
        <div className="btn-row">
          <button type="button" className="btn" onClick={openEditor}>
            Edit customer
          </button>
          <button
            type="button"
            className="btn ghost"
            onClick={onToggleArchive}
            disabled={busy !== null}
          >
            {busy === 'archive'
              ? 'Saving…'
              : archived
                ? 'Unarchive'
                : 'Archive'}
          </button>
        </div>
        {error && (
          <div className="inline-alert error" role="alert" style={{ marginTop: 12, marginBottom: 0 }}>
            {error}
          </div>
        )}
      </Card>
    );
  }

  return (
    <Card pad style={{ marginTop: 16 }}>
      <div className="section-label" style={{ padding: '0 0 10px' }}>
        Edit customer
      </div>
      {error && (
        <div className="inline-alert error" role="alert">
          {error}
        </div>
      )}
      <form className="pay-form" style={{ marginTop: 0, borderTop: 0, paddingTop: 0 }} onSubmit={onSave}>
        <label className="field">
          <span>Name</span>
          <input
            className="field-input"
            type="text"
            value={name}
            onChange={(e) => setName(e.target.value)}
          />
        </label>
        <label className="field">
          <span>Email</span>
          <input
            className="field-input"
            type="email"
            value={email}
            onChange={(e) => setEmail(e.target.value)}
          />
        </label>
        <label className="field">
          <span>Phone</span>
          <input
            className="field-input"
            type="tel"
            value={phone}
            onChange={(e) => setPhone(e.target.value)}
          />
        </label>
        <label className="field">
          <span>Address</span>
          <input
            className="field-input"
            type="text"
            value={address}
            onChange={(e) => setAddress(e.target.value)}
          />
        </label>
        <label className="field">
          <span>Notes</span>
          <textarea
            className="field-input"
            rows={3}
            value={notes}
            onChange={(e) => setNotes(e.target.value)}
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
            <span className="meta">
              Delete this customer? Their invoices and jobs stay but become
              unlinked.
            </span>
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
            Delete customer
          </button>
        )}
      </div>
    </Card>
  );
}

export default function CustomerDetailScreen() {
  const { id } = useParams();
  const { customers, jobs, invoices, notes } = useData();
  const state = useResources('customers');

  if (state.loading) return <Empty>Loading…</Empty>;
  if (state.error)
    return (
      <ErrorState
        message={`Couldn’t load this customer: ${state.error}`}
        onRetry={state.retry}
      />
    );
  const customer = customers.find((c) => c.id === id);
  if (!customer) return <Empty>Customer not found.</Empty>;

  const custJobs = jobs
    .filter((j) => j.customerId === customer.id && !j.archivedAt)
    .sort((a, b) => (b.createdAt || '').localeCompare(a.createdAt || ''));
  const custInvoices = invoices
    .filter(
      (i) => i.customerId === customer.id || i.customer === customer.name,
    )
    .sort((a, b) => (b.due || '').localeCompare(a.due || ''));

  const collected = custInvoices.reduce((s, i) => s + amountPaid(i), 0);
  const owed = custInvoices.reduce((s, i) => s + balanceDue(i), 0);
  const note = notes[customer.id] || customer.notes;

  return (
    <>
      <Link to="/customers" className="back-link">
        ‹ Customers
      </Link>

      <div className="page-head">
        <div>
          <h1>{customer.name || 'Customer'}</h1>
          <div className="sub">
            {[customer.phone, customer.email].filter(Boolean).join(' · ') ||
              'No contact info'}
          </div>
        </div>
        {isArchived(customer) && <Badge color="slate">Archived</Badge>}
      </div>

      <div className="grid grid-3" style={{ marginBottom: 16 }}>
        <Card className="stat">
          <div className="label">Revenue</div>
          <div className="value pos">{formatMoney(collected)}</div>
        </Card>
        <Card className="stat">
          <div className="label">Owed</div>
          <div className={`value ${owed > 0 ? 'neg' : ''}`.trim()}>
            {formatMoney(owed)}
          </div>
        </Card>
        <Card className="stat">
          <div className="label">Jobs</div>
          <div className="value">{custJobs.length}</div>
        </Card>
      </div>

      <div className="detail-grid">
        <Card>
          <div className="section-label">Jobs</div>
          {custJobs.length === 0 ? (
            <Empty>No jobs yet.</Empty>
          ) : (
            <div className="list">
              {custJobs.map((j) => {
                const b = jobStatusBadge(j.status);
                return (
                  <Link key={j.id} to={`/jobs/${j.id}`} className="row">
                    <div className="grow">
                      <div className="title">{j.title || 'Job'}</div>
                      <div className="meta">
                        {j.scheduledDate
                          ? formatDisplayDate(j.scheduledDate)
                          : 'Unscheduled'}
                      </div>
                    </div>
                    <Badge color={b.color}>{b.label}</Badge>
                    <span className="amt">
                      {formatMoney(j.estimateTotal || 0)}
                    </span>
                  </Link>
                );
              })}
            </div>
          )}
        </Card>

        <Card>
          <div className="section-label">Invoices</div>
          {custInvoices.length === 0 ? (
            <Empty>No invoices yet.</Empty>
          ) : (
            <div className="list">
              {custInvoices.map((inv) => {
                const b = invoiceStatusBadge(inv);
                return (
                  <Link
                    key={inv.id}
                    to={`/invoices/${inv.id}`}
                    className="row"
                  >
                    <div className="grow">
                      <div className="title">
                        {inv.number ? `#${inv.number}` : 'Invoice'}
                      </div>
                      <div className="meta">
                        Due {inv.due ? formatDisplayDate(inv.due) : '—'}
                      </div>
                    </div>
                    <Badge color={b.color}>{b.label}</Badge>
                    <span className="amt">{formatMoney(inv.amount || 0)}</span>
                  </Link>
                );
              })}
            </div>
          )}
        </Card>
      </div>

      {(customer.address || note) && (
        <Card pad style={{ marginTop: 16 }}>
          {customer.address && <KV k="Address" v={customer.address} />}
          {note && <KV k="Notes" v={note} />}
        </Card>
      )}

      <CustomerEditor customer={customer} />
    </>
  );
}
