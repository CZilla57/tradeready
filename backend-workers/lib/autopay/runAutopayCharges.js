// The autopay sweep (Phase 24 spec §4.6). Runs on the existing */15 cron,
// BEFORE the invoice auto-email sweep (src/index.js scheduled()), and from
// the CRON_SECRET-guarded manual route /api/cron/run-autopay.
//
// Never charged twice (D7):
//   1. CLAIM first: insert autopay_charges (user, invoice, attempt=1) with
//      on_conflict + ignore-duplicates. No row back → another run has it.
//   2. CHARGE with the idempotency key tr-autopay:<invoiceId>:1 and the
//      claim's stored amount, so a replay sends identical parameters and
//      Stripe returns the first result (errors included).
//   3. BOOK with ledger id stripe_<pi id>; the union trigger collapses any
//      duplicate.
//   Every terminal status write is conditional on status=claimed, and only
//   the run that flips it sends mail, so receipts and alerts go out once.
// Mutual exclusion with the pay page: after claiming, the sweep expires any
// OPEN Checkout Session for the invoice before charging; if one already
// completed, the customer just paid on the pay page, so the claim is released
// and nothing is charged. The pay page does the mirror image (it re-checks
// for a claim after creating its session). Each side writes its marker, then
// looks for the other's, so a customer can't pay twice in the window.
// Off-session amounts are capped at the authorized ceiling AND the live
// balance (the selector), and are never retried after a decline: the
// customer gets a pay link and the owner an alert. An UNKNOWN outcome
// (network, Stripe 5xx/429) leaves the claim `claimed`; a later sweep
// re-reads it idempotently, and after 6 h (well inside Stripe's 24 h key
// window) lists the customer's PaymentIntents instead.

const { makeStripe, isUnknownOutcome } = require('../stripe/client.js');
const { recordStripePayment } = require('../stripe/recordPayment.js');
const { balanceDue } = require('../paymentMath.js');
const store = require('./store.js');
const { selectInvoicesToCharge, selectHousekeeping, planKey } = require('./selectInvoicesToCharge.js');
const { revokeEnrollment } = require('./revoke.js');
const { isHardFailure, normalizeFailureReason } = require('./reasons.js');
const { buildReceiptEmail, buildChargeFailedEmail, ownerChargeProblemAlert } = require('./emails.js');
const { cardLabel, autopayLedgerNote } = require('./format.js');
const { alertOwner, sendCustomerEmail } = require('../ownerAlert.js');
const { mintInvoicePayToken, mintManageToken, payPageUrl, ID_RE } = require('../pay/payToken.js');

const UNKNOWN_LIST_AFTER_MS = 6 * 60 * 60 * 1000;
// A claim younger than this belongs to a run that may still be working on it.
const RESUME_AFTER_MS = 5 * 60 * 1000;

const enc = encodeURIComponent;
const chargeKey = (invoiceId) => `tr-autopay:${invoiceId}:1`;

function emptyResult() {
  return {
    scanned: 0, charged: 0, failed: 0, skipped: 0, unknown: 0, deferred: 0, revoked: 0, expired: 0, yielded: 0,
    autopayHandled: new Set(),
    autopayByInvoice: new Map(),
  };
}

// Conditional terminal write: true only for the run that flipped it.
async function settleClaim(env, claim, patch) {
  const rows = await store.updateCharge(env, claim.id, patch, { where: '&status=eq.claimed' });
  return rows.length > 0;
}

async function markClaimBestEffort(env, claimId, patch) {
  try {
    await store.updateCharge(env, claimId, patch);
  } catch (err) {
    console.error(`[autopay] charge ${claimId} write failed:`, err.message);
  }
}

function manageUrlFor(env, enrollment) {
  if (!env.PAY_LINK_SIGNING_SECRET) return null;
  return payPageUrl(env, 'm', mintManageToken(env.PAY_LINK_SIGNING_SECRET, { userId: enrollment.user_id, enrollmentId: enrollment.id }));
}

