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
- Calendar icon in the header → `CalendarScreen` (2026-08-07): day + week
  views, out-of-hours/blackout shading, buffer-aware conflict badges,
  "Needs scheduling" queue, tap-to-reschedule sheet
- Booking rows: customer reschedule requests + cancellations needing action
  (`utils/bookingAttention.ts`; rows self-dismiss as resolved)
- Insights card (`utils/todayInsights.ts` + `components/InsightsCard.tsx`,
  2026-08-04; Phase 15 contextual-AI extensions 2026-08-08): seven
  deterministic rules — labor overrun, low-margin estimate, uninvoiced
  complete work, invoices due soon, tomorrow's open slot, unscheduled
  approved jobs, maintenance-due customers — top 3 by fixed priority, each
  with a stable id, a "Why am I seeing this?" explanation (long-press), and
  deep-link actions. Non-self-resolving kinds (low-margin, maintenance-due)
  support dismiss/snooze (`utils/insightMutes.ts`, device-local). "Ask
  coach" rows prefill the AI tab — never auto-sent, numbers computed
  on-device
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
  - Job description and photos (each photo has a customer-visibility eye
    toggle for the portal, 2026-08-07 — absent means hidden, fail closed)
  - Status timeline (Lead → Estimate Sent → Approved → Scheduled → In Progress → Complete → Invoiced → Paid)
  - Time tracking (clock in/out, session history)
  - Estimate-vs-actual profitability card (Phase 13, 2026-08-07): estimated
    vs. actual revenue/labor/materials/profit with variance rows, a
    cash-collected summary, a "What changed?" drill-down, and a completion-time
    review. Unknown figures (untracked hours, unlinked expenses, legacy jobs)
    stay unknown and carry a warning — never shown as $0. Shows once a job is
    in progress or later and has an estimate.
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
- Opt-in second tier (`autoEmailInvoiceOnComplete`, 2026-08-06): the auto-created invoice is emailed to the customer by a 15-minute Workers cron (Resend, `invoices@gettradereadyapp.com`, one-and-done via `auto_invoice_email_log`) — including approved change-order lines and a payment link when one was minted at creation; with no customer email on file the send screen opens as before.

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
- Job profitability card (`components/money/JobProfitabilityCard.tsx`, Phase 13,
  2026-08-07): medians of estimate-vs-actual across completed jobs that have
  tracked data, with an explicit "N of M completed jobs have tracked data"
  coverage line so partial data is never presented as complete. Medians, not
  means; per-job-type grouping deferred (owner decision D5). Hidden until there
  is at least one completed job.
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
  - Customer Portal — create / share / disable / rotate the customer's portal
    link (server-authoritative since 2026-08-07; see Customer Portal below)
- Add / edit customer

### Tab 6 — Chat (AI Coach)
- Chat interface — ask Claude or Groq about running the business
- Quick prompts on the empty state — four buttons, two data-aware (overdue
  count/total, average job value)
- Proactive insights live on the Today tab (see Tab 1), not here; insight
  "Ask coach" actions deep-link into this chat with a prefilled prompt
  (`initialPrompt` param — never auto-sent)

### Settings (opened via the gear icon in Today's header — not a tab)
A hub screen (`SettingsHubScreen`) whose rows each push a focused subpage;
Support and Legal are single-tap actions that live on the hub itself
(2026-08-05 hub/subpages split, replacing a single 1,390-line screen):
- Business profile — name, trade, contact, logo (`SettingsBusinessScreen`)
- Appearance — dark / light mode toggle (`SettingsAppearanceScreen`)
- Pricing defaults — labor rate, material markup, overhead, margin (`SettingsPricingScreen`)
- Invoice numbering (`SettingsInvoiceNumberingScreen`)
- Import data — CSV import of customers, jobs, invoices, expenses from
  Jobber/Housecall Pro/QuickBooks/spreadsheet exports (`SettingsImportScreen`)
- AI Assistant — Groq / Anthropic API keys (`SettingsAIScreen`)
- Review requests (`SettingsReviewsScreen`)
- Notifications — reminder rules, auto-outreach toggle (tap an overdue reminder to open a ready-to-send message), auto-email toggle (backend emails a one-and-done reminder once overdue) (`SettingsNotificationsScreen`)
- Payments — Stripe Connect onboarding and status, PayPal.Me, Venmo (`SettingsPaymentsScreen`)
- Booking link (`SettingsBookingScreen` — incl. the bookable-slots toggle, 2026-08-07)
- Schedule (`SettingsScheduleScreen`, 2026-08-07 — working hours, work days,
  appointment duration, buffer, time off; read everywhere via `resolveSchedule`)
