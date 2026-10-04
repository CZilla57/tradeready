// POST /api/estimate/change-respond — Workers port of
// backend/lib/estimate/changeRespond.js.
// The customer's Approve/Decline for ONE change order. Token-gated; stamps
// consentAt SERVER-SIDE and merges only that CO's approval.* into the jobs
// blob (service role). Reuses respond.js's nextApproval merge (terminal lock
// on approved). Refuses 409 when the tradesperson already recorded an
// on-site manual decision — a stale link can't override it.
//
// Phase 19 (e-signatures, spec §3.5): the same signature path as respond.js,
// with documentType "change_order". An e-signed approval is written with the
// conditional write (updateJobIfUnchanged, re-read on conflict) so two
// concurrent approvals can never seal two different records for one link;
// the legacy path keeps its unconditional upsert. Flags off → unchanged.

import { fetchJob, upsertJob, updateJobIfUnchanged, constantTimeEqual } from '../../../lib/estimateStore.js';
import { nextApproval, RESPOND_WRITE_ATTEMPTS } from './respond.js';
import { createRateLimiter } from '../../../lib/guards.js';
import { applyCors } from '../../../lib/estimate/cors.js';
import { snapshotDigest } from '../../../lib/estimate/quoteOptions.js';
import { clientIp, jsonBody } from '../../appCors.js';
import { esignV2, esignActive, esignRequireConsent } from '../../../lib/esign/flags.js';
import { edgeClientIp } from '../../../lib/esign/ip.js';
import { fail, parseSignatureFields, validateTypedName } from '../../../lib/esign/validate.js';
import { signApproval, tokenSha256 } from '../../../lib/esign/record.js';
import { eventsAtSigning, finishSigning } from '../../../lib/esign/service.js';
import { logEvent } from '../../../lib/esign/store.js';

const allow = createRateLimiter({ limit: 10 });

const STALE_SNAPSHOT_ERROR = 'This change order was just updated. Please reload the page to see the latest version.';

