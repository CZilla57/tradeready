// __tests__/globalSearch.test.ts
// Pins the cross-entity search behind Today's global search
// (utils/globalSearch.ts): per-entity match fields, ordering, section caps
// with true totals, and the blank-query no-op.

import { searchAll, GLOBAL_SEARCH_SECTION_LIMIT } from '../utils/globalSearch';
import type { Customer, Invoice, Job } from '../types/models';

function job(overrides: Partial<Job> = {}): Job {
  return {
    id: 'j1', customerId: 'c1', customerName: 'Alice', title: 'Fix sink',
    description: '', status: 'lead', scheduledDate: null,
    scheduledStartTime: null, scheduledEndTime: null, address: '',
    estimateTotal: 0, laborHours: 0, laborRate: 0, materials: [],
    materialMarkup: 0, overhead: 0, margin: 0, notes: '', invoiceId: null,
    createdAt: '2026-07-01',
    ...overrides,
  } as Job;
}

function customer(overrides: Partial<Customer> = {}): Customer {
  return {
    id: 'c1', name: 'Alice', email: '', phone: '', address: '', notes: '',
    ...overrides,
  } as Customer;
}

function invoice(overrides: Partial<Invoice> = {}): Invoice {
  return {
    id: 'i1', customer: 'Alice', number: 'INV-0001', amount: 100,
    due: '2026-07-01', email: '', phone: '', desc: '', paid: false,
    ...overrides,
  } as Invoice;
}

describe('searchAll', () => {
  test('blank or whitespace query returns nothing', () => {
    const data = { jobs: [job()], customers: [customer()], invoices: [invoice()] };
    expect(searchAll(data, '').total).toBe(0);
    expect(searchAll(data, '   ').total).toBe(0);
  });

  test('matches are case-insensitive across entity fields', () => {
    const data = {
      jobs: [job({ title: 'Replace WATER heater' })],
      customers: [customer({ email: 'water@example.com' })],
      invoices: [invoice({ desc: 'water damage repair' })],
    };
    const r = searchAll(data, 'Water');
    expect(r.jobs.total).toBe(1);
    expect(r.customers.total).toBe(1);
    expect(r.invoices.total).toBe(1);
    expect(r.total).toBe(3);
  });

  test('jobs match on title, customer name, address, description, and notes', () => {
    const data = {
      jobs: [
        job({ id: 'a', title: 'Gutter clean' }),
        job({ id: 'b', customerName: 'Gutterson' }),
        job({ id: 'c', address: '9 Gutter Ln' }),
        job({ id: 'd', description: 'gutter guards' }),
        job({ id: 'e', notes: 'bring gutter brush' }),
        job({ id: 'f', title: 'Unrelated' }),
      ],
      customers: [], invoices: [],
    };
    expect(searchAll(data, 'gutter').jobs.total).toBe(5);
  });

  test('invoices match on number', () => {
    const data = { jobs: [], customers: [], invoices: [invoice({ number: 'INV-0042' })] };
    expect(searchAll(data, '0042').invoices.total).toBe(1);
  });

  test('customers match on phone', () => {
    const data = { jobs: [], customers: [customer({ phone: '555-0199' })], invoices: [] };
    expect(searchAll(data, '0199').customers.total).toBe(1);
  });

  test('jobs order newest-first, customers alphabetical, invoices latest-due-first', () => {
    const data = {
      jobs: [
        job({ id: 'old', title: 'paint', createdAt: '2026-01-01' }),
        job({ id: 'new', title: 'paint', createdAt: '2026-07-01' }),
      ],
      customers: [customer({ id: 'z', name: 'Zed Paint' }), customer({ id: 'a', name: 'Al Paint' })],
      invoices: [
        invoice({ id: 'early', desc: 'paint', due: '2026-02-01' }),
        invoice({ id: 'late', desc: 'paint', due: '2026-08-01' }),
      ],
    };
    const r = searchAll(data, 'paint');
    expect(r.jobs.items.map((j) => j.id)).toEqual(['new', 'old']);
    expect(r.customers.items.map((c) => c.id)).toEqual(['a', 'z']);
    expect(r.invoices.items.map((i) => i.id)).toEqual(['late', 'early']);
  });

  test('sections cap at the limit but report the true total', () => {
    const many = Array.from({ length: GLOBAL_SEARCH_SECTION_LIMIT + 3 }, (_, n) =>
      job({ id: `j${n}`, title: `fence ${n}` })
    );
    const r = searchAll({ jobs: many, customers: [], invoices: [] }, 'fence');
    expect(r.jobs.items).toHaveLength(GLOBAL_SEARCH_SECTION_LIMIT);
    expect(r.jobs.total).toBe(GLOBAL_SEARCH_SECTION_LIMIT + 3);
    expect(r.total).toBe(GLOBAL_SEARCH_SECTION_LIMIT + 3);
  });

  test('legacy records with missing fields do not throw', () => {
    const data = {
      jobs: [job({ title: undefined, notes: undefined } as unknown as Partial<Job>)],
      customers: [customer({ name: undefined } as unknown as Partial<Customer>)],
      invoices: [invoice({ desc: undefined, number: undefined } as unknown as Partial<Invoice>)],
    };
    expect(() => searchAll(data, 'x')).not.toThrow();
  });
});
