// __tests__/archive.test.ts
// Pins the soft-archive helpers (utils/archive.ts) and the archived-exclusion
// rule in global search: absent flag = active, clearing removes the key
// entirely, un-archiving an active record is a same-reference no-op.

import { isArchived, withArchived, countArchived } from '../utils/archive';
import { searchAll } from '../utils/globalSearch';
import type { Customer, Job } from '../types/models';

describe('isArchived / withArchived', () => {
  test('absent flag means active', () => {
    expect(isArchived({})).toBe(false);
    expect(isArchived({ archivedAt: undefined })).toBe(false);
    expect(isArchived({ archivedAt: '2026-08-02' })).toBe(true);
  });

  test('archiving stamps the date on a copy', () => {
    const record = { id: 'x' };
    const archived = withArchived(record, true, '2026-08-02');
    expect(archived).not.toBe(record);
    expect(archived.archivedAt).toBe('2026-08-02');
    expect(record).toEqual({ id: 'x' });
  });

  test('un-archiving removes the key entirely', () => {
    const archived = { id: 'x', archivedAt: '2026-08-02' };
    const restored = withArchived(archived, false, '2026-08-03');
    expect(restored).toEqual({ id: 'x' });
    expect('archivedAt' in restored).toBe(false);
  });

  test('un-archiving an active record is a same-reference no-op', () => {
    const record = { id: 'x' };
    expect(withArchived(record, false, '2026-08-02')).toBe(record);
  });

  test('countArchived counts only flagged records', () => {
    expect(countArchived([{}, { archivedAt: '2026-08-01' }, {}])).toBe(1);
  });
});

describe('global search excludes archived records', () => {
  const job = {
    id: 'j1', customerId: 'c1', customerName: 'Alice', title: 'Fix fence',
    description: '', status: 'paid', scheduledDate: null,
    scheduledStartTime: null, scheduledEndTime: null, address: '',
    estimateTotal: 0, laborHours: 0, laborRate: 0, materials: [],
    materialMarkup: 0, overhead: 0, margin: 0, notes: '', invoiceId: null,
    createdAt: '2026-07-01',
  } as unknown as Job;
  const customer = {
    id: 'c1', name: 'Fence Fred', email: '', phone: '', address: '', notes: '',
  } as unknown as Customer;

  test('archived job and customer disappear from results', () => {
    const active = searchAll({ jobs: [job], customers: [customer], invoices: [] }, 'fence');
    expect(active.jobs.total).toBe(1);
    expect(active.customers.total).toBe(1);

    const archived = searchAll(
      {
        jobs: [{ ...job, archivedAt: '2026-08-01' }],
        customers: [{ ...customer, archivedAt: '2026-08-01' }],
        invoices: [],
      },
      'fence'
    );
    expect(archived.total).toBe(0);
  });
});
