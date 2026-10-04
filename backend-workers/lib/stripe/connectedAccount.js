// Shared owner + connected-account resolution for the Tap to Pay routes
// (Phase 18 spec §2.1). Verifies the Supabase JWT exactly as the other owner
// routes do (/auth/v1/user), then reads the caller's own stripe_accounts row.
// The connected account id is NEVER taken from the request: it comes only from
// that row, keyed by the verified user id.
//
// → { userId, stripeAccountId } on success, or { status, body } to return
//   as-is. 401 unauthorized, 422 no_connected_account, 500 server_error.

async function resolveConnectedOwner(env, authHeader) {
  const { SUPABASE_URL, SUPABASE_ANON_KEY, SUPABASE_SERVICE_ROLE_KEY, STRIPE_SECRET_KEY } = env;
  if (!SUPABASE_URL || !SUPABASE_ANON_KEY || !SUPABASE_SERVICE_ROLE_KEY || !STRIPE_SECRET_KEY) {
    return { status: 500, body: { error: 'Server misconfiguration.', code: 'server_error' } };
  }
  if (!authHeader || !authHeader.startsWith('Bearer ')) {
    return { status: 401, body: { error: 'Unauthorized', code: 'unauthorized' } };
  }
  const userRes = await fetch(`${SUPABASE_URL}/auth/v1/user`, {
    headers: { Authorization: `Bearer ${authHeader.slice(7)}`, apikey: SUPABASE_ANON_KEY },
  });
  if (!userRes.ok) {
    return { status: 401, body: { error: 'Invalid or expired session. Please sign in again.', code: 'unauthorized' } };
  }
  const user = await userRes.json().catch(() => null);
  if (!user || !user.id) return { status: 401, body: { error: 'Unauthorized', code: 'unauthorized' } };

  const accountRes = await fetch(
    `${SUPABASE_URL}/rest/v1/stripe_accounts?user_id=eq.${encodeURIComponent(user.id)}&select=stripe_account_id`,
    { headers: { Authorization: `Bearer ${SUPABASE_SERVICE_ROLE_KEY}`, apikey: SUPABASE_SERVICE_ROLE_KEY } }
  );
  // A lookup error is not "no account": surface it so the caller answers 500.
  if (!accountRes.ok) throw new Error(`Supabase stripe_accounts lookup ${accountRes.status}`);
  const rows = await accountRes.json();
  const stripeAccountId = rows[0] && rows[0].stripe_account_id;
  if (!stripeAccountId) {
    return {
      status: 422,
      body: {
        error: 'No Stripe account connected. Go to Settings → Payment processor and tap "Connect Stripe account".',
        code: 'no_connected_account',
      },
    };
  }
  return { userId: user.id, stripeAccountId };
}

module.exports = { resolveConnectedOwner };
