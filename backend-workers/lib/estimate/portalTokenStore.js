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
  const legacy = await lookupCustomerByPortalToken(env, String(token));
  if (!legacy) return null;
  try {
    await insertTokenRow(env, { tokenHash: hash, userId: legacy.user_id, customerId: legacy.id, enabled: true });
  } catch (err) {
    console.error('[portal-tokens] backfill failed:', err.message);
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
};
