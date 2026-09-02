// POST /api/estimate/respond — Workers port of backend/lib/estimate/respond.js.
// The customer's Approve/Decline. Token-gated (no user auth — the token is the
// capability). Stamps consentAt SERVER-SIDE and merges only approval.* into the
// job blob (service role). The device performs the status transition on pull.

import { fetchJobVersioned, updateJobConditionally, constantTimeEqual } from '../../../lib/estimateStore.js';
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

  const meta = {
    consentAt: new Date().toISOString(),
    ip,
    userAgent: String(c.req.header('user-agent') || '').slice(0, 300),
  };

  // Concurrency-safe merge (ESTIMATE_WORKFLOW_ROADMAP.md, "Customer decision"):
  // the token must still match on the freshest version, and nextApproval's
  // terminal lock (already-approved) skips a needless write. A version conflict
  // refetches and re-checks the token before writing again, so an owner edit
  // landing between our read and write never loses the customer's response.
  let result;
  try {
    result = await updateJobConditionally(
      c.env,
      jobId,
      () => fetchJobVersioned(c.env, jobId),
      (row) => {
        const existing = row.data && row.data.approval;
        if (!existing || !constantTimeEqual(existing.token, String(token))) {
          return { conflict: true, reason: 'invalid' };
        }
        const merged = nextApproval(existing, { decision, signerName, declineReason }, meta);
        if (merged === existing) return { skip: true }; // terminal lock — no write
        return { data: { ...row.data, approval: merged } };
      }
    );
  } catch (err) {
    console.error('[estimate/respond] write failed:', err.message);
    return c.json({ error: 'Database error' }, 500);
  }

  if (result.notFound || (result.conflict && result.reason === 'invalid')) {
    return c.json({ error: 'This link is invalid or has expired.' }, 404);
  }
  if (result.conflict) {
    return c.json({ error: 'This estimate changed. Please reload and try again.' }, 409);
  }

  const approval = result.row.data.approval;
  return c.json({ ok: true, decision: approval.decision, consentAt: approval.consentAt }, 200);
}
