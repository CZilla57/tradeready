// backend-workers/lib/booking/slots.js
// Handler core for GET /api/booking/slots (Phase 11 C1, 2026-08-07 spec §8).
// Kept in lib/ as a plain (env, params) → {status, body} function so tests
// exercise it without a Hono context; the src/routes wrapper owns CORS,
// method checks, and the IP rate limit.
//
// Leak posture mirrors config.js: an anonymous caller learns ONLY the
// business display name, the IANA zone, and the offered slots. Unknown
// token, disabled link, and slot-booking-off are indistinguishable 404s.

const {
  resolveSchedule,
  computeCandidateSlots,
  resolveSlotsUtc,
  nowInZone,
} = require('./availability.js');
const {
  lookupUserByBookingToken,
  fetchJobsData,
  fetchActiveReservations,
} = require('./store.js');

async function slotsCore(env, { token, nowMs }) {
  if (!token || typeof token !== 'string') {
    return { status: 400, body: { error: 'Missing link parameters.' } };
  }

  let row;
  try {
    row = await lookupUserByBookingToken(env, token);
  } catch (err) {
    console.error('[booking/slots] lookup failed:', err.message);
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
    console.error('[booking/slots] data fetch failed:', err.message);
    return { status: 500, body: { error: 'Database error' } };
  }

  const now = nowInZone(schedule.timeZone, nowMs);
  const extraBusy = reservations.map((r) => ({
    date: r.slot_date,
    start: r.slot_start,
    end: r.slot_end,
  }));
  const slots = computeCandidateSlots({
    schedule,
    jobs,
    extraBusy,
    fromDate: now.date,
    days: schedule.slotWindowDays,
    now,
  });

  return {
    status: 200,
    body: {
      businessName: String(row.data?.businessName || '').slice(0, 120),
      timeZone: schedule.timeZone,
      slots: resolveSlotsUtc(slots, schedule.timeZone),
    },
  };
}

module.exports = { slotsCore };