// A fresh pay link for the FULL live balance (no `a`: the pay page charges
// the balance at click time).
function payUrlFor(env, enrollment, invoiceId) {
  if (!env.PAY_LINK_SIGNING_SECRET) return null;
  return payPageUrl(env, 't', mintInvoicePayToken(env.PAY_LINK_SIGNING_SECRET, { userId: enrollment.user_id, invoiceId }));
}

// Customer fallback email + owner alert for a failed/skipped/unknown charge.
async function notifyProblem(ctx, { claim, enrollment, invoice, reason, cardRemoved = false, emailCustomer = true }) {
  const { env, settingsByUser, result } = ctx;
  const settings = settingsByUser.get(enrollment.user_id) || {};
  let customerEmailed = false;
  if (emailCustomer) {
    const to = await store.resolveAutopayRecipient(env, enrollment, invoice.email);
    customerEmailed = await sendCustomerEmail(
      env,
      buildChargeFailedEmail({
        settings,
        to,
        customerName: invoice.customer,
        invoiceNumber: invoice.number,
        amountCents: claim.amount_cents,
        maxAmountCents: enrollment.max_amount_cents,
        reason,
        payUrl: payUrlFor(env, enrollment, invoice.id),
        manageUrl: cardRemoved ? null : manageUrlFor(env, enrollment),
        cardRemoved,
      }),
      'autopay fallback email'
    );
    if (customerEmailed) result.autopayHandled.add(invoice.id);
  }
  await alertOwner(env, {
    userId: enrollment.user_id,
    settings,
    alert: ownerChargeProblemAlert({
      customerName: invoice.customer,
      invoiceNumber: invoice.number,
      amountCents: claim.amount_cents,
      reason,
      customerEmailed,
      cardRemoved,
    }),
    data: { invoiceId: invoice.id, recurringInvoiceId: enrollment.recurring_invoice_id },
  });
  const now = new Date().toISOString();
  await markClaimBestEffort(env, claim.id, { owner_notified_at: now, ...(customerEmailed ? { customer_notified_at: now } : {}) });
}

async function onSucceeded(ctx, { claim, enrollment, invoice, pi, card }) {
  const { env, settingsByUser, result } = ctx;
  let booked;
  try {
    booked = await recordStripePayment(env, {
      invoiceId: invoice.id,
      connectedAccountId: enrollment.stripe_account_id,
      ledgerId: `stripe_${pi.id}`,
      amount: (pi.amount_received || pi.amount || claim.amount_cents) / 100,
      extra: { stripePaymentIntentId: pi.id, channel: 'autopay', note: autopayLedgerNote(card.brand, card.last4) },
    });
  } catch (err) {
    // The money moved; the ledger write didn't. Keep the claim `claimed` with
    // the PI id so the next sweep re-reads it and retries the (idempotent)
    // append.
    console.error(`[autopay] ledger write for ${pi.id} failed:`, err.message);
    await markClaimBestEffort(env, claim.id, { payment_intent_id: pi.id });
    result.unknown++;
    return;
  }
  const flipped = await settleClaim(env, claim, { status: 'succeeded', payment_intent_id: pi.id });
  if (!flipped) return; // another run settled it and sent the receipt
  result.charged++;
  if (booked.outcome !== 'appended' && booked.outcome !== 'duplicate') {
    // Money moved but the ledger refused it (the invoice vanished, or the
    // owner's account changed mid-run). Tell the owner to record it by hand.
    console.error(`[autopay] ${pi.id} succeeded but the ledger said ${booked.outcome} for invoice ${invoice.id}`);
    const number = String(invoice.number || invoice.id);
    await alertOwner(env, {
      userId: enrollment.user_id,
      settings: settingsByUser.get(enrollment.user_id) || {},
      alert: {
        subject: `Record an automatic payment: invoice ${number}`,
        text: `An automatic payment of ${(claim.amount_cents / 100).toFixed(2)} USD for invoice ${number} succeeded on Stripe (${pi.id}), but TradeReady could not add it to the invoice. Please record it in TradeReady.`,
        pushTitle: 'Record an autopay payment',
        pushBody: `Invoice ${number}`,
      },
      data: { invoiceId: invoice.id },
    });
  }
  const to = await store.resolveAutopayRecipient(env, enrollment, invoice.email);
  const after = booked.invoice || invoice;
  const sent = await sendCustomerEmail(
    env,
    buildReceiptEmail({
      settings: settingsByUser.get(enrollment.user_id) || {},
      to,
      customerName: invoice.customer,
      invoiceNumber: invoice.number,
      amountCents: pi.amount_received || pi.amount || claim.amount_cents,
      card: cardLabel(card.brand, card.last4),
      remainingCents: Math.round(balanceDue(after) * 100),
      date: new Date().toISOString().split('T')[0],
      autopay: true,
      manageUrl: manageUrlFor(env, enrollment),
    }),
    'autopay receipt'
  );
  if (sent) await markClaimBestEffort(env, claim.id, { customer_notified_at: new Date().toISOString() });
}

