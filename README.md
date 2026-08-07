# TradeReady — Expo App

A mobile-first business operating system for solo tradespeople (plumbers, electricians,
HVAC, landscapers, painters, handymen). Manage jobs, quotes, invoices, customers,
expenses, and time-tracking from one app — with an AI layer that helps price work
and draft professional messages.

---

## Step 1 — Install the tools (one time only)

You need two things installed on your computer: Node.js and Expo CLI.

1. Go to https://nodejs.org and download the "LTS" version. Install it like any app.
2. Open Terminal (Mac) or Command Prompt (Windows) and run:
   ```
   npm install -g expo-cli
   ```
3. On your iPhone, download the free **Expo Go** app from the App Store.

---

## Step 2 — Get the app running

1. Copy this entire `tradeready` folder somewhere on your computer (e.g. your Desktop).
2. Open Terminal and navigate to that folder:
   ```
   cd ~/Desktop/tradeready
   ```
3. Install the app's dependencies (takes 1–2 minutes):
   ```
   npm install
   ```
4. Start the app:
   ```
   npx expo start
   ```
5. A QR code will appear in the Terminal. Open the **Expo Go** app on your iPhone
   and scan the QR code. The app will load on your phone in about 30 seconds.

That's it — you're running the app on your real iPhone!

Every time you save a change to a file, the app on your phone refreshes automatically.
This is called "hot reload" and it makes development very fast.

---

## Step 3 — Connect Stripe for payments

Stripe Connect is built in. Users connect their Stripe account from
**Settings → Connect Stripe** — no API keys needed. The backend (a Cloudflare
Worker, source in `backend-workers/src/`) handles account creation, onboarding,
payment link generation, and webhooks.

The backend is deployed at `tradeready-backend.tradeready.workers.dev`
(cut over from Vercel 2026-08-06; the old `backend-tradeready1.vercel.app`
deployment stays dormant as a rollback target until decommission). The app
reads `backendUrl` from `app.json` at runtime:

```json
"extra": {
  "backendUrl": "https://tradeready-backend.tradeready.workers.dev",
  "backendUrlIsPlaceholder": false
}
```

---

## Step 4 — AI setup

AI features (business chat, pricebook suggestions, receipt scanning) are proxied
through the backend Worker using server-side API keys — no user-supplied keys
required.

- **AI Coach chat** — Groq (Llama 3.1) via `backend/api/ai-chat.js`
- **Pricebook AI Assist** — Claude (Anthropic) via `backend/api/pricebook-suggest.js`
- **Receipt scanning** — Claude vision via `backend/api/receipt-extract.js`; attaching
  a receipt photo to an expense pre-fills merchant/amount/date/category for review
  (never auto-saves; extraction failure falls back to plain manual entry)

Required Vercel env vars: `GROQ_API_KEY`, `ANTHROPIC_API_KEY`, `SUPABASE_URL`,
`SUPABASE_ANON_KEY`.

---

## Step 5 — Booking link (optional)

Nothing to set up here — it's built in and ready whenever you want it.

- **Booking link** — Settings → "Booking link" creates a public request-a-quote
  page you can share with customers (create, share, toggle off, or rotate for
  a fresh link, all from Settings). A submission is turned into a customer
  record and a new lead job automatically — no manual entry. You get an email
  alert for every new request; once your device has registered for push
  notifications you'll also get a push alert (this needs a build with the push
  entitlement — it's a silent no-op in Expo Go, so on Expo Go you'll only see
  the email).
- **Bookable time slots** (added 2026-08-07) — flip "Bookable time slots" on
  the same Settings page and your booking link upgrades from a text box to a
  real slot picker: customers choose from your actual open times, computed
  from your working hours (Settings → Schedule), your calendar, and other
  bookings. Two customers can never take the same slot — the second one is
  asked to pick another time. A booked slot lands on your calendar
  automatically, and the customer gets a manage page where they can confirm,
  add the appointment to their phone's calendar, ask to reschedule, or
  cancel. Reschedule requests and cancellations show up as rows on Today.
- **Calendar** (added 2026-08-07) — the calendar icon in Today's header opens
  day and week views of your schedule, with an "Needs scheduling" queue for
  approved jobs that don't have a time yet. Tap any job block to view or
  reschedule it; conflict warnings respect the buffer time you set in
  Settings → Schedule.

---

## Step 6 — Customer portal (optional)

