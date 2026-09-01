import { useState } from 'react';
import { Link, useNavigate, useParams } from 'react-router-dom';
import { useData, useResources } from '../lib/DataContext';
import { Card, Empty, Badge, KV, ErrorState } from '../ui/components';
import {
  jobStatusBadge,
  JOB_PIPELINE,
  nextOperationalStatus,
  canAuthorEstimate,
} from '../ui/status';
import { formatMoney } from '@shared/utils/format';
import { formatDisplayDate, formatTimeRange } from '@shared/utils/dateHelpers';
import { isArchived } from '@shared/utils/archive';
import type { Job } from '@shared/types/models';
import {
  updateJobDetails,
  setJobArchived,
  deleteJob,
  advanceJobStatus,
  updateJobPricing,
} from '../lib/writeRepository';
import { estimateTotalFromPricing } from '../ui/pricingMath';
import { MaterialsEditor } from '../ui/MaterialsEditor';
import {
  materialsToDrafts,
  parseMaterialDrafts,
  type MaterialDraft,
} from '../ui/materialsDraft';

function errorMessage(err: unknown): string {
  return err instanceof Error ? err.message : 'Something went wrong';
}

/** Parse a required non-negative number field; null when blank or invalid. */
function parseNonNeg(s: string): number | null {
  const t = s.trim();
  if (t === '') return null;
  const n = Number(t);
  return Number.isFinite(n) && n >= 0 ? n : null;
}

/**
 * Advance a job one operational step (scheduled → in progress → complete) via
 * `advanceJobStatus` (roadmap P3 stage 3b). Only the two consent-free,
 * invoice-free transitions are offered; everything else (approval, invoicing,
 * payment) is reflected from its own domain, not driven here. Follows the
 * established edit pattern: the button disables while in flight, a failed write
 * stays visible as an error, and success re-pulls jobs from the server.
 */
function StatusAdvance({ job }: { job: Job }) {
  const { retry } = useData();
  const transition = nextOperationalStatus(job.status);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  if (!transition || isArchived(job)) return null;

  async function onAdvance() {
    if (busy) return;
    setBusy(true);
    setError(null);
    try {
      await advanceJobStatus(job.id);
      retry(['jobs']);
    } catch (err) {
      setError(errorMessage(err));
    } finally {
      setBusy(false);
    }
  }

  return (
    <div style={{ marginTop: 12 }}>
      <button
        type="button"
        className="btn primary sm"
        onClick={onAdvance}
        disabled={busy}
      >
        {busy ? 'Saving…' : transition.label}
      </button>
      {error && (
        <div
          className="inline-alert error"
          role="alert"
          style={{ marginTop: 10, marginBottom: 0 }}
        >
          {error}
        </div>
      )}
    </div>
  );
}

/**
 * Author a job's estimate — the pricing inputs, its materials, and the derived
 * `estimateTotal` (roadmap P3 stage 3b, estimate authoring). Mirrors the mobile
 * PricingCalculator's `saveToJob`: `updateJobPricing` spreads the fresh server
 * row and overwrites only the pricing fields, so status / approval / invoiceId /
 * changeOrders / timeSessions / jobCosts survive. `estimateTotal` is recomputed
 * here via the shared `estimateTotalFromPricing` port over the edited inputs +
 * materials AND the job's existing `jobCosts`, matching the mobile save (P0.6).
 * Hidden once the customer has a frozen approval decision (`canAuthorEstimate`):
 * re-pricing a signed estimate is the deferred change-order surface.
 */
