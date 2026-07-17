# TradeReady — Monthly Ops & Scaling Checklist

Written 2026-07-16, just after the 1.0 App Store submission. This is a ~10-minute
pass to run once a month. It exists because TradeReady is local-first: the app runs
off data on the user's phone, so almost nothing scales with user count. The three
things that do — Supabase (sync + sign-in), the Vercel backend (mostly the AI
proxy), and the Resend reminder emails — all hit **plan quotas** long before they
hit performance limits. That makes scaling a monitoring habit, not an engineering
project.

All free-tier numbers below are **as of July 2026** and providers change them —
when this file and a provider's Usage page disagree, the Usage page wins.

---

## One-time: confirm which plan each service is on

None of this is visible from the code — it lives in the provider dashboards, so it
was **unverified** when this doc was written. Do this once, tick the boxes, and
date it.

- [ ] **Vercel** — vercel.com → `backend` project → Settings → General.
      **If it says Hobby, upgrade to Pro (~$20/mo) as soon as the app has paying
      users.** Hobby's terms prohibit commercial use — this one is about
      compliance, not capacity, so it doesn't wait for a usage signal.
- [ ] **Supabase** — supabase.com/dashboard → organization → Billing. Free is fine
      at launch; note the plan here when checked.
- [ ] **Resend** — resend.com → Settings/Billing. Free = 100 emails/day, 3,000/month.
- [ ] **Groq** — console.groq.com → Settings → Limits. Free tier has
      requests-per-minute and tokens-per-day caps that all users share through the
      server key.
- [ ] **Sentry** — tradeready-3r.sentry.io → Settings → Subscription. Free ≈ 5k
      errors/month.
- [ ] **PostHog** — us.posthog.com → Billing. Free = 1M events/month.
- [ ] **RevenueCat** — app.revenuecat.com. Free until ~$2,500/month tracked revenue.
- [x] **Sentry alert rules created** — done 2026-07-16 via
      `scripts/create-sentry-alerts.mjs`; all three verified live (re-run printed
      SKIP for each). Recipient: the org's sole member.

---

## The monthly 10-minute pass

| # | Service | Open | Look at | Act when |
|---|---------|------|---------|----------|
| 1 | Supabase | supabase.com/dashboard/project/ncbqswfdvckmdocbawaa → Reports / Usage | Database size, Egress, Auth MAU | DB above ~400 MB (free cap 500 MB) or egress past ~70% of quota mid-month → Pro ($25/mo). But read "the cheap lever" below first. |
| 2 | Vercel | vercel.com → `backend` project → Usage + Observability | Function invocations, error rate, p95 duration | p95 on `/api/ai-chat` creeping toward the 10 s `maxDuration` (`backend/vercel.json`), or a rising error rate → check Groq before paying Vercel anything. |
| 3 | Resend | resend.com → Emails / Metrics | Emails sent per day | Sustained days above ~70 (free cap 100/day) → paid plan (~$20/mo for 50k/mo). |
| 4 | Groq | console.groq.com → Usage | Request volume and 429 counts | Any recurring 429s → switch the account to the pay-as-you-go tier (cheap for `llama-3.1-8b-instant`). |
| 5 | Sentry + PostHog | Subscription / Billing pages | Errors/month vs 5k; events/month vs 1M | Nearing a cap → upgrade or trim events. Overrunning these blinds the monitoring; the app itself is unaffected. |
| 6 | Reminder cron | Vercel → `backend` → Logs, filter `/api/cron/send-reminders` | The daily 15:00 UTC run (schedule in `backend/vercel.json`) returns 200 | Any streak of 401/500 → check `CRON_SECRET` / `RESEND_API_KEY` env vars, then Resend status. |

**Leading indicator:** the PostHog MAU trend. If active users double month-over-month,
run this pass mid-month instead of waiting for the next one.

---

## When a Sentry alert fires: reading the signal

