import { useMemo, useState } from 'react';
import { Link } from 'react-router-dom';
import { useData, useResources } from '../lib/DataContext';
import { Card, PageHead, Empty, Badge, ErrorState } from '../ui/components';
import { jobStatusBadge } from '../ui/status';
import { formatMoney } from '@shared/utils/format';
import { formatDisplayDate } from '@shared/utils/dateHelpers';
import type { Job, JobStatus } from '@shared/types/models';

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
  const { jobs } = useData();
  const state = useResources('jobs');
  const [filter, setFilter] = useState<Filter>('active');
  const [q, setQ] = useState('');

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
      <PageHead title="Jobs" sub={`${rows.length} shown`} />
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
