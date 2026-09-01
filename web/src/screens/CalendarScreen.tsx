import { useMemo, useState } from 'react';
import { Link } from 'react-router-dom';
import { useData, useResources } from '../lib/DataContext';
import { Card, PageHead, Empty, Badge, ErrorState } from '../ui/components';
import { jobStatusBadge } from '../ui/status';
import { formatMoney } from '@shared/utils/format';
import {
  getTodayDateString,
  getWeekDates,
  weekMonthLabel,
  shiftDate,
  formatTimeRange,
} from '@shared/utils/dateHelpers';
import {
  resolveSchedule,
  isWorkDay,
  isBlackoutDate,
} from '@shared/utils/scheduleConfig';
import type { Job, Settings } from '@shared/types/models';
import { scheduleJob } from '../lib/writeRepository';

const DOW = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

function timeKey(j: Job): string {
  return j.scheduledStartTime ?? '99:99';
}

function errorMessage(err: unknown): string {
  return err instanceof Error ? err.message : 'Something went wrong';
}

const EMPTY_SETTINGS = {} as Settings;

/**
 * An inline "assign a date" scheduler for a job that needs one (roadmap P3
 * stage 5b). Collapsed, it's a link to the job plus a Schedule button; expanded,
 * a date (required) + optional start/end time form. Saving goes through
 * `scheduleJob`, which applies the date onto the fresh server row and advances
 * an approved job to `scheduled` (P0.6). Follows the InvoiceDetailScreen UX:
 * in-flight disable, a failed write that stays open with the error, and a server
 * re-pull on success handled by the caller.
 */
function NeedsSchedulingRow({
  job,
  defaultDate,
  onScheduled,
}: {
  job: Job;
  defaultDate: string;
  onScheduled: () => void;
}) {
  const [open, setOpen] = useState(false);
  const [date, setDate] = useState(defaultDate);
  const [start, setStart] = useState('');
  const [end, setEnd] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  function openForm() {
    setDate(job.scheduledDate || defaultDate);
    setStart(job.scheduledStartTime || '');
    setEnd(job.scheduledEndTime || '');
    setError(null);
    setOpen(true);
  }

  async function onSave(e: React.FormEvent) {
    e.preventDefault();
    if (busy) return;
    if (!date) {
      setError('Pick a date.');
      return;
    }
    if (end && !start) {
      setError('Set a start time too, or clear the end time.');
      return;
    }
    if (start && end && end <= start) {
      setError('End time must be after the start time.');
      return;
    }
    setBusy(true);
    setError(null);
    try {
      await scheduleJob(job.id, {
        scheduledDate: date,
        scheduledStartTime: start || null,
        scheduledEndTime: end || null,
      });
      onScheduled();
      setOpen(false);
    } catch (err) {
      setError(errorMessage(err));
    } finally {
      setBusy(false);
    }
  }

  if (!open) {
    const b = jobStatusBadge(job.status);
    return (
      <div className="row">
        <Link to={`/jobs/${job.id}`} className="grow">
          <div className="title">{job.title || job.customerName || 'Job'}</div>
          <div className="meta">{job.customerName || 'No customer'}</div>
        </Link>
        <Badge color={b.color}>{b.label}</Badge>
        <span className="amt">{formatMoney(job.estimateTotal || 0)}</span>
        <button type="button" className="btn sm" onClick={openForm}>
          Schedule
        </button>
      </div>
    );
  }

  return (
    <div className="row" style={{ flexWrap: 'wrap' }}>
      <div className="grow" style={{ minWidth: 220 }}>
        <div className="title">{job.title || job.customerName || 'Job'}</div>
        {error && (
          <div className="inline-alert error" role="alert" style={{ marginTop: 6 }}>
            {error}
          </div>
        )}
        <form className="pay-form" style={{ marginTop: 8, borderTop: 0, paddingTop: 0 }} onSubmit={onSave}>
          <label className="field">
            <span>Date</span>
            <input className="field-input" type="date" value={date} onChange={(e) => setDate(e.target.value)} />
          </label>
          <div className="btn-row">
            <label className="field" style={{ flex: 1 }}>
              <span>Start (optional)</span>
              <input className="field-input" type="time" value={start} onChange={(e) => setStart(e.target.value)} />
            </label>
            <label className="field" style={{ flex: 1 }}>
              <span>End (optional)</span>
              <input className="field-input" type="time" value={end} onChange={(e) => setEnd(e.target.value)} />
            </label>
          </div>
          <div className="btn-row">
            <button type="submit" className="btn primary sm" disabled={busy}>
              {busy ? 'Scheduling…' : 'Schedule job'}
            </button>
            <button type="button" className="btn ghost sm" onClick={() => setOpen(false)} disabled={busy}>
              Cancel
            </button>
          </div>
        </form>
      </div>
    </div>
  );
}

