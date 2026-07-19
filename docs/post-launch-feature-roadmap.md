# Post-Launch Feature Roadmap — Solo-Operator Features

**Created:** 2026-07-17 · **Statuses updated:** 2026-07-18
**Status:** Items **1–4 are BUILT** on unmerged feature branches (owner-gated; see the per-phase STATUS blocks below — merges, deploys, and device smoke tests remain). Items 5–10 are still backlog. **None of this blocks the iOS App Store submission**, and nothing may be claimed in the store listing until merged, shipped, and device-smoke-tested.

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

| # | Feature | Impact | Effort | Reuses | Status (2026-07-18) |
|---|---------|--------|--------|--------|---------------------|
| 1 | Estimate approval loop (+ e-sign) | 🔥🔥🔥 | Med | SendEstimateScreen, status pipeline, hosted legal site | **BUILT** — PR #4 open |
| 2 | Appointment & "on my way" reminders | 🔥🔥🔥 | Low–Med | Notifications + composers (as built — cron/Resend rejected in design) | **BUILT** — PR #3 open |
| 3 | Deposits / partial payments | 🔥🔥 | Med | Stripe Connect, invoice model | **BUILT** — ship-gated (migration + backend) |
| 4 | Tax set-aside / quarterly estimate | 🔥🔥🔥 (differentiator) | Med | P&L data, mileage, AI coach | **BUILT** — stacked on #3's branch |
| 5 | Receipt OCR | 🔥🔥 | Med | Photo pipeline, backend AI proxy | backlog |
| 6 | Recurring invoices (maintenance plans) | 🔥 | Med | RecurringJobs engine, invoice model | backlog |
| 7 | Accounting / CSV export | 🔥 | Low | Existing money/expense data | backlog |
| 8 | Automatic (GPS) mileage | 🔥🔥 | High (native) | MileageLog / Trip model | backlog |
| 9 | Online booking / request-a-quote link | 🔥🔥🔥 (new-work ceiling) | High (web) | Sync write path, Jobs list | backlog |
| 10 | Two-way SMS inbox | 🔥 | High | Outreach infra — evaluate before committing | backlog (evaluate first) |

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

**Why:** Receipts are attach-only today. QuickBooks' pitch to solos is "snap a receipt → expense auto-fills." This reuses your existing photo pipeline and the backend AI proxy for extraction — much cheaper than it sounds.

**Kickoff prompt:**
> Load `superpowers:brainstorming` and `tradeready-ai-layer`. I want receipt OCR: when a user attaches a receipt photo to an expense, extract merchant, amount, date, and a suggested category and pre-fill the expense form for confirmation (never auto-save without review). Reuse the existing photo pipeline and route extraction through the backend AI proxy (respect rate limits and payload caps). Handle low-confidence/failed extraction gracefully. Phase-gated plan, stop for go-ahead.

## Phase 6 — Recurring invoices (maintenance plans)

**Why:** You have recurring *jobs* but not recurring *billing*. Maintenance plans (monthly/quarterly service) are steady solo revenue and a natural extension of the recurring-jobs engine.

**Kickoff prompt:**
> Load `superpowers:brainstorming` and `tradeready-architecture-contract`, and read the recurring-jobs engine (`utils/recurringJobs.ts`, `RecurringJobsScreen`). I want recurring invoices for maintenance plans: generate an invoice on a schedule for a customer, optionally with a payment link. Mirror the recurring-jobs pattern rather than inventing a new one. Cover pause/skip/end and how generated invoices appear in the Invoices list. Phase-gated plan, stop for go-ahead.

## Phase 7 — Accounting / CSV export

**Why:** Low effort, high value once a year at tax time. Export income and expenses to CSV (and optionally a QuickBooks-friendly format) so the numbers can leave the app.

**Kickoff prompt:**
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

## Notes

- **2026-07-18 status update:** items 1–4 were built in order on their own
  feature branches (see the STATUS blocks). Their kickoff prompts are kept as
  historical record of what was asked for — where the build diverged from the
  prompt (notably Phase 2's on-device design), the STATUS block is the truth.
- **Sequencing rationale:** 1–2 reuse the outreach/notification infra and move money fastest; 3 reuses Stripe; 4–7 reuse existing data + AI with modest new surface; 8–9 are native/web-heavy and carry dependency + review risk; 10 is a maybe.
- **Every phase** ends with owner sign-off before code, follows the no-red-gate rule, and must be device-smoke-tested before its capability is claimed in the listing.
- Revisit priority after launch based on real user feedback — this order is a hypothesis, not a commitment.
