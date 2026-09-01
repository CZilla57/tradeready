import { useMemo, useState } from 'react';
import { Link, useNavigate } from 'react-router-dom';
import { useData, useResources } from '../lib/DataContext';
import { Card, PageHead, Empty, Badge, ErrorState } from '../ui/components';
import { formatMoney } from '@shared/utils/format';
import { createPricebookEntry } from '../lib/writeRepository';
import { estimateTotalFromPricing } from '../ui/pricingMath';

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
 * The "New service" form (roadmap P3 stage 5 — creation flows). Creates a saved
 * service through `createPricebookEntry` (mobile-format id + createdAt/updatedAt)
 * and navigates to it. The derived `estimateTotal` is computed with the
 * pricingMath port over the entered pricing inputs (no materials yet) + the
 * owner's `minimumJobFee`, matching the mobile save. Follows the house UX:
 * in-flight disable, a failed write that stays open with the error.
 */
function NewServiceForm({ onClose }: { onClose: () => void }) {
  const { settings } = useData();
  const navigate = useNavigate();
  const [name, setName] = useState('');
  const [category, setCategory] = useState('');
  const [description, setDescription] = useState('');
  const [laborHours, setLaborHours] = useState('1');
  const [laborRate, setLaborRate] = useState(String(settings?.laborRate ?? 85));
  const [materialMarkup, setMaterialMarkup] = useState(String(settings?.materialMarkup ?? 20));
  const [overhead, setOverhead] = useState(String(settings?.overheadPercent ?? 15));
  const [margin, setMargin] = useState(String(settings?.marginPercent ?? 20));
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function onSave(e: React.FormEvent) {
    e.preventDefault();
    if (busy) return;
    if (!name.trim()) {
      setError('Give this service a name.');
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
    setBusy(true);
    setError(null);
    try {
      const estimateTotal = estimateTotalFromPricing({
        laborHours: pricing.laborHours!,
        laborRate: pricing.laborRate!,
        materials: [],
        materialMarkup: pricing.materialMarkup!,
        overheadPercent: pricing.overhead!,
        marginPercent: pricing.margin!,
        minimumJobFee: settings?.minimumJobFee ?? 75,
      });
      const created = await createPricebookEntry({
        name: name.trim(),
        category: category.trim(),
        description: description.trim(),
        laborHours: pricing.laborHours!,
        laborRate: pricing.laborRate!,
        materialMarkup: pricing.materialMarkup!,
        overhead: pricing.overhead!,
        margin: pricing.margin!,
        estimateTotal,
      });
      navigate(`/pricebook/${created.id}`);
    } catch (err) {
      setError(errorMessage(err));
      setBusy(false);
    }
  }

  return (
    <Card pad>
      <div className="section-label" style={{ padding: '0 0 10px' }}>
        New service
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
        <label className="field">
          <span>Category</span>
          <input className="field-input" type="text" value={category} onChange={(e) => setCategory(e.target.value)} />
        </label>
        <label className="field">
          <span>Description</span>
          <textarea className="field-input" rows={2} value={description} onChange={(e) => setDescription(e.target.value)} />
        </label>
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
        <div className="muted" style={{ fontSize: 12, fontWeight: 400 }}>
          The total is calculated from these. Material line items are added in the
          mobile app.
        </div>
        <div className="btn-row">
          <button type="submit" className="btn primary" disabled={busy}>
            {busy ? 'Creating…' : 'Create service'}
          </button>
          <button type="button" className="btn ghost" onClick={onClose} disabled={busy}>
            Cancel
          </button>
        </div>
      </form>
    </Card>
  );
}

export default function PricebookScreen() {
  const { pricebook } = useData();
  const state = useResources('pricebook');
  const [q, setQ] = useState('');
  const [creating, setCreating] = useState(false);

  const rows = useMemo(() => {
    const term = q.trim().toLowerCase();
    return [...pricebook]
      .filter(
        (p) =>
          !term ||
          p.name?.toLowerCase().includes(term) ||
          p.category?.toLowerCase().includes(term),
      )
      .sort((a, b) => (a.name || '').localeCompare(b.name || ''));
  }, [pricebook, q]);

  if (state.loading) return <Empty>Loading pricebook…</Empty>;
  if (state.error)
    return (
      <ErrorState
        message={`Couldn’t load pricebook: ${state.error}`}
        onRetry={state.retry}
      />
    );

  return (
    <>
      <PageHead
        title="Pricebook"
        sub={`${rows.length} saved services`}
        right={
          !creating && (
            <button type="button" className="btn sm" onClick={() => setCreating(true)}>
              New service
            </button>
          )
        }
      />
      {creating && <NewServiceForm onClose={() => setCreating(false)} />}
      <input
        className="search"
        placeholder="Search services or categories…"
        value={q}
        onChange={(e) => setQ(e.target.value)}
      />
      <Card>
        {rows.length === 0 ? (
          <Empty>No saved services yet.</Empty>
        ) : (
          <div className="list">
            {rows.map((p) => (
              <Link key={p.id} to={`/pricebook/${p.id}`} className="row">
                <div className="grow">
                  <div className="title">{p.name || 'Service'}</div>
                  <div className="meta">
                    {p.category ? `${p.category} · ` : ''}
                    {p.laborHours ?? 0} hr
                    {p.materials?.length
                      ? ` · ${p.materials.length} material${p.materials.length === 1 ? '' : 's'}`
                      : ''}
                  </div>
                </div>
                {p.category && <Badge color="slate">{p.category}</Badge>}
                <span className="amt">{formatMoney(p.estimateTotal || 0)}</span>
                <span className="chev">›</span>
              </Link>
            ))}
          </div>
        )}
      </Card>
    </>
  );
}
