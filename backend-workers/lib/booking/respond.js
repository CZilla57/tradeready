// backend-workers/lib/booking/respond.js
// Owner respond core (Phase 11 D2, 2026-08-07 spec §8). JWT resolution
// happens in the route wrapper; this core enforces OWNERSHIP as a 404 — a
// valid request id belonging to another user is indistinguishable from an
// unknown id (no oracle). Both actions free the reservation:
//   resolve_reschedule — the owner has re-scheduled the job in the app (the
//     job's own schedule is the busy-ness truth now) → status confirmed.
//   decline — owner rejects/cancels the booking → status declined + a
//     plain-wording email to the customer when an address is on file.

const {
  fetchRequestById,
  patchBookingRequest,
  updateReservationStatus,
} = require('./store.js');

const SENDER = 'TradeReady <leads@gettradereadyapp.com>';

const TRANSITIONS = {
  resolve_reschedule: { from: ['reschedule_requested'], to: 'confirmed', email: false },
  decline: { from: ['booked', 'confirmed', 'reschedule_requested'], to: 'declined', email: true },
};

function buildDeclineEmail({ to, request }) {
  const when = request.slot ? `${request.slot.date} at ${request.slot.start}` : 'your requested time';
  return {
    from: SENDER,
    to,
    subject: `About your appointment on ${request.slot ? request.slot.date : 'file'}`,
    text: [
      `Hi ${request.name || 'there'},`,
      ``,
      `Unfortunately the appointment you booked for ${when} can't go ahead as scheduled.`,
      `The business will reach out if a new time is possible, or you can rebook from their booking link.`,
      ``,
      `— TradeReady, on behalf of the business`,
    ].join('\n'),
  };
}

async function respondCore(env, { userId, requestId, action, nowMs }) {
  const t = TRANSITIONS[action];
  if (!t) return { status: 400, body: { error: 'Invalid action.' } };
  if (!requestId || typeof requestId !== 'string') {
    return { status: 400, body: { error: 'Missing request id.' } };
  }

  let row;
  try {
    row = await fetchRequestById(env, requestId);
  } catch (err) {
    console.error('[booking/respond] fetch failed:', err.message);
    return { status: 500, body: { error: 'Database error' } };
  }
  if (!row || row.user_id !== userId || !row.data) {
    return { status: 404, body: { error: 'Not found' } };
  }

  const current = row.data.status;
  if (!t.from.includes(current)) {
    return { status: 409, body: { error: 'invalid_state' } };
  }

  const nextData = {
    ...row.data,
    status: t.to,
    history: [
      ...(row.data.history || []),
      { at: new Date(nowMs).toISOString(), actor: 'owner', event: action },
    ],
  };

  try {
    await updateReservationStatus(env, row.data.id, 'cancelled');
    await patchBookingRequest(env, row.id, nextData, nowMs);
  } catch (err) {
    console.error('[booking/respond] write failed:', err.message);
    return { status: 500, body: { error: 'Database error' } };
  }

  if (t.email && row.data.email && env.RESEND_API_KEY) {
    try {
      const r = await fetch('https://api.resend.com/emails', {
        method: 'POST',
        headers: { Authorization: `Bearer ${env.RESEND_API_KEY}`, 'Content-Type': 'application/json' },
        body: JSON.stringify(buildDeclineEmail({ to: row.data.email, request: row.data })),
      });
      if (!r.ok) throw new Error(`Resend ${r.status}`);
    } catch (err) {
      console.error('[booking/respond] customer email failed:', err.message);
    }
  }

  return { status: 200, body: { ok: true, status: t.to } };
}

module.exports = { respondCore, buildDeclineEmail };
