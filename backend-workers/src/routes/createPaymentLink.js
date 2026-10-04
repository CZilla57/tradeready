// Workers port of backend/api/create-payment-link.js — mints the pay link for
// an invoice. Same route, same response shape ({url}) since Phase 24 (spec
// §4.3):
//   - PAY_LINK_SIGNING_SECRET set: returns a TradeReady pay-page URL carrying
//     a signed `p` token (lib/pay/payToken.js). No Stripe call is made; the
//     pay page creates a Checkout Session per visit from the live balance.
//   - unset (the rollout switch, §4.2): mints a legacy Stripe Payment Link
//     exactly as before, plus restrictions.completed_sessions.limit = 1 so a
//     link can be completed only once.
//   - Both paths refuse (404) an invoice id whose synced row belongs to
//     another user. An unsynced invoice still mints: the pay page and the
//     webhook re-check ownership.
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
// Optional: PAY_LINK_SIGNING_SECRET (switches to pay-page links),
//   PAY_PUBLIC_BASE (defaults to https://gettradereadyapp.com/pay.html)

import { appCors, clientIp, jsonBody } from '../appCors.js';
import { makeStripe } from '../../lib/stripe/client.js';
import { mintInvoicePayToken, payPageUrl, ID_RE, MAX_CENTS } from '../../lib/pay/payToken.js';
import { balanceDue } from '../../lib/paymentMath.js';

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

// The synced invoice row ({ user_id, data }), or null when it doesn't exist yet.
async function fetchInvoiceRow(env, invoiceId) {
  const res = await fetch(
    `${env.SUPABASE_URL}/rest/v1/invoices?id=eq.${encodeURIComponent(invoiceId)}&select=user_id,data`,
    { headers: { Authorization: `Bearer ${env.SUPABASE_SERVICE_ROLE_KEY}`, apikey: env.SUPABASE_SERVICE_ROLE_KEY } }
  );
  if (!res.ok) throw new Error(`Supabase invoice lookup ${res.status}`);
  const rows = await res.json();
  return rows.length ? rows[0] : null;
}

export function createCreatePaymentLinkHandler({ stripeFactory = makeStripe } = {}) {
  return async function createPaymentLinkHandler(c) {
    appCors(c, 'POST, OPTIONS');
    if (c.req.method === 'OPTIONS') return c.body(null, 200);
    if (c.req.method !== 'POST') return c.json({ error: 'Method not allowed' }, 405);

    const ip = clientIp(c);
    if (isRateLimited(ip)) {
      return c.json({ error: 'Too many requests. Please wait a moment.' }, 429);
    }

    const { STRIPE_SECRET_KEY, SUPABASE_URL, SUPABASE_ANON_KEY, SUPABASE_SERVICE_ROLE_KEY } = c.env;
    if (!STRIPE_SECRET_KEY || !SUPABASE_URL || !SUPABASE_ANON_KEY || !SUPABASE_SERVICE_ROLE_KEY) {
      return c.json({ error: 'Server misconfiguration. Check the server environment configuration.' }, 500);
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

    // Ownership (spec §4.3): a synced invoice row owned by someone else is a
    // 404 on both paths. No row yet (an unsynced device) still mints — the pay
    // page looks the invoice up under the token's owner at view time.
    let invoiceRow = null;
    if (invoiceId) {
      try {
        invoiceRow = await fetchInvoiceRow(c.env, String(invoiceId));
      } catch (err) {
        console.error('[create-payment-link] invoice lookup failed:', err.message);
        return c.json({ error: 'Could not create payment link. Please try again.' }, 500);
      }
      if (invoiceRow && invoiceRow.user_id !== userId) return c.json({ error: 'Invoice not found.' }, 404);
    }

    // Pay-page path (PAY_LINK_SIGNING_SECRET set): minting is an HMAC. The
    // requested amount rides in the token as cents; the pay page charges
    // min(requested, live balance), so a stale or deposit amount can never
    // overcharge.
    if (c.env.PAY_LINK_SIGNING_SECRET) {
      if (!invoiceId) return c.json({ error: 'invoiceId is required.' }, 400);
      if (!ID_RE.test(String(invoiceId))) return c.json({ error: 'Invalid invoiceId.' }, 400);
      const cents = Math.round(Number(amount) * 100);
      if (!Number.isInteger(cents) || cents <= 0 || cents > MAX_CENTS) {
        return c.json({ error: 'Amount must be greater than 0' }, 400);
      }
      // A partial ask (a deposit) also binds the balance it was minted
      // against, so it stops asking once any payment lands (payToken.js).
      const balanceCents = invoiceRow ? Math.round(balanceDue({ ...invoiceRow.data, id: String(invoiceId) }) * 100) : null;
      const token = mintInvoicePayToken(c.env.PAY_LINK_SIGNING_SECRET, { userId, invoiceId: String(invoiceId), cents, balanceCents });
      return c.json({ url: payPageUrl(c.env, 't', token) }, 200);
    }

    try {
      const stripe = stripeFactory(c.env);
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
          // One completed payment per link (spec §4.3, D12): a link in an
          // inbox can no longer be paid twice. The webhook also deactivates a
          // legacy link after its first payment (§4.5).
          restrictions: { completed_sessions: { limit: 1 } },
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
  };
}

export const createPaymentLinkHandler = createCreatePaymentLinkHandler();
