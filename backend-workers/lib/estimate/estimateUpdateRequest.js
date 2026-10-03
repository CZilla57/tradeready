// "Request an updated estimate" (Roadmap Phase 32, spec
// docs/superpowers/specs/2026-10-03-quote-expiration-design.md §4.5).
// The customer's page offers this once an estimate is past its valid-until
// date; it lands in the owner's existing attention pipeline as a
// `portal_change_requested` row with `portalKind: "quote_update"`.
//
// - Token-gated exactly like view/respond: the approval token is the
//   capability, compared in constant time; every miss is the same 404.
// - Insert-only — never a read-modify-write of the job blob, so it sits
//   outside the device's last-write-wins race and needs no trigger change.
// - One row per expiry episode: id = bkeu_<sha256(jobId|token|validUntil)>.
//   An extension changes validUntil, so a later expiry is a new episode.
//   insertRequestIfAbsent reports whether THIS call created the row, and only
//   that call notifies the owner — a retry or second click is a silent no-op.
// - No contact fields are copied: the owner already has them on the job.

const { createHash } = require('node:crypto');
const { fetchJob, constantTimeEqual } = require('../estimateStore.js');
const { insertRequestIfAbsent, fetchSettingsData } = require('./portalRequestStore.js');
const { notifyOwnerUpdate } = require('../booking/notifyOwner.js');
const { snapshotExpiry, formatValidUntil } = require('./estimateExpiry.js');

const NOTE_MAX_CHARS = 300;
const INVALID = { status: 404, json: { error: 'This link is invalid or has expired.' } };
const OK = { status: 200, json: { ok: true } };

function cap(value, n) {
  return String(value || '').slice(0, n);
}

async function estimateUpdateRequestCore(env, { body, ip, nowMs }) {
  const b = body && typeof body === 'object' ? body : {};

  // Honeypot: bots fill it, humans never see it — fake success, no writes.
  if (typeof b.website === 'string' && b.website.trim() !== '') {
    console.warn('[estimate/request-update] honeypot hit — dropped');
    return OK;
  }

  const { jobId, token } = b;
  if (!jobId || !token || typeof jobId !== 'string' || typeof token !== 'string') {
    return { status: 400, json: { error: 'Missing link parameters.' } };
  }
  const note = cap(typeof b.note === 'string' ? b.note.trim() : '', NOTE_MAX_CHARS);

  const row = await fetchJob(env, jobId);
  const data = (row && row.data) || {};
  const approval = data.approval;
  if (!row || !approval || !constantTimeEqual(approval.token, token)) return INVALID;

  if (approval.decision === 'approved') {
    return { status: 409, json: { error: 'This estimate was already approved.', code: 'already_approved' } };
  }
  const snapshot = approval.snapshot || {};
  const { validUntil, expired } = snapshotExpiry(snapshot, nowMs);
  if (!expired) {
    return {
      status: 409,
      json: { error: 'This estimate is still open. Please reload the page.', code: 'estimate_not_expired' },
    };
  }

  const request = {
    id: `bkeu_${createHash('sha256').update(`${jobId}|${token}|${validUntil}`).digest('hex').slice(0, 20)}`,
    status: 'portal_change_requested',
    portalKind: 'quote_update',
    jobRef: jobId,
    name: cap(snapshot.customerName || data.customerName, 120),
    phone: '',
    email: '',
    address: '',
    details: `Updated estimate requested for "${cap(snapshot.jobTitle || data.title, 200)}" (expired ${formatValidUntil(validUntil)})${note ? ` — ${note}` : ''}`,
    preferredTiming: '',
    createdAt: new Date(nowMs).toISOString(),
    source: 'estimate',
    sourceCustomerId: typeof data.customerId === 'string' ? data.customerId : undefined,
  };

  const inserted = await insertRequestIfAbsent(env, row.user_id, request);

  // Owner email (push is a no-op on native today) — only for the call that
  // created the row. Never fails the customer's request.
  if (inserted) {
    try {
      const settingsData = await fetchSettingsData(env, row.user_id);
      await notifyOwnerUpdate(env, { userId: row.user_id, settingsData, request, event: 'quote_update', note });
    } catch (err) {
      console.error('[estimate/request-update] notify failed:', err.message);
    }
  }

  return OK;
}

module.exports = { estimateUpdateRequestCore, NOTE_MAX_CHARS };
