// __tests__/todayInsights.test.ts
// Pins the deterministic Today-insight rules from the 2026-08-04 spec
// (docs/superpowers/specs/2026-08-04-today-insights-design.md). Fixed clock
// throughout: Tue Aug 4 2026, 10:00 local → "tomorrow" is 2026-08-05.

import { selectTodayInsights } from '../utils/todayInsights';
import type { Job, Invoice } from '../types/models';

const NOW = new Date(2026, 7, 4, 10, 0);

function job(overrides: Partial<Job>): Job {
  return {
    id: 'j1',
    customerId: 'c1',
    customerName: 'Dana',
    title: 'Faucet repair',
    description: '',
    status: 'in_progress',
    scheduledDate: null,
    scheduledStartTime: null,
    scheduledEndTime: null,
    address: '',
    estimateTotal: 1200,
    laborHours: 2,
    laborRate: 85,
    materials: [],
    materialMarkup: 20,
    overhead: 15,
    margin: 20,
    notes: '',
    invoiceId: null,
    createdAt: '2026-08-01',
    ...overrides,
  };
}

function invoice(overrides: Partial<Invoice>): Invoice {
  return {
    id: 'i1',
    customer: 'Dana',
    number: 'INV-0042',
    amount: 850,
    due: '2026-08-05',
    email: '',
    phone: '',
    desc: '',
    paid: false,
    ...overrides,
  };
}

/** An ended clock session of exactly `hours` on Aug 4. */
function session(hours: number) {
  const startMs = new Date(2026, 7, 4, 6, 0).getTime();
  return { start: new Date(startMs).toISOString(), end: new Date(startMs + hours * 3600000).toISOString() };
}

describe('labor_overrun', () => {
  test('fires at 15 minutes over, with elapsed and estimate in the title', () => {
    const jobs = [job({ timeSessions: [session(2.25)] })];
    const [insight] = selectTodayInsights(jobs, [], NOW);
    expect(insight.kind).toBe('labor_overrun');
    expect(insight.title).toBe("'Faucet repair' is 15m over its 2h labor estimate");
    expect(insight.target).toEqual({ type: 'job', jobId: 'j1' });
  });

  test('quarter-hour floor: 14 minutes over is silent', () => {
    const jobs = [job({ timeSessions: [session(2 + 14 / 60)] })];
    expect(selectTodayInsights(jobs, [], NOW)).toHaveLength(0);
  });

  test('coachPrompt carries tracked time, estimate, rate and total', () => {
    const [insight] = selectTodayInsights([job({ timeSessions: [session(3.5)] })], [], NOW);
    expect(insight.coachPrompt).toContain('3h 30m');
    expect(insight.coachPrompt).toContain('2h labor estimate');
    expect(insight.coachPrompt).toContain('$85.00/hr');
    expect(insight.coachPrompt).toContain('$1,200');
  });

  test('completed, archived, and zero-estimate jobs are excluded', () => {
    const sessions = [session(5)];
    expect(selectTodayInsights([job({ status: 'complete', invoiceId: 'i9', timeSessions: sessions })], [], NOW)).toHaveLength(0);
    expect(selectTodayInsights([job({ archivedAt: '2026-08-03', timeSessions: sessions })], [], NOW)).toHaveLength(0);
    expect(selectTodayInsights([job({ laborHours: 0, timeSessions: sessions })], [], NOW)).toHaveLength(0);
  });
});

