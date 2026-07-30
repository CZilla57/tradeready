// POST /api/estimate/respond
// The customer's Approve/Decline. Token-gated (no user auth — the token is the
// capability). Stamps consentAt SERVER-SIDE and merges only approval.* into the
// job blob (service role). The device performs the status transition on pull.

const { fetchJob, upsertJob, constantTimeEqual } = require('../../lib/estimateStore');
const { createRateLimiter } = require('../../lib/guards');

const ALLOWED_ORIGIN = 'https://czilla57.github.io';
const allow = createRateLimiter({ limit: 10 });

// Pure decision merge — exported for unit tests. Returns the SAME reference when
// locked (already approved) so callers can skip a needless DB write.
function nextApproval(existing, body, meta) {
  if (existing && existing.decision === 'approved') return existing; // terminal lock
  const decision = body.decision === 'approved' ? 'approved' : 'declined';
  return {
    ...existing,
    decision,
    consentAt: meta.consentAt,
    signerName: decision === 'approved' ? String(body.signerName || '').slice(0, 200) : (existing && existing.signerName),
    declineReason: decision === 'declined' ? String(body.declineReason || '').slice(0, 500) || undefined : undefined,
    ip: meta.ip,
    userAgent: meta.userAgent,
  };
}

async function handler(req, res) {
  res.setHeader('Access-Control-Allow-Origin', ALLOWED_ORIGIN);
  res.setHeader('Access-Control-Allow-Methods', 'POST, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type');
  if (req.method === 'OPTIONS') return res.status(200).end();
  if (req.method !== 'POST') return res.status(405).json({ error: 'Method not allowed' });

  const ip = (req.headers['x-forwarded-for'] || req.socket?.remoteAddress || 'unknown').split(',')[0].trim();
  if (!allow(ip)) return res.status(429).json({ error: 'Too many requests.' });

  const { jobId, token, decision, signerName, declineReason } = req.body || {};
  if (!jobId || !token) return res.status(400).json({ error: 'Missing link parameters.' });
  if (decision !== 'approved' && decision !== 'declined') return res.status(400).json({ error: 'Invalid decision.' });
  if (decision === 'approved' && !String(signerName || '').trim()) {
    return res.status(400).json({ error: 'Please type your name to approve.' });
  }

  let row;
  try {
    row = await fetchJob(jobId);
  } catch (err) {
    console.error('[estimate/respond] fetch failed:', err.message);
    return res.status(500).json({ error: 'Database error' });
  }
  const existing = row && row.data && row.data.approval;
  if (!row || !existing || !constantTimeEqual(existing.token, String(token))) {
    return res.status(404).json({ error: 'This link is invalid or has expired.' });
  }

  const merged = nextApproval(existing, { decision, signerName, declineReason }, {
    consentAt: new Date().toISOString(),
    ip,
    userAgent: String(req.headers['user-agent'] || '').slice(0, 300),
  });

  if (merged !== existing) {
    try {
      await upsertJob(jobId, row.user_id, { ...row.data, approval: merged });
    } catch (err) {
      console.error('[estimate/respond] upsert failed:', err.message);
      return res.status(500).json({ error: 'Database error' });
    }
  }

  return res.status(200).json({ ok: true, decision: merged.decision, consentAt: merged.consentAt });
}

handler.nextApproval = nextApproval;
module.exports = handler;
module.exports.nextApproval = nextApproval;
