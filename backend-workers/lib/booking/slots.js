// backend-workers/lib/booking/slots.js
// Handler core for GET /api/booking/slots (Phase 11 C1, 2026-08-07 spec §8).
// Kept in lib/ as a plain (env, params) → {status, body} function so tests
// exercise it without a Hono context; the src/routes wrapper owns CORS,
// method checks, and the IP rate limit.
//
// Leak posture mirrors config.js: an anonymous caller learns ONLY the
// business display name, the IANA zone, and the offered slots. Unknown
// token, disabled link, and slot-booking-off are indistinguishable 404s.

const { resolveSchedule } = require('./availability.js');
const {
  lookupUserByBookingToken,
  fetchJobsData,
  fetchActiveReservations,
} = require('./store.js');
const { fetchCalendarBusy } = require('../calendar/busyStore.js');
const { offerableSlots } = require('./offerable.js');

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

  // Phase 26: the owner's calendar busy times ride the same parallel read.
  // A missing row or table is `off` (today's offers, byte for byte).
  let jobs, reservations, calendarRow;
  try {
    [jobs, reservations, calendarRow] = await Promise.all([
      fetchJobsData(env, row.user_id),
      fetchActiveReservations(env, row.user_id),
      fetchCalendarBusy(env, row.user_id),
    ]);
  } catch (err) {
    console.error('[booking/slots] data fetch failed:', err.message);
    return { status: 500, body: { error: 'Database error' } };
  }

  // A stale snapshot offers nothing, which looks exactly like "fully
  // booked" (no oracle); book.html then shows the request form.
  const { state, slots } = offerableSlots({ schedule, jobs, reservations, calendarRow, nowMs });
  if (state === 'stale') {
    console.warn(`[booking/slots] calendar_stale user=${String(row.user_id).slice(0, 8)}`);
  }

  return {
    status: 200,
    body: {
      businessName: String(row.data?.businessName || '').slice(0, 120),
      timeZone: schedule.timeZone,
      slots,
    },
  };
}

module.exports = { slotsCore };
