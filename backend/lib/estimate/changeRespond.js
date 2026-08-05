// POST /api/estimate/change-respond
// The customer's Approve/Decline for ONE change order. Token-gated; stamps
// consentAt SERVER-SIDE and merges only that CO's approval.* into the jobs
// blob (service role). Reuses respond.js's nextApproval merge (terminal lock
// on approved). Refuses 409 when the tradesperson already recorded an
// on-site manual decision — a stale link can't override it.

const { fetchJob, upsertJob, constantTimeEqual } = require('../estimateStore');
const { nextApproval } = require('./respond');
const { createRateLimiter } = require('../guards');
const { applyCors } = require('./cors');
const allow = createRateLimiter({ limit: 10 });

module.exports = async function handler(req, res) {
  applyCors(req, res, 'POST, OPTIONS');
  if (req.method === 'OPTIONS') return res.status(200).end();
  if (req.method !== 'POST') return res.status(405).json({ error: 'Method not allowed' });

  const ip = (req.headers['x-forwarded-for'] || req.socket?.remoteAddress || 'unknown').split(',')[0].trim();
  if (!allow(ip)) return res.status(429).json({ error: 'Too many requests.' });

  const { jobId, changeOrderId, token, decision, signerName, declineReason } = req.body || {};
  if (!jobId || !changeOrderId || !token) return res.status(400).json({ error: 'Missing link parameters.' });
  if (decision !== 'approved' && decision !== 'declined') return res.status(400).json({ error: 'Invalid decision.' });
  if (decision === 'approved' && !String(signerName || '').trim()) {
    return res.status(400).json({ error: 'Please type your name to approve.' });
  }

  let row;
  try {
    row = await fetchJob(String(jobId));
  } catch (err) {
    console.error('[estimate/change-respond] fetch failed:', err.message);
    return res.status(500).json({ error: 'Database error' });
  }
  const cos = (row && row.data && Array.isArray(row.data.changeOrders)) ? row.data.changeOrders : [];
  const idx = cos.findIndex((c) => c && c.id === String(changeOrderId));
  const co = idx === -1 ? null : cos[idx];
  const existing = co && co.approval;
  if (!row || !co || !existing || !constantTimeEqual(existing.token, String(token))) {
    return res.status(404).json({ error: 'This link is invalid or has expired.' });
  }
  if (co.manualDecision) {
    return res.status(409).json({ error: 'This change was already decided.' });
  }

  const merged = nextApproval(existing, { decision, signerName, declineReason }, {
    consentAt: new Date().toISOString(),
    ip,
    userAgent: String(req.headers['user-agent'] || '').slice(0, 300),
  });

  if (merged !== existing) {
    const next = cos.slice();
    next[idx] = { ...co, approval: merged };
    try {
      await upsertJob(String(jobId), row.user_id, { ...row.data, changeOrders: next });
    } catch (err) {
      console.error('[estimate/change-respond] upsert failed:', err.message);
      return res.status(500).json({ error: 'Database error' });
    }
  }

  return res.status(200).json({ ok: true, decision: merged.decision, consentAt: merged.consentAt });
};
