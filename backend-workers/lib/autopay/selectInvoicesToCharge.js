// Pure eligibility for the autopay sweep (Phase 24 spec §4.6). No I/O.
//
// An invoice is charged now only when ALL hold:
//   - the enrollment is active and its stripe_account_id equals the owner's
//     CURRENT stripe_accounts row (never charge into a switched account)
//   - the plan row exists, is not deleted, has autopayEnabled === true, and
//     plan.customerId === enrollment.customer_id (a reassigned plan never
//     charges the first customer); the owner's toggle is read at charge time
//   - invoice.recurringInvoiceId === the enrollment's plan, no importBatchId,
//     and (when set) invoice.customerId === the enrollment's customer
//   - due > the activation date (UTC): the approved authorization covers
//     invoices that come due AFTER the day it was given (see build record:
//     the spec table said >=, the approved consent text says "after today")
//   - now ∈ [due 14:00 UTC, due + 7 d 14:00 UTC]: on the due date in every US
//     zone, never before the due date anywhere, ahead of the 15:00 UTC
//     reminder trigger
//   - balance > 0 and balance ≤ max_amount_cents (above → a one-time
//     `skipped` claim instead)
//   - no autopay_charges row for (user, invoice) — one attempt ever
//   - fewer than 25 claims for the user today (UTC)

const { balanceDue, isFullyPaid } = require('../paymentMath.js');

const WINDOW_START_HOUR_UTC = 14;
const WINDOW_DAYS = 7;
const DAY_MS = 86_400_000;
const MAX_CLAIMS_PER_USER_PER_DAY = 25;
const PENDING_TTL_MS = 48 * 60 * 60 * 1000;
const DATE_RE = /^(\d{4})-(\d{2})-(\d{2})$/;

// [start, end] in ms for a YYYY-MM-DD due date, or null when unparseable or
// not a real calendar date.
function chargeWindow(due) {
  const m = DATE_RE.exec(String(due || ''));
  if (!m) return null;
  const start = Date.UTC(Number(m[1]), Number(m[2]) - 1, Number(m[3]), WINDOW_START_HOUR_UTC, 0, 0);
  if (!Number.isFinite(start) || new Date(start).toISOString().slice(0, 10) !== due) return null;
  return { start, end: start + WINDOW_DAYS * DAY_MS };
}

function utcDate(iso) {
  const t = Date.parse(iso);
  return Number.isFinite(t) ? new Date(t).toISOString().slice(0, 10) : null;
}

const planKey = (userId, planId) => `${userId}|${planId}`;

// Rules that don't depend on the clock or on claims. → reason string or null.
function staticIneligibility({ invoice, enrollment, plan, currentAccountId }) {
  if (!enrollment || enrollment.status !== 'active') return 'enrollment_inactive';
  if (!currentAccountId || enrollment.stripe_account_id !== currentAccountId) return 'account_switched';
  if (!plan || plan.deleted || !plan.data) return 'plan_missing';
  if (plan.data.autopayEnabled !== true) return 'autopay_disabled';
  if (plan.data.customerId !== enrollment.customer_id) return 'plan_customer_changed';
  if (!invoice || invoice.recurringInvoiceId !== enrollment.recurring_invoice_id) return 'not_plan_invoice';
  if (invoice.importBatchId) return 'imported';
  if (invoice.customerId && invoice.customerId !== enrollment.customer_id) return 'invoice_customer_changed';
  const activated = utcDate(enrollment.activated_at);
  if (!activated || !(typeof invoice.due === 'string' && invoice.due > activated)) return 'due_before_consent';
  if (!chargeWindow(invoice.due)) return 'bad_due_date';
  if (isFullyPaid(invoice)) return 'paid';
  return null;
}

function balanceCents(invoice) {
  return Math.max(0, Math.round(balanceDue(invoice) * 100));
}

