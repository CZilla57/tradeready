import { useMemo, useState } from 'react';
import { Link, useNavigate } from 'react-router-dom';
import { useData, useResources } from '../lib/DataContext';
import { Card, PageHead, Empty, Badge, ErrorState } from '../ui/components';
import { jobStatusBadge } from '../ui/status';
import { formatMoney } from '@shared/utils/format';
import { formatDisplayDate } from '@shared/utils/dateHelpers';
import type { Customer, Job, JobStatus, Settings } from '@shared/types/models';
import { createJob } from '../lib/writeRepository';

function errorMessage(err: unknown): string {
  return err instanceof Error ? err.message : 'Something went wrong';
}

// Mobile's unpriced-job seed defaults (screens/AddJobScreen.tsx) — used when the
// owner hasn't set the corresponding pricing default in Settings.
const DEFAULT_LABOR_RATE = 85;
const DEFAULT_MATERIAL_MARKUP = 20;
const DEFAULT_OVERHEAD = 15;
const DEFAULT_MARGIN = 20;

/**
 * The "New job" form (roadmap P3 stage 5c — creation flows). Creates an unpriced
 * LEAD via `createJob` and navigates to it on success. A customer is picked from
 * existing records (a job needs the id + denormalized name; inline customer
 * creation belongs to the Customers screen, matching the New plan form). Title is
 * required. Estimate/pricing authoring is deferred (3b), so the four rate fields
 * are seeded from the business defaults, exactly as mobile seeds an unpriced job.
 * Follows the InvoiceDetailScreen UX: in-flight disable, a failed write that
 * stays open with the error.
 */
