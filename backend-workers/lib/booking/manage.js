// backend-workers/lib/booking/manage.js
// Customer manage cores (Phase 11 D1, 2026-08-07 spec §8): the manage token
// is a capability scoped to exactly ONE booking. The view answers the
// minimal card — businessName, status, slot — never the customer's own
// submission echo, never other bookings, never job data (config.js leak
// posture). Actions walk a strict state machine, append SERVER-written
// history, and cancel frees the reservation so the slot re-offers
// immediately. Owner notify is fire-and-forget, one push type
// (booking_update + jobId) so the app can land taps on the exact job.

const {
  fetchRequestByManageToken,
  fetchSettingsData,
  patchBookingRequest,
  updateReservationStatus,
  transitionBooking,
} = require('./store.js');
const { notifyOwnerUpdate } = require('./notifyOwner.js');

const MAX_NOTE = 300;

// action → legal source states, target state, side effects.
const TRANSITIONS = {
  confirm: { from: ['booked'], idempotentFrom: ['confirmed'], to: 'confirmed', free: false, notify: false },
  request_reschedule: { from: ['booked', 'confirmed'], idempotentFrom: [], to: 'reschedule_requested', free: false, notify: true },
  cancel: { from: ['booked', 'confirmed', 'reschedule_requested'], idempotentFrom: [], to: 'cancelled', free: true, notify: true },
};

async function manageViewCore(env, { token }) {
  if (!token || typeof token !== 'string') {
    return { status: 400, body: { error: 'Missing link parameters.' } };
  }

  let row;
  try {
    row = await fetchRequestByManageToken(env, token);
  } catch (err) {
    console.error('[booking/manage] lookup failed:', err.message);
    return { status: 500, body: { error: 'Database error' } };
  }
  if (!row || !row.data || !row.data.slot) {
    return { status: 404, body: { error: 'This link is invalid.' } };
  }

  let settings = null;
  try {
    settings = await fetchSettingsData(env, row.user_id);
  } catch (err) {
    console.error('[booking/manage] settings fetch failed:', err.message);
    return { status: 500, body: { error: 'Database error' } };
  }

  return {
    status: 200,
    body: {
      businessName: String(settings?.businessName || '').slice(0, 120),
      status: row.data.status,
      slot: row.data.slot,
    },
  };
}

async function manageActionCore(env, { token, action, note, nowMs }) {
  if (!token || typeof token !== 'string') {
    return { status: 400, body: { error: 'Missing link parameters.' } };
  }
  const t = TRANSITIONS[action];
  if (!t) return { status: 400, body: { error: 'Invalid action.' } };
  if (note !== undefined && (typeof note !== 'string' || note.length > MAX_NOTE)) {
    return { status: 400, body: { error: 'Note is too long.' } };
  }

  let row;
  try {
    row = await fetchRequestByManageToken(env, token);
  } catch (err) {
    console.error('[booking/manage] lookup failed:', err.message);
    return { status: 500, body: { error: 'Database error' } };
  }
  if (!row || !row.data || !row.data.slot) {
    return { status: 404, body: { error: 'This link is invalid.' } };
  }

  const current = row.data.status;
  // Retry/response-loss semantics (§2.2, verbatim): a retry after a COMMITTED
  // transition reads the new state and gets 409 invalid_state with the
  // current status echoed — the CLIENT (8.07) maps status == intended target
  // to success ("not server magic"). The server guarantee is no-write /
  // no-notify on 409, so a retried POST can never duplicate a transition,
  // history entry, or owner notification. The confirm-on-confirmed 200 below
  // is pre-8.04 legacy idempotence (pinned oracle), not the general rule.
  if (t.idempotentFrom.includes(current)) {
    return { status: 200, body: { ok: true, status: current } };
  }
  if (!t.from.includes(current)) {
    // 409 echoes the authoritative current status (§2.2) so the caller
    // reconciles without a second round trip. Additive field — old clients
    // matching on `error` are unaffected.
    return { status: 409, body: { error: 'invalid_state', status: current } };
  }

  const entry = {
    at: new Date(nowMs).toISOString(),
    actor: 'customer',
    event: action,
    ...(note && note.trim() ? { note: note.trim() } : {}),
  };

  // G2 atomic transition (8.04, §2.2): guarded write + reservation release +
  // exactly one history entry in ONE server transaction. Only the history
  // entry crosses into the RPC — never a whole-blob replay of a stale read
  // (§2.6 field protection); unknown/concurrent blob fields survive
  // server-side by merge.
  try {
    const stepped = await transitionBooking(env, {
      request_id: row.data.id,
      owner_id: null,
      manage_token: token,
      expected: t.from,
      target: t.to,
      history: entry,
      release: t.free,
      proof: null,
    });
    if (!stepped.unavailable) {
      if (!stepped.out.ok) {
        if (stepped.out.error === 'invalid_state') {
          return { status: 409, body: { error: 'invalid_state', status: stepped.out.status } };
        }
        if (stepped.out.error === 'not_found') {
          return { status: 404, body: { error: 'This link is invalid.' } };
        }
        console.error('[booking/manage] transition failed:', stepped.out.error);
        return { status: 500, body: { error: 'Database error' } };
      }
      // Notify exactly once per COMMITTED transition: 409 replays never reach
      // this point (no write, no notify above), so a retried POST cannot
      // double-notify. 8.07 maps a 409 whose echoed status equals the intended
      // target to success without contacting this path again.
      if (t.notify) await notifyTransition(env, row, entry, action, t.to);
      return { status: 200, body: { ok: true, status: t.to } };
    }
    // Function not deployed yet: legacy split path below, byte-identical to
    // the pre-8.04 behavior (dual-read compat, §10 step 3).
  } catch (err) {
    console.error('[booking/manage] transition RPC failed:', err.message);
    return { status: 500, body: { error: 'Database error' } };
  }

  const nextData = {
    ...row.data,
    status: t.to,
    history: [...(row.data.history || []), entry],
  };

  try {
    // Order: free the slot BEFORE the status write. If the free succeeds and
    // the patch fails, the slot is merely re-offerable early; the reverse
    // order could show "cancelled" while the slot stays held.
    if (t.free) await updateReservationStatus(env, row.data.id, 'cancelled');
    await patchBookingRequest(env, row.id, nextData, nowMs);
  } catch (err) {
    console.error('[booking/manage] write failed:', err.message);
    return { status: 500, body: { error: 'Database error' } };
  }

  if (t.notify) {
    try {
      await notifyTransition(env, row, entry, action, t.to);
    } catch (err) {
      console.error('[booking/manage] notify failed:', err.message);
    }
  }

  return { status: 200, body: { ok: true, status: t.to } };
}

// Fire-and-forget owner alert for a committed customer action. Reads fresh
// settings at send time; failures are logged and swallowed — a lost alert
// must never fail the customer's action, and the caller guarantees this runs
// at most once per (request, action, target).
async function notifyTransition(env, row, entry, action, target) {
  const settings = await fetchSettingsData(env, row.user_id);
  const nextData = { ...row.data, status: target, history: [...(row.data.history || []), entry] };
  await notifyOwnerUpdate(env, {
    userId: row.user_id,
    settingsData: settings,
    request: nextData,
    event: action,
    note: entry.note,
  });
}

module.exports = { manageViewCore, manageActionCore };
