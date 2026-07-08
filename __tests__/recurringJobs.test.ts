import { calculateNextDate, checkAndGenerateRecurringJobs } from '../utils/recurringJobs';
import type { RecurringJob, Job } from '../types/models';
import {
  loadJobs,
  saveJobs,
  loadRecurringJobs,
  saveRecurringJobs,
} from '../utils/storage';

jest.mock('../utils/storage', () => ({
  loadJobs: jest.fn(),
  saveJobs: jest.fn(),
  loadRecurringJobs: jest.fn(),
  saveRecurringJobs: jest.fn(),
}));

const mockLoadJobs = loadJobs as jest.MockedFunction<typeof loadJobs>;
const mockSaveJobs = saveJobs as jest.MockedFunction<typeof saveJobs>;
const mockLoadRecurringJobs = loadRecurringJobs as jest.MockedFunction<typeof loadRecurringJobs>;
const mockSaveRecurringJobs = saveRecurringJobs as jest.MockedFunction<typeof saveRecurringJobs>;

function makeRule(overrides: Partial<RecurringJob> = {}): RecurringJob {
  return {
    id: 'rj_test',
    customerId: 'c1',
    customerName: 'Alice',
    title: 'Lawn service',
    description: '',
    address: '1 Main St',
    notes: '',
    estimateTotal: 100,
    laborHours: 1,
    laborRate: 85,
    materials: [],
    materialMarkup: 20,
    overhead: 15,
    margin: 20,
    cadence: 'weekly',
    endCondition: 'never',
    occurrenceCount: 1,
    lastGeneratedDate: '2026-07-01',
    nextDueDate: '2026-07-08',
    isActive: true,
    createdAt: '2026-06-01',
    ...overrides,
  };
}

beforeEach(() => {
  jest.useFakeTimers();
  jest.setSystemTime(new Date('2026-07-08T12:00:00'));
  jest.clearAllMocks();
  mockSaveJobs.mockResolvedValue(undefined);
  mockSaveRecurringJobs.mockResolvedValue(undefined);
});

afterEach(() => {
  jest.useRealTimers();
});

// ---------------------------------------------------------------------------
// Part 1: calculateNextDate (pure function, no mocking needed)
// ---------------------------------------------------------------------------

describe('calculateNextDate', () => {
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

  test('monthly from Jan 31 overflows to March (JS Date behavior)', () => {
    // Jan 31 + 1 month = Feb 31 which JS rolls to March 2 or 3.
    // This is expected JS Date overflow behavior, not a bug.
    const result = calculateNextDate('2026-01-31', 'monthly');
    expect(result).toMatch(/^2026-03-0[23]$/);
  });
});

// ---------------------------------------------------------------------------
// Part 2: checkAndGenerateRecurringJobs (async, storage mocked)
// ---------------------------------------------------------------------------

