// __tests__/recurrence.test.ts
// Direct tests for the shared recurrence helpers extracted from
// utils/recurringJobs.ts (2026-08-01). The jobs engine's own suite
// (recurringJobs.test.ts) stays byte-identical — its passing unchanged is the
// proof the extraction preserved behavior.

import { calculateNextDate, isEndConditionMet } from '../utils/recurrence';
import type { RecurrenceState } from '../utils/recurrence';

function state(overrides: Partial<RecurrenceState> = {}): RecurrenceState {
  return {
    endCondition: 'never',
    occurrenceCount: 0,
    nextDueDate: '2026-07-08',
    ...overrides,
  };
}

describe('calculateNextDate (shared home)', () => {
  test('daily advances by 1 day', () => {
    expect(calculateNextDate('2026-07-08', 'daily')).toBe('2026-07-09');
  });

  test('weekly advances by 7 days', () => {
    expect(calculateNextDate('2026-07-08', 'weekly')).toBe('2026-07-15');
  });

  test('monthly advances by 1 month', () => {
    expect(calculateNextDate('2026-07-08', 'monthly')).toBe('2026-08-08');
  });

  test('quarterly advances by 3 months', () => {
    expect(calculateNextDate('2026-07-08', 'quarterly')).toBe('2026-10-08');
  });

  test('annually advances by 1 year', () => {
    expect(calculateNextDate('2026-07-08', 'annually')).toBe('2027-07-08');
  });

  test('monthly from Jan 31 overflows into March (JS Date behavior, accepted)', () => {
    // Jan 31 + 1 month = Feb 31, which JS normalizes to Mar 3 in 2026 (2026 is
    // not a leap year, so Feb has 28 days: Feb 31 -> Mar 3). Local-frame
    // formatting (formatLocalDate) makes this exact and TZ-independent, unlike
    // the old toISOString()/UTC formatting this hedge used to guard against.
    expect(calculateNextDate('2026-01-31', 'monthly')).toBe('2026-03-03');
  });

  test('daily across a month boundary', () => {
    expect(calculateNextDate('2026-07-31', 'daily')).toBe('2026-08-01');
  });
});

describe('isEndConditionMet', () => {
  test("'never' is never met", () => {
    expect(isEndConditionMet(state({ occurrenceCount: 9999 }))).toBe(false);
  });

  test("'count' is met when occurrenceCount reaches endCount", () => {
    expect(
      isEndConditionMet(state({ endCondition: 'count', endCount: 3, occurrenceCount: 3 }))
    ).toBe(true);
  });

  test("'count' is not met below endCount", () => {
    expect(
      isEndConditionMet(state({ endCondition: 'count', endCount: 3, occurrenceCount: 2 }))
    ).toBe(false);
  });

  test("'date' is met when nextDueDate is past endDate", () => {
    expect(
      isEndConditionMet(state({ endCondition: 'date', endDate: '2026-07-07' }))
    ).toBe(true);
  });

  test("'date' is NOT met on the end date itself (boundary: that day still generates)", () => {
    expect(
      isEndConditionMet(state({ endCondition: 'date', endDate: '2026-07-08' }))
    ).toBe(false);
  });
});
