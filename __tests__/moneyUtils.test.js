import {
  getDateRange,
  getPreviousRange,
  isInRange,
  getLast6MonthLabels,
  generateExpenseId,
  EXPENSE_CATEGORIES,
  DATE_FILTERS,
} from '../utils/moneyUtils';

// ─── getDateRange ─────────────────────────────────────────────────────────────

describe('getDateRange', () => {
  beforeEach(() => {
    jest.useFakeTimers();
    // Anchor to June 15, 2025 (local time) for deterministic month/year maths
    jest.setSystemTime(new Date(2025, 5, 15));
  });

  afterEach(() => {
    jest.useRealTimers();
  });

  test('this_month: June 1 – June 30, 2025', () => {
    const { start, end } = getDateRange('this_month');
    expect(start).toEqual(new Date(2025, 5, 1));
    expect(end).toEqual(new Date(2025, 6, 0, 23, 59, 59));
  });

  test('last_month: May 1 – May 31, 2025', () => {
    const { start, end } = getDateRange('last_month');
    expect(start).toEqual(new Date(2025, 4, 1));
    expect(end).toEqual(new Date(2025, 5, 0, 23, 59, 59));
  });

  test('this_year: Jan 1 – Dec 31, 2025', () => {
    const { start, end } = getDateRange('this_year');
    expect(start).toEqual(new Date(2025, 0, 1));
    expect(end).toEqual(new Date(2025, 11, 31, 23, 59, 59));
  });

  test('all_time: epoch start', () => {
    const { start } = getDateRange('all_time');
    expect(start.getTime()).toBe(0);
  });

  test('unknown filter falls back to all_time', () => {
    const { start } = getDateRange('bogus');
    expect(start.getTime()).toBe(0);
  });

  test('this_month: start is strictly before end', () => {
    const { start, end } = getDateRange('this_month');
    expect(start.getTime()).toBeLessThan(end.getTime());
  });
});

// ─── getPreviousRange ─────────────────────────────────────────────────────────

describe('getPreviousRange', () => {
  beforeEach(() => {
    jest.useFakeTimers();
    jest.setSystemTime(new Date(2025, 5, 15)); // June 15, 2025
  });

  afterEach(() => {
    jest.useRealTimers();
  });

  test('this_month → May 2025', () => {
    const range = getPreviousRange('this_month');
    expect(range.start).toEqual(new Date(2025, 4, 1));
    expect(range.end).toEqual(new Date(2025, 5, 0, 23, 59, 59));
  });

  test('last_month → April 2025', () => {
    const range = getPreviousRange('last_month');
    expect(range.start).toEqual(new Date(2025, 3, 1));
    expect(range.end).toEqual(new Date(2025, 4, 0, 23, 59, 59));
  });

  test('this_year → all of 2024', () => {
    const range = getPreviousRange('this_year');
    expect(range.start).toEqual(new Date(2024, 0, 1));
    expect(range.end).toEqual(new Date(2024, 11, 31, 23, 59, 59));
  });

  test('all_time → null (no meaningful previous period)', () => {
    expect(getPreviousRange('all_time')).toBeNull();
  });

  test('unknown filter → null', () => {
    expect(getPreviousRange('bogus')).toBeNull();
  });
});

// ─── isInRange ────────────────────────────────────────────────────────────────

describe('isInRange', () => {
  // Use local-time boundaries (matching getDateRange output)
  const start = new Date(2025, 5, 1);               // June 1 00:00:00 local
  const end   = new Date(2025, 5, 30, 23, 59, 59);  // June 30 23:59:59 local

  // Use 'T00:00:00' (no Z) so JS parses as local time — date-only strings
  // ('2025-06-01') are parsed as UTC midnight and behave inconsistently
  // across timezones, per the project's known Jest/date quirk.

  test('date within range returns true', () => {
    expect(isInRange('2025-06-15T00:00:00', start, end)).toBe(true);
  });

  test('date at start boundary returns true', () => {
    expect(isInRange('2025-06-01T00:00:00', start, end)).toBe(true);
  });

  test('date before range returns false', () => {
    expect(isInRange('2025-05-31T23:59:59', start, end)).toBe(false);
  });

  test('date after range returns false', () => {
    expect(isInRange('2025-07-01T00:00:00', start, end)).toBe(false);
  });

  test('local datetime string within range returns true', () => {
    expect(isInRange('2025-06-20T14:30:00', start, end)).toBe(true);
  });

  // ── Bare "YYYY-MM-DD" boundary days (the stored format for due/paidAt/exp.date/
  // trip.date). These parse as LOCAL midnight, so results are identical in every
  // timezone — the point of the fix. Under the old `new Date(dateString)` (UTC
  // midnight), the first/last-day cases flipped depending on the runner's TZ and
  // a period's opening day could be silently dropped from its totals.
  test('date-only first day of period is in range', () => {
    expect(isInRange('2025-06-01', start, end)).toBe(true);
  });

  test('date-only last day of period is in range', () => {
    expect(isInRange('2025-06-30', start, end)).toBe(true);
  });

  test('date-only day before period is out of range', () => {
    expect(isInRange('2025-05-31', start, end)).toBe(false);
  });

  test('date-only day after period is out of range', () => {
    expect(isInRange('2025-07-01', start, end)).toBe(false);
  });
});

