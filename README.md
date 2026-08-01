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
**Settings → Connect Stripe** — no API keys needed. The backend (Vercel
serverless at `backend/api/stripe/`) handles account creation, onboarding,
payment link generation, and webhooks.

The backend is deployed at `backend-tradeready1.vercel.app`. The app reads
`backendUrl` from `app.json` at runtime:

```json
"extra": {
  "backendUrl": "https://backend-tradeready1.vercel.app",
  "backendUrlIsPlaceholder": false
}
```

---

## Step 4 — AI setup

AI features (business chat, pricebook suggestions, receipt scanning) are proxied
through the Vercel backend using server-side API keys — no user-supplied keys
required.

- **AI Coach chat** — Groq (Llama 3.1) via `backend/api/ai-chat.js`
- **Pricebook AI Assist** — Claude (Anthropic) via `backend/api/pricebook-suggest.js`
- **Receipt scanning** — Claude vision via `backend/api/receipt-extract.js`; attaching
  a receipt photo to an expense pre-fills merchant/amount/date/category for review
  (never auto-saves; extraction failure falls back to plain manual entry)

Required Vercel env vars: `GROQ_API_KEY`, `ANTHROPIC_API_KEY`, `SUPABASE_URL`,
`SUPABASE_ANON_KEY`.

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
  storage/                       ← Local persistence (9 typed modules, see below)
    index.ts                     ← Barrel: re-exports public API
    keys.ts                      ← AsyncStorage key constants
    defaults.ts                  ← Default/seed values for each collection
    collections.ts               ← Load/save for invoices, jobs, customers, expenses
    settings.ts                  ← Settings (public + SecureStore-backed fields)
    customers.ts                 ← Customer registry (upsert, notes, migration)
    trips.ts                     ← loadTrips/saveTrips — mileage log, local-only (not synced)
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
  pdfTemplates.ts                ← HTML templates for invoice and estimate PDFs (XSS-safe)
  pdfExport.ts                   ← PDF rendering and share sheet
  photoStorage.ts                ← Device photo management (expo-file-system)
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
  SettingsScreen.tsx             ← Business profile, appearance, Stripe Connect, payments
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
  lib/guards.js                  ← Rate limiter + input caps shared by the AI endpoints
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

The one exception is an invoice's **payment ledger**, which is merged rather
than replaced: `pullRemote` unions the two sides' `payments` by payment id
(`utils/syncMerge.ts` → `mergePaymentLedgers` in `utils/invoicePayments.ts`),
then recomputes `paid` / `paidAt` from the union. Everything else on the
invoice — amount, customer, description — still follows last-write-wins.

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

**Photos are device-local only.** Photos attached to jobs are stored in the
device file system via `expo-file-system` and are not synced to the cloud. If
you reinstall the app or sign in on a different device, those photos will not
be present.

**SecureStore fields are device-local only.** API keys (`providerKey`,
`anthropicKey`, `groqKey`) live in the iOS Keychain / Android Keystore and
are never written to Supabase. You must re-enter them on each device.

**Mileage trips are device-local only.** The mileage deduction log (`Trip`
records, under Money → Mileage deduction) is stored in AsyncStorage only,
the same as recurring jobs — it is not in the sync engine's `COLLECTION_TABLES`
list (`utils/sync.ts:11`) and is cleared on sign-out. If you reinstall the app
or sign in on a different device, logged trips will not be present. The tax
set-aside card's standard-mileage deduction reads this same local log, so its
estimate can differ across devices; the card discloses this with a trip count. Adding
cloud sync later means adding a `trips` Supabase table plus one entry in
`COLLECTION_TABLES`.

**Recurring-invoice rules are device-local only.** Maintenance-plan rules
(`RecurringInvoice` records, behind the repeat icon on the Invoices tab) are
stored in AsyncStorage only, the same as recurring jobs and mileage trips —
not synced, cleared on sign-out. The invoices they generate are normal
records and sync like any other invoice.

**Estimate approvals are the one server-authoritative write path.** When a
customer approves or declines an estimate via the hosted link, the Vercel
backend writes `job.approval.*` straight to Supabase with the service-role
key (bypassing the normal device→cloud flow) — the same pattern the Stripe
webhook uses for invoice payments. The device picks the decision up on its
next `pullRemote` (sign-in or app-foreground) and advances the job's status
locally; the server never writes `job.status`. This write inherits the same
last-write-wins envelope as everything else: an un-pushed local edit to that
job can still clobber the pulled `approval.*` fields on its next push.

**First-device detection uses job count only.** `initialSync` decides whether
to push or pull based on whether the `jobs` table has any cloud rows for the
user. A user with customers and invoices but no jobs would be treated as a new
device and have their local data pushed up.

**Stale-data window on token expiry.** If a Supabase session expires while the
app is backgrounded and the device is offline, the `SIGNED_OUT` event fires the
next time the app is opened but before it can reach the network. Local data is
cleared at that point. Any unsent items in `__syncQueue` at the time of expiry
are lost.

**Pending queue items are dropped on sign-out.** `clearAllUserData()` removes
`__syncQueue`, so any writes that hadn't been flushed to Supabase are
permanently lost when the user signs out.

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