describe('uninvoiced_complete', () => {
  test('single job: create-invoice target and a formatQuote detail', () => {
    const jobs = [job({ status: 'complete', timeSessions: undefined })];
    const [insight] = selectTodayInsights(jobs, [], NOW);
    expect(insight.kind).toBe('uninvoiced_complete');
    expect(insight.title).toBe("'Faucet repair' is complete but not invoiced");
    expect(insight.detail).toBe('$1,200 to bill');
    expect(insight.target).toEqual({ type: 'createInvoice', jobId: 'j1' });
  });

  test('several jobs aggregate to one row targeting the Jobs tab', () => {
    const jobs = [
      job({ id: 'a', status: 'complete' }),
      job({ id: 'b', status: 'complete', title: 'Deck repair' }),
    ];
    const [insight] = selectTodayInsights(jobs, [], NOW);
    expect(insight.title).toBe("2 completed jobs haven't been invoiced");
    expect(insight.target).toEqual({ type: 'jobs' });
  });

  test('invoiced or archived complete jobs are excluded', () => {
    expect(selectTodayInsights([job({ status: 'complete', invoiceId: 'i1' })], [], NOW)).toHaveLength(0);
    expect(selectTodayInsights([job({ status: 'complete', archivedAt: '2026-08-01' })], [], NOW)).toHaveLength(0);
  });
});

describe('due_soon', () => {
  test.each([
    ['2026-08-04', 'today'],
    ['2026-08-05', 'tomorrow'],
    ['2026-08-06', 'in 2 days'],
  ])('due %s reads "due %s"', (due, label) => {
    const [insight] = selectTodayInsights([], [invoice({ due })], NOW);
    expect(insight.kind).toBe('due_soon');
    expect(insight.title).toBe(`Invoice INV-0042 ($850.00) is due ${label}`);
    expect(insight.target).toEqual({ type: 'invoice', invoiceId: 'i1' });
  });

  test('outside the window: 3 days out and already-overdue are both silent', () => {
    expect(selectTodayInsights([], [invoice({ due: '2026-08-07' })], NOW)).toHaveLength(0);
    expect(selectTodayInsights([], [invoice({ due: '2026-08-03' })], NOW)).toHaveLength(0); // Overdue section owns it
  });

  test('fully paid invoices are silent; aggregates sum balanceDue', () => {
    expect(selectTodayInsights([], [invoice({ paid: true })], NOW)).toHaveLength(0);
    const invs = [
      invoice({ id: 'a', amount: 850 }),
      invoice({ id: 'b', number: 'INV-0043', amount: 600, due: '2026-08-06',
                payments: [{ id: 'p1', amount: 100, date: '2026-08-01', method: 'cash' }] }),
    ];
    const [insight] = selectTodayInsights([], invs, NOW);
    expect(insight.title).toBe('$1,350.00 across 2 invoices is due within 2 days');
    expect(insight.target).toEqual({ type: 'invoices' });
  });
});

