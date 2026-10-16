// Pure assembly of the portal-view response (Phase 12A). Extracted from the
// route handler so the whitelist — the security boundary — is directly
// testable without a Hono context. The rows this consumes also carry contact
// info, rates, notes and other internal data; every section is constructed
// key-by-key (no spreads) and nothing beyond the whitelist may cross.
// Workers-only: the frozen Vercel twin keeps serving the v1 shape, so this
// deliberately has no backend/ mirror.

const { balanceDue, amountPaid, PAID_EPSILON } = require('../paymentMath.js');
const { isAllowedPaymentLink } = require('../reminderEmail.js');
const { changeOrderStatus } = require('./changeOrderMath.js');
const { photoSignature, PHOTO_URL_TTL_SEC } = require('../photoSign.js');
const { hasSnapshotOptions, lowestTierTotal } = require('./quoteOptions.js');
const { snapshotExpiry } = require('./estimateExpiry.js');
const { isPlanOfferable, planCents } = require('../autopay/offer.js');
const { cadencePhrase } = require('../autopay/consentText.js');
const { cardLabel, centsToDollars } = require('../autopay/format.js');
const { mintSetupToken, mintManageToken, payPageUrl } = require('../pay/payToken.js');

const ESTIMATE_PAGE = 'https://gettradereadyapp.com/estimate.html';
const CHANGE_PAGE = 'https://gettradereadyapp.com/change.html';
const BOOKING_MANAGE_PAGE = 'https://gettradereadyapp.com/booking.html';

const DATE_RE = /^\d{4}-\d{2}-\d{2}$/;
const DAY_MS = 86_400_000;
// The window is padded a day behind "today" so an owner-naive date can never
// drop out early just because the server clock sits in a different zone.
const APPOINTMENT_LOOKBACK_DAYS = 1;
const APPOINTMENT_WINDOW_DAYS = 60;

// A manage link is only offered while the booking is still actionable on the
// shipped manage page's state machine.
const ACTIVE_BOOKING_STATUSES = new Set(['booked', 'confirmed', 'reschedule_requested']);

function isoDateUTC(ms) {
  return new Date(ms).toISOString().slice(0, 10);
}

function cap(value, n) {
  return String(value || '').slice(0, n);
}

function buildAppointments(jobRows, requestRows, { token, apiOrigin, nowMs }) {
  const minDate = isoDateUTC(nowMs - APPOINTMENT_LOOKBACK_DAYS * DAY_MS);
  const maxDate = isoDateUTC(nowMs + APPOINTMENT_WINDOW_DAYS * DAY_MS);
  const manageByJobId = new Map();
  for (const r of Array.isArray(requestRows) ? requestRows : []) {
    const d = r && r.data;
    if (!d || !d.manageToken || d.kind !== 'booked' || !d.convertedJobId) continue;
    if (!ACTIVE_BOOKING_STATUSES.has(d.status)) continue;
    manageByJobId.set(d.convertedJobId, d.manageToken);
  }
  return jobRows
    .filter((r) => {
      const d = r && r.data;
      // Archive check (contract C12, task 8.06): canonical archive marker is
      // archivedAt (utils/archive.ts) but RN never sets d.archived — check
      // both so an archived job stops serving. Additive, compat-safe.
      if (!d || d.archived || d.archivedAt || d.status === 'declined') return false;
      const date = d.scheduledDate;
      if (typeof date !== 'string' || !DATE_RE.test(date)) return false;
      // Owner-naive string comparison on purpose (FA-039) — never Date-parse.
      return date >= minDate && date <= maxDate;
    })
    .sort((a, b) => {
      const ka = `${a.data.scheduledDate}|${a.data.scheduledStartTime || ''}`;
      const kb = `${b.data.scheduledDate}|${b.data.scheduledStartTime || ''}`;
      return ka < kb ? -1 : ka > kb ? 1 : 0;
    })
    .map((r) => {
      const d = r.data;
      const manageToken = manageByJobId.get(r.id) || null;
      return {
        title: cap(d.title, 200),
        date: d.scheduledDate,
        start: d.scheduledStartTime || null,
        end: d.scheduledEndTime || null,
        // Job ids already cross the wire inside approvalUrl — not a new exposure.
        jobRef: String(r.id),
        icsUrl: `${apiOrigin}/api/estimate/portal-ics?p=${encodeURIComponent(token)}&j=${encodeURIComponent(r.id)}`,
        manageUrl: manageToken ? `${BOOKING_MANAGE_PAGE}?m=${encodeURIComponent(manageToken)}` : null,
      };
    });
}