// enrollments: active rows; accountsByUser: Map userId → stripe_account_id;
// plansByKey: Map planKey → plan row (deleted rows included);
// invoiceRows: [{ id, user_id, data }]; charges: autopay_charges rows.
//
// → {
//   charge:      [{ invoice, enrollment, plan, cents }]   claim + charge now
//   skip:        [{ invoice, enrollment, plan, cents }]   above the ceiling
//   willCharge:  Map invoiceId → { invoice, enrollment, plan }   eligible
//                except for timing (window not over yet) — drives the
//                invoice-email "will be charged automatically" line
//   windowOpen:  Set invoiceId   eligible right now with no claim — the
//                reminder sweep leaves these alone
//   deferred:    number          held back by the daily cap
// }
function selectInvoicesToCharge({ enrollments, accountsByUser, plansByKey, invoiceRows, charges, now = new Date() }) {
  const nowMs = now.getTime();
  const dayStart = Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate());

  const claimed = new Set();
  const todayByUser = new Map();
  for (const ch of charges || []) {
    claimed.add(`${ch.user_id}|${ch.invoice_id}`);
    const t = Date.parse(ch.created_at);
    if (Number.isFinite(t) && t >= dayStart) todayByUser.set(ch.user_id, (todayByUser.get(ch.user_id) || 0) + 1);
  }

  const enrollmentByPlan = new Map();
  for (const e of enrollments || []) {
    if (e && e.status === 'active') enrollmentByPlan.set(planKey(e.user_id, e.recurring_invoice_id), e);
  }

  const charge = [];
  const skip = [];
  const willCharge = new Map();
  const windowOpen = new Set();
  let deferred = 0;

  const rows = [...(invoiceRows || [])].sort((a, b) => {
    const da = String((a.data && a.data.due) || '');
    const db = String((b.data && b.data.due) || '');
    return da < db ? -1 : da > db ? 1 : String(a.id) < String(b.id) ? -1 : 1;
  });

  for (const row of rows) {
    const invoice = { ...(row.data || {}), id: row.id };
    const planId = invoice.recurringInvoiceId;
    if (typeof planId !== 'string') continue;
    const enrollment = enrollmentByPlan.get(planKey(row.user_id, planId));
    if (!enrollment) continue;
    const plan = plansByKey.get(planKey(row.user_id, planId));
    if (staticIneligibility({ invoice, enrollment, plan, currentAccountId: accountsByUser.get(row.user_id) })) continue;
    if (claimed.has(`${row.user_id}|${row.id}`)) continue;

    const cents = balanceCents(invoice);
    if (cents <= 0) continue;
    const window = chargeWindow(invoice.due);
    if (nowMs > window.end) continue; // too late: the normal email/link path applies
    const withinCeiling = cents <= Number(enrollment.max_amount_cents);
    if (withinCeiling) willCharge.set(invoice.id, { invoice, enrollment, plan });
    if (nowMs < window.start) continue;

    if (withinCeiling) windowOpen.add(invoice.id);
    const used = todayByUser.get(row.user_id) || 0;
    if (used >= MAX_CLAIMS_PER_USER_PER_DAY) {
      deferred++;
      continue;
    }
    todayByUser.set(row.user_id, used + 1);
    (withinCeiling ? charge : skip).push({ invoice, enrollment, plan, cents });
  }

  return { charge, skip, willCharge, windowOpen, deferred };
}

