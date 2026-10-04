// GET /api/esign/verify?r=<recordId>&d=<recordDigest>
// Public, rate-limited integrity check (Phase 19 spec §3.5). Recomputes the
// record digest from the stored canonical record, compares it with the one
// asked about, and checks the Ed25519 seal against the published key.
// Answers {valid, signedAt, documentType, keyId} — never names, amounts or
// any other record content — and a bare {valid: false} for "unknown record"
// and "doesn't match" alike.

import { createRateLimiter } from '../../../lib/guards.js';
import { applyCors } from '../../../lib/estimate/cors.js';
import { clientIp } from '../../appCors.js';
import { isDigest, isRecordId, recordDigest } from '../../../lib/esign/record.js';
import { fetchRecordById } from '../../../lib/esign/store.js';
import { verifySeal } from '../../../lib/esign/seal.js';

const allow = createRateLimiter({ limit: 30 });

export async function esignVerifyHandler(c) {
  applyCors(c, 'GET, OPTIONS');
  if (c.req.method === 'OPTIONS') return c.body(null, 200);
  if (c.req.method !== 'GET') return c.json({ error: 'Method not allowed' }, 405);
  if (!allow(clientIp(c))) return c.json({ error: 'Too many requests.', code: 'rate_limited' }, 429);
  c.header('Cache-Control', 'no-store');

  const recordId = String(c.req.query('r') || '').trim().toLowerCase();
  const digest = String(c.req.query('d') || '').trim().toLowerCase();
  if (!isRecordId(recordId) || !isDigest(digest)) {
    return c.json({ error: 'Enter the record ID and the record SHA-256 from the signed copy.', code: 'invalid_request' }, 400);
  }

  let row;
  try {
    row = await fetchRecordById(c.env, recordId);
  } catch (err) {
    console.error('[esign/verify] fetch failed:', err.message);
    return c.json({ error: 'Database error', code: 'server_error' }, 500);
  }
  const invalid = { valid: false };
  if (!row || row.record_digest !== digest) return c.json(invalid, 200);
  if (recordDigest(row.record) !== digest) return c.json(invalid, 200);
  if (!(await verifySeal(c.env, digest, row.seal_key_id, row.seal))) return c.json(invalid, 200);
  return c.json({
    valid: true,
    signedAt: row.record && row.record.signedAt,
    documentType: row.document_type,
    keyId: row.seal_key_id,
  }, 200);
}
