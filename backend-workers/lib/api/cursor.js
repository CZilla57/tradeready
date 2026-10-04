// Keyset cursors for the open API (spec §5). A cursor is
//   base64url(JSON {u: updated_at, i: id, r: resource}) + "." + tag
// where tag = base64url(HMAC-SHA256(API_CURSOR_SECRET, payload)). The tag
// makes cursors server-minted only: a tampered, forged or cross-resource
// cursor is refused (400 invalid_cursor) before any value reaches a
// PostgREST filter. Cursors carry no owner and grant nothing — every query
// is owner-scoped regardless — so a cursor shared between owners only
// positions a scan inside the caller's own rows.
//
// Pure apart from node:crypto.

const { createHmac } = require('node:crypto');
const { constantTimeEqual } = require('../constantTime.js');

const MAX_CURSOR_CHARS = 1024;
const MAX_ID_CHARS = 512;

function tag(secret, payload) {
  return createHmac('sha256', String(secret)).update(payload).digest('base64url');
}

function encodeCursor(secret, { updatedAt, id, resource }) {
  if (!secret) throw new Error('API_CURSOR_SECRET is not configured');
  const payload = Buffer.from(JSON.stringify({ u: updatedAt, i: id, r: resource }), 'utf8').toString('base64url');
  return `${payload}.${tag(secret, payload)}`;
}

// Returns { updatedAt, id } or null for anything not minted by us for THIS
// resource.
function decodeCursor(secret, cursor, resource) {
  if (!secret || typeof cursor !== 'string' || cursor.length === 0 || cursor.length > MAX_CURSOR_CHARS) return null;
  const parts = cursor.split('.');
  if (parts.length !== 2) return null;
  const [payload, sig] = parts;
  if (!/^[A-Za-z0-9_-]+$/.test(payload) || !/^[A-Za-z0-9_-]+$/.test(sig)) return null;
  if (!constantTimeEqual(tag(secret, payload), sig)) return null;
  let parsed;
  try {
    parsed = JSON.parse(Buffer.from(payload, 'base64url').toString('utf8'));
  } catch {
    return null;
  }
  if (!parsed || typeof parsed !== 'object') return null;
  if (parsed.r !== resource) return null;
  if (typeof parsed.u !== 'string' || !Number.isFinite(Date.parse(parsed.u))) return null;
  if (typeof parsed.i !== 'string' || parsed.i.length === 0 || parsed.i.length > MAX_ID_CHARS) return null;
  return { updatedAt: parsed.u, id: parsed.i };
}

module.exports = { encodeCursor, decodeCursor, MAX_CURSOR_CHARS };
