// Owner-side portal token management (Phase 12D + Phase 8 task 8.06).
// Invariants (contract decisions §4, frozen in 8.00):
// - At most ONE non-revoked token per customer (partial unique index
//   portal_tokens_single_active; 8.06 migration). mint refuses (409
//   already_exists) when ANY live row exists — a stale-paint "Create" on a
//   second device must never silently stack a link beside the customer's
//   inbox copy; rotate is the explicit destructive path (revoke ALL, then
//   insert fresh, in ONE transaction).
// - The raw token is returned exactly once per operation; only its sha256 is
//   written to the token table (replay rows keep the response bytes for 30
//   days so a lost response replays the SAME capability).
// - Legacy blob-only customers get their blob token backfilled inside the
//   transaction, after which the table governs.
// - Operation replay is additive and optional: callers without an
//   operationId get the same atomic mutation without a replay row, so
//   existing RN/native payloads are preserved byte-identically.
//
// Atomicity lives in the `admin_portal_token` RPC
// (supabase/migrations/20260922_portal_token_admin.sql): per-customer
// advisory lock first, then replay lookup → customer check → backfill →
// state write + operations-row insert in ONE transaction. Any failure rolls
// back ALL of it — a failed insert after revoke (pinned gap G4-04) keeps the
// previous token live. When the RPC is not deployed the core keeps the
// legacy split path byte-identically (dual-write discipline, §10 step 3);
// the single-active index still guards the invariant once applied.

const {
  sha256Hex,
  fetchCustomerTokenRows,
  insertTokenRow,
  revokeCustomerTokens,
  setCustomerTokenEnabled,
  fetchCustomerById,
  callPortalRpc,
  portalRequestHash,
} = require('./portalTokenStore.js');

const ACTIONS = new Set(['mint', 'set_enabled', 'rotate', 'status']);

const UUID_V4_RE =
  /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-4[0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$/;

function mapRpcError(out) {
  if (out.error === 'already_exists' || out.error === 'operation_conflict') {
    return { status: 409, json: { error: out.error } };
  }
  if (out.error === 'not_found') return { status: 404, json: { error: 'Not found' } };
  if (out.error === 'invalid_action' || out.error === 'invalid_args') {
    return { status: 400, json: { error: 'Invalid request.' } };
  }
  return null;
}

async function portalManageCore(env, { userId, body, randHex }) {
  const action = body.action;
  const customerId = body.customerId;
  if (!ACTIONS.has(action)) return { status: 400, json: { error: 'Invalid request.' } };
  if (!customerId || typeof customerId !== 'string') return { status: 400, json: { error: 'Invalid request.' } };
  if (action === 'set_enabled' && typeof body.enabled !== 'boolean') {
    return { status: 400, json: { error: 'Invalid request.' } };
  }

  if (action === 'status') {
    return statusCore(env, { userId, customerId, token: body.token });
  }

  // operationId is OPTIONAL (existing payloads carry none): when present it
  // must be a client-generated UUID v4 and enables replay recovery; when
  // absent the mutation still commits atomically with no replay row.
  let operationId = null;
  if (body.operationId !== undefined) {
    if (typeof body.operationId !== 'string' || !UUID_V4_RE.test(body.operationId)) {
      return { status: 400, json: { error: 'Invalid request.' } };
    }
    operationId = body.operationId;
  }

  const enabled = action === 'set_enabled' ? body.enabled : null;
  const needsToken = action === 'mint' || action === 'rotate';
  if (needsToken && (!randHex || typeof randHex !== 'string')) {
    console.error('[estimate/portal-manage] no server token for mint/rotate');
    return { status: 500, json: { error: 'Database error' } };
  }
  const result = { ok: true };
  if (needsToken) result.token = randHex;

  // Single atomic call: revision-free replay-stable hash, server token hash,
  // and the response template the RPC stamps (enabled + adopted) and stores
  // verbatim for replay.
  let called;
  try {
    called = await callPortalRpc(env, 'admin_portal_token', {
      p_user_id: userId,
      p_customer_id: customerId,
      p_action: action,
      p_operation_id: operationId,
      p_request_hash: operationId ? portalRequestHash(action, customerId, enabled) : 'no-replay',
      p_enabled: enabled,
      p_token_hash: needsToken ? sha256Hex(randHex) : null,
      p_result: result,
    });
  } catch (err) {
    console.error('[estimate/portal-manage] RPC failed:', err.message);
    return { status: 500, json: { error: 'Database error' } };
  }
  if (!called.unavailable) {
    const out = called.out;
    if (out.ok) return { status: 200, json: out.response };
    const mapped = mapRpcError(out);
    if (mapped) return mapped;
    console.error('[estimate/portal-manage] unexpected envelope:', out.error);
    return { status: 500, json: { error: 'Database error' } };
  }

  // Pre-deploy fallback: the legacy split path, byte-identical to the 8.00
  // characterization except the C6 mint guard (ANY live row blocks, not just
  // enabled ones — the single-active index enforces the same rule once
  // applied, so the two paths never disagree on the verdict).
  return legacyManageCore(env, { userId, body, randHex });
}

async function legacyManageCore(env, { userId, body, randHex }) {
  const { action, customerId } = body;

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
    // C6: ANY live row blocks (disabled rows included) — re-enable via
    // set_enabled(true); destruction only via rotate.
    if (rows.some((r) => !r.revoked_at)) {
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

// Authoritative reconciliation read (contract §6): current enabled state,
// whether the caller's display copy matches authority, and whether the
// customer is adopted into server authority — never a token. Read-only: no
// operations row, no state write, NEVER adopts. A present-but-stale display
// token gets tokenValid:false → the UI shows the rotation-recovery path,
// never a share URL. Unknown/foreign customer stays 404 (no oracle).
async function statusCore(env, { userId, customerId, token }) {
  const customer = await fetchCustomerById(env, userId, customerId);
  if (!customer) return { status: 404, json: { error: 'Not found' } };
  const rows = await fetchCustomerTokenRows(env, userId, customerId);
  const live = rows.filter((r) => !r.revoked_at);
  if (live.length === 0) {
    // Unadopted: the blob display copy (when present) is still the
    // authority. A matching enabled copy validates; anything else does not.
    const blobPortal = customer.data && customer.data.portal;
    const blobToken = blobPortal && blobPortal.token;
    const enabled = blobPortal ? blobPortal.enabled !== false : false;
    const tokenValid =
      typeof token === 'string' &&
      typeof blobToken === 'string' &&
      enabled === true &&
      token === blobToken;
    return { status: 200, json: { ok: true, enabled, tokenValid, adopted: false } };
  }
  const current = live[0];
  const tokenValid =
    typeof token === 'string' &&
    current.enabled === true &&
    typeof current.token_hash === 'string' &&
    current.token_hash === sha256Hex(token);
  return { status: 200, json: { ok: true, enabled: current.enabled, tokenValid, adopted: true } };
}

module.exports = { portalManageCore, statusCore, legacyManageCore };
