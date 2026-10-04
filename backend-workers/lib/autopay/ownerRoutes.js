// Owner-facing autopay routes (Phase 24 spec §4.8), called by the native app
// with the owner's Supabase JWT. The exact contract lives in the spec's build
// record §13.1; tests/autopayOwnerRoutes.test.cjs pins it key-by-key.
// Consent IP and user agent never leave the server; the consent time does.

const store = require('./store.js');
const { normalizeFailureReason } = require('./reasons.js');
const { centsToDollars } = require('./format.js');
const { revokeEnrollment } = require('./revoke.js');
const { buildAutopayOffEmail } = require('./emails.js');
const { sendCustomerEmail } = require('../ownerAlert.js');
const { UUID_RE } = require('../pay/payToken.js');

const CHARGE_LOOKBACK_DAYS = 120;
const MAX_ENROLLMENTS = 200;

function iso(value) {
  if (!value) return null;
  const t = Date.parse(value);
  return Number.isFinite(t) ? new Date(t).toISOString() : null;
}

function intOrNull(v) {
  return Number.isInteger(v) ? v : null;
}

function enrollmentForOwner(row) {
  const hasCard = /^\d{4}$/.test(String(row.card_last4 || ''));
  return {
    id: row.id,
    recurringInvoiceId: row.recurring_invoice_id,
    customerId: row.customer_id,
    status: row.status,
    card: hasCard
      ? {
          brand: String(row.card_brand || 'unknown').toLowerCase(),
          last4: row.card_last4,
          expMonth: intOrNull(row.card_exp_month),
          expYear: intOrNull(row.card_exp_year),
          wallet: row.card_wallet || null,
        }
      : null,
    maxAmount: centsToDollars(row.max_amount_cents),
    consentedAt: iso(row.consented_at),
    activatedAt: iso(row.activated_at),
    revokedAt: iso(row.revoked_at),
    revokedBy: row.revoked_by || null,
    revokeReason: row.status === 'active' ? null : row.revoke_reason || null,
  };
}

function chargeForOwner(row) {
  return {
    invoiceId: row.invoice_id,
    status: row.status,
    amount: centsToDollars(row.amount_cents),
    failureReason: normalizeFailureReason(row),
    at: iso(row.created_at),
  };
}

const OWNER_STATUSES = new Set(['active', 'revoked', 'replaced']);

async function ownerStatus(env, { userId, now = new Date() }) {
  const since = new Date(now.getTime() - CHARGE_LOOKBACK_DAYS * 86_400_000).toISOString();
  const [enrollments, charges] = await Promise.all([
    store.fetchEnrollmentsForUser(env, userId, { statuses: ['active', 'revoked', 'replaced'] }),
    store.fetchRecentChargesForUser(env, userId, since),
  ]);
  return {
    enrollments: enrollments
      .filter((e) => OWNER_STATUSES.has(e.status) && e.activated_at)
      .sort((a, b) => String(b.consented_at).localeCompare(String(a.consented_at)))
      .slice(0, MAX_ENROLLMENTS)
      .map(enrollmentForOwner),
    charges: charges
      .sort((a, b) => String(b.created_at).localeCompare(String(a.created_at)))
      .slice(0, 500)
      .map(chargeForOwner),
  };
}

// → { status, body } per the §13.1 contract.
async function ownerRemove(env, { stripe, userId, body }) {
  if (!body || body.action !== 'remove' || typeof body.enrollmentId !== 'string' || !UUID_RE.test(body.enrollmentId)) {
    return { status: 400, body: { error: 'Expected {"action":"remove","enrollmentId":"<uuid>"}.', code: 'invalid_request' } };
  }
  const enrollment = await store.fetchEnrollmentById(env, userId, body.enrollmentId);
  if (!enrollment) return { status: 404, body: { error: 'Not found', code: 'not_found' } };
  if (enrollment.status !== 'active' && enrollment.status !== 'pending') {
    return { status: 200, body: { enrollment: enrollmentForOwner(enrollment), changed: false } };
  }
  const revoked = await revokeEnrollment(env, { enrollment, by: 'owner', reason: 'owner_removed', stripe });
  const changed = revoked.changed;
  // Lost a race with another revoke: report the row as it now stands.
  const row = changed ? revoked.row : (await store.fetchEnrollmentById(env, userId, enrollment.id)) || revoked.row;
  if (changed && enrollment.status === 'active') {
    try {
      const [settings, planRow, to] = await Promise.all([
        store.fetchSettings(env, userId),
        store.fetchPlanForUser(env, userId, row.recurring_invoice_id),
        store.resolveAutopayRecipient(env, row, null),
      ]);
      const plan = planRow && planRow.data ? planRow.data : {};
      await sendCustomerEmail(
        env,
        buildAutopayOffEmail({ settings, to, customerName: plan.customerName, planDescription: plan.description, by: 'owner' }),
        'autopay removed-by-owner email'
      );
    } catch (err) {
      console.error('[autopay/manage] customer email failed:', err.message);
    }
  }
  return { status: 200, body: { enrollment: enrollmentForOwner(row), changed } };
}

module.exports = { ownerStatus, ownerRemove, enrollmentForOwner, chargeForOwner, CHARGE_LOOKBACK_DAYS };
