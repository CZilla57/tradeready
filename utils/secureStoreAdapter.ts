// utils/secureStoreAdapter.ts
// expo-secure-store caps individual values at 2048 bytes, but a Supabase auth
// session (JWT + refresh token + user metadata) routinely exceeds that. This
// adapter transparently splits a value across `key`, `key_chunk_1`,
// `key_chunk_2`, ... and reassembles them on read, so it can be dropped in
// wherever supabase-js wants a { getItem, setItem, removeItem } storage.
import * as SecureStore from 'expo-secure-store';

const CHUNK_SIZE = 2048;

// The SecureStore key the Supabase auth session is stored under. Shared with
// utils/supabase.ts (passed as auth.storageKey, so supabase-js actually
// writes here instead of its own URL-derived default) and
// utils/storage/lifecycle.ts (cleared on sign-out) — export it once so the
// three stay in sync rather than risking three independent literals drifting.
export const SESSION_STORAGE_KEY = 'supabase_session';

export class SecureStoreAdapter {
  async getItem(key: string): Promise<string | null> {
    const base = await SecureStore.getItemAsync(key);
    if (base === null) return null;

    let result = base;
    let i = 1;
    while (true) {
      const chunk = await SecureStore.getItemAsync(`${key}_chunk_${i}`);
      if (chunk === null) break;
      result += chunk;
      i++;
    }
    return result;
  }

  async setItem(key: string, value: string): Promise<void> {
    // Clean up old chunks first
    await this._removeChunks(key);

    if (value.length <= CHUNK_SIZE) {
      await SecureStore.setItemAsync(key, value);
      return;
    }

    const chunks: string[] = [];
    for (let i = 0; i < value.length; i += CHUNK_SIZE) {
      chunks.push(value.slice(i, i + CHUNK_SIZE));
    }

    await SecureStore.setItemAsync(key, chunks[0]);
    for (let i = 1; i < chunks.length; i++) {
      await SecureStore.setItemAsync(`${key}_chunk_${i}`, chunks[i]);
    }
  }

  async removeItem(key: string): Promise<void> {
    await SecureStore.deleteItemAsync(key);
    await this._removeChunks(key);
  }

  private async _removeChunks(key: string): Promise<void> {
    let i = 1;
    while (true) {
      const chunkKey = `${key}_chunk_${i}`;
      const exists = await SecureStore.getItemAsync(chunkKey);
      if (exists === null) break;
      await SecureStore.deleteItemAsync(chunkKey);
      i++;
    }
  }
}
