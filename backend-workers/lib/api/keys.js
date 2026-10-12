// Owner API keys for the read-only open API (Roadmap Phase 23). Spec:
// docs/superpowers/specs/2026-10-03-open-api-design.md §2 and §14.4a #5.
//
// Format (self-verifying, 2026-10-12): `trk_` + 107 base64url characters
// over 80 bytes:
//   [ 0,16) key id    — the api_keys.id UUID, chosen by the Worker at mint
//   [16,32) owner id  — the owner's auth user UUID
//   [32,64) secret    — 32 CSPRNG bytes (256 bits)
//   [64,80) tag       — HMAC-SHA256(API_KEY_TAG_SECRET, TAG_DOMAIN ‖ bytes[0,64))
//                       truncated to 128 bits
// The tag lets the Worker reject a forged or random key with one HMAC, before
// it spends any rate budget or calls the authorize RPC, and lets the request
// guard charge a tag-valid key's budget to its owner. Only a key minted with
// the Worker secret verifies; there is no untagged format.
//
// At rest only sha256(raw key) hex and the 12-character display prefix are
// stored — the portal_tokens choice: a key with a 256-bit random part cannot
// be brute-forced from its hash, so a slow KDF adds cost and no safety. The
// raw key exists once, in the create/rotate response.
//
// No I/O. Callers pass the random bytes in, so tests are deterministic. The
// HMAC uses WebCrypto (crypto.subtle); the imported CryptoKey is cached per
// isolate.

const { createHash } = require('node:crypto');

const KEY_PREFIX = 'trk_';
const KEY_ID_BYTES = 16;
const KEY_OWNER_BYTES = 16;
const KEY_RANDOM_BYTES = 32;
const KEY_TAG_BYTES = 16; // 128-bit truncated HMAC-SHA256
const KEY_SIGNED_BYTES = KEY_ID_BYTES + KEY_OWNER_BYTES + KEY_RANDOM_BYTES; // 64
const KEY_PAYLOAD_BYTES = KEY_SIGNED_BYTES + KEY_TAG_BYTES; // 80
const KEY_BODY_CHARS = 107; // base64url of 80 bytes, no padding
const DISPLAY_PREFIX_CHARS = 12; // "trk_" + 8
const KEY_RE = /^trk_[A-Za-z0-9_-]{107}$/;
// Domain separation: this secret signs API keys and nothing else.
const TAG_DOMAIN = Buffer.from('tradeready-api-key-v1\0', 'utf8');
// API_KEY_TAG_SECRET shorter than this counts as unset (fail closed). The
// owner generates it from at least 32 random bytes (base64: 44+ characters).
const MIN_TAG_SECRET_CHARS = 32;
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

// Canonical order: every response and every stored array uses it.
const SCOPES = Object.freeze(['customers:read', 'jobs:read', 'invoices:read', 'expenses:read', 'mileage:read']);
const PRESETS = Object.freeze({
  everything: SCOPES,
  bookkeeping: Object.freeze(['customers:read', 'invoices:read', 'expenses:read', 'mileage:read']),
});

// Which scope each /v1 resource needs. `account` needs any scope (a key
// always has at least one), so it is absent here on purpose.
const RESOURCE_SCOPE = Object.freeze({
  customers: 'customers:read',
  jobs: 'jobs:read',
  estimates: 'jobs:read',
  invoices: 'invoices:read',
  payments: 'invoices:read',
  expenses: 'expenses:read',
  mileage: 'mileage:read',
});

const MAX_LIVE_KEYS = 5;
const MAX_NAME_CHARS = 40;
// Expiry choices → lifetime in days (null = never expires). Default 1 year.
const EXPIRY_DAYS = Object.freeze({ '1y': 365, '90d': 90, none: null });
const DEFAULT_EXPIRY = '1y';
// Rotation grace choices → seconds the old key keeps working.
const GRACE_SECONDS = Object.freeze({ '24h': 86_400, immediate: 0 });
const DEFAULT_GRACE = '24h';