async function onFailed(ctx, { claim, enrollment, invoice, failure, stripe }) {
  const { env, result } = ctx;
  const flipped = await settleClaim(env, claim, {
    status: 'failed',
    failure_code: failure.code || 'card_declined',
    decline_code: failure.decline_code || null,
    failure_message: String(failure.message || '').slice(0, 500) || null,
    payment_intent_id: failure.paymentIntentId || claim.payment_intent_id || null,
  });
  if (!flipped) return;
  result.failed++;
  // Cancel the failed PaymentIntent so nothing can confirm it later.
  if (failure.paymentIntentId && failure.cancel !== false) {
    try {
      await stripe.paymentIntents.cancel(failure.paymentIntentId, {}, { stripeAccount: enrollment.stripe_account_id });
    } catch (err) {
      console.warn(`[autopay] cancel ${failure.paymentIntentId} failed: ${err.message}`);
    }
  }
  const hard = failure.code !== 'processing_error' && isHardFailure(failure);
  if (hard) {
    try {
      const { changed } = await revokeEnrollment(env, { enrollment, by: 'system', reason: 'hard_decline', stripe, from: ['active'] });
      if (changed) result.revoked++;
    } catch (err) {
      console.error(`[autopay] revoke after hard decline failed (${enrollment.id}):`, err.message);
    }
  }
  const reason = normalizeFailureReason({ status: 'failed', failure_code: failure.code, decline_code: failure.decline_code });
  await notifyProblem(ctx, { claim, enrollment, invoice, reason, cardRemoved: hard });
}

function failureFromError(err) {
  if (err && (err.type === 'StripeCardError' || Number(err.statusCode) === 402)) {
    return {
      code: err.code || 'card_declined',
      decline_code: err.decline_code || null,
      message: err.message,
      paymentIntentId: err.payment_intent && err.payment_intent.id ? err.payment_intent.id : null,
    };
  }
  return {
    code: 'processing_error',
    decline_code: null,
    message: `${(err && err.code) || (err && err.type) || 'error'}: ${(err && err.message) || ''}`,
    paymentIntentId: err && err.payment_intent && err.payment_intent.id ? err.payment_intent.id : null,
  };
}

function failureFromIntent(pi) {
  const e = pi.last_payment_error || {};
  return {
    code: e.code || (pi.status === 'requires_action' ? 'authentication_required' : 'card_declined'),
    decline_code: e.decline_code || null,
    message: e.message || `PaymentIntent ${pi.status}`,
    paymentIntentId: pi.id,
    cancel: pi.status !== 'canceled',
  };
}

// Acts on a PaymentIntent's CURRENT state. 'processing' (or anything not
// terminal) leaves the claim for a later sweep.
async function handleIntent(ctx, item, pi, card) {
  if (pi.status === 'succeeded') return onSucceeded(ctx, { ...item, pi, card });
  if (['requires_payment_method', 'requires_action', 'requires_confirmation', 'canceled'].includes(pi.status)) {
    return onFailed(ctx, { ...item, failure: failureFromIntent(pi) });
  }
  await markClaimBestEffort(ctx.env, item.claim.id, { payment_intent_id: pi.id });
  ctx.result.unknown++;
}

