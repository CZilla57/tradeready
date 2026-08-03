// POST /api/subscription/webhook
// Receives RevenueCat lifecycle events and keeps the Supabase `subscriptions`
// table in sync for server-side verification and analytics.
//
// The mobile app uses the RC SDK as the primary entitlement source of truth.
// This endpoint is a secondary record — useful for server-side features,
// analytics, and compliance (GDPR deletion already cascades via ON DELETE CASCADE).
//
// Required Vercel env vars:
//   REVENUECAT_WEBHOOK_SECRET  — set in RC dashboard → Integrations → Webhooks
//   SUPABASE_URL
//   SUPABASE_SERVICE_ROLE_KEY

const SUPABASE_URL              = process.env.SUPABASE_URL;
const SUPABASE_SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;
const RC_WEBHOOK_SECRET         = process.env.REVENUECAT_WEBHOOK_SECRET;

const { resolvePlan } = require('../../lib/plan');
const { constantTimeEqual } = require('../../lib/constantTime');

// app_user_id is client-controlled (whatever the app passed to Purchases.logIn),
// so a modified client can make RC emit genuinely-signed events carrying any id.
// Before the service-role upsert it must look like a UUID AND exist in
// auth.users — otherwise this endpoint could poison another user's row.
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

module.exports = async function handler(req, res) {
  if (req.method !== 'POST') return res.status(405).json({ error: 'Method not allowed' });

  // Verify the RevenueCat shared secret — fail closed if unset.
  if (!RC_WEBHOOK_SECRET) {
    console.error('[subscription/webhook] REVENUECAT_WEBHOOK_SECRET not configured');
    return res.status(500).json({ error: 'Webhook not configured' });
  }
  // Constant-time compare so response timing can't leak the secret prefix.
  const auth = req.headers['authorization'];
  if (!constantTimeEqual(auth, `Bearer ${RC_WEBHOOK_SECRET}`)) {
    return res.status(401).json({ error: 'Unauthorized' });
  }

  const event = req.body?.event;
  if (!event?.type || !event?.app_user_id) {
    return res.status(400).json({ error: 'Missing event.type or event.app_user_id' });
  }

  const userId     = event.app_user_id;   // == Supabase user UUID (set via Purchases.logIn)
  const type       = event.type;
  const expiresAt  = toIsoOrNull(event.expiration_at_ms);
  const periodType = event.period_type ?? null;
  const productId  = event.product_id != null ? String(event.product_id) : null;

  if (typeof userId !== 'string' || !UUID_RE.test(userId)) {
    // Permanently-invalid id — acknowledge with 200 so RC doesn't retry it.
    console.warn('[subscription/webhook] app_user_id is not a UUID, skipping');
    return res.status(200).json({ received: true, skipped: true });
  }

  const status = resolveStatus(type);
  if (!status) {
    // Acknowledge unknown event types without acting on them.
    return res.status(200).json({ received: true, skipped: true });
  }

  const plan = resolvePlan(productId);

  try {
    if (!(await authUserExists(userId))) {
      // Well-formed UUID but no such account — also permanent, don't retry.
      console.warn('[subscription/webhook] app_user_id not in auth.users, skipping:', userId);
      return res.status(200).json({ received: true, skipped: true });
    }
    await upsertSubscription({ userId, status, plan, periodType, expiresAt, productId });
    return res.status(200).json({ received: true });
  } catch (err) {
    // Log and return 500 so RC retries the webhook. Covers transient Supabase
    // failures in both the auth lookup and the upsert.
    console.error('[subscription/webhook] upsert error', err.message);
    return res.status(500).json({ error: 'Database error' });
  }
};

// RevenueCat sends expiration_at_ms as epoch milliseconds. A malformed value
// (non-numeric, or outside the valid Date range) used to throw a RangeError
// from toISOString() outside the try block — a crash-500 that made RC retry a
// permanently-bad event forever. Tolerate garbage: store null instead.
function toIsoOrNull(ms) {
  if (!ms) return null;
  const n = Number(ms);
  if (!Number.isFinite(n)) return null;
  const d = new Date(n);
  return Number.isNaN(d.getTime()) ? null : d.toISOString();
}

// Existence check against the Supabase auth admin API, using the same
// service-role fetch pattern as upsertSubscription. ok → true; 404 → false
// (no such user); anything else throws so the caller 500s and RC retries.
// userId is UUID-validated before this is called, so it's safe to interpolate.
async function authUserExists(userId) {
  const res = await fetch(`${SUPABASE_URL}/auth/v1/admin/users/${userId}`, {
    headers: {
      Authorization: `Bearer ${SUPABASE_SERVICE_ROLE_KEY}`,
      apikey: SUPABASE_SERVICE_ROLE_KEY,
    },
  });
  if (res.ok) return true;
  if (res.status === 404) return false;
  throw new Error(`Supabase auth lookup ${res.status}`);
}

function resolveStatus(type) {
  switch (type) {
    case 'TRIAL_STARTED':                       return 'trialing';
    case 'INITIAL_PURCHASE':
    case 'RENEWAL':
    case 'TRIAL_CONVERTED':
    case 'UNCANCELLATION':                      return 'active';
    case 'CANCELLATION':
    case 'TRIAL_CANCELLED':                     return 'cancelled';
    case 'EXPIRATION':
    case 'REFUND':
    case 'BILLING_ISSUES_DETECTED':             return 'expired';
    default:                                    return null;
  }
}

async function upsertSubscription({ userId, status, plan, periodType, expiresAt, productId }) {
  const res = await fetch(`${SUPABASE_URL}/rest/v1/subscriptions`, {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${SUPABASE_SERVICE_ROLE_KEY}`,
      apikey: SUPABASE_SERVICE_ROLE_KEY,
      'Content-Type': 'application/json',
      Prefer: 'resolution=merge-duplicates',
    },
    body: JSON.stringify({
      user_id:          userId,
      status,
      plan,
      period_type:      periodType,
      expires_at:       expiresAt,
      product_identifier: productId,
      updated_at:       new Date().toISOString(),
    }),
  });

  if (!res.ok) {
    const body = await res.text();
    throw new Error(`Supabase error ${res.status}: ${body}`);
  }
}
