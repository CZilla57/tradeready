// __tests__/invoiceNumber.test.ts
// nextInvoiceNumber was extracted 2026-08-01 from two near-identical
// screen-local copies (AddInvoiceScreen.autoInvoiceNumber,
// CreateInvoiceFromJobScreen.nextInvoiceNumber) so the recurring-invoice
// generator isn't a third copy.
// These tests pin the shared rule: digit-scan max + 1, INV-%04d.

import { nextInvoiceNumber } from '../utils/invoiceNumber';
import type { Invoice } from '../types/models';

function inv(number: string): Invoice {
  return {
    id: 'x',
    customer: 'A',
    number,
    amount: 100,
    due: '2026-01-01',
    email: '',
    phone: '',
    desc: '',
    paid: false,
  };
}

describe('nextInvoiceNumber', () => {
  test('empty list starts at INV-0001', () => {
    expect(nextInvoiceNumber([])).toBe('INV-0001');
  });

  test('max + 1 across gaps', () => {
    expect(nextInvoiceNumber([inv('INV-0002'), inv('INV-0007')])).toBe('INV-0008');
  });

  test('non-numeric numbers are ignored', () => {
    expect(nextInvoiceNumber([inv('DRAFT'), inv('INV-0003')])).toBe('INV-0004');
  });

  test('all-non-numeric list starts at INV-0001', () => {
    expect(nextInvoiceNumber([inv('DRAFT'), inv('FINAL')])).toBe('INV-0001');
  });

  test('a missing number field does not throw (legacy-data guard)', () => {
    const legacy = { ...inv('INV-0005'), number: undefined } as unknown as Invoice;
    expect(nextInvoiceNumber([legacy, inv('INV-0002')])).toBe('INV-0003');
  });

  test('pads to 4 digits and grows past 9999', () => {
    expect(nextInvoiceNumber([inv('INV-0009')])).toBe('INV-0010');
    expect(nextInvoiceNumber([inv('INV-9999')])).toBe('INV-10000');
  });

  test('digit-scan concatenates ALL digit runs (existing behavior, pinned)', () => {
    // "A1B2" scans to 12 — both original copies did this; the extraction must
    // not "fix" it.
    expect(nextInvoiceNumber([inv('A1B2')])).toBe('INV-0013');
  });
});

describe('nextInvoiceNumber with settings (prefix + starting number)', () => {
  test('custom prefix renders and matches case-insensitively when scanning', () => {
    expect(nextInvoiceNumber([], { invoicePrefix: 'JOB' })).toBe('JOB-0001');
    expect(nextInvoiceNumber([inv('job-0004')], { invoicePrefix: 'JOB' })).toBe('JOB-0005');
  });

  test('blank or whitespace prefix falls back to INV', () => {
    expect(nextInvoiceNumber([], { invoicePrefix: '' })).toBe('INV-0001');
    expect(nextInvoiceNumber([], { invoicePrefix: '   ' })).toBe('INV-0001');
  });

  test('trailing dash in the prefix is not doubled', () => {
    expect(nextInvoiceNumber([], { invoicePrefix: 'JOB-' })).toBe('JOB-0001');
  });

  test('starting number is a floor on an empty list', () => {
    expect(nextInvoiceNumber([], { invoiceStartNumber: 500 })).toBe('INV-0500');
  });

  test('starting number loses once the sequence has grown past it', () => {
    expect(nextInvoiceNumber([inv('INV-0800')], { invoiceStartNumber: 500 })).toBe('INV-0801');
  });

  test('starting number wins while the sequence is still below it', () => {
    expect(nextInvoiceNumber([inv('INV-0003')], { invoiceStartNumber: 500 })).toBe('INV-0500');
  });

  test('invalid starting numbers are ignored', () => {
    expect(nextInvoiceNumber([], { invoiceStartNumber: 0 })).toBe('INV-0001');
    expect(nextInvoiceNumber([], { invoiceStartNumber: -5 })).toBe('INV-0001');
    expect(nextInvoiceNumber([], { invoiceStartNumber: NaN })).toBe('INV-0001');
  });

  test('fractional starting number is floored', () => {
    expect(nextInvoiceNumber([], { invoiceStartNumber: 12.9 })).toBe('INV-0012');
  });

  test('digit-bearing prefix does not compound its own digits into the counter', () => {
    // Without the leading-prefix strip, "2026-0005" would scan to 20260005.
    expect(nextInvoiceNumber([inv('2026-0005')], { invoicePrefix: '2026' })).toBe('2026-0006');
  });

  test('legacy INV numbers still count under a new digitless scan path', () => {
    // Old INV invoices have no leading "2026", so the whole string digit-scans.
    expect(nextInvoiceNumber([inv('INV-0007')], { invoicePrefix: '2026' })).toBe('2026-0008');
  });

  test('undefined settings object behaves like the legacy call', () => {
    expect(nextInvoiceNumber([inv('INV-0002')], undefined)).toBe('INV-0003');
    expect(nextInvoiceNumber([inv('INV-0002')], {})).toBe('INV-0003');
  });
});
