// GET /api/estimate/view?j=<jobId>&t=<token> — Workers port of
// backend/lib/estimate/view.js.
// Sanitized, token-gated read for the public viewer. Returns ONLY this estimate's
// frozen snapshot + decision state — never other jobs or extra PII.

import { fetchJob, constantTimeEqual } from '../../../lib/estimateStore.js';
import { createRateLimiter } from '../../../lib/guards.js';
import { applyCors } from '../../../lib/estimate/cors.js';
import { snapshotDigest } from '../../../lib/estimate/quoteOptions.js';
import { snapshotExpiry } from '../../../lib/estimate/estimateExpiry.js';
import { clientIp } from '../../appCors.js';

const allow = createRateLimiter({ limit: 30 });

export async function estimateViewHandler(c) {
  applyCors(c, 'GET, OPTIONS');
  if (c.req.method === 'OPTIONS') return c.body(null, 200);
  if (c.req.method !== 'GET') return c.json({ error: 'Method not allowed' }, 405);

  const ip = clientIp(c);
  if (!allow(ip)) return c.json({ error: 'Too many requests.' }, 429);

  const jobId = c.req.query('j');
  const token = c.req.query('t');
  if (!jobId || !token) return c.json({ error: 'Missing link parameters.' }, 400);

  let row;
  try {
    row = await fetchJob(c.env, String(jobId));
  } catch (err) {
    console.error('[estimate/view] fetch failed:', err.message);
    return c.json({ error: 'Database error' }, 500);
  }
  const a = row && row.data && row.data.approval;
  if (!row || !a || !constantTimeEqual(a.token, String(token))) {
    return c.json({ error: 'This link is invalid or has expired.' }, 404);
  }

  const nowMs = Date.now();
  const body = {
    ...a.snapshot,
    decision: a.decision || null,
    consentAt: a.consentAt || null,
    signerName: a.signerName || null,
    signatureRequired: true,
    // Echoed back by the page on respond; option estimates require it so a
    // decision made on a superseded snapshot is refused (Phase 25 §4).
    snapshotDigest: snapshotDigest(a.snapshot),
    // Phase 32: past its valid-until date in the owner's zone, so respond
    // will refuse an approval (410). validUntil/validUntilTimeZone already
    // arrive through the snapshot spread. An approval is never "expired".
    expired: a.decision !== 'approved' && snapshotExpiry(a.snapshot, nowMs).expired,
  };
  // The customer's accepted good/better/best choice (server-written by
  // respond, under the approved lock).
  if (a.decision === 'approved' && a.selection) body.selection = a.selection;
  return c.json(body, 200);
}
