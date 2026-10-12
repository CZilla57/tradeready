// Owner-side API key management (spec §2 "Management endpoint"; contract in
// the spec's build record §14.1). The route shell
// (src/routes/api/keysManage.js) verifies the Supabase JWT and the
// per-user rate limit; everything else is here and tested.
//
// Invariants:
// - The raw key is minted from Worker CSPRNG bytes and tagged with
//   API_KEY_TAG_SECRET (keys.js mintApiKey; the key embeds its own api_keys
//   id and the owner id), returned exactly once in the create/rotate 200
//   body, and NEVER written anywhere: the RPC receives only its sha256 hash,
//   its 12-character display prefix and the new key id. Without the tag
//   secret create/rotate answer 503 `unavailable` before any database
//   contact — an untagged key is never minted. There is no
//   replay table holding it (unlike portal_operations), so a replayed
//   operationId gets 409 already_completed with the key's id and prefix and
//   no secret — the price of never storing the raw key (decision D4).
// - create/rotate/revoke are one `api_key_admin` RPC transaction under a
//   per-owner advisory lock, which enforces the 5-live-key cap and the
//   rotate-and-expire pairing. Ownership is checked inside the function.
// - list/activity are owner-scoped GETs that name their columns; key_hash
//   (and the operation bookkeeping columns) are never selected.

const keys = require('./keys.js');

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const UUID_V4_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const ACTIONS = new Set(['list', 'create', 'rotate', 'revoke', 'activity']);
const KEY_COLUMNS = 'id,name,key_prefix,scopes,created_at,expires_at,revoked_at,last_used_at,replaced_by';
const HISTORY_LIMIT = 50;
const ACTIVITY_LIMIT = 50;

function headers(env, extra = {}) {
  return {
    Authorization: `Bearer ${env.SUPABASE_SERVICE_ROLE_KEY}`,
    apikey: env.SUPABASE_SERVICE_ROLE_KEY,
    ...extra,
  };
}

function iso(value) {
  if (typeof value !== 'string' || value.length === 0) return null;
  const ms = Date.parse(value);
  return Number.isFinite(ms) ? new Date(ms).toISOString() : null;
}

function keyStatus(row, nowMs) {
  if (row.revoked_at) return 'revoked';
  const expires = row.expires_at ? Date.parse(row.expires_at) : NaN;
  if (Number.isFinite(expires) && expires <= nowMs) return 'expired';
  if (row.replaced_by) return 'expiring';
  return 'active';
}

// One mapper for every key the app sees (RPC rows and REST rows alike).
function toKeySummary(row, nowMs) {
  const r = row && typeof row === 'object' ? row : {};
  const scopes = Array.isArray(r.scopes) ? r.scopes : [];
  return {
    id: String(r.id ?? ''),
    name: typeof r.name === 'string' ? r.name : '',
    prefix: typeof r.key_prefix === 'string' ? r.key_prefix : '',
    scopes: keys.SCOPES.filter((s) => scopes.includes(s)),
    createdAt: iso(r.created_at),
    expiresAt: iso(r.expires_at),
    revokedAt: iso(r.revoked_at),
    lastUsedAt: iso(r.last_used_at),
    replacedBy: r.replaced_by ? String(r.replaced_by) : null,
    status: keyStatus(r, nowMs),
  };
}

// Canonical request hash: the mutating intent only. Same operationId with a
// different hash → 409 operation_conflict.
function requestHash(intent) {
  return keys.sha256Hex(JSON.stringify(intent));
}

async function callAdminRpc(env, args) {
  let res;
  try {
    res = await fetch(`${env.SUPABASE_URL}/rest/v1/rpc/api_key_admin`, {
      method: 'POST',
      headers: headers(env, { 'Content-Type': 'application/json' }),
      body: JSON.stringify(args),
    });
  } catch (err) {
    throw new Error(`api_key_admin transport failed: ${err.message}`);
  }
  if (res.status === 404) return { unavailable: true };
  if (!res.ok) throw new Error(`api_key_admin returned ${res.status}`);
  let out;
  try {
    out = await res.json();
  } catch {
    return { unavailable: true };
  }
  if (!out || typeof out.ok !== 'boolean') return { unavailable: true };
  return { unavailable: false, out };
}