function NewJobForm({
  customers,
  settings,
  onClose,
}: {
  customers: Customer[];
  settings: Settings | null;
  onClose: () => void;
}) {
  const navigate = useNavigate();
  const pickable = customers
    .filter((c) => !c.archivedAt)
    .sort((a, b) => (a.name || '').localeCompare(b.name || ''));
  const [customerId, setCustomerId] = useState('');
  const [title, setTitle] = useState('');
  const [description, setDescription] = useState('');
  const [address, setAddress] = useState('');
  const [date, setDate] = useState('');
  const [start, setStart] = useState('');
  const [end, setEnd] = useState('');
  const [notes, setNotes] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function onSave(e: React.FormEvent) {
    e.preventDefault();
    if (busy) return;
    const customer = pickable.find((c) => c.id === customerId);
    if (!customer) {
      setError('Choose a customer.');
      return;
    }
    const trimmedTitle = title.trim();
    if (!trimmedTitle) {
      setError('Job title is required.');
      return;
    }
    if (start && end && end < start) {
      setError('End time can’t be before start time.');
      return;
    }
    setBusy(true);
    setError(null);
    try {
      const created = await createJob({
        customerId: customer.id,
        customerName: customer.name,
        title: trimmedTitle,
        description: description.trim(),
        address: address.trim(),
        scheduledDate: date || null,
        scheduledStartTime: start || null,
        scheduledEndTime: end || null,
        notes: notes.trim(),
        laborRate: settings?.laborRate ?? DEFAULT_LABOR_RATE,
        materialMarkup: settings?.materialMarkup ?? DEFAULT_MATERIAL_MARKUP,
        overhead: settings?.overheadPercent ?? DEFAULT_OVERHEAD,
        margin: settings?.marginPercent ?? DEFAULT_MARGIN,
      });
      navigate(`/jobs/${created.id}`);
    } catch (err) {
      setError(errorMessage(err));
      setBusy(false);
    }
  }

  return (
    <Card pad>
      <div className="section-label" style={{ padding: '0 0 10px' }}>
        New job
      </div>
      {error && (
        <div className="inline-alert error" role="alert">
          {error}
        </div>
      )}
      {pickable.length === 0 ? (
        <div className="muted" style={{ fontSize: 13 }}>
          Add a customer first — a job is booked for an existing customer.
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
            <select className="field-input" value={customerId} onChange={(e) => setCustomerId(e.target.value)}>
              <option value="">Select a customer…</option>
              {pickable.map((c) => (
                <option key={c.id} value={c.id}>
                  {c.name || 'Unnamed'}
                </option>
              ))}
            </select>
          </label>
          <label className="field">
            <span>Title</span>
            <input className="field-input" type="text" value={title} onChange={(e) => setTitle(e.target.value)} autoFocus />
          </label>
          <label className="field">
            <span>Description</span>
            <textarea className="field-input" rows={2} value={description} onChange={(e) => setDescription(e.target.value)} />
          </label>
          <label className="field">
            <span>Scheduled date</span>
            <input className="field-input" type="date" value={date} onChange={(e) => setDate(e.target.value)} />
          </label>
          <div className="btn-row">
            <label className="field" style={{ flex: 1 }}>
              <span>Start</span>
              <input className="field-input" type="time" aria-label="Start time" value={start} onChange={(e) => setStart(e.target.value)} />
            </label>
            <label className="field" style={{ flex: 1 }}>
              <span>End</span>
              <input className="field-input" type="time" aria-label="End time" value={end} onChange={(e) => setEnd(e.target.value)} />
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
              {busy ? 'Creating…' : 'Create job'}
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

type Filter = 'active' | 'estimates' | 'completed' | 'all';

const ESTIMATE_STATUSES: JobStatus[] = ['lead', 'estimate_sent', 'declined'];
const DONE_STATUSES: JobStatus[] = ['complete', 'invoiced', 'paid'];

function matches(job: Job, filter: Filter): boolean {
  switch (filter) {
    case 'estimates':
      return ESTIMATE_STATUSES.includes(job.status);
    case 'completed':
      return DONE_STATUSES.includes(job.status);
    case 'active':
      return !DONE_STATUSES.includes(job.status) && job.status !== 'declined';
    default:
      return true;
  }
}

const FILTERS: { key: Filter; label: string }[] = [
  { key: 'active', label: 'Active' },
  { key: 'estimates', label: 'Estimates' },
  { key: 'completed', label: 'Completed' },
  { key: 'all', label: 'All' },
];

export default function JobsScreen() {
  const { jobs, customers, settings } = useData();
  const state = useResources('jobs');
  const [filter, setFilter] = useState<Filter>('active');
  const [q, setQ] = useState('');
  const [creating, setCreating] = useState(false);

  const rows = useMemo(() => {
    const term = q.trim().toLowerCase();
    return jobs
      .filter((j) => !j.archivedAt)
      .filter((j) => matches(j, filter))
      .filter(
        (j) =>
          !term ||
          j.title?.toLowerCase().includes(term) ||
          j.customerName?.toLowerCase().includes(term) ||
          j.address?.toLowerCase().includes(term),
      )
      .sort((a, b) => (b.createdAt || '').localeCompare(a.createdAt || ''));
  }, [jobs, filter, q]);

  if (state.loading) return <Empty>Loading jobs…</Empty>;
  if (state.error)
    return (
      <ErrorState
        message={`Couldn’t load jobs: ${state.error}`}
        onRetry={state.retry}
      />
    );

  return (
    <>
      <PageHead
        title="Jobs"
        sub={`${rows.length} shown`}
        right={
          !creating && (
            <button type="button" className="btn sm" onClick={() => setCreating(true)}>
              New job
            </button>
          )
        }
      />
      {creating && (
        <NewJobForm
          customers={customers}
          settings={settings}
          onClose={() => setCreating(false)}
        />
      )}
      <input
        className="search"
        placeholder="Search jobs, customers, addresses…"
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
          <Empty>No jobs match.</Empty>
        ) : (
          <div className="list">
            {rows.map((j) => {
              const badge = jobStatusBadge(j.status);
              return (
                <Link key={j.id} to={`/jobs/${j.id}`} className="row">
                  <div className="grow">
                    <div className="title">
                      {j.title || j.customerName || 'Untitled job'}
                    </div>
                    <div className="meta">
                      {j.customerName || 'No customer'}
                      {j.scheduledDate
                        ? ` · ${formatDisplayDate(j.scheduledDate)}`
                        : ''}
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
