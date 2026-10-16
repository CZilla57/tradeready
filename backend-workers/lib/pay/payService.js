// The pay page's server side (Phase 24 spec §4.4): view, checkout and
// autopay-off. Routes in src/routes/pay/* are thin shells around these, so
// every branch is testable with a fake Stripe client and a fake Supabase.
//
// Money safety, all enforced here and never trusted from the browser:
//   - The token binds owner + invoice (or plan / enrollment). Every lookup is
//     scoped by the token's user id.
//   - The charge is min(token amount, LIVE ledger balance), computed with
//     paymentMath.js at click time. A paid invoice can't be paid again.
//   - At most one open Checkout Session per invoice: older open sessions
//     (including legacy Payment Link sessions) are expired first.
//   - A checkout is also refused (409 in_flight) while a COMPLETED Checkout
//     Session for the invoice has no stripe_<session id> ledger entry yet
//     (paid, webhook not landed), so a second payment can't stack on it.
//   - A checkout is refused while an autopay charge for the invoice is in
//     flight (claimed), and re-checks for a fresh claim after creating its
//     session (mutual exclusion with the sweep, which expires open sessions
//     after claiming).
//   - Consent: the server re-renders the authorization and stores exactly
//     that text, version, time, IP and user agent. A stale version or a
//     changed amount is a 409 "please reload", never a silent record.
//   - Card data never touches TradeReady: entry is on Stripe Checkout.
//   - Tips (Phase 28, tips spec §4): offered only on a full-balance payment
//     of an unpaid invoice when the owner's settings say tipsEnabled; the
//     setting is re-read at checkout, the tip is capped at the invoice amount
//     being paid, and it rides as a SEPARATE "Tip" line with server-set
//     metadata (tr_tip_cents) so the webhook books it apart from the invoice.
//
// Every result is { status, body }.

const { balanceDue, isFullyPaid, PAID_EPSILON } = require('../paymentMath.js');
const { verifyPayToken, mintManageToken, mintSetupToken, payPageUrl, payPublicBase, tokenCharge } = require('./payToken.js');
const { invoiceView, receiptFromSession, setupView, manageView } = require('./payView.js');
const { tipsEnabled, tipBaseCents, tipsBlock, parseTipCents } = require('./tips.js');
const { evaluateInvoiceOffer, evaluatePlanSetup, planCents, isPlanOfferable, activeEnrollmentForPlan } = require('../autopay/offer.js');
const { renderConsent, checkoutSubmitMessage, checkoutSetupMessage, CONSENT_VERSION } = require('../autopay/consentText.js');
const { dollarsToCents, clean } = require('../autopay/format.js');
const { revokeEnrollment } = require('../autopay/revoke.js');
const { buildAutopayOffEmail, ownerAutopayOffAlert } = require('../autopay/emails.js');
const { alertOwner, sendCustomerEmail } = require('../ownerAlert.js');
const { isPlausibleEmail } = require('../selectInvoicesToRemind.js');
const store = require('../autopay/store.js');
const { completedInvoiceSessions } = require('../autopay/sessions.js');

const MESSAGES = {
  bad_request: 'This link is incomplete.',
  invalid: 'This link is no longer valid.',
  not_ready: "This invoice isn't ready yet. Please try again in a few minutes.",
  gone: 'This link is no longer valid.',
  unavailable: "Online payment isn't available.",
  expired: 'This setup link has expired.',
  paid: 'This invoice is already paid.',
  in_flight: 'A payment for this invoice is being processed. Please check back in a few minutes.',
  changed: 'This page is out of date. Please reload.',
  maybe_paid: 'This invoice may have just been paid. Reload.',
  busy: 'Please try again in a moment.',
  tips_off: 'Tips are no longer offered. Please reload.',
  tip_invalid: "Please check the tip amount. It can't be more than the invoice.",
  server_error: 'Something went wrong. Please try again.',
};
const STATUS = {
  bad_request: 400, invalid: 404, not_ready: 409, gone: 410, unavailable: 410, expired: 410,
  paid: 409, in_flight: 409, changed: 409, maybe_paid: 409, busy: 409, tips_off: 409, tip_invalid: 400,
  server_error: 500,
};

