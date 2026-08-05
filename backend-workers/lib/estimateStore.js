// Shared Supabase access for the estimate-approval endpoints. Uses the service
// role key (bypasses owner-scoped RLS) exactly like the Stripe webhook.
//
// Workers port of backend/lib/estimateStore.js: env vars arrive as the `env`
// parameter (Workers bindings) instead of module-level process.env reads.

const { constantTimeEqual } = require('./constantTime');

function headers(env) {
  return {
    Authorization: `Bearer ${env.SUPABASE_SERVICE_ROLE_KEY}`,
    apikey: env.SUPABASE_SERVICE_ROLE_KEY,
  };
}

// Returns { user_id, data } or null.
async function fetchJob(env, jobId) {
  const res = await fetch(
    `${env.SUPABASE_URL}/rest/v1/jobs?id=eq.${encodeURIComponent(jobId)}&deleted=eq.false&select=user_id,data`,
    { headers: headers(env) }
  );
  if (!res.ok) throw new Error(`Supabase fetch ${res.status}: ${await res.text()}`);
  const rows = await res.json();
  return rows.length ? rows[0] : null;
}

// Returns { user_id, data } only if the row belongs to userId; else null.
async function fetchJobForUser(env, jobId, userId) {
  const res = await fetch(
    `${env.SUPABASE_URL}/rest/v1/jobs?id=eq.${encodeURIComponent(jobId)}&user_id=eq.${encodeURIComponent(userId)}&deleted=eq.false&select=user_id,data`,
    { headers: headers(env) }
  );
  if (!res.ok) throw new Error(`Supabase fetch ${res.status}: ${await res.text()}`);
  const rows = await res.json();
  return rows.length ? rows[0] : null;
}

async function upsertJob(env, id, userId, data) {
  const res = await fetch(`${env.SUPABASE_URL}/rest/v1/jobs`, {
    method: 'POST',
    headers: { ...headers(env), 'Content-Type': 'application/json', Prefer: 'resolution=merge-duplicates' },
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

// constantTimeEqual moved to ./constantTime.js (shared with the RevenueCat
// subscription webhook); re-exported below so existing importers keep working.

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
