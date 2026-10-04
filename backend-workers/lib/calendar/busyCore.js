// backend-workers/lib/calendar/busyCore.js
// Handler core for POST /api/calendar/busy (Roadmap Phase 26, spec §3.1).
// A plain (env, params) → {status, body} function so tests run it without a
// Hono context; src/routes/calendar/busy.js owns CORS, the owner JWT and the
// per-user rate limit, exactly like the booking-admin route.
//
// Actions:
// - put {sourceId, snapshot | null, takeOver?}: validates, then replaces the
//   owner's row and stamps received_at with the Worker clock. Another
//   device's row answers 409 source_mismatch unless takeOver is true.
// - status {sourceId?}: what the settings page and the Today row show.
// - disable {}: deletes the owner's row, from any device (the owner's intent).
//
// Privacy (§5): put logs counts only (timed, allDay, window days) and a user
// id prefix, never an instant. A missing table answers 503 `unavailable`.

const {
  TTL_HOURS,
  MAX_BODY_BYTES,
  isSourceId,
  validateSnapshot,
  gateFreshness,
  normalizeInstant,
  parseAnyInstant,
} = require('./busyGate.js');
const { fetchCalendarBusyRow, upsertCalendarBusy, deleteCalendarBusy } = require('./busyStore.js');

const DAY_MS = 24 * 60 * 60 * 1000;

const invalidSnapshot = () => ({ status: 400, body: { error: 'invalid_snapshot' } });
const invalidRequest = () => ({ status: 400, body: { error: 'invalid_request' } });
const unavailable = () => ({ status: 503, body: { error: 'unavailable' } });
const databaseError = () => ({ status: 500, body: { error: 'Database error' } });

function isoOrNull(value) {
  const ms = parseAnyInstant(value);
  return ms === null ? null : new Date(ms).toISOString();
}

function byteLength(text) {
  return new TextEncoder().encode(text).length;
}

function userPrefix(userId) {
  return String(userId).slice(0, 8);
}

async function busyCore(env, { userId, body, nowMs, bodyBytes }) {
  if (typeof body !== 'object' || body === null || Array.isArray(body)) return invalidRequest();
  switch (body.action) {
    case 'put':
      return put(env, { userId, body, nowMs, bodyBytes });
    case 'status':
      return status(env, { userId, body, nowMs });
    case 'disable':
      return disable(env, { userId });
    default:
      return invalidRequest();
  }
}

async function put(env, { userId, body, nowMs, bodyBytes }) {
  const size = typeof bodyBytes === 'number' ? bodyBytes : byteLength(JSON.stringify(body));
  if (size > MAX_BODY_BYTES) return invalidSnapshot();
  if (!isSourceId(body.sourceId)) return invalidSnapshot();
  if (body.snapshot !== null && (typeof body.snapshot !== 'object' || Array.isArray(body.snapshot))) {
    return invalidSnapshot();
  }

  let checked = null;
  if (body.snapshot !== null) {
    checked = validateSnapshot(body.snapshot, { nowMs });
    if (!checked.ok) return invalidSnapshot();
  }

  let existing;
  try {
    existing = await fetchCalendarBusyRow(env, userId);
  } catch (err) {
    console.error('[calendar/busy] fetch failed:', err.message);
    return databaseError();
  }
  if (!existing.available) return unavailable();
  if (existing.row && existing.row.source_id !== body.sourceId && body.takeOver !== true) {
    return {
      status: 409,
      body: { error: 'source_mismatch', receivedAt: isoOrNull(existing.row.received_at) },
    };
  }

  const receivedAt = new Date(nowMs).toISOString();
  const snapshot = body.snapshot;
  const row = {
    user_id: userId,
    source_id: body.sourceId,
    snapshot: snapshot === null ? null : { v: 1, timed: snapshot.timed, allDay: snapshot.allDay },
    computed_at: snapshot === null ? null : snapshot.computedAt,
    window_start: snapshot === null ? null : snapshot.windowStart,
    window_end: snapshot === null ? null : snapshot.windowEnd,
    received_at: receivedAt,
  };

  try {
    const written = await upsertCalendarBusy(env, row);
    if (!written.available) return unavailable();
  } catch (err) {
    console.error('[calendar/busy] upsert failed:', err.message);
    return databaseError();
  }

  if (checked) {
    const windowDays = Math.round((checked.value.windowEndMs - checked.value.windowStartMs) / DAY_MS);
    console.log(
      `[calendar/busy] put user=${userPrefix(userId)} timed=${checked.value.timed.length} allDay=${checked.value.allDay.length} windowDays=${windowDays}`
    );
  } else {
    console.log(`[calendar/busy] put user=${userPrefix(userId)} snapshot=null`);
  }
  // `created` lets the source device notice that its row was removed
  // elsewhere (checks turned off on another device) since its last put.
  return { status: 200, body: { ok: true, receivedAt, created: !existing.row } };
}

async function status(env, { userId, body, nowMs }) {
  if (body.sourceId !== undefined && body.sourceId !== null && !isSourceId(body.sourceId)) {
    return invalidRequest();
  }
  let found;
  try {
    found = await fetchCalendarBusyRow(env, userId);
  } catch (err) {
    console.error('[calendar/busy] status fetch failed:', err.message);
    return databaseError();
  }
  if (!found.available) return unavailable();
  const row = found.row;
  return {
    status: 200,
    body: {
      ok: true,
      enabled: !!row,
      thisDevice: !!row && isSourceId(body.sourceId) && row.source_id === body.sourceId,
      shared: !!row && row.snapshot !== null && row.snapshot !== undefined,
      computedAt: row ? normalizeInstant(row.computed_at) : null,
      receivedAt: row ? isoOrNull(row.received_at) : null,
      fresh: gateFreshness(row, { nowMs }).state === 'fresh',
      ttlHours: TTL_HOURS,
    },
  };
}

async function disable(env, { userId }) {
  try {
    const removed = await deleteCalendarBusy(env, userId);
    if (!removed.available) return unavailable();
  } catch (err) {
    console.error('[calendar/busy] delete failed:', err.message);
    return databaseError();
  }
  console.log(`[calendar/busy] disable user=${userPrefix(userId)}`);
  return { status: 200, body: { ok: true } };
}

module.exports = { busyCore };
