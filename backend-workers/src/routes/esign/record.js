// POST /api/esign/record — the owner app's signed copy and audit trail
// (Phase 19 spec §3.5, §3.7). JWT-authed with appCors, like create-link.
// Body {jobId, changeOrderId?, recordId?}; every lookup is scoped by the
// caller's user_id. Returns the sealed record, the live event log for that
// link and the signed PDF (base64). Contract: spec §11.1 C.
//
// Reads only Worker-held evidence: the sealed record, else the
// signature_pending row (sealed now). The owner's job blob is never read —
// the owner can write it, so an approval there with no Worker evidence is
// "not found", never sealed (spec §11.10).

import { Buffer } from 'node:buffer';
import { createRateLimiter } from '../../../lib/guards.js';
import { appCors, jsonBody } from '../../appCors.js';
import { isoAt, isRecordId } from '../../../lib/esign/record.js';
import { listEvents } from '../../../lib/esign/store.js';
import { ensureRecord, sealOf, signedPdfOf } from '../../../lib/esign/service.js';
import { signedPdfFilename } from '../../../lib/esign/pdf.js';

const allow = createRateLimiter({ limit: 30 });
const MAX_ID_CHARS = 200;

const NOT_FOUND = { error: 'No signed record was found for this job.', code: 'record_not_found' };
const PENDING = { error: 'The signed record is still being prepared. Please try again shortly.', code: 'record_pending' };

function badId(v) {
  return typeof v !== 'string' || v.length === 0 || v.length > MAX_ID_CHARS;
}

export async function esignRecordHandler(c) {
  appCors(c, 'POST, OPTIONS');
  if (c.req.method === 'OPTIONS') return c.body(null, 200);
  if (c.req.method !== 'POST') return c.json({ error: 'Method not allowed' }, 405);

  const { SUPABASE_URL, SUPABASE_ANON_KEY, SUPABASE_SERVICE_ROLE_KEY } = c.env;
  if (!SUPABASE_URL || !SUPABASE_ANON_KEY || !SUPABASE_SERVICE_ROLE_KEY) {
    return c.json({ error: 'Server misconfiguration.', code: 'server_error' }, 500);
  }
  const auth = c.req.header('authorization');
  if (!auth || !auth.startsWith('Bearer ')) return c.json({ error: 'Unauthorized', code: 'unauthorized' }, 401);
  let userId;
  try {
    const userRes = await fetch(`${SUPABASE_URL}/auth/v1/user`, {
      headers: { Authorization: auth, apikey: SUPABASE_ANON_KEY },
    });
    if (!userRes.ok) return c.json({ error: 'Invalid or expired session.', code: 'unauthorized' }, 401);
    userId = (await userRes.json())?.id;
  } catch (err) {
    console.error('[esign/record] auth failed:', err.message);
    return c.json({ error: 'Database error', code: 'server_error' }, 500);
  }
  if (!userId) return c.json({ error: 'Unauthorized', code: 'unauthorized' }, 401);
  if (!allow(userId)) return c.json({ error: 'Too many requests. Please wait a moment.', code: 'rate_limited' }, 429);

  const body = (await jsonBody(c)) || {};
  const { jobId } = body;
  const changeOrderId = body.changeOrderId == null ? null : body.changeOrderId;
  const recordId = body.recordId == null ? null : body.recordId;
  if (badId(jobId)) return c.json({ error: 'jobId is required', code: 'invalid_request' }, 400);
  if (changeOrderId !== null && badId(changeOrderId)) {
    return c.json({ error: 'changeOrderId must be a string', code: 'invalid_request' }, 400);
  }
  if (recordId !== null && !isRecordId(recordId)) {
    return c.json({ error: 'recordId must be a record id', code: 'invalid_request' }, 400);
  }

  let ensured;
  try {
    ensured = await ensureRecord(c.env, { userId, jobId, changeOrderId, recordId });
  } catch (err) {
    console.error('[esign/record] record fetch failed:', err.message);
    return c.json({ error: 'Database error', code: 'server_error' }, 500);
  }
  if (!ensured) return c.json(NOT_FOUND, 404);
  if (!ensured.row) return c.json(PENDING, 503);
  const row = ensured.row;

  let events = [];
  try {
    events = (await listEvents(c.env, {
      userId, jobId: row.job_id, changeOrderId: row.change_order_id || null, tokenHash: row.approval_token_sha256,
    }))
      .map((e) => ({ type: e.event, at: isoAt(e.created_at), ip: e.ip || null }));
  } catch (err) {
    console.error('[esign/record] events fetch failed:', err.message);
  }

  return c.json({
    recordId: row.id,
    recordDigest: row.record_digest,
    documentType: row.document_type,
    jobId: row.job_id,
    changeOrderId: row.change_order_id || null,
    signedAt: row.record.signedAt,
    signatureMethod: row.record.signatureMethod,
    seal: sealOf(row),
    record: row.record,
    events,
    pdf: {
      filename: signedPdfFilename(row.record),
      contentType: 'application/pdf',
      base64: Buffer.from(signedPdfOf(row)).toString('base64'),
    },
  }, 200);
}
