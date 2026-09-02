// POST /api/estimate/create-link — Workers port of
// backend/lib/estimate/createLink.js.
// Mints a secure approval token and writes {token, sentAt, snapshot} into the
// caller's job blob (service role). JWT-authed + rate-limited, mirroring
// create-payment-link. The device never needs a secure RNG.

import { randomBytes } from 'node:crypto';
import { fetchJobForUserVersioned, updateJobConditionally, planApprovalWrite } from '../../../lib/estimateStore.js';
import { createRateLimiter } from '../../../lib/guards.js';
import { jsonBody } from '../../appCors.js';

const allow = createRateLimiter({ limit: 10 });

// Pure planner for minting a link on ONE change order inside the array.
// Mirrors planApprovalWrite's freeze semantics (delegates to it); refuses a
// CO that already has an on-site manual decision. Never mutates its input.
export function planChangeOrderLink(changeOrders, changeOrderId, snapshot, sentAt, mintToken) {
  const list = Array.isArray(changeOrders) ? changeOrders : [];
  const idx = list.findIndex((co) => co && co.id === changeOrderId);
  if (idx === -1) return { error: 'not-found' };
  const co = list[idx];
  if (co.manualDecision) return { error: 'decided' };
  const plan = planApprovalWrite(co.approval, snapshot, sentAt, mintToken);
  const next = list.slice();
  next[idx] = { ...co, approval: plan.approval };
  return { changed: plan.changed, changeOrders: next, token: plan.token, sentAt: plan.sentAt };
}

export async function estimateCreateLinkHandler(c) {
  // Env-overridable so the branded domain can be switched on without a code
  // change — and so it stays on github.io until DNS for the custom domain
  // actually resolves. Flipping this only affects NEWLY minted links; old ones
  // keep working via the Pages redirect (and CORS accepts both hosts).
  const PUBLIC_BASE = c.env.ESTIMATE_PUBLIC_BASE || 'https://czilla57.github.io/tradeready-legal/estimate.html';
  // change.html rides the same host as estimate.html (env-overridable the same
  // way): swap the filename off the estimate base so flipping
  // ESTIMATE_PUBLIC_BASE to the branded domain moves BOTH pages.
  const CHANGE_PUBLIC_BASE =
    c.env.CHANGE_PUBLIC_BASE || PUBLIC_BASE.replace(/estimate\.html$/, 'change.html');

  // CORS never applies to this endpoint (the app calls it with a native
  // fetch — see lib/estimate/cors.js), so a single static real host replaces
  // the dead tradeready.app entry rather than an echo list.
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

  const { jobId, snapshot, changeOrderId } = (await jsonBody(c)) || {};
  if (!jobId || typeof jobId !== 'string') return c.json({ error: 'jobId is required' }, 400);
  if (!snapshot || typeof snapshot !== 'object') return c.json({ error: 'snapshot is required' }, 400);
  if (changeOrderId !== undefined && typeof changeOrderId !== 'string') {
    return c.json({ error: 'changeOrderId must be a string' }, 400);
  }

  const sentAt = new Date().toISOString();
  // Mint once and reuse across retries: a conflicting attempt wrote nothing, so
  // re-planning on the fresh row must not leak a fresh token each pass.
  let cachedToken;
  const mint = () => (cachedToken || (cachedToken = randomBytes(24).toString('hex')));
  const fetchRow = () => fetchJobForUserVersioned(c.env, jobId, userId);

  if (changeOrderId) {
    // Mint a link on ONE change order. The pure planner re-runs against the
    // freshest version each attempt; a decided/absent CO on the fresh row is a
    // terminal conflict (no retry), matching its prior single-shot behavior.
    let result;
    try {
      result = await updateJobConditionally(c.env, jobId, fetchRow, (row) => {
        const p = planChangeOrderLink(row.data?.changeOrders, changeOrderId, snapshot, sentAt, mint);
        if (p.error) return { conflict: true, reason: p.error };
        if (!p.changed) return { skip: true }; // frozen (already approved) — return its link
        return { data: { ...row.data, changeOrders: p.changeOrders } };
      });
    } catch (err) {
      console.error('[estimate/create-link] write failed:', err.message);
      return c.json({ error: 'Database error' }, 500);
    }
    if (result.notFound) {
      return c.json({ error: 'Estimate not synced yet. Open the app while online and try again.' }, 422);
    }
    if (result.conflict && result.reason === 'not-found') {
      return c.json({ error: 'Change order not synced yet. Open the app while online and try again.' }, 422);
    }
    if (result.conflict && result.reason === 'decided') {
      return c.json({ error: 'This change was already decided.' }, 409);
    }
    if (result.conflict) {
      return c.json({ error: 'This estimate changed. Please reload and try again.' }, 409);
    }
    const co = result.row.data.changeOrders.find((x) => x && x.id === changeOrderId);
    const { token, sentAt: coSentAt } = co.approval;
    const url = `${CHANGE_PUBLIC_BASE}?j=${encodeURIComponent(jobId)}&co=${encodeURIComponent(changeOrderId)}&t=${encodeURIComponent(token)}`;
    return c.json({ url, token, sentAt: coSentAt }, 200);
  }

  let result;
  try {
    result = await updateJobConditionally(c.env, jobId, fetchRow, (row) => {
      const p = planApprovalWrite(row.data?.approval || {}, snapshot, sentAt, mint);
      if (!p.changed) return { skip: true }; // approved snapshot is frozen — return its link
      return { data: { ...row.data, approval: p.approval } };
    });
  } catch (err) {
    console.error('[estimate/create-link] write failed:', err.message);
    return c.json({ error: 'Database error' }, 500);
  }
  if (result.notFound) {
    return c.json({ error: 'Estimate not synced yet. Open the app while online and try again.' }, 422);
  }
  if (result.conflict) {
    return c.json({ error: 'This estimate changed. Please reload and try again.' }, 409);
  }
  const approval = result.row.data.approval;
  const url = `${PUBLIC_BASE}?j=${encodeURIComponent(jobId)}&t=${encodeURIComponent(approval.token)}`;
  return c.json({ url, token: approval.token, sentAt: approval.sentAt }, 200);
}
