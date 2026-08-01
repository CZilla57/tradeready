import { checkAndGenerateRecurringInvoices, fastForwardedNextDueDate } from '../utils/recurringInvoices';
import { invoiceIssueDate } from '../utils/pdfTemplates';
import type { RecurringInvoice, Invoice, Customer } from '../types/models';
import {
  loadInvoices,
  saveInvoices,
  loadCustomers,
  loadRecurringInvoices,
  saveRecurringInvoices,
} from '../utils/storage';
import { syncNotifications } from '../utils/notifications';

jest.mock('../utils/storage', () => ({
  loadInvoices: jest.fn(),
  saveInvoices: jest.fn(),
  loadCustomers: jest.fn(),
  loadRecurringInvoices: jest.fn(),
  saveRecurringInvoices: jest.fn(),
  // resolveCustomer is pure; its real behavior is pinned by
  // __tests__/customerIdentity.test.js. Reimplemented inline so this mock
  // factory doesn't drag the real storage graph (sync/supabase) into the test.
  resolveCustomer: jest.fn(
    (customers: any[], link: { customerId?: string | null; customerName?: string | null }) =>
      customers.find((c) => c.id === link.customerId) ??
      customers.find(
        (c) => c.name.trim().toLowerCase() === (link.customerName || '').trim().toLowerCase(),
      ) ??
      null,
  ),
}));

jest.mock('../utils/notifications', () => ({
  syncNotifications: jest.fn(),
}));

const mockLoadInvoices = loadInvoices as jest.MockedFunction<typeof loadInvoices>;
const mockSaveInvoices = saveInvoices as jest.MockedFunction<typeof saveInvoices>;
const mockLoadCustomers = loadCustomers as jest.MockedFunction<typeof loadCustomers>;
const mockLoadRecurringInvoices =
  loadRecurringInvoices as jest.MockedFunction<typeof loadRecurringInvoices>;
const mockSaveRecurringInvoices =
  saveRecurringInvoices as jest.MockedFunction<typeof saveRecurringInvoices>;
const mockSyncNotifications = syncNotifications as jest.MockedFunction<typeof syncNotifications>;

const alice: Customer = {
  id: 'c1', name: 'Alice', email: 'alice@x.com', phone: '555-0001', address: '', notes: '',
};

function makeRule(overrides: Partial<RecurringInvoice> = {}): RecurringInvoice {
  return {
    id: 'ri_test',
    customerId: 'c1',
    customerName: 'Alice',
    description: 'Monthly maintenance',
    amount: 150,
    dueDays: 30,
    cadence: 'weekly',
    endCondition: 'never',
    occurrenceCount: 0,
    lastGeneratedDate: null,
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
  mockLoadInvoices.mockResolvedValue([]);
  mockLoadCustomers.mockResolvedValue([alice]);
  mockSaveInvoices.mockResolvedValue(undefined);
  mockSaveRecurringInvoices.mockResolvedValue(undefined);
});

afterEach(() => {
  jest.useRealTimers();
});

