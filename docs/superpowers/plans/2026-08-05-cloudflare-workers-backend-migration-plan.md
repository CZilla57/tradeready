# Cloudflare Workers Backend Migration — Implementation Plan

**Spec:** none — scoped directly in a chat session on 2026-08-05 by reading the live `backend/` tree at commit `89e9762` (branch `master`). This doc *is* the spec; all facts below are file:line-verified against that commit, re-verify before relying on them if HEAD has moved.
**Branch:** `feat/cloudflare-workers-backend` (cut fresh off `master`, NOT off `feat/settings-subpages` — that branch is unrelated in-progress work; confirm with `git branch --show-current` and `git status` before starting, per the standing concurrent-session caveat).
**Rule:** every phase ends with a gate (see per-phase verification) and its own commit. The existing `backend/` (Vercel) directory is not touched or deleted until Phase 5's cutover is owner-approved — this plan builds a parallel `backend-workers/` the whole way through Phase 4.
**New dependencies this plan introduces:** `hono` (routing) and `wrangler` (build/deploy CLI), both scoped to the new `backend-workers/` directory only — they do not touch the Expo app's `package.json`. Per `tradeready-change-control`'s no-dependency-changes-without-approval rule, get an explicit go-ahead before Phase 1's `npm init`/`npm install`, even though this is backend tooling, not an Expo SDK change.

## Why this migration, and what "done" looks like

The current backend is 11 Vercel serverless functions under `backend/api/` (`backend-tradeready1.vercel.app`), against a 12-function-per-project cap (`tradeready-run-and-operate` / `tradeready-config-and-flags`; see `project_vercel_function_cap.md`). The domain `gettradereadyapp.com` (apex, `www`, and `estimates.` subdomain — the three CORS origins repeated across every handler) is already a Cloudflare DNS zone, so attaching a Worker needs no CNAME/A-record work. Done means: all 11 endpoints + the cron job behaviorally identical on Cloudflare Workers, verified side-by-side against the live Vercel backend before any cutover, with the money-critical Stripe webhook tested against real Stripe test-mode events.

## Source-of-truth inventory (verified 2026-08-05 @ `89e9762`)

