import { SecureStoreAdapter } from '../utils/secureStoreAdapter';
import * as SecureStore from 'expo-secure-store';

jest.mock('expo-secure-store');

const adapter = new SecureStoreAdapter();
const encoder = new TextEncoder();

beforeEach(() => {
  jest.clearAllMocks();
});

describe('SecureStoreAdapter', () => {
  it('stores and retrieves a short value in a single chunk', async () => {
    const value = JSON.stringify({ token: 'abc' });
    (SecureStore.setItemAsync as jest.Mock).mockResolvedValue(undefined);
    (SecureStore.getItemAsync as jest.Mock).mockImplementation((key: string) => {
      if (key === 'supabase_session') return Promise.resolve(value);
      return Promise.resolve(null);
    });

    await adapter.setItem('supabase_session', value);
    expect(SecureStore.setItemAsync).toHaveBeenCalledWith('supabase_session', value);
    expect(encoder.encode(value).byteLength).toBeLessThanOrEqual(2048);

    const result = await adapter.getItem('supabase_session');
    expect(result).toBe(value);
  });

  it('chunks a value whose UTF-8 byte length exceeds 2048', async () => {
    const longValue = 'x'.repeat(3000);
    const setCalls: [string, string][] = [];
    (SecureStore.setItemAsync as jest.Mock).mockImplementation((key: string, val: string) => {
      setCalls.push([key, val]);
      return Promise.resolve(undefined);
    });
    (SecureStore.getItemAsync as jest.Mock).mockResolvedValue(null);

    await adapter.setItem('supabase_session', longValue);

    expect(setCalls.length).toBe(2);
    expect(setCalls[0][0]).toBe('supabase_session');
    expect(setCalls[1][0]).toBe('supabase_session_chunk_1');
    expect(encoder.encode(setCalls[0][1]).byteLength).toBeLessThanOrEqual(2048);
    expect(encoder.encode(setCalls[1][1]).byteLength).toBeLessThanOrEqual(2048);
  });

  it('reassembles a chunked value on getItem', async () => {
    const longValue = 'x'.repeat(3000);
    const bytes = encoder.encode(longValue);
    const chunk0 = new TextDecoder().decode(bytes.slice(0, 2048));
    const chunk1 = new TextDecoder().decode(bytes.slice(2048));

    (SecureStore.getItemAsync as jest.Mock).mockImplementation((key: string) => {
      if (key === 'supabase_session') return Promise.resolve(chunk0);
      if (key === 'supabase_session_chunk_1') return Promise.resolve(chunk1);
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
      if (key === 'supabase_session_chunk_1') return Promise.resolve('y');
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

  it('chunks correctly when multi-byte characters exceed the byte limit', async () => {
    // Each 😀 is 4 bytes in UTF-8 but only 2 JS code units.
    // 513 × 4 = 2052 bytes but only 1026 code units — old length-based
    // chunking would not have split this.
    const value = '😀'.repeat(513);
    expect(value.length).toBe(1026);
    expect(encoder.encode(value).byteLength).toBe(2052);

    const setCalls: [string, string][] = [];
    (SecureStore.setItemAsync as jest.Mock).mockImplementation((key: string, val: string) => {
      setCalls.push([key, val]);
      return Promise.resolve(undefined);
    });
    (SecureStore.getItemAsync as jest.Mock).mockResolvedValue(null);

    await adapter.setItem('test_key', value);

    expect(setCalls.length).toBe(2);
    expect(encoder.encode(setCalls[0][1]).byteLength).toBeLessThanOrEqual(2048);
    expect(encoder.encode(setCalls[1][1]).byteLength).toBeLessThanOrEqual(2048);
    expect(setCalls[0][1] + setCalls[1][1]).toBe(value);
  });
});
