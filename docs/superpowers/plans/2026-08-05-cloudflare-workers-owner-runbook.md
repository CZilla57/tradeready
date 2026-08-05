# Cloudflare Workers Migration — Owner Runbook

Companion to `2026-08-05-cloudflare-workers-backend-migration-plan.md`. Phases 1–3 are
BUILT and committed on `feat/cloudflare-workers-backend` (`2775224`, `e6f6b59`, `67f1090`):
all 11 endpoints + the 4 stripe/connect sub-routes + the cron are ported to
`backend-workers/` and a 40-case request diff against the live Vercel backend came back
identical on every testable path. What remains needs YOUR hands, because it involves your
Cloudflare account, real secret values, and live dashboards. Everything below is laid out
in order; nothing here touches production until Part 5, and Parts 1–4 are risk-free.

**One plan gap found and folded in below:** the four public pages on gettradereadyapp.com
(`book.html`, `change.html`, `estimate.html`, `portal.html` in `tradeready-legal/`) each
hardcode `var API = 'https://backend-tradeready1.vercel.app/...'`. The plan's Phase 5
didn't list them; they're now step 5.4.

---

## Part 1 — Log wrangler into your Cloudflare account (~2 min, one-time)

You already have a Cloudflare account (the gettradereadyapp.com DNS zone lives there).
Run this in a terminal; it opens a browser window — approve the access request:

```bash
cd C:\dev\tradeready\tradeready\backend-workers; npx wrangler login
```

Confirm it worked:

```bash
cd C:\dev\tradeready\tradeready\backend-workers; npx wrangler whoami
```

You should see your account name/id. Everything else in this runbook depends on this.

## Part 2 — (Recommended) Give the local Worker real env values, so Claude can verify the happy paths BEFORE deploying

The 40-case diff covered every path reachable without secrets (CORS, methods, validation,
auth rejection via real Supabase). The happy paths (real JWT → Groq call, estimate
view/respond round-trip, cron batch against real tables) need real values locally.

1. ⚠️ **`vercel env pull` will NOT work for most of these** (confirmed 2026-08-05: the
   pulled file had one value, rest blank). The variables were stored as **Sensitive** in
   Vercel, and sensitive values are write-only — neither the CLI nor the dashboard can
   ever display them again. Get each value from its original source instead. Where a
   provider doesn't allow re-viewing, create an **additional** key — the old key stays
   valid, so the Vercel backend keeps running untouched. **Never "roll"/revoke an
   existing key** (that would break production).

   | Secret | Where to get it | Re-viewable? |
   |---|---|---|
   | `SUPABASE_SERVICE_ROLE_KEY` | supabase.com → project → Project Settings → API keys → `service_role` → Reveal | ✅ yes |
   | `SUPABASE_ANON_KEY` | Already known — it ships in the app: `sb_publishable_eTyJedvrw47RtZ0waCj8Bw_SDOllgvF` | ✅ (public) |
   | `STRIPE_SECRET_KEY` | dashboard.stripe.com → Developers → API keys → **Create secret key** (name it e.g. "workers-backend"). Stripe never re-shows the existing live key; a second key coexists fine. | ➕ create new |
   | `STRIPE_CONNECT_WEBHOOK_SECRET` | dashboard.stripe.com → Developers → Webhooks → the backend-tradeready1 endpoint → Signing secret → **Reveal** | ✅ yes |
   | `REVENUECAT_WEBHOOK_SECRET` | app.revenuecat.com → project → Integrations → Webhooks → the Authorization header value shown on the config page | ✅ yes |
   | `CRON_SECRET` | Self-chosen string; nothing else shares it (only guards the manual-run URL, and only for the Worker). Mint a fresh one: `node -e "console.log(require('crypto').randomBytes(24).toString('hex'))"` | ➕ mint fresh |
   | `RESEND_API_KEY` | resend.com → API Keys → **Create API key** (values are shown once; a second key coexists fine) | ➕ create new |
   | `GROQ_API_KEY` | console.groq.com → API Keys → **Create API key** (same: shown once, second key coexists) | ➕ create new |

2. Open `C:\dev\tradeready\tradeready\backend-workers\.dev.vars` (already created,
   gitignored) and replace each `placeholder` with the value from the table.
   For `ESTIMATE_PUBLIC_ORIGIN` / `ESTIMATE_PUBLIC_BASE` / `CHANGE_PUBLIC_BASE`: these
   are NOT sensitive, so the dashboard shows whether they exist and what they hold
   (vercel.com → backend-tradeready1 → Settings → Environment Variables) — add the
   lines only if Vercel has them set; if unset there, leave them out here. Note the
   answer — the same three configure `wrangler.toml` `[vars]` in Part 3.

