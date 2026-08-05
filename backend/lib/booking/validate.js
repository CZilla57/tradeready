// Field rules for public booking submissions (spec §6). Pure — no I/O.
// Returns { ok: true, value } with trimmed strings, or { ok: false, error }
// with a client-safe message the page shows inline.

const CAPS = { name: 100, phone: 50, email: 200, address: 300, details: 2000, preferredTiming: 200 };
const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

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
  if (!value.name) return { ok: false, error: 'Please tell us your name.' };
  if (!value.details) return { ok: false, error: 'Please describe what you need done.' };
  if (!value.phone && !value.email) return { ok: false, error: 'Please give a phone or email so we can reach you.' };
  if (value.email && !EMAIL_RE.test(value.email)) return { ok: false, error: 'That email address doesn\'t look right.' };
  return { ok: true, value };
}

module.exports = { validateBookingPayload };
