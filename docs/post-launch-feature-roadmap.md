# Post-Launch Feature Roadmap — Solo-Operator Features

**Created:** 2026-07-17 · **Statuses updated:** 2026-08-06
**Status:** Items **1–7 and 9 are SHIPPED** (merged to master; 1–2 OTA'd 2026-07-30, 5 OTA'd earlier, the rest live or riding the post-1.1.0 OTA). Item 8 (GPS mileage) remains backlog and approval-gated; item 10 stays deferred (evaluate-first — deferral reaffirmed 2026-08-06). For what comes next, see **"2026-08-06 update — external audit & next queue"** below. Nothing may be claimed in the store listing until merged, shipped, and device-smoke-tested.

## What this is

Ten features the big pro apps (Jobber, Housecall Pro, QuickBooks Self-Employed) have that TradeReady lacks and that genuinely help a **one-person operation**. Team/dispatch/multi-tech features were deliberately excluded. Ordered by leverage-per-engineering-hour and dependency: infra-reuse wins first, native/web-heavy builds last.

## How to use the kickoff prompts

Each phase has a **Kickoff prompt** — paste it when it's time to build that feature. Every prompt assumes the owner's working rules:

- Start with `superpowers:brainstorming`, then produce a phase-gated plan and **stop for owner go-ahead** before writing code.
- Load `tradeready-architecture-contract` before touching navigation, status transitions, data shapes, or shared UI.
- Never land on a red gate (tsc / tests / lint). No new dependencies or SDK bumps without explicit owner approval.
- A feature may not appear in the store listing until it's built **and** device-smoke-tested (claims discipline).

---

## Rule of the road: ship order

| # | Feature | Impact | Effort | Reuses | Status (2026-08-06) |
|---|---------|--------|--------|--------|---------------------|
| 1 | Estimate approval loop (+ e-sign) | 🔥🔥🔥 | Med | SendEstimateScreen, status pipeline, hosted legal site | **SHIPPED** — merged, OTA'd 2026-07-30 |
| 2 | Appointment & "on my way" reminders | 🔥🔥🔥 | Low–Med | Notifications + composers (as built — cron/Resend rejected in design) | **SHIPPED** — merged, OTA'd 2026-07-30 |
| 3 | Deposits / partial payments | 🔥🔥 | Med | Stripe Connect, invoice model | **SHIPPED** — merged; migration + backend live |
| 4 | Tax set-aside / quarterly estimate | 🔥🔥🔥 (differentiator) | Med | P&L data, mileage, AI coach | **SHIPPED** — merged `acbeff1` |
| 5 | Receipt OCR | 🔥🔥 | Med | Photo pipeline, backend AI proxy | **SHIPPED** — merged `8144eca`, OTA'd |
| 6 | Recurring invoices (maintenance plans) | 🔥 | Med | RecurringJobs engine, invoice model | **SHIPPED** — merged 2026-08-01 |
| 7 | Accounting / CSV export | 🔥 | Low | Existing money/expense data | **SHIPPED** — merged 2026-08-01 |
| 8 | Automatic (GPS) mileage | 🔥🔥 | High (native) | MileageLog / Trip model | backlog — approval-gated (dep + privacy label) |
| 9 | Online booking / request-a-quote link | 🔥🔥🔥 (new-work ceiling) | High (web) | Sync write path, Jobs list | **SHIPPED** — merged `cec034f` 2026-08-04 |
| 10 | Two-way SMS inbox | 🔥 | High | Outreach infra — evaluate before committing | deferred (reaffirmed 2026-08-06) |

---

## Phase 1 — Estimate approval loop (+ optional e-signature)