function fail(code, businessName) {
  const body = { error: MESSAGES[code], code };
  if (businessName) body.businessName = clean(businessName, 120);
  return { status: STATUS[code], body };
}

const SESSION_ID_RE = /^cs_[A-Za-z0-9_]{1,200}$/;
const TEN_MINUTES_MS = 10 * 60 * 1000;
const DAY_SEC = 86400;

function toCents(dollars) {
  return Math.round(Number(dollars) * 100);
}

function balanceCentsOf(invoice) {
  return Math.max(0, Math.round(balanceDue(invoice) * 100));
}

// Checkout sessions expire between 30 min and 24 h after creation. The value
// is a function of the 10-minute idempotency bucket (bucket start + 41 min →
// 31–41 min from now), so a double-click within the bucket sends identical
// parameters and Stripe replays the first session instead of erroring.
function expiresAtFor(bucket) {
  return Math.floor((bucket * TEN_MINUTES_MS) / 1000) + 41 * 60;
}

async function loadInvoiceContext(env, userId, invoiceId) {
  const [settings, invoiceRow, accountId] = await Promise.all([
    store.fetchSettings(env, userId),
    store.fetchInvoiceForUser(env, userId, invoiceId),
    store.fetchStripeAccountId(env, userId),
  ]);
  let planRow = null;
  let enrollments = [];
  const planId = invoiceRow && invoiceRow.data && invoiceRow.data.recurringInvoiceId;
  if (planId && typeof planId === 'string') {
    [planRow, enrollments] = await Promise.all([
      store.fetchPlanForUser(env, userId, planId),
      store.fetchEnrollmentsForPlan(env, userId, planId),
    ]);
  }
  return { settings, invoiceRow, accountId, planRow, enrollments };
}

// No row for (token owner, invoice). If the id exists under ANOTHER owner the
// token can never be valid (404, spec §4.2 "u exposure"); otherwise the
// owner's device just hasn't synced it yet (409 not_ready, retry later).
async function missingInvoice(env, invoiceId, biz) {
  const rows = await store.sbGet(env, `invoices?id=eq.${encodeURIComponent(invoiceId)}&select=user_id`);
  return rows.length ? fail('invalid') : fail('not_ready', biz);
}

// ── GET /api/pay/view ──────────────────────────────────────────────────────

async function viewInvoice(env, { stripe, token, sessionId, nowSec }) {
  const v = verifyPayToken(env.PAY_LINK_SIGNING_SECRET, token, { expectKind: 'p', nowSec });
  if (!v.ok) return fail('invalid');
  const { u: userId, i: invoiceId } = v.payload;
  const ctx = await loadInvoiceContext(env, userId, invoiceId);
  const biz = ctx.settings.businessName;
  if (!ctx.invoiceRow) return missingInvoice(env, invoiceId, biz);
  if (ctx.invoiceRow.deleted) return fail('gone', biz);

  const invoice = { ...ctx.invoiceRow.data, id: invoiceId };
  const paid = isFullyPaid(invoice);

  let receipt = null;
  if (sessionId && SESSION_ID_RE.test(sessionId) && ctx.accountId && stripe) {
    try {
      const session = await stripe.checkout.sessions.retrieve(
        sessionId,
        { expand: ['payment_intent.latest_charge'] },
        { stripeAccount: ctx.accountId }
      );
      receipt = receiptFromSession(session, invoiceId);
    } catch (err) {
      console.error('[pay/view] session retrieve failed:', err.message);
    }
  }

  if (!paid && !ctx.accountId) return fail('unavailable', biz);

  const balanceCents = balanceCentsOf(invoice);
  const { cents: chargeCents, depositCents } = tokenCharge(v.payload, balanceCents);
  const { offer, active } = evaluateInvoiceOffer({
    invoice,
    planRow: ctx.planRow,
    enrollments: ctx.enrollments,
    isFullBalance: chargeCents === balanceCents,
  });
  const tipBase = tipBaseCents({ settings: ctx.settings, paid, payload: v.payload, balanceCents, chargeCents });
  return {
    status: 200,
    body: invoiceView({
      businessName: biz,
      invoice,
      paid,
      balanceCents,
      depositCents,
      planRow: ctx.planRow,
      offer,
      activeEnrollment: active,
      receipt,
      tips: tipsBlock(tipBase),
    }),
  };
}

