// Vercel serverless function — creates a Stripe Payment Link for an invoice.
//
// SECURITY MODEL (transitional MVP):
//   - STRIPE_SECRET_KEY lives in Vercel environment variables only.
//     It is never accepted from the request body.
//   - BACKEND_API_TOKEN (optional but recommended) is a shared secret that
//     the mobile app sends as "Authorization: Bearer <token>". Set it in
//     Vercel project settings to prevent unauthenticated calls.
//
// TODO (v2): Replace with Stripe Connect so each user authorises their own
//   Stripe account via OAuth and no shared secret key is needed.

const Stripe = require('stripe');

const STRIPE_SECRET_KEY = process.env.STRIPE_SECRET_KEY;
const BACKEND_API_TOKEN = process.env.BACKEND_API_TOKEN;

// In-memory sliding-window rate limiter: 10 requests per IP per 60 seconds.
// Per-instance state — resets on Vercel cold starts, which is acceptable.
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
  const allowedOrigins = ['https://tradeready.app', 'null'];
  const origin = req.headers['origin'] || 'null';
  res.setHeader('Access-Control-Allow-Origin', allowedOrigins.includes(origin) ? origin : 'https://tradeready.app');
  res.setHeader('Access-Control-Allow-Methods', 'POST, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type, Authorization');

  if (req.method === 'OPTIONS') return res.status(200).end();
  if (req.method !== 'POST') return res.status(405).json({ error: 'Method not allowed' });

  const ip = (req.headers['x-forwarded-for'] || req.socket?.remoteAddress || 'unknown').split(',')[0].trim();
  if (isRateLimited(ip)) {
    return res.status(429).json({ error: 'Too many requests. Please wait a moment.' });
  }

  // Verify API token when one is configured on the server
  if (BACKEND_API_TOKEN) {
    const auth = req.headers['authorization'];
    if (auth !== `Bearer ${BACKEND_API_TOKEN}`) {
      return res.status(401).json({ error: 'Unauthorized' });
    }
  }

  if (!STRIPE_SECRET_KEY) {
    return res.status(500).json({
      error: 'STRIPE_SECRET_KEY is not configured. Add it to your Vercel project environment variables.',
    });
  }

  const { amount, invoiceNumber, description } = req.body;

  if (!amount || amount <= 0) return res.status(400).json({ error: 'Amount must be greater than 0' });

  try {
    const stripe = new Stripe(STRIPE_SECRET_KEY, { apiVersion: '2023-10-16' });

    const product = await stripe.products.create({
      name: invoiceNumber ? `Invoice ${invoiceNumber}` : 'Invoice Payment',
      ...(description ? { description } : {}),
    });

    const price = await stripe.prices.create({
      currency: 'usd',
      unit_amount: Math.round(amount * 100),
      product: product.id,
    });

    const paymentLink = await stripe.paymentLinks.create({
      line_items: [{ price: price.id, quantity: 1 }],
      after_completion: {
        type: 'hosted_confirmation',
        hosted_confirmation: {
          custom_message: 'Payment received. Thank you for your business!',
        },
      },
    });

    res.status(200).json({ url: paymentLink.url });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
};