Nothing to set up here — it's built in and ready whenever you want it.

- **Customer portal** — Customers → pick a customer → "Customer Portal" gives
  that customer their own persistent link showing their estimates (approve or
  decline through the same hosted approval page the estimate-send flow
  already uses) and invoices (with paid-to-date shown, and a Pay button when
  a payment link is already cached on the invoice — the portal can't mint new
  ones). Create, share, toggle off, or rotate for a fresh link, all from that
  customer's detail screen. Since 2026-08-07 the link itself is controlled
  server-side, so turning it off or rotating it kills the old link
  immediately — no waiting for a sync.
- **What else the portal shows** (added 2026-08-07) — upcoming appointments
  for the next 60 days, each with an "Add to calendar" download (an
  appointment the customer booked through your booking link keeps its own
  manage-page link); any change orders you sent a sign-off link for; and job
  photos — but only photos you've marked visible with the eye toggle on the
  job's photo strip. Photos are hidden from the portal unless you flip that
  toggle, and shared photo links expire after 15 minutes, so a forwarded
  photo link goes dead quickly.
- **Portal requests** (added 2026-08-07) — the portal has a request box: the
  customer can send you a message or ask to reschedule or cancel an
  appointment. Those requests show up as rows on Today for you to act on —
  the portal never changes your jobs, invoices, or schedule by itself. A
  message from a portal customer is linked to their existing customer record,
  not a duplicate.

---

## Step 7 — Change orders (optional)

Nothing to set up here — it's built in and ready whenever you want it.

- **Change orders** — document a mid-job scope change (title, details, amount;
  negative = descope credit), get the customer's sign-off before the extra
  work starts (e-sign link on change.html, or an on-site "verbal OK" record),
  and the approved amount flows into the job's billable total, invoice line
  items, and PDF automatically. Cancelled/declined change orders stay in the
  history. Change-order decisions arriving via link are picked up on the next
  sync pull (no push notification — same as webhook payments).

---

## Step 8 — CSV data import (optional)

Nothing to set up here — it's built in and ready whenever you want it.

- **Import data** — Settings → "Import data" brings customers, jobs (with
  schedule), invoices (including historical paid invoices), and expenses in
  from a Jobber, Housecall Pro, QuickBooks, or plain spreadsheet CSV export.
  Pick a file → map columns (common header names are recognized
  automatically) → choose a date format → validate → preview → import → a
  report of what imported and what was skipped or flagged, with reasons →
  one-tap undo. A historical invoice marked paid with no mappable paid date
  imports as outstanding and gets flagged rather than guessed. Imported
  invoices are excluded from the automatic overdue-payment reminders so a
  switcher's old receivables don't trigger emails to their customers.

---

## File map — what does what

