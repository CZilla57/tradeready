// POST /api/stripe/webhook — Workers port of backend/api/stripe/webhook.js.
// Stripe Connect webhook — appends a ledger entry to the invoice in Supabase
// when a customer completes payment through a Stripe payment link or the
// TradeReady pay page.
//
// Phase 24 (spec §4.5) — still ONE endpoint and ONE event type
// (checkout.session.completed); no new Dashboard subscription:
//   - Paid payment sessions book through the shared recordStripePayment
//     (lib/stripe/recordPayment.js) with the unchanged id stripe_<session id>
//     (TH-9). On 'appended', a pay-page session (metadata.tr_kind 'invoice')
//     gets a payment receipt to the Checkout email.
//   - metadata.tr_enrollment → activate the autopay enrollment
//     (lib/autopay/activate.js). Setup-mode sessions (tr_kind
//     'autopay_setup') only activate.
//   - Legacy Payment Link sessions (session.payment_link) → the link is
//     deactivated after its payment, best-effort, so a link already in an
//     inbox can't be paid twice.
//   Activation, receipt and deactivation failures are logged and answered
//   200: the ledger write already succeeded, and Stripe retries are reserved
//   for ledger errors (which still answer 500).
//   A pay-page PaymentIntent must NEVER be booked from a PaymentIntent event:
//   its ledger id is the session's (forward note for Phase 18).
//
// Phase 28 (tips spec §4.3): a pay-page session may carry a second "Tip"
// line. The SAME ledger entry records `amount` = the invoice portion and
// `tipAmount` = the tip, split from the server-set metadata tr_invoice_cents
// + tr_tip_cents only when they add up exactly to amount_total
// (lib/pay/tips.js splitSessionAmount). Otherwise — legacy Payment Link
// sessions, or a mismatch that should never happen — the whole amount_total
// is booked as the invoice payment exactly as before (a mismatch is logged as
// tip_split_mismatch), so money is never dropped. paid/paidAt still come from
// `amount` only (paymentMath.js unchanged), so a tip never pays or overpays
// an invoice.
//
// The invoice's `payments` array is the source of truth for what's been paid;
// `paid`/`paidAt` are written alongside it as a best-effort CACHE (not the
// source of truth) so simple reads don't need to sum the ledger. A FUTURE
// Postgres trigger will union ledger entries from concurrent writers, so that
// this handler's write can only ever ADD an entry — it will not be able to
// shrink or clobber one written elsewhere. That trigger does NOT exist yet:
// today this is a plain read-modify-write, and a concurrent write landing
// between this handler's fetch and its upsert is clobbered, not merged.
// DEPLOY ORDERING: this handler must NOT be deployed before the union trigger
// is applied.
//
// The app's sync layer (pullRemote) picks up the Supabase change on the next
// focus event, so the invoice appears paid automatically without any manual step.
//
// Setup in Stripe Dashboard → Developers → Webhooks:
//   Endpoint URL : <this Worker's URL>/api/stripe/webhook  (Vercel today —
//                  repointed at Phase 5 cutover, not before)
//   Listen to   : Events on Connected accounts
//   Events      : checkout.session.completed
//   Then copy the signing secret in as STRIPE_CONNECT_WEBHOOK_SECRET.
//
// Required bindings:
//   STRIPE_SECRET_KEY
//   STRIPE_CONNECT_WEBHOOK_SECRET  — signing secret from the webhook endpoint above
//   SUPABASE_URL
//   SUPABASE_SERVICE_ROLE_KEY
//
// Workers-specific changes, outcome identical to the Vercel source:
// - c.req.text() replaces the manual raw-body stream + Buffer.concat (Workers
//   hands over the raw body directly; no bodyParser opt-out exists or is
//   needed — signature verification runs over the same exact bytes).
// - constructEventAsync + SubtleCryptoProvider replaces the synchronous
//   constructEvent, which needs Node's sync crypto.createHmac. This is the
//   edge-runtime verification path Stripe's SDK ships specifically for this.
// - createFetchHttpClient: the SDK's fetch-based transport, required off Node.

