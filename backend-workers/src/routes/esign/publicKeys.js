// GET /api/esign/public-keys — the Ed25519 public keys that check record
// seals, by key id (Phase 19 spec §3.5, decision 19-Q10). Every key ever
// used stays listed so old seals keep verifying after a rotation. The signed
// message is the 32 raw bytes of the record's SHA-256 digest.

import { applyCors } from '../../../lib/estimate/cors.js';
import { publicKeys } from '../../../lib/esign/seal.js';

export async function esignPublicKeysHandler(c) {
  applyCors(c, 'GET, OPTIONS');
  if (c.req.method === 'OPTIONS') return c.body(null, 200);
  if (c.req.method !== 'GET') return c.json({ error: 'Method not allowed' }, 405);
  const keys = publicKeys(c.env);
  const current = String(c.env.ESIGN_SEAL_KEY_ID || '').trim();
  c.header('Cache-Control', 'public, max-age=300');
  return c.json({
    alg: 'Ed25519',
    signedMessage: 'sha256(canonical record JSON), as 32 raw bytes',
    current: keys.some((k) => k.keyId === current) ? current : null,
    keys,
  }, 200);
}
