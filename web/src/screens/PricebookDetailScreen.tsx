import { Link, useParams } from 'react-router-dom';
import { useData, useResources } from '../lib/DataContext';
import { Card, Empty, KV, ErrorState } from '../ui/components';
import { formatMoney } from '@shared/utils/format';

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
    </>
  );
}
