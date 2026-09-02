import { useState } from 'react';
import { Link, useNavigate, useParams } from 'react-router-dom';
import { useData, useResources } from '../lib/DataContext';
import { Card, Empty, KV, ErrorState } from '../ui/components';
import { formatMoney } from '@shared/utils/format';
import type { PricebookEntry } from '@shared/types/models';
import { savePricebookEntry, deletePricebookEntry } from '../lib/writeRepository';
import { estimateTotalFromPricing } from '../ui/pricingMath';
import { MaterialsEditor } from '../ui/MaterialsEditor';
import {
  materialsToDrafts,
  parseMaterialDrafts,
  type MaterialDraft,
} from '../ui/materialsDraft';
import { JobCostsEditor } from '../ui/JobCostsEditor';
import {
  jobCostsToDrafts,
  parseJobCostDrafts,
  type JobCostDraft,
} from '../ui/jobCostsDraft';

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
 * Edit a saved service — metadata (name, category, description) AND pricing
 * inputs (labor hours/rate, material markup, overhead, margin) — and delete it
 * (roadmap P3 stage 4). `estimateTotal` is a DERIVED field: on save it is
 * recomputed with `estimateTotalFromPricing` (the web port of
 * `pricingEngine.calculateEstimate`) over the edited inputs plus the entry's
 * existing materials/jobCosts, using the owner's `minimumJobFee` from settings —
 * exactly the buildEstimateInput→calculateEstimate path the mobile
 * PricebookEntryScreen saves through (travel/tax 0, non-emergency), so a service
 * priced here matches one priced on the phone (P0.6). Material line items and
 * direct-cost lines are both editable via the shared `MaterialsEditor` /
 * `JobCostsEditor`; the edited lists feed the recompute and are written on the
 * entry.
 */
function PricebookEditor({ entry }: { entry: PricebookEntry }) {
  const { retry, settings } = useData();
  const navigate = useNavigate();

  const [open, setOpen] = useState(false);
  const [name, setName] = useState(entry.name ?? '');
  const [category, setCategory] = useState(entry.category ?? '');
  const [description, setDescription] = useState(entry.description ?? '');
  const [laborHours, setLaborHours] = useState(String(entry.laborHours ?? 0));
  const [laborRate, setLaborRate] = useState(String(entry.laborRate ?? 0));
  const [materialMarkup, setMaterialMarkup] = useState(String(entry.materialMarkup ?? 0));
  const [overhead, setOverhead] = useState(String(entry.overhead ?? 0));
  const [margin, setMargin] = useState(String(entry.margin ?? 0));
  const [materials, setMaterials] = useState<MaterialDraft[]>(
    materialsToDrafts(entry.materials),
  );
  const [jobCosts, setJobCosts] = useState<JobCostDraft[]>(
    jobCostsToDrafts(entry.jobCosts),
  );
  const [busy, setBusy] = useState<'save' | 'delete' | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [confirmDelete, setConfirmDelete] = useState(false);

  function openEditor() {
    setName(entry.name ?? '');
    setCategory(entry.category ?? '');
    setDescription(entry.description ?? '');
    setLaborHours(String(entry.laborHours ?? 0));
    setLaborRate(String(entry.laborRate ?? 0));
    setMaterialMarkup(String(entry.materialMarkup ?? 0));
    setOverhead(String(entry.overhead ?? 0));
    setMargin(String(entry.margin ?? 0));
    setMaterials(materialsToDrafts(entry.materials));
    setJobCosts(jobCostsToDrafts(entry.jobCosts));
    setError(null);
    setConfirmDelete(false);
    setOpen(true);
  }

  async function onSave(e: React.FormEvent) {
    e.preventDefault();
    if (busy) return;
    if (!name.trim()) {
      setError('Service name is required.');
      return;
    }
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
    const parsedJobCosts = parseJobCostDrafts(jobCosts);
    if (!parsedJobCosts.ok) {
      setError(parsedJobCosts.error);
      return;
    }
    setBusy('save');
    setError(null);
    try {
      // Recompute the derived total the same way the mobile save does
      // (travel/tax 0, non-emergency; minimumJobFee from the owner's settings),
      // now over the EDITED materials and direct-cost lines.
      const estimateTotal = estimateTotalFromPricing({
        laborHours: pricing.laborHours!,
        laborRate: pricing.laborRate!,
        materials: parsedMaterials.materials,
        materialMarkup: pricing.materialMarkup!,
        jobCosts: parsedJobCosts.jobCosts,
        overheadPercent: pricing.overhead!,
        marginPercent: pricing.margin!,
        minimumJobFee: settings?.minimumJobFee ?? 75,
      });
      await savePricebookEntry(
        {
          ...entry,
          name: name.trim(),
          category: category.trim(),
          description: description.trim(),
          laborHours: pricing.laborHours!,
          laborRate: pricing.laborRate!,
          materialMarkup: pricing.materialMarkup!,
          overhead: pricing.overhead!,
          margin: pricing.margin!,
          materials: parsedMaterials.materials,
          jobCosts: parsedJobCosts.jobCosts,
          estimateTotal,
        },
        entry,
      );
      retry(['pricebook']);
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
      await deletePricebookEntry(entry.id);
      navigate('/pricebook');
    } catch (err) {
      setError(errorMessage(err));
      setBusy(null);
    }
  }

  if (!open) {
    return (
      <Card pad>
        <button type="button" className="btn" onClick={openEditor}>
          Edit service
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
        Edit service
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
          <span>Category</span>
          <input
            className="field-input"
            type="text"
            value={category}
            onChange={(e) => setCategory(e.target.value)}
          />
        </label>
        <label className="field">
          <span>Description</span>
          <textarea
            className="field-input"
            rows={3}
            value={description}
            onChange={(e) => setDescription(e.target.value)}
          />
        </label>
        <div className="section-label" style={{ padding: '4px 0 0' }}>
          Pricing
        </div>
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
        <MaterialsEditor
          drafts={materials}
          onChange={setMaterials}
          disabled={busy !== null}
        />
        <JobCostsEditor
          drafts={jobCosts}
          onChange={setJobCosts}
          disabled={busy !== null}
        />
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
            <span className="meta">Delete this service?</span>
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
            Delete service
          </button>
        )}
      </div>
    </Card>
  );
}

