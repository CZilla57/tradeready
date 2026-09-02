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

// --- Optimistic-concurrency helpers (ESTIMATE_WORKFLOW_ROADMAP.md, Phase 0) ---
//
// The old unconditional fetch -> modify -> write sequence raced when more than
// one writer (mobile, the Worker's own customer endpoints, and — soon — the web
// portal) touched the same job blob. These helpers add the versioned read +
// conditional write the workflow needs before that third writer lands.
//
// The database is the sole authority for `updated_at`: `set_updated_at_trg`
// (migration 20260831) stamps `now()` on every jobs insert/update, so the
// version read here is monotonic and the conditional write below never sends a
// timestamp of its own.

// Versioned read: like fetchJob but also selects `updated_at`, the value a
// conditional write must echo back. Returns { user_id, data, updated_at } | null.
async function fetchJobVersioned(env, jobId) {
  const res = await fetch(
    `${env.SUPABASE_URL}/rest/v1/jobs?id=eq.${encodeURIComponent(jobId)}&deleted=eq.false&select=user_id,data,updated_at`,
    { headers: headers(env) }
  );
  if (!res.ok) throw new Error(`Supabase fetch ${res.status}: ${await res.text()}`);
  const rows = await res.json();
  return rows.length ? rows[0] : null;
}

// Owner-scoped versioned read. Returns the row only when it belongs to userId.
async function fetchJobForUserVersioned(env, jobId, userId) {
  const res = await fetch(
    `${env.SUPABASE_URL}/rest/v1/jobs?id=eq.${encodeURIComponent(jobId)}&user_id=eq.${encodeURIComponent(userId)}&deleted=eq.false&select=user_id,data,updated_at`,
    { headers: headers(env) }
  );
  if (!res.ok) throw new Error(`Supabase fetch ${res.status}: ${await res.text()}`);
  const rows = await res.json();
  return rows.length ? rows[0] : null;
}

// Conditional write primitive. PATCHes `data` onto the job ONLY while its stored
// `updated_at` still equals expectedUpdatedAt (the value a versioned read
// returned). The trigger owns the new timestamp, so the body carries `data`
// only, and the fresh row (including its new `updated_at`) is read back via
// return=representation.
//
// Returns { updated: true, row } on success, or { updated: false } when the
// guard matched zero rows — the version moved or the row was deleted. A
// zero-row PATCH is a CONFLICT, never a silent success (roadmap behavior #3).
// Throws only on a transport/HTTP error, which callers must not treat as a
// conflict.
async function conditionalUpdateJob(env, id, expectedUpdatedAt, data) {
  const query =
    `id=eq.${encodeURIComponent(id)}` +
    `&updated_at=eq.${encodeURIComponent(expectedUpdatedAt)}` +
    `&deleted=eq.false` +
    `&select=user_id,data,updated_at`;
  const res = await fetch(`${env.SUPABASE_URL}/rest/v1/jobs?${query}`, {
    method: 'PATCH',
    headers: { ...headers(env), 'Content-Type': 'application/json', Prefer: 'return=representation' },
    body: JSON.stringify({ data }),
  });
  if (!res.ok) throw new Error(`Supabase conditional update ${res.status}: ${await res.text()}`);
  const rows = await res.json();
  if (!rows.length) return { updated: false };
  return { updated: true, row: rows[0] };
}

// Bounded optimistic-concurrency loop. Reads the freshest job via `fetchRow`,
// asks the operation-specific `plan` what to write, and conditionally persists
// it against the version just read. On a version conflict it refetches and
// re-plans against the new row, up to `tries` times. Domain merge rules stay in
// `plan` (per the roadmap's operation-specific merge table); generic version
// handling stays here.
//
// `fetchRow()` must return a versioned row ({ ..., updated_at }) or null.
// `plan(row)` returns exactly one of:
//   { data }              -> the blob to write onto the job
//   { skip: true }        -> already in the desired state; no write needed
//   { conflict, reason }  -> the fresh row can no longer accept the operation
//
// Resolves to one of:
//   { ok: true,  changed: true,  row }   (written; row is the fresh post-write)
//   { ok: true,  changed: false, row }   (skipped; row is the version read)
//   { ok: false, notFound: true }        (row missing)
//   { ok: false, conflict: true, reason} (plan-refused, or retries exhausted)
async function updateJobConditionally(env, jobId, fetchRow, plan, { tries = 3 } = {}) {
  let row = await fetchRow();
  for (let attempt = 0; attempt < tries; attempt++) {
    if (!row) return { ok: false, notFound: true };
    const planned = plan(row);
    if (planned.skip) return { ok: true, changed: false, row };
    if (planned.conflict) return { ok: false, conflict: true, reason: planned.reason };
    const result = await conditionalUpdateJob(env, jobId, row.updated_at, planned.data);
    if (result.updated) return { ok: true, changed: true, row: result.row };
    // Version moved between our read and write — refetch and let plan re-decide.
    row = await fetchRow();
  }
  return { ok: false, conflict: true, reason: 'max-retries' };
}

// The former unconditional `upsertJob` (POST + resolution=merge-duplicates) was
// removed once every approval mutation moved onto conditionalUpdateJob — the
// roadmap forbids keeping an unconditional upsert for these writes, since it is
// exactly the last-writer-wins path that loses a concurrent customer decision.

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

module.exports = {
  fetchJob,
  fetchJobForUser,
  constantTimeEqual,
  planApprovalWrite,
  fetchJobVersioned,
  fetchJobForUserVersioned,
  conditionalUpdateJob,
  updateJobConditionally,
};
