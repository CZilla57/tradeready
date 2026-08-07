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
  if (t.idempotentFrom.includes(current)) {
    return { status: 200, body: { ok: true, status: current } };
  }
  if (!t.from.includes(current)) {
    return { status: 409, body: { error: 'invalid_state' } };
  }

  const entry = {
    at: new Date(nowMs).toISOString(),
    actor: 'customer',
    event: action,
    ...(note && note.trim() ? { note: note.trim() } : {}),
  };
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
      const settings = await fetchSettingsData(env, row.user_id);
      await notifyOwnerUpdate(env, {
        userId: row.user_id,
        settingsData: settings,
        request: nextData,
        event: action,
        note: entry.note,
      });
    } catch (err) {
      console.error('[booking/manage] notify failed:', err.message);
    }
  }

  return { status: 200, body: { ok: true, status: t.to } };
}

module.exports = { manageViewCore, manageActionCore };
