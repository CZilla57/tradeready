// GET /api/estimate/change-view?j=<jobId>&co=<changeOrderId>&t=<token> —
// Workers port of backend/lib/estimate/changeView.js.
// Sanitized, token-gated read for the change-order viewer. Returns ONLY this
// CO's frozen snapshot + decided state + LIVE context totals (original/new).

import { fetchJob, constantTimeEqual } from '../../../lib/estimateStore.js';
import { billableContext } from '../../../lib/estimate/changeOrderMath.js';
import { createRateLimiter } from '../../../lib/guards.js';
import { applyCors } from '../../../lib/estimate/cors.js';
import { clientIp } from '../../appCors.js';

const allow = createRateLimiter({ limit: 30 });

export async function changeViewHandler(c) {
  applyCors(c, 'GET, OPTIONS');
  if (c.req.method === 'OPTIONS') return c.body(null, 200);
  if (c.req.method !== 'GET') return c.json({ error: 'Method not allowed' }, 405);

  const ip = clientIp(c);
  if (!allow(ip)) return c.json({ error: 'Too many requests.' }, 429);

  const jobId = c.req.query('j');
  const coId = c.req.query('co');
  const token = c.req.query('t');
  if (!jobId || !coId || !token) return c.json({ error: 'Missing link parameters.' }, 400);

  let row;
  try {
    row = await fetchJob(c.env, String(jobId));
  } catch (err) {
    console.error('[estimate/change-view] fetch failed:', err.message);
    return c.json({ error: 'Database error' }, 500);
  }
  const cos = (row && row.data && Array.isArray(row.data.changeOrders)) ? row.data.changeOrders : [];
  const co = cos.find((x) => x && x.id === String(coId));
  const a = co && co.approval;
  if (!row || !co || !a || !constantTimeEqual(a.token, String(token))) {
    return c.json({ error: 'This link is invalid or has expired.' }, 404);
  }

  // A manual on-site decision also counts as decided for the viewer.
  const decision = a.decision || (co.manualDecision && co.manualDecision.decision) || null;

  return c.json({
    ...a.snapshot,
    description: co.description || null,
    decision,
    consentAt: a.consentAt || null,
    signerName: a.signerName || null,
    signatureRequired: true,
    context: billableContext(row.data, String(coId)),
  }, 200);
}