```
App.tsx                          ← Entry point; sets up tabs and navigation stacks
app.json                         ← Expo config (name, icons, backendUrl, EAS project)
types/
  models.ts                      ← TypeScript types for all data shapes

utils/
  theme.ts                       ← All colors, font sizes, spacing (light + dark mode tokens)
  analytics.ts                   ← PostHog + Sentry wrapper (track, identifyUser, reportError)
  storage/                       ← Local persistence (typed modules, see below)
    index.ts                     ← Barrel: re-exports public API
    keys.ts                      ← AsyncStorage key constants
    defaults.ts                  ← Default/seed values for each collection
    collections.ts               ← Load/save for invoices, jobs, customers, expenses
    settings.ts                  ← Settings (public + SecureStore-backed fields)
    customers.ts                 ← Customer registry (upsert, notes, migration)
    trips.ts                     ← loadTrips/saveTrips — mileage log (synced since 2026-08-03)
    bookingRequests.ts           ← loadBookingRequests/saveBookingRequests — synced request queue
    bookingConversion.ts         ← convertBookingRequests — new requests into Customer + lead Job
    lifecycle.ts                 ← Onboarding, clearSampleData, clearAllUserData
    dailyOps.ts                  ← Today-tab derived reads (today's jobs, overdue, leads)
  format.ts                      ← formatMoney (2 dp, invoices/totals) / formatQuote (estimates)
  pricingEngine.ts               ← Pricing math, estimate breakdown, price ranges
  invoiceHelpers.ts              ← Payment link fetch, AI message text, PDF helpers
  anthropicMessage.ts            ← Shared Anthropic (Claude) API call with error fallback
  messaging.ts                   ← composeEmail / composeSMS (availability guard + Alert)
  dateHelpers.ts                 ← Date/time formatting, week math, greeting
  jobStatus.ts                   ← advanceStatusForSchedule (approved → scheduled logic)
  jobStatusDisplay.ts            ← getJobStatusDisplay — badge labels + colors
  timeTracking.ts                ← computeTimeTracking — clock-in/out session math
  mileageUtils.ts                ← computeTripMiles, mileageSummary — mileage deduction math
  taxEstimate.ts                 ← Tax set-aside math: IRS payment periods, SE tax, reserve estimate
  invoiceStats.ts                ← summarizeInvoices, isOverdue, filterInvoices
  numberInput.ts                 ← parseNumberInput, buildEstimateInput (safe 0-handling)
  customerList.ts                ← buildCustomerList — invoice/record join + rollup
  sync.ts                        ← Supabase sync queue (push/pull, enqueue, trySync)
  supabase.ts                    ← Supabase client (auth + database)
  notifications.ts               ← Push notification scheduling (overdue reminders)
  bookingLink.ts                 ← Booking-link URL builder + mint-endpoint client
  portalLink.ts                  ← Customer-portal URL builder + portal-manage client (server-owned mint/enable/rotate)
  pushToken.ts                   ← Expo push-token registration into the settings blob
  scheduleConfig.ts              ← resolveSchedule — Settings.schedule defaults + sanitizing
  calendar.ts                    ← Calendar day/week block layout + unscheduled queue
  availability.ts                ← Bookable-slot engine (open slots from hours/jobs/buffers)
  bookingAttention.ts            ← Today rows for customer reschedule/cancel actions
  bookingRespond.ts              ← Owner respond client (resolve reschedule / decline)
  pdfTemplates.ts                ← HTML templates for invoice and estimate PDFs (XSS-safe)
  pdfExport.ts                   ← PDF rendering and share sheet
  photoStorage.ts                ← Device photo management + logo downscale for PDFs
  aiService.ts                   ← Groq AI integration (backend-proxied via Vercel)
  pricebookAI.ts                 ← Pricebook AI Assist (backend-proxied via Vercel)
  receiptOCR.ts                  ← Receipt scan: parse/clamp + routing (user key / backend)
  subscription.ts                ← RevenueCat subscription helpers
  paywallCopy.ts                 ← Trial wording derived from the store's real intro offer
  recurringJobs.ts               ← Recurring job scheduling engine
  recurrence.ts                  ← Shared recurrence math (cadence step + end conditions)
  recurringInvoices.ts           ← Recurring invoice (maintenance plan) engine
  invoiceNumber.ts               ← Next-invoice-number rule (INV-%04d)
  reviewRequest.ts               ← Customer review request helpers
  moneyUtils.ts                  ← Expense categories, date filters, date range math
  businessSnapshot.ts            ← Business metrics snapshot for AI context
  conversionFunnel.ts            ← Lead → paid conversion funnel analytics
  avgJobValue.ts                 ← Average job value analytics
  invoiceAging.ts                ← Invoice aging analytics
  revenueByType.ts               ← Revenue breakdown by job type
  seasonalTrends.ts              ← Seasonal revenue trends
  customerMix.ts                 ← Customer mix analytics (new vs repeat)
  expenseTrends.ts               ← Expense trends analytics
  revenueForecast.ts             ← Revenue forecast analytics
  csvImport.ts                   ← RFC-4180 CSV parser (never throws) + import-batch content hash
  importMapping.ts               ← Per-entity field defs, header-synonym detection (Jobber/HCP/QB), date-format parsing
  importEngine.ts                ← Pure per-entity import builders, status/category mapping, undo (stripBatch)
  importHistory.ts               ← Non-synced AsyncStorage import-batch history

hooks/
  useTheme.ts                    ← Dark/light theme hook (reads ThemeContext)
  useRefresh.ts                  ← Pull-to-refresh hook (shared across 9 screens)
  useSyncStatus.ts               ← Sync status hook (pending count, last sync time)
  useMoneyData.ts                ← Money tab data loader (invoices, expenses, refresh)

components/
  UI.tsx                         ← Shared primitives: Button, Card, Badge, StatCard,
                                   EmptyState, SectionHeader, LoadingState, …
  Field.tsx                      ← Shared text-input (label + input + escape hatches)
  DateTimePickerSheet.tsx        ← Cross-platform date/time picker (iOS sheet / Android dialog)
  SyncBanner.tsx                 ← Sync status banner (pending items indicator)
  PricebookPickerModal.tsx       ← Pricebook item picker for job materials
  money/
    SummaryCard.tsx              ← Income/expense summary widget
    MonthlyChart.tsx             ← Bar chart for monthly revenue
    ReceivablesCard.tsx          ← Outstanding receivables summary
    TopCustomersCard.tsx         ← Top customers by revenue
    ExpenseRow.tsx               ← Single expense list row
    AddExpenseModal.tsx          ← Log-expense bottom sheet
    MileageCard.tsx              ← Mileage deduction card on the Money dashboard
    TaxSetAsideCard.tsx          ← Quarterly tax set-aside card (reserve + deadline)
    TaxSettingsModal.tsx         ← Income-tax rate + vehicle-deduction election sheet
    PricebookCard.tsx            ← Pricebook quick-access card
    ConversionFunnelCard.tsx     ← Lead → paid conversion funnel
    AvgJobValueCard.tsx          ← Average job value chart
    InvoiceAgingCard.tsx         ← Invoice aging breakdown
    RevenueByTypeCard.tsx        ← Revenue by job type chart
    SeasonalTrendsCard.tsx       ← Seasonal revenue trends chart
    CustomerMixCard.tsx          ← New vs repeat customer mix
    ExpenseTrendsCard.tsx        ← Expense trends chart
    RevenueForecastCard.tsx      ← Revenue forecast chart

screens/
  TodayScreen.tsx                ← Today tab: schedule, earnings summary, route launch
  CalendarScreen.tsx             ← Day/week calendar + tap-to-reschedule sheet
  RouteScreen.tsx                ← Map view (deep-links to Apple/Google Maps)
  JobsScreen.tsx                 ← Job list with status filters (Active / Estimates / Completed)
  JobDetailScreen.tsx            ← Job detail: status pipeline, time tracking, materials
  AddJobScreen.tsx               ← Add / edit job form
  SendEstimateScreen.tsx         ← Review and send estimate via email or SMS
  PricingCalculatorScreen.tsx    ← AI-powered pricing calculator
  CreateInvoiceFromJobScreen.tsx ← Convert a completed job to an invoice
  InvoicesScreen.tsx             ← Invoice list with overdue detection
  AddInvoiceScreen.tsx           ← Add / edit invoice
  OutreachScreen.tsx             ← Generate and send collection messages
  MoneyScreen.tsx                ← Money tab: dashboard, expense log, analytics cards
  MileageLogScreen.tsx           ← Full mileage trip log (reached from Mileage deduction card)
  AddTripScreen.tsx              ← Add / edit trip (odometer start/end, from/to endpoint)
  CustomersScreen.tsx            ← Customer list with search
  CustomerDetailScreen.tsx       ← Customer history, notes, contact actions
  AddCustomerScreen.tsx          ← Add / edit customer
  SettingsHubScreen.tsx           ← Settings menu: rows push focused subpages; Support/Legal live here
  SettingsBusinessScreen.tsx      ← Business profile: contact info, logo, address
  SettingsAppearanceScreen.tsx    ← Dark/light theme toggle
  SettingsPricingScreen.tsx       ← Pricing defaults: hourly rate, materials markup, overhead
  SettingsInvoiceNumberingScreen.tsx ← Invoice numbering scheme (prefix, next number)
  SettingsImportScreen.tsx        ← CSV data import: customers, jobs, invoices, expenses
  SettingsAIScreen.tsx            ← AI Assistant: Groq/Anthropic API keys
  SettingsReviewsScreen.tsx       ← Review-request toggle, delay, and Google review link
  SettingsNotificationsScreen.tsx ← Overdue-invoice reminder rules and notification prefs
  SettingsPaymentsScreen.tsx      ← Payment processor setup: Stripe Connect, PayPal.Me, Venmo
  SettingsBookingScreen.tsx       ← Public booking link: enable/share, mint/rotate token, slot toggle
  SettingsScheduleScreen.tsx      ← Working hours, work days, buffers, time off
  SettingsSubscriptionScreen.tsx  ← Subscription status + manage/subscribe entry point
  SettingsAccountScreen.tsx       ← Clear sample data, sign out, delete account
  ChatScreen.tsx                 ← AI Coach chat (Groq via backend proxy)
  AuthScreen.tsx                 ← Sign in / sign up
  OnboardingScreen.tsx           ← First-run wizard
  PricebookScreen.tsx            ← Pricebook item list with AI-assisted pricing
  PricebookEntryScreen.tsx       ← Add / edit pricebook entry
  PaywallScreen.tsx              ← RevenueCat subscription paywall
  RecurringJobsScreen.tsx        ← Recurring job schedule manager
  RecurringInvoicesScreen.tsx    ← Maintenance-plan (recurring invoice) manager
  AddRecurringInvoiceScreen.tsx  ← Add / edit maintenance plan
  ReviewRequestScreen.tsx        ← Customer review request generator

context/
  AuthContext.tsx                ← Supabase auth state (session, sign-in, sign-out)
  ThemeContext.tsx                ← Dark/light mode context + toggle
  SubscriptionContext.tsx        ← RevenueCat subscription state
  SyncStatusContext.tsx          ← Sync queue status (pending count, last sync)

backend/                         ← Vercel serverless functions (deployed separately)
  api/                           ← Stripe Connect, payment links, AI proxies,
                                   account deletion, subscription webhook
  api/booking/[action].js        ← Booking link dispatcher — mint (JWT-authed),
                                   config, submit (public, token-gated)
  lib/guards.js                  ← Rate limiter + input caps shared by the AI endpoints
  lib/booking/                   ← store/validate/submit/config/mint/notifyOwner —
                                   booking link backend logic
  lib/estimate/portalView.js     ← portal-view handler — FROZEN at the v1 read
                                   shape (estimates + invoices); the completed
                                   Phase 12 portal is Workers-only (see below)
  lib/estimate/portalStore.js    ← Read-only, tenant-scoped Supabase reads for
                                   the v1 portal-view (token→customer, jobs, invoices)

backend-workers/                 ← Cloudflare Worker — the live backend since
                                   2026-08-06 (portal-relevant files shown;
                                   the Phase 12 portal exists ONLY here)
  src/routes/estimate/           ← portal-view (v2), portal-ics, portal-request,
                                   portal-manage route handlers
  src/routes/photosPublic.js     ← Anonymous signed photo read for portal photos
                                   (the owner-JWT /api/photos route is separate)
  lib/estimate/portalAssemble.js ← Whitelisted portal bundle — appointments,
                                   estimates, change orders, invoices (+ paid
                                   to date), customer-visible photos
  lib/estimate/portalTokenStore.js ← Server-owned token resolver (hash-only
                                   portal_tokens table; instant disable/rotate)
  lib/estimate/portalRequest.js  ← Customer message / reschedule / cancel
                                   request writes (capped, honeypotted)
  lib/photoSign.js               ← HMAC-signed, expiring portal photo URLs
```