export default function CalendarScreen() {
  const { jobs, settings, retry } = useData();
  // Calendar needs jobs; settings only shade work days/blackouts, so a settings
  // failure falls back to an unshaded grid rather than an empty screen.
  const state = useResources('jobs');
  const today = getTodayDateString();
  const [anchor, setAnchor] = useState(today);

  const schedule = useMemo(
    () => resolveSchedule(settings ?? EMPTY_SETTINGS),
    [settings],
  );
  const week = useMemo(() => getWeekDates(anchor), [anchor]);

  const byDate = useMemo(() => {
    const map = new Map<string, Job[]>();
    for (const j of jobs) {
      if (j.archivedAt || !j.scheduledDate) continue;
      const arr = map.get(j.scheduledDate) ?? [];
      arr.push(j);
      map.set(j.scheduledDate, arr);
    }
    for (const arr of map.values())
      arr.sort((a, b) => timeKey(a).localeCompare(timeKey(b)));
    return map;
  }, [jobs]);

  const needsScheduling = useMemo(
    () =>
      jobs
        .filter(
          (j) =>
            !j.archivedAt &&
            !j.scheduledDate &&
            (j.status === 'approved' || j.status === 'scheduled'),
        )
        .sort((a, b) => (b.createdAt || '').localeCompare(a.createdAt || '')),
    [jobs],
  );

  if (state.loading) return <Empty>Loading calendar…</Empty>;
  if (state.error)
    return (
      <ErrorState
        message={`Couldn’t load calendar: ${state.error}`}
        onRetry={state.retry}
      />
    );

  return (
    <>
      <PageHead
        title="Calendar"
        sub={weekMonthLabel(week)}
        right={
          <div className="week-nav">
            <button
              type="button"
              aria-label="Previous week"
              onClick={() => setAnchor(shiftDate(anchor, -7))}
            >
              <span aria-hidden="true">‹</span>
            </button>
            <button type="button" onClick={() => setAnchor(today)}>
              Today
            </button>
            <button
              type="button"
              aria-label="Next week"
              onClick={() => setAnchor(shiftDate(anchor, 7))}
            >
              <span aria-hidden="true">›</span>
            </button>
          </div>
        }
      />

      <div className="week-grid">
        {week.map((date, i) => {
          const dayJobs = byDate.get(date) ?? [];
          const off = !isWorkDay(schedule, date) || isBlackoutDate(schedule, date);
          const isToday = date === today;
          return (
            <div
              key={date}
              className={`day-col ${off ? 'off' : ''} ${isToday ? 'today' : ''}`.trim()}
            >
              <div className="day-head">
                <span className="dow">{DOW[i]}</span>
                <span className="dom">{Number(date.slice(8, 10))}</span>
              </div>
              {dayJobs.length === 0 ? (
                <div className="day-empty">{off ? 'Off' : '—'}</div>
              ) : (
                dayJobs.map((j) => (
                  <Link key={j.id} to={`/jobs/${j.id}`} className="day-job">
                    <div className="dj-time">
                      {j.scheduledStartTime
                        ? formatTimeRange(
                            j.scheduledStartTime,
                            j.scheduledEndTime,
                          )
                        : 'Anytime'}
                    </div>
                    <div className="dj-title">
                      {j.title || j.customerName || 'Job'}
                    </div>
                  </Link>
                ))
              )}
            </div>
          );
        })}
      </div>

      <Card style={{ marginTop: 18 }}>
        <div className="section-label">
          Needs scheduling ({needsScheduling.length})
        </div>
        {needsScheduling.length === 0 ? (
          <Empty>Every approved job has a date. Nice.</Empty>
        ) : (
          <div className="list">
            {needsScheduling.map((j) => (
              <NeedsSchedulingRow
                key={j.id}
                job={j}
                defaultDate={today}
                onScheduled={() => retry(['jobs'])}
              />
            ))}
          </div>
        )}
      </Card>
    </>
  );
}