// ─── getLast6MonthLabels ──────────────────────────────────────────────────────

describe('getLast6MonthLabels', () => {
  beforeEach(() => {
    jest.useFakeTimers();
    jest.setSystemTime(new Date(2025, 5, 15)); // June 15, 2025
  });

  afterEach(() => {
    jest.useRealTimers();
  });

  test('always returns exactly 6 entries', () => {
    expect(getLast6MonthLabels()).toHaveLength(6);
  });

  test('last entry is the current month', () => {
    const months = getLast6MonthLabels();
    const last = months[5];
    expect(last.label).toBe('Jun');
    expect(last.year).toBe(2025);
    expect(last.month).toBe(5);
  });

  test('first entry is 5 months ago', () => {
    const months = getLast6MonthLabels();
    const first = months[0];
    expect(first.label).toBe('Jan');
    expect(first.year).toBe(2025);
    expect(first.month).toBe(0);
  });

  test('each entry has label, year, and month properties', () => {
    getLast6MonthLabels().forEach(entry => {
      expect(entry).toHaveProperty('label');
      expect(entry).toHaveProperty('year');
      expect(entry).toHaveProperty('month');
    });
  });

  test('wraps across a year boundary correctly', () => {
    // Anchor to Feb 2025 — first month should be Sep 2024
    jest.setSystemTime(new Date(2025, 1, 10));
    const months = getLast6MonthLabels();
    expect(months[0].label).toBe('Sep');
    expect(months[0].year).toBe(2024);
    expect(months[5].label).toBe('Feb');
    expect(months[5].year).toBe(2025);
  });
});

// ─── generateExpenseId ────────────────────────────────────────────────────────

describe('generateExpenseId', () => {
  test('returns a non-empty string', () => {
    const id = generateExpenseId();
    expect(typeof id).toBe('string');
    expect(id.length).toBeGreaterThan(0);
  });

  test('generates unique IDs across 200 calls', () => {
    const ids = new Set(Array.from({ length: 200 }, () => generateExpenseId()));
    expect(ids.size).toBe(200);
  });
});

// ─── EXPENSE_CATEGORIES ───────────────────────────────────────────────────────

describe('EXPENSE_CATEGORIES', () => {
  test('has exactly 8 categories', () => {
    expect(EXPENSE_CATEGORIES).toHaveLength(8);
  });

  test('each category has id, label, and icon', () => {
    EXPENSE_CATEGORIES.forEach(cat => {
      expect(typeof cat.id).toBe('string');
      expect(typeof cat.label).toBe('string');
      expect(typeof cat.icon).toBe('string');
    });
  });

  test('last category is "other" (fallback for unknown categories)', () => {
    expect(EXPENSE_CATEGORIES[7].id).toBe('other');
  });

  test('all ids are unique', () => {
    const ids = EXPENSE_CATEGORIES.map(c => c.id);
    expect(new Set(ids).size).toBe(ids.length);
  });
});

// ─── DATE_FILTERS ─────────────────────────────────────────────────────────────

describe('DATE_FILTERS', () => {
  test('has exactly 4 filters', () => {
    expect(DATE_FILTERS).toHaveLength(4);
  });

  test('first filter is this_month (the default view)', () => {
    expect(DATE_FILTERS[0].id).toBe('this_month');
  });

  test('each filter has id and label', () => {
    DATE_FILTERS.forEach(f => {
      expect(typeof f.id).toBe('string');
      expect(typeof f.label).toBe('string');
    });
  });
});
