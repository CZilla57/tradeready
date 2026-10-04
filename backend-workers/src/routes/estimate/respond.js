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
//
// Phase 32 (quote expiration): approving after the snapshot's valid-until
// date (owner's zone, §2.4) is refused with 410 `estimate_expired` and a
// self-contained message. Declining stays allowed; the approved lock wins.
//
// Phase 19 (e-signatures, spec 2026-10-03-esignature-upgrade-design.md §3.5):
// with ESIGN_V2 on and a snapshot that carries `esign` (or
// ESIGN_REQUIRE_CONSENT on), an approval is a signature: the consent, typed
// name, optional drawing and optional copy email are validated, the edge IP
// is recorded, and the decision is written FIRST together with the
// server-owned keys signatureRecordId / recordDigest / signatureMethod /
// signatureEvidence. The sealed record is inserted after; a failure there
// keeps the Worker-built record in signature_pending and still answers 200
// with `recordPending: true` (lazy seal of that row on view/copy; never from
// the job blob, spec §11.10).
// Flags off → byte-for-byte the previous behavior.

import { fetchJob, updateJobIfUnchanged, constantTimeEqual } from '../../../lib/estimateStore.js';
import { createRateLimiter } from '../../../lib/guards.js';
import { applyCors } from '../../../lib/estimate/cors.js';
import {
  hasSnapshotOptions,
  isResolvedSelection,
  resolveSelection,
  snapshotDigest,
} from '../../../lib/estimate/quoteOptions.js';
import { expiredMessage, snapshotExpiry } from '../../../lib/estimate/estimateExpiry.js';
import { clientIp, jsonBody } from '../../appCors.js';
import { esignV2, esignActive, esignRequireConsent } from '../../../lib/esign/flags.js';
import { edgeClientIp } from '../../../lib/esign/ip.js';
import { fail, parseSignatureFields, validateTypedName } from '../../../lib/esign/validate.js';
import { signApproval, tokenSha256 } from '../../../lib/esign/record.js';
import { eventsAtSigning, finishSigning } from '../../../lib/esign/service.js';
import { logEvent } from '../../../lib/esign/store.js';

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

  // One clock read per request: consentAt and the expiry check agree, and
  // tests stub Date.now.
  const nowMs = Date.now();
  const ip = clientIp(c);
  if (!allow(ip)) return c.json({ error: 'Too many requests.' }, 429);

  const body = (await jsonBody(c)) || {};
  const { jobId, token, decision, signerName, declineReason, selection, snapshotDigest: sentDigest } = body;
  if (!jobId || !token) return c.json({ error: 'Missing link parameters.' }, 400);
  if (decision !== 'approved' && decision !== 'declined') return c.json({ error: 'Invalid decision.' }, 400);
  if (decision === 'approved' && !String(signerName || '').trim()) {
    return c.json({ error: 'Please type your name to approve.' }, 400);
  }

  // Phase 19 §3.5 step 1: the optional e-signature fields are shape-checked
  // before any DB contact. Whether they are REQUIRED depends on the snapshot.
  let sig = null;
  if (esignV2(c.env) && decision === 'approved') {
    const parsed = parseSignatureFields(body);
    if (parsed.error) return c.json({ error: parsed.error, code: parsed.code }, 400);
    sig = parsed.value;
  }
  const edgeIp = edgeClientIp(c);
  // Pre-minted once per request so a retried conditional write keeps it.
  const recordId = crypto.randomUUID();
  let trail = null;

  const meta = {
    consentAt: new Date(nowMs).toISOString(),
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

    // An approval through the e-signature path (not the approved lock).
    const signing = decision === 'approved' && existing.decision !== 'approved'
      && esignActive(c.env, existing.snapshot);
    let typedName = signerName;
    if (signing) {
      const name = validateTypedName(signerName);
      if (name.error) return c.json({ error: name.error, code: name.code }, 400);
      typedName = name.value;
      // An old cached page sends no consent: refused once consent is required.
      if (!sig.consent && esignRequireConsent(c.env)) {
        const e = fail('reload_required');
        return c.json({ error: e.error, code: e.code }, 400);
      }
    }

    // Option estimates must prove the page showed THIS snapshot; legacy
    // estimates are only checked when the page sent a digest. A consenting
    // signature always is, so the sealed document is the one on screen.
    const withOptions = hasSnapshotOptions(existing.snapshot);
    if (withOptions || sentDigest != null || (signing && sig.consent)) {
      if (sentDigest !== snapshotDigest(existing.snapshot)) {
        return c.json({ error: STALE_SNAPSHOT_ERROR }, 409);
      }
    }

    // After the digest (a stale page reloads first, then sees the expired
    // view) and before selection (an expired option estimate is 410, not
    // "Please choose an option."). An approved estimate keeps its lock.
    if (decision === 'approved' && existing.decision !== 'approved') {
      const { validUntil, expired } = snapshotExpiry(existing.snapshot, nowMs);
      if (expired) {
        return c.json({ error: expiredMessage(existing.snapshot, validUntil), code: 'estimate_expired', validUntil }, 410);
      }
    }

    let resolved;
    if (withOptions && decision === 'approved') {
      const result = resolveSelection(existing.snapshot, selection);
      if (result.error) return c.json({ error: SELECTION_ERRORS[result.error] }, 400);
      resolved = result.selection;
    }

    // Signature evidence records the edge address only (D9), never XFF.
    let merged = nextApproval(
      existing,
      { decision, signerName: typedName, declineReason, selection: resolved },
      signing ? { ...meta, ip: edgeIp } : meta
    );
    if (merged === existing) return ok(c, merged); // approved lock — nothing to write

    let signed = null;
    if (signing) {
      // This link's trail only (owner + job + token hash), so a token reused
      // from another job never imports that job's views.
      if (trail === null) {
        trail = await eventsAtSigning(c.env, {
          userId: row.user_id, jobId: String(jobId), changeOrderId: null, tokenHash: tokenSha256(existing.token),
        });
      }
      signed = signApproval(merged, {
        recordId,
        consent: sig.consent,
        drawn: sig.drawn,
        email: sig.email,
        events: trail,
        jobId: String(jobId),
        documentType: 'estimate',
      });
      merged = signed.approval;
    }

    let updated;
    try {
      updated = await updateJobIfUnchanged(c.env, jobId, row.user_id, row.updated_at, { ...row.data, approval: merged });
    } catch (err) {
      console.error('[estimate/respond] update failed:', err.message);
      return c.json({ error: 'Database error' }, 500);
    }
    if (updated) {
      // The decision is recorded; evidence follows (never fails the response).
      if (signed) {
        const { recordPending } = await finishSigning(c, {
          userId: row.user_id, record: signed.record, digest: signed.digest,
          email: sig.email, ip: edgeIp, userAgent: meta.userAgent,
        });
        return ok(c, merged, { recordPending });
      }
      if (decision === 'declined' && esignActive(c.env, existing.snapshot)) {
        await logEvent(c.env, {
          userId: row.user_id, jobId: String(jobId), changeOrderId: null, tokenHash: tokenSha256(existing.token),
          event: 'declined', ip: edgeIp, userAgent: meta.userAgent,
        });
      }
      return ok(c, merged);
    }
    // Version moved between read and write: re-read and re-validate.
  }

  return c.json({ error: 'Please try again in a moment.' }, 409);
}

function ok(c, approval, { recordPending = false } = {}) {
  const out = { ok: true, decision: approval.decision, consentAt: approval.consentAt };
  if (approval.decision === 'approved' && approval.selection) out.selection = approval.selection;
  // Phase 19: an e-signed approval (now, or already under the lock).
  if (approval.decision === 'approved' && approval.signatureRecordId) {
    out.recordId = approval.signatureRecordId;
    out.recordDigest = approval.recordDigest;
    out.signatureMethod = approval.signatureMethod;
    if (recordPending) out.recordPending = true;
  }
  return c.json(out, 200);
}
