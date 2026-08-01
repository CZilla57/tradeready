import { checkAndGenerateRecurringInvoices } from '../utils/recurringInvoices';
import { invoiceIssueDate } from '../utils/pdfTemplates';
import type { RecurringInvoice, Invoice, Customer } from '../types/models';
import {
  loadInvoices,
  saveInvoices,
  loadCustomers,
  loadRecurringInvoices,
  saveRecurringInvoices,
} from '../utils/storage';

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

const mockLoadInvoices = loadInvoices as jest.MockedFunction<typeof loadInvoices>;
const mockSaveInvoices = saveInvoices as jest.MockedFunction<typeof saveInvoices>;
const mockLoadCustomers = loadCustomers as jest.MockedFunction<typeof loadCustomers>;
const mockLoadRecurringInvoices =
  loadRecurringInvoices as jest.MockedFunction<typeof loadRecurringInvoices>;
const mockSaveRecurringInvoices =
  saveRecurringInvoices as jest.MockedFunction<typeof saveRecurringInvoices>;

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
