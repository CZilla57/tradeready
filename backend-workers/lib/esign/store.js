// Supabase access for e-signature evidence (spec §3.5, §4, §11.10): the
// insert-only `signature_records`, `signature_pending` and `signature_events`
// tables, through the service role (no client grant writes any of them, and
// no client role can read `signature_pending`). Rows are never updated or
// deleted here; the migration's trigger refuses updates and only the
// auth.users cascade deletes.
//
// A link is (owner, job, change order, token hash). Records and pending rows
// are unique per (token hash, job, change order); every read filters on the
// job and change order, and on the owner wherever the caller knows it, so a
// token reused on another job (or learned by another owner) never reaches
// this link's record, pending signature or trail.
//
// Raw approval tokens never reach these tables — only their SHA-256.

const MAX_LIVE_EVENTS = 200;
const LINK_CONFLICT = 'approval_token_sha256,job_id,change_order_id';
const RECORD_COLUMNS = 'id,user_id,approval_token_sha256,job_id,change_order_id,document_type,record,record_digest,seal_alg,seal_key_id,seal,signed_at';
const PENDING_COLUMNS = 'id,user_id,approval_token_sha256,job_id,change_order_id,document_type,record,record_digest,signed_at';

function headers(env) {
  return {
    Authorization: `Bearer ${env.SUPABASE_SERVICE_ROLE_KEY}`,
    apikey: env.SUPABASE_SERVICE_ROLE_KEY,
  };
}

function rest(env, path) {
  return `${env.SUPABASE_URL}/rest/v1/${path}`;
}

const eq = (column, value) => `${column}=eq.${encodeURIComponent(value)}`;

// Error text for logs: the status and PostgREST's error code only. The body
// can echo the failing row ("Failing row contains (...)"), and a record row
// holds the signer's name, email and IP.
async function failure(what, res) {
  const body = await res.json().catch(() => null);
  const code = body && typeof body.code === 'string' ? ` ${body.code}` : '';
  return new Error(`Supabase ${what} ${res.status}${code}`);
}

// The filter for one link (or, without a token hash, one owner's job /
// change order). `jobId` is required; `changeOrderId` null means the
// estimate. At least one of `userId` / `tokenHash` must be given.
function linkQuery({ userId = null, jobId, changeOrderId = null, tokenHash = null, recordId = null }) {
  if (jobId == null || jobId === '') throw new Error('esign link lookup without a job id');
  if (userId == null && tokenHash == null) throw new Error('esign link lookup without an owner or a token');
  const parts = [];
  if (userId != null) parts.push(eq('user_id', userId));
  parts.push(eq('job_id', jobId));
  parts.push(changeOrderId == null ? 'change_order_id=is.null' : eq('change_order_id', changeOrderId));
  if (tokenHash != null) parts.push(eq('approval_token_sha256', tokenHash));
  if (recordId != null) parts.push(eq('id', recordId));
  return parts.join('&');
}

// Insert-if-absent per link. Returns true when THIS call created the row,
// false when that link already had one (idempotent re-seal). Throws on any
// other failure.
async function insertIfAbsent(env, table, row) {
  const res = await fetch(rest(env, `${table}?on_conflict=${LINK_CONFLICT}`), {
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

function insertRecord(env, row) {
  return insertIfAbsent(env, 'signature_records', row);
}

// The Worker-captured evidence of a signature whose first seal or insert
// failed (spec §3.5 step 4). The only input a lazy seal ever uses.
function insertPending(env, row) {
  return insertIfAbsent(env, 'signature_pending', row);
}

async function selectOne(env, table, columns, query) {
  const res = await fetch(rest(env, `${table}?${query}&select=${columns}&limit=1`), { headers: headers(env) });
  if (!res.ok) throw await failure('fetch', res);
  const rows = await res.json();
  return Array.isArray(rows) && rows.length ? rows[0] : null;
}

// The sealed record of one link, or (owner-scoped, no token) the newest for
// that job / change order; `recordId` pins one.
function fetchRecordForLink(env, link) {
  return selectOne(env, 'signature_records', RECORD_COLUMNS, `${linkQuery(link)}&order=signed_at.desc`);
}

function fetchPendingForLink(env, link) {
  return selectOne(env, 'signature_pending', PENDING_COLUMNS, `${linkQuery(link)}&order=created_at.desc`);
}

function fetchRecordById(env, recordId) {
  return selectOne(env, 'signature_records', RECORD_COLUMNS, eq('id', recordId));
}

// Owner-scoped: always filtered by user_id. `recordId` pins one record;
// otherwise the newest for that job / change order.
function fetchOwnerRecord(env, userId, { jobId, changeOrderId = null, recordId = null }) {
  if (!userId) throw new Error('owner record lookup without a user id');
  return fetchRecordForLink(env, { userId, jobId, changeOrderId, recordId });
}

// Best-effort event log (the logPortalEvent convention): NEVER throws, so a
// broken log table can't take a signing or a download down. Every row names
// its owner, job and change order.
async function logEvent(env, { userId, jobId, changeOrderId = null, tokenHash, event, ip = null, userAgent = null }) {
  try {
    const res = await fetch(rest(env, 'signature_events'), {
      method: 'POST',
      headers: { ...headers(env), 'Content-Type': 'application/json', Prefer: 'return=minimal' },
      body: JSON.stringify({
        user_id: userId,
        job_id: jobId == null ? null : String(jobId),
        change_order_id: changeOrderId == null ? null : String(changeOrderId),
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

// Events for one link (owner + job + change order + token hash, all
// required), oldest first. Throws; callers decide to degrade.
async function listEvents(env, { userId, jobId, changeOrderId = null, tokenHash }, { limit = MAX_LIVE_EVENTS, event = null } = {}) {
  if (!userId || !tokenHash) throw new Error('esign event lookup without an owner or a token');
  const filter = event ? `&${eq('event', event)}` : '';
  const res = await fetch(
    rest(env, `signature_events?${linkQuery({ userId, jobId, changeOrderId, tokenHash })}${filter}&select=id,event,ip,created_at&order=created_at.asc,id.asc&limit=${limit}`),
    { headers: headers(env) }
  );
  if (!res.ok) throw await failure('fetch', res);
  const rows = await res.json();
  return Array.isArray(rows) ? rows : [];
}

module.exports = {
  MAX_LIVE_EVENTS,
  LINK_CONFLICT,
  linkQuery,
  insertRecord,
  insertPending,
  fetchRecordForLink,
  fetchPendingForLink,
  fetchRecordById,
  fetchOwnerRecord,
  logEvent,
  listEvents,
};