// Expire every open Checkout Session for this invoice on the owner's account
// (last 24 h). → 'clear', or 'completed' when an expire is refused because
// the session already completed (the customer paid on the pay page). Throws
// on an unknown outcome (the caller leaves the claim for a later sweep).
async function expireInvoiceSessions(stripe, accountId, invoiceId, nowSec) {
  let startingAfter;
  for (let page = 0; page < 10; page++) {
    const list = await stripe.checkout.sessions.list(
      { status: 'open', created: { gte: nowSec - 86400 }, limit: 100, ...(startingAfter ? { starting_after: startingAfter } : {}) },
      { stripeAccount: accountId }
    );
    const data = (list && list.data) || [];
    for (const s of data) {
      if (!s || !s.metadata || s.metadata.invoiceId !== invoiceId) continue;
      try {
        await stripe.checkout.sessions.expire(s.id, {}, { stripeAccount: accountId });
      } catch (err) {
        if (isUnknownOutcome(err)) throw err;
        return 'completed';
      }
    }
    if (!list || !list.has_more || !data.length) return 'clear';
    startingAfter = data[data.length - 1].id;
  }
  return 'clear';
}

// The autopay PaymentIntent for this claim, if Stripe has one (no charge is
// ever created here). Throws on a list failure.
async function findAutopayIntent(stripe, claim, enrollment) {
  const createdSec = Math.floor(Date.parse(claim.created_at) / 1000);
  const list = await stripe.paymentIntents.list(
    { customer: enrollment.stripe_customer_id, created: { gte: createdSec - 3600 }, limit: 100 },
    { stripeAccount: enrollment.stripe_account_id }
  );
  return ((list && list.data) || []).find((p) => p && p.metadata && p.metadata.invoiceId === claim.invoice_id && p.metadata.source === 'autopay') || null;
}

// Steps 2–6 for one claimed invoice. `isReplay`: a previous run may already
// have sent the create.
async function processClaim(ctx, item, { isReplay = false } = {}) {
  const { env, stripe, result } = ctx;
  const { claim, enrollment, invoice } = item;
  const stripeAccount = enrollment.stripe_account_id;

  // Mutual exclusion with the pay page (see the file header).
  let guard;
  try {
    guard = await expireInvoiceSessions(stripe, stripeAccount, invoice.id, Math.floor(ctx.now.getTime() / 1000));
  } catch (err) {
    console.warn(`[autopay] session check for ${invoice.id} failed: ${err.message}`);
    result.unknown++;
    return;
  }
  if (guard === 'completed') {
    if (isReplay) {
      let found = null;
      try {
        found = await findAutopayIntent(stripe, claim, enrollment);
      } catch (err) {
        result.unknown++;
        return;
      }
      if (found) return handleIntent(ctx, { ...item, stripe }, found, { brand: enrollment.card_brand, last4: enrollment.card_last4 });
    }
    // The customer is paying (or just paid) on the pay page: no autopay
    // attempt happened, so release the claim. If a balance remains, a later
    // sweep may charge it inside the window.
    await store.deleteClaim(env, claim.id);
    result.yielded++;
    return;
  }

  // Refresh the card (account updater) and prove it's still attached.
  let pm;
  try {
    pm = await stripe.paymentMethods.retrieve(enrollment.payment_method_id, {}, { stripeAccount });
  } catch (err) {
    if (isUnknownOutcome(err)) {
      result.unknown++;
      return;
    }
    pm = null;
  }
  const pmCustomer = pm && (typeof pm.customer === 'object' && pm.customer ? pm.customer.id : pm.customer);
  if (!pm || !pm.card || pmCustomer !== enrollment.stripe_customer_id) {
    const flipped = await settleClaim(env, claim, { status: 'failed', failure_code: 'payment_method_missing', failure_message: 'saved card missing or detached' });
    if (!flipped) return;
    result.failed++;
    try {
      const { changed } = await revokeEnrollment(env, { enrollment, by: 'system', reason: 'payment_method_missing', stripe, from: ['active'], detach: false });
      if (changed) result.revoked++;
    } catch (err) {
      console.error(`[autopay] revoke after missing card failed (${enrollment.id}):`, err.message);
    }
    await notifyProblem(ctx, { claim, enrollment, invoice, reason: 'payment_method_missing', cardRemoved: true });
    return;
  }
  const card = pm.card;
  if (card.last4 !== enrollment.card_last4 || card.exp_month !== enrollment.card_exp_month || card.exp_year !== enrollment.card_exp_year || card.brand !== enrollment.card_brand) {
    try {
      await store.updateEnrollments(env, `id=eq.${enc(enrollment.id)}`, {
        card_brand: card.brand || null,
        card_last4: card.last4 || null,
        card_exp_month: Number.isInteger(card.exp_month) ? card.exp_month : null,
        card_exp_year: Number.isInteger(card.exp_year) ? card.exp_year : null,
      });
    } catch (err) {
      console.error(`[autopay] card refresh write failed (${enrollment.id}):`, err.message);
    }
  }

  let pi;
  try {
    const number = String(invoice.number || '').replace(/\s+/g, ' ').trim().slice(0, 60);
    pi = await stripe.paymentIntents.create(
      {
        amount: claim.amount_cents,
        currency: 'usd',
        customer: enrollment.stripe_customer_id,
        payment_method: enrollment.payment_method_id,
        off_session: true,
        confirm: true,
        payment_method_types: ['card'],
        description: number ? `Invoice ${number}` : 'Invoice payment',
        metadata: { invoiceId: invoice.id, source: 'autopay', tr_enrollment: enrollment.id },
      },
      { stripeAccount, idempotencyKey: chargeKey(invoice.id) }
    );
  } catch (err) {
    if (isUnknownOutcome(err)) {
      console.warn(`[autopay] charge for ${invoice.id} outcome unknown: ${err.message}`);
      result.unknown++;
      return;
    }
    return onFailed(ctx, { ...item, failure: failureFromError(err), stripe });
  }
  return handleIntent(ctx, { ...item, stripe }, pi, card);
}

