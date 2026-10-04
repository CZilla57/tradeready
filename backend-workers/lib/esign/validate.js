// Input validation for e-signatures (spec §3.3, §3.4). Pure.
//
// Signing payload errors are { error, code } with a client-safe message the
// page shows as-is; snapshot (create-link) errors are plain strings, the
// create-link convention shared with quoteOptions / estimateExpiry.

const { CONSENT_VERSIONS } = require('./texts.js');
const { Buffer } = require('node:buffer');

const MAX_NAME_CHARS = 200;
const MAX_EMAIL_CHARS = 254;
const BOX_W = 600;
const BOX_H = 200;
const MAX_STROKES = 40;
const MAX_POINTS = 2000;
const MAX_DRAWN_BYTES = 24 * 1024;
const MAX_STROKE_MS = 3_600_000;
const MAX_SCOPE_CHARS = 4000;
const MAX_TERMS_CHARS = 4000;
const MAX_PHONE_CHARS = 40;
const MAX_TIME_ZONE_CHARS = 64;

// C0/C1 controls, and lone UTF-16 surrogates (Postgres jsonb refuses them and
// they don't survive UTF-8, so they could never be hashed faithfully).
const CONTROL_RE = /[\u0000-\u001F\u007F-\u009F]/;
const LONE_SURROGATE_RE = /[\uD800-\uDBFF](?![\uDC00-\uDFFF])|(?<![\uD800-\uDBFF])[\uDC00-\uDFFF]/;
const EMAIL_RE = /^[^\s@<>()[\]",;:\\]+@[^\s@<>()[\]",;:\\]+\.[^\s@<>()[\]",;:\\]+$/;

const ERRORS = {
  name_required: 'Please type your full name to sign.',
  name_too_long: `Please keep your name to ${MAX_NAME_CHARS} characters.`,
  name_invalid: 'Please type your name using letters, numbers and punctuation only.',
  drawing_invalid: "Your drawing couldn't be read. Please clear it and try again, or sign with your typed name only.",
  drawing_too_large: 'Your drawing is too detailed. Please clear it and try again, or sign with your typed name only.',
  email_invalid: 'Please check the email address for your copy.',
  consent_required: 'Please agree to use electronic records and signatures to sign.',
  consent_version_unknown: 'This page is out of date. Please reload the page and try again.',
  reload_required: 'This page is out of date. Please reload the page and try again.',
};

function fail(code) {
  return { error: ERRORS[code], code };
}

function isPlainObject(v) {
  return v !== null && typeof v === 'object' && !Array.isArray(v);
}

function cleanText(s) {
  return !CONTROL_RE.test(s) && !LONE_SURROGATE_RE.test(s);
}

function isEmailAddress(s) {
  return typeof s === 'string' && s.length <= MAX_EMAIL_CHARS && EMAIL_RE.test(s) && cleanText(s);
}

// The typed name is the legal act (D2): kept exactly as typed apart from the
// surrounding whitespace, never silently cut.
function validateTypedName(raw) {
  const name = typeof raw === 'string' ? raw.trim() : '';
  if (!name) return fail('name_required');
  if (name.length > MAX_NAME_CHARS) return fail('name_too_long');
  if (!cleanText(name)) return fail('name_invalid');
  return { value: name };
}

// §3.3. Returns { value: drawing | null } or an error. Empty or single-dot
// drawings are "not drawn" (null). The value is a fresh copy holding only
// the documented keys.
function normalizeDrawn(input) {
  if (input === undefined || input === null) return { value: null };
  if (!isPlainObject(input) || input.w !== BOX_W || input.h !== BOX_H || !Array.isArray(input.strokes)) {
    return fail('drawing_invalid');
  }
  if (input.strokes.length > MAX_STROKES) return fail('drawing_too_large');
  let points = 0;
  const strokes = [];
  for (const stroke of input.strokes) {
    if (!Array.isArray(stroke) || stroke.length === 0) return fail('drawing_invalid');
    points += stroke.length;
    if (points > MAX_POINTS) return fail('drawing_too_large');
    const out = [];
    for (const p of stroke) {
      if (!Array.isArray(p) || p.length !== 3) return fail('drawing_invalid');
      const [x, y, t] = p;
      if (!Number.isInteger(x) || !Number.isInteger(y) || !Number.isInteger(t)) return fail('drawing_invalid');
      if (x < 0 || x > BOX_W || y < 0 || y > BOX_H || t < 0 || t > MAX_STROKE_MS) return fail('drawing_invalid');
      out.push([x, y, t]);
    }
    strokes.push(out);
  }
  if (points < 2) return { value: null };
  const drawn = { w: BOX_W, h: BOX_H, strokes };
  if (Buffer.byteLength(JSON.stringify(drawn), 'utf8') > MAX_DRAWN_BYTES) return fail('drawing_too_large');
  return { value: drawn };
}

function normalizeEmail(input) {
  if (input === undefined || input === null) return { value: null };
  if (typeof input !== 'string') return fail('email_invalid');
  const email = input.trim();
  if (!email) return { value: null };
  if (!isEmailAddress(email)) return fail('email_invalid');
  return { value: email };
}

// `consent` absent → null (an older page). Present → it must be an explicit
// acceptance of a version this Worker knows.
function normalizeConsent(input) {
  if (input === undefined || input === null) return { value: null };
  if (!isPlainObject(input) || input.accepted !== true) return fail('consent_required');
  if (!CONSENT_VERSIONS.includes(input.version)) return fail('consent_version_unknown');
  return { value: { version: input.version } };
}

// The optional Phase 19 fields of an approve request, checked before any DB
// contact (§3.5 step 1). Returns { value: { drawn, email, consent } } or an
// error.
function parseSignatureFields(body) {
  const b = isPlainObject(body) ? body : {};
  const drawn = normalizeDrawn(b.drawn);
  if (drawn.error) return drawn;
  const email = normalizeEmail(b.signerEmail);
  if (email.error) return email;
  const consent = normalizeConsent(b.consent);
  if (consent.error) return consent;
  return { value: { drawn: drawn.value, email: email.value, consent: consent.value } };
}

// §3.4 snapshot additions, validated by create-link before any DB contact.
// Returns null or a client-safe string. Absent keys are fine.
function validateSnapshotEsign(snapshot) {
  const s = isPlainObject(snapshot) ? snapshot : {};
  const present = (k) => s[k] !== undefined && s[k] !== null;
  if (present('scope') && (typeof s.scope !== 'string' || s.scope.length > MAX_SCOPE_CHARS)) {
    return 'The scope must be text of at most 4,000 characters.';
  }
  if (present('terms') && (typeof s.terms !== 'string' || s.terms.length > MAX_TERMS_CHARS)) {
    return 'The terms must be text of at most 4,000 characters.';
  }
  if (present('businessContact')) {
    const bc = s.businessContact;
    if (!isPlainObject(bc)) return 'Business contact details are malformed.';
    if (bc.phone !== undefined && bc.phone !== null) {
      if (typeof bc.phone !== 'string') return 'Business contact details are malformed.';
      if (bc.phone.length > MAX_PHONE_CHARS) return 'The business phone must be at most 40 characters.';
    }
    if (bc.email !== undefined && bc.email !== null) {
      if (typeof bc.email !== 'string') return 'Business contact details are malformed.';
      if (bc.email.trim() && !isEmailAddress(bc.email.trim())) return 'The business email address is invalid.';
    }
  }
  if (present('signature')) {
    const sig = s.signature;
    if (!isPlainObject(sig)) return 'Signature settings are malformed.';
    if (sig.drawPad !== undefined && sig.drawPad !== null && typeof sig.drawPad !== 'boolean') {
      return 'Signature settings are malformed.';
    }
  }
  if (present('esign')) {
    const e = s.esign;
    if (!isPlainObject(e) || !CONSENT_VERSIONS.includes(e.version)) {
      return "This e-signature version isn't supported. Please update the app.";
    }
    if (e.timeZone !== undefined && e.timeZone !== null
      && (typeof e.timeZone !== 'string' || !e.timeZone.trim() || e.timeZone.length > MAX_TIME_ZONE_CHARS)) {
      return 'The e-signature time zone is invalid.';
    }
  }
  return null;
}

module.exports = {
  ERRORS,
  MAX_NAME_CHARS,
  MAX_EMAIL_CHARS,
  MAX_STROKES,
  MAX_POINTS,
  MAX_DRAWN_BYTES,
  BOX_W,
  BOX_H,
  fail,
  isEmailAddress,
  validateTypedName,
  normalizeDrawn,
  normalizeEmail,
  normalizeConsent,
  parseSignatureFields,
  validateSnapshotEsign,
};
