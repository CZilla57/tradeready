# TradeReady — App Architecture

## Vision

A mobile-first business operating system for solo blue collar workers and
small trade businesses (plumbers, electricians, HVAC, landscapers, cleaners,
painters, handymen). Helps them price jobs, schedule work, navigate their day,
collect payments, and grow — without needing a business degree.

---

## Current State (as of v1.0)

Six tabs are live. Items marked ⚠️ are stubs or partial implementations.

| Tab | What's built |
|---|---|
| **Today** | Jobs scheduled for today (time-sorted), earnings summary, route map launch, gear icon opens Settings (switching tabs away pops Settings back to TodayHome, so Today always lands on TodayHome) |
| **Jobs** | Full lifecycle lead → paid; time tracking; materials; job photos; estimate PDF + send |
| **Invoices** | Invoice list, overdue detection, collection messages, Stripe/Square/PayPal payment links |
| **Money** | Income/expense dashboard, monthly bar chart, top-customers card, expense logging with receipt scanning (photo → pre-filled form for review) |
| **Customers** | Customer list + detail, job history, notes, one-tap call/text/email |
| **Chat (AI Coach)** | Chat interface backed by Claude (Anthropic) or Groq |

**Settings** (business profile, AI keys, payment processor) moved off the tab
bar 2026-07-31 — it's now reached via the gear icon in Today's header, not a
tab of its own.

**Not yet built from the original vision:**
- Route optimization — the Route screen is a deep-link to Apple/Google Maps, not a waypoint optimizer
- Dedicated scheduling/calendar tab
- GPS auto-tracking of mileage (the mileage log is odometer-based manual entry, not GPS)
- Tax center and quarterly estimates
- Proactive AI insights feed

**AI on the backend:** AI calls are proxied through Vercel serverless functions
using server-side API keys — no user-supplied keys required. Groq powers the
AI Coach chat (`backend/api/ai-chat.js`); Claude powers pricebook suggestions
(`backend/api/pricebook-suggest.js`) and receipt scanning
(`backend/api/receipt-extract.js`, vision).

**Sync is live:** Supabase (Postgres + Auth) is the sync backend today, not a future item.
See the "Sync model" section of README.md for how the local-first queue works —
including the one place sync merges rather than replaces (an invoice's payment
ledger, unioned by payment id).

For the authoritative data shapes, see `types/models.ts`. The Data Models section below
is a simplified overview.

---

## The Five Pillars

1. **Get the job** — Estimates & proposals
2. **Do the job** — Scheduling & route planning
3. **Charge for the job** — Invoicing & payments
4. **Run the business** — Finances, expenses, taxes
5. **Grow the business** — AI coach, insights, reviews

---

## Screen Map

### Tab 1 — Today
The home screen. Shows what matters right now.
- Today's job schedule in time order
- Route map launch (opens Apple/Google Maps — ⚠️ not optimized)
- Quick actions: Start job, Mark complete, Call customer
- Earnings summary for today
- Gear icon in the header → Settings (see below)
- ⚠️ Weather alerts: not built
- ⚠️ Turn-by-turn route optimization: not built

### Tab 2 — Jobs
Full job lifecycle from lead to paid.

**Sub-screens:**
- Job list (filterable: Active, Estimates, Completed)
- Job detail
  - Customer info
  - Job description and photos
  - Status timeline (Lead → Estimate Sent → Approved → Scheduled → In Progress → Complete → Invoiced → Paid)
  - Time tracking (clock in/out, session history)
  - Linked invoice
  - Notes and materials used
- New job / edit job form
- Estimate builder → Pricing Calculator screen
- Proposal PDF preview and send

### Tab 3 — Invoices
- Invoice list with status badges (Paid / Due today / Overdue / Pending)
- Add / edit invoice form
- Collection message generator (email + SMS via Expo Mail Composer / SMS)
- Payment link generation (Stripe, Square, PayPal)

### Tab 4 — Money
Everything financial in one place.

**Sub-screens:**
- Dashboard: outstanding, collected, expenses this month
- Monthly revenue bar chart
- Top customers by revenue
- Receivables summary
- Expense log (add expense with category)
- Mileage deduction card → full trip log → add/edit trip screen (odometer
  start/end, from/to endpoint — a linked job or "Home / Shop"; total business
  miles × `settings.mileageRate` shown by period). Cloud-synced since
  2026-08-03 — see Data Models below.
