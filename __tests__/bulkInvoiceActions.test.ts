// __tests__/bulkInvoiceActions.test.ts
// Pins the selection math behind the Invoices multi-select bulk actions
// (utils/bulkInvoiceActions.ts): remind eligibility per channel, bulk settle
// semantics (paid untouched, same-reference no-op), and the email
// subject-splitting rule shared with OutreachScreen.

import { splitRemindable, bulkSettle, splitEmailSubject } from '../utils/bulkInvoiceActions';
import { isFullyPaid, amountPaid } from '../utils/invoicePayments';
import type { Invoice } from '../types/models';

function inv(overrides: Partial<Invoice> = {}): Invoice {
  return {
    id: 'i1',
    customer: 'Alice',
    number: 'INV-0001',
    amount: 100,
    due: '2026-07-01',
    email: 'alice@x.com',
    phone: '555-0001',
    desc: 'Work',
    paid: false,
    ...overrides,
  } as Invoice;
}

describe('splitRemindable', () => {
  const list = [
    inv({ id: 'a' }),
    inv({ id: 'b', email: '', phone: '555-0002' }),
    inv({ id: 'c', email: 'c@x.com', phone: '  ' }),
    inv({ id: 'paid', paid: true }),
    inv({ id: 'unselected' }),
  ];

  test('email channel: needs an email address; missing → skipped', () => {
    const { eligible, skippedNoContact } = splitRemindable(list, ['a', 'b', 'c'], 'email');
    expect(eligible.map((i) => i.id)).toEqual(['a', 'c']);
    expect(skippedNoContact.map((i) => i.id)).toEqual(['b']);
  });

  test('text channel: needs a phone number; whitespace-only → skipped', () => {
    const { eligible, skippedNoContact } = splitRemindable(list, ['a', 'b', 'c'], 'text');
    expect(eligible.map((i) => i.id)).toEqual(['a', 'b']);
    expect(skippedNoContact.map((i) => i.id)).toEqual(['c']);
  });

  test('paid invoices are ignored even when selected', () => {
    const { eligible, skippedNoContact } = splitRemindable(list, ['paid'], 'email');
    expect(eligible).toEqual([]);
    expect(skippedNoContact).toEqual([]);
  });

  test('unselected invoices never appear', () => {
    const { eligible } = splitRemindable(list, ['a'], 'email');
    expect(eligible.map((i) => i.id)).toEqual(['a']);
  });
});

describe('bulkSettle', () => {
  test('settles every selected unpaid invoice dated today', () => {
    const list = [inv({ id: 'a' }), inv({ id: 'b', amount: 250 }), inv({ id: 'other' })];
    const { updated, settled } = bulkSettle(list, ['a', 'b'], '2026-08-02');
    expect(settled).toHaveLength(2);
    const a = updated.find((i) => i.id === 'a')!;
    const b = updated.find((i) => i.id === 'b')!;
    expect(isFullyPaid(a)).toBe(true);
    expect(isFullyPaid(b)).toBe(true);
    expect(amountPaid(b)).toBe(250);
    // Unselected invoice untouched — same reference.
    expect(updated.find((i) => i.id === 'other')).toBe(list[2]);
  });

  test('already-paid selections are a same-reference no-op', () => {
    const list = [inv({ id: 'paid', paid: true })];
    const { updated, settled } = bulkSettle(list, ['paid'], '2026-08-02');
    expect(settled).toEqual([]);
    expect(updated).toBe(list);
  });

  test('empty selection is a same-reference no-op', () => {
    const list = [inv({ id: 'a' })];
    const { updated, settled } = bulkSettle(list, [], '2026-08-02');
    expect(settled).toEqual([]);
    expect(updated).toBe(list);
  });
});

describe('splitEmailSubject', () => {
  test('splits the Subject: header the way OutreachScreen does', () => {
    const raw = 'Subject: Payment reminder – INV-0001\n\nHi Alice,\nPlease pay.';
    expect(splitEmailSubject(raw, 'fallback')).toEqual({
      subject: 'Payment reminder – INV-0001',
      body: 'Hi Alice,\nPlease pay.',
    });
  });

  test('no Subject header → fallback subject, body untouched', () => {
    expect(splitEmailSubject('Hi Alice, please pay.', 'Payment reminder – INV-0001')).toEqual({
      subject: 'Payment reminder – INV-0001',
      body: 'Hi Alice, please pay.',
    });
  });

  test('blank subject after the header → fallback subject', () => {
    expect(splitEmailSubject('Subject: \n\nBody here.', 'fb').subject).toBe('fb');
  });
});
