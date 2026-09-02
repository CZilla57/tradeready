// POST /api/estimate/change-respond — Workers port of
// backend/lib/estimate/changeRespond.js.
// The customer's Approve/Decline for ONE change order. Token-gated; stamps
// consentAt SERVER-SIDE and merges only that CO's approval.* into the jobs
// blob (service role). Reuses respond.js's nextApproval merge (terminal lock
// on approved). Refuses 409 when the tradesperson already recorded an
// on-site manual decision — a stale link can't override it.

import { fetchJobVersioned, updateJobConditionally, constantTimeEqual } from '../../../lib/estimateStore.js';
import { nextApproval } from './respond.js';
import { createRateLimiter } from '../../../lib/guards.js';
import { applyCors } from '../../../lib/estimate/cors.js';
import { clientIp, jsonBody } from '../../appCors.js';

const allow = createRateLimiter({ limit: 10 });

export async function changeRespondHandler(c) {
  applyCors(c, 'POST, OPTIONS');
  if (c.req.method === 'OPTIONS') return c.body(null, 200);
  if (c.req.method !== 'POST') return c.json({ error: 'Method not allowed' }, 405);

  const ip = clientIp(c);
  if (!allow(ip)) return c.json({ error: 'Too many requests.' }, 429);

  const { jobId, changeOrderId, token, decision, signerName, declineReason } = (await jsonBody(c)) || {};
  if (!jobId || !changeOrderId || !token) return c.json({ error: 'Missing link parameters.' }, 400);
  if (decision !== 'approved' && decision !== 'declined') return c.json({ error: 'Invalid decision.' }, 400);
  if (decision === 'approved' && !String(signerName || '').trim()) {
    return c.json({ error: 'Please type your name to approve.' }, 400);
  }

  const id = String(changeOrderId);
  const meta = {
    consentAt: new Date().toISOString(),
    ip,
    userAgent: String(c.req.header('user-agent') || '').slice(0, 300),
  };

  // Concurrency-safe per-change decision. The merge is re-evaluated against the
  // freshest version on every attempt, so an on-site manual decision or a
  // concurrent owner edit that lands between our read and write is respected —
  // the customer's response is never written over a terminal outcome.
  let result;
  try {
    result = await updateJobConditionally(
      c.env,
      String(jobId),
      () => fetchJobVersioned(c.env, String(jobId)),
      (row) => {
        const cos = Array.isArray(row.data && row.data.changeOrders) ? row.data.changeOrders : [];
        const idx = cos.findIndex((x) => x && x.id === id);
        const co = idx === -1 ? null : cos[idx];
        const existing = co && co.approval;
        if (!co || !existing || !constantTimeEqual(existing.token, String(token))) {
          return { conflict: true, reason: 'invalid' };
        }
        // Declined is FINAL for change orders (owner decision 2026-08-05) —
        // unlike the estimate flow, a declined CO cannot be flipped to approved
        // from a stale link; the tradesperson issues a new CO instead.
        // nextApproval's declined→approved allowance therefore never fires here.
        if (co.manualDecision || existing.decision === 'declined') {
          return { conflict: true, reason: 'decided' };
        }
        const merged = nextApproval(existing, { decision, signerName, declineReason }, meta);
        if (merged === existing) return { skip: true }; // terminal approved lock
        const next = cos.slice();
        next[idx] = { ...co, approval: merged };
        return { data: { ...row.data, changeOrders: next } };
      }
    );
  } catch (err) {
    console.error('[estimate/change-respond] write failed:', err.message);
    return c.json({ error: 'Database error' }, 500);
  }

  if (result.notFound || (result.conflict && result.reason === 'invalid')) {
    return c.json({ error: 'This link is invalid or has expired.' }, 404);
  }
  if (result.conflict && result.reason === 'decided') {
    return c.json({ error: 'This change was already decided.' }, 409);
  }
  if (result.conflict) {
    return c.json({ error: 'This estimate changed. Please reload and try again.' }, 409);
  }

  const co = result.row.data.changeOrders.find((x) => x && x.id === id);
  return c.json({ ok: true, decision: co.approval.decision, consentAt: co.approval.consentAt }, 200);
}