- Analytics cards: conversion funnel, avg job value, invoice aging, revenue by type,
  seasonal trends, customer mix, expense trends, revenue forecast
- Tax set-aside card (`components/money/TaxSetAsideCard.tsx`): current IRS
  payment-period reserve + YTD + deadline from `utils/taxEstimate.ts` (SE tax +
  user-set effective income-tax rate; ledger-based cash income). Settings live
  in a modal off the card (`taxIncomeRate`, `vehicleDeductionMethod` — standard
  mileage OR actual fuel expenses, never both; unset deducts neither). Estimate
  only, persistent disclaimer; SS wage base is versioned per year (annual
  update: docs/ops-monthly-checklist.md)
- ⚠️ Receipt scanning: not built (manual entry only)
- ⚠️ GPS auto-tracking of mileage: not built (odometer entry only)

### Tab 5 — Customers
- Customer list with search
- Customer detail
  - Contact info
  - Full job and invoice history
  - Total revenue / amount owed
  - Notes
  - One-tap call / text / email
- Add / edit customer

### Tab 6 — Chat (AI Coach)
- Chat interface — ask Claude or Groq about running the business
- ⚠️ Suggested questions / contextual prompts: not built
- ⚠️ Proactive insights feed: not built

### Settings (opened via the gear icon in Today's header — not a tab)
- Business profile (name, trade, contact, logo)
- Appearance (dark / light mode toggle)
- Stripe Connect onboarding and status
- Subscription management (RevenueCat)
- Notification rules (+ auto-outreach toggle: tap an overdue reminder to open a ready-to-send message; + auto-email toggle: backend emails a one-and-done reminder once overdue)
- Labor rate, material markup, overhead, margin defaults

---

## Data Models

> For the exact shapes including optional fields, see `types/models.ts`.

### Customer
- id (`c<timestamp>_<counter>`)
- name, email, phone, address
- notes
- createdAt
- portal (optional — `{token, enabled}`; the per-customer portal link's share
  token, shared from CustomerDetail. Device-written only, same pattern as
  `Settings.bookingLink`: the backend's `portal-view` action resolves it to a
  whitelisted read-only bundle but never writes it. Public by design — the
  token travels in the shared URL — so not a SecureStore field)

### Job
- id, customerId, customerName (denormalized display)
- title, description, jobType
- status: `lead | estimate_sent | approved | scheduled | in_progress | complete | invoiced | paid`
- estimatedHours, laborRate
- materials: `[{ name, quantity, unitCost }]`
- overhead (%), margin (%)
- scheduledDate, scheduledStartTime, scheduledEndTime
- timeSessions: `[{ start, end? }]`
- address, photos, notes
- invoiceId, createdAt

### Invoice
- id, customerId (FK), customer (display name)
- jobId (optional)
- number, amount, due, paid, paidAt
- paymentLinkUrl
- payments (optional): ledger of partial payments — `{id, amount, date, method, note?, stripeSessionId?}`.
  A deposit, progress draws and a final balance are separate entries. `paid` is
  retained and maintained as "balance within half a cent of zero".
  **Absent on invoices created before the ledger existed** — `utils/invoicePayments.ts`
  derives those from `paid`/`amount`/`paidAt`, which is why no migration was needed.
  Payments are voided, never removed: a voided entry stays in the ledger with a
  `voidedAt` date and is skipped by `amountPaid`. Deletion has to be data rather
  than absence, because the sync union cannot distinguish "unknown to me" from
  "deleted by me".
  Recorded through the Record payment sheet (`components/RecordPaymentSheet.tsx`)
  and shown by `components/PaymentHistoryList.tsx`. "Mark paid" records a
  payment for the outstanding balance rather than setting the flag directly.
  Every money surface derives from the ledger: `outstanding` sums `balanceDue`,
  `collected` sums `amountPaid`, and revenue is bucketed by each payment's own
  date (`collectedInRange` / `collectedByPeriod` in `utils/invoicePayments.ts`).
  The one deliberate exception is `utils/invoiceAging.ts`, which sums invoice
  `amount` directly (via `Number(inv.amount) || 0`) to report the face value of
  settled business per customer — that is a different question from "what was
  collected", so it sits outside the ledger contract on purpose rather than by
  oversight.
  The customer-facing PDF (`utils/pdfTemplates.ts`) shows invoice total, paid to
  date and BALANCE DUE when partly paid, plus a payment history — excluding
  voided entries and the synthesized `legacy_<id>` entry, so pre-existing
  invoices render byte-identically.
  Collection surfaces — payment links, outreach messages and the cron reminder
  email — quote `balanceDue`, and name both numbers for a partly-paid invoice
  so the customer sees their deposit credited. `overpaidAmount` surfaces money
  received beyond the invoice total, which `balanceDue` clamps away.
