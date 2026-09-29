// Server-owned portal tokens (Phase 12D, decision D1-A). Stores sha256
// HASHES only — the raw token appears exactly once in the mint/rotate
// response and is never written anywhere server-side. This table is the auth
// AUTHORITY: disable and rotate take effect on the next request, no device
// sync round-trip (the v1 revocation-lag residual this phase closes).
//
// resolvePortalCustomer is the load-bearing contract:
//   1. hash known to the table + active  → authenticated (indexed PK hit).
//   2. hash known but revoked/disabled   → HARD STOP (null). Never fall
//      through to the blob — a rotated link's old token is in the table as
//      revoked, and this stop is what keeps it dead forever.
//   3. hash unknown → legacy blob lookup (pre-Phase-D tokens), with a
//      best-effort backfill so the next request takes the indexed path and
//      future rotation governs this link too.

const { createHash } = require('node:crypto');
const { lookupCustomerByPortalToken } = require('./portalStore.js');

function headers(env) {
  return {
    Authorization: `Bearer ${env.SUPABASE_SERVICE_ROLE_KEY}`,
    apikey: env.SUPABASE_SERVICE_ROLE_KEY,
  };
}

function sha256Hex(value) {
  return createHash('sha256').update(String(value)).digest('hex');
}

async function fetchTokenRow(env, tokenHash) {
  const res = await fetch(
    `${env.SUPABASE_URL}/rest/v1/portal_tokens?token_hash=eq.${encodeURIComponent(tokenHash)}&select=token_hash,user_id,customer_id,enabled,revoked_at`,
    { headers: headers(env) }
  );
  if (!res.ok) throw new Error(`Supabase fetch ${res.status}: ${await res.text()}`);
  const rows = await res.json();
  return rows.length ? rows[0] : null;
}

// Every row for a customer, any state — manage decides what matters.
async function fetchCustomerTokenRows(env, userId, customerId) {
  const res = await fetch(
    `${env.SUPABASE_URL}/rest/v1/portal_tokens?user_id=eq.${encodeURIComponent(userId)}&customer_id=eq.${encodeURIComponent(customerId)}&select=token_hash,enabled,revoked_at`,
    { headers: headers(env) }
  );
  if (!res.ok) throw new Error(`Supabase fetch ${res.status}: ${await res.text()}`);
  return res.json();
}

// ignore-duplicates: the resolver's lazy backfill can race itself across
// isolates — first write wins, the retry is a no-op.
async function insertTokenRow(env, { tokenHash, userId, customerId, enabled = true }) {
  const res = await fetch(`${env.SUPABASE_URL}/rest/v1/portal_tokens`, {
    method: 'POST',
    headers: { ...headers(env), 'Content-Type': 'application/json', Prefer: 'resolution=ignore-duplicates' },
    body: JSON.stringify({ token_hash: tokenHash, user_id: userId, customer_id: customerId, enabled }),
  });
  if (!res.ok) throw new Error(`Supabase insert ${res.status}: ${await res.text()}`);
}

// One-way: revoked_at never clears. Only non-revoked rows are touched, so
// historical revocation timestamps stay honest.
async function revokeCustomerTokens(env, userId, customerId) {
  const res = await fetch(
    `${env.SUPABASE_URL}/rest/v1/portal_tokens?user_id=eq.${encodeURIComponent(userId)}&customer_id=eq.${encodeURIComponent(customerId)}&revoked_at=is.null`,
    {
      method: 'PATCH',
      headers: { ...headers(env), 'Content-Type': 'application/json' },
      body: JSON.stringify({ enabled: false, revoked_at: new Date().toISOString() }),
    }
  );
  if (!res.ok) throw new Error(`Supabase patch ${res.status}: ${await res.text()}`);
}

async function setCustomerTokenEnabled(env, userId, customerId, enabled) {
  const res = await fetch(
    `${env.SUPABASE_URL}/rest/v1/portal_tokens?user_id=eq.${encodeURIComponent(userId)}&customer_id=eq.${encodeURIComponent(customerId)}&revoked_at=is.null`,
    {
      method: 'PATCH',
      headers: { ...headers(env), 'Content-Type': 'application/json' },
      body: JSON.stringify({ enabled }),
    }
  );
  if (!res.ok) throw new Error(`Supabase patch ${res.status}: ${await res.text()}`);
}

