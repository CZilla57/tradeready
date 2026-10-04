// GET /api/estimate/change-view?j=<jobId>&co=<changeOrderId>&t=<token> —
// Workers port of backend/lib/estimate/changeView.js.
// Sanitized, token-gated read for the change-order viewer. Returns ONLY this
// CO's frozen snapshot + decided state + LIVE context totals (original/new).

import { fetchJob, constantTimeEqual } from '../../../lib/estimateStore.js';
import { billableContext } from '../../../lib/estimate/changeOrderMath.js';
import { createRateLimiter } from '../../../lib/guards.js';
import { applyCors } from '../../../lib/estimate/cors.js';
import { clientIp } from '../../appCors.js';
import { snapshotDigest } from '../../../lib/estimate/quoteOptions.js';
import { esignV2, esignActive } from '../../../lib/esign/flags.js';
import { edgeClientIp } from '../../../lib/esign/ip.js';
import { signingTexts } from '../../../lib/esign/texts.js';
import { tokenSha256 } from '../../../lib/esign/record.js';
import { afterResponse, ensureRecord, logViewCapped, signedViewOf } from '../../../lib/esign/service.js';

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

  const body = {
    ...a.snapshot,
    description: co.description || null,
    decision,
    consentAt: a.consentAt || null,
    signerName: a.signerName || null,
    signatureRequired: true,
    context: billableContext(row.data, String(coId)),
  };

  // Phase 19 (same contract as view.js): server-rendered signing texts while
  // this change order signs through the e-signature path, the snapshot
  // digest the signing page echoes, and the signed view.
  delete body.esign;
  if (esignV2(c.env)) body.snapshotDigest = snapshotDigest(a.snapshot);
  const active = esignActive(c.env, a.snapshot);
  if (active && !decision) body.esign = signingTexts(a.snapshot, 'change_order');
  const signed = a.decision === 'approved'
    ? signedViewOf(a, await ensureRecord(c.env, {
      userId: row.user_id, jobId: String(jobId), changeOrderId: String(coId), documentType: 'change_order', approval: a,
    }))
    : null;
  if (signed) body.signed = signed;
  if (active) {
    afterResponse(c, logViewCapped(c.env, {
      userId: row.user_id,
      tokenHash: tokenSha256(a.token),
      ip: edgeClientIp(c),
      userAgent: String(c.req.header('user-agent') || '').slice(0, 300),
    }));
  }
  return c.json(body, 200);
}
