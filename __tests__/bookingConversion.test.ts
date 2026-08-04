// __tests__/bookingConversion.test.ts
// Pure conversion core for booking requests (2026-08-04 spec §3.3): every
// "new" request becomes a Customer (real contact fields) + a lead Job with a
// DETERMINISTIC id (jbk_<requestId>) so a crash between saves can never
// duplicate a lead. Idempotent and flag-free, like applyDecisionsToJobs.

import { convertBookingRequests } from '../utils/storage/bookingConversion';
import { defaultSettings } from '../utils/storage';
import type { BookingRequest, Customer } from '../types/models';

jest.mock('../utils/sync', () => ({
  enqueue: jest.fn(),
  enqueueCollectionChanges: jest.fn(),
  trySync: jest.fn(),
  pruneQueueRecords: jest.fn(),
}));
jest.mock('../utils/notifications', () => ({ syncNotifications: jest.fn() }));

const settings = { ...defaultSettings(), laborRate: 95, materialMarkup: 25, overheadPercent: 10, marginPercent: 30 };

const request: BookingRequest = {
  id: 'bk1700000000000_a1b2c3',
  status: 'new',
  name: 'Dana Rivers',
  phone: '555-0142',
  email: 'dana@example.com',
  address: '12 Elm St',
  details: 'Water heater is leaking',
  preferredTiming: 'Weekday mornings',
  createdAt: '2026-08-04T15:00:00.000Z',
};

describe('convertBookingRequests', () => {
  test('converts a new request into a customer with full contact info + a lead job', () => {
    const out = convertBookingRequests([request], [], [], settings);
    expect(out.changed).toBe(true);

    expect(out.customers).toHaveLength(1);
    const c = out.customers[0];
    expect(c.name).toBe('Dana Rivers');
    expect(c.email).toBe('dana@example.com');
    expect(c.phone).toBe('555-0142');
    expect(c.address).toBe('12 Elm St');

    expect(out.jobs).toHaveLength(1);
    const j = out.jobs[0];
    expect(j.id).toBe('jbk_bk1700000000000_a1b2c3');
    expect(j.status).toBe('lead');
    expect(j.customerId).toBe(c.id);
    expect(j.customerName).toBe('Dana Rivers');
    expect(j.title).toBe('Quote request');
    expect(j.description).toBe('Water heater is leaking');
    expect(j.address).toBe('12 Elm St');
    expect(j.notes).toBe('Preferred timing: Weekday mornings\nCame in via booking link 2026-08-04');
    expect(j.scheduledDate).toBeNull();
    expect(j.invoiceId).toBeNull();
    expect(j.createdAt).toBe('2026-08-04');
    // AddJob new-job pricing parity (AddJobScreen.tsx ~337): settings values
    // with the same fallbacks.
    expect(j.estimateTotal).toBe(0);
    expect(j.laborHours).toBe(0);
    expect(j.materials).toEqual([]);
    expect(j.laborRate).toBe(95);
    expect(j.materialMarkup).toBe(25);
    expect(j.overhead).toBe(10);
    expect(j.margin).toBe(30);

    const r = out.requests[0];
    expect(r.status).toBe('converted');
    expect(r.convertedJobId).toBe(j.id);
    expect(r.convertedCustomerId).toBe(c.id);
  });

  test('omits the timing line when preferredTiming is empty', () => {
    const out = convertBookingRequests([{ ...request, preferredTiming: '' }], [], [], settings);
    expect(out.jobs[0].notes).toBe('Came in via booking link 2026-08-04');
  });

  test('joins an existing customer by normalized name and backfills blank contact fields', () => {
    const existing: Customer = { id: 'c1', name: 'dana rivers', email: '', phone: '', address: '', notes: '', createdAt: '2026-01-01' };
    const out = convertBookingRequests([request], [], [existing], settings);
    expect(out.customers).toHaveLength(1);
    expect(out.jobs[0].customerId).toBe('c1');
    expect(out.customers[0].email).toBe('dana@example.com'); // backfilled, not clobbered
  });

  test('is idempotent — a second run over its own output changes nothing', () => {
    const first = convertBookingRequests([request], [], [], settings);
    const second = convertBookingRequests(first.requests, first.jobs, first.customers, settings);
    expect(second.changed).toBe(false);
    expect(second.jobs).toBe(first.jobs);
    expect(second.customers).toBe(first.customers);
    expect(second.requests).toBe(first.requests);
  });

  test('crash recovery: job already exists but request still "new" — no duplicate job, request gets marked', () => {
    const first = convertBookingRequests([request], [], [], settings);
    const rerun = convertBookingRequests([request], first.jobs, first.customers, settings);
    expect(rerun.jobs).toHaveLength(1);
    expect(rerun.changed).toBe(true); // the request row still needed marking
    expect(rerun.requests[0].status).toBe('converted');
  });

  test('ignores converted requests entirely', () => {
    const done: BookingRequest = { ...request, status: 'converted', convertedJobId: 'jX', convertedCustomerId: 'cX' };
    const out = convertBookingRequests([done], [], [], settings);
    expect(out.changed).toBe(false);
  });
});
