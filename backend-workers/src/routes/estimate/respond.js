// POST /api/estimate/respond — Workers port of backend/lib/estimate/respond.js.
// The customer's Approve/Decline. Token-gated (no user auth — the token is the
// capability). Stamps consentAt SERVER-SIDE and merges only approval.* into the
// job blob (service role). The device performs the status transition on pull.
//
// Phase 25 (good/better/best): option estimates require the snapshot digest
// the page was shown and, on approve, a {tierId, addOnIds} choice that is
// resolved against the frozen snapshot and stored as approval.selection. The
// write is conditional on the row version that was read, so a concurrent
// device push and a customer decision can no longer silently overwrite each
// other.

import { fetchJob, updateJobIfUnchanged, constantTimeEqual } from '../../../lib/estimateStore.js';
import { createRateLimiter } from '../../../lib/guards.js';
import { applyCors } from '../../../lib/estimate/cors.js';
import {
  hasSnapshotOptions,
  isResolvedSelection,
  resolveSelection,
  snapshotDigest,
} from '../../../lib/estimate/quoteOptions.js';
import { clientIp, jsonBody } from '../../appCors.js';

const allow = createRateLimiter({ limit: 10 });

// read → validate → merge → conditional write, at most this many times.
export const RESPOND_WRITE_ATTEMPTS = 3;

const STALE_SNAPSHOT_ERROR = 'This estimate was just updated. Please reload the page to see the latest version.';
const SELECTION_ERRORS = {
  choose_option: 'Please choose an option.',
  invalid_addons: 'Invalid add-on selection.',
};

// Pure decision merge — exported for reuse (change-respond). Returns the SAME
// reference when locked (already approved) so callers can skip a needless DB
// write. `body.selection` is persisted only on approve and only when it is a
// selection resolveSelection produced; change-respond never passes one.
export function nextApproval(existing, body, meta) {
  if (existing && existing.decision === 'approved') return existing; // terminal lock
  const decision = body.decision === 'approved' ? 'approved' : 'declined';
  const next = {
    ...existing,
    decision,
    consentAt: meta.consentAt,
    signerName: decision === 'approved' ? String(body.signerName || '').slice(0, 200) : (existing && existing.signerName),
    declineReason: decision === 'declined' ? String(body.declineReason || '').slice(0, 500) || undefined : undefined,
    ip: meta.ip,
    userAgent: meta.userAgent,
  };
  if (decision === 'approved' && isResolvedSelection(body.selection)) next.selection = body.selection;
  return next;
}

export async function estimateRespondHandler(c) {
  applyCors(c, 'POST, OPTIONS');
  if (c.req.method === 'OPTIONS') return c.body(null, 200);
  if (c.req.method !== 'POST') return c.json({ error: 'Method not allowed' }, 405);

  const ip = clientIp(c);
  if (!allow(ip)) return c.json({ error: 'Too many requests.' }, 429);

  const { jobId, token, decision, signerName, declineReason, selection, snapshotDigest: sentDigest } = (await jsonBody(c)) || {};
  if (!jobId || !token) return c.json({ error: 'Missing link parameters.' }, 400);
  if (decision !== 'approved' && decision !== 'declined') return c.json({ error: 'Invalid decision.' }, 400);
  if (decision === 'approved' && !String(signerName || '').trim()) {
    return c.json({ error: 'Please type your name to approve.' }, 400);
  }

  const meta = {
    consentAt: new Date().toISOString(),
    ip,
    userAgent: String(c.req.header('user-agent') || '').slice(0, 300),
  };

  for (let attempt = 0; attempt < RESPOND_WRITE_ATTEMPTS; attempt += 1) {
    let row;
    try {
      row = await fetchJob(c.env, jobId);
    } catch (err) {
      console.error('[estimate/respond] fetch failed:', err.message);
      return c.json({ error: 'Database error' }, 500);
    }
    const existing = row && row.data && row.data.approval;
    if (!row || !existing || !constantTimeEqual(existing.token, String(token))) {
      return c.json({ error: 'This link is invalid or has expired.' }, 404);
    }

    // Option estimates must prove the page showed THIS snapshot; legacy
    // estimates are only checked when the page sent a digest.
    const withOptions = hasSnapshotOptions(existing.snapshot);
    if (withOptions || sentDigest != null) {
      if (sentDigest !== snapshotDigest(existing.snapshot)) {
        return c.json({ error: STALE_SNAPSHOT_ERROR }, 409);
      }
    }

    let resolved;
    if (withOptions && decision === 'approved') {
      const result = resolveSelection(existing.snapshot, selection);
      if (result.error) return c.json({ error: SELECTION_ERRORS[result.error] }, 400);
      resolved = result.selection;
    }

    const merged = nextApproval(existing, { decision, signerName, declineReason, selection: resolved }, meta);
    if (merged === existing) return ok(c, merged); // approved lock — nothing to write

    let updated;
    try {
      updated = await updateJobIfUnchanged(c.env, jobId, row.user_id, row.updated_at, { ...row.data, approval: merged });
    } catch (err) {
      console.error('[estimate/respond] update failed:', err.message);
      return c.json({ error: 'Database error' }, 500);
    }
    if (updated) return ok(c, merged);
    // Version moved between read and write: re-read and re-validate.
  }

  return c.json({ error: 'Please try again in a moment.' }, 409);
}

function ok(c, approval) {
  const out = { ok: true, decision: approval.decision, consentAt: approval.consentAt };
  if (approval.decision === 'approved' && approval.selection) out.selection = approval.selection;
  return c.json(out, 200);
}
