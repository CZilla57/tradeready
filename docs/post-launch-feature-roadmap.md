# Post-Launch Feature Roadmap — Solo-Operator Features

**Created:** 2026-07-17 · **Statuses updated:** 2026-08-12
**Status:** Items **1–7, 9, and 11–15 are SHIPPED** (merged to master; see each row/STATUS block for OTA state). Item 8 (GPS mileage) remains backlog and approval-gated; item 10 (two-way SMS inbox) stays deferred (evaluate-first — deferral reaffirmed 2026-08-06). **Phases 16–22** (added 2026-08-09) are a fresh competitive-gap review against Jobber/Housecall Pro/QuickBooks Self-Employed, scoped for post-1.2 — none built yet, all need owner go-ahead at kickoff. For priorities, see **"2026-08-06 update — external audit & next queue"** below. Nothing may be claimed in the store listing until merged, shipped, and device-smoke-tested.

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

| # | Feature | Impact | Effort | Reuses | Status (2026-08-12) |
|---|---------|--------|--------|--------|---------------------|
| 1 | <span style="color:green">Estimate approval loop (+ e-sign)</span> | 🔥🔥🔥 | Med | SendEstimateScreen, status pipeline, hosted legal site | **SHIPPED** — merged, OTA'd 2026-07-30 |
| 2 | <span style="color:green">Appointment & "on my way" reminders</span> | 🔥🔥🔥 | Low–Med | Notifications + composers (as built — cron/Resend rejected in design) | **SHIPPED** — merged, OTA'd 2026-07-30 |
| 3 | <span style="color:green">Deposits / partial payments</span> | 🔥🔥 | Med | Stripe Connect, invoice model | **SHIPPED** — merged; migration + backend live |
| 4 | <span style="color:green">Tax set-aside / quarterly estimate</span> | 🔥🔥🔥 (differentiator) | Med | P&L data, mileage, AI coach | **SHIPPED** — merged `acbeff1` |
| 5 | <span style="color:green">Receipt OCR</span> | 🔥🔥 | Med | Photo pipeline, backend AI proxy | **SHIPPED** — merged `8144eca`, OTA'd |
| 6 | <span style="color:green">Recurring invoices (maintenance plans)</span> | 🔥 | Med | RecurringJobs engine, invoice model | **SHIPPED** — merged 2026-08-01 |
| 7 | <span style="color:green">Accounting / CSV export</span> | 🔥 | Low | Existing money/expense data | **SHIPPED** — merged 2026-08-01 |
| 8 | Automatic (GPS) mileage | 🔥🔥 | High (native) | MileageLog / Trip model | backlog — approval-gated (dep + privacy label) |
| 9 | <span style="color:green">Online booking / request-a-quote link</span> | 🔥🔥🔥 (new-work ceiling) | High (web) | Sync write path, Jobs list | **SHIPPED** — merged `cec034f` 2026-08-04 |
| 10 | Two-way SMS inbox | 🔥 | High | Outreach infra — evaluate before committing | deferred (reaffirmed 2026-08-06) |
| 11 | <span style="color:green">Calendar, availability & real online booking</span> | 🔥🔥🔥 | High | Booking link (#9), smart pickers, reminders | **SHIPPED** — `feat/calendar-availability`, all 4 phases (2026-08-07) |
| 12 | <span style="color:green">Customer portal completion</span> | 🔥🔥 | Med–High | Held portal branch, approval/change-order endpoints | **SHIPPED** — owner smoke PASSED, feature closed (2026-08-07) |
| 13 | <span style="color:green">Estimated-vs-actual job profitability</span> | 🔥🔥🔥 (differentiator) | Med | timeSessions, payments ledger, change orders | **SHIPPED** — merged `683ec15` 2026-08-07 |
| 14 | <span style="color:green">Accountant package / bookkeeping handoff</span> | 🔥 | Med | csvExport.ts, ExportDataScreen, payment ledger | **SHIPPED** — merged `d89a968` 2026-08-07 |
| 15 | <span style="color:green">Contextual AI & proactive operations</span> | 🔥🔥 | Med–High | todayInsights, follow-ups, dunning, AI layer | **SHIPPED** — merged `60da60b` 2026-08-07 |
| 16 | Missed-call text-back | 🔥🔥🔥 | Med (evaluate-first) | Outreach/notification infra, Phase 10 provider decision | staged 2026-08-09 — prompt ready |
| 17 | Live QuickBooks Online / Xero sync | 🔥🔥 | High (partner API) | csvExport.ts / Phase 14 mappings, backend AI-proxy pattern | staged 2026-08-09 — prompt ready |
| 18 | In-person card payment (Tap to Pay) | 🔥🔥 | High (native + Apple entitlement) | Stripe Connect, payment ledger (Phase 3) | staged 2026-08-09 — prompt ready |
| 19 | Legally-binding e-signature (upgrade) | 🔥 | Low–Med | Phase 1 consent snapshot + estimate-approval flow | staged 2026-08-09 — prompt ready |
| 20 | Custom job/inspection forms & checklists | 🔥🔥 | Med–High | Photo pipeline, Job model, sync | staged 2026-08-09 — prompt ready |
| 21 | Multi-property / equipment history | 🔥 | Med | Customer model, JobDetailScreen | staged 2026-08-09 — prompt ready |
| 22 | Customer financing at checkout | 🔥 | High (lender partnership) | Invoice/estimate send flow | staged 2026-08-09 — prompt ready (business decision, not just eng) |
| 23 | Read-only open API for other services | 🔥 | Med | Workers backend, owner-scoped RLS, portal-token pattern | staged 2026-08-12 — prompt ready |

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

## Phase 11 — Calendar, availability & real online booking

> **STATUS (2026-08-07): ALL FOUR PHASES BUILT** on `feat/calendar-availability`
> per the owner-approved design
> (`docs/superpowers/specs/2026-08-07-calendar-availability-booking-design.md`,
> D1–D8 approved). Phase A calendar + Schedule settings, Phase B availability
> engine + Workers twin + parity suite, Phase C slots/reserve endpoints +
> `booking_reservations` migration (APPLIED) + book.html slot picker
> (**LIVE** — Worker deployed, page pushed, real slots verified 187-slot
> response), Phase D manage/respond endpoints + booking.html + history union
> + Today booking rows (built; Worker redeploy + legal-repo push + owner
> smoke pending at time of writing). Feature flag:
> `Settings.schedule.bookableSlotsEnabled` (owner-enabled 2026-08-07).

> **Added 2026-08-06** (Codex-audit adoption; deepens next-queue item 4 and
> extends shipped Phase 9). Context verified: the booking link (`cec034f`)
> already provides the request model, hosted page, and conversion flow;
> overlap detection and smart schedule pickers shipped and are Phase A's
> foundation; `RouteScreen` is a Maps deep-link stub, not route optimization
> (architecture contract) — the prompt's exclusion stands. Slot math
> (Phase B) is FA-039 territory: local-frame dates, explicit TZ/DST tests.

**Kickoff prompt (owner-curated, 2026-08-06):**

```text
Work in C:\dev\tradeready\tradeready.

Deepen TradeReady scheduling from dated jobs and preferred-time requests into a solo-operator calendar and real bookable availability.

Read:
- Job scheduling fields in types/models.ts
- TodayScreen.tsx
- JobsScreen.tsx
- AddJobScreen.tsx
- RouteScreen.tsx
- date/time helpers
- appointment reminder code
- booking request model, backend, hosted page, conversion flow and tests
- deep-link handling and notification routing

Build in phases:

Phase A — owner calendar:
- Day and week views
- Unscheduled approved-work queue
- Overlap/conflict warnings
- Working hours
- Appointment duration
- Travel/buffer time
- Fast reschedule
- Preserve Today as the daily action surface

Phase B — availability engine:
- Calculate candidate slots deterministically from working hours, existing jobs, buffers and blackout periods
- Handle timezone and daylight-saving changes explicitly
- Do not infer travel time unless real data exists
- Unit-test all slot calculations independently of UI

Phase C — public booking:
- Allow the customer to choose only valid offered slots
- Make final reservation server-authoritative and atomic
- Prevent two customers from taking the same slot
- Support request-only services that still need owner approval
- Notify the owner and customer with accurate status wording

Phase D — customer changes:
- Confirm appointment
- Add to calendar
- Request reschedule or cancellation
- Record an auditable status history
- Never let a public token expose other customers or private job notes

Do not begin with Google Calendar APIs or route optimization. First establish TradeReady's internal schedule and conflict model. Treat external calendar sync as a later opt-in phase.

Produce the domain model, concurrency design, timezone rules, UI flow, API/RLS plan, migration compatibility and phased test plan. Stop before schema or backend changes.

After approval, ship behind a feature flag until migration, backend, hosted page and device smoke tests are complete. Run TypeScript, all tests and lint at every phase.
```

## Phase 12 — Customer portal completion

> **STATUS (2026-08-07): SHIPPED — owner smoke PASSED, feature CLOSED.**
> All five phases merged + CI green (design spec
> `docs/superpowers/specs/2026-08-07-portal-completion-design.md`, D1–D7
> approved): A read additions (appointments + manage links, change orders,
> amountPaid, portal-ics), B customer-visible photos (JobPhoto.customerVisible
> + HMAC signed URLs, secret set), C portal-request write path
> (`portal_change_requested` status, portal_access_log cap — migration
> applied), D server-owned `portal_tokens` (instant revoke/rotate, migration
> applied, Worker deployed), E portal.html rebuild (LIVE + E2E-verified) +
> docs sweep + smoke (`docs/superpowers/plans/2026-08-07-portal-completion-smoke.md`,
> PASSED 2026-08-07). Remaining: client pieces ride the next OTA (standing
> owner call). The precondition note below is a dated record — both
> preconditions cleared before kickoff.

> **Added 2026-08-06.** PRECONDITIONS: the built, review-approved portal
> branch `feat/customer-portal` (`4339848`) is still UNMERGED — merging it is
> an owner decision that comes before this phase; capability 6 (customer-
> visible photos/documents) depends on the job-photos R2 plan, itself blocked
> on Cloudflare-migration Phase 6. ⚠️ The portal's pay-link amount gate is
> load-bearing — preserve it.

**Kickoff prompt (owner-curated, 2026-08-06):**

```text
Work in C:\dev\tradeready\tradeready.

Expand the existing customer portal into a focused self-service journey without building a full messaging platform.

Read:
- Customer.portal model and token flow
- CustomerDetailScreen.tsx
- backend portal-view/store handlers
- portal.html in the legal-site repository if available
- estimate approval and change-order endpoints
- payment-link and partial-payment behavior
- appointment and booking models
- job-photo storage design if already implemented

Add capabilities in this order:
1. Upcoming appointment details
2. Add-to-calendar action
3. Estimate status and approval
4. Change-order viewing and approval
5. Invoice total, paid-to-date, balance and payment action
6. Selected customer-visible documents/photos
7. Request follow-up work
8. Request reschedule or cancellation

Security and privacy:
- Move portal capability tokens into a server-owned table if not already completed.
- Tokens must be high entropy, rotatable, revocable and tenant-scoped.
- Public responses must be explicit allowlists, not sanitized copies of full records.
- Never expose internal notes, costs, margins, AI discussions, local paths or unrelated customers.
- Customer-visible photos require explicit per-photo visibility.
- Use short-lived signed URLs for private photos and documents.
- Do not persist signed URLs in database records.
- Add rate limiting and security logging without logging raw portal tokens.
- Archive behavior and portal revocation must be deliberate and documented.

First produce a current-versus-proposed response schema, threat model, authorization design, customer flow and deployment plan. Stop for approval.

After approval, implement read-only additions before new write paths. Each public write must be idempotent, server-timestamped and protected against stale device overwrite. Verify backend, hosted portal and real-device flows before updating marketing claims.
```

## Phase 13 — Estimated-versus-actual job profitability

> **STATUS (2026-08-07): MERGED to master** (no-ff `683ec15`, pushed; CI
> Verify gate green) per the owner-approved design
> (`docs/superpowers/specs/2026-08-07-job-profitability-design.md`, D1–D6):
> 13B pure calculation layer + `Expense.jobId` / `Settings.laborCostRate`
> (`66eb773`), 13C Job Detail estimate-vs-actual card + expense-to-job linking
> + completion review (`3143d22`), 13D Money aggregate card + pricing
> reality-check warnings + owner labor-cost-rate setting (`86a97fd`), 13E docs
> sweep (README + ARCHITECTURE + this block, no code) (`22e1fe7`). Owner
> decisions honored: D1 `Expense.jobId` yes / retro-link deferred, D2
> `laborCostRate` yes, D3 refunds out of scope v1, D4 processing fees unknown
> v1 (never invented), D5 per-job-type aggregation deferred, D6
> compute-with-warnings (unknown ≠ zero). Gate re-verified green on the merged
> tree before push: tsc 0, 2,731 tests / 199 suites, lint 0. **Remaining:**
> owner device smoke, then the client card/UI reaches users on the next OTA
> (standing owner call — not yet OTA'd). Merge unblocks Phase 15's job-cost
> insight conditions ("actual cost above estimate" beyond labor hours), and
> Phase 14's accountant package may want a `jobId` column on `expenses.csv`
> (design §7, not done).

> **Added 2026-08-06** (deepens next-queue item 5; the Today Insights
> labor-overrun rule is the first step). Inventory note, verified 2026-08-06:
> `Expense` (types/models.ts:412) has NO `jobId` today — "actual job-linked
> material expense" requires a new additive-optional field (persisted-shape
> change → owner approval at that phase). `Job.timeSessions`, the invoice
> `payments` ledger, and change-order math all exist.

**Kickoff prompt (owner-curated, 2026-08-06):**

```text
Work in C:\dev\tradeready\tradeready.

Build trustworthy job profitability that compares the original estimate with actual labor, materials, expenses, change orders, invoicing and cash collection.

Read:
- types/models.ts
- utils/pricingEngine.ts
- time-tracking implementation
- expense model and jobId linkage
- pricebook/material models
- change-order math
- invoice payment ledger
- Money analytics
- businessSnapshot and AI context generation
- existing financial test fixtures

Define these figures separately:
- estimated revenue
- approved change-order revenue
- final billable amount
- invoiced amount
- cash collected
- estimated labor hours
- actual tracked labor hours
- billable labor rate
- optional owner labor-cost rate
- estimated material cost
- actual job-linked material expense
- other direct job expenses
- payment-processing fees when known
- estimated gross profit
- actual gross profit
- outstanding receivable

Accounting constraints:
- Do not treat invoiced revenue as cash collected.
- Do not invent processing fees, costs, dates or payment methods.
- Unknown legacy values must remain unknown and carry a warning.
- Keep labor billing rate separate from labor cost.
- Avoid double-counting materials that appear both on an estimate and in expenses.
- Change orders affect contracted revenue only when approved.
- Voided payments must remain in history but not collected totals.
- Overpayments and refunds must be represented explicitly.

UX:
- Estimate versus actual comparison on Job Detail
- Variance explanations
- "What changed?" drill-down
- Completion-time review
- Aggregate profitability by job type
- Contextual warning when future pricing is below observed cost or target margin

First inventory which inputs already exist and which require backward-compatible optional fields. Produce formula definitions, worked examples, migration requirements and test vectors. Stop for approval.

After approval, implement the pure calculation layer and exhaustive tests before adding UI or AI. AI may explain deterministic results but must never calculate or silently rewrite financial records.
```

## Phase 14 — Accountant package & bookkeeping handoff

> **STATUS (2026-08-07): MERGED to master** (no-ff `d89a968`) per the
> owner-approved design
> (`docs/superpowers/specs/2026-08-07-accountant-package-design.md`), built
> subagent-driven (10 tasks, each implement+review+gate) with a clean
> whole-branch final review (Ready-to-merge) plus a polish commit
> (`e021009`) and a stored-ZIP round-trip test (`171aa43`):
> `utils/zipStore.ts` (zero-dependency stored/uncompressed ZIP writer —
> crc32/utf8/base64/buildZip), `utils/accountingPackage.ts` (per-file
> builders for invoices.csv, invoice-line-items.csv, active-payments.csv,
> payment-activity.csv, expenses.csv with a Job column, mileage.csv,
> customers.csv, category-mapping.csv, export-warnings.csv, summary.json,
> README.txt, plus the `buildAccountingPackage` assembler), the `shareZip`
> delivery tail added to `utils/csvExport.ts`, and the "Accountant package
> (.zip)" action on `ExportDataScreen` — 11 files bundled into
> `TradeReady-Accounting_<start>_<end>.zip`. Owner decisions honored:
> receipt attachments explicitly deferred (device-local, PII-heavy);
> `vehicles.csv` omitted (no vehicle identity in the models); refund columns
> omitted (no refund concept — voids only); nothing invented. Output is
> deterministic for identical data + range (zeroed zip timestamps, fixed
> entry order, stable row ordering, no wall-clock in any payload) and adds
> zero new dependencies. Gate green on the merged tree: tsc 0, 2,775 tests /
> 206 suites, lint 0. **Remaining:** owner device smoke, then the
> `ExportDataScreen` UI change reaches users on the next OTA (standing owner
> call — not yet OTA'd).

> **Added 2026-08-06** (deepens next-queue item 7; its low-urgency ranking
> stands). All referenced files verified present 2026-08-06
> (`utils/csvExport.ts`, `screens/ExportDataScreen.tsx`,
> `__tests__/csvExport.test.ts`, the 2026-07-31 export spec). No vehicle
> identity exists in the models today — vehicles.csv stays conditional as
> written.

**Kickoff prompt (owner-curated, 2026-08-06):**

```text
Work in C:\dev\tradeready\tradeready.

Deepen the current individual CSV exports into an accountant-ready package while preserving all existing exports.

Read:
- utils/csvExport.ts
- screens/ExportDataScreen.tsx
- __tests__/csvExport.test.ts
- invoice payment-ledger utilities
- expense, mileage, customer, settings and invoice models
- docs/superpowers/specs/2026-07-31-csv-export-design.md
- current receipt-photo/cloud-storage implementation
- docs/release-checklist.md

The package should be named:
TradeReady-Accounting-<start>-<end>.zip

Include, as supported by real data:
- invoices.csv
- invoice-line-items.csv
- active-payments.csv
- payment-activity.csv including void/refund history
- expenses.csv
- mileage.csv
- vehicles.csv if vehicle identity is implemented
- customers.csv
- category-mapping.csv
- export-warnings.csv
- summary.csv or summary.json
- README.txt
- receipt attachments when available and explicitly selected

Rules:
- Maintain payment-level cash-basis income.
- Preserve partial payments and their actual dates.
- Exclude voided payments from active cash totals while retaining activity history.
- Never infer missing issue dates, vendors, payment accounts, taxes, fees, vehicle details or legacy receipt identity.
- Use blank/unknown values and explicit warnings.
- Keep import-oriented CSVs free of totals rows.
- Put control totals, monthly summaries and coverage metrics in separate control files.
- Make output deterministic for identical data and settings.
- Use RFC-4180 escaping, CRLF, UTF-8 BOM and stable ordering.
- Exclude API keys, tokens, local paths and other secrets.
- Warn when receipts are unavailable locally or in cloud storage.
- Avoid claiming direct QuickBooks compatibility until an actual import profile is tested.

Before implementation, compare every proposed column to the current data models and label it:
A. available now
B. derivable without guessing
C. requires a new optional field
D. unavailable for legacy records

Produce the final schemas, control equations, warning taxonomy, ZIP strategy, memory/battery safeguards and ten-phase implementation plan. Stop for approval.

After approval, implement pure export builders first, then controls, packaging, UI and documentation. Test financial equivalence, escaping, deterministic output, missing fields, receipt failures, large exports, secret exclusion, legacy records and sync retention. Finish with TypeScript, all Jest tests and lint.
```

## Phase 15 — Contextual AI & proactive operations

> **STATUS (2026-08-08): v1 BUILT** on `feat/contextual-ai-insights` per the
> owner-approved design
> (`docs/superpowers/specs/2026-08-07-contextual-ai-design.md`, D1–D8):
> Phase A insight identity + dismiss/snooze store + "why" reasons + analytics
> (`ffcd328`), Phase B low_margin_estimate (`c91a624`), Phase C
> maintenance_due + customer deep link (`7f9eab9`); docs sweep in Phase E.
> The owner-optional expense_anomaly rule (Phase D) was not built. Built
> ahead of Phase 13 by owner call — the job-cost conditions ("actual cost
> above estimate" beyond labor hours) remain BLOCKED on Phase 13's data
> layer, as ranked in the design. The kickoff's evaluation step (compare
> contextual entry points against the AI tab via the new `ai_chat_sent`
> source/provider props) starts once the OTA ships and data accrues. Gate
> green at every phase (2,680 tests / 196 suites after C).

> **Added 2026-08-06.** Sequenced AFTER Phase 13 — several listed conditions
> need profitability figures. Builds on shipped deterministic surfaces
> (`utils/todayInsights.ts` + `components/InsightsCard.tsx` 5-rule card,
> estimate follow-ups, overdue dunning) — inventory these first; several
> prompt conditions are already live rules, so extend rather than duplicate.
> Load `tradeready-ai-layer` before touching model ids or prompts (mandatory
> verification rule).

**Kickoff prompt (owner-curated, 2026-08-06):**

```text
Work in C:\dev\tradeready\tradeready.

Turn TradeReady's AI from a destination tab into a contextual action layer while keeping deterministic business rules authoritative.

Read:
- ChatScreen.tsx
- utils/aiService.ts
- utils/businessSnapshot.ts
- utils/todayInsights.ts
- components/InsightsCard.tsx
- pricing calculator and pricebook AI
- estimate follow-ups
- invoice outreach
- job profitability once implemented
- AI usage caps, analytics and backend guards

Design contextual assistance for:
- estimates below target margin
- actual job cost above estimate
- approved jobs that still need dates
- schedule gaps that can fit unscheduled work
- estimates awaiting customer action
- overdue invoice follow-up
- repeat customers due for maintenance
- customers eligible for a review request
- unusual expense or cash-flow changes

Rules:
- Deterministic code identifies the condition and computes every number.
- AI may explain, summarize or draft language.
- AI must not invent business facts.
- No autonomous price changes, customer messages, invoices, schedule changes or financial writes.
- Every mutation requires an explicit user confirmation.
- Avoid sending more customer or financial data to AI providers than the task requires.
- Respect usage caps and degrade to deterministic copy when AI is unavailable.
- Each insight must have a useful action, dismiss/snooze behavior, stable deduplication and an explanation of why it appeared.
- Do not remove the AI tab until analytics demonstrate that contextual entry points replace it.

First create an insight inventory ranked by expected revenue/time impact, define deterministic eligibility rules and show the exact data sent to AI for each. Include privacy, cost, fallback, analytics and evaluation plans. Stop for approval.

After approval, implement two or three highest-value insights first and compare engagement against the standalone AI tab before expanding.
```

---

## Phase 16 — Missed-call text-back

> **Added 2026-08-09** — competitive-gap review against Jobber/Housecall Pro/
> QuickBooks Self-Employed, scoped to solo-operator value (no team/dispatch
> items). Not yet built.

**Why:** The single most solo-relevant feature on this list — a customer calls while you're on a ladder with your hands full, you can't pick up, and the call just... ends. Housecall Pro's version auto-texts the caller with a "sorry I missed you, here's my booking link" message. Directly recovers jobs that would otherwise go to whoever answers first. Shares its phone-number-provisioning question with the deferred Phase 10 (two-way SMS) — evaluate together, since standing up SMS infrastructure for one and not the other is wasted spend either way.

**Kickoff prompt:**
> Load `superpowers:brainstorming` and `tradeready-architecture-contract`. Revisit Phase 10's two-way-SMS evaluation alongside this: I want missed calls to a tradesperson's business line to trigger an automatic text back (e.g. "Sorry I missed you — here's my booking link: ...") reusing the booking link from Phase 9/11. This requires either a provisioned business phone number (Twilio-style, ongoing per-message cost) or a carrier/CallKit-level integration — investigate what's actually feasible from an Expo/React Native app on iOS, since apps cannot generally intercept a missed call on someone else's cell number without call-forwarding setup. Give me an honest feasibility and cost memo first — this may be a no-go as a native app feature and more of a "forward your business number to Google Voice" setup guide instead. Only if there's a real in-app path, produce a phase-gated plan. Stop for go-ahead either way.

## Phase 17 — Live QuickBooks Online / Xero sync

> **Added 2026-08-09** — competitive-gap review, not yet built.

**Why:** The Accountant Package (Phase 14) hands an accountant a ZIP of CSVs once a year — useful, but competitors post transactions directly into the customer's own QuickBooks Online or Xero ledger, which is what most solo owners' accountants actually expect and ask for. This is a bigger lift than it looks: it means registering as a developer with Intuit/Xero, building OAuth token storage + refresh, and mapping Job/Invoice/Expense onto their APIs — not just formatting a file.

**Kickoff prompt:**
> Load `superpowers:brainstorming`, `tradeready-architecture-contract`, and re-read the Phase 14 accountant-package spec (`docs/superpowers/specs/2026-08-07-accountant-package-design.md`) for the existing export mappings — reuse those field mappings rather than re-deriving them. I want to evaluate live QuickBooks Online and/or Xero sync (push invoices/expenses/customers, not just export a file). This needs OAuth app registration with Intuit and/or Xero (their developer approval process, sandbox testing, ongoing token refresh, and their own rate limits) — this is a new external dependency and partner relationship, not just code, so it needs explicit owner approval before any registration happens. Give me a go/no-go memo covering registration lead time, ongoing maintenance burden (their APIs change), and whether one-way push (safer) or two-way sync (riskier, conflict-prone) is the right scope. Only if it's a go, produce a phase-gated plan. Stop for go-ahead either way.

## Phase 18 — In-person card payment (Tap to Pay)

> **Added 2026-08-09** — competitive-gap review, not yet built.

**Why:** Right now the only collection path is a Stripe payment link sent to the customer — there's no way to tap/swipe a card standing at the job site and get paid on the spot, which is a real friction point ("I'll mail you a check"). Apple's Tap to Pay on iPhone (contactless only, no extra hardware, works with the existing Stripe Connect integration via Stripe Terminal SDK) is the natural fit for a solo trade — no card reader to carry or lose. Requires a native module and a special Apple entitlement application, so this needs explicit dependency approval and has real lead time before any code lands.

**Kickoff prompt:**
> Load `superpowers:brainstorming`, `tradeready-payments-and-billing`, and `tradeready-architecture-contract`. I want to evaluate in-person card payment collection at the job site, reusing the existing Stripe Connect accounts — most likely via Stripe Terminal SDK's Tap to Pay on iPhone (contactless, no extra hardware). This requires a new native dependency and an Apple entitlement application (lead time, may be rejected) — flag this clearly as a dependency + app.json change requiring my approval before any registration or install. Cover how a collected in-person payment reconciles with the existing invoice/payment-ledger model (Phase 3) so it doesn't fork from the Stripe-link path. Give me a go/no-go recommendation with the entitlement lead time called out, then a phase-gated plan. Stop for go-ahead.

## Phase 19 — Legally-binding e-signature (upgrade)

> **Added 2026-08-09** — competitive-gap review, not yet built. **Note the
> overlap with Phase 1:** the shipped estimate-approval loop already captures
> a typed-name consent with an immutable snapshot, which is legally valid
> consent under the U.S. ESIGN Act for most contractor-estimate purposes.
> This phase is a genuine upgrade (drawn signature, applicable to any
> document — estimates, contracts, change orders) but may not be worth the
> build cost if typed-name consent already covers the real risk. Evaluate
> before committing, don't assume it's needed.

**Why:** Jobber/Housecall Pro let a customer draw a signature (finger/stylus) on any document, not just tap Approve. For most solo trades this is more about the *feel* of professionalism/being taken seriously on a big-ticket job (kitchen remodel, roof) than a legal necessity — the existing typed-name consent already covers the ESIGN Act bar.

**Kickoff prompt:**
> Load `superpowers:brainstorming` and re-read Phase 1's shipped consent-capture design (typed-name + immutable snapshot in the estimate-approval flow). Before building anything, give me an honest assessment: does a drawn signature meaningfully add legal or trust value over the typed-name consent already shipped, for a solo trade's estimates/contracts? If it's a go, I want it reusable across estimates, change orders (Phase — change-orders feature), and any future contract documents, using a lightweight canvas-based signature capture with no new native dependency if at all possible. Phase-gated plan, stop for go-ahead.

## Phase 20 — Custom job/inspection forms & checklists

> **Added 2026-08-09** — competitive-gap review, not yet built.

**Why:** Jobber has a form builder — safety checklists, inspection reports, pre/post-job walkthroughs, each attachable to a job with photos and free text. TradeReady has no equivalent; today a solo tradesperson doing this kind of documentation is stuck with paper or a generic notes app. This is a genuine differentiator opportunity for licensed trades (HVAC/electrical/plumbing) that need documented inspections, and it reuses the existing photo pipeline and Job model.

**Kickoff prompt:**
> Load `superpowers:brainstorming`, `tradeready-architecture-contract`, and `tradeready-storage-and-sync`. I want custom job/inspection forms: the tradesperson defines a reusable checklist template (text items, pass/fail, photo-required fields), attaches an instance of it to a job, fills it in on-device (including photos, reusing the existing photo pipeline), and it becomes part of the job's record — exportable/shareable like an estimate PDF. Design the template data model carefully (this is new schema — flag any migration) and how templates sync/scope per-user. Start with a small built-in template library rather than a full drag-and-drop builder. Phase-gated plan, stop for go-ahead.

## Phase 21 — Multi-property / equipment history

> **Added 2026-08-09** — competitive-gap review, not yet built.

**Why:** TradeReady's Customer model is flat — one address, no history of what equipment is installed where. Jobber's "Properties" concept lets one client have multiple service addresses, and tracks equipment (make/model/serial/install date/warranty) at each one, so a returning HVAC or appliance tech immediately sees what they're walking into. Useful for repeat/maintenance-plan customers (Phase 6) especially.

**Kickoff prompt:**
> Load `superpowers:brainstorming`, `tradeready-architecture-contract`, and `tradeready-storage-and-sync`. I want to extend the Customer model to support multiple service properties per customer, and optionally track equipment (type, make/model, serial number, install date, warranty expiration) per property, surfaced on CustomerDetailScreen and JobDetailScreen. This touches core data shapes — design the migration path carefully (existing customers have exactly one implicit property today) and confirm this doesn't break the getOrCreateCustomer/identity contract. Phase-gated plan, stop for go-ahead.

## Phase 22 — Customer financing at checkout

> **Added 2026-08-09** — competitive-gap review, not yet built. **This is
> primarily a business decision, not an engineering one** — it requires
> partnering with a lender (Wisetack-style point-of-sale financing), which
> means an application/approval process and a revenue-share or fee
> arrangement before any code is worth writing.

**Why:** Housecall Pro and Jobber both offer "let your customer pay over time" financing at invoice/estimate time, which helps close bigger jobs (a $8k roof repair becomes "$180/month"). Lowest priority on this list for a true solo shop — it's real leverage on higher-ticket trades (roofing, HVAC replacement) and much less relevant to a handyman/small-repair business.

**Kickoff prompt:**
> Before any design work: I want a business memo, not a build — is customer financing worth pursuing given TradeReady's current user base and job-size profile? Cover what a Wisetack-style integration actually requires (lender partnership/application, KYC, revenue share, and where financing would surface in the estimate/invoice send flow). Only proceed to `superpowers:brainstorming` and a phase-gated plan if the answer is yes and I've picked a partner.

## Phase 23 — Read-only open API for other services

> **Added 2026-08-12** — owner-initiated. Not yet built. **Distinct from
> Phase 17** (live QuickBooks/Xero *push*): this is a *pull* surface — a
> generic, authenticated, read-only HTTP API any external service (Zapier, a
> customer's own tooling, an accountant's software) can call to read that
> owner's TradeReady data. Phase 17 pushes into one named partner; this lets
> arbitrary consumers read. They can share an underlying field-mapping /
> allowlist layer.

**Why:** TradeReady's data is already cloud-resident and tenant-isolated
(Supabase Postgres, owner-scoped RLS — see `ARCHITECTURE.md`), and the backend
(`backend-workers/`) already serves authenticated HTTP endpoints. A read-only
open API turns "your data is locked in the app" into "your data is yours to
route anywhere," which is a real retention/trust lever for power users and a
prerequisite for any third-party integration ecosystem. The hard infrastructure
mostly exists: the **customer portal** and **booking link** already prove the
pattern — token-authenticated, tenant-scoped endpoints returning **explicit
allowlisted fields** (never full records), with rotatable/revocable tokens
(`portal_tokens`), rate limiting, and security logging. This phase generalizes
that pattern from "one customer, one job" to "one owner, their whole account,
read-only."

⚠️ **Scope discipline:** read-only only. No write-back in this phase — writes
fight the local-first sync model (the cloud copy lags the device's last sync,
and an external write racing a device push needs the union-merge care the
invoice-payment ledger already uses). Write access, if ever, is a separate
later phase with its own approval.

**Kickoff prompt:**
> Load `superpowers:brainstorming`, `tradeready-architecture-contract`, and `tradeready-storage-and-sync`, and re-read the customer-portal token/allowlist design (`docs/superpowers/specs/2026-08-07-portal-completion-design.md`) and the Phase 14 accountant-package field mappings (`docs/superpowers/specs/2026-08-07-accountant-package-design.md`) — reuse both rather than re-deriving them. I want a **read-only, open, authenticated HTTP API** that lets an external service (Zapier, an accountant's tool, the owner's own scripts) read one owner's TradeReady data — jobs, estimates, invoices, payments, expenses, customers, mileage. This is a *pull* API for arbitrary consumers, distinct from Phase 17's QuickBooks/Xero *push*, though they should share the field-mapping/allowlist layer.
>
> Design, and stop for approval before any code:
> - **Auth:** per-owner API keys (or OAuth) that are high-entropy, rotatable, revocable, and tenant-scoped — mirror the `portal_tokens` server-owned-table pattern; never reuse portal/booking tokens. Cover key issuance/rotation UX in-app.
> - **Response contract:** every endpoint returns an **explicit allowlist**, not a sanitized copy of the full record. Never expose internal notes, costs, margins, labor-cost rate, AI discussions, local file paths, other owners' data, or secrets. Define the exact public schema per resource.
> - **Read-only guarantee:** no write paths in this phase; state that as an invariant, not a convention.
> - **Freshness honesty:** the API reads the Supabase cloud copy, which is only as current as the owning device's last sync — document this and consider surfacing a `lastSyncedAt` so consumers aren't misled.
> - **Operational safety:** rate limiting, per-key usage caps, security logging that never logs raw keys, pagination, and stable/versioned response shapes (`/v1/...`).
> - **Privacy/cost:** send no more than each endpoint needs; no PII beyond what the owner's own account already contains.
>
> Produce the resource list + public schemas, auth/threat model, versioning strategy, rate-limit/abuse design, and a phase-gated plan (read endpoints before key-management UI before docs). Stop for go-ahead.

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
   delta. **Full kickoff prompt: Phase 11.**
5. **Estimated-vs-actual job profitability** — agreed. The Today Insights
   labor-overrun rule is the first step. The genuinely missing insight pieces:
   an **invoice-level payer-behavior hint** and **materials-vs-estimate on job
   completion**. **Full kickoff prompt: Phase 13.**
6. **Activation instrumentation before any paywall change** — pre-paywall sample
   exploration is a legitimate conversion experiment but *not* obviously right:
   the hard-paywall-after-onboarding flow was a deliberate owner decision in the
   2026-08-03 onboarding restructure, and the 2-week trial already provides
   try-before-pay. First add **trial-start** and **activation** ("created a real
   customer and estimate") telemetry events; revisit the flow only with data.
7. **Accountant package** — low urgency: bundle the existing CSV exports with
   control totals. Never infer missing historical fields. **Full kickoff
   prompt: Phase 14.**

Also staged with full kickoff prompts, outside this priority list:
**customer-portal completion (Phase 12)** and the **contextual-AI action
layer (Phase 15)** — the latter sequenced after Phase 13.

### Deferrals reaffirmed

Teams/dispatch, two-way SMS inbox (#10), and a web app stay deferred — the
depth-not-breadth, solo-operator thesis holds.

---

## Notes

- **Phases 16–22 (added 2026-08-09):** a fresh competitive-gap review against
  Jobber/Housecall Pro/QuickBooks Self-Employed, done after Phases 11–15
  shipped. Deliberately scoped post-1.2 — none are prioritized ahead of
  whatever's already in flight. Several carry explicit dependency/partner/
  entitlement approval gates (17, 18, 22) or an evaluate-first framing (16,
  19) rather than a straight build — read each Why block before treating a
  kickoff prompt as a green light.
- **Phases 11–15 (added 2026-08-06):** owner-curated kickoff prompts from the
  Codex-audit adoption — deeper successors to the original ten-item list, not
  part of its 2026-07-17 leverage ranking. Their context blockquotes carry
  repo-verified preconditions (portal branch merge, `Expense.jobId` absence,
  R2-photos dependency) — re-verify at kickoff, the tree will drift.
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
