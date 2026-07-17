// GET /api/estimate/view?j=<jobId>&t=<token>
// Sanitized, token-gated read for the public viewer. Returns ONLY this estimate's
// frozen snapshot + decision state — never other jobs or extra PII.

const { fetchJob, constantTimeEqual } = require('../../lib/estimateStore');
const { createRateLimiter } = require('../../lib/guards');

const ALLOWED_ORIGIN = 'https://czilla57.github.io';
const allow = createRateLimiter({ limit: 30 });

module.exports = async function handler(req, res) {
  res.setHeader('Access-Control-Allow-Origin', ALLOWED_ORIGIN);
  res.setHeader('Access-Control-Allow-Methods', 'GET, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type');
  if (req.method === 'OPTIONS') return res.status(200).end();
  if (req.method !== 'GET') return res.status(405).json({ error: 'Method not allowed' });

  const ip = (req.headers['x-forwarded-for'] || req.socket?.remoteAddress || 'unknown').split(',')[0].trim();
  if (!allow(ip)) return res.status(429).json({ error: 'Too many requests.' });

  const jobId = req.query.j;
  const token = req.query.t;
  if (!jobId || !token) return res.status(400).json({ error: 'Missing link parameters.' });

  let row;
  try {
    row = await fetchJob(String(jobId));
  } catch (err) {
    console.error('[estimate/view] fetch failed:', err.message);
    return res.status(500).json({ error: 'Database error' });
  }
  const a = row && row.data && row.data.approval;
  if (!row || !a || !constantTimeEqual(a.token, String(token))) {
    return res.status(404).json({ error: 'This link is invalid or has expired.' });
  }

  return res.status(200).json({
    ...a.snapshot,
    decision: a.decision || null,
    consentAt: a.consentAt || null,
    signerName: a.signerName || null,
    signatureRequired: true,
  });
};