- depositRequest (optional): `{amount, percent?, requestedAt}` — the up-front amount asked for.

### Expense
- id, date, amount
- category: `fuel | materials | tools | insurance | marketing | subcontractor | office | other`
- description, receiptPhoto (device-local path)
- jobId (optional)

### Trip
- id, date, odometerStart, odometerEnd, miles (derived: `max(0, end - start)`)
- fromJobId / toJobId (either may be `null` = "Home / Shop"), fromLabel / toLabel (denormalized)
- purpose, createdAt
- Mileage tax deduction log, modeled on `RecurringJob`: stored in AsyncStorage
  (`utils/storage/trips.ts`) and cloud-synced since 2026-08-03 (`trips` entry
  in `COLLECTION_TABLES`, `utils/sync.ts`; blob-shape table + owner-scoped RLS
  like every other collection). Deliberately separate from
  `Job.travelFeePerMile`/`travelMiles` (the customer-facing travel fee on
  estimates) and the `fuel` expense category — the deduction does not
  auto-post to expenses, to avoid double-counting under IRS rules.
  Deduction total = business miles × `settings.mileageRate` (default 0.70).

### BookingRequest
- id (`bk<epoch-ms>_<6 hex>`, server-minted), status: `new | converted`
- name, phone, email, address, details, preferredTiming
- createdAt (ISO, server clock); convertedJobId / convertedCustomerId (set on conversion)
- A public request-a-quote submission (booking link, 2026-08-04). Rows are
  INSERTED server-side only — the token-gated `/api/booking/submit` endpoint
  writes them with the service role (`backend/lib/booking/store.js`) — and are
  synced like every other collection (`bookingRequests` entry in
  `COLLECTION_TABLES`, `utils/sync.ts`; blob-shape table + owner-scoped RLS,
  migration `supabase/migrations/20260804_booking_requests.sql`). **Device
  converts:** on every sign-in and app foreground, `applyBookingRequests`
  (`utils/storage/bookingConversion.ts`) turns each `status: "new"` row into a
  `Customer` (via the same `upsertCustomerInList` upsert every other
  customer-creation path uses) plus a lead `Job` with a deterministic id
  `jbk_<requestId>`, then flips the row to `status: "converted"` — idempotent
  and flag-free, mirroring `applyEstimateDecisions`.

### Settings / Business Profile
- businessName, ownerName, trade
- phone, email, address, logoPhoto
- laborRate, materialMarkup, overhead, margin, minimumJobFee
- mileageRate (default 0.70 — $ per business mile, mileage deduction estimate)
- taxIncomeRate (optional — effective income-tax % for the tax set-aside card;
  unset = SE tax only)
- vehicleDeductionMethod (optional — 'mileage' | 'actual'; the IRS either/or
  election for the tax estimate; unset deducts neither)
- bookingLink (optional — `{token, enabled}`; the public booking link's share
  token. Device-written only, from the Settings screen; the backend reads it
  to resolve a public link but never writes it. Public by design — the token
  travels in the shared URL — so it is not a SecureStore field)
- pushToken (optional — `{token, platform, updatedAt}`; the device's Expo push
  token, written by `utils/pushToken.ts` only when it changes; read
  server-side to send booking-request push alerts. Not a secret, so not a
  SecureStore field)
- paymentProcessor + providerKey (SecureStore)
- anthropicKey, groqKey (SecureStore)
- notificationRules, autoOutreachEnabled, autoSendEmailEnabled

---

## The Pricing / Estimate Engine

This is the core feature that doesn't exist well anywhere for this market.

**Inputs:**
- Job type
- Estimated hours
- Materials (name, quantity, cost)
- Any special conditions (emergency/after-hours, etc.)

**Calculation** (see `utils/pricingEngine.ts` for implementation):
```
Labor cost     = hours × laborRate
Materials cost = sum(qty × unitCost) × (1 + markupPercent / 100)
Overhead line  = estimateTotal − labor − material
Subtotal       = labor + materials + overhead
Profit margin  = subtotal × marginPercent / 100
Total          = subtotal + profit
```

