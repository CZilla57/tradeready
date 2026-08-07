// HMAC signing for anonymous portal photo reads (Phase 12B). The signature
// binds userId + photoId + expiry to a server-held secret
// (PORTAL_URL_SIGNING_SECRET, set via `wrangler secret put`), so a signed
// URL grants exactly one object for a bounded time and nothing else.
// Signatures are computed per portal-view response and NEVER persisted
// (spec §6) — the owner untoggling a photo takes effect within the TTL.

const { createHmac } = require('node:crypto');
const { constantTimeEqual } = require('./constantTime.js');

const PHOTO_URL_TTL_SEC = 900; // 15 minutes — one portal page session

const UUID_RE = /^[0-9a-fA-F-]{36}$/;

function photoSignature({ secret, userId, photoId, expiresAtSec }) {
  return createHmac('sha256', String(secret))
    .update(`${userId}|${photoId}|${expiresAtSec}`)
    .digest('hex');
}

function verifyPhotoSignature({ secret, userId, photoId, expiresAtSec, sig, nowMs }) {
  if (!secret || typeof sig !== 'string') return false;
  const exp = Number(expiresAtSec);
  if (!Number.isFinite(exp) || nowMs / 1000 > exp) return false;
  return constantTimeEqual(photoSignature({ secret, userId, photoId, expiresAtSec }), sig);
}

// Route-level decision for /api/photos-public. Validates shape BEFORE the
// signature check and derives the R2 key ONLY from verified values, so a
// forged or expired URL can never shape a key outside the signed user's
// prefix. Callers answer the same oracle-free 404 for every { ok: false }.
function resolvePublicPhotoKey({ secret, photoId, userId, expiresAtSec, sig, nowMs, photoIdRe }) {
  if (!secret) return { ok: false };
  if (typeof userId !== 'string' || !UUID_RE.test(userId)) return { ok: false };
  if (typeof photoId !== 'string' || !photoIdRe.test(photoId)) return { ok: false };
  if (!/^\d{1,12}$/.test(String(expiresAtSec))) return { ok: false };
  if (!verifyPhotoSignature({ secret, userId, photoId, expiresAtSec, sig, nowMs })) return { ok: false };
  return { ok: true, key: `${userId}/${photoId}.jpg` };
}

module.exports = { photoSignature, verifyPhotoSignature, resolvePublicPhotoKey, PHOTO_URL_TTL_SEC };