async function loadPlanContext(env, userId, planId) {
  const [settings, planRow, accountId, enrollments] = await Promise.all([
    store.fetchSettings(env, userId),
    store.fetchPlanForUser(env, userId, planId),
    store.fetchStripeAccountId(env, userId),
    store.fetchEnrollmentsForPlan(env, userId, planId),
  ]);
  return { settings, planRow, accountId, enrollments };
}

// A setup token is bound to the plan's customer at mint time (`c`), so a plan
// reassigned within the 7-day window can't be set up by its old customer.
function setupTokenMatchesPlan(payload, planRow) {
  return !!planRow && !!planRow.data && (!payload.c || payload.c === planRow.data.customerId);
}

async function viewSetup(env, { token, nowSec }) {
  const v = verifyPayToken(env.PAY_LINK_SIGNING_SECRET, token, { expectKind: 's', nowSec });
  if (!v.ok && v.reason !== 'expired') return fail('invalid');
  const { u: userId, r: planId } = v.payload;
  const ctx = await loadPlanContext(env, userId, planId);
  const biz = ctx.settings.businessName;
  if (!v.ok) return fail('expired', biz);
  const setup = evaluatePlanSetup({ planRow: ctx.planRow, enrollments: ctx.enrollments });
  if (!setup || !setupTokenMatchesPlan(v.payload, ctx.planRow)) return fail('invalid', biz);
  if (!ctx.accountId) return fail('unavailable', biz);
  return { status: 200, body: setupView({ businessName: biz, planRow: ctx.planRow, amountCents: setup.amountCents, isUpdate: setup.isUpdate }) };
}

// A manage link from an older email keeps working after the customer saved a
// new card: a `replaced` enrollment resolves to the plan's current active one
// for the same customer.
async function resolveManagedEnrollment(env, userId, enrollmentId) {
  const enrollment = await store.fetchEnrollmentById(env, userId, enrollmentId);
  if (!enrollment || enrollment.status !== 'replaced') return enrollment;
  const siblings = await store.fetchEnrollmentsForPlan(env, userId, enrollment.recurring_invoice_id);
  return siblings.find((e) => e.status === 'active' && e.customer_id === enrollment.customer_id) || enrollment;
}

async function viewManage(env, { token, nowSec }) {
  const v = verifyPayToken(env.PAY_LINK_SIGNING_SECRET, token, { expectKind: 'm', nowSec });
  if (!v.ok) return fail('invalid');
  const userId = v.payload.u;
  const enrollment = await resolveManagedEnrollment(env, userId, v.payload.e);
  if (!enrollment) return fail('invalid');
  const [settings, planRow, accountId] = await Promise.all([
    store.fetchSettings(env, userId),
    store.fetchPlanForUser(env, userId, enrollment.recurring_invoice_id),
    store.fetchStripeAccountId(env, userId),
  ]);
  let setupUrl = null;
  if (accountId && isPlanOfferable(planRow) && planRow.data.customerId === enrollment.customer_id) {
    setupUrl = payPageUrl(env, 's', mintSetupToken(env.PAY_LINK_SIGNING_SECRET, { userId, planId: planRow.id, customerId: enrollment.customer_id, nowSec }));
  }
  return { status: 200, body: manageView({ businessName: settings.businessName, planRow, enrollment, setupUrl }) };
}

async function view(env, { stripe, query, nowSec = Math.floor(Date.now() / 1000) }) {
  if (!env.PAY_LINK_SIGNING_SECRET) return fail('invalid');
  if (query.t) return viewInvoice(env, { stripe, token: String(query.t), sessionId: query.session_id ? String(query.session_id) : null, nowSec });
  if (query.s) return viewSetup(env, { token: String(query.s), nowSec });
  if (query.m) return viewManage(env, { token: String(query.m), nowSec });
  return fail('bad_request');
}

