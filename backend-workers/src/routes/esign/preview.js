// GET /api/esign/preview?j=<jobId>&t=<token>[&c=<changeOrderId>]
// The unsigned PDF of the current snapshot (Phase 19 spec §3.1), linked from
// the disclosure so a signer can check that the PDF form opens on their
// device before agreeing. Token-gated, same CORS as the estimate routes.
// Behind ESIGN_V2 (404 while off). Deterministic bytes, nothing stored.

import { fetchJob } from '../../../lib/estimateStore.js';
import { createRateLimiter } from '../../../lib/guards.js';
import { applyCors } from '../../../lib/estimate/cors.js';
import { snapshotDigest } from '../../../lib/estimate/quoteOptions.js';
import { clientIp } from '../../appCors.js';
import { esignV2 } from '../../../lib/esign/flags.js';
import { approvalForLink } from '../../../lib/esign/service.js';
import { renderPreviewPdf, previewPdfFilename } from '../../../lib/esign/pdf.js';

const allow = createRateLimiter({ limit: 10 });

export async function esignPreviewHandler(c) {
  applyCors(c, 'GET, OPTIONS');
  if (c.req.method === 'OPTIONS') return c.body(null, 200);
  if (c.req.method !== 'GET') return c.json({ error: 'Method not allowed' }, 405);
  if (!esignV2(c.env)) return c.json({ error: 'Not found' }, 404);
  if (!allow(clientIp(c))) return c.json({ error: 'Too many requests.', code: 'rate_limited' }, 429);

  const jobId = c.req.query('j');
  const token = c.req.query('t');
  const coId = c.req.query('c') || null;
  if (!jobId || !token) return c.json({ error: 'Missing link parameters.', code: 'invalid_request' }, 400);

  let job;
  try {
    job = await fetchJob(c.env, String(jobId));
  } catch (err) {
    console.error('[esign/preview] fetch failed:', err.message);
    return c.json({ error: 'Database error', code: 'server_error' }, 500);
  }
  const link = approvalForLink(job, { changeOrderId: coId, token: String(token) });
  if (!link) return c.json({ error: 'This link is invalid or has expired.', code: 'invalid_link' }, 404);

  const snapshot = link.approval.snapshot;
  const bytes = renderPreviewPdf({ snapshot, documentType: link.documentType, snapshotDigest: snapshotDigest(snapshot) });
  c.header('Cache-Control', 'no-store');
  c.header('Content-Type', 'application/pdf');
  c.header('Content-Disposition', `attachment; filename="${previewPdfFilename(link.documentType)}"`);
  return c.body(bytes, 200);
}
