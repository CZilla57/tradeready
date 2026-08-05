// POST /api/stripe/webhook — Workers port of backend/api/stripe/webhook.js.
// Stripe Connect webhook — appends a ledger entry to the invoice in Supabase
// when a customer completes payment through a Stripe payment link.
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

import Stripe from 'stripe';
import { amountPaid, isFullyPaid, materializeLegacyLedger } from '../../../lib/paymentMath.js';
import { verifyConnectedAccountOwnership } from '../../../lib/stripe/webhookOwnership.js';

export async function stripeWebhookHandler(c) {
  if (c.req.method !== 'POST') return c.json({ error: 'Method not allowed' }, 405);

  const rawBody = await c.req.text();
  const sig = c.req.header('stripe-signature');

  let event;
  try {
    const stripe = new Stripe(c.env.STRIPE_SECRET_KEY, {
      apiVersion: '2023-10-16',
      httpClient: Stripe.createFetchHttpClient(),
    });
    event = await stripe.webhooks.constructEventAsync(
      rawBody,
      sig,
      c.env.STRIPE_CONNECT_WEBHOOK_SECRET,
      undefined,
      Stripe.createSubtleCryptoProvider()
    );
  } catch (err) {
    console.error('[stripe/webhook] signature verification failed:', err.message);
    return c.json({ error: 'Webhook signature verification failed.' }, 400);
  }

  // Only care about completed checkout sessions
  if (event.type !== 'checkout.session.completed') {
    return c.json({ received: true, skipped: true }, 200);
  }

  const session = event.data.object;

  // Guard: only mark paid when money actually moved
  if (session.payment_status !== 'paid') {
    return c.json({ received: true, skipped: true }, 200);
  }

  const invoiceId = session.metadata?.invoiceId;
  if (!invoiceId) {
    // Payment link was created before webhook support — nothing to do
    return c.json({ received: true, skipped: true }, 200);
  }

  try {
    const outcome = await recordStripePayment(c.env, invoiceId, session, event.account);
    if (outcome && outcome.skipped) {
      return c.json({ received: true, skipped: true }, 200);
    }
    return c.json({ received: true }, 200);
  } catch (err) {
    console.error('[stripe/webhook] failed to mark invoice paid:', err.message);
    // Return 500 so Stripe retries; transient DB errors should self-heal
    return c.json({ error: 'Database error' }, 500);
  }
}

// ── Helpers ───────────────────────────────────────────────────────────────────

