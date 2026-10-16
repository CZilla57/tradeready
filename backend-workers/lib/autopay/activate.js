// Webhook activation of a pending autopay enrollment (Phase 24 spec §4.5):
// a paid pay-page session with metadata.tr_enrollment, or a completed
// setup-mode session (metadata.tr_kind === 'autopay_setup').
//
// Safety checks before anything is written:
//   - the enrollment exists and is still `pending` (an active one is an
//     idempotent redelivery; a revoked/replaced one is never resurrected)
//   - event.account === enrollment.stripe_account_id === the owner's current
//     stripe_accounts row (never activate against a switched account)
//   - the session is the enrollment's own checkout session
//   - the saved card is a card attached to the enrollment's Stripe Customer
// Then: any prior active enrollment for the plan becomes `replaced`, this one
// becomes `active` with brand/last4/expiry/wallet (never more card data), the
// replaced cards are detached unless still in use, and the customer gets the
// "Automatic payments are on" email.
//
// Returns { outcome } — 'activated' | 'already_active' | 'not_found' |
// 'inactive' | 'ownership_skip' | 'mismatch' | 'no_card'. Never throws for a
// Stripe or email problem; a Supabase read error throws (the webhook logs and
// still answers 200, spec §4.5).

const store = require('./store.js');
const { revokeEnrollment, detachIfUnused } = require('./revoke.js');
const { cardLabel } = require('./format.js');
const { buildAutopayOnEmail } = require('./emails.js');
const { sendCustomerEmail } = require('../ownerAlert.js');
const { mintManageToken, payPageUrl } = require('../pay/payToken.js');

const enc = encodeURIComponent;

async function fetchEnrollmentAnyUser(env, enrollmentId) {
  if (!/^[0-9a-fA-F-]{36}$/.test(String(enrollmentId || ''))) return null;
  const rows = await store.sbGet(env, `autopay_enrollments?id=eq.${enc(enrollmentId)}&select=*`);
  return rows.length ? rows[0] : null;
}

async function resolvePaymentMethod(stripe, intent, accountId) {
  const pm = intent && intent.payment_method;
  if (pm && typeof pm === 'object') return pm;
  if (typeof pm === 'string') return stripe.paymentMethods.retrieve(pm, {}, { stripeAccount: accountId });
  return null;
}

async function replacePriorActive(env, enrollment) {
  const prior = await store.sbGet(
    env,
    `autopay_enrollments?user_id=eq.${enc(enrollment.user_id)}&recurring_invoice_id=eq.${enc(enrollment.recurring_invoice_id)}` +
      `&status=eq.active&id=neq.${enc(enrollment.id)}&select=*`
  );
  const replaced = [];
  for (const old of prior) {
    // Detach later, after the new row is active, so a card shared with the
    // new enrollment is seen as in use.
    const { changed, row } = await revokeEnrollment(env, { enrollment: old, by: null, reason: 'replaced', from: ['active'], to: 'replaced', detach: false });
    if (changed) replaced.push(row);
  }
  return replaced;
}

