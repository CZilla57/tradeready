// RNTL v14 ships an async renderHook() — every test must await it.
import { renderHook, act } from '@testing-library/react-native';
import { useSyncStatus } from '../hooks/useSyncStatus';
import AsyncStorage from '@react-native-async-storage/async-storage';
import * as Network from 'expo-network';
import { trySyncAwait } from '../utils/sync';

jest.mock('expo-network', () => ({
  getNetworkStateAsync: jest.fn().mockResolvedValue({ isConnected: true, isInternetReachable: true }),
}));
jest.mock('../utils/sync', () => ({ trySyncAwait: jest.fn().mockResolvedValue(undefined) }));

beforeEach(() => {
  jest.clearAllMocks();
  jest.useFakeTimers();
  (AsyncStorage.getItem as jest.Mock).mockResolvedValue(null);
});

afterEach(() => {
  jest.useRealTimers();
});

describe('useSyncStatus', () => {
  it('initial state is online with zero pending', async () => {
    const { result } = await renderHook(() => useSyncStatus());
    expect(result.current.isOnline).toBe(true);
    expect(result.current.pendingCount).toBe(0);
    expect(result.current.syncing).toBe(false);
  });

  it('reports offline when getNetworkStateAsync says disconnected', async () => {
    (Network.getNetworkStateAsync as jest.Mock).mockResolvedValue({ isConnected: false });
    const { result } = await renderHook(() => useSyncStatus());

    await act(async () => { jest.advanceTimersByTime(100); });

    expect(result.current.isOnline).toBe(false);
  });

  it('reports correct pendingCount from parsed __syncQueue', async () => {
    const queue = [
      { table: 'jobs', op: 'upsert', recordId: '1', payload: {}, ts: '2026-01-01' },
      { table: 'invoices', op: 'upsert', recordId: '2', payload: {}, ts: '2026-01-01' },
    ];
    (AsyncStorage.getItem as jest.Mock).mockResolvedValue(JSON.stringify(queue));

    const { result } = await renderHook(() => useSyncStatus());

    await act(async () => { jest.advanceTimersByTime(100); });

    expect(result.current.pendingCount).toBe(2);
  });

  it('returns pendingCount 0 when queue is empty or missing', async () => {
    (AsyncStorage.getItem as jest.Mock).mockResolvedValue(null);
    const { result } = await renderHook(() => useSyncStatus());

    await act(async () => { jest.advanceTimersByTime(100); });

    expect(result.current.pendingCount).toBe(0);
  });

  it('syncNow calls trySyncAwait and re-polls queue after', async () => {
    const queue = [{ table: 'jobs', op: 'upsert', recordId: '1', payload: {}, ts: '2026-01-01' }];
    (AsyncStorage.getItem as jest.Mock).mockResolvedValue(JSON.stringify(queue));

    const { result } = await renderHook(() => useSyncStatus());
    await act(async () => { jest.advanceTimersByTime(100); });

    expect(result.current.pendingCount).toBe(1);

    (AsyncStorage.getItem as jest.Mock).mockResolvedValue('[]');

    await act(async () => { result.current.syncNow(); });

    expect(trySyncAwait).toHaveBeenCalled();
    expect(result.current.pendingCount).toBe(0);
  });

  it('syncing is true during sync and false after', async () => {
    let resolveSync!: () => void;
    (trySyncAwait as jest.Mock).mockImplementation(() => new Promise(r => { resolveSync = r; }));

    const { result } = await renderHook(() => useSyncStatus());

    await act(() => { result.current.syncNow(); });

    expect(result.current.syncing).toBe(true);

    await act(async () => { resolveSync(); });

    expect(result.current.syncing).toBe(false);
  });

  it('syncing returns to false even if trySyncAwait throws', async () => {
    (trySyncAwait as jest.Mock).mockRejectedValueOnce(new Error('sync failed'));

    const { result } = await renderHook(() => useSyncStatus());

    await act(async () => { result.current.syncNow(); });

    expect(result.current.syncing).toBe(false);
  });

  it('clears interval on unmount', async () => {
    const clearSpy = jest.spyOn(global, 'clearInterval');
    const { unmount } = await renderHook(() => useSyncStatus());

    await unmount();

    expect(clearSpy).toHaveBeenCalled();
    clearSpy.mockRestore();
  });
});