The three rules in Appendix A email the owner when something new breaks, something
fixed comes back, or error volume spikes. Every handled failure in the app carries a
`context` extra (`utils/analytics.ts:41`) — open the Sentry issue, find `context`
under "Additional Data", and use this map:

| `context` value | Points at | First thing to check |
|---|---|---|
| `aiChat` | Groq AI proxy (`backend/api/ai-chat.js`) | Groq 429s/quota. The proxy allows 20 turns/user/minute (`backend/api/ai-chat.js:24`), but all users share one Groq key. |
| `generatePaymentLink`, `stripeConnect`, `stripeDisconnect` | Stripe endpoints on the backend | Vercel function logs, then the Stripe dashboard. |
| `pushQueue`, `pullRemote`, `initialSync` | Supabase sync | status.supabase.com, then the Supabase usage quotas (row 1 above). |
| `purchase`, `restorePurchases` | RevenueCat | RevenueCat status page and dashboard. |
| `deleteAccount` | Backend delete-account endpoint | Vercel function logs. |
| `onboardingFinish`, screen-load contexts | App-local code | Normal bug triage — not a scaling signal. |

A **volume spike alert with sync contexts across many users** is the "backend is
down or a quota just ran out" signature — check rows 1–4 of the monthly table in
order.

---

## What runs out first (the expected order)

1. **Vercel Hobby terms** — immediately, if applicable; see the one-time list.
2. **Resend 100/day** — scales with overdue invoices from opted-in users, not with
   total users. Cheap upgrade.
3. **Groq free-tier caps** — a handful of simultaneous AI Coach users can trip
   shared per-minute limits. Cheap upgrade.
4. **Supabase free tier** — sync pushes whole-record JSON blobs, so egress grows
   faster than user count. **The cheap lever:** implementing per-record sync change
   tracking (a known open performance item) cuts egress substantially — worth
   doing before paying for Pro if egress is what trips.
5. **Sentry/PostHog event caps** — lose visibility, not functionality.
6. **Actual compute** — Vercel functions scale horizontally on their own; nothing
   to do here for a long time.

---

## Appendix A — Sentry alert rules (one-time setup)

Three rules on the `tradeready-3r` org, `react-native` project, all emailing the
owner:

1. **New error type — notify owner.** Fires when Sentry sees an error it has never
   seen before (first-seen). Catches every new failure mode, including the first
   quota rejection from any provider.
2. **Resolved error came back — notify owner.** Fires when an issue marked resolved
   regresses or an archived one reappears.
3. **Error volume spike — >20 errors/hour.** Fires when total error events cross 20
   in an hour, whatever the issue. This is the "breaking at scale" tripwire; raise
   the threshold as real usage grows.

### To create them (script — preferred)

1. Create an **org auth token**: tradeready-3r.sentry.io → Settings → Auth Tokens →
   Create New Token, scopes `alerts:write`, `org:read`, `project:read`,
   `member:read`.
2. From the `tradeready/` folder, in PowerShell:

   ```powershell
   $env:SENTRY_AUTH_TOKEN = "sntrys_..."
   node scripts/create-sentry-alerts.mjs
   ```

The script is safe to re-run (existing rules are skipped, not duplicated) and
prints links to each created rule. Rules 1–2 use Sentry's workflow-engine API
(beta as of 2026-07), so they may appear under the new Alerts UI rather than the
legacy list; rule 3 is a standard metric alert. All three should be visible at
tradeready-3r.sentry.io → Alerts.

### To create them by hand (UI fallback)

In tradeready-3r.sentry.io → Alerts → Create Alert:

- Rules 1–2: choose **Issues**, condition "A new issue is created" (rule 1) or
  "changes state from resolved to unresolved" / "reappears" (rule 2), action
  "Send a notification via email" to the owner, project `react-native`.
- Rule 3: choose **Errors → Number of Errors**, project `react-native`, threshold
  20 per 60 minutes, critical action email to the owner.

Once created, tick the box in the one-time list above and date it.
