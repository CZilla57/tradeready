// Workers port of backend/api/delete-account.js — permanently deletes a user
// account and all data.
//
// SECURITY MODEL:
//   The caller sends their Supabase JWT as "Authorization: Bearer <token>".
//   The server verifies the JWT via Supabase (anon key), extracts the user ID,
//   then uses the service role key to delete all data rows and the auth user.
//   The service role key never leaves this server.
//
// Required bindings:
//   SUPABASE_URL              — e.g. https://xxxx.supabase.co
//   SUPABASE_ANON_KEY         — publishable anon key (for JWT verification)
//   SUPABASE_SERVICE_ROLE_KEY — secret service role key (for admin deletes)

import { appCors, clientIp } from '../appCors.js';

// Keep in step with the client's synced tables (COLLECTION_TABLES in
// utils/sync.ts + settings/customer_notes). Belt-and-braces: every table
// added since launch also carries an auth.users ON DELETE CASCADE FK, so the
// auth-user delete below covers a miss here — but the explicit list keeps the
// data-before-user ordering meaningful. Missing tables 404 and are tolerated.
const DATA_TABLES = [
  'invoices',
  'jobs',
  'customers',
  'expenses',
  'settings',
  'customer_notes',
  'pricebook',
  'recurringJobs',
  'recurringInvoices',
  'trips',
];

// Tight rate limit for a destructive action: 5 requests per IP per 5 minutes.
const rateLimitMap = new Map();
const RATE_LIMIT = 5;
const WINDOW_MS = 5 * 60_000;

function isRateLimited(ip) {
  const now = Date.now();
  const timestamps = (rateLimitMap.get(ip) || []).filter(t => now - t < WINDOW_MS);
  if (timestamps.length >= RATE_LIMIT) {
    rateLimitMap.set(ip, timestamps);
    return true;
  }
  timestamps.push(now);
  rateLimitMap.set(ip, timestamps);
  return false;
}

export async function deleteAccountHandler(c) {
  appCors(c, 'POST, OPTIONS');

  if (c.req.method === 'OPTIONS') return c.body(null, 200);
  if (c.req.method !== 'POST') return c.json({ error: 'Method not allowed' }, 405);

  const ip = clientIp(c);
  if (isRateLimited(ip)) {
    return c.json({ error: 'Too many requests. Please wait a moment.' }, 429);
  }

  const { SUPABASE_URL, SUPABASE_ANON_KEY, SUPABASE_SERVICE_ROLE_KEY } = c.env;
  if (!SUPABASE_URL || !SUPABASE_ANON_KEY || !SUPABASE_SERVICE_ROLE_KEY) {
    return c.json({
      error: 'Server misconfiguration: SUPABASE_URL, SUPABASE_ANON_KEY, and SUPABASE_SERVICE_ROLE_KEY must be set in Vercel environment variables.',
    }, 500);
  }

  const auth = c.req.header('authorization');
  if (!auth || !auth.startsWith('Bearer ')) {
    return c.json({ error: 'Unauthorized' }, 401);
  }
  const userJwt = auth.slice(7);

  // Verify the user JWT and retrieve user_id.
  const userRes = await fetch(`${SUPABASE_URL}/auth/v1/user`, {
    headers: {
      Authorization: `Bearer ${userJwt}`,
      apikey: SUPABASE_ANON_KEY,
    },
  });

  if (!userRes.ok) {
    return c.json({ error: 'Invalid or expired session. Please sign in again.' }, 401);
  }

  const user = await userRes.json();
  const userId = user?.id;
  if (!userId) {
    return c.json({ error: 'Unauthorized' }, 401);
  }

  try {
    // Delete all data rows for this user. Run in parallel for speed.
    // Data is deleted before the auth user so a partial failure leaves an
    // orphaned user record (recoverable) rather than orphaned data (not recoverable).
    const deleteResults = await Promise.all(
      DATA_TABLES.map(table =>
        fetch(`${SUPABASE_URL}/rest/v1/${table}?user_id=eq.${encodeURIComponent(userId)}`, {
          method: 'DELETE',
          headers: {
            Authorization: `Bearer ${SUPABASE_SERVICE_ROLE_KEY}`,
            apikey: SUPABASE_SERVICE_ROLE_KEY,
            Prefer: 'return=minimal',
          },
        })
      )
    );

    const failedTable = deleteResults.find(r => !r.ok && r.status !== 404);
    if (failedTable) {
      throw new Error(`Data delete failed: HTTP ${failedTable.status}`);
    }

    // Delete the auth user last — requires service role admin access.
    const deleteUserRes = await fetch(`${SUPABASE_URL}/auth/v1/admin/users/${userId}`, {
      method: 'DELETE',
      headers: {
        Authorization: `Bearer ${SUPABASE_SERVICE_ROLE_KEY}`,
        apikey: SUPABASE_SERVICE_ROLE_KEY,
      },
    });

    if (!deleteUserRes.ok) {
      const errBody = await deleteUserRes.json().catch(() => ({}));
      throw new Error(errBody.message || `Auth user delete failed: HTTP ${deleteUserRes.status}`);
    }

    return c.json({ success: true }, 200);
  } catch (err) {
    console.error('delete-account error:', err.message);
    return c.json({ error: 'Failed to delete account. Please try again or contact support.' }, 500);
  }
}
