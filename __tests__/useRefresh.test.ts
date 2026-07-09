// RNTL v14 ships an async renderHook()/render() — every test must await it.
import { renderHook, act } from '@testing-library/react-native';
import { useRefresh } from '../hooks/useRefresh';
import { trySync } from '../utils/sync';
import { track } from '../utils/analytics';

jest.mock('../utils/sync', () => ({ trySync: jest.fn().mockResolvedValue(undefined) }));
jest.mock('../utils/analytics', () => ({ track: jest.fn() }));

beforeEach(() => jest.clearAllMocks());

describe('useRefresh', () => {
  it('refreshing starts as false', async () => {
    const { result } = await renderHook(() => useRefresh(jest.fn().mockResolvedValue(undefined)));
    expect(result.current.refreshing).toBe(false);
  });

  it('calls trySync then the reload callback on refresh', async () => {
    const reload = jest.fn().mockResolvedValue(undefined);
    const { result } = await renderHook(() => useRefresh(reload, 'TestScreen'));

    await act(async () => { result.current.onRefresh(); });

    expect(trySync).toHaveBeenCalled();
    expect(reload).toHaveBeenCalled();
  });

  it('tracks pull_to_refresh event with screen name', async () => {
    const reload = jest.fn().mockResolvedValue(undefined);
    const { result } = await renderHook(() => useRefresh(reload, 'JobsScreen'));

    await act(async () => { result.current.onRefresh(); });

    expect(track).toHaveBeenCalledWith('pull_to_refresh', { screen: 'JobsScreen' });
  });

  it('refreshing returns to false after refresh completes', async () => {
    const reload = jest.fn().mockResolvedValue(undefined);
    const { result } = await renderHook(() => useRefresh(reload));

    await act(async () => { result.current.onRefresh(); });

    expect(result.current.refreshing).toBe(false);
  });

  it('sync failure does not prevent reload from running', async () => {
    (trySync as jest.Mock).mockRejectedValueOnce(new Error('offline'));
    const reload = jest.fn().mockResolvedValue(undefined);
    const { result } = await renderHook(() => useRefresh(reload));

    await act(async () => { result.current.onRefresh(); });

    expect(reload).toHaveBeenCalled();
    expect(result.current.refreshing).toBe(false);
  });

  it('refreshing returns to false even if reload throws', async () => {
    const reload = jest.fn().mockRejectedValue(new Error('load failed'));
    const { result } = await renderHook(() => useRefresh(reload));

    await act(async () => { result.current.onRefresh(); });

    expect(result.current.refreshing).toBe(false);
  });
});
