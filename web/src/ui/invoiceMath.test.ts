import { describe, it, expect } from 'vitest';
import type { Invoice, Payment } from '@shared/types/models';
import { daysPastDue, isOverdue, summarizeInvoices } from './invoiceMath';

// Minimal Invoice factory — only the fields the money math reads matter.
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

const NOW = new Date('2026-08-30T12:00:00');

describe('daysPastDue', () => {
  it('counts whole local days from the due date to now', () => {
    expect(daysPastDue('2026-08-20', NOW)).toBe(10);
  });
  it('is negative for a future due date', () => {
    expect(daysPastDue('2026-09-05', NOW)).toBe(-6);
  });
  it('is zero on the due date itself', () => {
    expect(daysPastDue('2026-08-30', NOW)).toBe(0);
  });
});

describe('isOverdue', () => {
  it('is true when a balance remains and the due date has passed', () => {
    expect(isOverdue(inv({ due: '2026-08-01', paid: false }))).toBe(true);
  });
  it('is false when fully paid, even if past due', () => {
    const paidInv = inv({
      due: '2026-08-01',
      amount: 100,
      payments: [payment({ amount: 100 })],
    });
    expect(isOverdue(paidInv)).toBe(false);
  });
  it('is false when not yet due', () => {
    // Guard the assertion against the real clock: only meaningful in the
    // future relative to today's date.
    const future = new Date();
    future.setFullYear(future.getFullYear() + 1);
    const dd = `${future.getFullYear()}-01-01`;
    expect(isOverdue(inv({ due: dd, paid: false }))).toBe(false);
  });
});

describe('summarizeInvoices', () => {
  it('sums outstanding and collected and counts overdue invoices', () => {
    const invoices: Invoice[] = [
      // Fully paid via ledger: collected 100, outstanding 0.
      inv({ id: 'a', amount: 100, payments: [payment({ id: 'pa', amount: 100 })] }),
      // Partly paid: collected 40, outstanding 60, and past due => overdue.
      inv({
        id: 'b',
        amount: 100,
        due: '2026-08-01',
        payments: [payment({ id: 'pb', amount: 40 })],
      }),
      // Unpaid, future due (not overdue): outstanding 200.
      inv({ id: 'c', amount: 200, due: '2999-01-01', paid: false }),
    ];
    const s = summarizeInvoices(invoices);
    expect(s.collected).toBe(140);
    expect(s.outstanding).toBe(260);
    expect(s.overdueCount).toBe(1);
  });

  it('treats a legacy paid invoice (no ledger) as fully collected', () => {
    const s = summarizeInvoices([inv({ amount: 300, paid: true })]);
    expect(s.collected).toBe(300);
    expect(s.outstanding).toBe(0);
  });
});