import { makeStripe, webhookCryptoProvider } from '../../../lib/stripe/client.js';
import { recordStripePayment } from '../../../lib/stripe/recordPayment.js';
import { activateEnrollment } from '../../../lib/autopay/activate.js';
import { buildReceiptEmail } from '../../../lib/autopay/emails.js';
import { cardLabel } from '../../../lib/autopay/format.js';
import { fetchSettings } from '../../../lib/autopay/store.js';
import { sendCustomerEmail } from '../../../lib/ownerAlert.js';
import { balanceDue } from '../../../lib/paymentMath.js';
import { handleTapToPayIntent } from '../../../lib/stripe/tapToPayWebhook.js';
import { splitSessionAmount } from '../../../lib/pay/tips.js';

// The PaymentIntent behind a paid session, with its card and saved payment
// method expanded. Null on any error (callers degrade, never fail).
async function retrieveSessionIntent(stripe, session, accountId) {
  const id = typeof session.payment_intent === 'string' ? session.payment_intent : session.payment_intent && session.payment_intent.id;
  if (!id) return null;
  try {
    return await stripe.paymentIntents.retrieve(id, { expand: ['payment_method', 'latest_charge'] }, { stripeAccount: accountId });
  } catch (err) {
    console.error(`[stripe/webhook] retrieve ${id} failed:`, err.message);
    return null;
  }
}

async function retrieveSetupIntent(stripe, session, accountId) {
  const id = typeof session.setup_intent === 'string' ? session.setup_intent : session.setup_intent && session.setup_intent.id;
  if (!id) return null;
  try {
    return await stripe.setupIntents.retrieve(id, { expand: ['payment_method'] }, { stripeAccount: accountId });
  } catch (err) {
    console.error(`[stripe/webhook] retrieve ${id} failed:`, err.message);
    return null;
  }
}

async function activate(env, stripe, { enrollmentId, event, session, intent, invoiceEmail }) {
  try {
    const { outcome } = await activateEnrollment(env, { stripe, enrollmentId, eventAccount: event.account, session, intent, invoiceEmail });
    console.log(`[stripe/webhook] autopay enrollment ${enrollmentId}: ${outcome}`);
  } catch (err) {
    console.error(`[stripe/webhook] autopay activation ${enrollmentId} failed:`, err.message);
  }
}

async function sendPaymentReceipt(env, { result, session, intent, split }) {
  try {
    const invoice = result.invoice || {};
    const charge = intent && intent.latest_charge && typeof intent.latest_charge === 'object' ? intent.latest_charge : null;
    const card = charge && charge.payment_method_details ? charge.payment_method_details.card : null;
    const settings = await fetchSettings(env, result.userId);
    const email = buildReceiptEmail({
      settings,
      to: session.customer_details && session.customer_details.email,
      customerName: invoice.customer,
      invoiceNumber: invoice.number,
      amountCents: split.invoiceCents,
      tipCents: split.tipCents,
      card: card ? cardLabel(card.brand, card.last4) : null,
      remainingCents: Math.round(balanceDue(invoice) * 100),
      date: new Date().toISOString().split('T')[0],
    });
    await sendCustomerEmail(env, email, 'payment receipt');
  } catch (err) {
    console.error('[stripe/webhook] receipt failed:', err.message);
  }
}

async function deactivatePaymentLink(stripe, session, accountId) {
  const id = typeof session.payment_link === 'string' ? session.payment_link : session.payment_link && session.payment_link.id;
  if (!id) return;
  try {
    await stripe.paymentLinks.update(id, { active: false, inactive_message: 'This invoice has been paid. Thank you!' }, { stripeAccount: accountId });
  } catch (err) {
    console.error(`[stripe/webhook] deactivate payment link ${id} failed:`, err.message);
  }
}

