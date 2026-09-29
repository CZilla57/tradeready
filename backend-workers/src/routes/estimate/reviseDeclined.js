// POST /api/estimate/revise-declined — archives one exact declined approval,
// invalidates its old capability, and returns the job to lead in a single
// optimistic write. The bearer establishes ownership; no owner ID is accepted.

import { fetchJobForUser, updateJobIfUnchanged } from '../../../lib/estimateStore.js';
import { planDeclinedEstimateRevision } from '../../../lib/estimateRevision.js';
import { createRateLimiter } from '../../../lib/guards.js';
import { jsonBody } from '../../appCors.js';

const allow = createRateLimiter({ limit: 10 });
const TOKEN_PATTERN = /^[A-Za-z0-9_-]{16,256}$/;

export async function estimateReviseDeclinedHandler(c) {
  c.header('Access-Control-Allow-Origin', 'https://gettradereadyapp.com');
  c.header('Access-Control-Allow-Methods', 'POST, OPTIONS');
  c.header('Access-Control-Allow-Headers', 'Content-Type, Authorization');
  if (c.req.method === 'OPTIONS') return c.body(null, 200);
  if (c.req.method !== 'POST') return c.json({ error: 'Method not allowed' }, 405);

  const { SUPABASE_URL, SUPABASE_ANON_KEY } = c.env;
  if (!SUPABASE_URL || !SUPABASE_ANON_KEY || !c.env.SUPABASE_SERVICE_ROLE_KEY) {
    return c.json({ error: 'Server misconfiguration.' }, 500);
  }
  const auth = c.req.header('authorization');
  if (!auth || !auth.startsWith('Bearer ')) return c.json({ error: 'Unauthorized' }, 401);
  const userRes = await fetch(`${SUPABASE_URL}/auth/v1/user`, {
    headers: { Authorization: auth, apikey: SUPABASE_ANON_KEY },
  });
  if (!userRes.ok) return c.json({ error: 'Invalid or expired session.' }, 401);
  const userId = (await userRes.json())?.id;
  if (!userId) return c.json({ error: 'Unauthorized' }, 401);
  if (!allow(userId)) return c.json({ error: 'Too many requests. Please wait a moment.' }, 429);

  const { jobId, approvalToken } = (await jsonBody(c)) || {};
  if (!jobId || typeof jobId !== 'string') return c.json({ error: 'jobId is required' }, 400);
  if (typeof approvalToken !== 'string' || !TOKEN_PATTERN.test(approvalToken)) {
    return c.json({ error: 'approvalToken is invalid' }, 400);
  }

  let row;
  try {
    row = await fetchJobForUser(c.env, jobId, userId);
  } catch (err) {
    console.error('[estimate/revise-declined] fetch failed:', err.message);
    return c.json({ error: 'Database error' }, 500);
  }
  if (!row) {
    return c.json({ error: 'Estimate not synced yet. Open the app while online and try again.' }, 422);
  }
  const plan = planDeclinedEstimateRevision(row.data, approvalToken);
  if (plan.error) {
    return c.json({ error: 'The estimate changed. Refresh it before revising.' }, 409);
  }
  if (!plan.changed) return c.json({ job: plan.job }, 200);

  try {
    const updated = await updateJobIfUnchanged(
      c.env,
      jobId,
      userId,
      row.updated_at,
      plan.job
    );
    if (!updated) {
      return c.json({ error: 'The estimate changed. Refresh it before revising.' }, 409);
    }
    return c.json({ job: updated.data }, 200);
  } catch (err) {
    console.error('[estimate/revise-declined] update failed:', err.message);
    return c.json({ error: 'Database error' }, 500);
  }
}