---

## Submitting to the App Store (when you're ready)

This is a separate process that comes after you've tested the app and are
happy with it. The short version:

> **Before any build that reaches users — including an OTA `eas update` — run
> through `docs/release-checklist.md`.** It carries a list of merged-but-not-yet
> shippable features. This repo has long-lived branches whose data-layer changes
> go live with *any* build off `master`, including one made for an unrelated
> reason, so "I only changed one small thing" is not a safe assumption.

1. Sign up for an Apple Developer account at developer.apple.com ($99/year).
2. Install the EAS CLI: `npm install -g eas-cli`
3. Run `eas build --platform ios` to build the app in the cloud (no Mac needed).
4. Submit via `eas submit --platform ios` or upload manually through App Store Connect.

Apple reviews new apps in 1–3 days. Full guide: https://docs.expo.dev/submit/ios/

---

## Quality checks

The project ships with Jest tests and ESLint. Run them from the `tradeready/` folder.

### Lint

```bash
npm run lint          # report problems
npm run lint:fix      # auto-fix what ESLint can fix
```

### Format (Prettier)

```bash
npm run format        # rewrite all JS/JSON/MD files in-place
```

### Type check

```bash
npm run typecheck     # tsc --noEmit (TypeScript modules only; JS files use allowJs)
```

