// backend-workers/lib/booking/reserve.js
// Handler core for POST /api/booking/reserve (Phase 11 C2, 2026-08-07 spec
// §6). Sequence: honeypot → shape/contact validation → token + slots-on gate
// (no oracle) → SERVER RECOMPUTE membership check (a stale page can't book an
// invalid slot) → atomic reservation INSERT (unique-index race loser → 409
// slot_taken) → bookingRequests blob row (kind "booked") with best-effort
// compensation delete if that second write fails → fire-and-forget owner
// notify. Time (`nowMs`), the id suffix (`randHex`), and the manage token
// are injected by the route wrapper so this core is deterministic in tests.

const {
  resolveSchedule,
  computeCandidateSlots,
  resolveSlotsUtc,
  nowInZone,
} = require('./availability.js');
const {
  lookupUserByBookingToken,
  insertBookingRequest,
  newRequestId,
  newReservationId,
  fetchJobsData,
  fetchActiveReservations,
  insertReservation,
  deleteReservation,
} = require('./store.js');
const { validateBookingPayload } = require('./validate.js');
const { notifyOwner } = require('./notifyOwner.js');

const DATE_RE = /^\d{4}-\d{2}-\d{2}$/;
const TIME_RE = /^([01]\d|2[0-3]):[0-5]\d$/;

async function reserveCore(env, { body, nowMs, randHex, manageToken }) {
  if (typeof body.website === 'string' && body.website.trim() !== '') {
    console.warn('[booking/reserve] honeypot hit — submission dropped');
    return { status: 200, body: { ok: true } };
  }

  const token = body.b;
  if (!token || typeof token !== 'string') {
    return { status: 400, body: { error: 'Missing link parameters.' } };
  }

  const slot = body.slot;
  if (
    !slot ||
    typeof slot.date !== 'string' ||
    !DATE_RE.test(slot.date) ||
    typeof slot.start !== 'string' ||
    !TIME_RE.test(slot.start)
  ) {
    return { status: 400, body: { error: 'Invalid slot.' } };
  }

  const checked = validateBookingPayload(body);
  if (!checked.ok) return { status: 400, body: { error: checked.error } };

  let row;
  try {
    row = await lookupUserByBookingToken(env, token);
  } catch (err) {
    console.error('[booking/reserve] lookup failed:', err.message);
    return { status: 500, body: { error: 'Database error' } };
  }
  if (!row) return { status: 404, body: { error: 'This link is invalid.' } };

  const schedule = resolveSchedule(row.data);
  if (!schedule.bookableSlotsEnabled || !schedule.timeZone) {
    return { status: 404, body: { error: 'This link is invalid.' } };
  }

  let jobs, reservations;
  try {
    [jobs, reservations] = await Promise.all([
      fetchJobsData(env, row.user_id),
      fetchActiveReservations(env, row.user_id),
    ]);
  } catch (err) {
    console.error('[booking/reserve] data fetch failed:', err.message);
    return { status: 500, body: { error: 'Database error' } };
  }

  // Server-authoritative membership check: the requested slot must be a
  // CURRENT candidate. Stale offer and taken slot answer identically — the
  // page's remedy is the same (refresh the slot list).
  const now = nowInZone(schedule.timeZone, nowMs);
  const candidates = computeCandidateSlots({
    schedule,
    jobs,
    extraBusy: reservations.map((r) => ({ date: r.slot_date, start: r.slot_start, end: r.slot_end })),
    fromDate: now.date,
    days: schedule.slotWindowDays,
    now,
  });
  const match = candidates.find((s) => s.date === slot.date && s.start === slot.start);
  if (!match) return { status: 409, body: { error: 'slot_taken' } };

  const resolved = resolveSlotsUtc([match], schedule.timeZone);
  if (resolved.length === 0) return { status: 409, body: { error: 'slot_taken' } };
  const offer = resolved[0];

  const requestId = newRequestId(nowMs, randHex);
  const reservationId = newReservationId(nowMs, randHex);

  try {
    const { conflict } = await insertReservation(env, {
      id: reservationId,
      user_id: row.user_id,
      request_id: requestId,
      slot_date: offer.date,
      slot_start: offer.start,
      slot_end: offer.end,
      slot_start_utc: offer.startUtc,
      slot_end_utc: offer.endUtc,
      status: 'booked',
    });
    if (conflict) return { status: 409, body: { error: 'slot_taken' } };
  } catch (err) {
    console.error('[booking/reserve] reservation insert failed:', err.message);
    return { status: 500, body: { error: 'Database error' } };
  }

  const request = {
    id: requestId,
    status: 'booked',
    kind: 'booked',
    ...checked.value,
    slot: {
      date: offer.date,
      start: offer.start,
      end: offer.end,
      timeZone: schedule.timeZone,
      startUtc: offer.startUtc,
      endUtc: offer.endUtc,
    },
    manageToken,
    history: [{ at: new Date(nowMs).toISOString(), actor: 'customer', event: 'booked' }],
    createdAt: new Date(nowMs).toISOString(),
  };

  try {
    await insertBookingRequest(env, row.user_id, request);
  } catch (err) {
    console.error('[booking/reserve] request insert failed:', err.message);
    try {
      await deleteReservation(env, reservationId);
    } catch (cleanupErr) {
      // A held slot with no request row — surfaced in logs; the owner can
      // free it by declining from the app once Phase D lands.
      console.error('[booking/reserve] compensation delete failed:', cleanupErr.message);
    }
    return { status: 500, body: { error: 'Database error' } };
  }

  try {
    await notifyOwner(env, { userId: row.user_id, settingsData: row.data, request });
  } catch (err) {
    console.error('[booking/reserve] notify failed:', err.message);
  }

  return { status: 200, body: { ok: true, manageToken, slot: request.slot } };
}

module.exports = { reserveCore };