function JobPricingEditor({ job }: { job: Job }) {
  const { retry, settings } = useData();
  const [open, setOpen] = useState(false);
  const [laborHours, setLaborHours] = useState(String(job.laborHours ?? 0));
  const [laborRate, setLaborRate] = useState(String(job.laborRate ?? 0));
  const [materialMarkup, setMaterialMarkup] = useState(String(job.materialMarkup ?? 0));
  const [overhead, setOverhead] = useState(String(job.overhead ?? 0));
  const [margin, setMargin] = useState(String(job.margin ?? 0));
  const [materials, setMaterials] = useState<MaterialDraft[]>(
    materialsToDrafts(job.materials),
  );
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  function openEditor() {
    setLaborHours(String(job.laborHours ?? 0));
    setLaborRate(String(job.laborRate ?? 0));
    setMaterialMarkup(String(job.materialMarkup ?? 0));
    setOverhead(String(job.overhead ?? 0));
    setMargin(String(job.margin ?? 0));
    setMaterials(materialsToDrafts(job.materials));
    setError(null);
    setOpen(true);
  }

  async function onSave(e: React.FormEvent) {
    e.preventDefault();
    if (busy) return;
    const pricing = {
      laborHours: parseNonNeg(laborHours),
      laborRate: parseNonNeg(laborRate),
      materialMarkup: parseNonNeg(materialMarkup),
      overhead: parseNonNeg(overhead),
      margin: parseNonNeg(margin),
    };
    if (Object.values(pricing).some((v) => v === null)) {
      setError('Enter a valid, non-negative number for every pricing field.');
      return;
    }
    const parsedMaterials = parseMaterialDrafts(materials);
    if (!parsedMaterials.ok) {
      setError(parsedMaterials.error);
      return;
    }
    setBusy(true);
    setError(null);
    try {
      // Recompute the derived total the mobile way (travel/tax 0, non-emergency;
      // minimumJobFee from settings) over the edited inputs + materials AND the
      // job's existing jobCosts (which the portal doesn't author).
      const estimateTotal = estimateTotalFromPricing({
        laborHours: pricing.laborHours!,
        laborRate: pricing.laborRate!,
        materials: parsedMaterials.materials,
        materialMarkup: pricing.materialMarkup!,
        jobCosts: job.jobCosts,
        overheadPercent: pricing.overhead!,
        marginPercent: pricing.margin!,
        minimumJobFee: settings?.minimumJobFee ?? 75,
      });
      await updateJobPricing(job.id, {
        laborHours: pricing.laborHours!,
        laborRate: pricing.laborRate!,
        materials: parsedMaterials.materials,
        materialMarkup: pricing.materialMarkup!,
        overhead: pricing.overhead!,
        margin: pricing.margin!,
        estimateTotal,
      });
      retry(['jobs']);
      setOpen(false);
    } catch (err) {
      setError(errorMessage(err));
    } finally {
      setBusy(false);
    }
  }

  if (!open) {
    return (
      <Card pad>
        <div className="section-label" style={{ padding: '0 0 8px' }}>
          Estimate
        </div>
        <KV k="Total" v={formatMoney(job.estimateTotal || 0)} />
        <button type="button" className="btn" style={{ marginTop: 12 }} onClick={openEditor}>
          Edit estimate
        </button>
        {error && (
          <div className="inline-alert error" role="alert" style={{ marginTop: 12, marginBottom: 0 }}>
            {error}
          </div>
        )}
      </Card>
    );
  }

  return (
    <Card pad>
      <div className="section-label" style={{ padding: '0 0 10px' }}>
        Edit estimate
      </div>
      {error && (
        <div className="inline-alert error" role="alert">
          {error}
        </div>
      )}
      <form className="pay-form" style={{ marginTop: 0, borderTop: 0, paddingTop: 0 }} onSubmit={onSave}>
        <div className="btn-row">
          <label className="field" style={{ flex: 1 }}>
            <span>Labor hours</span>
            <input className="field-input" type="number" step="0.25" min="0" inputMode="decimal" value={laborHours} onChange={(e) => setLaborHours(e.target.value)} />
          </label>
          <label className="field" style={{ flex: 1 }}>
            <span>Labor rate ($/hr)</span>
            <input className="field-input" type="number" step="0.01" min="0" inputMode="decimal" value={laborRate} onChange={(e) => setLaborRate(e.target.value)} />
          </label>
        </div>
        <div className="btn-row">
          <label className="field" style={{ flex: 1 }}>
            <span>Material markup (%)</span>
            <input className="field-input" type="number" step="0.1" min="0" inputMode="decimal" value={materialMarkup} onChange={(e) => setMaterialMarkup(e.target.value)} />
          </label>
          <label className="field" style={{ flex: 1 }}>
            <span>Overhead (%)</span>
            <input className="field-input" type="number" step="0.1" min="0" inputMode="decimal" value={overhead} onChange={(e) => setOverhead(e.target.value)} />
          </label>
          <label className="field" style={{ flex: 1 }}>
            <span>Margin (%)</span>
            <input className="field-input" type="number" step="0.1" min="0" inputMode="decimal" value={margin} onChange={(e) => setMargin(e.target.value)} />
          </label>
        </div>
        <div className="meta">The total is recalculated from these.</div>
        <MaterialsEditor drafts={materials} onChange={setMaterials} disabled={busy} />
        <div className="btn-row">
          <button type="submit" className="btn primary" disabled={busy}>
            {busy ? 'Saving…' : 'Save estimate'}
          </button>
          <button type="button" className="btn ghost" onClick={() => setOpen(false)} disabled={busy}>
            Cancel
          </button>
        </div>
      </form>
    </Card>
  );
}