**AI layer on top:**
User describes the job in plain English → Claude extracts the inputs →
calculator runs → Claude explains the price in plain English and flags
anything that seems off (e.g. "that's below your break-even rate")

**Output:**
- Price range (low/mid/high — not just one number)
- Itemized breakdown
- One-tap "Turn into estimate" → formatted PDF proposal sent via email or SMS

---

## Estimate Approval Loop

Lets a customer approve or decline a sent estimate from a hosted link, and
flows that decision back into the job pipeline — the same "service role
writes the blob, device reconciles on pull" pattern as the Stripe
payment-link/webhook flow (`backend/api/stripe/webhook.js`), applied to a
`Job` instead of an `Invoice`.

- **App side:** `SendEstimateScreen`'s "Send for approval" builds a frozen
  snapshot (`computeEstimateBreakdown` output — labor/materials/overhead/total)
  and calls the JWT-authed `POST /api/estimate/create-link`, which mints a
  token with Node `crypto.randomBytes` and writes `{token, sentAt, snapshot}`
  into the job's blob via the Supabase service role. The app mirrors that
  back into the local job so `JobDetail` reflects it immediately.
- **Customer side:** the link opens `estimate.html` on the GitHub Pages legal
  site. Token-gated `GET /api/estimate/view` and `POST /api/estimate/respond`
  (both service-role, constant-time token compare) return the sanitized
  snapshot and, on Approve/Decline, write the decision.
- **Server writes are additive and confined to `job.approval.*`** — decision,
  a server-stamped `consentAt` (authoritative clock), typed-name signature,
  decline reason, IP, and user-agent. The server never writes `job.status`.
- **Device owns every pipeline transition.** The existing `pullRemote` poll
  (sign-in / app-foreground, no new sync infrastructure) picks up the
  updated blob; `applyEstimateDecisions()` (`utils/storage/estimateApprovals.ts`)
  reconciles it via `applyEstimateDecision()` (`utils/jobStatus.ts`), which
  advances `estimate_sent → approved` or branches to the terminal `declined`
  status — never regressing a job already past `estimate_sent`. Idempotent
  and flag-free: a no-op run performs no write.
- **Conflict model:** inherits the app's last-write-wins envelope as-is (no
  new merge/conflict logic). Because server writes only touch `approval.*`,
  a device that pulls before pushing preserves them; a device that pushes a
  stale blob after the server write can still clobber `approval.*` — the
  same accepted risk as the Stripe invoice-paid case.
- **Customer portal shares this dispatcher (2026-08-05).** `GET
  /api/estimate/portal-view` joins `create-link` / `respond` / `view` in
  `api/estimate/[action].js`'s route list — still one Vercel function (11 of
  12). It is read-only and token-gated: given a customer's `Customer.portal`
  token, it resolves a whitelisted bundle (business name, customer name,
  approval-carrying estimates linking back to this same hosted approval
  page, and invoices with `balanceDue` plus allowlist-filtered
  `paymentLinkUrl`) for the public `portal.html` page. It adds no write path
  of its own — approve/decline still goes through `respond` above, and Pay
  still goes through a payment link minted elsewhere; `portal-view` only
  reads and sanitizes.

---

## Route Planning

**Current implementation:** The Route screen deep-links today's scheduled jobs
to Apple Maps / Google Maps. The user sees their jobs on a map and can tap for
turn-by-turn directions, but there is no server-side waypoint optimization.

**Original vision (not yet built):**
1. Pull all jobs scheduled for a given day
2. Get their addresses + the user's starting location
3. Call Google Maps Directions API with all waypoints
4. Get back optimized order + estimated drive times
5. Show timeline: "Leave home at 7:45am → Job 1 8:00-10:00am → 22 min drive → Job 2 10:22am..."

---

## AI Coach — What Claude Powers

| Feature | Status | What the user does | What Claude does |
|---|---|---|---|
| Job pricing | ✅ Built | Describes a job in plain English | Extracts hours/materials, suggests price, explains reasoning |
| Estimate writing | ✅ Built | Reviews calculated price | Writes professional proposal text |
| Collection messages | ✅ Built | Picks an invoice | Writes email/SMS with payment link |
| Business chat | ✅ Built | Asks anything | Answers based on trade context |
| Difficult customers | ✅ Built | Describes situation | Drafts a professional response |
| Contract review | ⚠️ Not built | Photographs a contract | Flags unusual clauses in plain English |
| Proactive insights | ⚠️ Not built | (automatic) | Analyzes data and surfaces actionable tips |
| Receipt scanning | ⚠️ Not built | Photographs a receipt | Extracts amount, vendor, category |

