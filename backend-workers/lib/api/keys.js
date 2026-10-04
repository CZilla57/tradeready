// Owner API keys for the read-only open API (Roadmap Phase 23). Spec:
// docs/superpowers/specs/2026-10-03-open-api-design.md §2.
//
// Format: `trk_` + 43 base64url characters over 32 CSPRNG bytes (256 bits).
// At rest only sha256(raw key) hex is stored — the portal_tokens choice: a
// 256-bit random key cannot be brute-forced from its hash, so a slow KDF adds
// cost and no safety. The raw key exists once, in the create/rotate response.
//
// Pure: no I/O. Callers pass the random bytes in, so tests are deterministic.

const { createHash } = require('node:crypto');

const KEY_PREFIX = 'trk_';
const KEY_RANDOM_BYTES = 32;
const KEY_BODY_CHARS = 43; // base64url of 32 bytes, no padding
const DISPLAY_PREFIX_CHARS = 12; // "trk_" + 8
const KEY_RE = /^trk_[A-Za-z0-9_-]{43}$/;

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

function generateApiKey(randomBytes) {
  if (!Buffer.isBuffer(randomBytes) || randomBytes.length !== KEY_RANDOM_BYTES) {
    throw new Error('generateApiKey needs exactly 32 random bytes');
  }
  return KEY_PREFIX + randomBytes.toString('base64url');
}

function isWellFormedKey(value) {
  return typeof value === 'string' && KEY_RE.test(value);
}

function displayPrefix(rawKey) {
  return String(rawKey).slice(0, DISPLAY_PREFIX_CHARS);
}

// `Authorization: Bearer trk_…` only. Returns { key } or { error } where the
// error is always `invalid_key` — a missing, non-Bearer or malformed header
// gives no hint about which part was wrong.
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
  KEY_RANDOM_BYTES,
  KEY_BODY_CHARS,
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
  generateApiKey,
  isWellFormedKey,
  displayPrefix,
  parseBearer,
  keyInQuery,
  normalizeScopes,
  normalizeName,
  hasScope,
};
