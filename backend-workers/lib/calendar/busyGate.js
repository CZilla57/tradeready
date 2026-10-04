// backend-workers/lib/calendar/busyGate.js
// Calendar busy times (Roadmap Phase 26, spec
// docs/superpowers/specs/2026-10-03-calendar-sync-design.md §2.2–§2.4, §3.1).
//
// Pure and shared by the write path (POST /api/calendar/busy validates what a
// device sends) and the read path (slots/reserve re-validate what is stored,
// then turn it into owner-naive busy windows for the unchanged availability
// engine).
//
// ⚠️ PARITY: `calendarBusyGate` has a Swift twin,
// `NativeCalendarBusy.gate` (native/TradeReadyNative/Domain/NativeCalendarBusy.swift).
// Both are pinned to the same vectors in
// native/ScheduleTests/Fixtures/scheduleVectors.json (`calendarBusyVectors`,
// `offerableScenarios`): Jest asserts this file, the Swift availability suite
// asserts the twin. A behavior change lands in both, with a vector.
//
// Freshness fails closed (§1.4): a missing row is `off` (today's behavior), a
// row that is null, invalid, older than the TTL or past its window is
// `stale` (no offers), and time outside the snapshot's coverage is busy.

const { nowInZone } = require('../booking/availability.js');

const TTL_HOURS = 48;
const MAX_TIMED = 500;
const MAX_ALL_DAY = 100;
const MAX_WINDOW_DAYS = 63;
const MAX_ALL_DAY_DAYS = 63;
const MAX_BODY_BYTES = 64 * 1024;
const MAX_SKEW_MS = 10 * 60 * 1000;

const MINUTE_MS = 60 * 1000;
const HOUR_MS = 60 * MINUTE_MS;
const DAY_MS = 24 * HOUR_MS;
const DAY_MINUTES = 24 * 60;

const INSTANT_RE = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):00Z$/;
const DATE_RE = /^(\d{4})-(\d{2})-(\d{2})$/;
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

function isSourceId(value) {
  return typeof value === 'string' && UUID_RE.test(value);
}