---

## Tech Stack

### Mobile app
- **Expo 54 / React Native 0.81 / React 19** — framework
- **React Navigation** (bottom tabs + native stacks)
- **AsyncStorage** — local data; app works fully offline
- **Supabase** — Postgres + Auth; background sync layer (local-first, cloud-backed)
- **TypeScript** — fully migrated; all modules are `.ts/.tsx` strict
- **expo-image-picker** — job site and receipt photo capture
- **expo-image-manipulator** — caps the business logo at 512px when it is picked, and again when it is embedded in a PDF
- **expo-notifications** — payment reminders, appointment alerts
- **expo-mail-composer / expo-sms** — native email/SMS composers
- **expo-document-picker** — import existing customer lists
- **@react-native-community/datetimepicker** — date/time picker (cross-platform)

### Backend (Vercel serverless)
- **Stripe Connect** — Express account onboarding, payment link generation, webhook-driven invoice marking
- AI proxy — Groq chat completions (`ai-chat.js`) + Anthropic pricebook suggestions (`pricebook-suggest.js`) + Anthropic vision receipt extraction (`receipt-extract.js`)
- RevenueCat subscription webhook (`subscription/webhook.js`)
- Booking link — public request-a-quote intake, one dispatcher function `api/booking/[action].js` routing `mint` (JWT-authed token mint), `config` (public, token-gated form bootstrap) and `submit` (public, token-gated insert) — the 11th of 12 Vercel Hobby-plan functions
- Push notification scheduling
- PDF generation for proposals and invoices
- ⚠️ Google Maps Directions API: planned for route optimization; not yet wired up

### Observability
- **PostHog** — 33 business events (sign_up, job_created, invoice_paid, etc. — grep `track(` in screens/utils/hooks/components for the full set)
- **Sentry** — error reporting via `reportError()` in all critical catch blocks

### Future (multi-user / scale)
- Web dashboard
- Team / subcontractor accounts

---

## Build Order (Recommended)

Build in this sequence so you always have something shippable:

**Phase 1 — MVP**
✅ Invoice tracking
✅ Collection messages with payment links
✅ Customer history
✅ Basic job tracking (status pipeline)
✅ Pricing calculator
✅ Estimate → PDF

**Phase 2 — Daily operations**
⚠️ Scheduling / calendar tab (jobs have scheduled dates; no calendar view)
✅ Today screen (jobs for today)
⚠️ Route optimization (deep-link only; waypoint optimizer not built)
✅ Job photos

**Phase 3 — Money**
✅ Expense tracking
⬜ Receipt scanning (OCR)
✅ Mileage tracking (odometer-based log + deduction estimate, cloud-synced; ⚠️ GPS auto-tracking not built)
✅ Quarterly tax estimates (set-aside card: SE tax + user rate, IRS payment periods, mileage-vs-fuel election; estimate only, not filing support)
⚠️ Revenue reports (monthly chart + top customers built; detailed reports not built)

**Phase 4 — Growth**
✅ AI Coach chat
✅ Customer review requests
✅ Recurring jobs
✅ Pricebook with AI-assisted pricing
✅ Dark mode
⬜ Proactive insights feed

**Phase 5 — Scale**
✅ Cloud sync (Supabase — local-first)
⬜ Web dashboard
⬜ Team / subcontractor support
⬜ Customer self-booking portal

---

## What Makes This Different from Competitors

| Feature | TradeReady | Jobber | Housecall Pro | QuickBooks |
|---|---|---|---|---|
| Price | $15-20/mo target | $49+/mo | $65+/mo | $30+/mo |
| Designed for beginners | ✅ | ❌ | ❌ | ❌ |
| AI pricing help | ✅ | ❌ | ❌ | ❌ |
| AI business coach | ✅ | ❌ | ❌ | ❌ |
| Route optimization | ⚠️ stub | ✅ | ✅ | ❌ |
| Works offline | ✅ | Partial | Partial | ❌ |
| Setup time | < 5 min | Hours | Hours | Days |

The core differentiation is that this app *teaches* people how to run a
business as they use it, not just tracks data. That's the AI layer.
