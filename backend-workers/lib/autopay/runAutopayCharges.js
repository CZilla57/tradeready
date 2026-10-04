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
//
// The pre-charge gate (review fix 2026-10-04, spec §13.7). Immediately
// before ANY paymentIntents.create — first attempt or replay — processClaim:
//   a. expires every OPEN Checkout Session for the invoice (a refused expire
//      means it just completed), THEN lists the account's COMPLETE sessions
//      (both read to the end; a list that can't be finished is an unknown,
//      never "clear"). Open first: a session that completes in between is
//      still seen as complete.
//   b. re-reads the invoice, the enrollment, the plan and the Stripe account
//      from the database and judges them with liveVerdict: a deleted or paid
//      invoice, a revoked/changed enrollment, a lost plan/toggle/account, a
//      balance that differs from the claimed amount, a completed pay-page
//      session not yet in the ledger, or a time outside the window → stand
//      down, nothing is charged.
//   c. stamps charge_sent_at on the still-`claimed` row, then sends the
//      create. No stamp → no create.
// Standing down: a claim with no charge_sent_at is released (deleted; the
// DELETE itself requires charge_sent_at is null), and a later sweep
// re-selects the invoice at its live balance if it is still due. A claim
// whose create MAY have reached Stripe is never released: the sweep lists
// the customer's PaymentIntents for this claim and acts on what it finds;
// with none found it settles `failed`/`unknown` and tells the owner, so no
// later claim can charge on top of a create Stripe did receive.
// A check that fails before the create (network, Stripe 5xx, Supabase)
// releases a never-sent claim, so the pay page isn't blocked as `in_flight`
// by a claim no run is working on.
// Off-session amounts are capped at the authorized ceiling AND the live
// balance, and are never retried after a decline: the customer gets a pay
// link and the owner an alert. An UNKNOWN create outcome (network, Stripe
// 5xx/429) leaves the stamped claim `claimed`; a later sweep replays it
// through the same gate (same key, same amount, only if the live balance
// still equals it), and after 6 h (well inside Stripe's 24 h key window)
// lists the customer's PaymentIntents instead.

const { makeStripe, isUnknownOutcome } = require('../stripe/client.js');
const { recordStripePayment } = require('../stripe/recordPayment.js');
const { balanceDue, amountPaid, PAID_EPSILON } = require('../paymentMath.js');
const store = require('./store.js');
const { selectInvoicesToCharge, selectHousekeeping, liveVerdict, planGoneFor, planKey, WINDOW_DAYS } = require('./selectInvoicesToCharge.js');
const { revokeEnrollment } = require('./revoke.js');
const { isHardFailure, normalizeFailureReason } = require('./reasons.js');
const { buildReceiptEmail, buildChargeFailedEmail, ownerChargeProblemAlert } = require('./emails.js');
const { cardLabel, autopayLedgerNote } = require('./format.js');
const { alertOwner, sendCustomerEmail } = require('../ownerAlert.js');
const { mintInvoicePayToken, mintManageToken, payPageUrl, ID_RE } = require('../pay/payToken.js');