### Tests

```bash
npm test              # run all tests once
npm run test:watch    # watch mode — re-runs on file save
```

**Test layout:**

| File | What it covers |
|---|---|
| `__tests__/format.test.js` | `formatMoney` / `formatQuote` currency formatters |
| `__tests__/pricingEngine.test.js` | Pricing math — estimate, price range, break-even, trade nicknames |
| `__tests__/numberInput.test.js` | `parseNumberInput` safe parsing; `buildEstimateInput` (0%-overhead case) |
| `__tests__/invoiceHelpers.test.js` | Invoice date/status logic, payment link builder |
| `__tests__/invoiceStats.test.js` | Invoice summary stats, overdue detection, search filter |
| `__tests__/dateHelpers.test.js` | Date formatting, week math, greeting, time range |
| `__tests__/timeTracking.test.js` | Clock-in/out session math, live timer string |
| `__tests__/mileageUtils.test.js` | `computeTripMiles`, `mileageSummary` — mileage deduction math |
| `__tests__/taxEstimate.test.js` | Tax set-aside math: payment periods, deadline shifts, SE tax, vehicle election |
| `__tests__/TaxSetAsideCard.test.js` | Tax card presentation: figures, unset-state prompts, disclaimer |
| `__tests__/TaxSettingsModal.test.js` | Tax settings sheet: pre-fill, validation, draft shape |
| `__tests__/jobStatus.test.js` | Status pipeline; approved → scheduled transition |
| `__tests__/jobStatusDisplay.test.js` | Badge labels and colors for all 8 job statuses |
| `__tests__/customerList.test.js` | Customer aggregation from invoices + manual records |
| `__tests__/customerIdentity.test.js` | Customer registry upsert, migration, notes |
| `__tests__/messaging.test.js` | Email/SMS composer — availability guard, fallback Alert |
| `__tests__/anthropicMessage.test.js` | Anthropic API call — error and empty-response fallback |
| `__tests__/storage.test.js` | Local persistence layer |
| `__tests__/sync.test.js` | Supabase sync queue — enqueue, push, pull |
| `__tests__/notifications.test.js` | Push notification scheduling |
| `__tests__/paymentLink.test.js` | Payment link URL builder |
| `__tests__/moneyUtils.test.js` | Money utility functions |
| `__tests__/UI.test.js` | Component smoke tests — Badge, Button, EmptyState, StatCard |
| `__tests__/paywallCopy.test.js` | Paywall trial wording from the store's intro-offer data |
| `__tests__/backendGuards.test.js` | Backend rate limiter + AI payload input caps |

