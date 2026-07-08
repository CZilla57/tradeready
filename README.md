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

## Step 3 — Connect your payment processor

1. Open the app and go to the Settings tab.
2. Select your payment processor (Stripe, Square, PayPal, etc.).
3. Paste in your API key or account ID.

For the payment link to actually work, you also need to deploy the serverless
functions in the `invoice-payment-api` folder to Vercel. See that folder's
README for instructions. Once deployed, update `backendUrl` in `app.json`:

```json
"extra": {
  "backendUrl": "https://your-deployment.vercel.app",
  "backendUrlIsPlaceholder": false
}
```

The app reads `backendUrl` at runtime — no code changes required.

---

## Step 4 — Add your AI keys

The app uses Claude (Anthropic) to generate pricing estimates and collection messages,
and optionally Groq as an alternative AI provider.

1. Go to console.anthropic.com and create an account.
2. Generate an API key.
3. Open the app, go to **Settings**, and paste the key into the **Anthropic key** field.

The key is stored securely in the iOS Keychain / Android Keystore and never leaves
your device. You must re-enter it on each device you sign in to.

For a production app, you'd move the Anthropic API call to a serverless function
so your key isn't stored on the device at all.

---

## File map — what does what

```
App.js                           ← Entry point; sets up tabs and navigation stacks
app.json                         ← Expo config (name, icons, backendUrl, EAS project)
types/
  models.ts                      ← TypeScript types for all data shapes

utils/
  theme.js                       ← All colors, font sizes, spacing
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
  invoiceHelpers.js              ← Payment link fetch, AI message text, PDF helpers
  anthropicMessage.ts            ← Shared Anthropic (Claude) API call with error fallback
  messaging.ts                   ← composeEmail / composeSMS (availability guard + Alert)
  dateHelpers.ts                 ← Date/time formatting, week math, greeting
  jobStatus.ts                   ← advanceStatusForSchedule (approved → scheduled logic)
  jobStatusDisplay.ts            ← getJobStatusDisplay — badge labels + colors
  timeTracking.ts                ← computeTimeTracking — clock-in/out session math
  mileageUtils.ts                ← computeTripMiles, mileageSummary — mileage deduction math
  invoiceStats.ts                ← summarizeInvoices, isOverdue, filterInvoices
  numberInput.ts                 ← parseNumberInput, buildEstimateInput (safe 0-handling)
  customerList.ts                ← buildCustomerList — invoice/record join + rollup
  sync.js                        ← Supabase sync queue (push/pull, enqueue, trySync)
  supabase.js                    ← Supabase client (auth + database)
  notifications.js               ← Push notification scheduling (overdue reminders)
  pdfTemplates.js                ← HTML templates for invoice and estimate PDFs
  pdfExport.js                   ← PDF rendering and share sheet
  photoStorage.js                ← Device photo management (expo-file-system)
  aiService.js                   ← Groq AI integration (alternative to Anthropic)
  moneyUtils.js                  ← (legacy) retained for existing callers

components/
  UI.js                          ← Shared primitives: Button, Card, Badge, StatCard,
                                   EmptyState, SectionHeader, LoadingState, …
  Field.tsx                      ← Shared text-input (label + input + escape hatches)
  DateTimePickerSheet.tsx        ← Cross-platform date/time picker (iOS sheet / Android dialog)
  money/
    SummaryCard.js               ← Income/expense summary widget
    MonthlyChart.js              ← Bar chart for monthly revenue
    ReceivablesCard.js           ← Outstanding receivables summary
    TopCustomersCard.js          ← Top customers by revenue
    ExpenseRow.js                ← Single expense list row
    AddExpenseModal.js           ← Log-expense bottom sheet
    MileageCard.tsx              ← "Mileage deduction" card on the Money dashboard

screens/
  TodayScreen.js                 ← Today tab: schedule, earnings summary, route launch
  RouteScreen.js                 ← Map view (deep-links to Apple/Google Maps)
  JobsScreen.js                  ← Job list with status filters (Active / Estimates / Completed)
  JobDetailScreen.js             ← Job detail: status pipeline, time tracking, materials
  AddJobScreen.js                ← Add / edit job form
  SendEstimateScreen.js          ← Review and send estimate via email or SMS
  PricingCalculatorScreen.js     ← AI-powered pricing calculator
  CreateInvoiceFromJobScreen.js  ← Convert a completed job to an invoice
  InvoicesScreen.js              ← Invoice list with overdue detection
  AddInvoiceScreen.js            ← Add / edit invoice
  OutreachScreen.js              ← Generate and send collection messages
  MoneyScreen.js                 ← Money tab: dashboard, expense log, charts
  MileageLogScreen.tsx           ← Full mileage trip log (reached from the Mileage deduction card)
  AddTripScreen.tsx              ← Add / edit trip (odometer start/end, from/to endpoint)
  CustomersScreen.js             ← Customer list with search
  CustomerDetailScreen.js        ← Customer history, notes, contact actions
  AddCustomerScreen.js           ← Add / edit customer
  SettingsScreen.js              ← Business profile, AI keys, payment processor
  ChatScreen.js                  ← AI Coach chat (Claude or Groq)
  AuthScreen.js                  ← Sign in / sign up
  OnboardingScreen.js            ← First-run wizard

context/
  AuthContext.js                 ← Supabase auth state (session, sign-in, sign-out)
```

---

## Submitting to the App Store (when you're ready)

This is a separate process that comes after you've tested the app and are
happy with it. The short version:

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

**No conflict resolution.** If the same record is edited on two devices while
both are offline, last-write wins when they both sync. There is no merge or
conflict detection.

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
or sign in on a different device, logged trips will not be present. Adding
cloud sync later means adding a `trips` Supabase table plus one entry in
`COLLECTION_TABLES`.

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