export async function changeRespondHandler(c) {
  applyCors(c, 'POST, OPTIONS');
  if (c.req.method === 'OPTIONS') return c.body(null, 200);
  if (c.req.method !== 'POST') return c.json({ error: 'Method not allowed' }, 405);

  const ip = clientIp(c);
  if (!allow(ip)) return c.json({ error: 'Too many requests.' }, 429);

  const body = (await jsonBody(c)) || {};
  const { jobId, changeOrderId, token, decision, signerName, declineReason, snapshotDigest: sentDigest } = body;
  if (!jobId || !changeOrderId || !token) return c.json({ error: 'Missing link parameters.' }, 400);
  if (decision !== 'approved' && decision !== 'declined') return c.json({ error: 'Invalid decision.' }, 400);
  if (decision === 'approved' && !String(signerName || '').trim()) {
    return c.json({ error: 'Please type your name to approve.' }, 400);
  }

  // Phase 19: optional e-signature fields, shape-checked before any DB contact.
  const v2 = esignV2(c.env);
  let sig = null;
  if (v2 && decision === 'approved') {
    const parsed = parseSignatureFields(body);
    if (parsed.error) return c.json({ error: parsed.error, code: parsed.code }, 400);
    sig = parsed.value;
  }
  const edgeIp = edgeClientIp(c);
  const recordId = crypto.randomUUID();
  const userAgent = String(c.req.header('user-agent') || '').slice(0, 300);
  let trail = null;

  for (let attempt = 0; attempt < RESPOND_WRITE_ATTEMPTS; attempt += 1) {
    let row;
    try {
      row = await fetchJob(c.env, String(jobId));
    } catch (err) {
      console.error('[estimate/change-respond] fetch failed:', err.message);
      return c.json({ error: 'Database error' }, 500);
    }
    const cos = (row && row.data && Array.isArray(row.data.changeOrders)) ? row.data.changeOrders : [];
    const idx = cos.findIndex((x) => x && x.id === String(changeOrderId));
    const co = idx === -1 ? null : cos[idx];
    const existing = co && co.approval;
    if (!row || !co || !existing || !constantTimeEqual(existing.token, String(token))) {
      return c.json({ error: 'This link is invalid or has expired.' }, 404);
    }
    // Declined is FINAL for change orders (owner decision 2026-08-05) — unlike
    // the estimate flow, a declined CO cannot be flipped to approved from a
    // stale link; the tradesperson issues a new CO instead. nextApproval's
    // declined→approved allowance therefore never fires here.
    if (co.manualDecision || existing.decision === 'declined') {
      return c.json({ error: 'This change was already decided.' }, 409);
    }

    const signing = decision === 'approved' && existing.decision !== 'approved'
      && esignActive(c.env, existing.snapshot);
    let typedName = signerName;
    if (signing) {
      const name = validateTypedName(signerName);
      if (name.error) return c.json({ error: name.error, code: name.code }, 400);
      typedName = name.value;
      if (!sig.consent && esignRequireConsent(c.env)) {
        const e = fail('reload_required');
        return c.json({ error: e.error, code: e.code }, 400);
      }
    }
    // The page that signs proves it showed THIS snapshot (a re-send under the
    // same token can replace it until approved).
    if (v2 && (sentDigest != null || (signing && sig.consent))
      && sentDigest !== snapshotDigest(existing.snapshot)) {
      return c.json({ error: STALE_SNAPSHOT_ERROR }, 409);
    }

    let merged = nextApproval(existing, { decision, signerName: typedName, declineReason }, {
      consentAt: new Date().toISOString(),
      ip: signing ? edgeIp : ip,
      userAgent,
    });
    if (merged === existing) return ok(c, merged); // approved lock — nothing to write

    let signed = null;
    if (signing) {
      if (trail === null) trail = await eventsAtSigning(c.env, tokenSha256(existing.token));
      signed = signApproval(merged, {
        recordId,
        consent: sig.consent,
        drawn: sig.drawn,
        email: sig.email,
        events: trail,
        jobId: String(jobId),
        changeOrderId: String(changeOrderId),
        documentType: 'change_order',
      });
      merged = signed.approval;
    }
    const next = cos.slice();
    next[idx] = { ...co, approval: merged };

    if (!signed) {
      try {
        await upsertJob(c.env, String(jobId), row.user_id, { ...row.data, changeOrders: next });
      } catch (err) {
        console.error('[estimate/change-respond] upsert failed:', err.message);
        return c.json({ error: 'Database error' }, 500);
      }
      if (decision === 'declined' && esignActive(c.env, existing.snapshot)) {
        await logEvent(c.env, {
          userId: row.user_id, tokenHash: tokenSha256(existing.token), event: 'declined', ip: edgeIp, userAgent,
        });
      }
      return ok(c, merged);
    }

    let updated;
    try {
      updated = await updateJobIfUnchanged(c.env, String(jobId), row.user_id, row.updated_at, { ...row.data, changeOrders: next });
    } catch (err) {
      console.error('[estimate/change-respond] update failed:', err.message);
      return c.json({ error: 'Database error' }, 500);
    }
    if (updated) {
      const { recordPending } = await finishSigning(c, {
        userId: row.user_id, record: signed.record, digest: signed.digest, email: sig.email, ip: edgeIp, userAgent,
      });
      return ok(c, merged, { recordPending });
    }
    // Version moved between read and write: re-read and re-validate.
  }

  return c.json({ error: 'Please try again in a moment.' }, 409);
}

function ok(c, approval, { recordPending = false } = {}) {
  const out = { ok: true, decision: approval.decision, consentAt: approval.consentAt };
  if (approval.decision === 'approved' && approval.signatureRecordId) {
    out.recordId = approval.signatureRecordId;
    out.recordDigest = approval.recordDigest;
    out.signatureMethod = approval.signatureMethod;
    if (recordPending) out.recordPending = true;
  }
  return c.json(out, 200);
}
