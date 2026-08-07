// backend-workers/lib/booking/availability.js
// Server-side availability engine (Phase 11 B2, 2026-08-07 spec §5–6): the
// CommonJS twin of the client's utils/scheduleConfig.ts + utils/availability.ts,
// plus the naive→UTC resolver used at the public boundary. The server
// recomputes candidate slots from the settings blob + job blobs + active
// reservations at BOTH offer time (GET slots) and reserve time (membership
// check), so a stale hosted page can never book an invalid slot.
//
// ⚠️ PARITY: any behavior change here must land in the client twins too —
// __tests__/availabilityParity.test.ts pins them together. Same discipline
// as selectInvoicesToRemind / isPlausibleEmail.
//
// Timezone rules (spec §4): schedule data is owner-naive ("YYYY-MM-DD",
// "HH:MM"); zonedTimeToUtc resolves a naive slot to a UTC instant with the
// owner's IANA zone via the Intl offset-probe (no dependency). A local time
// skipped by spring-forward returns null (the slot is dropped from offers);
// a repeated fall-back time resolves to the FIRST occurrence.

const TIME_RE = /^([01]\d|2[0-3]):[0-5]\d$/;
const DATE_RE = /^\d{4}-\d{2}-\d{2}$/;
const DAY_MINUTES = 24 * 60;
const SLOT_GRID_MINUTES = 30;

const TERMINAL_STATUSES = new Set(["complete", "invoiced", "paid", "declined"]);

const SCHEDULE_DEFAULTS = Object.freeze({
  timeZone: null,
  workDays: Object.freeze([1, 2, 3, 4, 5, 6]),
  workDayStart: "08:00",
  workDayEnd: "17:00",
  defaultDurationMinutes: 60,
  bufferMinutes: 0,
  slotLeadHours: 24,
  slotWindowDays: 14,
  blackouts: Object.freeze([]),
  bookableSlotsEnabled: false,
});

function resolveNumber(raw, fallback, min, allowMin) {
  if (typeof raw !== "number" || !Number.isFinite(raw)) return fallback;
  if (allowMin ? raw < min : raw <= min) return fallback;
  return raw;
}

function resolveWorkDays(raw) {
  if (!Array.isArray(raw)) return [...SCHEDULE_DEFAULTS.workDays];
  const days = [
    ...new Set(
      raw.filter((d) => typeof d === "number" && Number.isInteger(d) && d >= 1 && d <= 7)
    ),
  ].sort((a, b) => a - b);
  return days.length > 0 ? days : [...SCHEDULE_DEFAULTS.workDays];
}

function resolveBlackouts(raw) {
  if (!Array.isArray(raw)) return [];
  const out = [];
  for (const entry of raw) {
    if (typeof entry !== "object" || entry === null) continue;
    if (typeof entry.id !== "string" || entry.id === "") continue;
    if (typeof entry.start !== "string" || !DATE_RE.test(entry.start)) continue;
    if (typeof entry.end !== "string" || !DATE_RE.test(entry.end)) continue;
    if (entry.end < entry.start) continue;
    out.push({
      id: entry.id,
      start: entry.start,
      end: entry.end,
      reason: typeof entry.reason === "string" ? entry.reason : undefined,
    });
  }
  return out;
}

/** Twin of utils/scheduleConfig.ts resolveSchedule — takes the settings
 *  blob (`data` column contents) and returns the sanitized config. */
function resolveSchedule(settingsData) {
  const raw = (settingsData && settingsData.schedule) || {};

  let workDayStart =
    typeof raw.workDayStart === "string" && TIME_RE.test(raw.workDayStart)
      ? raw.workDayStart
      : SCHEDULE_DEFAULTS.workDayStart;
  let workDayEnd =
    typeof raw.workDayEnd === "string" && TIME_RE.test(raw.workDayEnd)
      ? raw.workDayEnd
      : SCHEDULE_DEFAULTS.workDayEnd;
  if (workDayStart >= workDayEnd) {
    workDayStart = SCHEDULE_DEFAULTS.workDayStart;
    workDayEnd = SCHEDULE_DEFAULTS.workDayEnd;
  }

  return {
    timeZone: typeof raw.timeZone === "string" && raw.timeZone !== "" ? raw.timeZone : null,
    workDays: resolveWorkDays(raw.workDays),
    workDayStart,
    workDayEnd,
    defaultDurationMinutes: resolveNumber(
      raw.defaultDurationMinutes,
      SCHEDULE_DEFAULTS.defaultDurationMinutes,
      0,
      false
    ),
    bufferMinutes: resolveNumber(raw.bufferMinutes, SCHEDULE_DEFAULTS.bufferMinutes, 0, true),
    slotLeadHours: resolveNumber(raw.slotLeadHours, SCHEDULE_DEFAULTS.slotLeadHours, 0, true),
    slotWindowDays: resolveNumber(
      raw.slotWindowDays,
      SCHEDULE_DEFAULTS.slotWindowDays,
      0,
      false
    ),
    blackouts: resolveBlackouts(raw.blackouts),
    bookableSlotsEnabled: raw.bookableSlotsEnabled === true,
  };
}