/**
 * Edit a job's operational fields, archive/unarchive, or delete (roadmap P3
 * stage 3). Edits go through `updateJobDetails`, which applies them onto a fresh
 * server copy so a customer's estimate approval / change-order consent, mobile
 * time sessions, status, and pricing are never clobbered. Status transitions and
 * estimate/pricing editing are intentionally out of scope here.
 */
function JobEditor({ job }: { job: Job }) {
  const { retry } = useData();
  const navigate = useNavigate();
  const archived = isArchived(job);

  const [open, setOpen] = useState(false);
  const [title, setTitle] = useState(job.title ?? '');
  const [description, setDescription] = useState(job.description ?? '');
  const [address, setAddress] = useState(job.address ?? '');
  const [date, setDate] = useState(job.scheduledDate ?? '');
  const [start, setStart] = useState(job.scheduledStartTime ?? '');
  const [end, setEnd] = useState(job.scheduledEndTime ?? '');
  const [notes, setNotes] = useState(job.notes ?? '');
  const [busy, setBusy] = useState<'save' | 'archive' | 'delete' | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [confirmDelete, setConfirmDelete] = useState(false);

  function openEditor() {
    setTitle(job.title ?? '');
    setDescription(job.description ?? '');
    setAddress(job.address ?? '');
    setDate(job.scheduledDate ?? '');
    setStart(job.scheduledStartTime ?? '');
    setEnd(job.scheduledEndTime ?? '');
    setNotes(job.notes ?? '');
    setError(null);
    setConfirmDelete(false);
    setOpen(true);
  }

  async function onSave(e: React.FormEvent) {
    e.preventDefault();
    if (busy) return;
    if (start && end && end < start) {
      setError('End time can’t be before start time.');
      return;
    }
    setBusy('save');
    setError(null);
    try {
      await updateJobDetails(job.id, {
        title: title.trim(),
        description: description.trim(),
        address: address.trim(),
        scheduledDate: date || null,
        scheduledStartTime: start || null,
        scheduledEndTime: end || null,
        notes: notes.trim(),
      });
      retry(['jobs']);
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
      await setJobArchived(job.id, !archived);
      retry(['jobs']);
      if (!archived) navigate('/jobs');
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
      await deleteJob(job.id);
      navigate('/jobs');
    } catch (err) {
      setError(errorMessage(err));
      setBusy(null);
    }
  }

  if (!open) {
    return (
      <Card pad>
        <div className="btn-row">
          <button type="button" className="btn" onClick={openEditor}>
            Edit job
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
    <Card pad>
      <div className="section-label" style={{ padding: '0 0 10px' }}>
        Edit job
      </div>
      {error && (
        <div className="inline-alert error" role="alert">
          {error}
        </div>
      )}
      <form className="pay-form" style={{ marginTop: 0, borderTop: 0, paddingTop: 0 }} onSubmit={onSave}>
        <label className="field">
          <span>Title</span>
          <input
            className="field-input"
            type="text"
            value={title}
            onChange={(e) => setTitle(e.target.value)}
          />
        </label>
        <label className="field">
          <span>Description</span>
          <textarea
            className="field-input"
            rows={2}
            value={description}
            onChange={(e) => setDescription(e.target.value)}
          />
        </label>
        <label className="field">
          <span>Scheduled date</span>
          <input
            className="field-input"
            type="date"
            value={date}
            onChange={(e) => setDate(e.target.value)}
          />
        </label>
        <div className="btn-row">
          <label className="field" style={{ flex: 1 }}>
            <span>Start</span>
            <input
              className="field-input"
              type="time"
              aria-label="Start time"
              value={start}
              onChange={(e) => setStart(e.target.value)}
            />
          </label>
          <label className="field" style={{ flex: 1 }}>
            <span>End</span>
            <input
              className="field-input"
              type="time"
              aria-label="End time"
              value={end}
              onChange={(e) => setEnd(e.target.value)}
            />
          </label>
        </div>
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
            <span className="meta">Delete this job?</span>
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
            Delete job
          </button>
        )}
      </div>
    </Card>
  );
}