// Phase 25: an accepted good/better/best choice is the price the customer
// agreed to; an undecided option estimate shows its lowest tier ("From $X");
// a legacy estimate keeps its frozen snapshot total.
function estimateTotal(approval, hasOptions) {
  const accepted = approval.decision === 'approved' && approval.selection
    ? Number(approval.selection.total) : NaN;
  if (Number.isFinite(accepted)) return accepted;
  if (hasOptions) {
    const lowest = lowestTierTotal(approval.snapshot);
    if (lowest !== null) return lowest;
  }
  return Number(approval.snapshot?.total || 0);
}

// Only jobs with an approval link are customer-visible estimates — the
// frozen snapshot plus the shipped approval page. Internal jobs stay
// invisible. (v1 behavior, moved verbatim from the route.)
// Phase 32: `validUntil` is the frozen snapshot's date (null when undated);
// `expired` uses the same owner-zone rule as respond and is false once the
// customer decided — a decided estimate no longer needs a decision.
function buildEstimates(jobRows, nowMs) {
  return jobRows
    .filter((r) => r.data && r.data.approval && r.data.approval.token)
    .map((r) => {
      const approval = r.data.approval;
      const hasOptions = hasSnapshotOptions(approval.snapshot);
      const { validUntil, expired } = snapshotExpiry(approval.snapshot, nowMs);
      return {
        title: cap(approval.snapshot?.jobTitle || r.data.title, 200),
        total: estimateTotal(approval, hasOptions),
        decision: approval.decision || null,
        hasOptions,
        validUntil,
        expired: !approval.decision && expired,
        approvalUrl: `${ESTIMATE_PAGE}?j=${encodeURIComponent(r.id)}&t=${encodeURIComponent(approval.token)}`,
      };
    });
}

// Mirrors the estimates rule: no approval token → the CO is internal and
// invisible. Cancelled COs are owner bookkeeping, not customer state.
function buildChangeOrders(jobRows) {
  const out = [];
  for (const r of jobRows) {
    const d = r && r.data;
    if (!d || !Array.isArray(d.changeOrders)) continue;
    for (const co of d.changeOrders) {
      if (!co || !co.approval || !co.approval.token) continue;
      const status = changeOrderStatus(co);
      if (status === 'cancelled') continue;
      out.push({
        jobTitle: cap(d.title, 200),
        title: cap(co.title, 200),
        amount: Number(co.amount || 0),
        status,
        changeUrl: `${CHANGE_PAGE}?j=${encodeURIComponent(r.id)}&co=${encodeURIComponent(co.id)}&t=${encodeURIComponent(co.approval.token)}`,
      });
    }
  }
  return out;
}

