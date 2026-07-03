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

## Common errors

**"Command not found: expo"**
→ Run `npm install -g expo-cli` again, then try.

**"Unable to resolve module..."**
→ Run `npm install` in the project folder, then restart with `npx expo start`.

**App won't load on phone**
→ Make sure your phone and computer are on the same WiFi network.

**Messages not generating**
→ Check your internet connection. The app calls the Anthropic API to write messages.