function toMinutes(time) {
  const [h, m] = time.split(":").map(Number);
  return h * 60 + m;
}

function minutesToTime(minutes) {
  const h = Math.floor(minutes / 60);
  const m = minutes % 60;
  return `${String(h).padStart(2, "0")}:${String(m).padStart(2, "0")}`;
}

/** UTC-epoch day arithmetic on date components — DST-immune, frame-free. */
function epochDays(date) {
  const [y, m, d] = date.split("-").map(Number);
  return Date.UTC(y, m - 1, d) / 86400000;
}

function shiftNaiveDate(date, days) {
  const [y, m, d] = date.split("-").map(Number);
  const shifted = new Date(Date.UTC(y, m - 1, d + days));
  const yy = shifted.getUTCFullYear();
  const mm = String(shifted.getUTCMonth() + 1).padStart(2, "0");
  const dd = String(shifted.getUTCDate()).padStart(2, "0");
  return `${yy}-${mm}-${dd}`;
}

/** ISO weekday 1–7 (Mon=1) from epoch-day arithmetic (1970-01-01 = Thu). */
function isoWeekday(date) {
  return ((epochDays(date) + 3) % 7) + 1;
}

function isWorkDay(schedule, date) {
  return schedule.workDays.includes(isoWeekday(date));
}

function isBlackoutDate(schedule, date) {
  return schedule.blackouts.some((b) => b.start <= date && date <= b.end);
}

/** Twin of scheduleSmarts.blockWindow: missing end blocks max(labor, 1h). */
function blockWindow(start, end, laborHours) {
  const s = toMinutes(start);
  if (end) return [s, toMinutes(end)];
  return [s, Math.min(s + Math.max(laborHours, 1) * 60, DAY_MINUTES)];
}

function busyWindowsFor(date, jobs, extraBusy, bufferMinutes) {
  const raw = [];
  for (const j of jobs) {
    if (j.scheduledDate !== date) continue;
    if (!j.scheduledStartTime) continue;
    if (TERMINAL_STATUSES.has(j.status)) continue;
    raw.push(
      blockWindow(j.scheduledStartTime, j.scheduledEndTime, j.laborHours == null ? 0 : j.laborHours)
    );
  }
  for (const b of extraBusy) {
    if (b.date !== date) continue;
    raw.push([toMinutes(b.start), toMinutes(b.end)]);
  }

  const padded = raw
    .map(([s, e]) => [Math.max(0, s - bufferMinutes), Math.min(DAY_MINUTES, e + bufferMinutes)])
    .filter(([s, e]) => s < e)
    .sort((a, b) => a[0] - b[0]);

  const merged = [];
  for (const [s, e] of padded) {
    const last = merged[merged.length - 1];
    if (last && s <= last[1]) last[1] = Math.max(last[1], e);
    else merged.push([s, e]);
  }
  return merged;
}

/** Twin of utils/availability.ts computeCandidateSlots — same input shape,
 *  same output, byte for byte (parity suite). */
