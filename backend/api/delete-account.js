// Vercel serverless function — permanently deletes a user account and all data.
//
// SECURITY MODEL:
//   The caller sends their Supabase JWT as "Authorization: Bearer <token>".
//   The server verifies the JWT via Supabase (anon key), extracts the user ID,
//   then uses the service role key to delete all data rows and the auth user.
//   The service role key never leaves this server.
//
// REQUIRED VERCEL ENV VARS:
//   SUPABASE_URL              — e.g. https://xxxx.supabase.co
//   SUPABASE_ANON_KEY         — publishable anon key (for JWT verification)
//   SUPABASE_SERVICE_ROLE_KEY — secret service role key (for admin deletes)

const SUPABASE_URL = process.env.SUPABASE_URL;
const SUPABASE_ANON_KEY = process.env.SUPABASE_ANON_KEY;
const SUPABASE_SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;

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

module.exports = async function handler(req, res) {
  // Real hosts this project serves — tradeready.app was never ours (dead
  // entry from the original scaffold; see backend/lib/estimate/cors.js for
  // the canonical list rationale).
  const allowedOrigins = [
    'https://estimates.gettradereadyapp.com',
    'https://gettradereadyapp.com',
    'https://www.gettradereadyapp.com',
    'https://czilla57.github.io',
  ];
  const origin = req.headers['origin'];
  res.setHeader(
    'Access-Control-Allow-Origin',
    origin && allowedOrigins.includes(origin) ? origin : 'https://gettradereadyapp.com'
  );
  res.setHeader('Access-Control-Allow-Methods', 'POST, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type, Authorization');

  if (req.method === 'OPTIONS') return res.status(200).end();
  if (req.method !== 'POST') return res.status(405).json({ error: 'Method not allowed' });

  const ip = (req.headers['x-forwarded-for'] || req.socket?.remoteAddress || 'unknown').split(',')[0].trim();
  if (isRateLimited(ip)) {
    return res.status(429).json({ error: 'Too many requests. Please wait a moment.' });
  }

  if (!SUPABASE_URL || !SUPABASE_ANON_KEY || !SUPABASE_SERVICE_ROLE_KEY) {
    return res.status(500).json({
      error: 'Server misconfiguration: SUPABASE_URL, SUPABASE_ANON_KEY, and SUPABASE_SERVICE_ROLE_KEY must be set in Vercel environment variables.',
    });
  }

  const auth = req.headers['authorization'];
  if (!auth || !auth.startsWith('Bearer ')) {
    return res.status(401).json({ error: 'Unauthorized' });
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
    return res.status(401).json({ error: 'Invalid or expired session. Please sign in again.' });
  }

  const user = await userRes.json();
  const userId = user?.id;
  if (!userId) {
    return res.status(401).json({ error: 'Unauthorized' });
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

    return res.status(200).json({ success: true });
  } catch (err) {
    console.error('delete-account error:', err.message);
    return res.status(500).json({ error: 'Failed to delete account. Please try again or contact support.' });
  }
};
