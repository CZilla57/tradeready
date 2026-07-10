import { SecureStoreAdapter } from '../utils/secureStoreAdapter';
import * as SecureStore from 'expo-secure-store';

jest.mock('expo-secure-store');

const adapter = new SecureStoreAdapter();

beforeEach(() => {
  jest.clearAllMocks();
});

describe('SecureStoreAdapter', () => {
  it('stores and retrieves a short value in a single chunk', async () => {
    const value = JSON.stringify({ token: 'abc' });
    (SecureStore.setItemAsync as jest.Mock).mockResolvedValue(undefined);
    (SecureStore.getItemAsync as jest.Mock).mockImplementation((key: string) => {
      if (key === 'supabase_session') return Promise.resolve(value);
      if (key === 'supabase_session_chunk_1') return Promise.resolve(null);
      return Promise.resolve(null);
    });

    await adapter.setItem('supabase_session', value);
    const result = await adapter.getItem('supabase_session');
    expect(result).toBe(value);
  });

  it('chunks a value that exceeds 2048 bytes', async () => {
    const longValue = 'x'.repeat(3000);
    const setCalls: [string, string][] = [];
    (SecureStore.setItemAsync as jest.Mock).mockImplementation((key: string, val: string) => {
      setCalls.push([key, val]);
      return Promise.resolve(undefined);
    });

    await adapter.setItem('supabase_session', longValue);

    expect(setCalls.length).toBe(2);
    expect(setCalls[0][0]).toBe('supabase_session');
    expect(setCalls[1][0]).toBe('supabase_session_chunk_1');
    expect(setCalls[0][1].length).toBeLessThanOrEqual(2048);
    expect(setCalls[1][1].length).toBeLessThanOrEqual(2048);
  });

  it('reassembles a chunked value on getItem', async () => {
    const longValue = 'x'.repeat(3000);
    const chunk0 = longValue.slice(0, 2048);
    const chunk1 = longValue.slice(2048);

    (SecureStore.getItemAsync as jest.Mock).mockImplementation((key: string) => {
      if (key === 'supabase_session') return Promise.resolve(chunk0);
      if (key === 'supabase_session_chunk_1') return Promise.resolve(chunk1);
      if (key === 'supabase_session_chunk_2') return Promise.resolve(null);
      return Promise.resolve(null);
    });

    const result = await adapter.getItem('supabase_session');
    expect(result).toBe(longValue);
  });

  it('removes all chunks on removeItem', async () => {
    const deletedKeys: string[] = [];
    (SecureStore.deleteItemAsync as jest.Mock).mockImplementation((key: string) => {
      deletedKeys.push(key);
      return Promise.resolve(undefined);
    });
    (SecureStore.getItemAsync as jest.Mock).mockImplementation((key: string) => {
      if (key === 'supabase_session') return Promise.resolve('x'.repeat(2048));
      if (key === 'supabase_session_chunk_1') return Promise.resolve('y');
      if (key === 'supabase_session_chunk_2') return Promise.resolve(null);
      return Promise.resolve(null);
    });

    await adapter.removeItem('supabase_session');

    expect(deletedKeys).toContain('supabase_session');
    expect(deletedKeys).toContain('supabase_session_chunk_1');
  });

  it('returns null for a missing key', async () => {
    (SecureStore.getItemAsync as jest.Mock).mockResolvedValue(null);
    const result = await adapter.getItem('nonexistent');
    expect(result).toBeNull();
  });
});