- Subscription management — RevenueCat (`SettingsSubscriptionScreen`)
- Account — sign out, clear sample data, delete account (`SettingsAccountScreen`)

---

## Data Models

> For the exact shapes including optional fields, see `types/models.ts`.

### Customer
- id (`c<timestamp>_<counter>`)
- name, email, phone, address
- notes
- createdAt
- portal (optional — `{token, enabled}`; the per-customer portal link's share
  token, shared from CustomerDetail. Since Phase 12D (2026-08-07) this is a
  DISPLAY COPY only — the auth authority is the server-owned `portal_tokens`
  table (see Customer Portal below). CustomerDetail's create/toggle/rotate
  call the JWT-authed `portal-manage` endpoint first and save the copy only
  after the server confirms; normal sync then publishes it so the URL row and
  share sheet work offline. Public by design — the token travels in the
  shared URL — so not a SecureStore field)
- importBatchId (optional) — FK to the CSV import batch that created this
  record (2026-08 CSV data import, `SettingsImportScreen`). Additive-optional;
  absent on every record from any other path (manual entry, booking
  conversion, sync pull). Stamped only on records a batch created — never on
  merge-matched existing customers — so "Undo import" can delete-by-batch-id
  without touching pre-existing data. Same field on Job/Invoice/Expense below.
  JSON-blob sync, so no backend migration was needed.

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
- changeOrders?: ChangeOrder[] — documented scope changes with per-CO approval
  (server-written `approval` / device-written `manualDecision`); status
  derived, billable total = `estimateTotal` + approved COs
  (`utils/changeOrders.ts`)
- importBatchId (optional) — see Customer above.

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
- importBatchId (optional) — see Customer above. An imported invoice marked
  paid carries `paid`/`paidAt` but **no fabricated `payments` ledger** — it
  rides the same legacy-derivation path as any pre-ledger invoice
  (`utils/invoicePayments.ts`). A "paid" import row with no mappable paid
  date imports as outstanding and is flagged in the import report rather than
  guessed. Imported invoices are excluded from the automatic overdue-payment
  reminder (`selectInvoicesToRemind`, both backend copies, and the client's
  `utils/notifications.ts`) so a switcher's historical receivables never
  auto-email their customers.

### Expense
- id, date, amount
- category: `fuel | materials | tools | insurance | marketing | subcontractor | office | other`
- description, receiptPhoto (device-local path)
- jobId (optional) — set only by the Add Expense job picker (Phase 13,
  2026-08-07); links the expense into that job's actual costs. Absent means
  general business overhead (the pre-Phase-13 meaning) and is never backfilled;
  CSV import and Siri/widget replay never guess it.
- importBatchId (optional) — see Customer above.

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
- id (`bk<epoch-ms>_<6 hex>`, server-minted; portal requests use
  `bkpr_<hash>` — see Customer Portal), status:
  `new | converted | booked | confirmed | reschedule_requested | cancelled | declined | portal_change_requested`
  (the last added by Phase 12C, 2026-08-07 — old clients skip it by the
  explicit-match rule)