describe('checkAndGenerateRecurringInvoices', () => {
  test('generates 1 invoice when the rule is due today, with every field derived', async () => {
    mockLoadRecurringInvoices.mockResolvedValue([makeRule()]);

    await checkAndGenerateRecurringInvoices();

    expect(mockSaveInvoices).toHaveBeenCalledTimes(1);
    const saved: Invoice[] = mockSaveInvoices.mock.calls[0][0];
    expect(saved).toHaveLength(1);
    const inv = saved[0];
    expect(inv.id).toMatch(/^inv\d+$/);            // all-digits after the prefix
    expect(inv.customer).toBe('Alice');
    expect(inv.customerId).toBe('c1');
    expect(inv.number).toBe('INV-0001');
    expect(inv.amount).toBe(150);
    expect(inv.due).toBe('2026-08-07');            // occurrence 07-08 + 30 net days
    expect(inv.email).toBe('alice@x.com');         // snapshot at generation time
    expect(inv.phone).toBe('555-0001');
    expect(inv.desc).toBe('Monthly maintenance');
    expect(inv.paid).toBe(false);
    expect(inv.recurringInvoiceId).toBe('ri_test');
    expect(inv.occurrenceNumber).toBe(1);

    const rules: RecurringInvoice[] = mockSaveRecurringInvoices.mock.calls[0][0];
    expect(rules[0].occurrenceCount).toBe(1);
    expect(rules[0].lastGeneratedDate).toBe('2026-07-08');
    expect(rules[0].nextDueDate).toBe('2026-07-15');
  });

  test('re-sweeps notifications after both saves complete (not racing the rules write)', async () => {
    mockLoadRecurringInvoices.mockResolvedValue([makeRule()]);

    await checkAndGenerateRecurringInvoices();

    expect(mockSyncNotifications).toHaveBeenCalledTimes(1);
    const [saveInvoicesOrder] = mockSaveInvoices.mock.invocationCallOrder;
    const [saveRulesOrder] = mockSaveRecurringInvoices.mock.invocationCallOrder;
    const [syncOrder] = mockSyncNotifications.mock.invocationCallOrder;
    expect(syncOrder).toBeGreaterThan(saveInvoicesOrder);
    expect(syncOrder).toBeGreaterThan(saveRulesOrder);
  });

  test('generated invoices carry NO jobId, payments, or lineItems', async () => {
    mockLoadRecurringInvoices.mockResolvedValue([makeRule()]);

    await checkAndGenerateRecurringInvoices();

    const inv = mockSaveInvoices.mock.calls[0][0][0];
    expect('jobId' in inv).toBe(false);
    expect('payments' in inv).toBe(false);
    expect('lineItems' in inv).toBe(false);
  });

  test('catch-up generates every missed weekly occurrence with unique, parseable ids', async () => {
    jest.setSystemTime(new Date('2026-07-22T12:00:00'));
    mockLoadRecurringInvoices.mockResolvedValue([makeRule({ nextDueDate: '2026-07-01' })]);

    await checkAndGenerateRecurringInvoices();

    const saved: Invoice[] = mockSaveInvoices.mock.calls[0][0];
    expect(saved).toHaveLength(4); // 07-01, 07-08, 07-15, 07-22

    // Unique ids inside one same-millisecond batch (monotonic counter)…
    expect(new Set(saved.map((i) => i.id)).size).toBe(4);
    // …that all stay parseable by the PDF issue-date recovery.
    const FAR = new Date('2030-01-01T00:00:00.000Z');
    for (const i of saved) {
      expect(i.id).toMatch(/^inv\d+$/);
      expect(invoiceIssueDate(i.id, FAR)).not.toBe(FAR.toISOString()); // no fallback
    }

    expect(saved.map((i) => i.number)).toEqual(['INV-0001', 'INV-0002', 'INV-0003', 'INV-0004']);
    expect(saved.map((i) => i.occurrenceNumber)).toEqual([1, 2, 3, 4]);
    // due = occurrence date + 30 (NOT generation date) — catch-up invoices
    // date from when the money was owed and may appear already overdue.
    expect(saved.map((i) => i.due)).toEqual(['2026-07-31', '2026-08-07', '2026-08-14', '2026-08-21']);

    const rules: RecurringInvoice[] = mockSaveRecurringInvoices.mock.calls[0][0];
    expect(rules[0].occurrenceCount).toBe(4);
    expect(rules[0].nextDueDate).toBe('2026-07-29');
  });

  test('invoice numbering continues from existing invoices', async () => {
    mockLoadInvoices.mockResolvedValue([
      { id: 'old', customer: 'B', number: 'INV-0007', amount: 1, due: '2026-01-01', email: '', phone: '', desc: '', paid: true },
    ]);
    mockLoadRecurringInvoices.mockResolvedValue([makeRule()]);

    await checkAndGenerateRecurringInvoices();

    const saved: Invoice[] = mockSaveInvoices.mock.calls[0][0];
    expect(saved).toHaveLength(2); // existing + 1 generated, single batched save
    expect(saved[1].number).toBe('INV-0008');
  });

  test('end condition count: deactivates without generating', async () => {
    mockLoadRecurringInvoices.mockResolvedValue([
      makeRule({ endCondition: 'count', endCount: 3, occurrenceCount: 3 }),
    ]);

    await checkAndGenerateRecurringInvoices();

    expect(mockSaveInvoices).toHaveBeenCalledTimes(1);
    expect(mockSaveInvoices.mock.calls[0][0]).toHaveLength(0);
    expect(mockSaveRecurringInvoices.mock.calls[0][0][0].isActive).toBe(false);
  });

  test('end condition date: past end date deactivates without generating', async () => {
    mockLoadRecurringInvoices.mockResolvedValue([
      makeRule({ endCondition: 'date', endDate: '2026-07-07' }),
    ]);

    await checkAndGenerateRecurringInvoices();

    expect(mockSaveInvoices.mock.calls[0][0]).toHaveLength(0);
    expect(mockSaveRecurringInvoices.mock.calls[0][0][0].isActive).toBe(false);
  });

  test('generates the final occurrence then deactivates when the next generation reaches endCount', async () => {
    mockLoadRecurringInvoices.mockResolvedValue([
      makeRule({ endCondition: 'count', endCount: 3, occurrenceCount: 2 }),
    ]);

    await checkAndGenerateRecurringInvoices();

    const saved: Invoice[] = mockSaveInvoices.mock.calls[0][0];
    expect(saved).toHaveLength(1);
    expect(saved[0].occurrenceNumber).toBe(3);

    const rules: RecurringInvoice[] = mockSaveRecurringInvoices.mock.calls[0][0];
    expect(rules[0].isActive).toBe(false);
  });

  test('a paused rule is preserved unchanged in the saved rules array beside an active one', async () => {
    const pausedRule = makeRule({ id: 'ri_paused', isActive: false });
    const pausedRuleSnapshot: RecurringInvoice = JSON.parse(JSON.stringify(pausedRule));
    const activeRule = makeRule({ id: 'ri_active' });
    mockLoadRecurringInvoices.mockResolvedValue([pausedRule, activeRule]);

    await checkAndGenerateRecurringInvoices();

    expect(mockSaveRecurringInvoices).toHaveBeenCalledTimes(1);
    const rules: RecurringInvoice[] = mockSaveRecurringInvoices.mock.calls[0][0];
    expect(rules).toHaveLength(2);
    expect(rules[0]).toEqual(pausedRuleSnapshot); // paused rule: untouched, deep-equal to its input
    expect(rules[1].id).toBe('ri_active');
  });

  test("end condition never: stays active", async () => {
    mockLoadRecurringInvoices.mockResolvedValue([makeRule()]);

    await checkAndGenerateRecurringInvoices();

    expect(mockSaveRecurringInvoices.mock.calls[0][0][0].isActive).toBe(true);
  });

  test('rule not yet due: no saves at all', async () => {
    mockLoadRecurringInvoices.mockResolvedValue([makeRule({ nextDueDate: '2026-07-15' })]);

    await checkAndGenerateRecurringInvoices();

    expect(mockSaveInvoices).not.toHaveBeenCalled();
    expect(mockSaveRecurringInvoices).not.toHaveBeenCalled();
  });

  test('paused rule is skipped entirely', async () => {
    mockLoadRecurringInvoices.mockResolvedValue([makeRule({ isActive: false })]);

    await checkAndGenerateRecurringInvoices();

    expect(mockSaveInvoices).not.toHaveBeenCalled();
    expect(mockSaveRecurringInvoices).not.toHaveBeenCalled();
  });

  test('customer gone: contact snapshot is blank (backfillInvoiceContacts heals later)', async () => {
    mockLoadCustomers.mockResolvedValue([]);
    mockLoadRecurringInvoices.mockResolvedValue([makeRule()]);

    await checkAndGenerateRecurringInvoices();

    const inv = mockSaveInvoices.mock.calls[0][0][0];
    expect(inv.email).toBe('');
    expect(inv.phone).toBe('');
    expect(inv.customer).toBe('Alice'); // denormalized name still works
  });

  test('re-entry guard: a concurrent second call is a no-op', async () => {
    let release!: (rules: RecurringInvoice[]) => void;
    mockLoadRecurringInvoices.mockReturnValueOnce(
      new Promise<RecurringInvoice[]>((res) => { release = res; })
    );

    const first = checkAndGenerateRecurringInvoices();
    const second = checkAndGenerateRecurringInvoices(); // guard returns immediately
    release([]);
    await Promise.all([first, second]);

    expect(mockLoadRecurringInvoices).toHaveBeenCalledTimes(1);
  });
});

