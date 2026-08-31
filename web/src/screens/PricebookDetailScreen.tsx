import { useState } from 'react';
import { Link, useNavigate, useParams } from 'react-router-dom';
import { useData, useResources } from '../lib/DataContext';
import { Card, Empty, KV, ErrorState } from '../ui/components';
import { formatMoney } from '@shared/utils/format';
import type { PricebookEntry } from '@shared/types/models';
import { savePricebookEntry, deletePricebookEntry } from '../lib/writeRepository';

function errorMessage(err: unknown): string {
  return err instanceof Error ? err.message : 'Something went wrong';
}

/**
 * Edit a saved service's metadata (name, category, description) and delete it
 * (roadmap P3 stage 4). Pricing fields are NOT edited here — `estimateTotal` is
 * derived by the pricing engine, which isn't cleanly web-importable, so pricing
 * edits are deferred. The full entry is passed with edits applied, so untouched
 * pricing fields round-trip.
 */
function PricebookEditor({ entry }: { entry: PricebookEntry }) {
  const { retry } = useData();
  const navigate = useNavigate();

  const [open, setOpen] = useState(false);
  const [name, setName] = useState(entry.name ?? '');
  const [category, setCategory] = useState(entry.category ?? '');
  const [description, setDescription] = useState(entry.description ?? '');
  const [busy, setBusy] = useState<'save' | 'delete' | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [confirmDelete, setConfirmDelete] = useState(false);

  function openEditor() {
    setName(entry.name ?? '');
    setCategory(entry.category ?? '');
    setDescription(entry.description ?? '');
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
    setBusy('save');
    setError(null);
    try {
      await savePricebookEntry({
        ...entry,
        name: name.trim(),
        category: category.trim(),
        description: description.trim(),
      });
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
        <div className="meta">
          Pricing (labor, materials, margins) is edited in the mobile app.
        </div>
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
