// POST /api/estimate/change-respond — Workers port of
// backend/lib/estimate/changeRespond.js.
// The customer's Approve/Decline for ONE change order. Token-gated; stamps
// consentAt SERVER-SIDE and merges only that CO's approval.* into the jobs
// blob (service role). Reuses respond.js's nextApproval merge (terminal lock
// on approved). Refuses 409 when the tradesperson already recorded an
// on-site manual decision — a stale link can't override it.

import { fetchJob, upsertJob, constantTimeEqual } from '../../../lib/estimateStore.js';
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

  const merged = nextApproval(existing, { decision, signerName, declineReason }, {
    consentAt: new Date().toISOString(),
    ip,
    userAgent: String(c.req.header('user-agent') || '').slice(0, 300),
  });

  if (merged !== existing) {
    const next = cos.slice();
    next[idx] = { ...co, approval: merged };
    try {
      await upsertJob(c.env, String(jobId), row.user_id, { ...row.data, changeOrders: next });
    } catch (err) {
      console.error('[estimate/change-respond] upsert failed:', err.message);
      return c.json({ error: 'Database error' }, 500);
    }
  }

  return c.json({ ok: true, decision: merged.decision, consentAt: merged.consentAt }, 200);
}