- name, phone, email, address, details, preferredTiming
- createdAt (ISO, server clock); convertedJobId / convertedCustomerId (set on conversion)
- Phase 11 additive fields (2026-08-07): `kind` (`request | booked`), `slot`
  (owner-naive date/start/end + IANA timeZone + UTC instants), `manageToken`
  (per-booking capability for the customer manage page — public-by-design,
  like the portal token), `history` (append-only audit trail, SERVER-written;
  unioned on pull by `utils/syncMerge.ts` so a device push racing a server
  append can't drop an entry)
- Phase 12C additive fields (2026-08-07, portal requests): `source:
  "portal"` + `sourceCustomerId` (conversion links the EXISTING customer by
  id instead of name-matching), `jobRef` + `portalKind`
  (`reschedule | cancel`, the appointment change asked for), `handledAt`
  (DEVICE-written when the owner dismisses the request on Today; absent =
  still needs attention)
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
  and flag-free, mirroring `applyEstimateDecisions`. A `kind: "booked"` row
  (slot booking) converts the same way but the lead Job carries the slot's
  schedule fields and the row KEEPS `status: "booked"` (the customer manage
  page reads it; `convertedJobId` is the done-marker).
- **Bookable slots (2026-08-07, behind `Settings.schedule.bookableSlotsEnabled`):**
  `/api/booking/slots` computes open times server-side (the availability
  engine twin, `backend-workers/lib/booking/availability.js`, mirroring
  `utils/availability.ts` — pinned by a parity suite) and
  `/api/booking/reserve` claims a slot ATOMICALLY via the
  `booking_reservations` table's partial unique index
  (`user_id, slot_start_utc WHERE status='booked'` — migration
  `supabase/migrations/20260807_booking_reservations.sql`); a racing customer
  gets 409 slot_taken. Customers self-serve on `booking.html`
  (`/api/booking/manage`: confirm / ICS download / request reschedule /
  cancel — strict state machine, history append); the owner responds from
  Today's booking rows (`/api/booking/respond`: resolve_reschedule /
  decline — both free the reservation). All times are owner-naive strings;
  UTC exists only at the public boundary via the owner's stored IANA zone.

### Settings / Business Profile
- businessName, ownerName, trade
- phone, email, address, logoPhoto
- laborRate, materialMarkup, overhead, margin, minimumJobFee
- laborCostRate (optional — owner labor-COST rate $/hr for job profitability,
  Phase 13; deliberately separate from laborRate, the billing rate, and never
  used in any customer-facing price. Unset excludes owner labor from cost and
  labels profit "before paying yourself"; an explicit 0 is valid and distinct
  from unset. Never defaulted — an invented rate would fabricate profit)
- mileageRate (default 0.70 — $ per business mile, mileage deduction estimate)
- taxIncomeRate (optional — effective income-tax % for the tax set-aside card;
  unset = SE tax only)
- vehicleDeductionMethod (optional — 'mileage' | 'actual'; the IRS either/or
  election for the tax estimate; unset deducts neither)
- bookingLink (optional — `{token, enabled}`; the public booking link's share
  token. Device-written only, from the Settings hub's Booking link subpage
  (`SettingsBookingScreen`); the backend reads it to resolve a public link but
  never writes it. Public by design — the token travels in the shared URL —
  so it is not a SecureStore field)
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
- **Customer portal grew out of this dispatcher (2026-08-05).** `GET
  /api/estimate/portal-view` joined `create-link` / `respond` / `view` in
  `api/estimate/[action].js`'s route list as a read-only, token-gated
  estimates+invoices bundle. That v1 read shape is where the Vercel twin
  remains frozen; the completed Phase 12 portal is Workers-only — see the
  Customer Portal section below.

---

## Customer Portal (Phase 12 — completed 2026-08-07)

The per-customer portal (`portal.html?p=<token>`) grew from the v1
estimates+invoices bundle into a full read surface plus one narrow write
path. Every Phase 12 endpoint lives on the Workers backend only — the Vercel
twin stays frozen at the v1 read shape and gets no mirror of any of this.

**portal-view response (v2).** Assembled key-by-key in
`backend-workers/lib/estimate/portalAssemble.js` — the whitelist is the
security boundary; no field beyond it may cross:
- `appointments[]` — scheduled jobs in a `[today − 1 day, +60 days]` window
  (owner-naive string comparison, never Date-parsed — FA-039); each carries
  `jobRef`, an `icsUrl`, and a `manageUrl` to the booking manage page when
  the job originated from a booking that is still actionable
- `estimates[]` — unchanged v1 shape (approval-carrying jobs linking back to
  the hosted approval page)
- `changeOrders[]` — only link-carrying, non-cancelled change orders,
  linking to `change.html`
- `invoices[]` — v1 shape plus `amountPaid`, the ledger-derived paid-to-date
- `photos[]` — ONLY photos with `JobPhoto.customerVisible === true` AND an
  `uploadedAt` (i.e. mirrored to R2). URLs are HMAC-signed
  (`PORTAL_URL_SIGNING_SECRET`, TTL 900 s) and never persisted; a missing
  secret yields an empty photos section — fail closed. The owner opts each
  photo in via JobDetail's eye toggle; absent means hidden.

