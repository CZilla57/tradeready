// Workers port of backend/api/create-payment-link.js — creates a Stripe
// Payment Link for an invoice.
//
// SECURITY MODEL (Stripe Connect):
//   - Caller authenticates via Supabase JWT ("Authorization: Bearer <token>").
//   - Server verifies the JWT, then looks up the caller's connected Stripe account
//     in the stripe_accounts table.
//   - Payment link is created on that connected account using the platform key.
//   - STRIPE_SECRET_KEY is the platform key — it never leaves the server, and
//     money goes directly to the user's own Stripe account.
//
// Required bindings:
//   STRIPE_SECRET_KEY, SUPABASE_URL, SUPABASE_ANON_KEY, SUPABASE_SERVICE_ROLE_KEY

import Stripe from 'stripe';
import { appCors, clientIp, jsonBody } from '../appCors.js';

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

export async function createPaymentLinkHandler(c) {
  appCors(c, 'POST, OPTIONS');
  if (c.req.method === 'OPTIONS') return c.body(null, 200);
  if (c.req.method !== 'POST') return c.json({ error: 'Method not allowed' }, 405);

  const ip = clientIp(c);
  if (isRateLimited(ip)) {
    return c.json({ error: 'Too many requests. Please wait a moment.' }, 429);
  }

  const { STRIPE_SECRET_KEY, SUPABASE_URL, SUPABASE_ANON_KEY, SUPABASE_SERVICE_ROLE_KEY } = c.env;
  if (!STRIPE_SECRET_KEY || !SUPABASE_URL || !SUPABASE_ANON_KEY || !SUPABASE_SERVICE_ROLE_KEY) {
    return c.json({ error: 'Server misconfiguration. Check Vercel environment variables.' }, 500);
  }

  // Auth: verify Supabase JWT
  const auth = c.req.header('authorization');
  if (!auth || !auth.startsWith('Bearer ')) {
    return c.json({ error: 'Unauthorized' }, 401);
  }
  const userJwt = auth.slice(7);

  const userRes = await fetch(`${SUPABASE_URL}/auth/v1/user`, {
    headers: { Authorization: `Bearer ${userJwt}`, apikey: SUPABASE_ANON_KEY },
  });
  if (!userRes.ok) return c.json({ error: 'Invalid or expired session. Please sign in again.' }, 401);
  const user = await userRes.json();
  const userId = user?.id;
  if (!userId) return c.json({ error: 'Unauthorized' }, 401);

  // Look up connected Stripe account for this user
  const accountRes = await fetch(
    `${SUPABASE_URL}/rest/v1/stripe_accounts?user_id=eq.${encodeURIComponent(userId)}&select=stripe_account_id`,
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
    return c.json({
      error: 'No Stripe account connected. Go to Settings → Payment processor and tap "Connect Stripe account".',
    }, 422);
  }

  const { amount, invoiceNumber, description, invoiceId } = (await jsonBody(c)) || {};
  if (!amount || amount <= 0) return c.json({ error: 'Amount must be greater than 0' }, 400);

  try {
    // createFetchHttpClient: the stripe SDK's edge-runtime HTTP client —
    // required off Node (Workers has no Node http module).
    const stripe = new Stripe(STRIPE_SECRET_KEY, {
      apiVersion: '2023-10-16',
      httpClient: Stripe.createFetchHttpClient(),
    });
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

    // Do NOT deactivate product/price here. A Payment Link's `active` field on
    // a Price means "usable for a NEW purchase" — every visit to a Payment
    // Link creates a new purchase attempt against its underlying price at
    // click-time, not at link-creation time. Deactivating the price the
    // instant the link is minted makes the link permanently unusable
    // ("this link is no longer active"), for every customer, immediately.
    // The dashboard-clutter tradeoff is real but the link must work.

    return c.json({ url: paymentLink.url }, 200);
  } catch (err) {
    console.error('[create-payment-link] error:', err.message);
    return c.json({ error: 'Could not create payment link. Please try again.' }, 500);
  }
}
