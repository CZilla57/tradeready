// POST /api/estimate/respond — Workers port of backend/lib/estimate/respond.js.
// The customer's Approve/Decline. Token-gated (no user auth — the token is the
// capability). Stamps consentAt SERVER-SIDE and merges only approval.* into the
// job blob (service role). The device performs the status transition on pull.

import { fetchJob, upsertJob, constantTimeEqual } from '../../../lib/estimateStore.js';
import { createRateLimiter } from '../../../lib/guards.js';
import { applyCors } from '../../../lib/estimate/cors.js';
import { clientIp, jsonBody } from '../../appCors.js';

const allow = createRateLimiter({ limit: 10 });

// Pure decision merge — exported for reuse (change-respond). Returns the SAME
// reference when locked (already approved) so callers can skip a needless DB
// write.
export function nextApproval(existing, body, meta) {
  if (existing && existing.decision === 'approved') return existing; // terminal lock
  const decision = body.decision === 'approved' ? 'approved' : 'declined';
  return {
    ...existing,
    decision,
    consentAt: meta.consentAt,
    signerName: decision === 'approved' ? String(body.signerName || '').slice(0, 200) : (existing && existing.signerName),
    declineReason: decision === 'declined' ? String(body.declineReason || '').slice(0, 500) || undefined : undefined,
    ip: meta.ip,
    userAgent: meta.userAgent,
  };
}

export async function estimateRespondHandler(c) {
  applyCors(c, 'POST, OPTIONS');
  if (c.req.method === 'OPTIONS') return c.body(null, 200);
  if (c.req.method !== 'POST') return c.json({ error: 'Method not allowed' }, 405);

  const ip = clientIp(c);
  if (!allow(ip)) return c.json({ error: 'Too many requests.' }, 429);

  const { jobId, token, decision, signerName, declineReason } = (await jsonBody(c)) || {};
  if (!jobId || !token) return c.json({ error: 'Missing link parameters.' }, 400);
  if (decision !== 'approved' && decision !== 'declined') return c.json({ error: 'Invalid decision.' }, 400);
  if (decision === 'approved' && !String(signerName || '').trim()) {
    return c.json({ error: 'Please type your name to approve.' }, 400);
  }

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

  const merged = nextApproval(existing, { decision, signerName, declineReason }, {
    consentAt: new Date().toISOString(),
    ip,
    userAgent: String(c.req.header('user-agent') || '').slice(0, 300),
  });

  if (merged !== existing) {
    try {
      await upsertJob(c.env, jobId, row.user_id, { ...row.data, approval: merged });
    } catch (err) {
      console.error('[estimate/respond] upsert failed:', err.message);
      return c.json({ error: 'Database error' }, 500);
    }
  }

  return c.json({ ok: true, decision: merged.decision, consentAt: merged.consentAt }, 200);
}
