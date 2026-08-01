// __tests__/invoiceNumber.test.ts
// nextInvoiceNumber was extracted 2026-08-01 from two identical screen-local
// copies (AddInvoiceScreen.autoInvoiceNumber, CreateInvoiceFromJobScreen.
// nextInvoiceNumber) so the recurring-invoice generator isn't a third copy.
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