async function recordStripePayment(env, invoiceId, session, connectedAccountId) {
  const supabaseHeaders = {
    Authorization: `Bearer ${env.SUPABASE_SERVICE_ROLE_KEY}`,
    apikey: env.SUPABASE_SERVICE_ROLE_KEY,
  };

  const fetchRes = await fetch(
    `${env.SUPABASE_URL}/rest/v1/invoices?id=eq.${encodeURIComponent(invoiceId)}&select=user_id,data`,
    { headers: supabaseHeaders }
  );

  if (!fetchRes.ok) {
    throw new Error(`Supabase fetch ${fetchRes.status}: ${await fetchRes.text()}`);
  }

  const rows = await fetchRes.json();
  if (!rows.length) {
    // Invoice hasn't synced to Supabase yet (device was offline when the link
    // was generated). Log and return — retries won't help until it syncs.
    console.warn(`[stripe/webhook] invoice ${invoiceId} not found in Supabase — skipping`);
    return;
  }

  const { user_id, data } = rows[0];

  // Ownership check: metadata.invoiceId is client-supplied at link-creation
  // time (create-payment-link stamps whatever the app sends), so it may name
  // an invoice the paying connected account does NOT own. Require the event's
  // connected account (`event.account` — Connect events carry it there) to be
  // the account on record for this invoice's owner, or a payment into an
  // attacker's own account could settle a victim's invoice. A mismatch or
  // missing stripe_accounts row is deliberate, not transient — skip with a
  // 200 rather than throw, or Stripe would retry forever. A Supabase error
  // in the lookup still throws → 500 → retry.
  const ownership = await verifyConnectedAccountOwnership({
    supabaseUrl: env.SUPABASE_URL,
    headers: supabaseHeaders,
    userId: user_id,
    eventAccount: connectedAccountId,
  });
  if (!ownership.ok) {
    console.warn(
      `[stripe/webhook] invoice ${invoiceId}: event account ${connectedAccountId} does not match ` +
      `owner's connected account ${ownership.expectedAccountId} (${ownership.reason}) — skipping`
    );
    return { skipped: true };
  }

  const paymentId = `stripe_${session.id}`;

  // Materialize the legacy implied payment (if any) BEFORE appending the
  // Stripe entry. Skipping this would silently erase the invoice's
  // originally-recorded amount the moment `payments` goes from absent to
  // non-empty — see the CRITICAL rule on materializeLegacyLedger in
  // utils/invoicePayments.ts. The stored blob (`data`) is not guaranteed to
  // carry a reliable `id` field of its own, so `invoiceId` — the id this row
  // was just fetched by — is used instead, ensuring the synthesized
  // `legacy_<id>` matches what the device would independently produce for
  // the same invoice.
  const existing = materializeLegacyLedger({ ...data, id: invoiceId });

  // Idempotency: a repeated Stripe delivery must not append twice. The
  // Postgres trigger's union would collapse the duplicate id anyway, but
  // checking here keeps the write itself clean.
  if (existing.some((p) => p && p.id === paymentId)) return;

  // NOTE: dated from UTC. The device records local dates, so a payment near
  // midnight at a large offset can land on the adjacent day — and since each
  // payment is individually revenue-bucketed, that can shift a month boundary.
  // The server does not know the user's timezone. Accepted limitation.
  const paymentAmount = (session.amount_total || 0) / 100;

  // Guard: a zero (or missing) amount_total adds no money but WOULD still
  // flip `payments` from absent to non-empty, which is exactly what kills the
  // legacy fallback for a paid invoice. Refuse to write rather than risk that.
  if (!(paymentAmount > 0)) {
    console.warn(
      `[stripe/webhook] invoice ${invoiceId}: session ${session.id} has non-positive ` +
      `amount_total (${session.amount_total}) — skipping write`
    );
    return;
  }

  // method 'stripe' is RESERVED for webhook-created entries (types/models.ts
  // PaymentMethod; the RecordPaymentSheet chips deliberately omit it), so the
  // history UI can distinguish an auto-reconciled Stripe-link payment from a
  // card payment the tradesperson keyed in by hand.
  const payment = {
    id: paymentId,
    amount: paymentAmount,
    date: new Date().toISOString().split('T')[0],
    method: 'stripe',
    stripeSessionId: session.id,
  };

  const payments = [...existing, payment];
  const nextData = { ...data, payments };

  // paid/paidAt are a best-effort CACHE, not the source of truth: the trigger
  // may union in entries this function never saw. The device re-derives both
  // on sync, and the reminder cron derives from the ledger rather than reading
  // these fields.
  const settled = isFullyPaid(nextData);
  nextData.paid = settled;
  if (settled) {
    nextData.paidAt = payment.date;
  } else {
    delete nextData.paidAt;
  }

  console.log(
    `[stripe/webhook] invoice ${invoiceId}: +$${payment.amount} (${paymentId}), ` +
    `paid ${amountPaid(nextData)} of ${nextData.amount}`
  );

  const upsertRes = await fetch(`${env.SUPABASE_URL}/rest/v1/invoices`, {
    method: 'POST',
    headers: {
      ...supabaseHeaders,
      'Content-Type': 'application/json',
      Prefer: 'resolution=merge-duplicates',
    },
    body: JSON.stringify({
      id: invoiceId,
      user_id,
      data: nextData,
      updated_at: new Date().toISOString(),
      deleted: false,
    }),
  });

  if (!upsertRes.ok) {
    throw new Error(`Supabase upsert ${upsertRes.status}: ${await upsertRes.text()}`);
  }
}
