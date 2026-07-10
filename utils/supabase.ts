import 'react-native-url-polyfill/auto';
import { createClient } from '@supabase/supabase-js';
import { SecureStoreAdapter, SESSION_STORAGE_KEY } from './secureStoreAdapter';

const SUPABASE_URL = 'https://ncbqswfdvckmdocbawaa.supabase.co';
const SUPABASE_ANON_KEY = 'sb_publishable_eTyJedvrw47RtZ0waCj8Bw_SDOllgvF';

const secureStorage = new SecureStoreAdapter();

export const supabase = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
  auth: {
    storage: secureStorage,
    // Without an explicit storageKey, supabase-js derives one from the
    // project URL (`sb-<ref>-auth-token`) — pin it so utils/storage/
    // lifecycle.ts's sign-out cleanup targets a known, stable key instead of
    // an implicit one two files would otherwise have to independently derive.
    storageKey: SESSION_STORAGE_KEY,
    autoRefreshToken: true,
    persistSession: true,
    detectSessionInUrl: false,
  },
});
