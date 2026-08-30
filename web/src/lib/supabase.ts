import { createClient } from '@supabase/supabase-js';

// Same Supabase project as the mobile app. These values are public — they ship
// inside the distributed app bundle (see ../../utils/supabase.ts) and are only
// an anon key; every table is guarded by row-level security keyed on
// auth.uid(), so a signed-in browser only ever sees its own account's rows.
const SUPABASE_URL = 'https://ncbqswfdvckmdocbawaa.supabase.co';
const SUPABASE_ANON_KEY = 'sb_publishable_eTyJedvrw47RtZ0waCj8Bw_SDOllgvF';

export const supabase = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
  auth: {
    // Browser localStorage (the supabase-js web default). Distinct from the
    // native SecureStore adapter the mobile app uses — sessions do not cross
    // between the two surfaces, but they authenticate against the same users.
    persistSession: true,
    autoRefreshToken: true,
    // Complete the OAuth (Google) and password-reset redirect handshakes that
    // land back on the web origin with tokens in the URL fragment.
    detectSessionInUrl: true,
  },
});