// Resolve a claim that never settled by listing the customer's
// PaymentIntents (no new charge is ever created here).
async function resolveByList(ctx, item, { ageMs }) {
  const { env, stripe, result } = ctx;
  const { claim, enrollment, invoice } = item;
  let found = null;
  try {
    found = await findAutopayIntent(stripe, claim, enrollment);
  } catch (err) {
    console.warn(`[autopay] list for claim ${claim.id} failed: ${err.message}`);
    result.unknown++;
    return;
  }
  if (found) {
    const card = { brand: enrollment.card_brand, last4: enrollment.card_last4 };
    return handleIntent(ctx, { ...item, stripe }, found, card);
  }
  if (ageMs < UNKNOWN_LIST_AFTER_MS && enrollment.status === 'active') {
    result.unknown++;
    return;
  }
  const flipped = await settleClaim(env, claim, { status: 'failed', failure_code: 'unknown', failure_message: 'outcome never confirmed by Stripe' });
  if (!flipped) return;
  result.failed++;
  await notifyProblem(ctx, { claim, enrollment, invoice, reason: 'unknown', emailCustomer: false });
}

// Claims a previous run left `claimed`.
async function resumeClaim(ctx, item, { nowMs }) {
  const { stripe, result } = ctx;
  const { claim, enrollment } = item;
  const ageMs = nowMs - Date.parse(claim.created_at);
  if (!(ageMs >= RESUME_AFTER_MS)) return;
  if (ageMs >= UNKNOWN_LIST_AFTER_MS) return resolveByList(ctx, item, { ageMs });
  if (claim.payment_intent_id) {
    try {
      const pi = await stripe.paymentIntents.retrieve(claim.payment_intent_id, {}, { stripeAccount: enrollment.stripe_account_id });
      return handleIntent(ctx, { ...item, stripe }, pi, { brand: enrollment.card_brand, last4: enrollment.card_last4 });
    } catch (err) {
      console.warn(`[autopay] retrieve ${claim.payment_intent_id} failed: ${err.message}`);
      result.unknown++;
      return;
    }
  }
  // No PI id yet. Replaying the create (same key, same stored amount) is an
  // idempotent re-read — but only while the authorization still stands;
  // otherwise just look for an existing charge.
  if (item.stillEligible) return processClaim(ctx, item, { isReplay: true });
  return resolveByList(ctx, item, { ageMs });
}