3. Tell Claude ".dev.vars is filled" — the next session runs the full happy-path
   parallel diff (`wrangler dev` vs live Vercel, identical requests, including a real
   signed-in JWT if you paste one from the app or a test sign-in) and reports the
   endpoint-by-endpoint table before anything is deployed.

## Part 3 — Phase 4: put secrets into Cloudflare and deploy to *.workers.dev (no production impact)

Nothing points at the deployed Worker after this — it's a parallel deployment for
verification only.

1. First, mirror the optional `[vars]`: open `backend-workers\wrangler.toml` — if (and
   only if) Vercel has `ESTIMATE_PUBLIC_ORIGIN` / `ESTIMATE_PUBLIC_BASE` /
   `CHANGE_PUBLIC_BASE` set, uncomment those lines and paste the same values.
   `SUPABASE_URL` is already filled in.

2. Store the 8 secrets. Each command prompts you to paste the value (same values as
   `.dev.vars` / the Vercel dashboard), then uploads it encrypted:

```bash
cd C:\dev\tradeready\tradeready\backend-workers; npx wrangler secret put SUPABASE_SERVICE_ROLE_KEY
```

```bash
cd C:\dev\tradeready\tradeready\backend-workers; npx wrangler secret put SUPABASE_ANON_KEY
```

```bash
cd C:\dev\tradeready\tradeready\backend-workers; npx wrangler secret put STRIPE_SECRET_KEY
```

```bash
cd C:\dev\tradeready\tradeready\backend-workers; npx wrangler secret put STRIPE_CONNECT_WEBHOOK_SECRET
```

```bash
cd C:\dev\tradeready\tradeready\backend-workers; npx wrangler secret put REVENUECAT_WEBHOOK_SECRET
```

```bash
cd C:\dev\tradeready\tradeready\backend-workers; npx wrangler secret put CRON_SECRET
```

```bash
cd C:\dev\tradeready\tradeready\backend-workers; npx wrangler secret put RESEND_API_KEY
```

```bash
cd C:\dev\tradeready\tradeready\backend-workers; npx wrangler secret put GROQ_API_KEY
```

   (SUPABASE_ANON_KEY is technically public but is stored as a secret to mirror the
   Vercel setup exactly. The first `secret put` may ask to create the Worker — say yes.)

3. Deploy:

```bash
cd C:\dev\tradeready\tradeready\backend-workers; npx wrangler deploy
```

   The output ends with the assigned URL, like
   `https://tradeready-backend.<your-subdomain>.workers.dev`. **Copy it and give it to
   Claude** — the next session re-runs the whole diff suite against the deployed Worker
   (proves the secrets are wired in the real environment, per plan Phase 4 step 3) and
   writes the endpoint-by-endpoint gate table you'll approve Phase 5 on.

   Note: deploying also activates the cron trigger — the Worker will run the reminder
   batch daily at 15:00 UTC **in parallel with Vercel's cron** from this moment. That is
   safe by design: the `auto_reminder_log` claim (one-and-done per invoice, unique on
   user_id+invoice_id) makes the two crons idempotent — whichever claims first sends,
   the other skips. If you'd rather not have the parallel run at all, deploy with the
   trigger commented out in wrangler.toml `[triggers]` and re-add it at cutover.

## Part 4 — Stripe webhook live-fire test (test mode, still no production impact)

This is the money-critical endpoint; verify it against real signed Stripe events before
cutover. Needs the Stripe CLI (winget: `winget install stripe.stripe-cli`, then
`stripe login` — it opens the browser and pairs with your Stripe account).

1. Forward TEST-mode events to the deployed Worker:

