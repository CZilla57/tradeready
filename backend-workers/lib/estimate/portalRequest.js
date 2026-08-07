// The portal's FIRST write path (Phase 12C): a portal customer requests
// follow-up work, or a reschedule/cancel of an owner-scheduled appointment.
// Insert-only — never a read-modify-write of an existing blob, so the
// estimate/CO stale-write exposure class does not apply here.
//
// - followup → a normal `status: "new"` bookingRequests row; the shipped
//   pipeline (owner push, device lead conversion) takes over. Contact fields
//   are copied server-side FROM the resolved customer record — the page
//   never supplies identity.
// - reschedule/cancel → `status: "portal_change_requested"`, a status value
//   OTA-old clients skip entirely (models.ts explicit-match rule), so these
//   rows can never become bogus leads; new clients surface them on Today.
// - Idempotent: id = bkpr_<sha256(token|requestKey).slice(0,20)>; the store
//   inserts with ignore-duplicates, so a retry is a silent no-op success.
// - Durable cap: 5 requests/day/token via portal_access_log. A cap-check DB
//   error fails OPEN (the in-memory IP limit still guards) — availability
//   over strictness for a solo-operator inbox.

const { createHash } = require('node:crypto');
const {
  lookupCustomerByPortalToken,
  fetchCustomerJobs,
} = require('./portalStore.js');
const {
  insertPortalRequest,
  logPortalEvent,
  countTodayRequests,
  fetchSettingsData,
} = require('./portalRequestStore.js');
const { notifyOwner } = require('../booking/notifyOwner.js');

const KINDS = new Set(['followup', 'reschedule', 'cancel']);
const REQUEST_KEY_RE = /^[A-Za-z0-9_-]{8,64}$/;
const DATE_RE = /^\d{4}-\d{2}-\d{2}$/;
const DAILY_CAP = 5;
const INVALID = { status: 404, json: { error: 'This link is invalid.' } };

function cap(value, n) {
  return String(value || '').slice(0, n);
}

async function portalRequestCore(env, { body, ip, nowMs }) {
  // Honeypot: bots fill it, humans never see it — fake success, no writes.
  if (typeof body.website === 'string' && body.website.trim() !== '') {
    console.warn('[estimate/portal-request] honeypot hit — dropped');
    return { status: 200, json: { ok: true } };
  }

  const token = body.p;
  if (!token || typeof token !== 'string') return { status: 400, json: { error: 'Missing link parameters.' } };

  const kind = body.kind;
  if (!KINDS.has(kind)) return { status: 400, json: { error: 'Invalid request.' } };
  if (typeof body.requestKey !== 'string' || !REQUEST_KEY_RE.test(body.requestKey)) {
    return { status: 400, json: { error: 'Invalid request.' } };
  }
  const note = cap(typeof body.note === 'string' ? body.note.trim() : '', 300);
  if (kind === 'followup' && !note) return { status: 400, json: { error: 'Please describe what you need.' } };

  const row = await lookupCustomerByPortalToken(env, String(token));
  if (!row) return INVALID;
  const tokenPrefix = String(token).slice(0, 8);

  // Durable per-token daily cap. Errors fail OPEN — a missing/broken log
  // table must not take the feature down; the in-memory IP limit remains.
  try {
    const used = await countTodayRequests(env, { userId: row.user_id, tokenPrefix, nowMs });
    if (used >= DAILY_CAP) {
      await logPortalEvent(env, { userId: row.user_id, tokenPrefix, event: 'denied', ip });
      return { status: 429, json: { error: 'Too many requests today.' } };
    }
  } catch (err) {
    console.error('[estimate/portal-request] cap check failed (failing open):', err.message);
  }

  const c = row.data || {};
  const request = {
    id: `bkpr_${createHash('sha256').update(`${token}|${body.requestKey}`).digest('hex').slice(0, 20)}`,
    status: 'new',
    name: cap(c.name, 120),
    phone: cap(c.phone, 40),
    email: cap(c.email, 254),
    address: cap(c.address, 200),
    details: note,
    preferredTiming: '',
    createdAt: new Date(nowMs).toISOString(),
    source: 'portal',
    sourceCustomerId: row.id,
  };

  if (kind === 'reschedule' || kind === 'cancel') {
    // The referenced appointment must be THIS customer's scheduled job —
    // anything else gets the same oracle-free 404 as a bad token.
    const jobs = await fetchCustomerJobs(env, row.user_id, row.id);
    const job = jobs.find((j) => j.id === String(body.jobRef || ''));
    const d = job && job.data;
    if (!d || typeof d.scheduledDate !== 'string' || !DATE_RE.test(d.scheduledDate)) return INVALID;
    request.status = 'portal_change_requested';
    request.jobRef = job.id;
    request.portalKind = kind;
    const verb = kind === 'reschedule' ? 'Reschedule' : 'Cancellation';
    request.details = `${verb} requested for "${cap(d.title, 200)}" (${d.scheduledDate})${note ? ` — ${note}` : ''}`;
  }

  await insertPortalRequest(env, row.user_id, request);
  await logPortalEvent(env, { userId: row.user_id, tokenPrefix, event: 'request', ip });

  // Owner push/email — fire-and-forget, never fails the submission.
  try {
    const settingsData = await fetchSettingsData(env, row.user_id);
    await notifyOwner(env, { userId: row.user_id, settingsData, request });
  } catch (err) {
    console.error('[estimate/portal-request] notify failed:', err.message);
  }

  return { status: 200, json: { ok: true } };
}

module.exports = { portalRequestCore };