describe('open_slot', () => {
  const tomorrowJob = job({
    id: 'sched', status: 'scheduled', scheduledDate: '2026-08-05',
    scheduledStartTime: '09:00', scheduledEndTime: '11:00',
  });

  test('fires with the largest gap when tomorrow has a scheduled job', () => {
    const [insight] = selectTodayInsights([tomorrowJob], [], NOW);
    expect(insight.kind).toBe('open_slot');
    expect(insight.title).toBe('Tomorrow has a 6h open slot'); // 11:00–17:00
    expect(insight.target).toEqual({ type: 'selectDate', date: '2026-08-05' });
  });

  test('names the largest fitting approved unscheduled job and targets its schedule editor', () => {
    const jobs = [
      tomorrowJob,
      job({ id: 'fitS', status: 'approved', title: 'Small fix', laborHours: 1 }),
      job({ id: 'fitL', status: 'approved', title: 'Fence gate', laborHours: 4 }),
      job({ id: 'huge', status: 'approved', title: 'Full remodel', laborHours: 9 }),
    ];
    const insights = selectTodayInsights(jobs, [], NOW);
    expect(insights[0].title).toBe("Tomorrow has a 6h open slot — 'Fence gate' (4h) would fit");
    expect(insights[0].target).toEqual({ type: 'schedule', jobId: 'fitL' });
  });

  test('empty tomorrow and sub-2h gaps are silent', () => {
    expect(selectTodayInsights([job({ status: 'approved' })], [], NOW)
      .filter(i => i.kind === 'open_slot')).toHaveLength(0);
    const packed = [
      job({ id: 'a', status: 'scheduled', scheduledDate: '2026-08-05', scheduledStartTime: '08:00', scheduledEndTime: '12:01' }),
      job({ id: 'b', status: 'scheduled', scheduledDate: '2026-08-05', scheduledStartTime: '14:00', scheduledEndTime: '17:00' }),
    ];
    expect(selectTodayInsights(packed, [], NOW).filter(i => i.kind === 'open_slot')).toHaveLength(0); // 119 min
  });

  test('exactly 120 minutes fires', () => {
    const jobs = [
      job({ id: 'a', status: 'scheduled', scheduledDate: '2026-08-05', scheduledStartTime: '08:00', scheduledEndTime: '12:00' }),
      job({ id: 'b', status: 'scheduled', scheduledDate: '2026-08-05', scheduledStartTime: '14:00', scheduledEndTime: '17:00' }),
    ];
    const [insight] = selectTodayInsights(jobs, [], NOW);
    expect(insight.title).toBe('Tomorrow has a 2h open slot');
  });

  test('ties on laborHours keep array order (Array.prototype.sort is stable)', () => {
    const jobs = [
      tomorrowJob,
      job({ id: 'first', status: 'approved', title: 'First fix', laborHours: 3 }),
      job({ id: 'second', status: 'approved', title: 'Second fix', laborHours: 3 }),
    ];
    const [insight] = selectTodayInsights(jobs, [], NOW);
    expect(insight.title).toBe("Tomorrow has a 6h open slot — 'First fix' (3h) would fit");
    expect(insight.target).toEqual({ type: 'schedule', jobId: 'first' });
  });
});

describe('unscheduled_approved', () => {
  test('single job targets its schedule editor; several aggregate to Jobs', () => {
    const [single] = selectTodayInsights([job({ id: 'u1', status: 'approved', title: 'Fence gate' })], [], NOW);
    expect(single.kind).toBe('unscheduled_approved');
    expect(single.title).toBe("'Fence gate' is approved but not scheduled");
    expect(single.target).toEqual({ type: 'schedule', jobId: 'u1' });

    const [multi] = selectTodayInsights([
      job({ id: 'u1', status: 'approved' }),
      job({ id: 'u2', status: 'approved' }),
    ], [], NOW);
    expect(multi.title).toBe("2 approved jobs aren't on the schedule yet");
    expect(multi.target).toEqual({ type: 'jobs' });
  });

  test('the job consumed by open_slot never double-counts', () => {
    const jobs = [
      job({ id: 'sched', status: 'scheduled', scheduledDate: '2026-08-05', scheduledStartTime: '09:00', scheduledEndTime: '11:00' }),
      job({ id: 'fit', status: 'approved', title: 'Fence gate', laborHours: 4 }),
      job({ id: 'left', status: 'approved', title: 'Gutter clean', laborHours: 9 }),
    ];
    const insights = selectTodayInsights(jobs, [], NOW);
    const kinds = insights.map(i => i.kind);
    expect(kinds).toEqual(['open_slot', 'unscheduled_approved']);
    expect(insights[1].title).toBe("'Gutter clean' is approved but not scheduled");
  });
});

describe('priority order', () => {
  test('all five kinds arrive in spec order', () => {
    const jobs = [
      job({ id: 'over', timeSessions: [session(5)] }),
      job({ id: 'done', status: 'complete' }),
      job({ id: 'sched', status: 'scheduled', scheduledDate: '2026-08-05', scheduledStartTime: '09:00', scheduledEndTime: '11:00' }),
      job({ id: 'fit', status: 'approved', laborHours: 2 }),
      job({ id: 'left', status: 'approved', laborHours: 9 }),
    ];
    const kinds = selectTodayInsights(jobs, [invoice({})], NOW).map(i => i.kind);
    expect(kinds).toEqual(['labor_overrun', 'uninvoiced_complete', 'due_soon', 'open_slot', 'unscheduled_approved']);
  });
});
