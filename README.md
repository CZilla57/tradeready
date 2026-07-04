# Invoice Collector — Expo App

A React Native app for collecting overdue invoices. Built with Expo so you can
run it on your iPhone immediately without needing a Mac or Xcode.

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

1. Copy this entire `invoice-app` folder somewhere on your computer (e.g. your Desktop).
2. Open Terminal and navigate to that folder:
   ```
   cd ~/Desktop/invoice-app
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
README for instructions. Once deployed, update the `VERCEL_URL` in:
```
utils/invoiceHelpers.js
```

---

## Step 4 — Add your Anthropic API key

The app calls Claude to generate collection messages. To make this work:

1. Go to console.anthropic.com and create an account.
2. Generate an API key.
3. Open `utils/invoiceHelpers.js` and find the `generateOutreachMessage` function.
4. The fetch call to `api.anthropic.com` will work automatically once you're
   authenticated. For a production app, you'd move this call to a serverless
   function (same pattern as the payment link functions) so your key isn't in
   the app bundle.

---

## File map — what does what

```
App.js                     ← Entry point, sets up navigation
app.json                   ← Expo config (app name, icons, etc.)
package.json               ← List of packages the app depends on

utils/
  theme.js                 ← All colors, font sizes, spacing
  storage.js               ← Saves/loads data on the device
  invoiceHelpers.js        ← Invoice logic, payment link fetching, AI messages

components/
  UI.js                    ← Small reusable pieces (Button, Card, Badge, etc.)

screens/
  InvoicesScreen.js        ← Main invoice list
  AddInvoiceScreen.js      ← Add / edit invoice form
  OutreachScreen.js        ← Generate and send collection messages
  CustomersScreen.js       ← Customer list and history
  SettingsScreen.js        ← Business info, payment processor, notification rules
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

### Tests

```bash
npm test              # run all tests once
npm run test:watch    # watch mode — re-runs on file save
```

**Test layout:**

| File | What it covers |
|---|---|
| `__tests__/pricingEngine.test.js` | Pure pricing math (estimate, price range, break-even, trade nicknames) |
| `__tests__/invoiceHelpers.test.js` | Invoice date/status logic, currency formatting, payment link builder |
| `__tests__/UI.test.js` | Component smoke tests — Badge, Button, EmptyState, SectionHeader, StatCard |

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