async function getJson(env, path) {
  const res = await fetch(`${env.SUPABASE_URL}/rest/v1/${path}`, { headers: headers(env) });
  if (res.status === 404) return { unavailable: true };
  if (!res.ok) throw new Error(`api key read failed (${res.status})`);
  const rows = await res.json();
  if (!Array.isArray(rows)) throw new Error('api key read returned a non-array');
  return { unavailable: false, rows };
}

const ERR = (status, error, extra = {}) => ({ status, json: { error, ...extra } });

function mapRpcError(out) {
  switch (out.error) {
    case 'key_limit': return ERR(409, 'key_limit', { maxLiveKeys: keys.MAX_LIVE_KEYS });
    case 'not_found': return ERR(404, 'not_found');
    case 'operation_conflict': return ERR(409, 'operation_conflict');
    case 'already_completed': {
      const k = out.key && typeof out.key === 'object' ? out.key : {};
      return ERR(409, 'already_completed', {
        key: { id: String(k.id ?? ''), prefix: typeof k.key_prefix === 'string' ? k.key_prefix : '' },
      });
    }
    case 'invalid_args':
    case 'invalid_action': return ERR(400, 'invalid_request');
    default: return null;
  }
}

async function listCore(env, { userId, nowMs }) {
  const owner = `user_id=eq.${encodeURIComponent(userId)}`;
  const nowIso = new Date(nowMs).toISOString();
  // Every non-revoked unexpired key (bounded: ≤5 active plus rotation
  // graces), plus the most recent history, merged by id.
  const [live, recent] = await Promise.all([
    getJson(env, `api_keys?${owner}&revoked_at=is.null&or=${encodeURIComponent(`(expires_at.is.null,expires_at.gt."${nowIso}")`)}&select=${KEY_COLUMNS}&order=created_at.desc`),
    getJson(env, `api_keys?${owner}&select=${KEY_COLUMNS}&order=created_at.desc&limit=${HISTORY_LIMIT}`),
  ]);
  if (live.unavailable || recent.unavailable) return ERR(503, 'unavailable');
  const byId = new Map();
  for (const row of [...live.rows, ...recent.rows]) byId.set(String(row.id), row);
  const summaries = [...byId.values()]
    .map((row) => toKeySummary(row, nowMs))
    .sort((a, b) => (a.createdAt < b.createdAt ? 1 : a.createdAt > b.createdAt ? -1 : 0));
  return {
    status: 200,
    json: {
      ok: true,
      keys: summaries,
      liveCount: summaries.filter((k) => k.status === 'active').length,
      maxLiveKeys: keys.MAX_LIVE_KEYS,
    },
  };
}

async function activityCore(env, { userId, body }) {
  let filter = '';
  if (body.keyId !== undefined) {
    if (typeof body.keyId !== 'string' || !UUID_RE.test(body.keyId)) return ERR(400, 'invalid_request');
    filter = `&key_id=eq.${encodeURIComponent(body.keyId)}`;
  }
  const got = await getJson(
    env,
    `api_access_log?user_id=eq.${encodeURIComponent(userId)}${filter}&select=created_at,key_id,event,route,status,ip&order=created_at.desc&limit=${ACTIVITY_LIMIT}`
  );
  if (got.unavailable) return ERR(503, 'unavailable');
  return {
    status: 200,
    json: {
      ok: true,
      events: got.rows.map((r) => ({
        at: iso(r.created_at),
        keyId: String(r.key_id ?? ''),
        event: typeof r.event === 'string' ? r.event : '',
        route: typeof r.route === 'string' ? r.route : '',
        status: Number.isFinite(Number(r.status)) ? Number(r.status) : 0,
        ip: typeof r.ip === 'string' ? r.ip : null,
      })),
    },
  };
}