| Category | Files |
|---|---|
| `api/` handlers (11) | `ai-chat.js`, `booking/[action].js`, `create-payment-link.js`, `cron/send-reminders.js`, `delete-account.js`, `estimate/[action].js`, `pricebook-suggest.js`, `receipt-extract.js`, `stripe/connect.js`, `stripe/webhook.js`, `subscription/webhook.js` |
| `lib/` (19, business logic + shared helpers) | `aiUsage.js`, `booking/{config,mint,notifyOwner,store,submit,validate}.js`, `constantTime.js`, `estimate/{changeOrderMath,changeRespond,changeView,cors,createLink,portalStore,portalView,respond,view}.js`, `estimateStore.js`, `guards.js`, `overdue.js`, `paymentMath.js`, `plan.js`, `reminderEmail.js`, `selectInvoicesToRemind.js`, `stripe/{connectReturn,connectStatus,createConnectAccount,disconnect,webhookOwnership}.js` |
| `vercel.json` rewrites (become real routes) | `/api/stripe/connect-status` → `connect.js?action=connect-status`, `create-connect-account` → `?action=create-connect-account`, `disconnect` → `?action=disconnect`, `connect-return` → `?action=connect-return` |
| `vercel.json` cron | `{ path: "/api/cron/send-reminders", schedule: "0 15 * * *" }` |
| Only npm dependency | `stripe@^16.0.0` |
| Env vars referenced (12, `grep -rhoE "process\.env\.[A-Z_]+" api lib \| sort \| uniq -c`) | `SUPABASE_URL`(18), `SUPABASE_SERVICE_ROLE_KEY`(14), `SUPABASE_ANON_KEY`(10), `STRIPE_SECRET_KEY`(4), `GROQ_API_KEY`(3), `VERCEL_URL`(2, Vercel-auto — no Workers equivalent, see Phase 1 step 4), `RESEND_API_KEY`(2), `STRIPE_CONNECT_WEBHOOK_SECRET`(1), `REVENUECAT_WEBHOOK_SECRET`(1), `ESTIMATE_PUBLIC_ORIGIN`(1), `ESTIMATE_PUBLIC_BASE`(1), `CRON_SECRET`(1), `CHANGE_PUBLIC_BASE`(1) |
| CORS allow-list (repeated verbatim in `ai-chat.js`, `create-payment-link.js`, `delete-account.js`, `pricebook-suggest.js`, `receipt-extract.js`, `lib/stripe/connectStatus.js`, `lib/stripe/disconnect.js`, `lib/stripe/createConnectAccount.js`, `lib/estimate/cors.js`) | `https://estimates.gettradereadyapp.com`, `https://gettradereadyapp.com`, `https://www.gettradereadyapp.com` (falls back to the apex when `Origin` doesn't match) |
| No Supabase JS SDK, no `@vercel/*` packages, no multipart parser | Confirmed by `grep -rl "@vercel/"` (0 hits) and `package.json` dependencies (only `stripe`). Every Supabase call is a raw `fetch()` to `${SUPABASE_URL}/auth/v1/...` or `/rest/v1/...` — already edge-native, zero porting needed. |

## Global constraints (apply to every phase)

- Preserve the `backend/api/stripe/webhook.js:5-14` deploy-ordering comment's warning verbatim in the ported file — the union-trigger-not-applied-yet caveat is a real production constraint, not stale prose.
- No behavior changes while porting. Where a file needs a genuine rewrite (raw-body handling, CORS boilerplate, `VERCEL_URL`), keep the *outcome* identical; note any outcome-affecting choice explicitly in that phase's commit message and gate report.
- Every phase's code must run through `node -c` (or the Wrangler build) clean and, from Phase 2 onward, through `wrangler dev` manually exercised — there is no Jest suite for `backend/` today (confirmed: no `__tests__` reference backend files), so "gate" here means manual request verification with `curl`/Stripe CLI, not `npm test`.
- Nothing in `app.json`, the RevenueCat dashboard, or the Stripe dashboard changes before Phase 5. Phases 1–4 produce a fully working parallel backend on a `*.workers.dev` URL that nothing in production points to yet.

---

## Phase 1 — Scaffold + trivial/moderate endpoints (no cutover)

1. `backend-workers/` (new, sibling to `backend/`):
   - `npm init -y`, `npm install hono`, `npm install -D wrangler`.
   - `wrangler.toml`:
     ```toml
     name = "tradeready-backend"
     main = "src/index.js"
     compatibility_date = "2026-08-05"

     [vars]
     # non-secret only — everything else via `wrangler secret put`
     ```
   - `src/index.js` — Hono app skeleton:
     ```js
     import { Hono } from 'hono';
     import { cors } from 'hono/cors';

     const ALLOWED_ORIGINS = [
       'https://estimates.gettradereadyapp.com',
       'https://gettradereadyapp.com',
       'https://www.gettradereadyapp.com',
     ];

     const app = new Hono();

     app.use('*', cors({
       origin: (origin) => (origin && ALLOWED_ORIGINS.includes(origin) ? origin : ALLOWED_ORIGINS[1]),
     }));

     export default app;
     ```
     This single `cors()` middleware replaces the per-file `ALLOWED_ORIGINS` array + manual `res.setHeader('Access-Control-Allow-Origin', ...)` duplicated in the 9 files listed in the inventory table above — not a scope-creep refactor, just doing once, centrally, what porting would otherwise require rewriting 9 times identically.
2. Port the 9 trivial-tier handlers from the inventory table (`ai-chat`, `pricebook-suggest`, `receipt-extract`, `delete-account`, `create-payment-link`, `subscription/webhook`, `booking/[action]`, `estimate/[action]` + its `lib/estimate/*` helpers) into `src/routes/*.js`, mounted on `app`. Mechanical translation per handler:
   - `req.method` checks → Hono route method (`app.post('/api/x', handler)` instead of an in-body `if (req.method !== 'POST')`).
   - `req.headers['x']` → `c.req.header('x')`.
   - `req.query.action` → `c.req.query('action')`.
   - `await req.json()`-equivalent (currently implicit Vercel bodyParser) → `await c.req.json()`.
   - `res.status(N).json(x)` → `c.json(x, N)`.
   - `process.env.X` → `c.env.X` (pass `c.env` down into any `lib/` helper that currently reads `process.env` directly — those helpers keep their `require()`/`module.exports` CommonJS shape unchanged; only their env-access call sites change from a module-level `process.env.X` constant to a parameter).
3. Mount the 4 `stripe/connect.js` dispatcher actions as 4 real Hono routes (`/api/stripe/connect-status`, `/api/stripe/create-connect-account`, `/api/stripe/disconnect`, `/api/stripe/connect-return`) instead of the `vercel.json` rewrite trick — this removes the rewrite layer entirely, it isn't a Workers concept.
4. `lib/stripe/createConnectAccount.js:67-69` reads `process.env.VERCEL_URL` to build the onboarding return URL, falling back to the hardcoded `https://backend-tradeready1.vercel.app`. Workers has no equivalent auto-injected var. Replace with `new URL(c.req.url).origin` (derived from the actual incoming request — correct on `*.workers.dev` during Phase 1-4 testing and on the eventual custom domain after Phase 5, with no redeploy needed to change it). Pass this origin string down to the helper as a parameter instead of reading an env var.
5. Verify: `npx wrangler dev`, then for each of the 9+4 routes, `curl` it with the same headers/body shape the app or Stripe would send (a valid Supabase JWT in `Authorization: Bearer`, matching `Origin` header) and confirm the JSON response body matches what the same request against `https://backend-tradeready1.vercel.app` returns. Record the diff (or "identical") per endpoint in the phase report.
6. Commit: `git add backend-workers && git commit -m "feat: scaffold Cloudflare Workers backend, port 9 trivial endpoints + stripe/connect dispatcher"`.

## Phase 2 — Stripe webhook (highest-risk endpoint)

This is the one file that isn't a mechanical translation. `backend/api/stripe/webhook.js:41-58` streams the raw request body into a Node `Buffer` (`for await (const chunk of req) chunks.push(chunk); Buffer.concat(chunks)`) and calls the **synchronous** `stripe.webhooks.constructEvent(rawBody, sig, secret)`, which uses Node's `crypto` module — Workers has neither `Buffer` nor a compatible sync `crypto.createHmac` by default.

1. `src/routes/stripeWebhook.js`:
   ```js
   import Stripe from 'stripe';
   import { amountPaid, isFullyPaid, materializeLegacyLedger } from '../../lib/paymentMath.js';
   import { verifyConnectedAccountOwnership } from '../../lib/stripe/webhookOwnership.js';

   export async function stripeWebhookHandler(c) {
     const rawBody = await c.req.text(); // Workers gives the raw body directly — no bodyParser opt-out needed
     const sig = c.req.header('stripe-signature');

     const stripe = new Stripe(c.env.STRIPE_SECRET_KEY, {
       apiVersion: '2023-10-16',
       httpClient: Stripe.createFetchHttpClient(), // fetch-based client, required off Node
     });

     let event;
     try {
       // constructEventAsync uses SubtleCrypto instead of Node crypto — the
       // edge-runtime-safe verification path Stripe's SDK ships specifically for this.
       event = await stripe.webhooks.constructEventAsync(rawBody, sig, c.env.STRIPE_CONNECT_WEBHOOK_SECRET);
     } catch (err) {
       console.error('[stripe/webhook] signature verification failed:', err.message);
       return c.json({ error: 'Webhook signature verification failed.' }, 400);
     }

     if (event.type !== 'checkout.session.completed') {
       return c.json({ received: true, skipped: true });
     }
     const session = event.data.object;
     if (session.payment_status !== 'paid') {
       return c.json({ received: true, skipped: true });
     }
     const invoiceId = session.metadata?.invoiceId;
     if (!invoiceId) {
       return c.json({ received: true, skipped: true });
     }

     try {
       const outcome = await recordStripePayment(c.env, invoiceId, session, event.account);
       if (outcome?.skipped) return c.json({ received: true, skipped: true });
       return c.json({ received: true });
     } catch (err) {
       console.error('[stripe/webhook] failed to mark invoice paid:', err.message);
       return c.json({ error: 'Database error' }, 500); // 500 so Stripe retries — unchanged from source
     }
   }
   ```
   Copy `recordStripePayment` and every other helper below `backend/api/stripe/webhook.js`'s `// ── Helpers ──` marker unchanged except for `process.env.X` → the `env` object now threaded in as a parameter. Preserve the file's top-of-file deploy-ordering comment (source lines 5-14) verbatim in the new file — the union-trigger caveat is still true and unrelated to this migration.
2. `app.post('/api/stripe/webhook', stripeWebhookHandler)` — note this route must be registered so its body is read via `c.req.text()` before any global JSON-parsing middleware touches it; don't add a global body-parsing middleware to this Hono app (none is needed — every route reads its own body explicitly, matching the source's per-file style).
3. Verify with the Stripe CLI, in **test mode only**:
   ```bash
   stripe listen --forward-to localhost:8787/api/stripe/webhook
   stripe trigger checkout.session.completed
   ```
   Confirm: signature verifies, the Supabase invoice record referenced by a real test `invoiceId` in `session.metadata` gets the same ledger entry shape `recordStripePayment` currently produces against the Vercel backend (compare by running the identical trigger against a `stripe listen --forward-to https://backend-tradeready1.vercel.app/api/stripe/webhook` session and diffing the resulting Supabase rows). Also verify the negative paths: bad signature → 400, wrong event type → `{skipped: true}`, unpaid session → `{skipped: true}`, missing `metadata.invoiceId` → `{skipped: true}`.
