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

module.exports = async function handler(req, res) {
  if (req.method !== 'POST') return res.status(405).json({ error: 'Method not allowed' });

  // Verify the RevenueCat shared secret — fail closed if unset.
  if (!RC_WEBHOOK_SECRET) {
    console.error('[subscription/webhook] REVENUECAT_WEBHOOK_SECRET not configured');
    return res.status(500).json({ error: 'Webhook not configured' });
  }
  const auth = req.headers['authorization'];
  if (auth !== `Bearer ${RC_WEBHOOK_SECRET}`) {
    return res.status(401).json({ error: 'Unauthorized' });
  }

  const event = req.body?.event;
  if (!event?.type || !event?.app_user_id) {
    return res.status(400).json({ error: 'Missing event.type or event.app_user_id' });
  }

  const userId     = event.app_user_id;   // == Supabase user UUID (set via Purchases.logIn)
  const type       = event.type;
  const expiresAt  = event.expiration_at_ms ? new Date(event.expiration_at_ms).toISOString() : null;
  const periodType = event.period_type ?? null;
  const productId  = event.product_id ?? null;

  const status = resolveStatus(type);
  if (!status) {
    // Acknowledge unknown event types without acting on them.
    return res.status(200).json({ received: true, skipped: true });
  }

  const plan = resolvePlan(productId);

  try {
    await upsertSubscription({ userId, status, plan, periodType, expiresAt, productId });
    return res.status(200).json({ received: true });
  } catch (err) {
    // Log and return 500 so RC retries the webhook.
    console.error('[subscription/webhook] upsert error', err.message);
    return res.status(500).json({ error: 'Database error' });
  }
};

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
