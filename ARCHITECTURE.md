# TradeReady — App Architecture

## Vision

A mobile-first business operating system for solo blue collar workers and
small trade businesses (plumbers, electricians, HVAC, landscapers, cleaners,
painters, handymen). Helps them price jobs, schedule work, navigate their day,
collect payments, and grow — without needing a business degree.

---

## Current State (as of v1.0)

Seven tabs are live. Items marked ⚠️ are stubs or partial implementations.

| Tab | What's built |
|---|---|
| **Today** | Jobs scheduled for today (time-sorted), earnings summary, route map launch |
| **Jobs** | Full lifecycle lead → paid; time tracking; materials; job photos; estimate PDF + send |
| **Invoices** | Invoice list, overdue detection, collection messages, Stripe/Square/PayPal payment links |
| **Money** | Income/expense dashboard, monthly bar chart, top-customers card, expense logging |
| **Customers** | Customer list + detail, job history, notes, one-tap call/text/email |
| **Chat (AI Coach)** | Chat interface backed by Claude (Anthropic) or Groq |
| **Settings** | Business profile, AI keys, payment processor |

**Not yet built from the original vision:**
- Route optimization — the Route screen is a deep-link to Apple/Google Maps, not a waypoint optimizer
- Dedicated scheduling/calendar tab
- Receipt photo scanning for expenses (manual entry only)
- GPS auto-tracking of mileage (the mileage log is odometer-based manual entry, not GPS)
- Tax center and quarterly estimates
- Proactive AI insights feed

**AI on the backend:** AI calls are proxied through Vercel serverless functions
using server-side API keys — no user-supplied keys required. Groq powers the
AI Coach chat (`backend/api/ai-chat.js`); Claude powers pricebook suggestions
(`backend/api/pricebook-suggest.js`).

**Sync is live:** Supabase (Postgres + Auth) is the sync backend today, not a future item.
See the "Sync model" section of README.md for how the local-first queue works.

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
  miles × `settings.mileageRate` shown by period). Local-only, not synced —
  see Data Models below.
- Analytics cards: conversion funnel, avg job value, invoice aging, revenue by type,
  seasonal trends, customer mix, expense trends, revenue forecast
- ⚠️ Receipt scanning: not built (manual entry only)
- ⚠️ GPS auto-tracking of mileage: not built (odometer entry only)
- ⚠️ Tax center: not built

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

### Tab 7 — Settings
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

### Expense
- id, date, amount
- category: `fuel | materials | tools | insurance | marketing | subcontractor | office | other`
- description, receiptPhoto (device-local path)
- jobId (optional)

### Trip ⚠️ local-only, not synced
- id, date, odometerStart, odometerEnd, miles (derived: `max(0, end - start)`)
- fromJobId / toJobId (either may be `null` = "Home / Shop"), fromLabel / toLabel (denormalized)
- purpose, createdAt
- Mileage tax deduction log, modeled on `RecurringJob`: stored in AsyncStorage
  (`utils/storage/trips.ts`) and cleared on sign-out, deliberately **not** in
  `COLLECTION_TABLES` (`utils/sync.ts`) — no cloud sync yet. Deliberately
  separate from `Job.travelFeePerMile`/`travelMiles` (the customer-facing
  travel fee on estimates) and the `fuel` expense category — the deduction
  does not auto-post to expenses, to avoid double-counting under IRS rules.
  Deduction total = business miles × `settings.mileageRate` (default 0.70).
  **Future:** add a `trips` Supabase table + RLS + one `COLLECTION_TABLES`
  entry to sync this collection like the others.

### Settings / Business Profile
- businessName, ownerName, trade
- phone, email, address, logoPhoto
- laborRate, materialMarkup, overhead, margin, minimumJobFee
- taxRate
- mileageRate (default 0.70 — $ per business mile, mileage deduction estimate)
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
- **expo-notifications** — payment reminders, appointment alerts
- **expo-mail-composer / expo-sms** — native email/SMS composers
- **expo-document-picker** — import existing customer lists
- **@react-native-community/datetimepicker** — date/time picker (cross-platform)

### Backend (Vercel serverless)
- **Stripe Connect** — Express account onboarding, payment link generation, webhook-driven invoice marking
- AI proxy — Groq chat completions (`ai-chat.js`) + Anthropic pricebook suggestions (`pricebook-suggest.js`)
- RevenueCat subscription webhook (`subscription/webhook.js`)
- Push notification scheduling
- PDF generation for proposals and invoices
- ⚠️ Google Maps Directions API: planned for route optimization; not yet wired up

### Observability
- **PostHog** — 15 business events (sign_up, job_created, invoice_paid, etc.)
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
✅ Mileage tracking (odometer-based log + deduction estimate; ⚠️ GPS auto-tracking not built; local-only, not synced)
⬜ Quarterly tax estimates
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
