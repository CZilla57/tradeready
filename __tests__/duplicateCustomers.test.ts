// __tests__/duplicateCustomers.test.ts
// Pins the possible-duplicate detector behind the Customers-list prompt
// (utils/duplicateCustomers.ts): match rules per field, archived exclusion,
// stable order-independent pair keys, dismissal filtering, and the
// AsyncStorage round-trip for persisted dismissals.

import AsyncStorage from '@react-native-async-storage/async-storage';
import {
  findDuplicateCustomerPairs,
  filterUndismissed,
  pairKey,
  loadDismissedPairs,
  dismissPair,
  DISMISSED_DUPLICATES_STORAGE_KEY,
} from '../utils/duplicateCustomers';
import type { Customer } from '../types/models';

const cust = (over: Partial<Customer> = {}): Customer => ({
  id: 'c1', name: 'Alice', email: '', phone: '', address: '', notes: '', ...over,
} as Customer);

beforeEach(() => {
  jest.clearAllMocks();
});

describe('findDuplicateCustomerPairs', () => {
  test('same normalized name matches (case, trim, inner whitespace)', () => {
    const pairs = findDuplicateCustomerPairs([
      cust({ id: 'a', name: '  Al   Smith ' }),
      cust({ id: 'b', name: 'al smith' }),
    ]);
    expect(pairs).toHaveLength(1);
    expect(pairs[0].reason).toBe('name');
    expect(pairs[0].key).toBe('a|b');
  });

  test('same phone matches digit-for-digit across formatting', () => {
    const pairs = findDuplicateCustomerPairs([
      cust({ id: 'a', name: 'Al', phone: '(555) 010-1234' }),
      cust({ id: 'b', name: 'Big Al', phone: '555.010.1234' }),
    ]);
    expect(pairs).toHaveLength(1);
    expect(pairs[0].reason).toBe('phone');
  });

  test('short digit runs never match', () => {
    const pairs = findDuplicateCustomerPairs([
      cust({ id: 'a', name: 'Al', phone: '123' }),
      cust({ id: 'b', name: 'Bob', phone: '123' }),
    ]);
    expect(pairs).toHaveLength(0);
  });

  test('same email matches case-insensitively; blanks never match', () => {
    expect(findDuplicateCustomerPairs([
      cust({ id: 'a', name: 'Al', email: 'AL@X.com' }),
      cust({ id: 'b', name: 'Bob', email: 'al@x.com' }),
    ])).toHaveLength(1);
    expect(findDuplicateCustomerPairs([
      cust({ id: 'a', name: 'Al', email: '' }),
      cust({ id: 'b', name: 'Bob', email: '' }),
    ])).toHaveLength(0);
  });

  test('archived customers are excluded', () => {
    const pairs = findDuplicateCustomerPairs([
      cust({ id: 'a', name: 'Al Smith' }),
      cust({ id: 'b', name: 'Al Smith', archivedAt: '2026-08-01' }),
    ]);
    expect(pairs).toHaveLength(0);
  });

  test('a trio yields all three pairs', () => {
    const pairs = findDuplicateCustomerPairs([
      cust({ id: 'a', name: 'Al' }),
      cust({ id: 'b', name: 'Al' }),
      cust({ id: 'c', name: 'Al' }),
    ]);
    expect(pairs.map((p) => p.key)).toEqual(['a|b', 'a|c', 'b|c']);
  });
});

describe('pairKey / filterUndismissed', () => {
  test('pairKey is order-independent', () => {
    expect(pairKey('x', 'y')).toBe(pairKey('y', 'x'));
  });

  test('filterUndismissed drops dismissed keys only', () => {
    const pairs = findDuplicateCustomerPairs([
      cust({ id: 'a', name: 'Al' }),
      cust({ id: 'b', name: 'Al' }),
      cust({ id: 'c', name: 'Zed', phone: '5550101234' }),
      cust({ id: 'd', name: 'Zee', phone: '5550101234' }),
    ]);
    expect(pairs).toHaveLength(2);
    const remaining = filterUndismissed(pairs, ['a|b']);
    expect(remaining).toHaveLength(1);
    expect(remaining[0].key).toBe('c|d');
  });
});

describe('dismissal persistence', () => {
  test('loadDismissedPairs tolerates empty and malformed storage', async () => {
    (AsyncStorage.getItem as jest.Mock).mockResolvedValueOnce(null);
    expect(await loadDismissedPairs()).toEqual([]);
    (AsyncStorage.getItem as jest.Mock).mockResolvedValueOnce('not json');
    expect(await loadDismissedPairs()).toEqual([]);
    (AsyncStorage.getItem as jest.Mock).mockResolvedValueOnce('{"a":1}');
    expect(await loadDismissedPairs()).toEqual([]);
  });

  test('dismissPair appends once under the wipe-covered key', async () => {
    (AsyncStorage.getItem as jest.Mock).mockResolvedValueOnce(JSON.stringify(['a|b']));
    await dismissPair('c|d');
    expect(AsyncStorage.setItem).toHaveBeenCalledWith(
      DISMISSED_DUPLICATES_STORAGE_KEY,
      JSON.stringify(['a|b', 'c|d'])
    );

    (AsyncStorage.setItem as jest.Mock).mockClear();
    (AsyncStorage.getItem as jest.Mock).mockResolvedValueOnce(JSON.stringify(['a|b']));
    await dismissPair('a|b');
    expect(AsyncStorage.setItem).not.toHaveBeenCalled();
  });
});
