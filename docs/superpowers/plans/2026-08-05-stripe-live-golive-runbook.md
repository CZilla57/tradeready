# Stripe live-mode go-live runbook (owner-run)

Written 2026-08-05. Companion to `2026-08-05-cloudflare-workers-owner-runbook.md`,
which reserved this as a "separate future workstream" (its Part 2 mode rule).

**What this changes:** the payment-link system (System A, Stripe Connect) moves from
sandbox to real money. No code changes anywhere — two secrets per backend, one new
webhook endpoint, one SQL cleanup. RevenueCat / Supabase / Resend / Groq are untouched.

**Current-state facts this runbook relies on (verified 2026-08-05):**
- Both backends (Vercel `backend-tradeready1.vercel.app`, Worker
  `tradeready-backend.tradeready.workers.dev`) run the SAME sandbox `sk_test_` key.
- The app still calls Vercel (backendUrl OTA pending); the sandbox Stripe webhook
  already points at the **Worker** (flipped at cutover). Both backends write the same
  Supabase DB, so webhook-at-Worker works even while the app calls Vercel.
- The Stripe account has **never activated live payments** — `sk_live_` keys do not
  exist yet. That activation is the actual work here; the key swap is minutes.
- No Stripe key ships in the app bundle or public pages (grep-verified: no `pk_`/`sk_`
  outside backend env docs). Nothing app-side needs a build or OTA for this.

---

## Part 1 — Activate live payments (Stripe dashboard, owner identity required)

1. dashboard.stripe.com → exit the sandbox → complete **live activation**: business
   details, identity verification, bank account (payout destination for the PLATFORM
   account — user payouts go to their own Express accounts, this is just required to
   activate).
2. **Connect platform profile** (Settings → Connect → Platform profile, live mode):
   Stripe requires the platform questionnaire (loss-liability acknowledgment etc.)
   before live Express accounts can be created. Also set Connect **branding**
   (name/icon) — it appears on the hosted Express onboarding your users see.
3. Wait for Stripe to confirm activation (usually instant to a day).

## Part 2 — Create the live webhook endpoint (points at the Worker)

Live mode and test mode have separate webhook lists; the sandbox endpoint does not
carry over.

1. Live mode → Developers → Webhooks → Add endpoint:
   - URL: `https://tradeready-backend.tradeready.workers.dev/api/stripe/webhook`
   - **Listen to: Events on Connected accounts** (NOT "your account" — this is the
     setting people miss; connected-account checkouts fire there)
   - Event: `checkout.session.completed`
2. Reveal and copy its signing secret (`whsec_...`). Keep it handy for Part 3.
3. Live mode → Developers → API keys → copy the `sk_live_...` secret key.

## Part 3 — Flip the secrets (order minimizes the mismatch window)

1. Worker (from `tradeready/backend-workers/`, wrangler logged in):

   ```
   npx wrangler secret put STRIPE_SECRET_KEY          # paste sk_live_...
   npx wrangler secret put STRIPE_CONNECT_WEBHOOK_SECRET   # paste the live whsec_...
   ```

   Takes effect immediately (wrangler creates a new deployment per secret).

2. Vercel: dashboard → backend-tradeready1 → Settings → Environment Variables →
   replace `STRIPE_SECRET_KEY` with the same `sk_live_` value, then redeploy
   (manual CLI, from `tradeready/backend/`: `vercel --prod`). Vercel's
   `STRIPE_CONNECT_WEBHOOK_SECRET` can stay as-is — the live webhook points at the
   Worker; Vercel's webhook endpoint no longer receives events.

   Window note: between steps 1 and 2 the Worker is live-mode while the app (via
   Vercel) is still test-mode. Nothing is lost — a live payment's webhook would
   only exist after Vercel flips anyway, and any in-flight sandbox webhook retries
   just 400 until they stop mattering. Do the two steps back-to-back regardless.

3. `.dev.vars` (local dev) **keeps the sandbox keys** — local/dev work should stay
   in test mode forever. Same for any future `wrangler dev` testing.

## Part 4 — REQUIRED data cleanup: stale sandbox account IDs

Every row in Supabase `stripe_accounts` references a **sandbox** `acct_...` ID —
those IDs do not exist in live mode. The code reuses a stored ID unconditionally
(`createConnectAccount.js` — "Reuse an existing account if one was already created"),
so after the flip an affected user is soft-locked: connect-status reports
`connected:false` (the invalid-account catch), the UI shows the Connect button, and
every tap returns the generic 500 — there is no user-visible way out because the
Disconnect button only renders while connected.

1. First look: SQL editor → `select user_id, stripe_account_id, created_at from stripe_accounts;`
   — note who is affected (cross-check the sandbox dashboard's connected accounts if
   you want to know whether any are real users vs. your own test runs).
2. Then, at flip time: `delete from stripe_accounts;`
   Users re-onboard from Settings → Connect Stripe account — this time for real
   (live Express onboarding wants real SSN/bank data, unlike the sandbox one).

## Part 5 — After the flip

1. **Disable (or delete) the sandbox webhook endpoint** in the sandbox's
   Developers → Webhooks — its events will 400 against the Worker's new live
   signing secret forever and just generate retry noise.
2. Owner smoke (device): Settings → Connect Stripe account → live onboarding
   completes → create an invoice → payment link URL must be `buy.stripe.com/...`
   with **no `/test_`** → pay it with a real card (smallest amount) → background +
   foreground the app → invoice shows Paid. Refund yourself from the connected
   account's dashboard afterward.
3. Check Worker logs (`npx wrangler tail`) during the smoke for the webhook 200.

## Known residual: cached test links on devices

`resolvePaymentLink` (utils/invoiceHelpers.ts) reuses a cached `invoice.paymentLinkUrl`
while the amount is unchanged — an invoice that ever fetched a sandbox link keeps
offering `buy.stripe.com/test_...` after go-live until the amount is edited. If only
your own test data ever created links this is moot (and the Part 4 delete means new
users start clean). Optional one-line OTA guard: in `resolvePaymentLink`, treat a
cached URL containing `buy.stripe.com/test_` as a cache miss (safe in both modes —
test mode just re-mints a test link). Ask a session to build it if wanted.
