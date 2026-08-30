import { useMemo, useState } from 'react';
import { Link } from 'react-router-dom';
import { useData, useResources } from '../lib/DataContext';
import { Card, PageHead, Empty, Badge, ErrorState } from '../ui/components';
import { formatMoney } from '@shared/utils/format';

export default function PricebookScreen() {
  const { pricebook } = useData();
  const state = useResources('pricebook');
  const [q, setQ] = useState('');

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
      <PageHead title="Pricebook" sub={`${rows.length} saved services`} />
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
