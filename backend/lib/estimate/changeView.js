// GET /api/estimate/change-view?j=<jobId>&co=<changeOrderId>&t=<token>
// Sanitized, token-gated read for the change-order viewer. Returns ONLY this
// CO's frozen snapshot + decided state + LIVE context totals (original/new).

const { fetchJob, constantTimeEqual } = require('../estimateStore');
const { billableContext } = require('./changeOrderMath');
const { createRateLimiter } = require('../guards');
const { applyCors } = require('./cors');
const allow = createRateLimiter({ limit: 30 });

module.exports = async function handler(req, res) {
  applyCors(req, res, 'GET, OPTIONS');
  if (req.method === 'OPTIONS') return res.status(200).end();
  if (req.method !== 'GET') return res.status(405).json({ error: 'Method not allowed' });

  const ip = (req.headers['x-forwarded-for'] || req.socket?.remoteAddress || 'unknown').split(',')[0].trim();
  if (!allow(ip)) return res.status(429).json({ error: 'Too many requests.' });

  const jobId = req.query.j;
  const coId = req.query.co;
  const token = req.query.t;
  if (!jobId || !coId || !token) return res.status(400).json({ error: 'Missing link parameters.' });

  let row;
  try {
    row = await fetchJob(String(jobId));
  } catch (err) {
    console.error('[estimate/change-view] fetch failed:', err.message);
    return res.status(500).json({ error: 'Database error' });
  }
  const cos = (row && row.data && Array.isArray(row.data.changeOrders)) ? row.data.changeOrders : [];
  const co = cos.find((c) => c && c.id === String(coId));
  const a = co && co.approval;
  if (!row || !co || !a || !constantTimeEqual(a.token, String(token))) {
    return res.status(404).json({ error: 'This link is invalid or has expired.' });
  }

  // A manual on-site decision also counts as decided for the viewer.
  const decision = a.decision || (co.manualDecision && co.manualDecision.decision) || null;

  return res.status(200).json({
    ...a.snapshot,
    description: co.description || null,
    decision,
    consentAt: a.consentAt || null,
    signerName: a.signerName || null,
    signatureRequired: true,
    context: billableContext(row.data, String(coId)),
  });
};
