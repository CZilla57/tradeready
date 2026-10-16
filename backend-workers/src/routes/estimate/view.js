// GET /api/estimate/view?j=<jobId>&t=<token> — Workers port of
// backend/lib/estimate/view.js.
// Sanitized, token-gated read for the public viewer. Returns ONLY this estimate's
// frozen snapshot + decision state — never other jobs or extra PII.
// Phase 19 adds `esign` (signing texts) and `signed` (the signed view: name,
// drawing, record id and fingerprint — no email or IP), and logs `viewed`.

import { fetchJob, constantTimeEqual } from '../../../lib/estimateStore.js';
import { createRateLimiter } from '../../../lib/guards.js';
import { applyCors } from '../../../lib/estimate/cors.js';
import { snapshotDigest } from '../../../lib/estimate/quoteOptions.js';
import { snapshotExpiry } from '../../../lib/estimate/estimateExpiry.js';
import { clientIp } from '../../appCors.js';
import { esignActive } from '../../../lib/esign/flags.js';
import { edgeClientIp } from '../../../lib/esign/ip.js';
import { signingTexts } from '../../../lib/esign/texts.js';
import { tokenSha256 } from '../../../lib/esign/record.js';
import { afterResponse, logViewCapped, signedViewForLink } from '../../../lib/esign/service.js';

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

  // Phase 19. `esign` in the response is the server-rendered signing text
  // (never the snapshot's own {version} marker, which the spread copied):
  // present only while this estimate signs through the e-signature path.
  delete body.esign;
  const active = esignActive(c.env, a.snapshot);
  if (active && a.decision !== 'approved') body.esign = signingTexts(a.snapshot, 'estimate');
  // The signed view (any e-signed approval, flag on or off, so a rollback
  // keeps copies reachable), from the Worker-held record or pending
  // signature of this link — never from the blob, which the owner can write
  // (spec §11.10). Lazily seals a pending signature.
  const link = { userId: row.user_id, jobId: String(jobId), changeOrderId: null, tokenHash: tokenSha256(a.token) };
  const signed = await signedViewForLink(c.env, a, link);
  if (signed) body.signed = signed;
  if (active) {
    afterResponse(c, logViewCapped(c.env, {
      ...link,
      ip: edgeClientIp(c),
      userAgent: String(c.req.header('user-agent') || '').slice(0, 300),
    }));
  }
  return c.json(body, 200);
}
