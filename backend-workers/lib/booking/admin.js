// backend-workers/lib/booking/admin.js
// Handler core for POST /api/booking/admin (Phase 8 task 8.05, contract
// decisions §1 G3 verbatim): server-authoritative booking-link
// administration — create/enable/disable/rotate plus replay by operationId
// and the authoritative status read for native reconciliation (§6).
//
// Atomicity lives in the `admin_booking_link` RPC
// (supabase/migrations/20260921_booking_admin_state.sql): per-owner lock
// first (same advisory key as the 8.04 RPCs, §2.3 ordering root), then
// replay lookup → revision check → state write + operations-row insert in ONE
// transaction. This core validates input, owns server RNG input (rawToken is
// injected by the route wrapper so tests are deterministic), builds the
// replay-stable request hash, and maps the RPC envelope to HTTP verdicts.
// Time (`nowMs`) is injected for the same reason; the RPC owns timestamps.
//
// Response-loss model (explicit, §1.3/§1.5): a timeout after a mutation is an
// UNKNOWN outcome — the client retries with the SAME operationId and gets the
// stored copy back (never a second capability). Same operationId + different
// request hash is a client bug → 409 operation_conflict.
//
// The raw token is returned EXACTLY ONCE per operation (replay returns the
// stored copy). The state table holds hashes only; rotation (new
// operationId) is the recovery path for a lost display copy — there is no
// reveal endpoint by design (§1.4). Manage tokens are independent: nothing
// here touches bookingRequests.

const {
  bookingLinkStateByUserId,
  sha256Hex,
  callBookingRpc,
} = require('./store.js');

const UUID_V4_RE =
  /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-4[0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$/;

const MUTATIONS = ['mint', 'set_enabled', 'rotate'];

// Canonical request hash (§1.3): sha256 over the mutating intent only.
// expectedRevision is a precondition, not intent, so it is EXCLUDED — a
// retried POST carries the same intent even if the caller's revision view is
// stale (the RPC answers replay before checking revisions).
function requestHash(action, enabled) {
  return sha256Hex(JSON.stringify({ action, enabled: action === 'set_enabled' ? enabled : null }));
}

async function adminCore(env, { userId, body, rawToken }) {
  const action = body && body.action;
  if (action === 'status') return statusCore(env, { userId, token: body.token });
  if (!MUTATIONS.includes(action)) return { status: 400, body: { error: 'Invalid action.' } };

  const operationId = body.operationId;
  if (!operationId || typeof operationId !== 'string') {
    return { status: 400, body: { error: 'Missing operation id.' } };
  }
  if (!UUID_V4_RE.test(operationId)) {
    return { status: 400, body: { error: 'Invalid operation id.' } };
  }

  let enabled = null;
  if (action === 'set_enabled') {
    if (typeof body.enabled !== 'boolean') {
      return { status: 400, body: { error: 'Invalid enabled value.' } };
    }
    enabled = body.enabled;
  }

  let expectedRevision = null;
  if (body.expectedRevision !== undefined) {
    if (!Number.isInteger(body.expectedRevision) || body.expectedRevision < 0) {
      return { status: 400, body: { error: 'Invalid expected revision.' } };
    }
    expectedRevision = body.expectedRevision;
  }

  // The response TEMPLATE the RPC stamps (enabled + revision from the
  // committed row) and stores verbatim for replay. The raw token travels
  // here for mint/rotate only — status never sees one (§1.2).
  const needsToken = action === 'mint' || action === 'rotate';
  if (needsToken && (!rawToken || typeof rawToken !== 'string')) {
    console.error('[booking/admin] no server token for mint/rotate');
    return { status: 500, body: { error: 'Database error' } };
  }
  const result = { ok: true, operationId };
  if (needsToken) result.token = rawToken;

  let called;
  try {
    called = await callBookingRpc(env, 'admin_booking_link', {
      p_user_id: userId,
      p_action: action,
      p_operation_id: operationId,
      p_request_hash: requestHash(action, enabled),
      p_enabled: enabled,
      p_expected_revision: expectedRevision,
      p_token_hash: needsToken ? sha256Hex(rawToken) : null,
      p_result: result,
    });
  } catch (err) {
    console.error('[booking/admin] RPC failed:', err.message);
    return { status: 500, body: { error: 'Database error' } };
  }
  // New route, no legacy path: a missing function is a deploy-ordering bug,
  // never a fallback (there is no pre-admin behavior to preserve).
  if (called.unavailable) {
    console.error('[booking/admin] admin_booking_link not deployed');
    return { status: 500, body: { error: 'Database error' } };
  }

  const out = called.out;
  if (out.ok) return { status: 200, body: out.response };
  if (out.error === 'already_exists' || out.error === 'operation_conflict') {
    return { status: 409, body: { error: out.error } };
  }
  if (out.error === 'stale_revision') {
    // Current state echoed so the caller reconciles without a second round
    // trip (§1.4). Additive fields — old clients matching on `error` are
    // unaffected (and no old client calls this new endpoint).
    return { status: 409, body: { error: 'stale_revision', enabled: out.enabled, revision: out.revision } };
  }
  if (out.error === 'not_found') {
    // set_enabled with no state row; or a foreign operationId (no oracle).
    return { status: 404, body: { error: 'Not found' } };
  }
  console.error('[booking/admin] unexpected envelope:', out.error);
  return { status: 500, body: { error: 'Database error' } };
}

// Authoritative reconciliation read (§6): current enabled state/revision,
// whether the caller's display copy matches authority, and never a token.
// Read-only: no operations row, no revision bump, NEVER adopts (an adopted
// row can only be created by a committed mutation). A present-but-stale
// display token gets tokenValid:false → the UI shows the rotation-recovery
// path, never a share URL.
async function statusCore(env, { userId, token }) {
  let state;
  try {
    state = await bookingLinkStateByUserId(env, userId);
  } catch (err) {
    console.error('[booking/admin] status lookup failed:', err.message);
    return { status: 500, body: { error: 'Database error' } };
  }
  const row = state.available ? state.row : null;
  if (!row) {
    // Fresh owner, nothing to reconcile — 200, never 404 (§1.2).
    return { status: 200, body: { ok: true, enabled: false, revision: 0, tokenValid: false } };
  }
  const tokenValid =
    typeof token === 'string' &&
    row.enabled === true &&
    typeof row.token_hash === 'string' &&
    row.token_hash === sha256Hex(token);
  return {
    status: 200,
    body: { ok: true, enabled: row.enabled, revision: row.revision, tokenValid },
  };
}

module.exports = { adminCore, statusCore, requestHash };