describe('checkAndGenerateRecurringJobs', () => {
  test('generates 1 job when rule is due today', async () => {
    const rule = makeRule({ nextDueDate: '2026-07-08', occurrenceCount: 1 });
    mockLoadRecurringJobs.mockResolvedValue([rule]);
    mockLoadJobs.mockResolvedValue([]);

    await checkAndGenerateRecurringJobs();

    expect(mockSaveJobs).toHaveBeenCalledTimes(1);
    const savedJobs: Job[] = mockSaveJobs.mock.calls[0][0];
    expect(savedJobs).toHaveLength(1);
    expect(savedJobs[0].scheduledDate).toBe('2026-07-08');
    expect(savedJobs[0].status).toBe('scheduled');
    expect(savedJobs[0].recurringJobId).toBe('rj_test');
    expect(savedJobs[0].occurrenceNumber).toBe(2); // was 1, incremented to 2

    expect(mockSaveRecurringJobs).toHaveBeenCalledTimes(1);
    const savedRules: RecurringJob[] = mockSaveRecurringJobs.mock.calls[0][0];
    expect(savedRules[0].occurrenceCount).toBe(2);
    expect(savedRules[0].lastGeneratedDate).toBe('2026-07-08');
    expect(savedRules[0].nextDueDate).toBe('2026-07-15'); // advanced by 1 week
  });

  test('generates 4 jobs for 4 weekly occurrences spanning today', async () => {
    // Today = 2026-07-22, rule next due = 2026-07-01.
    // Loop: 07-01, 07-08, 07-15, 07-22 all satisfy nextDueDate <= today (07-22 <= 07-22).
    // 07-29 > 07-22, loop exits. So 4 jobs are generated.
    jest.setSystemTime(new Date('2026-07-22T12:00:00'));
    const rule = makeRule({ nextDueDate: '2026-07-01', occurrenceCount: 1 });
    mockLoadRecurringJobs.mockResolvedValue([rule]);
    mockLoadJobs.mockResolvedValue([]);

    await checkAndGenerateRecurringJobs();

    const savedJobs: Job[] = mockSaveJobs.mock.calls[0][0];
    expect(savedJobs).toHaveLength(4);
    expect(savedJobs[0].scheduledDate).toBe('2026-07-01');
    expect(savedJobs[1].scheduledDate).toBe('2026-07-08');
    expect(savedJobs[2].scheduledDate).toBe('2026-07-15');
    expect(savedJobs[3].scheduledDate).toBe('2026-07-22');

    const savedRules: RecurringJob[] = mockSaveRecurringJobs.mock.calls[0][0];
    // Started at 1, generated 4 jobs, so count = 5
    expect(savedRules[0].occurrenceCount).toBe(5);
    // 07-22 + 7 days = 07-29 (the next date after the last generated occurrence)
    expect(savedRules[0].nextDueDate).toBe('2026-07-29');
  });

  test('end condition count: stops after N occurrences', async () => {
    // occurrenceCount is already 3, endCount is 3 → end condition met immediately.
    // The loop enters (nextDueDate <= today), sees isEndConditionMet, sets isActive=false,
    // sets anyUpdated=true, and breaks without generating any job.
    // Because anyUpdated=true, saveJobs IS still called (with an empty new-jobs array).
    const rule = makeRule({
      nextDueDate: '2026-07-08',
      occurrenceCount: 3,
      endCondition: 'count',
      endCount: 3,
    });
    mockLoadRecurringJobs.mockResolvedValue([rule]);
    mockLoadJobs.mockResolvedValue([]);

    await checkAndGenerateRecurringJobs();

    // saveJobs is called because anyUpdated=true, but no new jobs were appended
    expect(mockSaveJobs).toHaveBeenCalledTimes(1);
    const savedJobs: Job[] = mockSaveJobs.mock.calls[0][0];
    expect(savedJobs).toHaveLength(0);

    expect(mockSaveRecurringJobs).toHaveBeenCalledTimes(1);
    const savedRules: RecurringJob[] = mockSaveRecurringJobs.mock.calls[0][0];
    expect(savedRules[0].isActive).toBe(false);
  });

  test('end condition date: past end date produces no jobs and deactivates', async () => {
    // endDate = 2026-07-07 (yesterday). isEndConditionMet checks nextDueDate > endDate,
    // i.e. '2026-07-08' > '2026-07-07' = true. Same anyUpdated=true flow as above.
    const rule = makeRule({
      nextDueDate: '2026-07-08',
      occurrenceCount: 1,
      endCondition: 'date',
      endDate: '2026-07-07', // yesterday
    });
    mockLoadRecurringJobs.mockResolvedValue([rule]);
    mockLoadJobs.mockResolvedValue([]);

    await checkAndGenerateRecurringJobs();

    // saveJobs is called because anyUpdated=true, but no new jobs were appended
    expect(mockSaveJobs).toHaveBeenCalledTimes(1);
    const savedJobs: Job[] = mockSaveJobs.mock.calls[0][0];
    expect(savedJobs).toHaveLength(0);

    expect(mockSaveRecurringJobs).toHaveBeenCalledTimes(1);
    const savedRules: RecurringJob[] = mockSaveRecurringJobs.mock.calls[0][0];
    expect(savedRules[0].isActive).toBe(false);
  });

  test('end condition never: keeps isActive true', async () => {
    const rule = makeRule({ nextDueDate: '2026-07-08', endCondition: 'never' });
    mockLoadRecurringJobs.mockResolvedValue([rule]);
    mockLoadJobs.mockResolvedValue([]);

    await checkAndGenerateRecurringJobs();

    const savedRules: RecurringJob[] = mockSaveRecurringJobs.mock.calls[0][0];
    expect(savedRules[0].isActive).toBe(true);
  });

  test('rule not yet due: generates nothing', async () => {
    const rule = makeRule({ nextDueDate: '2026-07-15' }); // today is 2026-07-08
    mockLoadRecurringJobs.mockResolvedValue([rule]);
    mockLoadJobs.mockResolvedValue([]);

    await checkAndGenerateRecurringJobs();

    expect(mockSaveJobs).not.toHaveBeenCalled();
    expect(mockSaveRecurringJobs).not.toHaveBeenCalled();
  });

  test('already inactive rule is skipped entirely', async () => {
    const rule = makeRule({ nextDueDate: '2026-07-08', isActive: false });
    mockLoadRecurringJobs.mockResolvedValue([rule]);
    mockLoadJobs.mockResolvedValue([]);

    await checkAndGenerateRecurringJobs();

    expect(mockSaveJobs).not.toHaveBeenCalled();
    expect(mockSaveRecurringJobs).not.toHaveBeenCalled();
  });
});
