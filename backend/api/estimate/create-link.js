// POST /api/estimate/create-link
// Mints a secure approval token (Node crypto) and writes {token, sentAt, snapshot}
// into the caller's job blob (service role). JWT-authed + rate-limited, mirroring
// create-payment-link.js. The device never needs a secure RNG.

const crypto = require('crypto');
const { fetchJobForUser, upsertJob } = require('../../lib/estimateStore');
const { createRateLimiter } = require('../../lib/guards');

const SUPABASE_URL = process.env.SUPABASE_URL;
const SUPABASE_ANON_KEY = process.env.SUPABASE_ANON_KEY;
const PUBLIC_BASE = 'https://czilla57.github.io/tradeready-legal/estimate.html';

const allow = createRateLimiter({ limit: 10 });

module.exports = async function handler(req, res) {
  res.setHeader('Access-Control-Allow-Origin', 'https://tradeready.app');
  res.setHeader('Access-Control-Allow-Methods', 'POST, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type, Authorization');
  if (req.method === 'OPTIONS') return res.status(200).end();
  if (req.method !== 'POST') return res.status(405).json({ error: 'Method not allowed' });

  if (!SUPABASE_URL || !SUPABASE_ANON_KEY || !process.env.SUPABASE_SERVICE_ROLE_KEY) {
    return res.status(500).json({ error: 'Server misconfiguration.' });
  }

  const auth = req.headers['authorization'];
  if (!auth || !auth.startsWith('Bearer ')) return res.status(401).json({ error: 'Unauthorized' });
  const userRes = await fetch(`${SUPABASE_URL}/auth/v1/user`, {
    headers: { Authorization: auth, apikey: SUPABASE_ANON_KEY },
  });
  if (!userRes.ok) return res.status(401).json({ error: 'Invalid or expired session.' });
  const userId = (await userRes.json())?.id;
  if (!userId) return res.status(401).json({ error: 'Unauthorized' });

  if (!allow(userId)) return res.status(429).json({ error: 'Too many requests. Please wait a moment.' });

  const { jobId, snapshot } = req.body || {};
  if (!jobId || typeof jobId !== 'string') return res.status(400).json({ error: 'jobId is required' });
  if (!snapshot || typeof snapshot !== 'object') return res.status(400).json({ error: 'snapshot is required' });

  let row;
  try {
    row = await fetchJobForUser(jobId, userId);
  } catch (err) {
    console.error('[estimate/create-link] fetch failed:', err.message);
    return res.status(500).json({ error: 'Database error' });
  }
  if (!row) {
    return res.status(422).json({ error: 'Estimate not synced yet. Open the app while online and try again.' });
  }

  const existing = row.data?.approval || {};
  // Reuse an outstanding token so re-sending doesn't break a link already out.
  const token = existing.token || crypto.randomBytes(24).toString('hex');
  const sentAt = new Date().toISOString();
  const nextData = {
    ...row.data,
    approval: { ...existing, token, sentAt, snapshot },
  };

  try {
    await upsertJob(jobId, userId, nextData);
  } catch (err) {
    console.error('[estimate/create-link] upsert failed:', err.message);
    return res.status(500).json({ error: 'Database error' });
  }

  const url = `${PUBLIC_BASE}?j=${encodeURIComponent(jobId)}&t=${encodeURIComponent(token)}`;
  return res.status(200).json({ url, token, sentAt });
};