async function housekeep(ctx, { liveEnrollments, plansByKey, now }) {
  const { env, stripe, result } = ctx;
  const { revokePlanGone, expirePending } = selectHousekeeping({
    enrollments: liveEnrollments,
    plansByKey,
    now,
    planIdOk: (id) => ID_RE.test(String(id)),
  });
  for (const e of revokePlanGone) {
    try {
      const { changed } = await revokeEnrollment(env, { enrollment: e, by: 'system', reason: 'plan_removed', stripe, from: ['active'] });
      if (changed) result.revoked++;
    } catch (err) {
      console.error(`[autopay] housekeeping revoke ${e.id} failed:`, err.message);
    }
  }
  for (const e of expirePending) {
    try {
      const { changed } = await revokeEnrollment(env, { enrollment: e, by: 'system', reason: 'abandoned', from: ['pending'], detach: false });
      if (changed) result.expired++;
    } catch (err) {
      console.error(`[autopay] expire pending ${e.id} failed:`, err.message);
    }
  }
  return new Set(revokePlanGone.map((e) => e.id));
}

async function runAutopayCharges(env, { stripeFactory = makeStripe, now = new Date() } = {}) {
  if (!env.SUPABASE_URL || !env.SUPABASE_SERVICE_ROLE_KEY) {
    throw new Error('Server misconfiguration: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY required.');
  }
  const result = emptyResult();
  if (!env.STRIPE_SECRET_KEY) {
    console.error('[autopay] STRIPE_SECRET_KEY missing — autopay sweep skipped');
    return result;
  }

  const [liveEnrollments, claimedRows] = await Promise.all([
    store.fetchLiveEnrollments(env),
    store.sbGet(env, 'autopay_charges?status=eq.claimed&select=*'),
  ]);
  if (!liveEnrollments.length && !claimedRows.length) return result;

  // Claims may reference enrollments that are no longer live.
  const enrollmentById = new Map(liveEnrollments.map((e) => [e.id, e]));
  const missingIds = [...new Set(claimedRows.map((c) => c.enrollment_id).filter((id) => !enrollmentById.has(id)))];
  if (missingIds.length) {
    const list = store.inList(missingIds, /^[0-9a-fA-F-]{36}$/);
    if (list) for (const e of await store.sbGet(env, `autopay_enrollments?id=in.${list}&select=*`)) enrollmentById.set(e.id, e);
  }

  const allEnrollments = [...enrollmentById.values()];
  const userIds = [...new Set(allEnrollments.map((e) => e.user_id))];
  const planIds = [...new Set(allEnrollments.map((e) => e.recurring_invoice_id))];
  const [accountsByUser, settingsByUser, planRows, invoiceRows, charges] = await Promise.all([
    store.fetchStripeAccountsForUsers(env, userIds),
    store.fetchSettingsForUsers(env, userIds),
    store.fetchPlansByIds(env, userIds, planIds),
    store.fetchPlanInvoices(env, userIds, planIds),
    store.fetchChargesForUsers(env, userIds),
  ]);
  const plansByKey = new Map(planRows.map((p) => [planKey(p.user_id, p.id), p]));
  const invoiceByKey = new Map(invoiceRows.map((r) => [`${r.user_id}|${r.id}`, { ...(r.data || {}), id: r.id }]));
  const stripe = stripeFactory(env);
  const ctx = { env, stripe, settingsByUser, result, now };

  // 1. Housekeeping (silent): plan gone/reassigned → revoke; stale pending → expire.
  const revokedNow = await housekeep(ctx, { liveEnrollments, plansByKey, now });
  const activeEnrollments = liveEnrollments.filter((e) => e.status === 'active' && !revokedNow.has(e.id));

  // 2. Selection over the current state.
  const selection = selectInvoicesToCharge({
    enrollments: activeEnrollments,
    accountsByUser,
    plansByKey,
    invoiceRows,
    charges,
    now,
  });
  result.deferred = selection.deferred;

  // 3. Resume claims earlier runs left open.
  for (const claim of claimedRows) {
    const enrollment = enrollmentById.get(claim.enrollment_id);
    const invoice = invoiceByKey.get(`${claim.user_id}|${claim.invoice_id}`) || { id: claim.invoice_id };
    if (!enrollment) continue;
    const plan = plansByKey.get(planKey(enrollment.user_id, enrollment.recurring_invoice_id));
    const stillEligible =
      enrollment.status === 'active' &&
      !revokedNow.has(enrollment.id) &&
      accountsByUser.get(enrollment.user_id) === enrollment.stripe_account_id &&
      !!plan && !plan.deleted && plan.data && plan.data.autopayEnabled === true && plan.data.customerId === enrollment.customer_id &&
      !!enrollment.payment_method_id;
    try {
      await resumeClaim(ctx, { claim, enrollment, invoice, stillEligible }, { nowMs: now.getTime() });
    } catch (err) {
      console.error(`[autopay] resume claim ${claim.id} failed:`, err.message);
    }
  }

  // 4. New charges.
  for (const item of selection.charge) {
    result.scanned++;
    try {
      const claim = await store.claimCharge(env, {
        user_id: item.enrollment.user_id,
        invoice_id: item.invoice.id,
        enrollment_id: item.enrollment.id,
        amount_cents: item.cents,
        status: 'claimed',
      }, { now });
      if (!claim) continue; // another run has it
      await processClaim(ctx, { claim, enrollment: item.enrollment, invoice: item.invoice });
    } catch (err) {
      console.error(`[autopay] invoice ${item.invoice.id} failed:`, err.message);
    }
  }

  // 5. Above the authorized amount: one skipped claim + the fallback, once.
  for (const item of selection.skip) {
    result.scanned++;
    try {
      const claim = await store.claimCharge(env, {
        user_id: item.enrollment.user_id,
        invoice_id: item.invoice.id,
        enrollment_id: item.enrollment.id,
        amount_cents: item.cents,
        status: 'skipped',
        failure_code: 'amount_above_authorized',
      }, { now });
      if (!claim) continue;
      result.skipped++;
      await notifyProblem(ctx, { claim, enrollment: item.enrollment, invoice: item.invoice, reason: 'amount_above_authorized' });
    } catch (err) {
      console.error(`[autopay] skip for ${item.invoice.id} failed:`, err.message);
    }
  }

  // 6. For the invoice emails: invoices an active enrollment will charge.
  const charged = new Set(selection.charge.map((i) => i.invoice.id));
  for (const [invoiceId, { invoice, enrollment }] of selection.willCharge) {
    if (charged.has(invoiceId) || result.autopayHandled.has(invoiceId)) continue;
    const label = cardLabel(enrollment.card_brand, enrollment.card_last4);
    if (!label) continue;
    result.autopayByInvoice.set(invoiceId, { card: label, chargeOn: invoice.due, manageUrl: manageUrlFor(env, enrollment) });
  }

  return result;
}