async function activateEnrollment(env, { stripe, enrollmentId, eventAccount, session, intent, invoiceEmail, nowIso = new Date().toISOString() }) {
  const enrollment = await fetchEnrollmentAnyUser(env, enrollmentId);
  if (!enrollment) return { outcome: 'not_found' };
  if (enrollment.status === 'active') return { outcome: 'already_active' };
  if (enrollment.status !== 'pending') return { outcome: 'inactive' };

  const currentAccount = await store.fetchStripeAccountId(env, enrollment.user_id);
  if (!eventAccount || eventAccount !== enrollment.stripe_account_id || eventAccount !== currentAccount) {
    console.warn(`[autopay/activate] ${enrollment.id}: account mismatch (event ${eventAccount}, enrollment ${enrollment.stripe_account_id}, current ${currentAccount})`);
    return { outcome: 'ownership_skip' };
  }
  if (enrollment.checkout_session_id && session && enrollment.checkout_session_id !== session.id) {
    console.warn(`[autopay/activate] ${enrollment.id}: session ${session.id} is not the enrollment's ${enrollment.checkout_session_id}`);
    return { outcome: 'mismatch' };
  }

  let pm;
  try {
    if (!intent || intent.status !== 'succeeded') {
      console.warn(`[autopay/activate] ${enrollment.id}: intent not succeeded (${intent && intent.status})`);
      return { outcome: 'mismatch' };
    }
    pm = await resolvePaymentMethod(stripe, intent, eventAccount);
  } catch (err) {
    console.error(`[autopay/activate] ${enrollment.id}: payment method lookup failed:`, err.message);
    return { outcome: 'no_card' };
  }
  if (!pm || pm.type !== 'card' || !pm.card) return { outcome: 'no_card' };
  const pmCustomer = typeof pm.customer === 'object' && pm.customer ? pm.customer.id : pm.customer;
  if (pmCustomer !== enrollment.stripe_customer_id) {
    console.warn(`[autopay/activate] ${enrollment.id}: card not attached to ${enrollment.stripe_customer_id}`);
    return { outcome: 'mismatch' };
  }

  const card = pm.card;
  const patch = {
    status: 'active',
    activated_at: nowIso,
    payment_method_id: pm.id,
    card_brand: card.brand || null,
    card_last4: card.last4 || null,
    card_exp_month: Number.isInteger(card.exp_month) ? card.exp_month : null,
    card_exp_year: Number.isInteger(card.exp_year) ? card.exp_year : null,
    card_wallet: card.wallet && card.wallet.type ? card.wallet.type : null,
    billing_email: (session && session.customer_details && session.customer_details.email) || enrollment.billing_email || null,
    ...(session && !enrollment.checkout_session_id ? { checkout_session_id: session.id } : {}),
  };

  let replaced = await replacePriorActive(env, enrollment);
  let rows;
  try {
    rows = await store.updateEnrollments(env, `id=eq.${enc(enrollment.id)}&status=eq.pending`, patch);
  } catch (err) {
    if (err.status !== 409) throw err;
    // Another activation for the plan landed between our replace and update
    // (the one-active-per-plan index refused us). Newest consent wins:
    // replace again, retry once.
    replaced = replaced.concat(await replacePriorActive(env, enrollment));
    rows = await store.updateEnrollments(env, `id=eq.${enc(enrollment.id)}&status=eq.pending`, patch);
  }
  if (!rows.length) {
    const now = await fetchEnrollmentAnyUser(env, enrollment.id);
    return { outcome: now && now.status === 'active' ? 'already_active' : 'inactive' };
  }
  const active = rows[0];
  for (const old of replaced) await detachIfUnused(env, stripe, old);

  // "Automatic payments are on" — the written record of the agreement.
  try {
    const [settings, planRow, to] = await Promise.all([
      store.fetchSettings(env, active.user_id),
      store.fetchPlanForUser(env, active.user_id, active.recurring_invoice_id),
      store.resolveAutopayRecipient(env, active, invoiceEmail),
    ]);
    const plan = planRow && planRow.data ? planRow.data : {};
    const manageUrl = env.PAY_LINK_SIGNING_SECRET
      ? payPageUrl(env, 'm', mintManageToken(env.PAY_LINK_SIGNING_SECRET, { userId: active.user_id, enrollmentId: active.id }))
      : null;
    await sendCustomerEmail(
      env,
      buildAutopayOnEmail({
        settings,
        to,
        customerName: plan.customerName,
        planDescription: plan.description,
        card: cardLabel(active.card_brand, active.card_last4),
        consentText: active.consent_text,
        consentedAt: active.consented_at,
        manageUrl,
      }),
      'autopay-on email'
    );
  } catch (err) {
    console.error(`[autopay/activate] ${active.id}: confirmation email failed:`, err.message);
  }
  return { outcome: 'activated', enrollment: active };
}

module.exports = { activateEnrollment };
