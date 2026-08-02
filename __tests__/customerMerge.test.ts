// __tests__/customerMerge.test.ts
// Pins the customer-merge core (utils/customerMerge.ts): reference
// re-pointing across all four dependent collections (id match + orphan
// name-fallback, the same join CustomerDetail uses), blank-only contact
// backfill, note concatenation, earliest createdAt, loser removal, and
// same-reference no-ops for untouched collections.

import { mergeCustomers, mergeCustomerRecords, type MergeData } from '../utils/customerMerge';
import type { Customer, Invoice, Job, RecurringInvoice, RecurringJob } from '../types/models';

const cust = (over: Partial<Customer> = {}): Customer => ({
  id: 'c1', name: 'Alice', email: '', phone: '', address: '', notes: '', ...over,
} as Customer);

const job = (over: Partial<Job> = {}): Job => ({
  id: 'j1', customerId: 'c1', customerName: 'Alice', title: 'Job', description: '',
  status: 'lead', scheduledDate: null, scheduledStartTime: null, scheduledEndTime: null,
  address: '', estimateTotal: 0, laborHours: 0, laborRate: 0, materials: [],
  materialMarkup: 0, overhead: 0, margin: 0, notes: '', invoiceId: null,
  createdAt: '2026-07-01', ...over,
} as Job);

const inv = (over: Partial<Invoice> = {}): Invoice => ({
  id: 'i1', customer: 'Alice', customerId: 'c1', number: 'INV-0001', amount: 100,
  due: '2026-07-01', email: '', phone: '', desc: '', paid: false, ...over,
} as Invoice);

const rjob = (over: Partial<RecurringJob> = {}): RecurringJob => ({
  id: 'rj1', customerId: 'c1', customerName: 'Alice', title: 'Mow', description: '',
  address: '', notes: '', estimateTotal: 0, laborHours: 0, laborRate: 0, materials: [],
  materialMarkup: 0, overhead: 0, margin: 0, cadence: 'monthly', endCondition: 'never',
  occurrenceCount: 1, lastGeneratedDate: '2026-07-01', nextDueDate: '2026-08-01',
  isActive: true, createdAt: '2026-07-01', ...over,
} as RecurringJob);

const rinv = (over: Partial<RecurringInvoice> = {}): RecurringInvoice => ({
  id: 'ri1', customerId: 'c1', customerName: 'Alice', description: 'Plan', amount: 50,
  dueDays: 30, cadence: 'monthly', endCondition: 'never', occurrenceCount: 1,
  lastGeneratedDate: '2026-07-01', nextDueDate: '2026-08-01', isActive: true,
  createdAt: '2026-07-01', ...over,
} as RecurringInvoice);

function data(over: Partial<MergeData> = {}): MergeData {
  return {
    customers: [cust({ id: 'A', name: 'Al Smith' }), cust({ id: 'B', name: 'Big Al' })],
    jobs: [], invoices: [], recurringJobs: [], recurringInvoices: [],
    ...over,
  };
}

describe('mergeCustomerRecords', () => {
  test('winner keeps non-blank fields; blanks backfill from loser', () => {
    const winner = cust({ id: 'A', email: 'al@x.com', phone: '' });
    const loser = cust({ id: 'B', email: 'other@x.com', phone: '555-1', address: '1 St' });
    const merged = mergeCustomerRecords(winner, loser);
    expect(merged.email).toBe('al@x.com');
    expect(merged.phone).toBe('555-1');
    expect(merged.address).toBe('1 St');
  });

  test('notes concatenate when both exist', () => {
    const merged = mergeCustomerRecords(cust({ notes: 'gate 44' }), cust({ id: 'B', notes: 'dog barks' }));
    expect(merged.notes).toBe('gate 44\n\ndog barks');
  });

  test('earliest createdAt wins', () => {
    const merged = mergeCustomerRecords(
      cust({ createdAt: '2026-06-01' }),
      cust({ id: 'B', createdAt: '2026-01-01' })
    );
    expect(merged.createdAt).toBe('2026-01-01');
  });
});

describe('mergeCustomers', () => {
  test('re-points id-linked jobs, invoices, and recurring rules to the winner', () => {
    const d = data({
      jobs: [job({ id: 'j1', customerId: 'B', customerName: 'Big Al' }), job({ id: 'j2', customerId: 'other' })],
      invoices: [inv({ id: 'i1', customerId: 'B', customer: 'Big Al' })],
      recurringJobs: [rjob({ customerId: 'B', customerName: 'Big Al' })],
      recurringInvoices: [rinv({ customerId: 'B', customerName: 'Big Al' })],
    });
    const r = mergeCustomers(d, 'A', 'B');
    expect(r.jobs.find((j) => j.id === 'j1')).toMatchObject({ customerId: 'A', customerName: 'Al Smith' });
    expect(r.jobs.find((j) => j.id === 'j2')).toBe(d.jobs[1]);
    expect(r.invoices[0]).toMatchObject({ customerId: 'A', customer: 'Al Smith' });
    expect(r.recurringJobs[0]).toMatchObject({ customerId: 'A', customerName: 'Al Smith' });
    expect(r.recurringInvoices[0]).toMatchObject({ customerId: 'A', customerName: 'Al Smith' });
    expect(r.changed).toEqual({ jobs: 1, invoices: 1, recurringJobs: 1, recurringInvoices: 1 });
  });

  test('orphans (blank customerId) join by the loser name, case-insensitively', () => {
    const d = data({
      jobs: [job({ customerId: '', customerName: '  big al ' })],
      invoices: [inv({ customerId: undefined, customer: 'BIG AL' } as unknown as Partial<Invoice>)],
    });
    const r = mergeCustomers(d, 'A', 'B');
    expect(r.jobs[0]).toMatchObject({ customerId: 'A', customerName: 'Al Smith' });
    expect(r.invoices[0]).toMatchObject({ customerId: 'A', customer: 'Al Smith' });
  });

  test('records pointing at a THIRD id with the loser name are left alone', () => {
    const d = data({ jobs: [job({ customerId: 'other', customerName: 'Big Al' })] });
    const r = mergeCustomers(d, 'A', 'B');
    expect(r.jobs).toBe(d.jobs);
  });

  test('loser is removed and the winner absorbs its blanks', () => {
    const d = data({
      customers: [cust({ id: 'A', name: 'Al Smith', phone: '' }), cust({ id: 'B', name: 'Big Al', phone: '555-9' })],
    });
    const r = mergeCustomers(d, 'A', 'B');
    expect(r.customers.map((c) => c.id)).toEqual(['A']);
    expect(r.customers[0].phone).toBe('555-9');
    expect(r.winner.phone).toBe('555-9');
  });

  test('untouched collections come back as the same reference', () => {
    const d = data({ jobs: [job({ customerId: 'other', customerName: 'Nobody' })] });
    const r = mergeCustomers(d, 'A', 'B');
    expect(r.jobs).toBe(d.jobs);
    expect(r.invoices).toBe(d.invoices);
    expect(r.recurringJobs).toBe(d.recurringJobs);
    expect(r.recurringInvoices).toBe(d.recurringInvoices);
  });

  test('self-merge and missing records throw', () => {
    expect(() => mergeCustomers(data(), 'A', 'A')).toThrow();
    expect(() => mergeCustomers(data(), 'A', 'nope')).toThrow();
  });
});