const UNKNOWN_LIST_AFTER_MS = 6 * 60 * 60 * 1000;
// A claim younger than this belongs to a run that may still be working on it.
const RESUME_AFTER_MS = 5 * 60 * 1000;
// Open sessions live at most 41 min (pay page) or 24 h (legacy Payment
// Link sessions). A completed session's webhook can lag by up to Stripe's
// 3-day retry schedule; 8 days covers that plus the whole 7-day window.
const OPEN_SESSION_LOOKBACK_SEC = 86400;
const COMPLETE_SESSION_LOOKBACK_SEC = 8 * 86400;
const SESSION_LIST_MAX_PAGES = 20;
const DAY_MS = 86_400_000;
// Stand-down reasons after which a found-but-failed PaymentIntent gets no
// customer pay-link email: there is nothing left to pay.
const QUIET_REASONS = new Set(['invoice_gone', 'paid']);

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
  } else if (booked.outcome === 'appended' && !booked.invoiceDeleted && booked.invoice && amountPaid(booked.invoice) > Number(booked.invoice.amount) + PAID_EPSILON) {
    // Only reachable when a create that may have reached Stripe is
    // reconciled after the invoice was paid another way: the charge already
    // happened, so it is booked (the ledger must match Stripe) and the owner
    // decides whether to refund. (recordStripePayment alerts for a deleted
    // invoice itself.)
    const number = String(invoice.number || invoice.id);
    const over = amountPaid(booked.invoice) - Number(booked.invoice.amount);
    await alertOwner(env, {
      userId: enrollment.user_id,
      settings: settingsByUser.get(enrollment.user_id) || {},
      alert: {
        subject: `Autopay overpaid invoice ${number}`,
        text: `An automatic payment of ${((pi.amount_received || pi.amount || claim.amount_cents) / 100).toFixed(2)} USD for invoice ${number} (${pi.id}) went through on Stripe after the invoice was paid another way. Invoice ${number} has now received ${over.toFixed(2)} USD more than the balance. If that wasn't owed, refund it in Stripe and record the refund in TradeReady.`,
        pushTitle: 'Autopay overpaid an invoice',
        pushBody: `Invoice ${number}: ${over.toFixed(2)} USD over`,
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

async function onFailed(ctx, { claim, enrollment, invoice, failure, stripe, quiet = false }) {
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
  await notifyProblem(ctx, { claim, enrollment, invoice, reason, cardRemoved: hard, emailCustomer: !quiet });
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

// Expire every open Checkout Session for this invoice on the owner's account
// (last 24 h). → 'clear', or 'completed' when an expire is refused because
// the session already completed (the customer paid on the pay page). Throws
// on an unknown outcome (the caller stands down without charging).
async function expireOpenSessions(stripe, accountId, invoiceId, nowSec) {
  const open = await listAllSessions(stripe, accountId, { status: 'open', created: { gte: nowSec - OPEN_SESSION_LOOKBACK_SEC } });
  for (const s of open) {
    if (!s || !s.metadata || s.metadata.invoiceId !== invoiceId) continue;
    try {
      await stripe.checkout.sessions.expire(s.id, {}, { stripeAccount: accountId });
    } catch (err) {
      if (isUnknownOutcome(err)) throw err;
      return 'completed';
    }
  }
  return 'clear';
}

// This invoice's COMPLETE Checkout Sessions (last 8 days). liveVerdict
// stands down while one of them has no stripe_<session id> ledger entry yet
// (paid on the pay page, webhook not landed). Throws like listAllSessions.
async function completedInvoiceSessions(stripe, accountId, invoiceId, nowSec) {
  const done = await listAllSessions(stripe, accountId, { status: 'complete', created: { gte: nowSec - COMPLETE_SESSION_LOOKBACK_SEC } });
  return done.filter((s) => s && s.status === 'complete' && s.metadata && s.metadata.invoiceId === invoiceId);
}

// The autopay PaymentIntent for this claim, if Stripe has one (no charge is
// ever created here), matched on the metadata every autopay create carries.
// Read to the end; throws on a list failure or a list too long to finish.
async function findAutopayIntent(stripe, claim, enrollment) {
  const createdSec = Math.floor(Date.parse(claim.created_at) / 1000);
  let startingAfter;
  for (let page = 0; page < SESSION_LIST_MAX_PAGES; page++) {
    const list = await stripe.paymentIntents.list(
      { customer: enrollment.stripe_customer_id, created: { gte: createdSec - 3600 }, limit: 100, ...(startingAfter ? { starting_after: startingAfter } : {}) },
      { stripeAccount: enrollment.stripe_account_id }
    );
    const data = (list && list.data) || [];
    const found = data.find((p) => p && p.metadata && p.metadata.invoiceId === claim.invoice_id && p.metadata.source === 'autopay');
    if (found) return found;
    if (!list || !list.has_more || !data.length) return null;
    startingAfter = data[data.length - 1].id;
  }
  throw new Error(`payment intent list for claim ${claim.id} longer than ${SESSION_LIST_MAX_PAGES} pages`);
}

// The rows the gate judges, read fresh from the database (throws on a
// Supabase error).
async function loadLive(env, claim, enrollment) {
  const [invoiceRow, liveEnrollment, plan, accountId] = await Promise.all([
    store.fetchInvoiceForUser(env, claim.user_id, claim.invoice_id),
    store.fetchEnrollmentById(env, claim.user_id, claim.enrollment_id),
    store.fetchPlanForUser(env, claim.user_id, enrollment.recurring_invoice_id),
    store.fetchStripeAccountId(env, claim.user_id),
  ]);
  return { invoiceRow, enrollment: liveEnrollment, plan, accountId };
}

const cardOf = (enrollment) => ({ brand: enrollment.card_brand, last4: enrollment.card_last4 });

// Release a claim no create was sent for (no attempt happened, so no row
// stays; §13.1). The DELETE is conditional on charge_sent_at is null.
async function releaseClaim(ctx, claim) {
  try {
    await store.deleteClaim(ctx.env, claim.id);
  } catch (err) {
    // The claim stays; the next sweep resumes it through the same gate.
    console.error(`[autopay] release of claim ${claim.id} failed:`, err.message);
  }
}

// A check before the create could not finish: nothing was charged in this
// run. A never-sent claim is released (so the pay page isn't held
// `in_flight`); a stamped one waits for a later sweep.
async function checkFailed(ctx, item, what, err) {
  console.warn(`[autopay] ${what} for ${item.claim.invoice_id} failed: ${err && err.message}`);
  ctx.result.unknown++;
  if (!item.claim.charge_sent_at) await releaseClaim(ctx, item.claim);
}

// Don't charge. `item.chargedWith` is the enrollment a previous create (if
// any) was sent with.
async function standDown(ctx, item, reason) {
  const { env, stripe, result } = ctx;
  const { claim } = item;
  if (!claim.charge_sent_at) {
    await releaseClaim(ctx, claim);
    result.yielded++;
    return;
  }
  // A create may have reached Stripe: never release (a new claim for this
  // invoice could then charge on top of it). Ask Stripe what happened.
  let found = null;
  try {
    found = await findAutopayIntent(stripe, claim, item.chargedWith);
  } catch (err) {
    console.warn(`[autopay] reconcile list for claim ${claim.id} failed: ${err.message}`);
    result.unknown++;
    return;
  }
  if (found) return handleIntent(ctx, { ...item, stripe, quiet: QUIET_REASONS.has(reason) }, found, cardOf(item.chargedWith));
  const flipped = await settleClaim(env, claim, {
    status: 'failed',
    failure_code: 'unknown',
    failure_message: `not replayed (${reason}); no PaymentIntent found for the claim`,
  });
  if (!flipped) return;
  result.failed++;
  await notifyProblem(ctx, { claim, enrollment: item.enrollment, invoice: item.invoice, reason: 'unknown', emailCustomer: false });
}

// The card on file is gone (missing, detached or moved to another Customer).
async function cardMissing(ctx, item) {
  const { env, stripe, result } = ctx;
  const { claim, enrollment, invoice } = item;
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
}

// Steps 2–6 for one claimed invoice, first attempt or replay (a claim with
// charge_sent_at: a previous run may already have sent the create). Every
// path to paymentIntents.create runs the gate in the file header.
async function processClaim(ctx, item) {
  const { env, stripe, result, now } = ctx;
  const { claim } = item;
  const chargedWith = item.enrollment;
  const stripeAccount = chargedWith.stripe_account_id;
  const nowSec = Math.floor(now.getTime() / 1000);
  const base = { ...item, chargedWith };

  // a. Mutual exclusion with the pay page: open sessions first, then complete.
  let completedSessions;
  try {
    if ((await expireOpenSessions(stripe, stripeAccount, claim.invoice_id, nowSec)) === 'completed') {
      return standDown(ctx, base, 'pay_page_pending');
    }
    completedSessions = await completedInvoiceSessions(stripe, stripeAccount, claim.invoice_id, nowSec);
  } catch (err) {
    return checkFailed(ctx, base, 'session check', err);
  }

  // Refresh the card (account updater) and prove it's still attached.
  let pm = null;
  try {
    if (chargedWith.payment_method_id) pm = await stripe.paymentMethods.retrieve(chargedWith.payment_method_id, {}, { stripeAccount });
  } catch (err) {
    if (isUnknownOutcome(err)) return checkFailed(ctx, base, 'card check', err);
    pm = null;
  }
  const pmCustomer = pm && (typeof pm.customer === 'object' && pm.customer ? pm.customer.id : pm.customer);
  const cardOk = !!(pm && pm.card && pmCustomer === chargedWith.stripe_customer_id);

  // b. The live re-read, judged as late as possible before the create.
  let live;
  try {
    live = await loadLive(env, claim, chargedWith);
  } catch (err) {
    return checkFailed(ctx, base, 'live re-read', err);
  }
  const verdict = liveVerdict({ claim, snapshot: chargedWith, live, completedSessions, now });
  const current = { ...base, invoice: verdict.invoice || item.invoice, enrollment: verdict.enrollment || chargedWith };
  if (!verdict.charge) return standDown(ctx, current, verdict.reason);

  if (!cardOk) {
    if (claim.charge_sent_at) {
      // A previous create may have gone through before the card vanished.
      let found = null;
      try {
        found = await findAutopayIntent(stripe, claim, chargedWith);
      } catch (err) {
        return checkFailed(ctx, current, 'reconcile list', err);
      }
      if (found) return handleIntent(ctx, { ...current, stripe }, found, cardOf(chargedWith));
    }
    return cardMissing(ctx, current);
  }
  const card = pm.card;
  const enrollment = current.enrollment;
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

  // c. Stamp, then charge. No stamp on a still-claimed row → no create.
  let marked;
  try {
    marked = await store.markChargeSent(env, claim, { now });
  } catch (err) {
    console.warn(`[autopay] charge stamp for ${claim.invoice_id} failed: ${err.message}`);
    result.unknown++;
    return;
  }
  if (!marked) return; // another run settled or released it meanwhile
  const invoice = current.invoice;
  const charging = { ...current, claim: marked };

  let pi;
  try {
    const number = String(invoice.number || '').replace(/\s+/g, ' ').trim().slice(0, 60);
    pi = await stripe.paymentIntents.create(
      {
        amount: marked.amount_cents,
        currency: 'usd',
        customer: chargedWith.stripe_customer_id,
        payment_method: chargedWith.payment_method_id,
        off_session: true,
        confirm: true,
        payment_method_types: ['card'],
        description: number ? `Invoice ${number}` : 'Invoice payment',
        metadata: { invoiceId: invoice.id, source: 'autopay', tr_enrollment: chargedWith.id },
      },
      { stripeAccount, idempotencyKey: chargeKey(invoice.id) }
    );
  } catch (err) {
    if (isUnknownOutcome(err)) {
      console.warn(`[autopay] charge for ${invoice.id} outcome unknown: ${err.message}`);
      result.unknown++;
      return;
    }
    return onFailed(ctx, { ...charging, failure: failureFromError(err), stripe });
  }
  return handleIntent(ctx, { ...charging, stripe }, pi, card);
}

// Resolve a stamped claim that never settled by listing the customer's
// PaymentIntents (no new charge is ever created here).
async function resolveByList(ctx, item) {
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
  if (found) return handleIntent(ctx, { ...item, stripe }, found, cardOf(enrollment));
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
  if (claim.payment_intent_id) {
    try {
      const pi = await stripe.paymentIntents.retrieve(claim.payment_intent_id, {}, { stripeAccount: enrollment.stripe_account_id });
      return handleIntent(ctx, { ...item, stripe }, pi, cardOf(enrollment));
    } catch (err) {
      console.warn(`[autopay] retrieve ${claim.payment_intent_id} failed: ${err.message}`);
      result.unknown++;
      return;
    }
  }
  if (claim.charge_sent_at && ageMs >= UNKNOWN_LIST_AFTER_MS) return resolveByList(ctx, item);
  // Never sent: a fresh, fully gated attempt (or a release). Stamped: the
  // create is replayed (same key, same amount) only if the live state still
  // matches the claim; otherwise standDown reconciles with Stripe.
  return processClaim(ctx, item);
}

async function housekeep(ctx, { liveEnrollments, plansByKey, now }) {
  const { env, stripe, result } = ctx;
  const { revokePlanGone, expirePending } = selectHousekeeping({
    enrollments: liveEnrollments,
    plansByKey,
    now,
    planIdOk: (id) => ID_RE.test(String(id)),
  });
  const revokedNow = new Set();
  for (const e of revokePlanGone) {
    // Confirm with a targeted read before revoking: a bulk read that came
    // back short must never look like "plan missing". A failed read skips
    // the revoke (fail closed); the next sweep looks again.
    let plan;
    try {
      plan = await store.fetchPlanForUser(env, e.user_id, e.recurring_invoice_id);
    } catch (err) {
      console.error(`[autopay] housekeeping: plan ${e.recurring_invoice_id} re-read failed, not revoking ${e.id}:`, err.message);
      continue;
    }
    if (!planGoneFor(e, plan)) {
      plansByKey.set(planKey(e.user_id, e.recurring_invoice_id), plan);
      continue;
    }
    revokedNow.add(e.id);
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
  return revokedNow;
}

// The earliest due date the sweep can still act on: a window closes 7 days
// after its due date (one spare day for the 14:00 UTC start).
function dueFromFor(now) {
  return new Date(now.getTime() - (WINDOW_DAYS + 1) * DAY_MS).toISOString().slice(0, 10);
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

  // Every sweep-wide read is paginated to the end (store.sbGetAll) and
  // throws on any error, which aborts the run before anything is charged or
  // revoked.
  const [liveEnrollments, claimedRows] = await Promise.all([
    store.fetchLiveEnrollments(env),
    store.fetchClaimedCharges(env),
  ]);
  if (!liveEnrollments.length && !claimedRows.length) return result;

  // Claims may reference enrollments that are no longer live.
  const enrollmentById = new Map(liveEnrollments.map((e) => [e.id, e]));
  const missingIds = [...new Set(claimedRows.map((c) => c.enrollment_id).filter((id) => !enrollmentById.has(id)))];
  if (missingIds.length) {
    for (const e of await store.fetchEnrollmentsByIds(env, missingIds)) enrollmentById.set(e.id, e);
  }

  const allEnrollments = [...enrollmentById.values()];
  const userIds = [...new Set(allEnrollments.map((e) => e.user_id))];
  const planIds = [...new Set(allEnrollments.map((e) => e.recurring_invoice_id))];
  const [accountsByUser, settingsByUser, planRows, invoiceRows, charges] = await Promise.all([
    store.fetchStripeAccountsForUsers(env, userIds),
    store.fetchSettingsForUsers(env, userIds),
    store.fetchPlansByIds(env, userIds, planIds),
    store.fetchPlanInvoices(env, userIds, planIds, { dueFrom: dueFromFor(now) }),
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

  // 3. Resume claims earlier runs left open. Eligibility is NOT judged from
  // this run's snapshot: processClaim re-reads everything right before any
  // create or replay.
  for (const claim of claimedRows) {
    const enrollment = enrollmentById.get(claim.enrollment_id);
    const invoice = invoiceByKey.get(`${claim.user_id}|${claim.invoice_id}`) || { id: claim.invoice_id };
    if (!enrollment) continue;
    try {
      await resumeClaim(ctx, { claim, enrollment, invoice }, { nowMs: now.getTime() });
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
      store.fetchPlanInvoices(env, userIds, planIds, { dueFrom: dueFromFor(now) }),
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
