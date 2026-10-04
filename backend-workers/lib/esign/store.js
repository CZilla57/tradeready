// Supabase access for e-signature evidence (spec §3.5, §4): the insert-only
// `signature_records` and `signature_events` tables, through the service
// role (no client grant writes either table). Records are never updated or
// deleted here; the migration's trigger refuses updates and only the
// auth.users cascade deletes.
//
// Raw approval tokens never reach these tables — only their SHA-256.

const MAX_LIVE_EVENTS = 200;
const RECORD_COLUMNS = 'id,user_id,approval_token_sha256,job_id,change_order_id,document_type,record,record_digest,seal_alg,seal_key_id,seal,signed_at';

function headers(env) {
  return {
    Authorization: `Bearer ${env.SUPABASE_SERVICE_ROLE_KEY}`,
    apikey: env.SUPABASE_SERVICE_ROLE_KEY,
  };
}

function rest(env, path) {
  return `${env.SUPABASE_URL}/rest/v1/${path}`;
}

// Error text for logs: the status and PostgREST's error code only. The body
// can echo the failing row ("Failing row contains (...)"), and a record row
// holds the signer's name, email and IP.
async function failure(what, res) {
  const body = await res.json().catch(() => null);
  const code = body && typeof body.code === 'string' ? ` ${body.code}` : '';
  return new Error(`Supabase ${what} ${res.status}${code}`);
}

// Insert-if-absent on the token hash. Returns true when THIS call created the
// row, false when a record for that token already existed (idempotent
// re-seal). Throws on any other failure.
async function insertRecord(env, row) {
  const res = await fetch(rest(env, 'signature_records?on_conflict=approval_token_sha256'), {
    method: 'POST',
    headers: {
      ...headers(env),
      'Content-Type': 'application/json',
      Prefer: 'resolution=ignore-duplicates,return=representation',
    },
    body: JSON.stringify(row),
  });
  if (!res.ok) throw await failure('insert', res);
  const rows = await res.json().catch(() => []);
  return Array.isArray(rows) && rows.length > 0;
}

async function selectOne(env, query) {
  const res = await fetch(rest(env, `signature_records?${query}&select=${RECORD_COLUMNS}&limit=1`), { headers: headers(env) });
  if (!res.ok) throw await failure('fetch', res);
  const rows = await res.json();
  return Array.isArray(rows) && rows.length ? rows[0] : null;
}

function fetchRecordByTokenHash(env, tokenHash) {
  return selectOne(env, `approval_token_sha256=eq.${encodeURIComponent(tokenHash)}`);
}

function fetchRecordById(env, recordId) {
  return selectOne(env, `id=eq.${encodeURIComponent(recordId)}`);
}

// Owner-scoped: always filtered by user_id. `recordId` pins one record;
// otherwise the newest for that job / change order.
function fetchOwnerRecord(env, userId, { jobId, changeOrderId = null, recordId = null }) {
  const parts = [
    `user_id=eq.${encodeURIComponent(userId)}`,
    `job_id=eq.${encodeURIComponent(jobId)}`,
    changeOrderId == null ? 'change_order_id=is.null' : `change_order_id=eq.${encodeURIComponent(changeOrderId)}`,
  ];
  if (recordId) parts.push(`id=eq.${encodeURIComponent(recordId)}`);
  return selectOne(env, `${parts.join('&')}&order=signed_at.desc`);
}

// Best-effort event log (the logPortalEvent convention): NEVER throws, so a
// broken log table can't take a signing or a download down.
async function logEvent(env, { userId, tokenHash, event, ip = null, userAgent = null }) {
  try {
    const res = await fetch(rest(env, 'signature_events'), {
      method: 'POST',
      headers: { ...headers(env), 'Content-Type': 'application/json', Prefer: 'return=minimal' },
      body: JSON.stringify({
        user_id: userId,
        approval_token_sha256: tokenHash,
        event,
        ip: ip || null,
        user_agent: userAgent ? String(userAgent).slice(0, 300) : null,
      }),
    });
    if (!res.ok) console.error('[esign] event log non-2xx', event, res.status);
  } catch (err) {
    console.error('[esign] event log failed:', event, err.message);
  }
}

// Events for one link, oldest first. Throws; callers decide to degrade.
async function listEvents(env, tokenHash, { limit = MAX_LIVE_EVENTS, event = null } = {}) {
  const filter = event ? `&event=eq.${encodeURIComponent(event)}` : '';
  const res = await fetch(
    rest(env, `signature_events?approval_token_sha256=eq.${encodeURIComponent(tokenHash)}${filter}&select=id,event,ip,created_at&order=created_at.asc,id.asc&limit=${limit}`),
    { headers: headers(env) }
  );
  if (!res.ok) throw await failure('fetch', res);
  const rows = await res.json();
  return Array.isArray(rows) ? rows : [];
}

module.exports = {
  MAX_LIVE_EVENTS,
  insertRecord,
  fetchRecordByTokenHash,
  fetchRecordById,
  fetchOwnerRecord,
  logEvent,
  listEvents,
};
