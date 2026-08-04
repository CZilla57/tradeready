// __tests__/bookingRequestsStorage.test.ts
// The bookingRequests collection: AsyncStorage under KEYS.bookingRequests,
// synced from birth (2026-08-04 booking-link spec) — every save diffs into
// the sync queue like the other collections.

import AsyncStorage from '@react-native-async-storage/async-storage';
import { enqueueCollectionChanges, trySync } from '../utils/sync';
import { loadBookingRequests, saveBookingRequests } from '../utils/storage';
import type { BookingRequest } from '../types/models';

jest.mock('../utils/sync', () => ({
  enqueue: jest.fn(),
  enqueueCollectionChanges: jest.fn(),
  trySync: jest.fn(),
  pruneQueueRecords: jest.fn(),
}));
jest.mock('../utils/notifications', () => ({ syncNotifications: jest.fn() }));

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

beforeEach(() => {
  jest.clearAllMocks();
  (AsyncStorage.getItem as jest.Mock).mockResolvedValue(null);
  (AsyncStorage.setItem as jest.Mock).mockResolvedValue(undefined);
});

describe('bookingRequests storage', () => {
  test('loadBookingRequests returns [] when nothing is stored', async () => {
    expect(await loadBookingRequests()).toEqual([]);
  });

  test('saveBookingRequests writes JSON under the bookingRequests key', async () => {
    await saveBookingRequests([request]);
    expect(AsyncStorage.setItem).toHaveBeenCalledWith(
      'bookingRequests',
      JSON.stringify([request])
    );
  });

  test('saveBookingRequests diffs into the sync queue and kicks a background sync', async () => {
    await saveBookingRequests([request]);
    expect(enqueueCollectionChanges).toHaveBeenCalledWith('bookingRequests', [], [request]);
    expect(trySync).toHaveBeenCalled();
  });

  test('loadBookingRequests round-trips a saved request', async () => {
    (AsyncStorage.getItem as jest.Mock).mockResolvedValue(JSON.stringify([request]));
    expect(await loadBookingRequests()).toEqual([request]);
  });

  test('corrupt JSON degrades to [] instead of throwing', async () => {
    (AsyncStorage.getItem as jest.Mock).mockResolvedValue('{not json');
    expect(await loadBookingRequests()).toEqual([]);
  });
});