function buildInvoices(invoiceRows) {
  return invoiceRows.map((r) => {
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
      // Explicit paid-to-date (Phase 12A): same ledger math as balanceDue,
      // including the legacy paid-flag fallback, so the two never disagree.
      amountPaid: amountPaid(inv),
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
}

// Only photos the owner EXPLICITLY marked customer-visible, and only ones
// whose bytes are confirmed in R2 (uploadedAt). Absent flag = hidden — fail
// closed. URLs are signed per response with a 15-minute TTL and never
// persisted (spec §6); no secret configured → the section is empty and the
// portal otherwise works.
function buildPhotos(jobRows, photoRows, { userId, apiOrigin, photoSecret, nowMs }) {
  if (!photoSecret) return [];
  const titleByJobId = new Map(jobRows.map((r) => [r.id, cap(r.data && r.data.title, 200)]));
  const expiresAtSec = Math.floor(nowMs / 1000) + PHOTO_URL_TTL_SEC;
  const out = [];
  for (const r of Array.isArray(photoRows) ? photoRows : []) {
    const d = r && r.data;
    if (!d || d.customerVisible !== true || !d.uploadedAt) continue;
    const sig = photoSignature({ secret: photoSecret, userId, photoId: r.id, expiresAtSec });
    out.push({
      jobTitle: titleByJobId.get(d.jobId) || '',
      url: `${apiOrigin}/api/photos-public/${encodeURIComponent(r.id)}?u=${encodeURIComponent(userId)}&e=${expiresAtSec}&s=${sig}`,
    });
  }
  return out;
}

// Phase 24 (spec §4.9): one entry per plan of this customer that offers
// autopay (active, "Offer autopay" on). `on` carries the card label and a
// manage link; `available` carries a 7-day setup link bound to this
// customer. Links are minted per response and never persisted. Without the
// pay-link secret or a Stripe connection the section is empty (fail closed:
// a link the pay page would refuse is worse than none).
function buildAutopay(planRows, enrollmentRows, { userId, customerId, paySecret, payEnv, stripeConnected, nowMs }) {
  if (!paySecret || !stripeConnected) return [];
  const activeByPlan = new Map();
  for (const e of Array.isArray(enrollmentRows) ? enrollmentRows : []) {
    if (e && e.status === 'active' && e.customer_id === customerId) activeByPlan.set(e.recurring_invoice_id, e);
  }
  const nowSec = Math.floor(nowMs / 1000);
  const out = [];
  for (const plan of Array.isArray(planRows) ? planRows : []) {
    if (!isPlanOfferable(plan) || plan.data.customerId !== customerId) continue;
    const active = activeByPlan.get(plan.id) || null;
    let setupUrl = null;
    let manageUrl = null;
    try {
      if (active) manageUrl = payPageUrl(payEnv, 'm', mintManageToken(paySecret, { userId, enrollmentId: active.id }));
      else setupUrl = payPageUrl(payEnv, 's', mintSetupToken(paySecret, { userId, planId: plan.id, customerId, nowSec }));
    } catch {
      continue; // an id the token format refuses: skip the plan, never fail the portal
    }
    out.push({
      description: cap(plan.data.description, 200),
      amount: centsToDollars(planCents(plan)),
      cadence: cadencePhrase(plan.data.cadence) || '',
      status: active ? 'on' : 'available',
      card: active ? cardLabel(active.card_brand, active.card_last4) : null,
      setupUrl,
      manageUrl,
    });
  }
  return out;
}

function assemblePortalView({
  businessName, customerRow, jobRows, invoiceRows, requestRows, photoRows, token, apiOrigin, nowMs, userId, photoSecret,
  planRows = [], enrollmentRows = [], paySecret = null, payEnv = {}, stripeConnected = false,
}) {
  return {
    businessName: cap(businessName, 120),
    customerName: cap(customerRow.data?.name, 120),
    appointments: buildAppointments(jobRows, requestRows, { token, apiOrigin, nowMs }),
    estimates: buildEstimates(jobRows, nowMs),
    changeOrders: buildChangeOrders(jobRows),
    invoices: buildInvoices(invoiceRows),
    photos: buildPhotos(jobRows, photoRows, { userId, apiOrigin, photoSecret, nowMs }),
    autopay: buildAutopay(planRows, enrollmentRows, { userId, customerId: customerRow.id, paySecret, payEnv, stripeConnected, nowMs }),
  };
}

module.exports = { assemblePortalView };
