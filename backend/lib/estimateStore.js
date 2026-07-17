// Shared Supabase access for the estimate-approval endpoints. Uses the service
// role key (bypasses owner-scoped RLS) exactly like backend/api/stripe/webhook.js.
// NOT routed by Vercel (lives under lib/, not api/).

const crypto = require('crypto');

const SUPABASE_URL = process.env.SUPABASE_URL;
const SUPABASE_SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;

function headers() {
  return {
    Authorization: `Bearer ${SUPABASE_SERVICE_ROLE_KEY}`,
    apikey: SUPABASE_SERVICE_ROLE_KEY,
  };
}

// Returns { user_id, data } or null.
async function fetchJob(jobId) {
  const res = await fetch(
    `${SUPABASE_URL}/rest/v1/jobs?id=eq.${encodeURIComponent(jobId)}&deleted=eq.false&select=user_id,data`,
    { headers: headers() }
  );
  if (!res.ok) throw new Error(`Supabase fetch ${res.status}: ${await res.text()}`);
  const rows = await res.json();
  return rows.length ? rows[0] : null;
}

// Returns { user_id, data } only if the row belongs to userId; else null.
async function fetchJobForUser(jobId, userId) {
  const res = await fetch(
    `${SUPABASE_URL}/rest/v1/jobs?id=eq.${encodeURIComponent(jobId)}&user_id=eq.${encodeURIComponent(userId)}&deleted=eq.false&select=user_id,data`,
    { headers: headers() }
  );
  if (!res.ok) throw new Error(`Supabase fetch ${res.status}: ${await res.text()}`);
  const rows = await res.json();
  return rows.length ? rows[0] : null;
}

async function upsertJob(id, userId, data) {
  const res = await fetch(`${SUPABASE_URL}/rest/v1/jobs`, {
    method: 'POST',
    headers: { ...headers(), 'Content-Type': 'application/json', Prefer: 'resolution=merge-duplicates' },
    body: JSON.stringify({
      id,
      user_id: userId,
      data,
      updated_at: new Date().toISOString(),
      deleted: false,
    }),
  });
  if (!res.ok) throw new Error(`Supabase upsert ${res.status}: ${await res.text()}`);
}

// Length-safe constant-time string compare (both must be non-empty strings).
function constantTimeEqual(a, b) {
  if (typeof a !== 'string' || typeof b !== 'string' || a.length === 0 || b.length === 0) return false;
  const ba = Buffer.from(a);
  const bb = Buffer.from(b);
  if (ba.length !== bb.length) return false;
  return crypto.timingSafeEqual(ba, bb);
}

// Decides the approval object to persist when (re)generating an approval link.
// Consent integrity: once a job is APPROVED, its snapshot is frozen — re-sending
// returns the existing link unchanged and never overwrites the approved snapshot.
// `mintToken` is injected (not called here) so this stays pure/deterministic.
function planApprovalWrite(existing, snapshot, sentAt, mintToken) {
  const prev = existing || {};
  if (prev.decision === 'approved' && prev.token) {
    return { approval: prev, changed: false, token: prev.token, sentAt: prev.sentAt };
  }
  const token = prev.token || mintToken();
  return {
    approval: { ...prev, token, sentAt, snapshot },
    changed: true,
    token,
    sentAt,
  };
}

module.exports = { fetchJob, fetchJobForUser, upsertJob, constantTimeEqual, planApprovalWrite };
