// GET /api/estimate/portal-view?p=<token>
// The customer-portal read (2026-08-04 portal spec §4). READ-ONLY — the
// portal's approve/decline and Pay actions reuse the shipped estimate page
// and cached payment links; this handler only assembles a WHITELISTED view.
// The whitelist is the security boundary: the rows it reads also carry
// contact info, rates, notes and other customers' data — none of which may
// cross the wire to an anonymous caller.

const { applyCors } = require('./cors');
const { createRateLimiter } = require('../guards');
const {
  lookupCustomerByPortalToken,
  fetchBusinessName,
  fetchCustomerJobs,
  fetchCustomerInvoices,
} = require('./portalStore');
const { balanceDue } = require('../paymentMath');
const { isAllowedPaymentLink } = require('../reminderEmail');

const ESTIMATE_PAGE = 'https://gettradereadyapp.com/estimate.html';
const allow = createRateLimiter({ limit: 30 });

module.exports = async function portalView(req, res) {
  applyCors(req, res, 'GET, OPTIONS');
  if (req.method === 'OPTIONS') return res.status(200).end();
  if (req.method !== 'GET') return res.status(405).json({ error: 'Method not allowed' });

  const ip = (req.headers['x-forwarded-for'] || req.socket?.remoteAddress || 'unknown').split(',')[0].trim();
  if (!allow(ip)) return res.status(429).json({ error: 'Too many requests.' });

  const token = req.query.p;
  if (!token) return res.status(400).json({ error: 'Missing link parameters.' });

  let row;
  try {
    row = await lookupCustomerByPortalToken(String(token));
  } catch (err) {
    console.error('[estimate/portal-view] lookup failed:', err.message);
    return res.status(500).json({ error: 'Database error' });
  }
  if (!row) return res.status(404).json({ error: 'This link is invalid.' });

  let businessName, jobRows, invoiceRows;
  try {
    [businessName, jobRows, invoiceRows] = await Promise.all([
      fetchBusinessName(row.user_id),
      fetchCustomerJobs(row.user_id, row.id),
      fetchCustomerInvoices(row.user_id, row.id),
    ]);
  } catch (err) {
    console.error('[estimate/portal-view] fetch failed:', err.message);
    return res.status(500).json({ error: 'Database error' });
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
    return {
      number: String(inv.number || ''),
      amount: Number(inv.amount || 0),
      balanceDue: balanceDue(inv),
      due: inv.due || null,
      paid: !!inv.paid,
      paidAt: inv.paidAt || null,
      // Same host allowlist as the dunning email — a tampered or legacy link
      // can never turn the portal into a phishing surface. Paid invoices get
      // no link at all.
      paymentLinkUrl: !inv.paid && isAllowedPaymentLink(link) ? link : null,
    };
  });

  return res.status(200).json({
    businessName: String(businessName || '').slice(0, 120),
    customerName: String(row.data?.name || '').slice(0, 120),
    estimates,
    invoices,
  });
};