function isPlainObject(value) {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

/** A wire instant ("YYYY-MM-DDTHH:MM:00Z") → epoch ms, or null. Rejects
 *  impossible dates (Feb 30) by round-tripping through Date.UTC. */
function parseInstant(value) {
  if (typeof value !== 'string') return null;
  const m = INSTANT_RE.exec(value);
  if (!m) return null;
  const [y, mo, d, h, mi] = m.slice(1).map(Number);
  if (mo < 1 || mo > 12 || d < 1 || h > 23 || mi > 59) return null;
  const ms = Date.UTC(y, mo - 1, d, h, mi);
  const back = new Date(ms);
  if (back.getUTCFullYear() !== y || back.getUTCMonth() !== mo - 1 || back.getUTCDate() !== d) return null;
  return ms;
}

/** A naive date ("YYYY-MM-DD") → UTC epoch days, or null for impossible dates. */
function parseDateDays(value) {
  if (typeof value !== 'string') return null;
  const m = DATE_RE.exec(value);
  if (!m) return null;
  const [y, mo, d] = m.slice(1).map(Number);
  if (mo < 1 || mo > 12 || d < 1) return null;
  const ms = Date.UTC(y, mo - 1, d);
  const back = new Date(ms);
  if (back.getUTCFullYear() !== y || back.getUTCMonth() !== mo - 1 || back.getUTCDate() !== d) return null;
  return ms / DAY_MS;
}

function formatDays(days) {
  const d = new Date(days * DAY_MS);
  return `${d.getUTCFullYear()}-${String(d.getUTCMonth() + 1).padStart(2, '0')}-${String(d.getUTCDate()).padStart(2, '0')}`;
}

function formatMinutes(minutes) {
  return `${String(Math.floor(minutes / 60)).padStart(2, '0')}:${String(minutes % 60).padStart(2, '0')}`;
}

/** Epoch ms → the wire instant form, or null when not at minute precision. */
function formatInstant(ms) {
  if (!Number.isFinite(ms) || ms % MINUTE_MS !== 0) return null;
  return `${new Date(ms).toISOString().slice(0, 16)}:00Z`;
}

/** A stored timestamptz (PostgREST answers "2026-10-03T14:05:00+00:00") or a
 *  wire instant → the wire instant form, or null. */
function normalizeInstant(value) {
  if (typeof value !== 'string') return null;
  if (parseInstant(value) !== null) return value;
  const ms = Date.parse(value);
  return Number.isFinite(ms) ? formatInstant(ms) : null;
}

/** Any parseable timestamp → epoch ms, or null (received_at carries seconds). */
function parseAnyInstant(value) {
  if (typeof value !== 'string') return null;
  const ms = Date.parse(value);
  return Number.isFinite(ms) ? ms : null;
}

/**
 * Validates a wire snapshot (§2.2, §3.1). Returns `{ok: true, value}` with
 * the parsed instants (ms) and dates (epoch days), or `{ok: false, reason}`.
 * The request-body size and `sourceId` are checked by busyCore; everything
 * about the snapshot itself is here, so the read path re-validates with the
 * exact same rules.
 */
function validateSnapshot(snapshot, { nowMs }) {
  const fail = (reason) => ({ ok: false, reason });
  if (!isPlainObject(snapshot)) return fail('not_object');
  if (snapshot.v !== 1) return fail('version');

  const computedAtMs = parseInstant(snapshot.computedAt);
  const windowStartMs = parseInstant(snapshot.windowStart);
  const windowEndMs = parseInstant(snapshot.windowEnd);
  if (computedAtMs === null || windowStartMs === null || windowEndMs === null) return fail('instant');
  if (windowStartMs > computedAtMs) return fail('window_after_computed');
  if (windowStartMs >= windowEndMs) return fail('window_order');
  if (windowEndMs - windowStartMs > MAX_WINDOW_DAYS * DAY_MS) return fail('window_length');
  if (computedAtMs > nowMs + MAX_SKEW_MS || windowStartMs > nowMs + MAX_SKEW_MS) return fail('skew');

  if (!Array.isArray(snapshot.timed) || snapshot.timed.length > MAX_TIMED) return fail('timed_cap');
  const timed = [];
  let previousEnd = -Infinity;
  for (const pair of snapshot.timed) {
    if (!Array.isArray(pair) || pair.length !== 2) return fail('timed_shape');
    const s = parseInstant(pair[0]);
    const e = parseInstant(pair[1]);
    if (s === null || e === null) return fail('timed_instant');
    if (s >= e) return fail('timed_order');
    if (s < windowStartMs || e > windowEndMs) return fail('timed_outside_window');
    // Sorted and strictly non-overlapping: touching blocks must have merged.
    if (s <= previousEnd) return fail('timed_overlap');
    previousEnd = e;
    timed.push([s, e]);
  }

  if (!Array.isArray(snapshot.allDay) || snapshot.allDay.length > MAX_ALL_DAY) return fail('all_day_cap');
  const allDay = [];
  let previousLast = -Infinity;
  for (const range of snapshot.allDay) {
    if (!Array.isArray(range) || range.length !== 2) return fail('all_day_shape');
    const d1 = parseDateDays(range[0]);
    const d2 = parseDateDays(range[1]);
    if (d1 === null || d2 === null) return fail('all_day_date');
    if (d1 > d2) return fail('all_day_order');
    if (d2 - d1 + 1 > MAX_ALL_DAY_DAYS) return fail('all_day_length');
    if (d1 <= previousLast) return fail('all_day_overlap');
    previousLast = d2;
    allDay.push([d1, d2]);
  }

  return { ok: true, value: { computedAtMs, windowStartMs, windowEndMs, timed, allDay } };
}

/** The stored row's snapshot in wire form (the jsonb holds {v,timed,allDay};
 *  the instants live in their own columns), or null when nothing is shared. */
function wireSnapshotFromRow(row) {
  if (!row || !isPlainObject(row.snapshot)) return null;
  return {
    v: row.snapshot.v,
    computedAt: normalizeInstant(row.computed_at),
    windowStart: normalizeInstant(row.window_start),
    windowEnd: normalizeInstant(row.window_end),
    timed: row.snapshot.timed,
    allDay: row.snapshot.allDay,
  };
}

/**
 * Steps 1–3 of §2.4: `off` (no row), `stale` (null, invalid, past the TTL from
 * min(computedAt, receivedAt), or windowEnd ≤ now), else `fresh` with the
 * parsed snapshot. Zone-free, so the status action can answer it too.
 */
function gateFreshness(row, { nowMs, ttlHours = TTL_HOURS }) {
  if (!row) return { state: 'off' };
  const wire = wireSnapshotFromRow(row);
  if (!wire) return { state: 'stale' };
  const checked = validateSnapshot(wire, { nowMs });
  if (!checked.ok) return { state: 'stale' };
  const receivedMs = parseAnyInstant(row.received_at);
  if (receivedMs === null) return { state: 'stale' };
  const effectiveMs = Math.min(checked.value.computedAtMs, receivedMs);
  if (nowMs - effectiveMs > ttlHours * HOUR_MS) return { state: 'stale' };
  if (checked.value.windowEndMs <= nowMs) return { state: 'stale' };
  return { state: 'fresh', parsed: checked.value };
}

// ── zone conversion (Intl, via the availability engine's nowInZone) ─────────

/** Local naive minutes since the epoch for an instant in `timeZone`. */
function localMinutes(ms, timeZone) {
  const z = nowInZone(timeZone, ms);
  return parseDateDays(z.date) * DAY_MINUTES + z.minutes;
}

/** Offset (minutes the zone is ahead of UTC) at a minute-precision instant. */
function offsetMinutes(ms, timeZone) {
  return localMinutes(ms, timeZone) - Math.floor(ms / MINUTE_MS);
}

/** Splits a local naive span [startMin, endMin) into per-date windows. A
 *  day's end of 24:00 is encoded as "23:59" (no slot can end later, since
 *  workDayEnd ≤ 23:59); windows that end up empty are dropped. */
function pushLocalSpan(out, startMin, endMin) {
  for (let day = Math.floor(startMin / DAY_MINUTES); day * DAY_MINUTES < endMin; day += 1) {
    const s = Math.max(startMin, day * DAY_MINUTES) - day * DAY_MINUTES;
    let e = Math.min(endMin, (day + 1) * DAY_MINUTES) - day * DAY_MINUTES;
    if (e === DAY_MINUTES) e = DAY_MINUTES - 1;
    if (s < e) out.push({ date: formatDays(day), start: formatMinutes(s), end: formatMinutes(e) });
  }
}

/**
 * §2.4 `calendarBusyGate(row, {timeZone, nowMs, ttlHours = 48})` →
 * `{state: 'off'} | {state: 'stale'} | {state: 'fresh', windows, lastCoveredDate}`.
 *
 * Timed pair [s, e): the local span is [s + min(offS, offE), e + max(offS, offE)),
 * exact without a transition inside the block and a superset across one (a
 * fall-back fold widens the window instead of losing the repeated hour).
 * All-day ranges block 00:00–23:59 on each date. Coverage edges: before
 * windowStart is busy, from windowEnd on is busy. The edge readings probe the
 * offset at the instant and one hour before (head, the latest reading) or after
 * (tail, the earliest reading), so a fold next to an edge is covered too.
 * Windows are sorted by (date, start, end) and not merged; the engine merges.
 */
function calendarBusyGate(row, { timeZone, nowMs, ttlHours = TTL_HOURS }) {
  const freshness = gateFreshness(row, { nowMs, ttlHours });
  if (freshness.state !== 'fresh') return { state: freshness.state };
  const { parsed } = freshness;
  const windows = [];

  for (const [s, e] of parsed.timed) {
    const offS = offsetMinutes(s, timeZone);
    const offE = offsetMinutes(e, timeZone);
    pushLocalSpan(windows, s / MINUTE_MS + Math.min(offS, offE), e / MINUTE_MS + Math.max(offS, offE));
  }
  for (const [d1, d2] of parsed.allDay) {
    for (let day = d1; day <= d2; day += 1) {
      windows.push({ date: formatDays(day), start: '00:00', end: '23:59' });
    }
  }

  // Head: everything before windowStart is uncovered, so busy. Dates between
  // the owner's today and the head's date (a device clock up to 10 minutes
  // fast) are whole busy days.
  const W = parsed.windowStartMs;
  const headMin = W / MINUTE_MS + Math.max(offsetMinutes(W - HOUR_MS, timeZone), offsetMinutes(W, timeZone));
  const headDay = Math.floor(headMin / DAY_MINUTES);
  const headMinute = headMin - headDay * DAY_MINUTES;
  if (headMinute > 0) windows.push({ date: formatDays(headDay), start: '00:00', end: formatMinutes(headMinute) });
  const todayDays = parseDateDays(nowInZone(timeZone, nowMs).date);
  for (let day = todayDays; day < headDay; day += 1) {
    windows.push({ date: formatDays(day), start: '00:00', end: '23:59' });
  }

  // Tail: windowEnd's earliest local reading (D, M) starts busy time.
  const E = parsed.windowEndMs;
  const tailMin = E / MINUTE_MS + Math.min(offsetMinutes(E, timeZone), offsetMinutes(E + HOUR_MS, timeZone));
  const tailDay = Math.floor(tailMin / DAY_MINUTES);
  const tailMinute = tailMin - tailDay * DAY_MINUTES;
  let lastCoveredDays;
  if (tailMinute === 0) {
    lastCoveredDays = tailDay - 1;
  } else {
    lastCoveredDays = tailDay;
    if (tailMinute < DAY_MINUTES - 1) {
      windows.push({ date: formatDays(tailDay), start: formatMinutes(tailMinute), end: '23:59' });
    }
  }

  windows.sort((a, b) =>
    a.date !== b.date ? (a.date < b.date ? -1 : 1)
      : a.start !== b.start ? (a.start < b.start ? -1 : 1)
        : a.end < b.end ? -1 : a.end > b.end ? 1 : 0);
  return { state: 'fresh', windows, lastCoveredDate: formatDays(lastCoveredDays) };
}

module.exports = {
  TTL_HOURS,
  MAX_TIMED,
  MAX_ALL_DAY,
  MAX_WINDOW_DAYS,
  MAX_BODY_BYTES,
  MAX_SKEW_MS,
  isSourceId,
  parseInstant,
  parseDateDays,
  normalizeInstant,
  parseAnyInstant,
  formatInstant,
  validateSnapshot,
  gateFreshness,
  calendarBusyGate,
};
