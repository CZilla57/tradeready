// __tests__/scheduleSmarts.test.ts
// Pins the labor-aware scheduling rules from the 2026-08-01 smart-schedule-
// pickers spec: end = start + labor rounded UP to 15 min, 08:00 default for
// non-today dates, next half-hour for today, and non-blocking overlap
// detection that ignores terminal-status jobs.

import {
  addLaborToStart,
  defaultStartTime,
  defaultEndTime,
  formatLaborHint,
  findScheduleConflicts,
} from '../utils/scheduleSmarts';
import type { Job } from '../types/models';

function job(overrides: Partial<Job>): Job {
  return {
    id: 'j_other',
    customerId: 'c1',
    customerName: 'A',
    title: 'Faucet repair',
    description: '',
    status: 'scheduled',
    scheduledDate: '2026-08-03',
    scheduledStartTime: '09:00',
    scheduledEndTime: '11:00',
    address: '',
    estimateTotal: 0,
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

describe('addLaborToStart', () => {
  test('whole hours landing on a boundary stay put', () => {
    expect(addLaborToStart('09:00', 2)).toBe('11:00');
  });

  test('fractional hours round UP to the next 15-minute boundary', () => {
    expect(addLaborToStart('09:00', 1.7)).toBe('10:45'); // 10:42 → 10:45
    expect(addLaborToStart('09:10', 2.5)).toBe('11:45'); // 11:40 → 11:45
    expect(addLaborToStart('09:05', 0.25)).toBe('09:30'); // 09:20 → 09:30
  });

  test('never crosses midnight — clamps to 23:59', () => {
    expect(addLaborToStart('22:00', 3)).toBe('23:59');
  });
});

describe('defaultStartTime', () => {
  const today2pm12 = new Date(2026, 7, 1, 14, 12); // Aug 1 2026, 2:12 PM local

  test('non-today date (future or past) → 08:00', () => {
    expect(defaultStartTime('2026-08-05', today2pm12)).toBe('08:00');
    expect(defaultStartTime('2026-07-20', today2pm12)).toBe('08:00');
  });

  test('today → next half-hour boundary', () => {
    expect(defaultStartTime('2026-08-01', today2pm12)).toBe('14:30');
    expect(defaultStartTime('2026-08-01', new Date(2026, 7, 1, 14, 30))).toBe('14:30');
    expect(defaultStartTime('2026-08-01', new Date(2026, 7, 1, 14, 47))).toBe('15:00');
  });

  test('empty date behaves like today', () => {
    expect(defaultStartTime('', today2pm12)).toBe('14:30');
  });

  test('late night clamps to 23:30', () => {
    expect(defaultStartTime('', new Date(2026, 7, 1, 23, 45))).toBe('23:30');
  });
});

describe('defaultEndTime', () => {
  test('uses labor hours when priced', () => {
    expect(defaultEndTime('09:00', 2.5)).toBe('11:30');
  });

  test('falls back to 1 hour when unpriced', () => {
    expect(defaultEndTime('09:00', 0)).toBe('10:00');
  });
});

describe('formatLaborHint', () => {
  test('whole hours', () => {
    expect(formatLaborHint(2)).toBe('2h');
  });
  test('mixed hours and minutes', () => {
    expect(formatLaborHint(2.5)).toBe('2h 30m');
  });
  test('sub-hour', () => {
    expect(formatLaborHint(0.25)).toBe('15m');
  });
});

describe('findScheduleConflicts', () => {
  const base = { date: '2026-08-03', start: '10:00', end: '12:00', laborHours: 2 };

  test('detects an overlapping window on the same date', () => {
    expect(findScheduleConflicts([job({})], base)).toHaveLength(1);
  });

  test('windows that merely touch do NOT conflict', () => {
    // other job 09:00–10:00, candidate starts 10:00
    expect(
      findScheduleConflicts([job({ scheduledEndTime: '10:00' })], base)
    ).toHaveLength(0);
  });

  test('different dates never conflict', () => {
    expect(
      findScheduleConflicts([job({ scheduledDate: '2026-08-04' })], base)
    ).toHaveLength(0);
  });

  test('a job with no start time never conflicts', () => {
    expect(
      findScheduleConflicts(
        [job({ scheduledStartTime: null, scheduledEndTime: null })],
        base
      )
    ).toHaveLength(0);
  });

  test('terminal statuses are history — excluded', () => {
    expect(findScheduleConflicts([job({ status: 'complete' })], base)).toHaveLength(0);
    expect(findScheduleConflicts([job({ status: 'invoiced' })], base)).toHaveLength(0);
    expect(findScheduleConflicts([job({ status: 'paid' })], base)).toHaveLength(0);
    expect(findScheduleConflicts([job({ status: 'declined' })], base)).toHaveLength(0);
  });

  test('the job being edited is excluded via excludeJobId', () => {
    expect(
      findScheduleConflicts([job({ id: 'j_me' })], { ...base, excludeJobId: 'j_me' })
    ).toHaveLength(0);
  });

  test('other job missing end time blocks max(laborHours, 1h)', () => {
    // 09:00 + 2h labor → blocks 09:00–11:00, overlaps candidate 10:00 start
    expect(
      findScheduleConflicts([job({ scheduledEndTime: null, laborHours: 2 })], base)
    ).toHaveLength(1);
    // 09:00 + max(0,1)=1h → blocks 09:00–10:00, touches only
    expect(
      findScheduleConflicts([job({ scheduledEndTime: null, laborHours: 0 })], base)
    ).toHaveLength(0);
  });

  test('empty candidate end falls back to max(laborHours, 1h)', () => {
    // candidate 10:00 + 2h → 10:00–12:00, other job 11:00–13:00 overlaps
    expect(
      findScheduleConflicts(
        [job({ scheduledStartTime: '11:00', scheduledEndTime: '13:00' })],
        { date: '2026-08-03', start: '10:00', end: null, laborHours: 2 }
      )
    ).toHaveLength(1);
  });

  test('missing date or start returns no conflicts', () => {
    expect(findScheduleConflicts([job({})], { ...base, date: '' })).toHaveLength(0);
    expect(findScheduleConflicts([job({})], { ...base, start: '' })).toHaveLength(0);
  });
});