// Invoice ids the reminder sweep must leave alone: an active enrollment will
// charge them in an open window and no claim exists yet (spec §4.10). Fails
// open (empty set) — a reminder racing a charge is a nuisance, not a charge.
async function autopayReminderExclusions(env, { now = new Date() } = {}) {
  try {
    const live = (await store.fetchLiveEnrollments(env)).filter((e) => e.status === 'active');
    if (!live.length) return new Set();
    const userIds = [...new Set(live.map((e) => e.user_id))];
    const planIds = [...new Set(live.map((e) => e.recurring_invoice_id))];
    const [accountsByUser, planRows, invoiceRows, charges] = await Promise.all([
      store.fetchStripeAccountsForUsers(env, userIds),
      store.fetchPlansByIds(env, userIds, planIds),
      store.fetchPlanInvoices(env, userIds, planIds),
      store.fetchChargesForUsers(env, userIds),
    ]);
    const plansByKey = new Map(planRows.map((p) => [planKey(p.user_id, p.id), p]));
    return selectInvoicesToCharge({ enrollments: live, accountsByUser, plansByKey, invoiceRows, charges, now }).windowOpen;
  } catch (err) {
    console.error('[autopay] reminder exclusions unavailable:', err.message);
    return new Set();
  }
}

module.exports = { runAutopayCharges, autopayReminderExclusions, chargeKey, UNKNOWN_LIST_AFTER_MS, RESUME_AFTER_MS };
