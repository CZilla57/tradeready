// __tests__/todayInsights.test.ts
// Pins the deterministic Today-insight rules from the 2026-08-04 spec
// (docs/superpowers/specs/2026-08-04-today-insights-design.md). Fixed clock
// throughout: Tue Aug 4 2026, 10:00 local → "tomorrow" is 2026-08-05.

import { selectTodayInsights } from '../utils/todayInsights';
import { resolveSchedule } from '../utils/scheduleConfig';
import { formatMoney } from '../utils/format';
import type { Job, Invoice, Customer, RecurringJob, Settings, Expense } from '../types/models';

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

function expense(overrides: Partial<Expense>): Expense {
  return {
    id: 'e1',
    createdAt: '2026-08-01',
    description: 'Supplies',
    amount: 100,
    category: 'materials',
    date: '2026-08-01',
    notes: '',
    receiptUri: null,
    ...overrides,
  };
}

/** Convenience: expense_anomaly is fed via the extras bag (5th arg). Filters to
 * the rule under test so an empty-jobs open_slot can't contaminate the count. */
function anomalyInsights(expenses: Expense[]) {
  return selectTodayInsights([], [], NOW, undefined, { expenses }).filter(
    (i) => i.kind === 'expense_anomaly'
  );
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

  test('detail reflects the billable total (estimate + approved change orders)', () => {
    const jobs = [job({
      status: 'complete', timeSessions: undefined,
      changeOrders: [{
        id: 'co1', title: 'Extra work', amount: 300, createdAt: '2026-08-01',
        manualDecision: { decision: 'approved', decidedAt: '2026-08-02' },
      }],
    })];
    const [insight] = selectTodayInsights(jobs, [], NOW);
    expect(insight.detail).toBe('$1,500 to bill'); // 1200 + 300, not $1,200
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

  test('a custom work window from Settings.schedule changes the gap math (Phase 11 A5)', () => {
    // Window ends 11:00 → only the 08:00–09:00 gap remains (60 min < 120) → silent
    const short = resolveSchedule({ schedule: { workDayEnd: '11:00' } } as unknown as Settings);
    expect(
      selectTodayInsights([tomorrowJob], [], NOW, short).filter(i => i.kind === 'open_slot')
    ).toHaveLength(0);
  });

  test('a blackout on tomorrow suppresses open_slot (Phase 11 A5)', () => {
    const off = resolveSchedule({
      schedule: { blackouts: [{ id: 'b1', start: '2026-08-05', end: '2026-08-05' }] },
    } as unknown as Settings);
    expect(
      selectTodayInsights([tomorrowJob], [], NOW, off).filter(i => i.kind === 'open_slot')
    ).toHaveLength(0);
  });

  test('a non-workday tomorrow suppresses open_slot (Phase 11 A5)', () => {
    // 2026-08-05 is a Wednesday; Monday-only workDays exclude it
    const monOnly = resolveSchedule({ schedule: { workDays: [1] } } as unknown as Settings);
    expect(
      selectTodayInsights([tomorrowJob], [], NOW, monOnly).filter(i => i.kind === 'open_slot')
    ).toHaveLength(0);
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

// Phase 15B: low_margin_estimate — implied margin from the job's own stored
// fields (labor hours × rate, marked-up materials, the job's own overhead %),
// compared against the Settings margin target on the same base the pricing
// engine applies margin to (costs + overhead).
describe('low_margin_estimate', () => {
  // laborCost 1000 (10h × $100), no materials, overhead 0 → implied margin
  // is simply (total − 1000) / 1000 × 100.
  const lowJob = (overrides: Partial<Job>) =>
    job({
      status: 'lead',
      laborHours: 10,
      laborRate: 100,
      materials: [],
      overhead: 0,
      ...overrides,
    });

  test('fires at exactly target − 3 points, silent a tenth above', () => {
    const atBoundary = selectTodayInsights([lowJob({ estimateTotal: 1170 })], [], NOW);
    expect(atBoundary).toHaveLength(1);
    expect(atBoundary[0].kind).toBe('low_margin_estimate');
    expect(atBoundary[0].title).toBe("'Faucet repair' is priced 3 points under your 20% margin");
    expect(atBoundary[0].detail).toBe('$170 profit on $1,170');
    expect(atBoundary[0].target).toEqual({ type: 'job', jobId: 'j1' });

    expect(selectTodayInsights([lowJob({ estimateTotal: 1171 })], [], NOW)).toHaveLength(0);
  });

  test('below break-even gets the severe copy with the shortfall', () => {
    const [insight] = selectTodayInsights([lowJob({ estimateTotal: 950 })], [], NOW);
    expect(insight.title).toBe("'Faucet repair' is priced below your costs and overhead");
    expect(insight.detail).toBe('$50 short of break-even');
  });

  test("overhead is allocated at the job's own percent", () => {
    // costBase 1000, overhead 15% → $150; total 1200 → $50 profit, 4.3% implied.
    const [insight] = selectTodayInsights([lowJob({ estimateTotal: 1200, overhead: 15 })], [], NOW);
    expect(insight.reason).toContain('overhead at 15% ($150)');
    expect(insight.reason).toContain('4.3%');
  });

  test('materials enter marked-up', () => {
    // 2 × $100 at 20% markup → $240; costBase 1240; total 1300 → $60 profit.
    const [insight] = selectTodayInsights(
      [lowJob({
        estimateTotal: 1300,
        materials: [{ id: 'm1', name: 'Pipe', quantity: 2, unitCost: 100 }],
        materialMarkup: 20,
      })],
      [],
      NOW
    );
    expect(insight.reason).toContain('materials $240');
    expect(insight.detail).toBe('$60 profit on $1,300');
  });

  test('only lead/estimate_sent qualify — approved jobs are contracted', () => {
    const approved = selectTodayInsights([lowJob({ estimateTotal: 1000, status: 'approved' })], [], NOW);
    expect(approved.map(i => i.kind)).not.toContain('low_margin_estimate');
    const sent = selectTodayInsights([lowJob({ estimateTotal: 1000, status: 'estimate_sent' })], [], NOW);
    expect(sent.map(i => i.kind)).toEqual(['low_margin_estimate']);
  });

  test('jobs without real pricing inputs are excluded, never guessed', () => {
    expect(selectTodayInsights([lowJob({ estimateTotal: 1000, laborHours: 0 })], [], NOW)).toHaveLength(0);
    expect(selectTodayInsights([lowJob({ estimateTotal: 1000, laborRate: 0 })], [], NOW)).toHaveLength(0);
    expect(selectTodayInsights([lowJob({ estimateTotal: 0 })], [], NOW)).toHaveLength(0);
  });

  test('one row: the worst offender, with the count of others in the detail', () => {
    const insights = selectTodayInsights(
      [
        lowJob({ id: 'mild', title: 'Mild', estimateTotal: 1100 }),
        lowJob({ id: 'bad', title: 'Bad', estimateTotal: 900 }),
      ],
      [],
      NOW
    );
    expect(insights).toHaveLength(1);
    expect(insights[0].title).toContain("'Bad'");
    expect(insights[0].detail).toContain('· 1 more under target');
  });

  test('honors a custom Settings margin target', () => {
    const jobs = [lowJob({ estimateTotal: 1400 })]; // implied 40%
    expect(selectTodayInsights(jobs, [], NOW)).toHaveLength(0); // default 20% target
    expect(
      selectTodayInsights(jobs, [], NOW, undefined, { targetMarginPercent: 50 })
    ).toHaveLength(1);
  });

  test('id embeds the price so a reprice resets an earlier dismissal', () => {
    const [insight] = selectTodayInsights([lowJob({ estimateTotal: 1170 })], [], NOW);
    expect(insight.id).toBe('low_margin_estimate:j1:1170');
  });

  test('coachPrompt carries the computed numbers and no customer identity', () => {
    const [insight] = selectTodayInsights([lowJob({ estimateTotal: 1170 })], [], NOW);
    expect(insight.coachPrompt).toContain('$1,170');
    expect(insight.coachPrompt).toContain('labor $1,000');
    expect(insight.coachPrompt).toContain('20% target');
    expect(insight.coachPrompt).not.toContain('Dana');
  });

  test('slots directly after labor_overrun in priority order', () => {
    const jobs = [
      job({ id: 'over', timeSessions: [session(5)] }),
      lowJob({ id: 'cheap', estimateTotal: 1000 }),
      job({ id: 'done', status: 'complete' }),
    ];
    const kinds = selectTodayInsights(jobs, [], NOW).map(i => i.kind);
    expect(kinds).toEqual(['labor_overrun', 'low_margin_estimate', 'uninvoiced_complete']);
  });
});

// Phase 15C: maintenance_due — last delivered job 6+ calendar months ago
// (local component math, DST-proof: Feb→Aug crosses a DST change), strict
// identity exclusions instead of guesses, suppressed while work is in motion.
describe('maintenance_due', () => {
  const customer = (overrides: Partial<Customer> = {}): Customer => ({
    id: 'c1',
    name: 'Dana Smith',
    email: '',
    phone: '555-1234',
    address: '',
    notes: '',
    ...overrides,
  });
  const rule = (overrides: Partial<RecurringJob> = {}): RecurringJob =>
    ({ id: 'rj1', customerId: 'c1', isActive: true, ...overrides } as RecurringJob);
  const historyJob = (overrides: Partial<Job> = {}) =>
    job({ id: 'h1', status: 'paid', scheduledDate: '2026-02-04', title: 'Furnace tune-up', ...overrides });
  const extras = (customers: Customer[], recurringJobs: RecurringJob[] = []) =>
    ({ customers, recurringJobs });

  test('fires at exactly 6 calendar months, silent a day short', () => {
    const due = selectTodayInsights([historyJob()], [], NOW, undefined, extras([customer()]));
    expect(due).toHaveLength(1);
    expect(due[0].kind).toBe('maintenance_due');
    expect(due[0].id).toBe('maintenance_due:c1');
    expect(due[0].title).toBe("It's been 6 months since you worked for Dana Smith");
    expect(due[0].detail).toBe('Last job: Furnace tune-up');
    expect(due[0].target).toEqual({ type: 'customer', customerId: 'c1' });

    const short = selectTodayInsights(
      [historyJob({ scheduledDate: '2026-02-05' })], [], NOW, undefined, extras([customer()])
    );
    expect(short).toHaveLength(0);
  });

  test('coachPrompt uses the first name only; reason carries the date math', () => {
    const [insight] = selectTodayInsights([historyJob()], [], NOW, undefined, extras([customer()]));
    expect(insight.coachPrompt).toContain('Dana');
    expect(insight.coachPrompt).not.toContain('Smith');
    expect(insight.reason).toContain('2026-02-04');
    expect(insight.reason).toContain('threshold: 6');
  });

  test('customers without a contact, or archived, are excluded', () => {
    expect(
      selectTodayInsights([historyJob()], [], NOW, undefined, extras([customer({ phone: ' ', email: '' })]))
    ).toHaveLength(0);
    expect(
      selectTodayInsights([historyJob()], [], NOW, undefined, extras([customer({ archivedAt: '2026-07-01' })]))
    ).toHaveLength(0);
  });

  test('anything in the active pipeline suppresses — unless that job is archived', () => {
    const inMotion = [historyJob(), job({ id: 'j2', status: 'scheduled', scheduledDate: null })];
    const active = selectTodayInsights(inMotion, [], NOW, undefined, extras([customer()]));
    expect(active.map(i => i.kind)).not.toContain('maintenance_due');

    const archived = [historyJob(), job({ id: 'j2', status: 'in_progress', archivedAt: '2026-07-01' })];
    const stillDue = selectTodayInsights(archived, [], NOW, undefined, extras([customer()]));
    expect(stillDue.map(i => i.kind)).toContain('maintenance_due');
  });

  test('an active recurring rule suppresses; an inactive one does not', () => {
    expect(
      selectTodayInsights([historyJob()], [], NOW, undefined, extras([customer()], [rule()]))
    ).toHaveLength(0);
    expect(
      selectTodayInsights([historyJob()], [], NOW, undefined, extras([customer()], [rule({ isActive: false })]))
    ).toHaveLength(1);
  });

  test('no delivered history means silence — never inferred', () => {
    // Lead-only history, unlinked (customerId "") history, and a delivered
    // job with no date all fail the join rather than guess.
    expect(
      selectTodayInsights([historyJob({ status: 'lead' })], [], NOW, undefined, extras([customer()]))
        .map(i => i.kind)
    ).not.toContain('maintenance_due');
    expect(
      selectTodayInsights([historyJob({ customerId: '' })], [], NOW, undefined, extras([customer()]))
    ).toHaveLength(0);
    expect(
      selectTodayInsights([historyJob({ scheduledDate: null })], [], NOW, undefined, extras([customer()]))
    ).toHaveLength(0);
    expect(selectTodayInsights([], [], NOW, undefined, extras([customer()]))).toHaveLength(0);
  });

  test('several due customers aggregate into one row targeting the Customers tab', () => {
    const insights = selectTodayInsights(
      [historyJob(), historyJob({ id: 'h2', customerId: 'c2', scheduledDate: '2025-11-01' })],
      [],
      NOW,
      undefined,
      extras([customer(), customer({ id: 'c2', name: 'Bob Reyes' })])
    );
    expect(insights).toHaveLength(1);
    expect(insights[0].id).toBe('maintenance_due:all');
    expect(insights[0].title).toBe("2 customers haven't been serviced in 6+ months");
    expect(insights[0].target).toEqual({ type: 'customers' });
  });

  test('rides last in priority order', () => {
    const jobs = [
      job({ id: 'left', status: 'approved', laborHours: 9, customerId: 'c2' }),
      historyJob(),
    ];
    const kinds = selectTodayInsights(jobs, [], NOW, undefined, extras([customer()])).map(i => i.kind);
    expect(kinds).toEqual(['unscheduled_approved', 'maintenance_due']);
  });
});

// Phase 15 foundation: every insight carries a stable dedup id (what
// dismissals/snoozes and analytics hang on) and a deterministic reason.
describe('insight identity and reasons', () => {
  test('every insight has a non-empty id and reason', () => {
    const jobs = [
      job({ id: 'over', timeSessions: [session(5)] }),
      job({ id: 'done', status: 'complete' }),
      job({ id: 'sched', status: 'scheduled', scheduledDate: '2026-08-05', scheduledStartTime: '09:00', scheduledEndTime: '11:00' }),
      job({ id: 'fit', status: 'approved', laborHours: 2 }),
      job({ id: 'left', status: 'approved', laborHours: 9 }),
    ];
    for (const insight of selectTodayInsights(jobs, [invoice({})], NOW)) {
      expect(insight.id).toBeTruthy();
      expect(insight.reason).toBeTruthy();
    }
  });

  test('single-record rows key on the record id; aggregates key on :all', () => {
    const one = selectTodayInsights([job({ id: 'done1', status: 'complete' })], [], NOW);
    expect(one[0].id).toBe('uninvoiced_complete:done1');

    const many = selectTodayInsights(
      [job({ id: 'done1', status: 'complete' }), job({ id: 'done2', status: 'complete' })],
      [],
      NOW
    );
    expect(many[0].id).toBe('uninvoiced_complete:all');

    const dueOne = selectTodayInsights([], [invoice({ id: 'i9' })], NOW);
    expect(dueOne[0].id).toBe('due_soon:i9');
  });

  test('labor_overrun and unscheduled_approved ids embed the job id; open_slot the date', () => {
    const jobs = [
      job({ id: 'over', timeSessions: [session(5)] }),
      job({ id: 'sched', status: 'scheduled', scheduledDate: '2026-08-05', scheduledStartTime: '09:00', scheduledEndTime: '11:00' }),
      job({ id: 'left', status: 'approved', laborHours: 9, title: 'Gutter clean' }),
    ];
    const ids = selectTodayInsights(jobs, [], NOW).map(i => i.id);
    expect(ids).toEqual(['labor_overrun:over', 'open_slot:2026-08-05', 'unscheduled_approved:left']);
  });

  test('reasons carry the deterministic rationale, numbers computed in code', () => {
    const [overrun] = selectTodayInsights([job({ timeSessions: [session(3.5)] })], [], NOW);
    expect(overrun.reason).toContain('3h 30m');
    expect(overrun.reason).toContain('2h labor estimate');

    const [due] = selectTodayInsights([], [invoice({ id: 'i9' })], NOW);
    expect(due.reason).toContain('INV-0042');
    expect(due.reason).toContain('due tomorrow');
  });
});

describe('expense_anomaly', () => {
  // NOW = Aug 4 2026. Current month 2026-08 (MTD through the 4th); prior three
  // full months = 2026-07, 2026-06, 2026-05.
  const priorEven = [
    expense({ id: 'p1', date: '2026-07-15', amount: 1000 }),
    expense({ id: 'p2', date: '2026-06-15', amount: 1000 }),
    expense({ id: 'p3', date: '2026-05-15', amount: 1000 }),
  ];

  test('fires above 1.5x the prior-3-month average, with % and money in the card', () => {
    const [i] = anomalyInsights([...priorEven, expense({ id: 'm', date: '2026-08-02', amount: 1600 })]);
    expect(i.kind).toBe('expense_anomaly');
    expect(i.id).toBe('expense_anomaly:2026-08');
    expect(i.title).toContain('60%'); // (1600-1000)/1000
    expect(i.detail).toBe(`${formatMoney(1600)} so far vs ${formatMoney(1000)} average`);
    expect(i.target).toEqual({ type: 'money' });
  });

  test('threshold is strictly greater than 1.5x — exactly 1.5x is silent', () => {
    expect(anomalyInsights([...priorEven, expense({ id: 'm', date: '2026-08-01', amount: 1500 })])).toHaveLength(0);
    expect(anomalyInsights([...priorEven, expense({ id: 'm', date: '2026-08-01', amount: 1501 })])).toHaveLength(1);
  });

  test('MTD below the $200 noise floor never fires, even at a huge ratio', () => {
    const prior = [
      expense({ id: 'p1', date: '2026-07-15', amount: 100 }),
      expense({ id: 'p2', date: '2026-06-15', amount: 100 }),
      expense({ id: 'p3', date: '2026-05-15', amount: 100 }),
    ];
    expect(anomalyInsights([...prior, expense({ id: 'm', date: '2026-08-01', amount: 199 })])).toHaveLength(0);
    expect(anomalyInsights([...prior, expense({ id: 'm', date: '2026-08-01', amount: 200 })])).toHaveLength(1);
  });

  test('requires all three prior months non-zero — a gap silences it', () => {
    const twoMonths = [
      expense({ id: 'p1', date: '2026-07-15', amount: 1000 }),
      expense({ id: 'p2', date: '2026-06-15', amount: 1000 }),
      // no 2026-05 record → that month totals 0
      expense({ id: 'm', date: '2026-08-01', amount: 5000 }),
    ];
    expect(anomalyInsights(twoMonths)).toHaveLength(0);
  });

  test('thin or empty history is silent', () => {
    expect(anomalyInsights([])).toHaveLength(0);
    expect(anomalyInsights([expense({ date: '2026-07-15', amount: 1000 })])).toHaveLength(0);
  });

  test('MTD is to-date — a future-dated current-month expense is excluded', () => {
    const withFuture = [
      ...priorEven,
      expense({ id: 'now', date: '2026-08-02', amount: 1400 }),
      expense({ id: 'future', date: '2026-08-20', amount: 1000 }), // after today (the 4th)
    ];
    // Counting only the 08-02 $1400 leaves MTD 1400 ≤ 1.5×1000 → silent.
    expect(anomalyInsights(withFuture)).toHaveLength(0);
  });

  test('reason names the biggest-driver category', () => {
    const perMonth = (ym: string) => [
      expense({ id: `mat-${ym}`, date: `${ym}-15`, amount: 900, category: 'materials' }),
      expense({ id: `fuel-${ym}`, date: `${ym}-15`, amount: 100, category: 'fuel' }),
    ];
    const expenses = [
      ...perMonth('2026-07'), ...perMonth('2026-06'), ...perMonth('2026-05'),
      expense({ id: 'mat-08', date: '2026-08-02', amount: 900, category: 'materials' }),
      expense({ id: 'fuel-08', date: '2026-08-02', amount: 1200, category: 'fuel' }), // the spike
    ];
    const [i] = anomalyInsights(expenses);
    expect(i).toBeDefined();
    expect(i.reason).toContain('Fuel & Transport');
  });

  test('rides last in priority order, after job/invoice rows', () => {
    const overrunJob = job({ timeSessions: [session(3.5)] }); // 3.5h vs 2h estimate → labor_overrun
    const insights = selectTodayInsights([overrunJob], [], NOW, undefined, {
      expenses: [...priorEven, expense({ id: 'm', date: '2026-08-02', amount: 1600 })],
    });
    expect(insights.length).toBeGreaterThan(1);
    expect(insights[0].kind).toBe('labor_overrun');
    expect(insights[insights.length - 1].kind).toBe('expense_anomaly');
  });
});