// ── Phase 8 task 8.06 (G4): transactional RPC ─────────────────────────────
// Same envelope discipline as the booking lane (store.js callBookingRpc): the
// RPC RETURNS jsonb {ok:true,...}/{ok:false,error,...} with HTTP 200, so a
// transport 404 on /rpc/admin_portal_token unambiguously means "function not
// deployed" → {unavailable:true} and the caller keeps the legacy split path
// byte-identically (adoption-gated dual writes, §10 step 3). A 200 body that
// is not an {ok:boolean} envelope is treated the same way.

async function callPortalRpc(env, fn, args) {
  let res;
  try {
    res = await fetch(`${env.SUPABASE_URL}/rest/v1/rpc/${fn}`, {
      method: 'POST',
      headers: { ...headers(env), 'Content-Type': 'application/json' },
      body: JSON.stringify(args),
    });
  } catch (err) {
    throw new Error(`Portal RPC ${fn} transport failed: ${err.message}`);
  }
  if (res.status === 404) return { unavailable: true };
  if (!res.ok) throw new Error(`Portal RPC ${fn} ${res.status}: ${await res.text()}`);
  let out;
  try {
    out = await res.json();
  } catch (err) {
    throw new Error(`Portal RPC ${fn} undecodable: ${err.message}`);
  }
  if (!out || typeof out.ok !== 'boolean') return { unavailable: true };
  return { unavailable: false, out };
}

// Canonical request hash (contract §1.3 as applied to §4): sha256 over the
// mutating intent only, scoped per customer. A retried POST carries the same
// intent; same operationId + different hash is a client bug →
// 409 operation_conflict.
function portalRequestHash(action, customerId, enabled) {
  return sha256Hex(JSON.stringify({ action, customerId, enabled: action === 'set_enabled' ? enabled : null }));
}

// The customer record by id — both-key scoped like every portal read.
async function fetchCustomerById(env, userId, customerId) {
  const res = await fetch(
    `${env.SUPABASE_URL}/rest/v1/customers?user_id=eq.${encodeURIComponent(userId)}&id=eq.${encodeURIComponent(customerId)}&deleted=eq.false&select=user_id,id,data`,
    { headers: headers(env) }
  );
  if (!res.ok) throw new Error(`Supabase fetch ${res.status}: ${await res.text()}`);
  const rows = await res.json();
  return rows.length ? rows[0] : null;
}

async function resolvePortalCustomer(env, token) {
  const hash = sha256Hex(token);
  const row = await fetchTokenRow(env, hash);
  if (row) {
    // Known hash: the table's word is FINAL — revoked/disabled never falls
    // through to the blob (see header). A live row still requires the
    // customer record to exist and be undeleted.
    if (!row.enabled || row.revoked_at) return null;
    return fetchCustomerById(env, row.user_id, row.customer_id);
  }
  // Unknown hash: legacy blob lookup, ADOPTION-GATED (contract §4). The blob
  // is authority only for customers the table never adopted (zero rows). A
  // customer with ≥1 portal_tokens row is adopted: an unknown hash fails
  // closed (null) even when a stale enabled blob token exists — that is the
  // G4-05 fix, and a conflicting/failed backfill must never authorize it.
  const legacy = await lookupCustomerByPortalToken(env, String(token));
  if (!legacy) return null;
  const existing = await fetchCustomerTokenRows(env, legacy.user_id, legacy.id);
  if (existing.length > 0) return null;
  try {
    await insertTokenRow(env, { tokenHash: hash, userId: legacy.user_id, customerId: legacy.id, enabled: true });
  } catch (err) {
    // Conflicting backfill (a rotation won the race and the single-active
    // index rejected us) authorizes nothing: re-read authority and fail
    // closed when rows now exist. A transient error with still-zero rows
    // keeps the pre-adoption blob authority (legacy behavior preserved).
    console.error('[portal-tokens] backfill failed:', err.message);
    let recheck = null;
    try {
      recheck = await fetchCustomerTokenRows(env, legacy.user_id, legacy.id);
    } catch (readErr) {
      console.error('[portal-tokens] backfill recheck failed:', readErr.message);
      return null;
    }
    if (recheck.length > 0) return null;
  }
  return legacy;
}

module.exports = {
  sha256Hex,
  fetchTokenRow,
  fetchCustomerTokenRows,
  insertTokenRow,
  revokeCustomerTokens,
  setCustomerTokenEnabled,
  fetchCustomerById,
  resolvePortalCustomer,
  callPortalRpc,
  portalRequestHash,
};
