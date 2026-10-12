// Checkout Session listing shared by the autopay sweep and the pay page's
// checkout (tips spec §13: refuse a checkout while a completed session for
// the invoice isn't booked yet). Behavior moved verbatim from
// runAutopayCharges.js.

// Open sessions live at most 41 min (pay page) or 24 h (legacy Payment
// Link sessions). A completed session's webhook can lag by up to Stripe's
// 3-day retry schedule; 8 days covers that plus the whole 7-day window.
const OPEN_SESSION_LOOKBACK_SEC = 86400;
const COMPLETE_SESSION_LOOKBACK_SEC = 8 * 86400;
const SESSION_LIST_MAX_PAGES = 20;

// Every session matching `params` on the owner's account, read to the end.
// Throws on a Stripe error and when the list can't be finished within
// SESSION_LIST_MAX_PAGES: a partial list is never treated as complete.
async function listAllSessions(stripe, accountId, params) {
  const out = [];
  let startingAfter;
  for (let page = 0; page < SESSION_LIST_MAX_PAGES; page++) {
    const list = await stripe.checkout.sessions.list(
      { ...params, limit: 100, ...(startingAfter ? { starting_after: startingAfter } : {}) },
      { stripeAccount: accountId }
    );
    const data = (list && list.data) || [];
    out.push(...data);
    if (!list || !list.has_more || !data.length) return out;
    startingAfter = data[data.length - 1].id;
  }
  throw new Error(`checkout session list (${params.status}) longer than ${SESSION_LIST_MAX_PAGES} pages`);
}

// This invoice's COMPLETE Checkout Sessions (last 8 days). liveVerdict
// stands down while one of them has no stripe_<session id> ledger entry yet
// (paid on the pay page, webhook not landed). Throws like listAllSessions.
async function completedInvoiceSessions(stripe, accountId, invoiceId, nowSec) {
  const done = await listAllSessions(stripe, accountId, { status: 'complete', created: { gte: nowSec - COMPLETE_SESSION_LOOKBACK_SEC } });
  return done.filter((s) => s && s.status === 'complete' && s.metadata && s.metadata.invoiceId === invoiceId);
}

module.exports = {
  OPEN_SESSION_LOOKBACK_SEC,
  COMPLETE_SESSION_LOOKBACK_SEC,
  SESSION_LIST_MAX_PAGES,
  listAllSessions,
  completedInvoiceSessions,
};