4. Commit: `git add backend-workers/src/routes/stripeWebhook.js backend-workers/lib && git commit -m "feat: port stripe webhook - constructEventAsync + fetch http client for edge crypto"`.

## Phase 3 — Cron (send-reminders)

`backend/api/cron/send-reminders.js` is invoked today as a Vercel Cron `GET` request carrying `Authorization: Bearer <CRON_SECRET>` (`vercel.json`'s `crons` array, `0 15 * * *`). Workers Cron Triggers don't hit an HTTP route at all — they call a dedicated `scheduled()` export directly, and only Cloudflare's own trigger can invoke it, so the bearer-secret check that exists purely to keep this endpoint from being called by anyone else becomes unnecessary for the triggered path.

1. `wrangler.toml` addition:
   ```toml
   [triggers]
   crons = ["0 15 * * *"]
   ```
2. `src/index.js`:
   ```js
   import { runReminders } from './lib/sendReminders.js'; // ported business logic, env-check + Resend send loop unchanged

   export default {
     fetch: app.fetch,
     async scheduled(event, env, ctx) {
       ctx.waitUntil(runReminders(env));
     },
   };
   ```
3. Keep an HTTP-triggerable fallback for manual runs, still behind `CRON_SECRET` (useful for the owner to force a run without waiting for 15:00 UTC): `app.get('/api/cron/send-reminders', async (c) => { if (c.req.header('Authorization') !== \`Bearer ${c.env.CRON_SECRET}\`) return c.text('Unauthorized', 401); await runReminders(c.env); return c.json({ ok: true }); })`.
4. Verify: `npx wrangler dev --test-scheduled`, then `curl "http://localhost:8787/__scheduled?cron=0+15+*+*+*"` (Wrangler's local scheduled-trigger endpoint) and confirm Resend receives the same reminder payloads `lib/reminderEmail.js` builds today (check via Resend's test-mode dashboard or by pointing `RESEND_API_KEY` at a sandboxed key during this test only).
5. Commit: `git add backend-workers/wrangler.toml backend-workers/src && git commit -m "feat: port daily reminder cron to a Workers scheduled trigger"`.

## Phase 4 — Full parallel-run verification

1. `wrangler secret put <NAME>` for each of the 9 secret-tier env vars (`STRIPE_SECRET_KEY`, `SUPABASE_SERVICE_ROLE_KEY`, `SUPABASE_ANON_KEY`, `STRIPE_CONNECT_WEBHOOK_SECRET`, `REVENUECAT_WEBHOOK_SECRET`, `CRON_SECRET`, `RESEND_API_KEY`, `GROQ_API_KEY`) plus `[vars]` entries in `wrangler.toml` for the 4 non-secret ones (`SUPABASE_URL`, `ESTIMATE_PUBLIC_ORIGIN`, `ESTIMATE_PUBLIC_BASE`, `CHANGE_PUBLIC_BASE`).
2. `npx wrangler deploy` → note the assigned `*.workers.dev` URL. Nothing in the app or dashboards points here yet.
3. Run every one of the 11 endpoints (+ the 4 stripe/connect sub-routes) against this deployed URL with the same request shapes used in Phase 1 step 5, this time against the *deployed* Worker rather than `wrangler dev` — confirms secrets are wired correctly in the real environment, not just local `.dev.vars`.
4. Write the endpoint-by-endpoint diff table (Vercel response vs Workers response, per route) into this phase's gate report — this is the evidence the owner needs before approving Phase 5's cutover.
5. No commit beyond what Phases 1-3 already produced — this phase is verification only, plus the `wrangler.toml` `[vars]` addition: `git add backend-workers/wrangler.toml && git commit -m "chore: wire non-secret env vars for deployed verification"`.

## Phase 5 — Cutover (owner-executed dashboard steps; sequence matters)

Everything up to here is reversible with zero user-facing risk — the Vercel backend keeps serving production traffic untouched. This phase is NOT something to run ahead into; **stop after Phase 4's report and get explicit go-ahead**, then execute this sequence in order (each step is independently reversible except the last):

1. Stripe Dashboard → Developers → Webhooks → update the Connect webhook endpoint URL from `https://backend-tradeready1.vercel.app/api/stripe/webhook` to the Workers URL. Stripe will start sending live events to the new endpoint immediately.
2. RevenueCat Dashboard → update the webhook URL similarly for `subscription/webhook`.
3. Decide the domain question from the scoping discussion: stay on `*.workers.dev`, or attach a Cloudflare custom domain (e.g. `api.gettradereadyapp.com`) via Workers & Pages → Custom Domains (zero DNS-provider friction since the zone's already on Cloudflare). This is an owner call, not a technical constraint.
4. Update `app.json`'s `expo.extra.backendUrl` (`tradeready-config-and-flags` §1a) to the new URL, then ship via `eas update` (OTA) — this reaches installed apps as soon as it's published, so only do this once steps 1-2 have been live and monitored for a full day with no webhook failures in the Stripe/RevenueCat dashboards.
5. Monitor both backends in parallel for a few days (Vercel backend still deployed but receiving no traffic once step 4's OTA has propagated) before Phase 6 decommissions it.

## Phase 6 — Decommission + docs

1. Delete the Vercel project (or leave it deployed-but-unused for a rollback window — owner's call) and remove `backend/` from the repo once the owner confirms the Workers backend has run cleanly for the monitoring window.
2. Update per the `tradeready-docs-and-writing` doc-update checklist: README's Step 3 (currently references deploying "the serverless functions" — update to Workers), the `backend/` file-map entry, and `tradeready-config-and-flags` §3's Vercel env var table (becomes a Workers secrets table; the 12-function-cap note in `tradeready-run-and-operate` / `project_vercel_function_cap.md` becomes obsolete and should say so, not be silently deleted).
3. Gate → commit `docs: update README/config-and-flags for Cloudflare Workers backend`.

---

## Final

Each phase's report follows the house format (`tradeready-docs-and-writing` §4): What was done, Verified (numbers/diffs, not adjectives — this plan has no tsc/test/lint gate, so "Verified" means the endpoint-diff table), Confidence Level, Missing Context, Recommended Next Step. **Stop after Phase 4's report and wait for explicit go-ahead before Phase 5** — that phase touches live Stripe/RevenueCat webhook routing and a user-facing OTA, which is exactly the class of action `tradeready-change-control` reserves for owner approval.