```bash
stripe listen --forward-to https://<your-worker-url>/api/stripe/webhook
```

   ⚠️ `stripe listen` re-signs forwarded events with its **own** signing secret, which it
   prints at startup (`Your webhook signing secret is whsec_...`). For the duration of
   this test, put THAT value into the Worker (`npx wrangler secret put
   STRIPE_CONNECT_WEBHOOK_SECRET` from backend-workers, paste the CLI's whsec) —
   otherwise every forwarded event correctly fails signature verification with a 400.
   **After the test, set it back to the real endpoint signing secret** (the dashboard
   Reveal value from Part 2's table) — cutover reuses the existing endpoint, and editing
   its URL does not change its signing secret.

2. In a second terminal, fire a synthetic completed checkout:

```bash
stripe trigger checkout.session.completed
```

3. Expected: the `stripe listen` window shows `200`, and the Worker's response body is
   `{"received":true,"skipped":true}` — *skipped* because the synthetic session has no
   `metadata.invoiceId` and no connected account, which is exactly what the Vercel
   handler does with the same event. Bad-signature/wrong-event negative paths were
   already verified identical.
4. For a full end-to-end (real ledger write): in the app, create a payment link for a
   test invoice and pay it with Stripe's test card via the Worker-forwarded listener —
   or simply defer this to the post-cutover monitoring day, since the handler body is
   byte-identical to Vercel's except env plumbing. Claude can drive a Supabase-row
   diff for you either way — ask when you're at this step.

`wrangler tail` streams the Worker's live logs while you test:

```bash
cd C:\dev\tradeready\tradeready\backend-workers; npx wrangler tail
```

## Part 5 — Phase 5: CUTOVER (only after you approve the Phase 4 gate table)

Do these IN ORDER. Each step is independently reversible by putting the old URL back.
The Vercel backend stays deployed and working throughout — traffic just stops arriving.

**5.1 Stripe webhook URL** — dashboard.stripe.com → Developers → Webhooks → the endpoint
`https://backend-tradeready1.vercel.app/api/stripe/webhook` → ⋯ → Update details →
replace the URL with `https://<worker-url>/api/stripe/webhook` → Save. Live events flow
to the Worker immediately. Watch the endpoint's Events log for green 200s.

**5.2 RevenueCat webhook URL** — app.revenuecat.com → your project → Integrations →
Webhooks → replace the URL with `https://<worker-url>/api/subscription/webhook` → save.
(The Authorization header value stays the same secret.)

**5.3 Domain decision (yours to make, either works):**
- Stay on `*.workers.dev` — zero extra steps, the URL just isn't branded.
- Custom domain, e.g. `api.gettradereadyapp.com` — Cloudflare dashboard → Workers &
  Pages → tradeready-backend → Settings → Domains & Routes → Add → Custom domain →
  type `api.gettradereadyapp.com`. Cloudflare creates the DNS record itself (the zone
  is already there — no registrar work). If you do this, use the custom domain in
  steps 5.1/5.2/5.4/5.5 (or update them again — both URLs keep working).

**5.4 The four public pages** (plan gap, now covered): in `tradeready-legal/`, change the
one `var API =` line near the top of each of `book.html` (line 40), `change.html` (44),
`estimate.html` (40), `portal.html` (39) from
`https://backend-tradeready1.vercel.app/...` to the Worker URL (keep the `/api/booking`
or `/api/estimate` suffix), then commit+push that repo so GitHub Pages republishes.
Claude can make these edits for you — just say so at this step. Until this step runs,
those pages keep using Vercel — which keeps working — so there is no rush window.

**5.5 The app** — `app.json` → `expo.extra.backendUrl` → the Worker URL, then ship via
`eas update` (OTA). Two constraints:
- Only do this after 5.1–5.2 have run clean for a full day (check both dashboards for
  webhook failures).
- The OTA train itself is still gated on iOS 1.1.0 clearing App Review (runtimeVersion
  keeps build 6 isolated) — the backendUrl flip rides the same OTA as the rest of the
  queued JS work when that unblocks. Claude makes this edit + the OTA when you say go.

**5.6 Monitor for a few days** — Stripe webhook events log, RC webhook log,
`npx wrangler tail` (or Workers dashboard → tradeready-backend → Logs), and confirm the
Vercel project's function invocations trend to zero. Then Phase 6 (decommission Vercel +
docs sweep) — that's a Claude session with one owner decision: delete the Vercel project
or keep it dormant as a rollback target.

---

## Quick reference — what Claude does vs what you do

| Step | Who | Status |
|---|---|---|
| Port all endpoints + cron (Phases 1–3) | Claude | ✅ done, committed |
| Negative-path diff vs live Vercel (40 cases) | Claude | ✅ done, 40/40 identical |
| `wrangler login` | **You** (Part 1) | ⬜ |
| Fill `.dev.vars` with real values | **You** (Part 2) | ⬜ recommended |
| Happy-path local diff | Claude (after Part 2) | ⬜ |
| `wrangler secret put` ×8 + `[vars]` + `wrangler deploy` | **You** (Part 3) | ⬜ |
| Deployed-Worker diff suite + Phase 4 gate table | Claude (give it the URL) | ⬜ |
| Stripe CLI test-mode webhook fire | **You** (Part 4, Claude assists) | ⬜ |
| Approve cutover | **You** | ⬜ |
| Stripe + RC dashboard URL flips, domain choice | **You** (5.1–5.3) | ⬜ |
| tradeready-legal page edits + push | Claude (on your go) | ⬜ |
| app.json backendUrl + OTA | Claude (on your go, post-1.1.0) | ⬜ |
| Decommission + docs (Phase 6) | Claude (on your go) | ⬜ |