// ── POST /api/pay/checkout ─────────────────────────────────────────────────

class CheckoutConflict extends Error {}

// Expire every other OPEN session for this invoice on the owner's account
// from the last 24 h (Checkout's maximum lifetime), so at most one can be
// paid. Sessions created under `idemKey` are the caller's own double-click
// and are left for Stripe's idempotent replay. An expire error means the
// session completed meanwhile → CheckoutConflict (409 "may have just been
// paid").
// A session minted under `idemKey` itself or under one of its re-mint keys
// (`<idemKey>:r...`, see createSession) is the caller's own.
function isOwnSession(session, idemKey) {
  const k = session.metadata && session.metadata.tr_idem;
  return !!k && (k === idemKey || k.startsWith(`${idemKey}:r`));
}

async function expireOtherOpenSessions(stripe, accountId, invoiceId, idemKey, nowSec) {
  let startingAfter;
  for (let page = 0; page < 10; page++) {
    const list = await stripe.checkout.sessions.list(
      { status: 'open', created: { gte: nowSec - DAY_SEC }, limit: 100, ...(startingAfter ? { starting_after: startingAfter } : {}) },
      { stripeAccount: accountId }
    );
    const data = (list && list.data) || [];
    for (const s of data) {
      if (!s.metadata || s.metadata.invoiceId !== invoiceId) continue;
      if (isOwnSession(s, idemKey)) continue;
      try {
        await stripe.checkout.sessions.expire(s.id, {}, { stripeAccount: accountId });
      } catch (err) {
        console.warn(`[pay/checkout] expire ${s.id} failed: ${err.message}`);
        throw new CheckoutConflict(err.message);
      }
    }
    if (!list || !list.has_more || !data.length) return;
    startingAfter = data[data.length - 1].id;
  }
}

// One Stripe Customer per (owner, TradeReady customer) on the connected
// account, created lazily (spec D5).
async function ensureStripeCustomer(env, stripe, { userId, customerId, accountId, name, email, bucket }) {
  const existing = await store.findReusableStripeCustomer(env, userId, customerId, accountId);
  if (existing) return existing;
  const created = await stripe.customers.create(
    {
      ...(clean(name, 200) ? { name: clean(name, 200) } : {}),
      ...(isPlausibleEmail(email) ? { email } : {}),
      metadata: { tr_user: userId, tr_customer: customerId },
    },
    { stripeAccount: accountId, idempotencyKey: `tr-cus:${userId}:${customerId}:${bucket}` }
  );
  return created.id;
}

// The pending consent record (spec §3.1). A double-click inside the same
// 10-minute bucket reuses the row it already wrote, so the session
// parameters (metadata, custom_text manage link) stay identical and Stripe
// replays the first session.
async function ensurePendingEnrollment(env, { userId, accountId, planRow, stripeCustomerId, amountCents, consentText, ip, userAgent, bucket }) {
  const bucketStartIso = new Date(bucket * TEN_MINUTES_MS).toISOString();
  const recent = await store.sbGet(
    env,
    `autopay_enrollments?user_id=eq.${encodeURIComponent(userId)}&recurring_invoice_id=eq.${encodeURIComponent(planRow.id)}` +
      `&customer_id=eq.${encodeURIComponent(planRow.data.customerId)}&status=eq.pending` +
      `&consented_at=gte.${encodeURIComponent(bucketStartIso)}&select=*&order=created_at.desc&limit=5`
  );
  const reusable = recent.find(
    (e) => e.consent_text === consentText && e.max_amount_cents === amountCents && e.stripe_customer_id === stripeCustomerId && e.stripe_account_id === accountId
  );
  if (reusable) return reusable;
  return store.insertEnrollment(env, {
    user_id: userId,
    stripe_account_id: accountId,
    customer_id: planRow.data.customerId,
    recurring_invoice_id: planRow.id,
    stripe_customer_id: stripeCustomerId,
    max_amount_cents: amountCents,
    status: 'pending',
    consent_version: CONSENT_VERSION,
    consent_text: consentText,
    consented_at: new Date().toISOString(),
    consent_ip: clean(ip, 64) || null,
    consent_user_agent: clean(userAgent, 512) || null,
  });
}

