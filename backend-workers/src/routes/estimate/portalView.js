// GET /api/estimate/portal-view?p=<token> — Workers port of
// backend/lib/estimate/portalView.js (v1) + the Phase 12A read additions
// (appointments, change orders, amountPaid), which are Workers-only.
// READ-ONLY — the portal's approve/decline, Pay, and booking-manage actions
// all reuse shipped pages and links; this handler only assembles a
// WHITELISTED view. The whitelist (lib/estimate/portalAssemble.js) is the
// security boundary: the rows it reads also carry contact info, rates,
// notes and other customers' data — none of which may cross the wire to an
// anonymous caller.

import { applyCors } from '../../../lib/estimate/cors.js';
import { createRateLimiter } from '../../../lib/guards.js';
import {
  fetchBusinessName,
  fetchCustomerJobs,
  fetchCustomerInvoices,
  fetchCustomerBookingRequests,
  fetchCustomerJobPhotos,
} from '../../../lib/estimate/portalStore.js';
import { resolvePortalCustomer } from '../../../lib/estimate/portalTokenStore.js';
import { logPortalEvent } from '../../../lib/estimate/portalRequestStore.js';
import { assemblePortalView } from '../../../lib/estimate/portalAssemble.js';
import { clientIp } from '../../appCors.js';

const allow = createRateLimiter({ limit: 30 });

export async function portalViewHandler(c) {
  applyCors(c, 'GET, OPTIONS');
  if (c.req.method === 'OPTIONS') return c.body(null, 200);
  if (c.req.method !== 'GET') return c.json({ error: 'Method not allowed' }, 405);

  const ip = clientIp(c);
  if (!allow(ip)) return c.json({ error: 'Too many requests.' }, 429);

  const token = c.req.query('p');
  if (!token) return c.json({ error: 'Missing link parameters.' }, 400);

  let row;
  try {
    // Phase 12D: table-first resolution — revoked/disabled tokens hard-stop
    // here; legacy blob tokens fall back and get lazily backfilled.
    row = await resolvePortalCustomer(c.env, String(token));
  } catch (err) {
    console.error('[estimate/portal-view] lookup failed:', err.message);
    return c.json({ error: 'Database error' }, 500);
  }
  if (!row) return c.json({ error: 'This link is invalid.' }, 404);

  let businessName, jobRows, invoiceRows, requestRows;
  try {
    [businessName, jobRows, invoiceRows, requestRows] = await Promise.all([
      fetchBusinessName(c.env, row.user_id),
      fetchCustomerJobs(c.env, row.user_id, row.id),
      fetchCustomerInvoices(c.env, row.user_id, row.id),
      fetchCustomerBookingRequests(c.env, row.user_id, row.id),
    ]);
  } catch (err) {
    console.error('[estimate/portal-view] fetch failed:', err.message);
    return c.json({ error: 'Database error' }, 500);
  }

  let photoRows = [];
  if (c.env.PORTAL_URL_SIGNING_SECRET) {
    try {
      photoRows = await fetchCustomerJobPhotos(c.env, row.user_id, jobRows.map((r) => r.id));
    } catch (err) {
      console.error('[estimate/portal-view] photos fetch failed:', err.message);
      photoRows = []; // photos are additive — never fail the whole portal for them
    }
  }

  // Security log (Phase 12D read events) — best-effort, prefix only.
  await logPortalEvent(c.env, { userId: row.user_id, tokenPrefix: String(token).slice(0, 8), event: 'view', ip });

  return c.json(
    assemblePortalView({
      businessName,
      customerRow: row,
      jobRows,
      invoiceRows,
      requestRows,
      photoRows,
      token: String(token),
      apiOrigin: new URL(c.req.url).origin,
      nowMs: Date.now(),
      userId: row.user_id,
      photoSecret: c.env.PORTAL_URL_SIGNING_SECRET,
    }),
    200
  );
}
