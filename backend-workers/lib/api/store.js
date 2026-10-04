// READ-ONLY data access for the open API (spec §1.5, §5). Read-only is an
// invariant enforced three ways; this module is the second:
//   1. the /v1 router answers 405 to every method but GET;
//   2. this module has exactly one fetch call, hard-wired to GET, and
//      PostgREST runs every GET in a READ ONLY transaction whatever key it
//      carries;
//   3. tests fail on any non-GET to a business table.
// Writes the API needs (the authorize RPC, the access log) live in
// auth.js, never here.
//
// Tenant isolation: every URL is built by ownerQuery(), which ALWAYS adds
// user_id=eq.<owner> first and refuses a non-UUID owner. There is no other
// way to build a URL in this file. Route tests assert the filter on every
// fetch.

const READ_TABLES = new Set(['customers', 'jobs', 'invoices', 'expenses', 'trips', 'settings']);
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const ROW_SELECT = 'id,updated_at,deleted,data';

function headers(env) {
  return {
    Authorization: `Bearer ${env.SUPABASE_SERVICE_ROLE_KEY}`,
    apikey: env.SUPABASE_SERVICE_ROLE_KEY,
  };
}

// PostgREST logic-tree value quoting: reserved characters (, . : ( ) and
// spaces) are safe inside double quotes; backslash escapes " and \.
function quote(value) {
  return `"${String(value).replace(/\\/g, '\\\\').replace(/"/g, '\\"')}"`;
}

function ownerQuery(env, table, userId, params) {
  if (!READ_TABLES.has(table)) throw new Error(`open API store: table ${table} is not readable`);
  if (typeof userId !== 'string' || !UUID_RE.test(userId)) throw new Error('open API store: owner id required');
  const qs = [`user_id=eq.${encodeURIComponent(userId)}`];
  for (const [name, value] of params) {
    if (name === 'user_id') throw new Error('open API store: the owner filter is not overridable');
    qs.push(`${encodeURIComponent(name)}=${encodeURIComponent(value)}`);
  }
  return `${env.SUPABASE_URL}/rest/v1/${table}?${qs.join('&')}`;
}

async function getRows(env, url) {
  const res = await fetch(url, { method: 'GET', headers: headers(env) });
  if (!res.ok) throw new Error(`open API read failed (${res.status})`);
  const rows = await res.json();
  if (!Array.isArray(rows)) throw new Error('open API read returned a non-array');
  return rows;
}

// One keyset page: `limit + 1` rows ordered (updated_at, id) ascending, so
// the caller can tell whether another page exists. Deleted rows are fetched
// only when the caller is syncing (updatedSince given) and become
// tombstones upstream.
async function listRows(env, { table, userId, filter, after, updatedSince, limit }) {
  const ands = [];
  if (filter) ands.push(filter);
  if (after) {
    const u = quote(after.updatedAt);
    ands.push(`or(updated_at.gt.${u},and(updated_at.eq.${u},id.gt.${quote(after.id)}))`);
  }
  const params = [['select', ROW_SELECT]];
  if (ands.length > 0) params.push(['and', `(${ands.join(',')})`]);
  if (updatedSince) params.push(['updated_at', `gte.${updatedSince}`]);
  else params.push(['deleted', 'is.false']);
  params.push(['order', 'updated_at.asc,id.asc'], ['limit', String(limit + 1)]);
  return getRows(env, ownerQuery(env, table, userId, params));
}

// One live row by id, or null. Deleted rows are never returned, so a
// deleted, missing or other-owner id are indistinguishable (404).
async function getRow(env, { table, userId, id }) {
  const rows = await getRows(env, ownerQuery(env, table, userId, [
    ['select', ROW_SELECT],
    ['id', `eq.${id}`],
    ['deleted', 'is.false'],
    ['limit', '1'],
  ]));
  return rows.length ? rows[0] : null;
}

// The live invoice whose ledger holds this payment id (jsonb containment).
async function getInvoiceByPaymentId(env, { userId, paymentId }) {
  const rows = await getRows(env, ownerQuery(env, 'invoices', userId, [
    ['select', ROW_SELECT],
    ['data->payments', `cs.${JSON.stringify([{ id: paymentId }])}`],
    ['deleted', 'is.false'],
    ['limit', '1'],
  ]));
  return rows.length ? rows[0] : null;
}

// Newest server updated_at across the owner's rows in the table, deleted
// ones included (a delete is a change). One indexed read.
async function newestUpdatedAt(env, { table, userId }) {
  const rows = await getRows(env, ownerQuery(env, table, userId, [
    ['select', 'updated_at'],
    ['order', 'updated_at.desc'],
    ['limit', '1'],
  ]));
  return rows.length ? rows[0].updated_at || null : null;
}

// Only businessName crosses into Worker memory — the settings blob also
// holds vendor API keys, the booking token and the push token, so the
// select names the one JSON path instead of fetching `data`.
async function fetchBusinessName(env, { userId }) {
  const rows = await getRows(env, ownerQuery(env, 'settings', userId, [
    ['select', 'businessName:data->>businessName'],
    ['limit', '1'],
  ]));
  return rows.length && typeof rows[0].businessName === 'string' ? rows[0].businessName : null;
}

module.exports = {
  READ_TABLES,
  ROW_SELECT,
  quote,
  ownerQuery,
  listRows,
  getRow,
  getInvoiceByPaymentId,
  newestUpdatedAt,
  fetchBusinessName,
};