export default function JobDetailScreen() {
  const { id } = useParams();
  const { jobs, customers, invoices } = useData();
  const state = useResources('jobs');

  if (state.loading) return <Empty>Loading…</Empty>;
  if (state.error)
    return (
      <ErrorState
        message={`Couldn’t load this job: ${state.error}`}
        onRetry={state.retry}
      />
    );
  const job = jobs.find((j) => j.id === id);
  if (!job) return <Empty>Job not found.</Empty>;

  const badge = jobStatusBadge(job.status);
  const customer = customers.find((c) => c.id === job.customerId);
  const invoice = job.invoiceId
    ? invoices.find((i) => i.id === job.invoiceId)
    : undefined;

  const currentIdx = JOB_PIPELINE.indexOf(job.status);
  const materials = job.materials ?? [];

  return (
    <>
      <Link to="/jobs" className="back-link">
        ‹ Jobs
      </Link>

      <div className="page-head">
        <div>
          <h1>{job.title || job.customerName || 'Job'}</h1>
          <div className="sub">
            {job.customerName || 'No customer'}
            {job.scheduledDate ? ` · ${formatDisplayDate(job.scheduledDate)}` : ''}
          </div>
        </div>
        <div className="btn-row">
          {isArchived(job) && <Badge color="slate">Archived</Badge>}
          <Badge color={badge.color}>{badge.label}</Badge>
        </div>
      </div>

      <div className="detail-grid wide-main">
        <div className="stack">
          {job.description && (
            <Card pad>
              <div className="section-label" style={{ padding: '0 0 8px' }}>
                Description
              </div>
              <div className="muted">{job.description}</div>
            </Card>
          )}

          <Card pad>
            <div className="section-label" style={{ padding: '0 0 12px' }}>
              Status
            </div>
            <div className="timeline">
              {JOB_PIPELINE.map((s, idx) => {
                const state =
                  idx < currentIdx
                    ? 'done'
                    : idx === currentIdx
                      ? 'current'
                      : '';
                return (
                  <div key={s} className={`tl-step ${state}`.trim()}>
                    <span className="tl-dot" />
                    <span className="tl-label">
                      {jobStatusBadge(s).label}
                    </span>
                  </div>
                );
              })}
            </div>
            <StatusAdvance job={job} />
          </Card>

          {materials.length > 0 && (
            <Card>
              <div className="section-label">Materials</div>
              <div className="list">
                {materials.map((m) => (
                  <div key={m.id} className="row">
                    <div className="grow">
                      <div className="title">{m.name || 'Material'}</div>
                      <div className="meta">
                        Qty {m.quantity ?? 0} · {formatMoney(m.unitCost || 0)} ea
                      </div>
                    </div>
                    <span className="amt">
                      {formatMoney((m.quantity || 0) * (m.unitCost || 0))}
                    </span>
                  </div>
                ))}
              </div>
            </Card>
          )}

          {canAuthorEstimate(job) ? (
            <JobPricingEditor job={job} />
          ) : (
            <Card pad>
              <div className="section-label" style={{ padding: '0 0 8px' }}>
                Estimate
              </div>
              <KV k="Total" v={formatMoney(job.estimateTotal || 0)} />
              <div className="meta" style={{ marginTop: 8 }}>
                Locked — the customer has {job.approval?.decision} this estimate.
                Price changes go through a change order (mobile app).
              </div>
            </Card>
          )}
        </div>

        <div className="stack">
          <Card pad>
            <div className="section-label" style={{ padding: '0 0 8px' }}>
              Overview
            </div>
            <KV k="Estimate total" v={formatMoney(job.estimateTotal || 0)} />
            <KV k="Labor hours" v={String(job.laborHours ?? 0)} />
            {job.laborRate ? (
              <KV k="Labor rate" v={`${formatMoney(job.laborRate)}/hr`} />
            ) : null}
            {job.scheduledStartTime && (
              <KV
                k="Scheduled time"
                v={formatTimeRange(
                  job.scheduledStartTime,
                  job.scheduledEndTime,
                )}
              />
            )}
            {job.address && <KV k="Address" v={job.address} />}
          </Card>

          {customer && (
            <Card pad>
              <div className="section-label" style={{ padding: '0 0 8px' }}>
                Customer
              </div>
              <Link to={`/customers/${customer.id}`} className="title">
                {customer.name}
              </Link>
              {customer.phone && <div className="meta">{customer.phone}</div>}
              {customer.email && <div className="meta">{customer.email}</div>}
            </Card>
          )}

          {invoice && (
            <Card pad>
              <div className="section-label" style={{ padding: '0 0 8px' }}>
                Linked invoice
              </div>
              <Link to={`/invoices/${invoice.id}`} className="title">
                Invoice {invoice.number || invoice.id.slice(0, 6)}
              </Link>
              <div className="meta">{formatMoney(invoice.amount || 0)}</div>
            </Card>
          )}

          {job.notes && (
            <Card pad>
              <div className="section-label" style={{ padding: '0 0 8px' }}>
                Notes
              </div>
              <div className="muted">{job.notes}</div>
            </Card>
          )}

          <JobEditor job={job} />
        </div>
      </div>
    </>
  );
}