export function createStripeWebhookHandler({ stripeFactory = makeStripe } = {}) {
  return async function stripeWebhookHandler(c) {
    if (c.req.method !== 'POST') return c.json({ error: 'Method not allowed' }, 405);

    const rawBody = await c.req.text();
    const sig = c.req.header('stripe-signature');

    let event;
    let stripe;
    try {
      stripe = stripeFactory(c.env);
      event = await stripe.webhooks.constructEventAsync(
        rawBody,
        sig,
        c.env.STRIPE_CONNECT_WEBHOOK_SECRET,
        undefined,
        webhookCryptoProvider()
      );
    } catch (err) {
      console.error('[stripe/webhook] signature verification failed:', err.message);
      return c.json({ error: 'Webhook signature verification failed.' }, 400);
    }

    // Phase 18: Tap to Pay PaymentIntents only (lib/stripe/tapToPayWebhook.js);
    // every other payment_intent.* event is skipped there.
    if (event.type === 'payment_intent.succeeded') return handleTapToPayIntent(c, event);

    // Only care about completed checkout sessions
    if (event.type !== 'checkout.session.completed') {
      return c.json({ received: true, skipped: true }, 200);
    }

    const session = event.data.object;
    const metadata = session.metadata || {};

    // Autopay setup (portal "Set up", manage-page card change): no payment,
    // so it never reaches the ledger path below.
    if (session.mode === 'setup') {
      if (session.status !== 'complete' || metadata.tr_kind !== 'autopay_setup' || !metadata.tr_enrollment) {
        return c.json({ received: true, skipped: true }, 200);
      }
      const intent = await retrieveSetupIntent(stripe, session, event.account);
      await activate(c.env, stripe, { enrollmentId: metadata.tr_enrollment, event, session, intent });
      return c.json({ received: true }, 200);
    }

    // Guard: only mark paid when money actually moved
    if (session.payment_status !== 'paid') {
      return c.json({ received: true, skipped: true }, 200);
    }

    const invoiceId = metadata.invoiceId;
    if (!invoiceId) {
      // Payment link was created before webhook support — nothing to do
      return c.json({ received: true, skipped: true }, 200);
    }

    const split = splitSessionAmount(session);
    if (split.mismatch) {
      console.warn(
        `[stripe/webhook] tip_split_mismatch ${session.id}: tr_invoice_cents=${String(metadata.tr_invoice_cents)} ` +
        `tr_tip_cents=${String(metadata.tr_tip_cents)} amount_total=${String(session.amount_total)} — booking the whole amount`
      );
    }

    let result;
    try {
      result = await recordStripePayment(c.env, {
        invoiceId,
        connectedAccountId: event.account,
        ledgerId: `stripe_${session.id}`,
        amount: split.invoiceCents / 100,
        extra: { stripeSessionId: session.id, ...(split.tipCents > 0 ? { tipAmount: split.tipCents / 100 } : {}) },
      });
    } catch (err) {
      console.error('[stripe/webhook] failed to mark invoice paid:', err.message);
      // Return 500 so Stripe retries; transient DB errors should self-heal
      return c.json({ error: 'Database error' }, 500);
    }
    if (result.outcome === 'ownership_skip') {
      return c.json({ received: true, skipped: true }, 200);
    }

    // Post-ledger steps: best-effort, each isolated, never a non-200.
    const wantsReceipt = result.outcome === 'appended' && metadata.tr_kind === 'invoice';
    const intent = metadata.tr_enrollment || wantsReceipt ? await retrieveSessionIntent(stripe, session, event.account) : null;
    if (metadata.tr_enrollment) {
      await activate(c.env, stripe, {
        enrollmentId: metadata.tr_enrollment,
        event,
        session,
        intent,
        invoiceEmail: result.invoice ? result.invoice.email : null,
      });
    }
    if (wantsReceipt) await sendPaymentReceipt(c.env, { result, session, intent, split });
    if (session.payment_link) await deactivatePaymentLink(stripe, session, event.account);

    return c.json({ received: true }, 200);
  };
}

export const stripeWebhookHandler = createStripeWebhookHandler();