function sha256Hex(value) {
  return createHash('sha256').update(String(value), 'utf8').digest('hex');
}

// The tag secret from the Worker env, or null when it is unset or too short.
// Callers fail closed on null: no key is minted or accepted without it.
function tagSecretFrom(env) {
  const s = env ? env.API_KEY_TAG_SECRET : undefined;
  return typeof s === 'string' && s.length >= MIN_TAG_SECRET_CHARS ? s : null;
}

// One imported HMAC key per isolate (re-imported only if the secret changes).
let cachedTagKey = null; // { secret, key: Promise<CryptoKey> }
function tagKey(secret) {
  if (cachedTagKey && cachedTagKey.secret === secret) return cachedTagKey.key;
  const key = globalThis.crypto.subtle.importKey(
    'raw',
    new TextEncoder().encode(secret),
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign']
  );
  const entry = { secret, key };
  cachedTagKey = entry;
  key.catch(() => {
    if (cachedTagKey === entry) cachedTagKey = null;
  });
  return key;
}

async function computeTag(secret, signed) {
  const key = await tagKey(secret);
  const mac = await globalThis.crypto.subtle.sign('HMAC', key, Buffer.concat([TAG_DOMAIN, signed]));
  return new Uint8Array(mac, 0, KEY_TAG_BYTES);
}

// Constant time in the content (the length is public and fixed).
function equalBytes(a, b) {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a[i] ^ b[i];
  return diff === 0;
}

function uuidToBytes(uuid) {
  if (typeof uuid !== 'string' || !UUID_RE.test(uuid)) return null;
  return Buffer.from(uuid.replace(/-/g, ''), 'hex');
}