export default function PricebookDetailScreen() {
  const { id } = useParams();
  const { pricebook } = useData();
  const state = useResources('pricebook');

  if (state.loading) return <Empty>Loading…</Empty>;
  if (state.error)
    return (
      <ErrorState
        message={`Couldn’t load this service: ${state.error}`}
        onRetry={state.retry}
      />
    );
  const entry = pricebook.find((p) => p.id === id);
  if (!entry) return <Empty>Service not found.</Empty>;

  const materials = entry.materials ?? [];

  return (
    <>
      <Link to="/pricebook" className="back-link">
        ‹ Pricebook
      </Link>

      <div className="page-head">
        <div>
          <h1>{entry.name || 'Service'}</h1>
          {entry.category && <div className="sub">{entry.category}</div>}
        </div>
        <span className="amt" style={{ fontSize: 22 }}>
          {formatMoney(entry.estimateTotal || 0)}
        </span>
      </div>

      <div className="detail-grid wide-main">
        <div className="stack">
          {entry.description && (
            <Card pad>
              <div className="section-label" style={{ padding: '0 0 8px' }}>
                Description
              </div>
              <div className="muted">{entry.description}</div>
            </Card>
          )}

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
        </div>

        <Card pad>
          <div className="section-label" style={{ padding: '0 0 8px' }}>
            Pricing
          </div>
          <KV k="Labor hours" v={String(entry.laborHours ?? 0)} />
          <KV k="Labor rate" v={`${formatMoney(entry.laborRate || 0)}/hr`} />
          <KV k="Material markup" v={`${entry.materialMarkup ?? 0}%`} />
          <KV k="Overhead" v={`${entry.overhead ?? 0}%`} />
          <KV k="Margin" v={`${entry.margin ?? 0}%`} />
          <KV k="Total" v={formatMoney(entry.estimateTotal || 0)} />
        </Card>
      </div>

      <div style={{ marginTop: 16 }}>
        <PricebookEditor entry={entry} />
      </div>
    </>
  );
}
