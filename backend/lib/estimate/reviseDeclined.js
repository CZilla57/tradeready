// POST /api/estimate/revise-declined — Vercel fallback for the authoritative
// declined-estimate revision operation.

const { fetchJobForUser, updateJobIfUnchanged } = require('../estimateStore');
const { planDeclinedEstimateRevision } = require('../estimateRevision');
const { createRateLimiter } = require('../guards');

const SUPABASE_URL = process.env.SUPABASE_URL;
const SUPABASE_ANON_KEY = process.env.SUPABASE_ANON_KEY;
const allow = createRateLimiter({ limit: 10 });
const TOKEN_PATTERN = /^[A-Za-z0-9_-]{16,256}$/;

module.exports = async function reviseDeclined(req, res) {
  res.setHeader('Access-Control-Allow-Origin', 'https://gettradereadyapp.com');
  res.setHeader('Access-Control-Allow-Methods', 'POST, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type, Authorization');
  if (req.method === 'OPTIONS') return res.status(200).end();
  if (req.method !== 'POST') return res.status(405).json({ error: 'Method not allowed' });
  if (!SUPABASE_URL || !SUPABASE_ANON_KEY || !process.env.SUPABASE_SERVICE_ROLE_KEY) {
    return res.status(500).json({ error: 'Server misconfiguration.' });
  }
  const auth = req.headers.authorization;
  if (!auth || !auth.startsWith('Bearer ')) return res.status(401).json({ error: 'Unauthorized' });
  const userRes = await fetch(`${SUPABASE_URL}/auth/v1/user`, {
    headers: { Authorization: auth, apikey: SUPABASE_ANON_KEY },
  });
  if (!userRes.ok) return res.status(401).json({ error: 'Invalid or expired session.' });
  const userId = (await userRes.json())?.id;
  if (!userId) return res.status(401).json({ error: 'Unauthorized' });
  if (!allow(userId)) return res.status(429).json({ error: 'Too many requests. Please wait a moment.' });

  const { jobId, approvalToken } = req.body || {};
  if (!jobId || typeof jobId !== 'string') return res.status(400).json({ error: 'jobId is required' });
  if (typeof approvalToken !== 'string' || !TOKEN_PATTERN.test(approvalToken)) {
    return res.status(400).json({ error: 'approvalToken is invalid' });
  }

  let row;
  try {
    row = await fetchJobForUser(jobId, userId);
  } catch (err) {
    console.error('[estimate/revise-declined] fetch failed:', err.message);
    return res.status(500).json({ error: 'Database error' });
  }
  if (!row) {
    return res.status(422).json({ error: 'Estimate not synced yet. Open the app while online and try again.' });
  }
  const plan = planDeclinedEstimateRevision(row.data, approvalToken);
  if (plan.error) {
    return res.status(409).json({ error: 'The estimate changed. Refresh it before revising.' });
  }
  if (!plan.changed) return res.status(200).json({ job: plan.job });

  try {
    const updated = await updateJobIfUnchanged(jobId, userId, row.updated_at, plan.job);
    if (!updated) {
      return res.status(409).json({ error: 'The estimate changed. Refresh it before revising.' });
    }
    return res.status(200).json({ job: updated.data });
  } catch (err) {
    console.error('[estimate/revise-declined] update failed:', err.message);
    return res.status(500).json({ error: 'Database error' });
  }
};
