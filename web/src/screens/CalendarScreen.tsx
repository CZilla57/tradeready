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

const DOW = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

function timeKey(j: Job): string {
  return j.scheduledStartTime ?? '99:99';
}

const EMPTY_SETTINGS = {} as Settings;

export default function CalendarScreen() {
  const { jobs, settings } = useData();
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
            {needsScheduling.map((j) => {
              const b = jobStatusBadge(j.status);
              return (
                <Link key={j.id} to={`/jobs/${j.id}`} className="row">
                  <div className="grow">
                    <div className="title">
                      {j.title || j.customerName || 'Job'}
                    </div>
                    <div className="meta">{j.customerName || 'No customer'}</div>
                  </div>
                  <Badge color={b.color}>{b.label}</Badge>
                  <span className="amt">{formatMoney(j.estimateTotal || 0)}</span>
                </Link>
              );
            })}
          </div>
        )}
      </Card>
    </>
  );
}
