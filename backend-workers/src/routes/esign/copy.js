// GET /api/esign/copy?j=<jobId>&t=<token>[&c=<changeOrderId>]&format=pdf|json
// The signer's copy (Phase 19 spec §3.5, D7). Token-gated like the estimate
// routes, same CORS. Resolves through signature_records by the token's
// SHA-256, the job id and the change-order id, so a sealed copy keeps working
// after the job is edited or deleted. Only when nothing is sealed yet does it
// read the job (soft-deleted rows too) to learn which Worker-held
// signature_pending row the landed decision names, and seals that row; the
// bytes never come from the job, which the owner can write (spec §11.10,
// §11.11). Serves the deterministic PDF (default) or the sealed record
// envelope as JSON for independent verification, and logs `copy_downloaded`.

import { createRateLimiter } from '../../../lib/guards.js';
import { applyCors } from '../../../lib/estimate/cors.js';
import { clientIp } from '../../appCors.js';
import { tokenSha256 } from '../../../lib/esign/record.js';
import { edgeClientIp } from '../../../lib/esign/ip.js';
import { logEvent } from '../../../lib/esign/store.js';
import { ensureRecordForToken, envelopeOf, signedPdfOf } from '../../../lib/esign/service.js';
import { signedPdfFilename } from '../../../lib/esign/pdf.js';

const allow = createRateLimiter({ limit: 20 });

// One answer for "no such link", "not signed" and "wrong job": no oracle.
const NOT_SIGNED = { error: 'No signed copy is available for this link.', code: 'not_signed' };
const PENDING = { error: 'Your signed copy is still being prepared. Please try again in a few minutes.', code: 'record_pending' };

export async function esignCopyHandler(c) {
  applyCors(c, 'GET, OPTIONS');
  if (c.req.method === 'OPTIONS') return c.body(null, 200);
  if (c.req.method !== 'GET') return c.json({ error: 'Method not allowed' }, 405);
  if (!allow(clientIp(c))) return c.json({ error: 'Too many requests.', code: 'rate_limited' }, 429);

  const jobId = c.req.query('j');
  const token = c.req.query('t');
  const coId = c.req.query('c') || null;
  const format = c.req.query('format') || 'pdf';
  if (!jobId || !token) return c.json({ error: 'Missing link parameters.', code: 'invalid_request' }, 400);
  if (format !== 'pdf' && format !== 'json') return c.json({ error: 'Unknown format.', code: 'invalid_request' }, 400);

  const tokenHash = tokenSha256(String(token));
  // jobs.id is a global key, so (token hash, job, change order) is one
  // owner's link even without the job row.
  let ensured;
  try {
    ensured = await ensureRecordForToken(c.env, { jobId: String(jobId), changeOrderId: coId ? String(coId) : null, token: String(token) });
  } catch (err) {
    console.error('[esign/copy] record fetch failed:', err.message);
    return c.json({ error: 'Database error', code: 'server_error' }, 500);
  }
  if (!ensured) return c.json(NOT_SIGNED, 404);
  if (!ensured.row) return c.json(PENDING, 503);
  const row = ensured.row;

  await logEvent(c.env, {
    userId: row.user_id,
    jobId: row.job_id,
    changeOrderId: row.change_order_id || null,
    tokenHash,
    event: 'copy_downloaded',
    ip: edgeClientIp(c),
    userAgent: String(c.req.header('user-agent') || '').slice(0, 300),
  });

  const filename = signedPdfFilename(row.record);
  c.header('Cache-Control', 'no-store');
  if (format === 'json') {
    c.header('Content-Disposition', `attachment; filename="${filename.replace(/\.pdf$/, '.json')}"`);
    return c.json(envelopeOf(row), 200);
  }
  c.header('Content-Type', 'application/pdf');
  c.header('Content-Disposition', `attachment; filename="${filename}"`);
  return c.body(signedPdfOf(row), 200);
}
