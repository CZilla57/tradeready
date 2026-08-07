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

const bookedRequest: BookingRequest = {
  id: 'bk1700000001000_d4e5f6',
  status: 'booked',
  kind: 'booked',
  name: 'Sam Ortiz',
  phone: '555-0177',
  email: 'sam@example.com',
  address: '9 Oak Ave',
  details: 'Panel inspection',
  preferredTiming: '',
  createdAt: '2026-08-07T15:00:00.000Z',
  slot: {
    date: '2026-08-12',
    start: '09:00',
    end: '10:00',
    timeZone: 'America/Chicago',
    startUtc: '2026-08-12T14:00:00.000Z',
    endUtc: '2026-08-12T15:00:00.000Z',
  },
  manageToken: 'm'.repeat(48),
  history: [{ at: '2026-08-07T15:00:00.000Z', actor: 'customer', event: 'booked' }],
};

describe('convertBookingRequests — portal requests (Phase 12C)', () => {
  const existing: Customer = {
    id: 'c_dana',
    name: 'Dana Rivers',
    phone: '555-0142',
    email: 'dana@example.com',
    address: '12 Elm St',
    createdAt: '2026-08-01',
  } as Customer;

  const portalFollowup: BookingRequest = {
    ...request,
    id: 'bkpr_aabbccddeeff00112233',
    details: 'Fence needs painting too',
    preferredTiming: '',
    source: 'portal',
    sourceCustomerId: 'c_dana',
  };

  test('sourceCustomerId links the EXISTING customer — no new record, no field churn', () => {
    const customersIn = [existing];
    const out = convertBookingRequests([portalFollowup], [], customersIn, settings);
    expect(out.changed).toBe(true);
    expect(out.customers).toBe(customersIn); // untouched by reference — no upsert ran
    expect(out.customers[0]).toBe(existing);
    expect(out.jobs[0].customerId).toBe('c_dana');
    expect(out.requests[0].status).toBe('converted');
    expect(out.requests[0].convertedCustomerId).toBe('c_dana');
  });

  test('a dangling sourceCustomerId falls back to the name-keyed upsert', () => {
    const out = convertBookingRequests([{ ...portalFollowup, sourceCustomerId: 'c_gone' }], [], [], settings);
    expect(out.customers).toHaveLength(1);
    expect(out.customers[0].name).toBe('Dana Rivers');
    expect(out.jobs[0].customerId).toBe(out.customers[0].id);
  });

  test('portal provenance line replaces the booking-link one', () => {
    const out = convertBookingRequests([portalFollowup], [], [existing], settings);
    expect(out.jobs[0].notes).toContain('Came in via customer portal');
    expect(out.jobs[0].notes).not.toContain('booking link');
  });

  test('portal_change_requested rows are INERT here — never converted to leads', () => {
    const change: BookingRequest = {
      ...portalFollowup,
      id: 'bkpr_ffeeddccbbaa99887766',
      status: 'portal_change_requested',
      jobRef: 'j1',
      portalKind: 'reschedule',
      details: 'Reschedule requested for "Water heater swap" (2026-08-12)',
    };
    const out = convertBookingRequests([change], [], [existing], settings);
    expect(out.changed).toBe(false);
    expect(out.jobs).toHaveLength(0);
    expect(out.requests[0]).toBe(change);
  });
});

describe('convertBookingRequests — booked kind (Phase 11 C3)', () => {
  test('a booked request becomes a lead job WITH the slot schedule, status stays booked', () => {
    const out = convertBookingRequests([bookedRequest], [], [], settings);
    expect(out.changed).toBe(true);

    const j = out.jobs[0];
    expect(j.id).toBe('jbk_bk1700000001000_d4e5f6');
    // D6 (owner-approved): slot-booked jobs enter as lead WITH schedule set —
    // they show on the calendar and count as busy without skipping pipeline.
    expect(j.status).toBe('lead');
    expect(j.title).toBe('Booked appointment');
    expect(j.scheduledDate).toBe('2026-08-12');
    expect(j.scheduledStartTime).toBe('09:00');
    expect(j.scheduledEndTime).toBe('10:00');
    expect(j.notes).toContain('Booked online for 2026-08-12 09:00');

    // Status is NOT flipped to converted — the customer's manage page keeps
    // reading booked/confirmed; the convertedJobId stamp is the done marker.
    const r = out.requests[0];
    expect(r.status).toBe('booked');
    expect(r.convertedJobId).toBe(j.id);
    expect(r.convertedCustomerId).toBe(out.customers[0].id);
  });

  test('idempotent: a booked request with convertedJobId is untouched on rerun', () => {
    const first = convertBookingRequests([bookedRequest], [], [], settings);
    const second = convertBookingRequests(first.requests, first.jobs, first.customers, settings);
    expect(second.changed).toBe(false);
    expect(second.jobs).toBe(first.jobs);
    expect(second.requests).toBe(first.requests);
  });

  test('crash recovery: job already exists but stamp is missing → stamps without duplicating', () => {
    const first = convertBookingRequests([bookedRequest], [], [], settings);
    const rerun = convertBookingRequests([bookedRequest], first.jobs, first.customers, settings);
    expect(rerun.jobs).toHaveLength(1);
    expect(rerun.requests[0].convertedJobId).toBe('jbk_bk1700000001000_d4e5f6');
  });
});

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
