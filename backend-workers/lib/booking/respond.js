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
  transitionBooking,
  fetchJobRowForProof,
  proofMatchesJob,
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

async function respondCore(env, { userId, requestId, action, nowMs, scheduleProof }) {
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
  // Retry/response-loss semantics (§2.2, verbatim): a retry after a COMMITTED
  // transition gets 409 invalid_state with the current status echoed — the
  // CLIENT (8.07) maps status == intended target to success ("not server
  // magic"). The server guarantee is no-write / no-email on 409, so a
  // retried POST can never duplicate a transition, history entry, or the
  // decline email.
  if (!t.from.includes(current)) {
    // Additive `status` echo (§2.2); old clients matching on `error` are
    // unaffected.
    return { status: 409, body: { error: 'invalid_state', status: current } };
  }

  const entry = { at: new Date(nowMs).toISOString(), actor: 'owner', event: action };

  // Replacement-schedule publication proof (§7 steps 2–3): a native
  // resolve_reschedule carries {jobId, updatedAt, date, start} proving the
  // revised job schedule was durably published. A superseding schedule edit
  // after proof generation REFUSES with schedule_changed and the hold is NOT
  // released. Calls WITHOUT proof are legacy RN calls (limitation L2,
  // accepted for compat): the transition proceeds unverified and is logged.
  const proof = action === 'resolve_reschedule' ? normalizeProof(scheduleProof) : null;
  if (action === 'resolve_reschedule' && !proof) {
    console.warn('[booking/respond] proof-less resolve_reschedule (legacy L2) — proceeding unverified');
  }

  // G2 atomic transition (8.04, §2.2): guarded write + reservation release +
  // exactly one history entry in ONE server transaction. Only the history
  // entry crosses into the RPC — never a whole-blob replay (§2.6).
  try {
    const stepped = await transitionBooking(env, {
      request_id: row.data.id,
      owner_id: userId,
      manage_token: null,
      expected: t.from,
      target: t.to,
      history: entry,
      release: true,
      proof,
    });
    if (!stepped.unavailable) {
      if (!stepped.out.ok) {
        if (stepped.out.error === 'invalid_state') {
          return { status: 409, body: { error: 'invalid_state', status: stepped.out.status } };
        }
        if (stepped.out.error === 'schedule_changed') {
          return { status: 409, body: { error: 'schedule_changed', status: stepped.out.status } };
        }
        if (stepped.out.error === 'not_found') {
          return { status: 404, body: { error: 'Not found' } };
        }
        console.error('[booking/respond] transition failed:', stepped.out.error);
        return { status: 500, body: { error: 'Database error' } };
      }
      // Exactly-once customer email per COMMITTED decline: 409 replays return
      // before this point (no write, no email), so a retried POST cannot send
      // a duplicate native notification email. 8.07 maps a 409 whose echoed
      // status equals the intended target to success.
      if (t.email) await sendDeclineEmail(env, row.data);
      return { status: 200, body: { ok: true, status: t.to } };
    }
    // Function not deployed yet: legacy split path below, byte-identical to
    // the pre-8.04 behavior (dual-read compat, §10 step 3).
  } catch (err) {
    console.error('[booking/respond] transition RPC failed:', err.message);
    return { status: 500, body: { error: 'Database error' } };
  }

  if (proof) {
    let jobRow;
    try {
      jobRow = await fetchJobRowForProof(env, userId, proof.jobId);
    } catch (err) {
      console.error('[booking/respond] proof fetch failed:', err.message);
      return { status: 500, body: { error: 'Database error' } };
    }
    if (!proofMatchesJob(jobRow, proof)) {
      return { status: 409, body: { error: 'schedule_changed', status: current } };
    }
  }

  const nextData = {
    ...row.data,
    status: t.to,
    history: [
      ...(row.data.history || []),
      entry,
    ],
  };

  try {
    await updateReservationStatus(env, row.data.id, 'cancelled');
    await patchBookingRequest(env, row.id, nextData, nowMs);
  } catch (err) {
    console.error('[booking/respond] write failed:', err.message);
    return { status: 500, body: { error: 'Database error' } };
  }

  if (t.email) await sendDeclineEmail(env, row.data);

  return { status: 200, body: { ok: true, status: t.to } };
}

// Decline email transport: fire-and-forget, at most once per committed
// decline (the caller guarantees single execution). No address on file or no
// Resend key → silent success; a failed send is logged, never retried here
// (retrying a send after an unknown outcome could duplicate the email).
async function sendDeclineEmail(env, request) {
  if (!request.email || !env.RESEND_API_KEY) return;
  try {
    const r = await fetch('https://api.resend.com/emails', {
      method: 'POST',
      headers: { Authorization: `Bearer ${env.RESEND_API_KEY}`, 'Content-Type': 'application/json' },
      body: JSON.stringify(buildDeclineEmail({ to: request.email, request })),
    });
    if (!r.ok) throw new Error(`Resend ${r.status}`);
  } catch (err) {
    console.error('[booking/respond] customer email failed:', err.message);
  }
}

// Strict-shape proof normalization: anything not carrying the exact
// {jobId, updatedAt, date, start} fields is NOT a proof (legacy L2 path),
// never a partial verification.
function normalizeProof(p) {
  if (!p || typeof p !== 'object') return null;
  if (typeof p.jobId !== 'string' || !p.jobId) return null;
  if (typeof p.updatedAt !== 'string' || !p.updatedAt) return null;
  if (typeof p.date !== 'string' || typeof p.start !== 'string') return null;
  return { jobId: p.jobId, updatedAt: p.updatedAt, date: p.date, start: p.start };
}

module.exports = { respondCore, buildDeclineEmail };
