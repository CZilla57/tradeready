// POST /api/stripe/webhook
// Stripe Connect webhook — appends a ledger entry to the invoice in Supabase
// when a customer completes payment through a Stripe payment link.
//
// The invoice's `payments` array is the source of truth for what's been paid;
// `paid`/`paidAt` are written alongside it as a best-effort CACHE (not the
// source of truth) so simple reads don't need to sum the ledger. A Postgres
// trigger unions ledger entries from concurrent writers, so this handler's
// write can only ever ADD an entry — it cannot shrink or clobber one written
// elsewhere.
//
// The app's sync layer (pullRemote) picks up the Supabase change on the next
// focus event, so the invoice appears paid automatically without any manual step.
//
// Setup in Stripe Dashboard → Developers → Webhooks:
//   Endpoint URL : https://backend-tradeready1.vercel.app/api/stripe/webhook
//   Listen to   : Events on Connected accounts
//   Events      : checkout.session.completed
//   Then copy the signing secret into Vercel as STRIPE_CONNECT_WEBHOOK_SECRET.
//
// Required Vercel env vars:
//   STRIPE_SECRET_KEY
//   STRIPE_CONNECT_WEBHOOK_SECRET  — signing secret from the webhook endpoint above
//   SUPABASE_URL
//   SUPABASE_SERVICE_ROLE_KEY

const Stripe = require('stripe');
const { amountPaid, isFullyPaid } = require('../../lib/paymentMath');

const STRIPE_SECRET_KEY            = process.env.STRIPE_SECRET_KEY;
const STRIPE_CONNECT_WEBHOOK_SECRET = process.env.STRIPE_CONNECT_WEBHOOK_SECRET;
const SUPABASE_URL                 = process.env.SUPABASE_URL;
const SUPABASE_SERVICE_ROLE_KEY    = process.env.SUPABASE_SERVICE_ROLE_KEY;

// Vercel must not parse the body — Stripe signature verification requires the raw bytes.
const handler = async function (req, res) {
  if (req.method !== 'POST') return res.status(405).json({ error: 'Method not allowed' });

  // Collect the raw body stream
  const chunks = [];
  for await (const chunk of req) chunks.push(chunk);
  const rawBody = Buffer.concat(chunks);

  // Verify the Stripe webhook signature
  const sig = req.headers['stripe-signature'];
  let event;
  try {
    const stripe = new Stripe(STRIPE_SECRET_KEY, { apiVersion: '2023-10-16' });
    event = stripe.webhooks.constructEvent(rawBody, sig, STRIPE_CONNECT_WEBHOOK_SECRET);
  } catch (err) {
    console.error('[stripe/webhook] signature verification failed:', err.message);
    return res.status(400).json({ error: 'Webhook signature verification failed.' });
  }

  // Only care about completed checkout sessions
  if (event.type !== 'checkout.session.completed') {
    return res.status(200).json({ received: true, skipped: true });
  }

  const session = event.data.object;

  // Guard: only mark paid when money actually moved
  if (session.payment_status !== 'paid') {
    return res.status(200).json({ received: true, skipped: true });
  }

  const invoiceId = session.metadata?.invoiceId;
  if (!invoiceId) {
    // Payment link was created before webhook support — nothing to do
    return res.status(200).json({ received: true, skipped: true });
  }

  try {
    await recordStripePayment(invoiceId, session);
    return res.status(200).json({ received: true });
  } catch (err) {
    console.error('[stripe/webhook] failed to mark invoice paid:', err.message);
    // Return 500 so Stripe retries; transient DB errors should self-heal
    return res.status(500).json({ error: 'Database error' });
  }
};

handler.config = { api: { bodyParser: false } };

module.exports = handler;

// ── Helpers ───────────────────────────────────────────────────────────────────

async function recordStripePayment(invoiceId, session) {
  const supabaseHeaders = {
    Authorization: `Bearer ${SUPABASE_SERVICE_ROLE_KEY}`,
    apikey: SUPABASE_SERVICE_ROLE_KEY,
  };

  const fetchRes = await fetch(
    `${SUPABASE_URL}/rest/v1/invoices?id=eq.${encodeURIComponent(invoiceId)}&select=user_id,data`,
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
  const paymentId = `stripe_${session.id}`;
  const existing = Array.isArray(data?.payments) ? data.payments : [];

  // Idempotency: a repeated Stripe delivery must not append twice. The
  // Postgres trigger's union would collapse the duplicate id anyway, but
  // checking here keeps the write itself clean.
  if (existing.some((p) => p && p.id === paymentId)) return;

  // NOTE: dated from UTC. The device records local dates, so a payment near
  // midnight at a large offset can land on the adjacent day — and since each
  // payment is individually revenue-bucketed, that can shift a month boundary.
  // The server does not know the user's timezone. Accepted limitation.
  const payment = {
    id: paymentId,
    amount: (session.amount_total || 0) / 100,
    date: new Date().toISOString().split('T')[0],
    method: 'card',
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

  const upsertRes = await fetch(`${SUPABASE_URL}/rest/v1/invoices`, {
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
