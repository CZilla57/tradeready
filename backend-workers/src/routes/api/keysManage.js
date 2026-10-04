// POST /api/api-keys/manage { action: list | create | rotate | revoke |
// activity, … } — owner-side API key management for Settings → API access
// (Roadmap Phase 23). Contract: the spec's build record §14.1.
// JWT-authed (the caller is the APP — hence appCors, which allows the
// Authorization header), per-user 10/min, copying portalManage.js.
// Thin shell; the invariants live in lib/api/keyAdmin.js (tested). The raw
// key is minted here from the Worker CSPRNG and only its hash is stored.

import { randomBytes } from 'node:crypto';
import { createRateLimiter } from '../../../lib/guards.js';
import { apiKeysManageCore } from '../../../lib/api/keyAdmin.js';
import { KEY_RANDOM_BYTES } from '../../../lib/api/keys.js';
import { appCors, jsonBody } from '../../appCors.js';

const allow = createRateLimiter({ limit: 10 });

async function authUserId(c) {
  const auth = c.req.header('authorization');
  if (!auth || !auth.startsWith('Bearer ')) return { error: c.json({ error: 'unauthorized' }, 401) };
  const userRes = await fetch(`${c.env.SUPABASE_URL}/auth/v1/user`, {
    headers: { Authorization: `Bearer ${auth.slice(7)}`, apikey: c.env.SUPABASE_ANON_KEY },
  });
  if (!userRes.ok) return { error: c.json({ error: 'unauthorized' }, 401) };
  const user = await userRes.json().catch(() => null);
  if (!user?.id) return { error: c.json({ error: 'unauthorized' }, 401) };
  return { userId: user.id };
}

export async function apiKeysManageHandler(c) {
  appCors(c, 'POST, OPTIONS');
  if (c.req.method === 'OPTIONS') return c.body(null, 200);
  if (c.req.method !== 'POST') return c.json({ error: 'method_not_allowed' }, 405);

  let authed;
  try {
    authed = await authUserId(c);
  } catch (err) {
    console.error('[api-keys/manage] session check failed:', err.message);
    return c.json({ error: 'server_error' }, 500);
  }
  if (authed.error) return authed.error;
  if (!allow(authed.userId)) return c.json({ error: 'rate_limited' }, 429);

  const body = (await jsonBody(c)) || {};
  let out;
  try {
    out = await apiKeysManageCore(c.env, {
      userId: authed.userId,
      body,
      nowMs: Date.now(),
      randomBytes: () => randomBytes(KEY_RANDOM_BYTES),
    });
  } catch (err) {
    console.error('[api-keys/manage] failed:', err.message);
    return c.json({ error: 'server_error' }, 500);
  }
  return c.json(out.json, out.status);
}