// The pre-charge gate (review fix 2026-10-04, spec §13.7), judged on a
// FRESH read taken immediately before paymentIntents.create, on the first
// attempt and on every replay. The selector above works on the run's
// snapshot, which can be minutes (or, for a resumed claim, hours) old.
//
// claim: the autopay_charges row; snapshot: the enrollment the run charged
// with; live: { invoiceRow (deleted included), enrollment, plan, accountId }
// re-read now; completedSessions: `complete` Checkout Sessions on the
// owner's account (any invoice); now: Date.
// → { charge: true, invoice, enrollment }
//   | { charge: false, reason, invoice|null, enrollment|null }
// Never charge: a deleted or paid invoice; an enrollment that is no longer
// active, changed card or customer, or lost its account / plan / toggle; a
// balance that differs from the claimed amount (the claim's amount is what
// the create would send); a pay-page payment that completed but isn't in the
// ledger yet; or a time outside the charge window.
function liveVerdict({ claim, snapshot, live, completedSessions = [], now = new Date() }) {
  const { invoiceRow, enrollment, plan, accountId } = live || {};
  const invoice = invoiceRow ? { ...(invoiceRow.data || {}), id: invoiceRow.id } : null;
  const no = (reason) => ({ charge: false, reason, invoice, enrollment: enrollment || null });
  if (!invoiceRow || invoiceRow.deleted || !invoiceRow.data) return no('invoice_gone');
  if (!enrollment || enrollment.id !== claim.enrollment_id) return no('enrollment_inactive');
  if (snapshot && (enrollment.payment_method_id !== snapshot.payment_method_id || enrollment.stripe_customer_id !== snapshot.stripe_customer_id)) {
    return no('card_changed');
  }
  if (!enrollment.payment_method_id) return no('enrollment_inactive');
  const why = staticIneligibility({ invoice, enrollment, plan, currentAccountId: accountId });
  if (why) return no(why);
  const cents = balanceCents(invoice);
  if (cents <= 0) return no('paid');
  const booked = new Set((invoice.payments || []).map((p) => p && p.id));
  const unbooked = (completedSessions || []).some(
    (s) => s && s.status === 'complete' && s.metadata && s.metadata.invoiceId === invoice.id && !booked.has(`stripe_${s.id}`)
  );
  if (unbooked) return no('pay_page_pending');
  const window = chargeWindow(invoice.due);
  const nowMs = now.getTime();
  if (!window || nowMs < window.start || nowMs > window.end) return no('outside_window');
  if (cents !== Number(claim.amount_cents)) return no('balance_changed');
  if (!(Number(claim.amount_cents) <= Number(enrollment.max_amount_cents))) return no('above_authorized');
  return { charge: true, invoice, enrollment };
}

// Silent housekeeping (spec §4.6): active enrollments whose plan is gone or
// now belongs to another customer are revoked; pending rows older than 48 h
// are expired. `plansByKey` must come from a fetch that includes deleted
// rows; `planIdOk` guards against treating an unfetchable id as missing.
// These are CANDIDATES only: the sweep confirms each revoke with a targeted
// read of that plan and skips it when that read fails (fail closed), so a
// truncated or failed bulk read can never revoke an enrollment.
function selectHousekeeping({ enrollments, plansByKey, now = new Date(), planIdOk = () => true }) {
  const revokePlanGone = [];
  const expirePending = [];
  for (const e of enrollments || []) {
    if (!e) continue;
    if (e.status === 'pending') {
      const t = Date.parse(e.consented_at || e.created_at);
      if (Number.isFinite(t) && now.getTime() - t > PENDING_TTL_MS) expirePending.push(e);
      continue;
    }
    if (e.status !== 'active' || !planIdOk(e.recurring_invoice_id)) continue;
    if (planGoneFor(e, plansByKey.get(planKey(e.user_id, e.recurring_invoice_id)))) revokePlanGone.push(e);
  }
  return { revokePlanGone, expirePending };
}

// The plan an enrollment authorized is gone: missing, deleted, or now
// belonging to another customer.
function planGoneFor(enrollment, plan) {
  return !plan || plan.deleted || !plan.data || plan.data.customerId !== enrollment.customer_id;
}

module.exports = {
  selectInvoicesToCharge,
  selectHousekeeping,
  planGoneFor,
  chargeWindow,
  staticIneligibility,
  liveVerdict,
  balanceCents,
  planKey,
  MAX_CLAIMS_PER_USER_PER_DAY,
  WINDOW_START_HOUR_UTC,
  WINDOW_DAYS,
  PENDING_TTL_MS,
};