const REMINT_MAX = 3;

// Create the Checkout Session, and make sure what comes back is payable.
//
// Stripe replays the CACHED original response for a repeated idempotency
// key, and that response says `open` even after the session was expired
// (the customer switched tip A -> B -> A inside one 10-minute bucket, or
// another tab / the autopay sweep expired it). So an `open` create response
// is checked against the session's live status. An expired session is
// replaced under a key that names the dead session
// (`<key>:r<last 12 chars of its id>`; short because Stripe caps keys at 255
// characters): deterministic, so two identical requests racing on the same
// dead session still share one new session, and distinct per dead session,
// so a later replay of the SAME base key never lands on a session this chain
// already killed. A completed one is returned as-is
// (the caller answers 409 "may have just been paid").
async function createSession(stripe, params, { accountId, idemKey }) {
  let key = idemKey;
  let session;
  for (let attempt = 0; attempt <= REMINT_MAX; attempt++) {
    const send = attempt === 0 ? params : { ...params, metadata: { ...params.metadata, tr_idem: key } };
    session = await stripe.checkout.sessions.create(send, { stripeAccount: accountId, idempotencyKey: key });
    if (!session) return session;
    let status = session.status;
    if (status === 'open') {
      try {
        const live = await stripe.checkout.sessions.retrieve(session.id, {}, { stripeAccount: accountId });
        if (live && live.status) status = live.status;
      } catch (err) {
        // Can't confirm: fall back to the create response rather than
        // blocking a payment the customer may be able to make.
        console.warn(`[pay/checkout] live status of ${session.id} unavailable: ${err.message}`);
      }
    }
    if (status !== 'expired') return status === session.status ? session : { ...session, status };
    key = `${key}:r${session.id.slice(-12)}`;
  }
  throw new Error(`checkout session still expired after ${REMINT_MAX} re-mints (${idemKey})`);
}