_(Table lists the core suites; `npm test` is the authoritative count — 38 suites as of 2026-07-13.)_

**Tech notes:**

- Test runner: [jest-expo](https://github.com/expo/expo/tree/main/packages/jest-expo) (matches Expo SDK version)
- Component tests: [@testing-library/react-native](https://callstack.github.io/react-native-testing-library/) v14 (async `render`)
- Linter: ESLint 8 with `eslint-config-expo`

---

## Sync model and known limitations

TradeReady is **local-first**: all reads and writes hit AsyncStorage immediately.
Supabase sync is a background layer — the app works fully offline and syncs when
a network connection is available.

### How sync works

| Event | What happens |
|---|---|
| First login on a device | Local data is pushed to the cloud (if none exists there yet) |
| Login on a second device | Cloud data is pulled down; local storage is populated from the cloud |
| Every save operation | Change is queued in `__syncQueue` and pushed on the next online moment |
| App resumes from background | Queue is flushed; any remote changes since the last sync are pulled |
| Sign-out | All local data, the sync queue, and the `__dataOwner` marker are cleared |

### Known limitations

**Almost no conflict resolution.** If the same record is edited on two devices
while both are offline, last-write wins when they both sync. There is no
general merge or conflict detection.

**Offline scheduling can be double-booked online (added 2026-08-07).** The
bookable-slots feature computes open times from the jobs that have reached the
cloud. A job you schedule while your phone is offline is invisible to the
booking page until your next sync, so a customer could book that same window
in the meantime. The clash shows up as a conflict warning on the calendar and
in Add Job as soon as the booking syncs down — resolve it by rescheduling one
of the two.

There are two designed exceptions. An invoice's **payment ledger** is merged
rather than replaced: `pullRemote` unions the two sides' `payments` by payment
id (`utils/syncMerge.ts` → `mergePaymentLedgers` in `utils/invoicePayments.ts`),
then recomputes `paid` / `paidAt` from the union. Everything else on the
invoice — amount, customer, description — still follows last-write-wins.
Similarly, a booking request's **history** (the audit trail of customer
confirm/reschedule/cancel actions, added 2026-08-07) is unioned on pull so a
server-appended entry and a device write racing each other can't drop
anything; all other booking-request fields stay last-write-wins.

The exception exists because a ledger can legitimately grow on both sides at
once: the Stripe webhook appends a payment server-side while the tradesperson
records a cash payment on the device. Replacing would destroy whichever side
lost, i.e. lose money. The union by id is what makes that safe to merge, but a
repeated webhook delivery can't double-count only because the webhook and
`applyPayment` each check for an existing entry with that payment id and skip
appending a duplicate *before* the union ever runs — the union itself has no
way to tell a genuine second payment from a redelivered one.

**Ledger union:** The Postgres union trigger is applied to the live database, so
the ledger merge is enforced on both sides — `pullRemote` unites the device
ledger with what's on the server, and a Postgres trigger unites both sides on
every write to the `invoices` table. This means neither a stale device push
nor a webhook write can shrink or clobber a ledger entry. The union works
only because deletion is recorded as a one-way `voidedAt` date rather than
removal from the array — a union cannot distinguish "unknown to me" from
"deleted by me" without the data. This protection covers recorded ledger
**entries** only: an invoice with no `payments` key on either side has no data
for the union to merge, so it remains last-write-wins on the `paid` flag —
legacy invoices (the majority of production data today) are not covered.

Do NOT "simplify" this back to a plain replace, and do not widen the union to
other tables without designing a merge for their shape.

**Job photos sync across devices since 2026-08-06.** Photos attached to jobs are
still rendered from the device file system (the app never waits on the network
to show a photo), but they are now mirrored to Cloudflare R2 in the background:
each photo is a record in the synced `jobPhotos` collection, and its
compressed JPEG bytes upload to R2 and download on demand. Attach on one device
and the photo appears on your others after sync; reinstall and photos re-download.
A photo captured on another device shows a placeholder until its bytes arrive.
The image bytes themselves are last-write-wins per photo id (adds never
conflict). **Receipt photos and the business logo remain device-local only** —
they use the same file store but are not yet mirrored.

**SecureStore fields are device-local only.** API keys (`providerKey`,
`anthropicKey`, `groqKey`) live in the iOS Keychain / Android Keystore and
are never written to Supabase. You must re-enter them on each device.

**Recurring rules and mileage trips sync since 2026-08-03.** Recurring-job
rules, recurring-invoice (maintenance plan) rules, and mileage `Trip` records
are full members of `COLLECTION_TABLES` (`utils/sync.ts`) — they push, pull,
and survive reinstalls like every other collection. Devices that predate the
change enqueue their existing local records once, on the first sign-in after
updating (per-user `__collBackfill_v1_` flag). Residual limitation: the
recurring generation engines skip an occurrence whose job/invoice already
arrived from another device (matched on `recurringJobId`/`recurringInvoiceId`
+ `occurrenceNumber`), but two devices that both generate the same occurrence
*before either has synced* will still each create one — the same
concurrent-edit envelope as last-write-wins above.

**Estimate approvals are the one server-authoritative write path.** When a
customer approves or declines an estimate via the hosted link, the Vercel
backend writes `job.approval.*` straight to Supabase with the service-role
key (bypassing the normal device→cloud flow) — the same pattern the Stripe
webhook uses for invoice payments. The device picks the decision up on its
next `pullRemote` (sign-in or app-foreground) and advances the job's status
locally; the server never writes `job.status`. This write inherits the same
last-write-wins envelope as everything else: an un-pushed local edit to that
job can still clobber the pulled `approval.*` fields on its next push.

**Booking link and push token live in the settings blob.** `settings.bookingLink`
(the minted share token) and `settings.pushToken` (the device's Expo push
token) are plain fields on the same synced `Settings` row as everything else,
so a stale device's settings save can clobber them — the same last-write-wins
class as the rest of Settings, not a special case. On a single device this
can't happen day-to-day: the Settings screen keeps both fields pinned to their
on-disk value across a "Save settings" tap. The exposure is cross-device only —
a second device that saves settings before pulling the latest booking link or
push token overwrites it with its own stale copy: whichever token ends up in
the cloud row is the one that resolves, so a link you already shared under a
token that just got clobbered away will 404 until you tap "Get new link" to
rotate it and re-share. A clobbered push token just falls back to email-only
alerts until a device re-registers, which happens automatically on the next
app foreground or sign-in (`utils/pushToken.ts`, only-on-change). Separately,
because request conversion (`utils/storage/bookingConversion.ts`) assigns
customers a time-based rather than deterministic id, two devices converting
the same request concurrently can each create a duplicate customer record for
the same person, which the existing duplicate-customer merge prompt recovers.

**The portal token on the customer record is only a display copy (since
2026-08-07).** The real authority is the server's `portal_tokens` table,
which stores only a sha256 hash of each token (the raw token is returned
exactly once, when the link is created) — so disabling or rotating a link
takes effect on the very next request, with no sync round-trip.
`Customer.portal` on the device is a display copy kept so the URL row and
share sheet work offline; CustomerDetail's create/toggle/rotate buttons call
the server first and save the copy only after the server confirms.
Cross-device last-write-wins can still clobber the *copy* (a stale device
overwriting the customer blob), which makes a device display an outdated
link — if the link a device shows ever stops working, rotate from
CustomerDetail and re-share.

**An out-of-date app can still mint an untracked portal link.** A phone
running a pre-2026-08-07 build mints portal tokens the old stateless way,
writing them only onto the customer blob. The server's fallback honors such a
token (and registers it in `portal_tokens` on first use), so nothing breaks —
but until the next rotate, that customer can briefly have two working links.
Rotating from CustomerDetail revokes every link for that customer at once.

**The portal's abuse limits are best-effort.** A customer can send at most 5
portal requests (messages, reschedule or cancel asks) per day per link,
counted against the `portal_access_log` table — if that log is unreachable
the cap is skipped rather than blocking a legitimate customer (deliberate
fail-open). Separately, the per-IP rate limits on the public portal
endpoints are held in memory per Worker isolate, so the effective global
limit is a multiple of the configured number.

**Estimates and invoices are invisible on the portal until customerId is
stamped.** The portal-view backend matches a customer's jobs (for estimates,
appointments, change orders, and photos) and invoices by `customerId`, but
older records that predate that field only carry a typed customer name. Those
records stay invisible on the customer's portal page until
`migrateCustomerIdentity` backfills `customerId` onto them, which runs
automatically on the owner's next sign-in — so the gap is transient, not
permanent, but a portal link shared and opened before that backfill runs will
show less than exists.

