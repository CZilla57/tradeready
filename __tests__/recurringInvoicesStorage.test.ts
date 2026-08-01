// __tests__/recurringInvoicesStorage.test.ts
// The recurringInvoices collection is LOCAL-ONLY (mirror of recurringJobs):
// plain AsyncStorage under KEYS.recurringInvoices, never enqueued to sync.

import AsyncStorage from '@react-native-async-storage/async-storage';
import { loadRecurringInvoices, saveRecurringInvoices } from '../utils/storage';
import type { RecurringInvoice } from '../types/models';

// Isolate the storage barrel from sync/notification side-effects, exactly as
// __tests__/storage.test.js and __tests__/sampleMigration.test.js do.
jest.mock('../utils/sync', () => ({
  enqueue: jest.fn(),
  enqueueCollectionChanges: jest.fn(),
  trySync: jest.fn(),
  pruneQueueRecords: jest.fn(),
}));
jest.mock('../utils/notifications', () => ({ syncNotifications: jest.fn() }));

const rule: RecurringInvoice = {
  id: 'ri1700000000000',
  customerId: 'c1',
  customerName: 'Riverside Bakery',
  description: 'Monthly maintenance',
  amount: 150,
  dueDays: 30,
  cadence: 'monthly',
  endCondition: 'never',
  occurrenceCount: 0,
  lastGeneratedDate: null,
  nextDueDate: '2026-08-01',
  isActive: true,
  createdAt: '2026-08-01',
};

beforeEach(() => {
  jest.clearAllMocks();
  (AsyncStorage.getItem as jest.Mock).mockResolvedValue(null);
  (AsyncStorage.setItem as jest.Mock).mockResolvedValue(undefined);
});

describe('recurringInvoices storage', () => {
  test('loadRecurringInvoices returns [] when nothing is stored', async () => {
    expect(await loadRecurringInvoices()).toEqual([]);
  });

  test('saveRecurringInvoices writes JSON under the recurringInvoices key', async () => {
    await saveRecurringInvoices([rule]);
    expect(AsyncStorage.setItem).toHaveBeenCalledWith(
      'recurringInvoices',
      JSON.stringify([rule])
    );
  });

  test('loadRecurringInvoices round-trips a saved rule', async () => {
    (AsyncStorage.getItem as jest.Mock).mockResolvedValue(JSON.stringify([rule]));
    const loaded = await loadRecurringInvoices();
    expect(loaded).toHaveLength(1);
    expect(loaded[0]).toEqual(rule);
  });

  test('corrupt JSON degrades to [] instead of throwing', async () => {
    (AsyncStorage.getItem as jest.Mock).mockResolvedValue('{not json');
    expect(await loadRecurringInvoices()).toEqual([]);
  });
});
