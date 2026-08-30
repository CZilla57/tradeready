import { describe, it, expect } from 'vitest';
import type { Invoice, Job, Payment } from '@shared/types/models';
import {
  jobStatusBadge,
  invoiceStatusBadge,
  estimateStatusBadge,
  isEstimateJob,
} from './status';

function inv(partial: Partial<Invoice> = {}): Invoice {
  return {
    id: 'i1',
    customer: 'Acme',
    number: '1001',
    amount: 100,
    due: '2026-08-01',
    email: '',
    phone: '',
    desc: '',
    paid: false,
    ...partial,
  };
}
function payment(partial: Partial<Payment> = {}): Payment {
  return { id: 'p1', amount: 0, date: '2026-08-01', method: 'other', ...partial };
}
function job(partial: Partial<Job> = {}): Job {
  return { id: 'j1', status: 'lead', ...partial } as Job;
}

describe('jobStatusBadge', () => {
  it('maps known statuses to a label + color', () => {
    expect(jobStatusBadge('complete')).toEqual({
      label: 'Completed',
      color: 'green',
    });
    expect(jobStatusBadge('in_progress').color).toBe('amber');
  });
  it('falls back to the raw status for anything unknown', () => {
    expect(jobStatusBadge('gremlin')).toEqual({
      label: 'gremlin',
      color: 'slate',
    });
  });
});

describe('invoiceStatusBadge', () => {
  it('is Paid when fully paid', () => {
    expect(
      invoiceStatusBadge(inv({ amount: 100, payments: [payment({ amount: 100 })] }))
        .label,
    ).toBe('Paid');
  });
  it('is Overdue when a balance remains past the due date', () => {
    expect(invoiceStatusBadge(inv({ due: '2026-08-01', paid: false })).label).toBe(
      'Overdue',
    );
  });
  it('is Partly paid when some but not all is paid and not yet overdue', () => {
    const b = invoiceStatusBadge(
      inv({ amount: 100, due: '2999-01-01', payments: [payment({ amount: 40 })] }),
    );
    expect(b.label).toBe('Partly paid');
    expect(b.color).toBe('amber');
  });
  it('is Unpaid when nothing is paid and not yet overdue', () => {
    expect(
      invoiceStatusBadge(inv({ amount: 100, due: '2999-01-01', paid: false })).label,
    ).toBe('Unpaid');
  });
});

describe('estimateStatusBadge / isEstimateJob', () => {
  it('marks an approved job as Approved', () => {
    expect(estimateStatusBadge(job({ status: 'approved' })).label).toBe('Approved');
  });
  it('marks a declined job as Declined', () => {
    expect(estimateStatusBadge(job({ status: 'declined' })).label).toBe('Declined');
  });
  it('marks an estimate_sent job as Sent', () => {
    expect(estimateStatusBadge(job({ status: 'estimate_sent' })).label).toBe('Sent');
  });
  it('treats estimate-stage statuses as estimate jobs', () => {
    expect(isEstimateJob(job({ status: 'lead' }))).toBe(true);
    expect(isEstimateJob(job({ status: 'estimate_sent' }))).toBe(true);
  });
  it('treats a plain paid job as not an estimate', () => {
    expect(isEstimateJob(job({ status: 'paid', estimateTotal: 0 }))).toBe(false);
  });
});