async function checkoutInvoice(env, { stripe, body, ip, userAgent, nowMs }) {
  const nowSec = Math.floor(nowMs / 1000);
  const v = verifyPayToken(env.PAY_LINK_SIGNING_SECRET, String(body.t), { expectKind: 'p', nowSec });
  if (!v.ok) return fail('invalid');
  const { u: userId, i: invoiceId } = v.payload;
  const optIn = !!body.autopay;

  const [ctx, charges] = await Promise.all([
    loadInvoiceContext(env, userId, invoiceId),
    store.fetchChargesForInvoice(env, userId, invoiceId),
  ]);
  const biz = ctx.settings.businessName;
  if (!ctx.invoiceRow) return missingInvoice(env, invoiceId, biz);
  if (ctx.invoiceRow.deleted) return fail('gone', biz);
  const invoice = { ...ctx.invoiceRow.data, id: invoiceId };
  if (isFullyPaid(invoice)) return fail('paid', biz);
  if (!ctx.accountId) return fail('unavailable', biz);

  // The amount: never more than the live balance, never a client number.
  const balanceCents = balanceCentsOf(invoice);
  const { cents } = tokenCharge(v.payload, balanceCents);
  if (cents <= 0 || balanceCents / 100 <= PAID_EPSILON) return fail('paid', biz);
  if (charges.some((ch) => ch.status === 'claimed')) return fail('in_flight', biz);

  // The tip (Phase 28, spec §4.2), all before any Stripe call: re-read the
  // owner's setting (it may have been turned off since the page loaded),
  // refuse it on anything but a full-balance payment (a deposit), refuse it
  // when the amount the page based it on is stale, and cap it at the
  // invoice amount being paid. Without a tip nothing below changes.
  const tip = parseTipCents(body.tipCents);
  if (!tip.ok) return fail('tip_invalid', biz);
  const tipCents = tip.cents;
  if (tipCents > 0) {
    if (!tipsEnabled(ctx.settings)) return fail('tips_off', biz);
    if (tipBaseCents({ settings: ctx.settings, paid: false, payload: v.payload, balanceCents, chargeCents: cents }) === null) return fail('tips_off', biz);
    if (body.baseCents !== undefined && body.baseCents !== cents) return fail('changed', biz);
    if (tipCents > cents) return fail('tip_invalid', biz);
  }

  let offer = null;
  let consent = null;
  if (optIn) {
    ({ offer } = evaluateInvoiceOffer({ invoice, planRow: ctx.planRow, enrollments: ctx.enrollments, isFullBalance: cents === balanceCents }));
    const a = body.autopay || {};
    if (!offer || a.consentVersion !== CONSENT_VERSION || dollarsToCents(a.amount) !== offer.amountCents) return fail('changed', biz);
    consent = renderConsent({
      businessName: biz,
      planDescription: ctx.planRow.data.description,
      amountCents: offer.amountCents,
      cadence: ctx.planRow.data.cadence,
      isUpdate: offer.isUpdate,
    });
  }

  const bucket = Math.floor(nowMs / TEN_MINUTES_MS);
  // The tip is part of the key, so a double-click replays the same session
  // and a changed tip mints a new one (and expires the old one below).
  const idemKey = `tr-co:${invoiceId}:${cents}${tipCents > 0 ? `:t${tipCents}` : ''}:${optIn ? 'a' : 'n'}:${bucket}`;
  try {
    await expireOtherOpenSessions(stripe, ctx.accountId, invoiceId, idemKey, nowSec);
  } catch (err) {
    if (err instanceof CheckoutConflict) return fail('maybe_paid', biz);
    throw err;
  }

  // A payment that completed on Stripe but isn't in the ledger yet (the
  // webhook lags) hasn't reduced the balance this click was priced from, so
  // a second session would take the customer's money twice. Listed AFTER the
  // open-session pass above (a session completing between the two is still
  // seen as complete), with the same helper the autopay sweep uses.
  const booked = new Set((invoice.payments || []).map((p) => p && p.id));
  const completed = await completedInvoiceSessions(stripe, ctx.accountId, invoiceId, nowSec);
  if (completed.some((s) => !booked.has(`stripe_${s.id}`))) return fail('in_flight', biz);

  let enrollment = null;
  let stripeCustomerId = null;
  let manageUrl = null;
  if (optIn) {
    stripeCustomerId = await ensureStripeCustomer(env, stripe, {
      userId,
      customerId: ctx.planRow.data.customerId,
      accountId: ctx.accountId,
      name: invoice.customer || ctx.planRow.data.customerName,
      email: invoice.email,
      bucket,
    });
    enrollment = await ensurePendingEnrollment(env, {
      userId, accountId: ctx.accountId, planRow: ctx.planRow, stripeCustomerId,
      amountCents: offer.amountCents, consentText: consent.text, ip, userAgent, bucket,
    });
    manageUrl = payPageUrl(env, 'm', mintManageToken(env.PAY_LINK_SIGNING_SECRET, { userId, enrollmentId: enrollment.id }));
  }

  const number = clean(invoice.number, 60);
  const name = number ? `Invoice ${number}` : 'Invoice payment';
  const base = payPublicBase(env);
  const t = encodeURIComponent(String(body.t));
  const params = {
    mode: 'payment',
    payment_method_types: ['card'],
    line_items: [
      { price_data: { currency: 'usd', unit_amount: cents, product_data: { name } }, quantity: 1 },
      ...(tipCents > 0 ? [{ price_data: { currency: 'usd', unit_amount: tipCents, product_data: { name: 'Tip' } }, quantity: 1 }] : []),
    ],
    metadata: {
      invoiceId,
      tr_kind: 'invoice',
      tr_invoice_cents: String(cents),
      ...(tipCents > 0 ? { tr_tip_cents: String(tipCents) } : {}),
      tr_idem: idemKey,
      ...(enrollment ? { tr_enrollment: enrollment.id } : {}),
    },
    payment_intent_data: {
      metadata: { invoiceId, source: 'pay_page' },
      description: name,
      ...(enrollment ? { setup_future_usage: 'off_session' } : {}),
    },
    ...(stripeCustomerId ? { customer: stripeCustomerId } : {}),
    expires_at: expiresAtFor(bucket),
    success_url: `${base}?t=${t}&session_id={CHECKOUT_SESSION_ID}`,
    cancel_url: `${base}?t=${t}`,
    ...(enrollment
      ? { custom_text: { submit: { message: checkoutSubmitMessage({ businessName: biz, planDescription: ctx.planRow.data.description, amountCents: offer.amountCents, manageUrl }) } } }
      : {}),
  };

  const session = await createSession(stripe, params, { accountId: ctx.accountId, idemKey });
  if (!session || session.status === 'complete') return fail('maybe_paid', biz);

  // Mutual exclusion with the autopay sweep (lib/autopay/runAutopayCharges.js
  // header): our session now exists, so look again for a claim the sweep may
  // have written since the first check. If one appeared, withdraw the session
  // so the customer can't pay on top of the automatic charge.
  const known = new Set(charges.map((ch) => ch.id));
  const fresh = (await store.fetchChargesForInvoice(env, userId, invoiceId))
    .filter((ch) => !known.has(ch.id) && (ch.status === 'claimed' || ch.status === 'succeeded'));
  if (fresh.length) {
    try {
      await stripe.checkout.sessions.expire(session.id, {}, { stripeAccount: ctx.accountId });
    } catch (err) {
      console.warn(`[pay/checkout] withdraw ${session.id} failed: ${err.message}`);
    }
    return fail(fresh.some((ch) => ch.status === 'claimed') ? 'in_flight' : 'maybe_paid', biz);
  }

  if (enrollment && enrollment.checkout_session_id !== session.id) {
    await store.updateEnrollments(env, `id=eq.${encodeURIComponent(enrollment.id)}&status=eq.pending`, { checkout_session_id: session.id });
  }
  return { status: 200, body: { url: session.url } };
}

