import { useMemo, useState } from 'react';
import { Link } from 'react-router-dom';
import { useData } from '../lib/DataContext';
import { Card, PageHead, Empty, Badge } from '../ui/components';
import { estimateStatusBadge, isEstimateJob } from '../ui/status';
import { formatMoney } from '@shared/utils/format';
import { formatDisplayDate } from '@shared/utils/dateHelpers';

type Filter = 'all' | 'sent' | 'approved' | 'declined';

export default function EstimatesScreen() {
  const { jobs, loading, error } = useData();
  const [filter, setFilter] = useState<Filter>('all');
  const [q, setQ] = useState('');

  const rows = useMemo(() => {
    const term = q.trim().toLowerCase();
    return jobs
      .filter((j) => !j.archivedAt && isEstimateJob(j))
      .filter((j) => {
        if (filter === 'all') return true;
        const label = estimateStatusBadge(j).label.toLowerCase();
        return label === filter;
      })
      .filter(
        (j) =>
          !term ||
          j.title?.toLowerCase().includes(term) ||
          j.customerName?.toLowerCase().includes(term),
      )
      .sort((a, b) =>
        (b.estimateSentAt || b.createdAt || '').localeCompare(
          a.estimateSentAt || a.createdAt || '',
        ),
      );
  }, [jobs, filter, q]);

  if (loading) return <Empty>Loading estimates…</Empty>;
  if (error) return <Empty>Couldn’t load estimates: {error}</Empty>;

  const FILTERS: { key: Filter; label: string }[] = [
    { key: 'all', label: 'All' },
    { key: 'sent', label: 'Sent' },
    { key: 'approved', label: 'Approved' },
    { key: 'declined', label: 'Declined' },
  ];

  return (
    <>
      <PageHead title="Estimates" sub={`${rows.length} shown`} />
      <input
        className="search"
        placeholder="Search estimates or customers…"
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
          <Empty>No estimates match.</Empty>
        ) : (
          <div className="list">
            {rows.map((j) => {
              const b = estimateStatusBadge(j);
              const when = j.estimateSentAt || j.createdAt;
              return (
                <Link key={j.id} to={`/estimates/${j.id}`} className="row">
                  <div className="grow">
                    <div className="title">
                      {j.title || j.customerName || 'Estimate'}
                    </div>
                    <div className="meta">
                      {j.customerName || 'No customer'}
                      {when ? ` · ${formatDisplayDate(when)}` : ''}
                    </div>
                  </div>
                  <Badge color={b.color}>{b.label}</Badge>
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
