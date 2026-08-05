// GET /api/estimate/portal-view?p=<token> — Workers port of
// backend/lib/estimate/portalView.js.
// The customer-portal read (2026-08-04 portal spec §4). READ-ONLY — the
// portal's approve/decline and Pay actions reuse the shipped estimate page
// and cached payment links; this handler only assembles a WHITELISTED view.
// The whitelist is the security boundary: the rows it reads also carry
// contact info, rates, notes and other customers' data — none of which may
// cross the wire to an anonymous caller.

import { applyCors } from '../../../lib/estimate/cors.js';
import { createRateLimiter } from '../../../lib/guards.js';
import {
  lookupCustomerByPortalToken,
  fetchBusinessName,
  fetchCustomerJobs,
  fetchCustomerInvoices,
} from '../../../lib/estimate/portalStore.js';
import { balanceDue, PAID_EPSILON } from '../../../lib/paymentMath.js';
import { isAllowedPaymentLink } from '../../../lib/reminderEmail.js';
import { clientIp } from '../../appCors.js';

const ESTIMATE_PAGE = 'https://gettradereadyapp.com/estimate.html';
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

  let businessName, jobRows, invoiceRows;
  try {
    [businessName, jobRows, invoiceRows] = await Promise.all([
      fetchBusinessName(c.env, row.user_id),
      fetchCustomerJobs(c.env, row.user_id, row.id),
      fetchCustomerInvoices(c.env, row.user_id, row.id),
    ]);
  } catch (err) {
    console.error('[estimate/portal-view] fetch failed:', err.message);
    return c.json({ error: 'Database error' }, 500);
  }

  // Only jobs with an approval link are customer-visible estimates — the
  // frozen snapshot plus the shipped approval page. Internal jobs stay
  // invisible.
  const estimates = jobRows
    .filter((r) => r.data && r.data.approval && r.data.approval.token)
    .map((r) => ({
      title: String(r.data.approval.snapshot?.jobTitle || r.data.title || '').slice(0, 200),
      total: Number(r.data.approval.snapshot?.total || 0),
      decision: r.data.approval.decision || null,
      approvalUrl: `${ESTIMATE_PAGE}?j=${encodeURIComponent(r.id)}&t=${encodeURIComponent(r.data.approval.token)}`,
    }));

  const invoices = invoiceRows.map((r) => {
    const inv = r.data || {};
    const link = inv.paymentLinkUrl;
    const due = balanceDue(inv);
    // Mirrors linkCurrent in reminderEmail.js: a cached link is only shown
    // when it was minted for the CURRENT balance. A link cached before a
    // partial payment (or for a deposit) charges a different amount than the
    // portal displays, and there's no owner in the loop here to catch the
    // customer being overcharged. An absent/unparseable paymentLinkAmount
    // fails the match and drops the link — fail closed, same as the email.
    const linkAmount = Number(inv.paymentLinkAmount);
    const linkCurrent =
      !inv.paid &&
      isAllowedPaymentLink(link) &&
      Number.isFinite(linkAmount) &&
      Math.abs(linkAmount - due) <= PAID_EPSILON;
    return {
      number: String(inv.number || ''),
      amount: Number(inv.amount || 0),
      balanceDue: due,
      due: inv.due || null,
      paid: !!inv.paid,
      paidAt: inv.paidAt || null,
      // Same host allowlist as the dunning email — a tampered or legacy link
      // can never turn the portal into a phishing surface. Paid invoices get
      // no link at all. Same current-balance gate as the dunning email — see
      // linkCurrent above.
      paymentLinkUrl: linkCurrent ? link : null,
    };
  });

  return c.json({
    businessName: String(businessName || '').slice(0, 120),
    customerName: String(row.data?.name || '').slice(0, 120),
    estimates,
    invoices,
  }, 200);
}
