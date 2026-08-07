// Owner-side portal token management (Phase 12D): mint / set_enabled /
// rotate against the server-owned portal_tokens table. Invariants:
// - One ACTIVE token per customer. mint refuses (409) when one exists —
//   a stale-paint "Create" on a second device must never silently kill a
//   link already in the customer's inbox; rotate is the explicit
//   destructive path (revoke ALL, then insert fresh).
// - The raw token is returned exactly once; only its sha256 is written.
// - Legacy blob-only customers get their blob token backfilled into the
//   table on the FIRST manage action, after which the table governs.

const {
  sha256Hex,
  fetchCustomerTokenRows,
  insertTokenRow,
  revokeCustomerTokens,
  setCustomerTokenEnabled,
  fetchCustomerById,
} = require('./portalTokenStore.js');

const ACTIONS = new Set(['mint', 'set_enabled', 'rotate']);

async function portalManageCore(env, { userId, body, randHex }) {
  const action = body.action;
  const customerId = body.customerId;
  if (!ACTIONS.has(action)) return { status: 400, json: { error: 'Invalid request.' } };
  if (!customerId || typeof customerId !== 'string') return { status: 400, json: { error: 'Invalid request.' } };
  if (action === 'set_enabled' && typeof body.enabled !== 'boolean') {
    return { status: 400, json: { error: 'Invalid request.' } };
  }

  // Ownership as a 404, no oracle about other tenants (booking-respond
  // convention).
  const customer = await fetchCustomerById(env, userId, customerId);
  if (!customer) return { status: 404, json: { error: 'Not found' } };

  let rows = await fetchCustomerTokenRows(env, userId, customerId);

  // Legacy backfill: a pre-Phase-D customer carries only the blob token.
  // Materialize it in the table first so every action below (including this
  // one) operates purely on server state.
  const blobPortal = customer.data && customer.data.portal;
  if (rows.length === 0 && blobPortal && blobPortal.token) {
    const enabled = blobPortal.enabled !== false;
    await insertTokenRow(env, { tokenHash: sha256Hex(blobPortal.token), userId, customerId, enabled });
    rows = [{ token_hash: sha256Hex(blobPortal.token), enabled, revoked_at: null }];
  }

  if (action === 'mint') {
    if (rows.some((r) => r.enabled && !r.revoked_at)) {
      return { status: 409, json: { error: 'already_exists' } };
    }
    await insertTokenRow(env, { tokenHash: sha256Hex(randHex), userId, customerId, enabled: true });
    return { status: 200, json: { ok: true, token: randHex } };
  }

  if (action === 'set_enabled') {
    if (rows.length === 0) return { status: 404, json: { error: 'Not found' } };
    await setCustomerTokenEnabled(env, userId, customerId, body.enabled);
    return { status: 200, json: { ok: true, enabled: body.enabled } };
  }

  // rotate — works from zero rows too (rotate-as-create); the destructive
  // confirmation lives client-side.
  await revokeCustomerTokens(env, userId, customerId);
  await insertTokenRow(env, { tokenHash: sha256Hex(randHex), userId, customerId, enabled: true });
  return { status: 200, json: { ok: true, token: randHex } };
}

module.exports = { portalManageCore };