function computeCandidateSlots(input) {
  const { schedule, jobs, extraBusy = [], fromDate, days, now } = input;
  const duration = schedule.defaultDurationMinutes;
  const workStart = toMinutes(schedule.workDayStart);
  const workEnd = toMinutes(schedule.workDayEnd);
  const earliestAbs =
    epochDays(now.date) * DAY_MINUTES + now.minutes + schedule.slotLeadHours * 60;

  const out = [];

  for (let i = 0; i < days; i++) {
    const date = shiftNaiveDate(fromDate, i);
    if (!isWorkDay(schedule, date)) continue;
    if (isBlackoutDate(schedule, date)) continue;

    const dayAbs = epochDays(date) * DAY_MINUTES;
    const busy = busyWindowsFor(date, jobs, extraBusy, schedule.bufferMinutes);

    const gaps = [];
    let cursor = workStart;
    for (const [s, e] of busy) {
      if (s > cursor) gaps.push([cursor, Math.min(s, workEnd)]);
      cursor = Math.max(cursor, e);
      if (cursor >= workEnd) break;
    }
    if (cursor < workEnd) gaps.push([cursor, workEnd]);

    for (const [gapStart, gapEnd] of gaps) {
      let start = Math.ceil(gapStart / SLOT_GRID_MINUTES) * SLOT_GRID_MINUTES;
      for (; start + duration <= gapEnd; start += SLOT_GRID_MINUTES) {
        if (dayAbs + start < earliestAbs) continue;
        out.push({ date, start: minutesToTime(start), end: minutesToTime(start + duration) });
      }
    }
  }

  return out;
}

/** Milliseconds the zone is ahead of UTC at the given UTC instant. */
function offsetAt(utcMs, timeZone) {
  const dtf = new Intl.DateTimeFormat("en-US", {
    timeZone,
    hour12: false,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
  });
  const parts = {};
  for (const p of dtf.formatToParts(new Date(utcMs))) parts[p.type] = p.value;
  const asUtc = Date.UTC(
    Number(parts.year),
    Number(parts.month) - 1,
    Number(parts.day),
    parts.hour === "24" ? 0 : Number(parts.hour),
    Number(parts.minute),
    Number(parts.second)
  );
  return asUtc - utcMs;
}

/**
 * Resolve an owner-naive date+time to a UTC instant in `timeZone`.
 * Returns an ISO string, or null when the local time does not exist
 * (spring-forward gap). An ambiguous fall-back time resolves to the FIRST
 * occurrence (the earlier UTC instant — the larger, pre-transition offset).
 */
function zonedTimeToUtc(date, time, timeZone) {
  const [y, mo, d] = date.split("-").map(Number);
  const [h, mi] = time.split(":").map(Number);
  const naiveUtcMs = Date.UTC(y, mo - 1, d, h, mi);

  const candidateOffsets = new Set();
  for (const probe of [naiveUtcMs - 86400000, naiveUtcMs, naiveUtcMs + 86400000]) {
    candidateOffsets.add(offsetAt(probe, timeZone));
  }

  const matches = [];
  for (const off of candidateOffsets) {
    const utcMs = naiveUtcMs - off;
    if (offsetAt(utcMs, timeZone) === off) matches.push(utcMs);
  }
  if (matches.length === 0) return null;
  return new Date(Math.min(...matches)).toISOString();
}

/**
 * Map candidate slots to public offers carrying UTC instants. A slot whose
 * START does not exist locally is dropped (spec §4 rule 4); an endUtc that
 * lands in a gap resolves via the same probe and cannot be null when the
 * start resolved (offset transitions are step functions — the end simply
 * lands on the post-transition offset).
 */
function resolveSlotsUtc(slots, timeZone) {
  const out = [];
  for (const s of slots) {
    const startUtc = zonedTimeToUtc(s.date, s.start, timeZone);
    if (startUtc === null) continue;
    let endUtc = zonedTimeToUtc(s.date, s.end, timeZone);
    if (endUtc === null) {
      // End inside a spring-forward gap: derive from the start instant plus
      // the naive duration so the offer still carries a usable window.
      const duration = toMinutes(s.end) - toMinutes(s.start);
      endUtc = new Date(Date.parse(startUtc) + duration * 60000).toISOString();
    }
    out.push({ ...s, startUtc, endUtc });
  }
  return out;
}

/** The owner-naive clock ({date, minutes}) for a UTC instant in `timeZone`
 *  — what the engines' injected `now` expects at the public boundary. */
function nowInZone(timeZone, nowMs) {
  const dtf = new Intl.DateTimeFormat("en-US", {
    timeZone,
    hour12: false,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
  });
  const parts = {};
  for (const p of dtf.formatToParts(new Date(nowMs))) parts[p.type] = p.value;
  const h = parts.hour === "24" ? 0 : Number(parts.hour);
  return {
    date: `${parts.year}-${parts.month}-${parts.day}`,
    minutes: h * 60 + Number(parts.minute),
  };
}

module.exports = {
  SCHEDULE_DEFAULTS,
  resolveSchedule,
  computeCandidateSlots,
  zonedTimeToUtc,
  resolveSlotsUtc,
  nowInZone,
};