**Endpoints (all Workers-only):**
- `GET /api/estimate/portal-ics` — one floating-local-time VEVENT for an
  owner-scheduled job (no timezone conversion: the appointment happens at
  the owner's wall-clock time). Booked slots keep the booking manage page's
  own ICS instead.
- `POST /api/estimate/portal-request` — the portal's one public write.
  `followup` inserts a `bookingRequests` row (`status: "new"`,
  `source: 'portal'` + `sourceCustomerId`) so device conversion links the
  EXISTING customer by id instead of creating a duplicate.
  `reschedule` / `cancel` create rows with the NEW status
  `portal_change_requested`, which old clients skip harmlessly and Today
  surfaces until the owner stamps `handledAt`. Idempotent: `bkpr_` ids
  derive from `sha256(token|requestKey)` and inserts use
  `Prefer: resolution=ignore-duplicates`. A honeypot field drops bots; a
  durable cap of 5 requests/day/token is counted via `portal_access_log`
  and deliberately fails OPEN on log errors.
- `GET /api/photos-public/:photoId` — anonymous HMAC-signed photo read; the
  owner-JWT `/api/photos` route is unchanged and separate.
- `POST /api/estimate/portal-manage` — owner-JWT management: `mint` (409
  `already_exists` while an active token exists — the stale-paint guard),
  `set_enabled`, and `rotate` (revokes ALL of the customer's token rows,
  then mints fresh).

**Server-owned tokens (Phase 12D).** The `portal_tokens` table stores sha256
hashes ONLY — the raw token is returned exactly once, at mint/rotate, and is
never written anywhere server-side. Resolution order
(`backend-workers/lib/estimate/portalTokenStore.js`) is the load-bearing
contract:
1. hash known to the table + active → authenticated;
2. hash known but revoked/disabled → hard-stop 404 — NEVER falls through to
   the blob. This stop is what makes rotate/disable instant and permanent;
3. hash unknown → legacy blob fallback (pre-12D tokens) with a lazy backfill,
   so the next request takes the indexed path and rotation governs that link
   too.
`Customer.portal` on the device is a display copy (see Data Models);
CustomerDetail's controls call `portal-manage` first and save the copy only
after the server confirms.

**Tables (both migrations applied 2026-08-07):**
- `portal_tokens` — `token_hash` PK, `user_id`, `customer_id`, `enabled`,
  one-way `revoked_at`
- `portal_access_log` — security log of `view` / `ics` / `photo` / `request` /
  `denied` events; rows record an 8-character `token_prefix`, never raw tokens

**Accepted residuals (design decisions, not oversights):** an OTA-old
client's stateless mint creates a blob-only token that the fallback honors
and backfills — two live links are possible until the next rotate; the daily
request cap fails open when `portal_access_log` is unreachable (a legitimate
customer is never blocked by a logging outage); in-memory IP rate limits are
per-isolate. User-facing phrasing lives in README's Known limitations.

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
| Proactive insights | ✅ Built (2026-08-04; extended 2026-08-08) | (automatic) | Deterministic Today-card rules surface actionable conditions; AI only drafts via "Ask coach" prefills |
| Receipt scanning | ✅ Built (2026-07-19) | Photographs a receipt | Extracts amount, vendor, category (user Anthropic key or backend Groq vision) |

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
- **PostHog** — 51 business events as of 2026-08-08 (sign_up, job_created, invoice_paid, insight_shown/tapped/dismissed, etc. — grep `track(` in screens/utils/hooks/components for the full set)
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
✅ Job profitability (estimate vs actual per job + trailing completed-job medians + pricing reality-check; 2026-08-07; unknown values stay unknown, never $0)
⚠️ Revenue reports (monthly chart + top customers built; detailed reports not built)

**Phase 4 — Growth**
✅ AI Coach chat
✅ Customer review requests
✅ Recurring jobs
✅ Pricebook with AI-assisted pricing
✅ Dark mode
✅ Proactive insights feed (Today card, 2026-08-04; Phase 15 contextual-AI extensions 2026-08-08)

**Phase 5 — Scale**
✅ Cloud sync (Supabase — local-first)
⬜ Web dashboard
⬜ Team / subcontractor support
✅ Customer self-booking portal (bookable slots on the booking link +
   per-customer portal with appointments, change orders, photos and
   reschedule/cancel requests — both completed 2026-08-07)

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