// ── fastForwardedNextDueDate (Fix B, 2026-08-01: Resume never back-bills) ───

describe('fastForwardedNextDueDate', () => {
  const today = '2026-07-08'; // matches the fake system time set in beforeEach

  test('an already-future nextDueDate is left unchanged', () => {
    const rule = makeRule({ nextDueDate: '2026-07-15', cadence: 'weekly' });
    expect(fastForwardedNextDueDate(rule, today)).toBe('2026-07-15');
  });

  test('a past nextDueDate advances to the first strictly-future weekly occurrence', () => {
    const rule = makeRule({ nextDueDate: '2026-07-01', cadence: 'weekly' });
    // 07-01 and 07-08 (== today) are both skipped; 07-15 is the first date > today.
    expect(fastForwardedNextDueDate(rule, today)).toBe('2026-07-15');
  });

  test('a past nextDueDate advances to the first strictly-future monthly occurrence', () => {
    const rule = makeRule({ nextDueDate: '2026-05-08', cadence: 'monthly' });
    // 05-08, 06-08, and 07-08 (== today) are all skipped; 08-08 is the first date > today.
    expect(fastForwardedNextDueDate(rule, today)).toBe('2026-08-08');
  });

  test('nextDueDate equal to today also advances (<=, not <)', () => {
    const rule = makeRule({ nextDueDate: today, cadence: 'weekly' });
    expect(fastForwardedNextDueDate(rule, today)).toBe('2026-07-15');
  });

  test('is pure: does not mutate the rule or advance occurrenceCount', () => {
    const rule = makeRule({ nextDueDate: '2026-07-01', cadence: 'weekly', occurrenceCount: 2 });
    const snapshot: RecurringInvoice = JSON.parse(JSON.stringify(rule));

    fastForwardedNextDueDate(rule, today);

    expect(rule).toEqual(snapshot);
  });

  // Finding 2 (2026-08-01): an already-ended plan must NOT be fast-forwarded
  // into the future on Resume — that would show an Active card with a Next
  // date past its own end, and schedule a bogus rinv_ reminder for an
  // occurrence the engine will never bill. Without the isEndConditionMet
  // guard, both cases below would advance nextDueDate via the while loop
  // because the stored nextDueDate is <= today.

  test('ended by date: nextDueDate already past endDate is returned unchanged, not fast-forwarded', () => {
    const rule = makeRule({
      nextDueDate: '2026-07-08', // == today
      cadence: 'weekly',
      endCondition: 'date',
      endDate: '2026-07-01', // already elapsed
    });
    expect(fastForwardedNextDueDate(rule, today)).toBe('2026-07-08');
  });

  test('ended by count: occurrenceCount already met is returned unchanged, not fast-forwarded', () => {
    const rule = makeRule({
      nextDueDate: '2026-07-01', // in the past — would otherwise fast-forward
      cadence: 'weekly',
      endCondition: 'count',
      endCount: 3,
      occurrenceCount: 3, // already met
    });
    expect(fastForwardedNextDueDate(rule, today)).toBe('2026-07-01');
  });
});

describe('resume fast-forward integration', () => {
  test('a rule fast-forwarded on resume generates nothing on the next engine run', async () => {
    // Simulates RecurringInvoicesScreen.setActive's resume path: the rule
    // missed several weekly occurrences while paused, and Resume advances
    // nextDueDate past today BEFORE the engine ever sees it again.
    const resumedRule = makeRule({ nextDueDate: '2026-07-01', cadence: 'weekly' });
    resumedRule.nextDueDate = fastForwardedNextDueDate(resumedRule, '2026-07-08');
    mockLoadRecurringInvoices.mockResolvedValue([resumedRule]);

    await checkAndGenerateRecurringInvoices();

    expect(mockSaveInvoices).not.toHaveBeenCalled();
    expect(mockSaveRecurringInvoices).not.toHaveBeenCalled();
  });
});