async function checkoutSetup(env, { stripe, body, ip, userAgent, nowMs }) {
  const nowSec = Math.floor(nowMs / 1000);
  const v = verifyPayToken(env.PAY_LINK_SIGNING_SECRET, String(body.s), { expectKind: 's', nowSec });
  if (!v.ok && v.reason !== 'expired') return fail('invalid');
  const { u: userId, r: planId } = v.payload;
  const ctx = await loadPlanContext(env, userId, planId);
  const biz = ctx.settings.businessName;
  if (!v.ok) return fail('expired', biz);
  const setup = evaluatePlanSetup({ planRow: ctx.planRow, enrollments: ctx.enrollments });
  if (!setup || !setupTokenMatchesPlan(v.payload, ctx.planRow)) return fail('invalid', biz);
  if (!ctx.accountId) return fail('unavailable', biz);
  if (body.consentVersion !== CONSENT_VERSION || dollarsToCents(body.amount) !== setup.amountCents) return fail('changed', biz);

  const planRow = ctx.planRow;
  const consent = renderConsent({
    businessName: biz,
    planDescription: planRow.data.description,
    amountCents: setup.amountCents,
    cadence: planRow.data.cadence,
    isUpdate: setup.isUpdate,
  });
  const bucket = Math.floor(nowMs / TEN_MINUTES_MS);
  const idemKey = `tr-su:${planId}:${planRow.data.customerId}:${setup.amountCents}:${bucket}`;
  const customerEmail = await store.fetchCustomerEmail(env, userId, planRow.data.customerId).catch(() => null);
  const stripeCustomerId = await ensureStripeCustomer(env, stripe, {
    userId,
    customerId: planRow.data.customerId,
    accountId: ctx.accountId,
    name: planRow.data.customerName,
    email: customerEmail,
    bucket,
  });
  const enrollment = await ensurePendingEnrollment(env, {
    userId, accountId: ctx.accountId, planRow, stripeCustomerId,
    amountCents: setup.amountCents, consentText: consent.text, ip, userAgent, bucket,
  });
  const manageToken = mintManageToken(env.PAY_LINK_SIGNING_SECRET, { userId, enrollmentId: enrollment.id });
  const manageUrl = payPageUrl(env, 'm', manageToken);
  const base = payPublicBase(env);
  const params = {
    mode: 'setup',
    customer: stripeCustomerId,
    payment_method_types: ['card'],
    setup_intent_data: { metadata: { tr_enrollment: enrollment.id } },
    metadata: { tr_kind: 'autopay_setup', tr_enrollment: enrollment.id, tr_idem: idemKey },
    expires_at: expiresAtFor(bucket),
    success_url: `${base}?m=${encodeURIComponent(manageToken)}&done=1`,
    cancel_url: `${base}?s=${encodeURIComponent(String(body.s))}`,
    custom_text: { submit: { message: checkoutSetupMessage({ businessName: biz, planDescription: planRow.data.description, amountCents: setup.amountCents, manageUrl }) } },
  };
  const session = await createSession(stripe, params, { accountId: ctx.accountId, idemKey });
  if (!session || session.status === 'complete') return fail('changed', biz);
  if (enrollment.checkout_session_id !== session.id) {
    await store.updateEnrollments(env, `id=eq.${encodeURIComponent(enrollment.id)}&status=eq.pending`, { checkout_session_id: session.id });
  }
  return { status: 200, body: { url: session.url } };
}

