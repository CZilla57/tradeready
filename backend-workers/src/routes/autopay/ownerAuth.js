// Shared JWT check for the owner autopay routes (Phase 24 spec §4.8): the
// same Supabase /auth/v1/user verification create-payment-link uses.
// → { userId } or { status, body } to return as-is.

export async function resolveOwner(c) {
  const { SUPABASE_URL, SUPABASE_ANON_KEY, SUPABASE_SERVICE_ROLE_KEY } = c.env;
  if (!SUPABASE_URL || !SUPABASE_ANON_KEY || !SUPABASE_SERVICE_ROLE_KEY) {
    return { status: 500, body: { error: 'Server misconfiguration.', code: 'server_error' } };
  }
  const auth = c.req.header('authorization');
  if (!auth || !auth.startsWith('Bearer ')) return { status: 401, body: { error: 'Unauthorized', code: 'unauthorized' } };
  const res = await fetch(`${SUPABASE_URL}/auth/v1/user`, {
    headers: { Authorization: `Bearer ${auth.slice(7)}`, apikey: SUPABASE_ANON_KEY },
  });
  if (!res.ok) return { status: 401, body: { error: 'Invalid or expired session. Please sign in again.', code: 'unauthorized' } };
  const user = await res.json().catch(() => null);
  if (!user || !user.id) return { status: 401, body: { error: 'Unauthorized', code: 'unauthorized' } };
  return { userId: user.id };
}