**Archiving a customer does not disable their portal link.** Archiving only
hides the customer from list views (Customers, Jobs, search) — it deliberately
touches neither the server-side portal token nor `Customer.portal`, so the
customer-facing portal keeps working after archive, the same way archived
customers' invoices and notifications keep working. Disable or rotate the
link from CustomerDetail if you need to cut it off.

**First-device detection counts settings rows.** `initialSync` decides
push-vs-pull by counting the user's rows in the cloud `settings` table
(`utils/sync.ts`) — a settings row is created by the first successful push, so
count 0 ≈ this user has never synced. Edge case: a user whose cloud holds data
but whose settings push never completed would be misclassified as a first
device and have local data pushed up.

**Token-expiry sign-outs do not wipe local data.** Supabase fires `SIGNED_OUT`
on token expiry as well as on real sign-outs, so the auth handler deliberately
clears nothing (`context/AuthContext.tsx`) — an offline user whose session
lapsed keeps their local data and unsent queue, and syncing resumes on the
next sign-in. Cross-user isolation is enforced by the `__dataOwner` guard in
`initialSync` instead. (A wipe-on-SIGNED_OUT version shipped briefly in July
2026 and destroyed offline changes on token expiry; do not reintroduce it.)

**Explicit sign-out prompts before dropping unsynced changes.** The Settings
sign-out button checks `__syncQueue` first: with items pending it offers
"Sync & sign out" (flush, then clear) or "Sign out anyway" (destructive).
Only the destructive choice discards the queue — but it does so permanently:
`clearAllUserData()` removes `__syncQueue` along with the collections.

---

## Common errors

**"Command not found: expo"**
→ Run `npm install -g expo-cli` again, then try.

**"Unable to resolve module..."**
→ Run `npm install` in the project folder, then restart with `npx expo start`.

**App won't load on phone**
→ Make sure your phone and computer are on the same WiFi network.

**Messages not generating**
→ Check your internet connection. The app calls the Anthropic API to write messages.
→ Make sure your Anthropic API key is entered in Settings.