async function checkout(env, { stripe, body, ip, userAgent, nowMs = Date.now() }) {
  if (!env.PAY_LINK_SIGNING_SECRET) return fail('invalid');
  if (!body || typeof body !== 'object') return fail('bad_request');
  if (typeof body.t === 'string' && body.t) return checkoutInvoice(env, { stripe, body, ip, userAgent, nowMs });
  if (typeof body.s === 'string' && body.s) return checkoutSetup(env, { stripe, body, ip, userAgent, nowMs });
  return fail('bad_request');
}

// ── POST /api/pay/autopay-off ──────────────────────────────────────────────

async function autopayOff(env, { stripe, body, nowSec = Math.floor(Date.now() / 1000) }) {
  if (!env.PAY_LINK_SIGNING_SECRET) return fail('invalid');
  const v = verifyPayToken(env.PAY_LINK_SIGNING_SECRET, body && typeof body.m === 'string' ? body.m : '', { expectKind: 'm', nowSec });
  if (!v.ok) return fail('invalid');
  const userId = v.payload.u;
  const enrollment = await resolveManagedEnrollment(env, userId, v.payload.e);
  if (!enrollment) return fail('invalid');
  if (enrollment.status !== 'active') return { status: 200, body: { status: 'off', changed: false } };

  const { changed, row } = await revokeEnrollment(env, { enrollment, by: 'customer', reason: 'customer_turned_off', stripe, from: ['active'] });
  if (changed) {
    const [settings, planRow] = await Promise.all([
      store.fetchSettings(env, userId).catch(() => ({})),
      store.fetchPlanForUser(env, userId, row.recurring_invoice_id).catch(() => null),
    ]);
    const plan = planRow && planRow.data ? planRow.data : {};
    const to = await store.resolveAutopayRecipient(env, row, null);
    await sendCustomerEmail(
      env,
      buildAutopayOffEmail({ settings, to, customerName: plan.customerName, planDescription: plan.description, by: 'customer' }),
      'autopay-off email'
    );
    await alertOwner(env, {
      userId,
      settings,
      alert: ownerAutopayOffAlert({ customerName: plan.customerName, planDescription: plan.description, by: 'customer' }),
      data: { recurringInvoiceId: row.recurring_invoice_id },
    });
  }
  return { status: 200, body: { status: 'off', changed } };
}

module.exports = {
  view,
  checkout,
  autopayOff,
  fail,
  expiresAtFor,
  activeEnrollmentForPlan,
  planCents,
  MESSAGES,
};
