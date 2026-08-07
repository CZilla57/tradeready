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
  lookupCustomerByPortalToken,
  fetchBusinessName,
  fetchCustomerJobs,
  fetchCustomerInvoices,
  fetchCustomerBookingRequests,
} from '../../../lib/estimate/portalStore.js';
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
    row = await lookupCustomerByPortalToken(c.env, String(token));
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

  return c.json(
    assemblePortalView({
      businessName,
      customerRow: row,
      jobRows,
      invoiceRows,
      requestRows,
      token: String(token),
      apiOrigin: new URL(c.req.url).origin,
      nowMs: Date.now(),
    }),
    200
  );
}
