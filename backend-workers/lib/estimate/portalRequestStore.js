// Write-side Supabase access for the portal-request path (Phase 12C). Kept
// SEPARATE from portalStore.js on purpose — that module is READ-ONLY by
// contract and stays that way; every portal write lives here.
//
// insertPortalRequest uses resolution=ignore-duplicates (NOT the booking
// store's merge-duplicates): the row id is deterministic per (token,
// requestKey), so a network retry re-POSTs the same id and MUST leave the
// existing row untouched — merge would clobber createdAt, handledAt, and the
// device's conversion stamps.

function headers(env) {
  return {
    Authorization: `Bearer ${env.SUPABASE_SERVICE_ROLE_KEY}`,
    apikey: env.SUPABASE_SERVICE_ROLE_KEY,
  };
}

async function insertPortalRequest(env, userId, request) {
  const res = await fetch(`${env.SUPABASE_URL}/rest/v1/bookingRequests`, {
    method: 'POST',
    headers: { ...headers(env), 'Content-Type': 'application/json', Prefer: 'resolution=ignore-duplicates' },
    body: JSON.stringify({
      id: request.id,
      user_id: userId,
      data: request,
      updated_at: new Date().toISOString(),
      deleted: false,
    }),
  });
  if (!res.ok) throw new Error(`Supabase insert ${res.status}: ${await res.text()}`);
}

// Best-effort security log (markLog convention: NEVER throws — a broken log
// table must not take the write path down). token_prefix only, never the
// raw token.
async function logPortalEvent(env, { userId, tokenPrefix, event, ip }) {
  try {
    await fetch(`${env.SUPABASE_URL}/rest/v1/portal_access_log`, {
      method: 'POST',
      headers: { ...headers(env), 'Content-Type': 'application/json' },
      body: JSON.stringify({ user_id: userId, token_prefix: tokenPrefix, event, ip: ip || null }),
    });
  } catch (err) {
    console.error('[estimate/portal-request] log failed:', err.message);
  }
}

// Rows logged for this token since UTC midnight — the durable daily cap
// input. Throws on failure; the CALLER decides to fail open.
async function countTodayRequests(env, { userId, tokenPrefix, nowMs }) {
  const midnight = new Date(nowMs).toISOString().slice(0, 10) + 'T00:00:00.000Z';
  const res = await fetch(
    `${env.SUPABASE_URL}/rest/v1/portal_access_log?user_id=eq.${encodeURIComponent(userId)}&token_prefix=eq.${encodeURIComponent(tokenPrefix)}&event=eq.request&created_at=gte.${encodeURIComponent(midnight)}&select=id&limit=6`,
    { headers: headers(env) }
  );
  if (!res.ok) throw new Error(`Supabase fetch ${res.status}: ${await res.text()}`);
  const rows = await res.json();
  return rows.length;
}

// The owner's settings blob — notifyOwner needs the push token inside it.
async function fetchSettingsData(env, userId) {
  const res = await fetch(
    `${env.SUPABASE_URL}/rest/v1/settings?user_id=eq.${encodeURIComponent(userId)}&select=data`,
    { headers: headers(env) }
  );
  if (!res.ok) throw new Error(`Supabase fetch ${res.status}: ${await res.text()}`);
  const rows = await res.json();
  return rows.length ? rows[0].data || {} : {};
}

module.exports = { insertPortalRequest, logPortalEvent, countTodayRequests, fetchSettingsData };