> **STATUS: BUILT 2026-07-18** on `feat/estimate-approval-loop` (15 commits;
> [PR #4](https://github.com/CZilla57/tradeready/pull/4) open, mergeable). As
> designed here, plus two decisions the prompt left open: the write-back is
> **service-role endpoints + an on-device reconciler** (poll-style, not a
> webhook), and a **`declined` job status** was added to the pipeline. E-sign
> shipped as typed-name consent with an immutable consent snapshot; the
> customer-facing `estimate.html` lives on a held branch
> (`feat/estimate-approval-legal`) in the tradeready-legal repo. **To go
> live:** merge, deploy the backend, push the legal-site branch, device E2E.

**Why:** `SendEstimateScreen` currently sends a PDF into the void with no way for the customer to say yes. This is the single most-loved solo feature in Jobber/Housecall — customer taps **Approve**, the job auto-advances `estimate → approved → scheduled`, and you capture a timestamp of consent. Directly converts quotes to revenue on infrastructure you already own.

**Kickoff prompt (historical — already executed):**
> Load `superpowers:brainstorming` and `tradeready-architecture-contract`, then design an estimate-approval loop. Today `SendEstimateScreen` sends a PDF and stops. I want the customer to receive a link (host it on the existing github.io legal/landing site) where they can view the estimate and tap Approve or Decline; approval should flow back and advance the job through the existing status pipeline (respect the approved→scheduled transition rules) and stamp a consent timestamp. Consider a typed-name or drawn e-signature as an optional add-on. Produce a phase-gated plan — including the write-back path (webhook vs poll) and how it reconciles with local-first sync — and stop for my go-ahead before coding.

## Phase 2 — Appointment & "on my way" reminders

> **STATUS: BUILT 2026-07-18** on `feat/appointment-reminders` (12 commits;
> [PR #3](https://github.com/CZilla57/tradeready/pull/3) open). **The
> architecture below was evaluated and REJECTED in design** — the committed
> spec is explicit: *no backend, cron, Resend, or Supabase table; everything
> is on-device*, because Expo cannot silently send SMS and no cron can know
> when you leave for a job. As built: a day-before local notification opens a
> pre-filled SMS/email composer (tap-to-send, never auto-sent), and "on my
> way" is a one-tap button on the job. Of this section's claimed reuse, only
> the notification plumbing held. **To go live:** merge + device smoke test.

**Why:** Your auto-outreach infra (Resend + Vercel cron) only chases overdue invoices today. Extend the same machinery to send the customer an appointment confirmation the day before and an "on my way" text the morning of the job. For a solo op who can't answer the phone from a ladder, this is the biggest professionalism-per-effort win — Housecall's signature move, and you're most of the way there.

**Kickoff prompt (historical — already executed; the built design deliberately diverged, see STATUS):**
> Load `superpowers:brainstorming`, `tradeready-architecture-contract`, and skim the auto-outreach setup (the Resend cron in `backend/`, plus the overdue-reminder flow). I want customer-facing appointment reminders: a confirmation the day before a scheduled job and an optional "on my way" message the morning of. Reuse the existing outreach/notification plumbing rather than adding a new channel. Cover opt-in/settings, timezone handling, and dedupe (don't double-send). Phase-gated plan, stop for go-ahead.

## Phase 3 — Deposits / partial payments / progress billing

> **STATUS: BUILT 2026-07-18** on `feat/deposits-partial-payments` (all
> phases: payment ledger with void semantics, sync union merge + Postgres
> trigger, recording UI, money-surface sweep, deposit requests with
> partial-amount links, PDF balance). No PR yet. **SHIP-GATED:** the Supabase
> migration is not applied and the backend is not deployed — do not ship any
> build off a master containing this branch until both are done, in that
> order. The authoritative gate is `docs/release-checklist.md`; the runbook
> is `docs/deposits-resume-here.md` §4.

**Why:** Invoices + Stripe links are all-or-nothing right now. Solo trades routinely take a deposit before starting — "request 50% up front" is a common reason people churn to Jobber. Reuses your Stripe Connect payment-link path.

**Kickoff prompt (historical — already executed):**
> Load `superpowers:brainstorming`, `tradeready-payments-and-billing`, and `tradeready-architecture-contract`. I want to support deposits and partial payments on invoices: request a fixed amount or a percentage up front, generate a Stripe payment link for that partial amount, and track amount-paid vs balance-remaining on the invoice (the mark-paid webhook must reconcile partials, not just full payment). Show remaining balance in the UI. Design the invoice-model changes carefully — flag any migration. Phase-gated plan, stop for go-ahead.

## Phase 4 — Tax set-aside / quarterly estimate

> **STATUS: BUILT 2026-07-18** on `feat/tax-set-aside` — **stacked on Phase
> 3's branch** (income comes from the payment ledger), so it merges only
> after deposits does. Money-tab card (current IRS payment-period reserve +
> YTD + deadline) with a settings modal (user income-tax rate; mileage-vs-fuel
> election, neither until chosen), and the AI coach cites the figures under a
> guidance-only constraint. Spec:
> `docs/superpowers/specs/2026-07-18-tax-set-aside-design.md`. Carries an
> **annual January maintenance obligation** (SS wage base + mileage-rate
> default — see `docs/ops-monthly-checklist.md`). **To go live:** merge after
> deposits + device smoke.

**Why:** You already track income (P&L), expenses, and mileage — you're one screen and some math away from "set aside ~$X for taxes this quarter." This is literally why solo tradespeople pay for QuickBooks Self-Employed, and it fits TradeReady's "teaches you the business" positioning better than any competitor because it can lean on your existing AI coach. Strongest **differentiator** on the list.

**Kickoff prompt (historical — already executed):**
> Load `superpowers:brainstorming`, `trade-business-reference`, and `tradeready-ai-layer`. I want a tax set-aside feature: estimate quarterly tax owed from net profit (income minus deductible expenses and mileage) using a user-set effective rate, and surface a "set aside $X" figure plus quarter deadlines. This is guidance, not filing — be careful with disclaimer language (we are not tax advisors). Consider surfacing it through the AI coach as well as a Money-tab card. Phase-gated plan, stop for go-ahead.

## Phase 5 — Receipt OCR

> **STATUS: BUILT 2026-07-19** on `feat/receipt-ocr` (off master — deliberately
> NOT stacked on the deposits/tax chain; merges independently). As designed
> here: attach a receipt photo → Claude vision extracts merchant/amount/date/
> category → pre-fills only fields the user hasn't touched, never auto-saves.
> Routing mirrors pricebookAI (user anthropicKey → direct; else backend
> `receipt-extract.js`, JWT + 5/min rate limit); every failure degrades to
> plain manual entry. No new dependencies, no data-shape changes. Spec:
> `docs/superpowers/specs/2026-07-19-receipt-ocr-design.md`. **To go live:**
> merge, deploy backend, push the held `feat/receipt-ocr-legal` privacy-policy
> branch (tradeready-legal), device smoke.

**Why:** Receipts are attach-only today. QuickBooks' pitch to solos is "snap a receipt → expense auto-fills." This reuses your existing photo pipeline and the backend AI proxy for extraction — much cheaper than it sounds.

**Kickoff prompt (historical — already executed):**
> Load `superpowers:brainstorming` and `tradeready-ai-layer`. I want receipt OCR: when a user attaches a receipt photo to an expense, extract merchant, amount, date, and a suggested category and pre-fill the expense form for confirmation (never auto-save without review). Reuse the existing photo pipeline and route extraction through the backend AI proxy (respect rate limits and payload caps). Handle low-confidence/failed extraction gracefully. Phase-gated plan, stop for go-ahead.

## Phase 6 — Recurring invoices (maintenance plans)

> **STATUS: BUILT 2026-08-01** on `feat/recurring-invoices`. As designed in
> `docs/superpowers/specs/2026-07-31-recurring-invoices-design.md`: standalone
> per-customer rules (amount + cadence + end conditions + pause/resume),
> shared recurrence helpers extracted to `utils/recurrence.ts`, generation on
> sign-in/app-foreground, review-and-send notification (`rinv_` namespace) —
> never auto-sent; payment links mint on demand in the existing send flow.

**Why:** You have recurring *jobs* but not recurring *billing*. Maintenance plans (monthly/quarterly service) are steady solo revenue and a natural extension of the recurring-jobs engine.

**Kickoff prompt (historical — already executed):**
> Load `superpowers:brainstorming` and `tradeready-architecture-contract`, and read the recurring-jobs engine (`utils/recurringJobs.ts`, `RecurringJobsScreen`). I want recurring invoices for maintenance plans: generate an invoice on a schedule for a customer, optionally with a payment link. Mirror the recurring-jobs pattern rather than inventing a new one. Cover pause/skip/end and how generated invoices appear in the Invoices list. Phase-gated plan, stop for go-ahead.

## Phase 7 — Accounting / CSV export

> **STATUS: BUILT 2026-07-31** on `feat/csv-export`. As designed in
> `docs/superpowers/specs/2026-07-31-csv-export-design.md`: income/expenses/
> mileage CSVs from a Money-tab Export Data modal (header download icon),
> range presets + custom, share-sheet delivery. Income rows are payment-level
> and sum-equivalent to `collectedInRange` (tested). No new dependencies; no
> schema changes; JS-only → OTA-eligible. **To go live:** merge + device
> smoke test.

**Why:** Low effort, high value once a year at tax time. Export income and expenses to CSV (and optionally a QuickBooks-friendly format) so the numbers can leave the app.

**Kickoff prompt (historical — already executed):**
> Load `superpowers:brainstorming`. I want a CSV export of income and expenses (date range selectable) from the Money tab, using the data already in storage — no schema changes expected. Consider a column layout that imports cleanly into QuickBooks/spreadsheets. Use the platform share sheet to hand off the file. Phase-gated plan, stop for go-ahead.

## Phase 8 — Automatic (GPS) mileage tracking

**Why:** Mileage is manual entry today (`AddTripScreen`). QB Self-Employed auto-tracks drives via GPS — a real solo pain-saver. Bigger native lift: background location, battery, permission prompts, and App Store review scrutiny on always-on location.

**Kickoff prompt:**
> Load `superpowers:brainstorming`, `tradeready-architecture-contract`, and `tradeready-build-and-env`. I want optional automatic mileage tracking via GPS that creates trips in the existing Trip/MileageLog model. This needs background location — call out the dependency/permission implications up front (background location is a dependency + app.json change requiring my approval, and an App Store privacy-label update). Keep it strictly opt-in with a clear battery/privacy explanation. Given the cost, first give me a go/no-go recommendation, then a phase-gated plan. Stop for go-ahead.

## Phase 9 — Online booking / request-a-quote link

**Why:** Highest ceiling for winning *new* work — solo ops lose jobs by missing calls while working. A shareable link where a customer requests a job or picks a slot, dropping straight into your Jobs list. Big build: needs a hosted web surface and an authenticated write path into sync.

**Kickoff prompt:**
> Load `superpowers:brainstorming`, `tradeready-architecture-contract`, and `tradeready-storage-and-sync`. I want a public "request a quote / book a slot" link a tradesperson can share; submissions should land as new leads/jobs in their Jobs list. Design the hosted web form and — most importantly — the secure write path into the owner's data (how an unauthenticated public submission safely reaches one user's account through Supabase/RLS without exposing anything). This is the largest item on the roadmap; give me an architecture options memo first, then a phase-gated plan. Stop for go-ahead.

## Phase 10 — Two-way SMS inbox (evaluate first)

**Why:** A central inbox for customer texts is nice but heavy, and often redundant for a one-person shop who just uses their phone's Messages app. Listed last on purpose — validate demand before building.

**Kickoff prompt:**
> Load `superpowers:brainstorming`. Before any build, I want an honest evaluation: does a two-way SMS inbox add enough over a solo operator's native Messages app to justify the cost (a messaging provider dependency, phone-number provisioning, inbound webhooks, and ongoing per-message fees)? Give me a recommendation with the tradeoffs. Only if it's a go, produce a phase-gated plan. Stop for go-ahead either way.

---

## 2026-08-06 update — external audit & next queue

A second external audit (Codex; the first was ChatGPT's, reviewed 2026-08-03) was
assessed against the codebase and adopted into this roadmap. It largely converged
with existing plans — corroboration, not redirection. Several of its "missing"
items were already built: overlap detection and smart schedule pickers shipped;
below-break-even sanity warnings live in the pricing calculator; and the Today
Insights card already covers unscheduled approved jobs, open slots, and labor
overrun. The genuinely new material and the resulting queue:

### ⚠️ Release-gate checks (OWNER — before/at the next release steps)

1. **Verify the ASC privacy nutrition label for the in-review 1.1.0 build
   declares photo collection** — receipt OCR ships in it, and this may not be
   deferrable to the next submission. (ASC privacy labels are generally editable
   without a new binary — verify in App Store Connect.)
2. **The trip-sync OTA must not ship ahead of the mileage privacy-label
   correction.** The durability work (`0288972`, riding the post-1.1.0 OTA)
   starts syncing mileage trips to the cloud; the privacy label must reflect
   that before the OTA goes out.

### Next queue (rough order)

1. **Claims accuracy** — already sequenced: listing overclaims fix at the next
   store submission (see the 2026-08-03 review notes in the session records).
2. **Durability** — trip/rule cloud-sync built (`0288972`); job-photo R2 sync is
   fully planned but **hard-blocked on Cloudflare-migration Phase 6** (Vercel
   decommission) per its own plan doc.
3. **CSV data import** (added 2026-08-06, owner-initiated) — migrate customers,
   jobs + schedule, and full money history from Jobber / Housecall Pro /
   QuickBooks CSV exports. Design approved and spec committed:
   `docs/superpowers/specs/2026-08-06-data-import-design.md`. JS-only, zero new
   dependencies, OTA-eligible. Sequencing vs calendar/availability is an owner
   call at kickoff.
4. **Calendar / availability view** — agreed as the **next big feature**. The
   scheduling guardrails (overlap warnings, smart pickers, week strip) already
   exist; the missing surface is the calendar itself — a month view is the known
   delta.
5. **Estimated-vs-actual job profitability** — agreed. The Today Insights
   labor-overrun rule is the first step. The genuinely missing insight pieces:
   an **invoice-level payer-behavior hint** and **materials-vs-estimate on job
   completion**.
6. **Activation instrumentation before any paywall change** — pre-paywall sample
   exploration is a legitimate conversion experiment but *not* obviously right:
   the hard-paywall-after-onboarding flow was a deliberate owner decision in the
   2026-08-03 onboarding restructure, and the 2-week trial already provides
   try-before-pay. First add **trial-start** and **activation** ("created a real
   customer and estimate") telemetry events; revisit the flow only with data.
7. **Accountant package** — low urgency: bundle the existing CSV exports with
   control totals. Never infer missing historical fields.

### Deferrals reaffirmed

Teams/dispatch, two-way SMS inbox (#10), and a web app stay deferred — the
depth-not-breadth, solo-operator thesis holds.

---

## Notes

- **Widgets & Siri (added 2026-08-02):** home-screen widgets and Siri/App Intents
  are planned outside this ten-item list — see `docs/widget-plan.md` (App Group
  bridge foundation, Next Job + Job Timer widgets, voice Tier 1). ⚠️ backlog,
  native, ships only via a fresh EAS build.
- **2026-07-18 status update:** items 1–4 were built in order on their own
  feature branches (see the STATUS blocks). Their kickoff prompts are kept as
  historical record of what was asked for — where the build diverged from the
  prompt (notably Phase 2's on-device design), the STATUS block is the truth.
- **Sequencing rationale:** 1–2 reuse the outreach/notification infra and move money fastest; 3 reuses Stripe; 4–7 reuse existing data + AI with modest new surface; 8–9 are native/web-heavy and carry dependency + review risk; 10 is a maybe.
- **Every phase** ends with owner sign-off before code, follows the no-red-gate rule, and must be device-smoke-tested before its capability is claimed in the listing.
- Revisit priority after launch based on real user feedback — this order is a hypothesis, not a commitment.
