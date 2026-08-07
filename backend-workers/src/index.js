// TradeReady backend on Cloudflare Workers — Hono app mirroring the Vercel
// backend's public URL surface exactly (same paths, same responses).
//
// Routing notes, all deliberate:
// - app.all + in-handler method checks (not app.post/app.get): on Vercel every
//   method reached the handler and wrong methods got the handler's own
//   405 {error} WITH its CORS headers. Method-scoped Hono routes would turn
//   those into bare 404s — a behavior change.
// - The Vercel [action].js dispatchers (booking, estimate) become real routes;
//   the per-prefix catch-alls below reproduce their 404 {error:'Not found'}
//   for unknown actions.
// - The four stripe/connect routes were vercel.json rewrites onto
//   api/stripe/connect.js?action=…; here they are plain routes (the rewrite
//   layer isn't a Workers concept). The internal /api/stripe/connect?action=…
//   URL was never called by the app and is not reproduced.
// - No global middleware. Each route owns its CORS/auth/rate-limit exactly
//   like the source files did, and the Stripe webhook (Phase 2) must read its
//   own raw body — nothing here may touch a request body before the handler.

import { Hono } from 'hono';
import { runReminders } from '../lib/sendReminders.js';
import { runInvoiceEmails } from '../lib/sendInvoiceEmails.js';

import { aiChatHandler } from './routes/aiChat.js';
import { pricebookSuggestHandler } from './routes/pricebookSuggest.js';
import { receiptExtractHandler } from './routes/receiptExtract.js';
import { deleteAccountHandler } from './routes/deleteAccount.js';
import { createPaymentLinkHandler } from './routes/createPaymentLink.js';
import { invoicePdfHandler } from './routes/invoicePdf.js';
import { photosHandler } from './routes/photos.js';
import { photosPublicHandler } from './routes/photosPublic.js';
import { subscriptionWebhookHandler } from './routes/subscriptionWebhook.js';
import { bookingMintHandler } from './routes/booking/mint.js';
import { bookingConfigHandler } from './routes/booking/config.js';
import { bookingSubmitHandler } from './routes/booking/submit.js';
import { bookingSlotsHandler } from './routes/booking/slots.js';
import { bookingReserveHandler } from './routes/booking/reserve.js';
import { bookingManageHandler } from './routes/booking/manage.js';
import { bookingRespondHandler } from './routes/booking/respond.js';
import { estimateCreateLinkHandler } from './routes/estimate/createLink.js';
import { estimateRespondHandler } from './routes/estimate/respond.js';
import { estimateViewHandler } from './routes/estimate/view.js';
import { portalViewHandler } from './routes/estimate/portalView.js';
import { portalIcsHandler } from './routes/estimate/portalIcs.js';
import { changeViewHandler } from './routes/estimate/changeView.js';
import { changeRespondHandler } from './routes/estimate/changeRespond.js';
import { connectStatusHandler } from './routes/stripe/connectStatus.js';
import { createConnectAccountHandler } from './routes/stripe/createConnectAccount.js';
import { disconnectHandler } from './routes/stripe/disconnect.js';
import { connectReturnHandler } from './routes/stripe/connectReturn.js';
import { stripeWebhookHandler } from './routes/stripe/webhook.js';
import { cronSendRemindersHandler, cronSendInvoiceEmailsHandler } from './routes/cron.js';

const app = new Hono();

app.all('/api/ai-chat', aiChatHandler);
app.all('/api/pricebook-suggest', pricebookSuggestHandler);
app.all('/api/receipt-extract', receiptExtractHandler);
app.all('/api/delete-account', deleteAccountHandler);
app.all('/api/create-payment-link', createPaymentLinkHandler);
app.all('/api/invoice-pdf', invoicePdfHandler);
app.all('/api/photos/:photoId', photosHandler);
app.all('/api/photos-public/:photoId', photosPublicHandler);
app.all('/api/subscription/webhook', subscriptionWebhookHandler);

app.all('/api/booking/mint', bookingMintHandler);
app.all('/api/booking/config', bookingConfigHandler);
app.all('/api/booking/submit', bookingSubmitHandler);
app.all('/api/booking/slots', bookingSlotsHandler);
app.all('/api/booking/reserve', bookingReserveHandler);
app.all('/api/booking/manage', bookingManageHandler);
app.all('/api/booking/respond', bookingRespondHandler);
app.all('/api/booking/:action', (c) => c.json({ error: 'Not found' }, 404));

app.all('/api/estimate/create-link', estimateCreateLinkHandler);
app.all('/api/estimate/respond', estimateRespondHandler);
app.all('/api/estimate/view', estimateViewHandler);
app.all('/api/estimate/portal-view', portalViewHandler);
app.all('/api/estimate/portal-ics', portalIcsHandler);
app.all('/api/estimate/change-view', changeViewHandler);
app.all('/api/estimate/change-respond', changeRespondHandler);
app.all('/api/estimate/:action', (c) => c.json({ error: 'Not found' }, 404));

app.all('/api/stripe/connect-status', connectStatusHandler);
app.all('/api/stripe/create-connect-account', createConnectAccountHandler);
app.all('/api/stripe/disconnect', disconnectHandler);
app.all('/api/stripe/connect-return', connectReturnHandler);
// Reads its own raw body via c.req.text() — keep this app middleware-free so
// nothing consumes the body before signature verification (see file header).
app.all('/api/stripe/webhook', stripeWebhookHandler);

// Manual-run fallback; the production trigger is scheduled() below.
app.all('/api/cron/send-reminders', cronSendRemindersHandler);
app.all('/api/cron/send-invoice-emails', cronSendInvoiceEmailsHandler);

// Anything else under this Worker: JSON 404 (Vercel served its own 404 page).
app.notFound((c) => c.json({ error: 'Not found' }, 404));

export default {
  fetch: app.fetch,
  // Workers Cron Triggers (wrangler.toml [triggers]) dispatched by pattern:
  // */15 → the invoice auto-email sweep; the daily 15:00 UTC trigger keeps
  // running the payment reminders. At 15:00 both fire — disjoint batches
  // over different log tables, harmless. Only Cloudflare's scheduler can
  // invoke this, so the CRON_SECRET bearer check lives solely on the manual
  // HTTP fallback routes.
  async scheduled(event, env, ctx) {
    if (event.cron === '*/15 * * * *') {
      ctx.waitUntil(
        runInvoiceEmails(env).catch((err) =>
          console.error('[send-invoice-emails] scheduled run failed:', err.message)
        )
      );
      return;
    }
    ctx.waitUntil(
      runReminders(env).catch((err) =>
        console.error('[send-reminders] scheduled run failed:', err.message)
      )
    );
  },
};
