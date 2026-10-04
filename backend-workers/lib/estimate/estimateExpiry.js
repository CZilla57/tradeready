// Quote expiration dates (Roadmap Phase 32). Pure helpers shared by
// create-link (validation), view and the portal assembler (display state),
// respond (enforcement) and request-update. Spec: docs/superpowers/specs/
// 2026-10-03-quote-expiration-design.md §2.4, §4.1.
//
// The rule (§2.4): an estimate is expired at `nowMs` iff its snapshot has a
// `validUntil` and today in the owner's zone is AFTER that date, compared as
// YYYY-MM-DD strings. No instant arithmetic, so DST cannot move the deadline.
// The zone is `validUntilTimeZone` when the runtime resolves it, otherwise
// anywhere-on-Earth (UTC-12), which can only ever expire LATE, never early.
//
// Parity contract with the native app: both sides load
// native/QuoteExpiryTests/Fixtures/quote-expiry-vectors.json.
//
// Nothing here reads the process time zone: "today" always comes from Intl
// with an explicit zone, and display dates are formatted in UTC.

const { nowInZone } = require('../booking/availability.js');

const ANYWHERE_ON_EARTH_ZONE = 'Etc/GMT+12';
const MAX_TIME_ZONE_CHARS = 64;
// A garbage guard, not a product rule — the app caps the picker at 365.
const MAX_DAYS_AHEAD = 400;
const DAY_MS = 86_400_000;
const YMD_RE = /^\d{4}-\d{2}-\d{2}$/;

function isPlainObject(v) {
  return v !== null && typeof v === 'object' && !Array.isArray(v);
}

// "Present" means non-null: the device omits absent keys (putOptional), and
// an explicit null reads the same way.
function present(v) {
  return v !== undefined && v !== null;
}

function isResolvableTimeZone(tz) {
  if (typeof tz !== 'string' || tz.length === 0) return false;
  try {
    new Intl.DateTimeFormat('en-US', { timeZone: tz });
    return true;
  } catch {
    return false;
  }
}

function ymdToUtcMs(ymd) {
  const [y, m, d] = ymd.split('-').map(Number);
  return Date.UTC(y, m - 1, d);
}

// A real calendar date: the shape AND a Date.UTC round trip, so 2026-02-30
// and 2026-13-01 are refused. (Date.UTC maps years 0–99 to 1900–1999, so the
// round trip also refuses those.)
function isRealYmd(v) {
  if (typeof v !== 'string' || !YMD_RE.test(v)) return false;
  return new Date(ymdToUtcMs(v)).toISOString().slice(0, 10) === v;
}

function enforcementZone(tz) {
  return isResolvableTimeZone(tz) ? tz : ANYWHERE_ON_EARTH_ZONE;
}

function todayIn(zone, nowMs) {
  return nowInZone(zone, nowMs).date;
}

// Returns null when the snapshot's validity keys are absent or acceptable,
// else a client-safe error string. Runs only when either key is present.
function validateSnapshotValidity(snapshot, nowMs) {
  const s = isPlainObject(snapshot) ? snapshot : {};
  const hasDate = present(s.validUntil);
  const hasZone = present(s.validUntilTimeZone);
  if (!hasDate && !hasZone) return null;
  if (hasDate !== hasZone) return 'Valid-until date and time zone must be sent together.';

  if (!isRealYmd(s.validUntil)) return 'The valid-until date is invalid.';
  const tz = s.validUntilTimeZone;
  if (typeof tz !== 'string' || tz.trim().length === 0 || tz.length > MAX_TIME_ZONE_CHARS) {
    return 'The valid-until time zone is invalid.';
  }
  // Accepted, never rewritten: the snapshot is device-authored and frozen,
  // and refusing would block a send over an ICU alias mismatch. Enforcement
  // falls back to anywhere-on-Earth, which never expires early.
  if (!isResolvableTimeZone(tz)) {
    console.warn('[estimate/expiry] unresolvable valid-until time zone; enforcing anywhere-on-Earth');
  }

  const today = todayIn(enforcementZone(tz), nowMs);
  if (s.validUntil < today) return 'The valid-until date is in the past.';
  if ((ymdToUtcMs(s.validUntil) - ymdToUtcMs(today)) / DAY_MS > MAX_DAYS_AHEAD) {
    return 'The valid-until date is too far in the future.';
  }
  return null;
}

// §2.4. `validUntil` is null when the snapshot carries no usable date — an
// undated (or malformed) snapshot never expires.
function snapshotExpiry(snapshot, nowMs) {
  const s = isPlainObject(snapshot) ? snapshot : {};
  if (!isRealYmd(s.validUntil)) return { validUntil: null, expired: false };
  const today = todayIn(enforcementZone(s.validUntilTimeZone), nowMs);
  return { validUntil: s.validUntil, expired: today > s.validUntil };
}

// "November 2, 2026". Formatted in UTC from midnight UTC of that date, so the
// calendar day can never shift whatever zone the runtime sits in.
function formatValidUntil(ymd) {
  if (!isRealYmd(ymd)) return String(ymd || '');
  return new Intl.DateTimeFormat('en-US', { dateStyle: 'long', timeZone: 'UTC' })
    .format(new Date(`${ymd}T00:00:00Z`));
}

// The 410 text. Complete on its own, so an old page that only shows
// `out.error` still tells the customer what happened and what to do.
function expiredMessage(snapshot, validUntil) {
  const name = isPlainObject(snapshot) && typeof snapshot.businessName === 'string'
    ? snapshot.businessName.trim().slice(0, 120) : '';
  return `This estimate expired on ${formatValidUntil(validUntil)}. Please ask ${name || 'the business'} for an updated estimate.`;
}

module.exports = {
  ANYWHERE_ON_EARTH_ZONE,
  isResolvableTimeZone,
  validateSnapshotValidity,
  snapshotExpiry,
  formatValidUntil,
  expiredMessage,
};
