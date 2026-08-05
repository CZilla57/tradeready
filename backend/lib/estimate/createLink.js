// POST /api/estimate/create-link
// Mints a secure approval token (Node crypto) and writes {token, sentAt, snapshot}
// into the caller's job blob (service role). JWT-authed + rate-limited, mirroring
// create-payment-link.js. The device never needs a secure RNG.

const crypto = require('crypto');
const { fetchJobForUser, upsertJob, planApprovalWrite } = require('../estimateStore');
const { createRateLimiter } = require('../guards');

const SUPABASE_URL = process.env.SUPABASE_URL;
const SUPABASE_ANON_KEY = process.env.SUPABASE_ANON_KEY;
// Env-overridable so the branded domain can be switched on from Vercel without
// a code change - and so it stays on github.io until DNS for the custom domain
// actually resolves. Flipping this only affects NEWLY minted links; old ones
// keep working via the Pages redirect (and CORS accepts both hosts).
const PUBLIC_BASE = process.env.ESTIMATE_PUBLIC_BASE || 'https://czilla57.github.io/tradeready-legal/estimate.html';

// change.html rides the same host as estimate.html (env-overridable the same
// way): swap the filename off the estimate base so flipping
// ESTIMATE_PUBLIC_BASE to the branded domain moves BOTH pages.
const CHANGE_PUBLIC_BASE =
  process.env.CHANGE_PUBLIC_BASE || PUBLIC_BASE.replace(/estimate\.html$/, 'change.html');

const allow = createRateLimiter({ limit: 10 });

// Pure planner for minting a link on ONE change order inside the array.
// Mirrors planApprovalWrite's freeze semantics (delegates to it); refuses a
// CO that already has an on-site manual decision. Never mutates its input.
function planChangeOrderLink(changeOrders, changeOrderId, snapshot, sentAt, mintToken) {
  const list = Array.isArray(changeOrders) ? changeOrders : [];
  const idx = list.findIndex((c) => c && c.id === changeOrderId);
  if (idx === -1) return { error: 'not-found' };
  const co = list[idx];
  if (co.manualDecision) return { error: 'decided' };
  const plan = planApprovalWrite(co.approval, snapshot, sentAt, mintToken);
  const next = list.slice();
  next[idx] = { ...co, approval: plan.approval };
  return { changed: plan.changed, changeOrders: next, token: plan.token, sentAt: plan.sentAt };
}

const handler = async function(req, res) {
  // CORS never applies to this endpoint (the app calls it with a native
  // fetch — see ./cors.js), so a single static real host replaces the dead
  // tradeready.app entry rather than an echo list.
  res.setHeader('Access-Control-Allow-Origin', 'https://gettradereadyapp.com');
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

  const { jobId, snapshot, changeOrderId } = req.body || {};
  if (!jobId || typeof jobId !== 'string') return res.status(400).json({ error: 'jobId is required' });
  if (!snapshot || typeof snapshot !== 'object') return res.status(400).json({ error: 'snapshot is required' });
  if (changeOrderId !== undefined && typeof changeOrderId !== 'string') {
    return res.status(400).json({ error: 'changeOrderId must be a string' });
  }

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

  const sentAt = new Date().toISOString();

  if (changeOrderId) {
    const plan = planChangeOrderLink(row.data?.changeOrders, changeOrderId, snapshot, sentAt,
      () => crypto.randomBytes(24).toString('hex'));
    if (plan.error === 'not-found') {
      return res.status(422).json({ error: 'Change order not synced yet. Open the app while online and try again.' });
    }
    if (plan.error === 'decided') {
      return res.status(409).json({ error: 'This change was already decided.' });
    }
    if (plan.changed) {
      try {
        await upsertJob(jobId, userId, { ...row.data, changeOrders: plan.changeOrders });
      } catch (err) {
        console.error('[estimate/create-link] upsert failed:', err.message);
        return res.status(500).json({ error: 'Database error' });
      }
    }
    const url = `${CHANGE_PUBLIC_BASE}?j=${encodeURIComponent(jobId)}&co=${encodeURIComponent(changeOrderId)}&t=${encodeURIComponent(plan.token)}`;
    return res.status(200).json({ url, token: plan.token, sentAt: plan.sentAt });
  }

  const existing = row.data?.approval || {};
  const plan = planApprovalWrite(existing, snapshot, sentAt, () => crypto.randomBytes(24).toString('hex'));

  if (plan.changed) {
    try {
      await upsertJob(jobId, userId, { ...row.data, approval: plan.approval });
    } catch (err) {
      console.error('[estimate/create-link] upsert failed:', err.message);
      return res.status(500).json({ error: 'Database error' });
    }
  }

  const url = `${PUBLIC_BASE}?j=${encodeURIComponent(jobId)}&t=${encodeURIComponent(plan.token)}`;
  return res.status(200).json({ url, token: plan.token, sentAt: plan.sentAt });
};

module.exports = handler;
module.exports.planChangeOrderLink = planChangeOrderLink;