function bytesToUuid(bytes) {
  const h = Buffer.from(bytes).toString('hex');
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-${h.slice(12, 16)}-${h.slice(16, 20)}-${h.slice(20, 32)}`;
}

// A new api_keys.id: a lower-case UUID v4 from 16 CSPRNG bytes.
function newKeyId(randomBytes) {
  if (!Buffer.isBuffer(randomBytes) || randomBytes.length !== KEY_ID_BYTES) {
    throw new Error('newKeyId needs exactly 16 random bytes');
  }
  const b = Buffer.from(randomBytes);
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  return bytesToUuid(b);
}

// Mints a tagged key. keyId and ownerId are UUID strings; randomBytes is
// exactly 32 CSPRNG bytes.
async function mintApiKey(secret, { keyId, ownerId, randomBytes }) {
  if (typeof secret !== 'string' || secret.length < MIN_TAG_SECRET_CHARS) {
    throw new Error('API_KEY_TAG_SECRET is not configured');
  }
  const id = uuidToBytes(keyId);
  const owner = uuidToBytes(ownerId);
  if (!id || !owner) throw new Error('mintApiKey needs a key id and an owner id (UUIDs)');
  if (!Buffer.isBuffer(randomBytes) || randomBytes.length !== KEY_RANDOM_BYTES) {
    throw new Error('mintApiKey needs exactly 32 random bytes');
  }
  const signed = Buffer.concat([id, owner, randomBytes]);
  const tag = await computeTag(secret, signed);
  return KEY_PREFIX + Buffer.concat([signed, tag]).toString('base64url');
}

// Checks a presented key's tag. Returns { keyId, ownerId } (lower-case UUID
// strings) for a key minted with this secret, or null for anything else:
// wrong shape, non-canonical base64url, or a bad tag. No I/O beyond the HMAC.
async function verifyApiKey(secret, key) {
  if (typeof secret !== 'string' || secret.length < MIN_TAG_SECRET_CHARS) return null;
  if (!isWellFormedKey(key)) return null;
  const body = key.slice(KEY_PREFIX.length);
  const bytes = Buffer.from(body, 'base64url');
  // Exactly one spelling per key: base64url of 80 bytes leaves 2 spare bits
  // in the last character, and a second spelling would hash differently.
  if (bytes.length !== KEY_PAYLOAD_BYTES || bytes.toString('base64url') !== body) return null;
  const signed = bytes.subarray(0, KEY_SIGNED_BYTES);
  const expected = await computeTag(secret, signed);
  if (!equalBytes(expected, bytes.subarray(KEY_SIGNED_BYTES))) return null;
  return {
    keyId: bytesToUuid(bytes.subarray(0, KEY_ID_BYTES)),
    ownerId: bytesToUuid(bytes.subarray(KEY_ID_BYTES, KEY_ID_BYTES + KEY_OWNER_BYTES)),
  };
}

function isWellFormedKey(value) {
  return typeof value === 'string' && KEY_RE.test(value);
}

function displayPrefix(rawKey) {
  return String(rawKey).slice(0, DISPLAY_PREFIX_CHARS);
}

// `Authorization: Bearer trk_…` only. Returns { key } or { error } where the
// error is always `invalid_key` — a missing, non-Bearer or malformed header
// gives no hint about which part was wrong. Shape only: the tag is checked
// by verifyApiKey.
function parseBearer(header) {
  if (typeof header !== 'string') return { error: 'invalid_key' };
  const match = /^Bearer ([^\s]+)$/.exec(header.trim());
  if (!match || !isWellFormedKey(match[1])) return { error: 'invalid_key' };
  return { key: match[1] };
}

// Query-string presentation is refused before anything else (§2): URLs land
// in logs and browser history. Any parameter named like a credential, or any
// value that looks like one of our keys, counts.
const CREDENTIAL_PARAM_NAMES = new Set(['api_key', 'apikey', 'key', 'access_token', 'token', 'authorization', 'bearer']);

function keyInQuery(searchParams) {
  for (const [name, value] of searchParams) {
    if (CREDENTIAL_PARAM_NAMES.has(String(name).toLowerCase())) return true;
    if (typeof value === 'string' && value.trim().startsWith(KEY_PREFIX)) return true;
  }
  return false;
}

// Scope list from a request body: non-empty, every entry known; returns the
// de-duplicated canonical-order list, or null when invalid.
function normalizeScopes(input) {
  if (!Array.isArray(input) || input.length === 0 || input.length > 20) return null;
  if (input.some((s) => typeof s !== 'string' || !SCOPES.includes(s))) return null;
  const wanted = new Set(input);
  return SCOPES.filter((s) => wanted.has(s));
}

// Key names: trimmed, 1–40 characters, no control characters. Returns the
// trimmed name, or null when invalid.
// eslint-disable-next-line no-control-regex
const CONTROL_RE = /[\u0000-\u001f\u007f-\u009f\u2028\u2029]/;
function normalizeName(input) {
  if (typeof input !== 'string') return null;
  const name = input.trim();
  if (name.length < 1 || name.length > MAX_NAME_CHARS || CONTROL_RE.test(name)) return null;
  return name;
}

function hasScope(scopes, resource) {
  const list = Array.isArray(scopes) ? scopes : [];
  if (resource === 'account') return list.some((s) => SCOPES.includes(s));
  const needed = RESOURCE_SCOPE[resource];
  return Boolean(needed) && list.includes(needed);
}

module.exports = {
  KEY_PREFIX,
  KEY_ID_BYTES,
  KEY_OWNER_BYTES,
  KEY_RANDOM_BYTES,
  KEY_TAG_BYTES,
  KEY_PAYLOAD_BYTES,
  KEY_BODY_CHARS,
  TAG_DOMAIN,
  MIN_TAG_SECRET_CHARS,
  DISPLAY_PREFIX_CHARS,
  SCOPES,
  PRESETS,
  RESOURCE_SCOPE,
  MAX_LIVE_KEYS,
  MAX_NAME_CHARS,
  EXPIRY_DAYS,
  DEFAULT_EXPIRY,
  GRACE_SECONDS,
  DEFAULT_GRACE,
  sha256Hex,
  tagSecretFrom,
  newKeyId,
  mintApiKey,
  verifyApiKey,
  isWellFormedKey,
  displayPrefix,
  parseBearer,
  keyInQuery,
  normalizeScopes,
  normalizeName,
  hasScope,
};
