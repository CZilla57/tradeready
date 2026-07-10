// Vercel serverless function — creates a Stripe Payment Link for an invoice.
//
// SECURITY MODEL (Stripe Connect):
//   - Caller authenticates via Supabase JWT ("Authorization: Bearer <token>").
//   - Server verifies the JWT, then looks up the caller's connected Stripe account
//     in the stripe_accounts table.
//   - Payment link is created on that connected account using the platform key.
//   - STRIPE_SECRET_KEY is the platform key — it never leaves the server, and
//     money goes directly to the user's own Stripe account.
//
// Required Vercel env vars:
//   STRIPE_SECRET_KEY, SUPABASE_URL, SUPABASE_ANON_KEY, SUPABASE_SERVICE_ROLE_KEY

const Stripe = require('stripe');

const STRIPE_SECRET_KEY = process.env.STRIPE_SECRET_KEY;
const SUPABASE_URL = process.env.SUPABASE_URL;
const SUPABASE_ANON_KEY = process.env.SUPABASE_ANON_KEY;
const SUPABASE_SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;

// In-memory sliding-window rate limiter: 10 requests per IP per 60 seconds.
const rateLimitMap = new Map();
const RATE_LIMIT = 10;
const WINDOW_MS = 60_000;

function isRateLimited(ip) {
  const now = Date.now();
  const timestamps = (rateLimitMap.get(ip) || []).filter(t => now - t < WINDOW_MS);
  if (timestamps.length >= RATE_LIMIT) {
    rateLimitMap.set(ip, timestamps);
    return true;
  }
  timestamps.push(now);
  rateLimitMap.set(ip, timestamps);
  return false;
}

module.exports = async function handler(req, res) {
  const allowedOrigins = ['https://tradeready.app'];
  const origin = req.headers['origin'];
  res.setHeader('Access-Control-Allow-Origin', origin && allowedOrigins.includes(origin) ? origin : 'https://tradeready.app');
  res.setHeader('Access-Control-Allow-Methods', 'POST, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type, Authorization');
  if (req.method === 'OPTIONS') return res.status(200).end();
  if (req.method !== 'POST') return res.status(405).json({ error: 'Method not allowed' });

  const ip = (req.headers['x-forwarded-for'] || req.socket?.remoteAddress || 'unknown').split(',')[0].trim();
  if (isRateLimited(ip)) {
    return res.status(429).json({ error: 'Too many requests. Please wait a moment.' });
  }

  if (!STRIPE_SECRET_KEY || !SUPABASE_URL || !SUPABASE_ANON_KEY || !SUPABASE_SERVICE_ROLE_KEY) {
    return res.status(500).json({ error: 'Server misconfiguration. Check Vercel environment variables.' });
  }

  // Auth: verify Supabase JWT
  const auth = req.headers['authorization'];
  if (!auth || !auth.startsWith('Bearer ')) {
    return res.status(401).json({ error: 'Unauthorized' });
  }
  const userJwt = auth.slice(7);

  const userRes = await fetch(`${SUPABASE_URL}/auth/v1/user`, {
    headers: { Authorization: `Bearer ${userJwt}`, apikey: SUPABASE_ANON_KEY },
  });
  if (!userRes.ok) return res.status(401).json({ error: 'Invalid or expired session. Please sign in again.' });
  const user = await userRes.json();
  const userId = user?.id;
  if (!userId) return res.status(401).json({ error: 'Unauthorized' });

  // Look up connected Stripe account for this user
  const accountRes = await fetch(
    `${SUPABASE_URL}/rest/v1/stripe_accounts?user_id=eq.${userId}&select=stripe_account_id`,
    {
      headers: {
        Authorization: `Bearer ${SUPABASE_SERVICE_ROLE_KEY}`,
        apikey: SUPABASE_SERVICE_ROLE_KEY,
      },
    }
  );
  const accountRows = accountRes.ok ? await accountRes.json() : [];
  const stripeAccountId = accountRows[0]?.stripe_account_id;

  if (!stripeAccountId) {
    return res.status(422).json({
      error: 'No Stripe account connected. Go to Settings → Payment processor and tap "Connect Stripe account".',
    });
  }

  const { amount, invoiceNumber, description, invoiceId } = req.body;
  if (!amount || amount <= 0) return res.status(400).json({ error: 'Amount must be greater than 0' });

  try {
    const stripe = new Stripe(STRIPE_SECRET_KEY, { apiVersion: '2023-10-16' });
    // All Stripe API calls target the connected account, not the platform account.
    const stripeOpts = { stripeAccount: stripeAccountId };

    const product = await stripe.products.create(
      {
        name: invoiceNumber ? `Invoice ${invoiceNumber}` : 'Invoice Payment',
        ...(description ? { description } : {}),
      },
      stripeOpts
    );

    const price = await stripe.prices.create(
      { currency: 'usd', unit_amount: Math.round(amount * 100), product: product.id },
      stripeOpts
    );

    const paymentLink = await stripe.paymentLinks.create(
      {
        line_items: [{ price: price.id, quantity: 1 }],
        after_completion: {
          type: 'hosted_confirmation',
          hosted_confirmation: { custom_message: 'Payment received. Thank you for your business!' },
        },
        // invoiceId lets the webhook auto-mark the invoice paid when the customer pays
        ...(invoiceId ? { metadata: { invoiceId } } : {}),
      },
      stripeOpts
    );

    // Archive the one-time product/price so they don't clutter the Stripe dashboard.
    try {
      await Promise.all([
        stripe.products.update(product.id, { active: false }, stripeOpts),
        stripe.prices.update(price.id, { active: false }, stripeOpts),
      ]);
    } catch {
      // Non-fatal — the link is live.
    }

    return res.status(200).json({ url: paymentLink.url });
  } catch (err) {
    console.error('[create-payment-link] error:', err.message);
    return res.status(500).json({ error: 'Could not create payment link. Please try again.' });
  }
};
