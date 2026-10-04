// Field rules for public booking submissions (spec §6). Pure — no I/O.
// Returns { ok: true, value } with trimmed strings, or { ok: false, error }
// with a client-safe message the page shows inline.

const CAPS = { name: 100, phone: 50, email: 200, address: 300, details: 2000, preferredTiming: 200 };
const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
const LEAD_SOURCE_MAX = 40;

// Optional lead-source tag (the booking page's ?src= param). It is a marketing
// URL param, not customer input, so it is cleaned and capped instead of
// rejected: anything unusable returns '' and the caller drops the key. The
// native app maps presets (Nextdoor, Google, ...), so this never lowercases.
function cleanLeadSource(raw) {
  if (typeof raw !== 'string') return '';
  // Tabs/newlines become spaces BEFORE control characters are stripped, so
  // "next\tdoor" stays two words instead of fusing into "nextdoor".
  const cleaned = raw
    .replace(/[\t\n\v\f\r]/g, ' ')
    .replace(/\p{Cc}/gu, '')
    .replace(/\s+/g, ' ')
    .trim();
  // Truncate by code point so a surrogate pair is never cut in half.
  return Array.from(cleaned).slice(0, LEAD_SOURCE_MAX).join('').trim();
}

// Phase 34: a customer's referral code, 16 lowercase Crockford base32
// characters (the alphabet without i, l, o, u). The device generates and
// resolves codes; this file only checks the format.
const REFERRAL_CODE_RE = /^[0-9a-hjkmnp-tv-z]{16}$/;
// The same alphabet in either ASCII case. The input is checked against it
// BEFORE lowercasing, because toLowerCase() maps U+212A KELVIN SIGN to "k".
// Only ASCII ever becomes a code.
const REFERRAL_CODE_ANY_CASE_RE = /^[0-9A-HJKMNP-TV-Za-hjkmnp-tv-z]{16}$/;

// Optional referral code (the booking page's ?r= param). An opaque attribution
// tag, not a credential: the Worker never looks it up, so a valid, unknown or
// garbage code behaves identically for the person booking (no oracle).
// Unusable input is dropped, never rejected. Shared vectors:
// native/ReferralTests/Fixtures/referral-code-vectors.json.
function cleanReferralCode(raw) {
  if (typeof raw !== 'string') return '';
  const trimmed = raw.trim();
  if (!REFERRAL_CODE_ANY_CASE_RE.test(trimmed)) return '';
  const code = trimmed.toLowerCase();
  return REFERRAL_CODE_RE.test(code) ? code : '';
}

function validateBookingPayload(body) {
  const src = body || {};
  const value = {};
  for (const [field, cap] of Object.entries(CAPS)) {
    const raw = src[field];
    if (raw != null && typeof raw !== 'string') return { ok: false, error: `${field} must be text.` };
    const trimmed = (raw || '').trim();
    if (trimmed.length > cap) return { ok: false, error: `${field} is too long (max ${cap} characters).` };
    value[field] = trimmed;
  }
  const leadSource = cleanLeadSource(src.leadSource);
  if (leadSource) value.leadSource = leadSource;
  const referralCode = cleanReferralCode(src.referralCode);
  if (referralCode) value.referralCode = referralCode;
  if (!value.name) return { ok: false, error: 'Please tell us your name.' };
  if (!value.details) return { ok: false, error: 'Please describe what you need done.' };
  if (!value.phone && !value.email) return { ok: false, error: 'Please give a phone or email so we can reach you.' };
  if (value.email && !EMAIL_RE.test(value.email)) return { ok: false, error: 'That email address doesn\'t look right.' };
  return { ok: true, value };
}

module.exports = { validateBookingPayload, cleanReferralCode, REFERRAL_CODE_RE };