// randomBytes: (n) => Buffer(n), injected so tests are deterministic and the
// route uses node:crypto's CSPRNG. Called for 16 bytes (the key id) and 32
// bytes (the secret part).
async function apiKeysManageCore(env, { userId, body, nowMs = Date.now(), randomBytes }) {
  const b = body && typeof body === 'object' && !Array.isArray(body) ? body : {};
  if (!ACTIONS.has(b.action)) return ERR(400, 'invalid_request');
  if (typeof userId !== 'string' || !UUID_RE.test(userId)) return ERR(401, 'unauthorized');

  if (b.action === 'list') return listCore(env, { userId, nowMs });
  if (b.action === 'activity') return activityCore(env, { userId, body: b });

  if (b.action === 'revoke') {
    if (typeof b.keyId !== 'string' || !UUID_RE.test(b.keyId)) return ERR(400, 'invalid_request');
    return mutate(env, nowMs, {
      p_user_id: userId,
      p_action: 'revoke',
      p_operation_id: null,
      p_request_hash: null,
      p_key_id: b.keyId,
      p_name: null,
      p_scopes: null,
      p_expiry_days: null,
      p_key_hash: null,
      p_key_prefix: null,
      p_grace_seconds: null,
      p_new_key_id: null,
    });
  }

  // create | rotate: both mint a new key and need an operation id.
  if (typeof b.operationId !== 'string' || !UUID_V4_RE.test(b.operationId)) return ERR(400, 'invalid_request');
  const operationId = b.operationId.toLowerCase();

  let rpcArgs;
  if (b.action === 'create') {
    const name = keys.normalizeName(b.name);
    const scopes = keys.normalizeScopes(b.scopes);
    const expiry = b.expiry === undefined ? keys.DEFAULT_EXPIRY : b.expiry;
    if (!name || !scopes || !Object.prototype.hasOwnProperty.call(keys.EXPIRY_DAYS, expiry)) {
      return ERR(400, 'invalid_request');
    }
    rpcArgs = {
      p_action: 'create',
      p_request_hash: requestHash({ action: 'create', name, scopes, expiry }),
      p_key_id: null,
      p_name: name,
      p_scopes: scopes,
      p_expiry_days: keys.EXPIRY_DAYS[expiry],
      p_grace_seconds: null,
    };
  } else {
    const grace = b.grace === undefined ? keys.DEFAULT_GRACE : b.grace;
    if (typeof b.keyId !== 'string' || !UUID_RE.test(b.keyId)) return ERR(400, 'invalid_request');
    if (!Object.prototype.hasOwnProperty.call(keys.GRACE_SECONDS, grace)) return ERR(400, 'invalid_request');
    rpcArgs = {
      p_action: 'rotate',
      p_request_hash: requestHash({ action: 'rotate', keyId: b.keyId.toLowerCase(), grace }),
      p_key_id: b.keyId,
      p_name: null,
      p_scopes: null,
      p_expiry_days: null,
      p_grace_seconds: keys.GRACE_SECONDS[grace],
    };
  }

  const tagSecret = keys.tagSecretFrom(env);
  if (!tagSecret) {
    console.error('[api-keys/manage] API_KEY_TAG_SECRET is not configured');
    return ERR(503, 'unavailable');
  }
  const keyId = keys.newKeyId(randomBytes(keys.KEY_ID_BYTES));
  const secret = await keys.mintApiKey(tagSecret, {
    keyId,
    ownerId: userId.toLowerCase(),
    randomBytes: randomBytes(keys.KEY_RANDOM_BYTES),
  });
  const out = await mutate(env, nowMs, {
    p_user_id: userId,
    p_operation_id: operationId,
    p_key_hash: keys.sha256Hex(secret),
    p_key_prefix: keys.displayPrefix(secret),
    p_new_key_id: keyId,
    ...rpcArgs,
  });
  if (out.status !== 200) return out;
  // The key embeds its id: a committed row under any other id would hold a
  // key whose tag names a different row. Never hand that secret out.
  if (out.json.key.id.toLowerCase() !== keyId) {
    console.error('[api-keys/manage] committed key id does not match the minted key id');
    return ERR(500, 'server_error');
  }
  // The one and only place the raw key appears.
  return { status: 200, json: { ...out.json, secret } };
}

async function mutate(env, nowMs, args) {
  const called = await callAdminRpc(env, args);
  if (called.unavailable) return ERR(503, 'unavailable');
  const out = called.out;
  if (!out.ok) {
    const mapped = mapRpcError(out);
    if (mapped) return mapped;
    console.error('[api-keys/manage] unexpected RPC error:', String(out.error).slice(0, 40));
    return ERR(500, 'server_error');
  }
  const json = { ok: true, key: toKeySummary(out.key, nowMs) };
  if (args.p_action === 'rotate') json.previous = toKeySummary(out.previous, nowMs);
  return { status: 200, json };
}

module.exports = { apiKeysManageCore, toKeySummary, keyStatus, requestHash, KEY_COLUMNS };
