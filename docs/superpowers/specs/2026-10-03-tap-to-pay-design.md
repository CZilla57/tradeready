# In-Person Card Payment / Tap to Pay on iPhone (Roadmap Phase 18) — Design Spec

**Date:** 2026-10-03
**Status:** SCOPED. Builds on `feat/tap-to-pay`, stacked on the build-order branches before it (#1–#12, ending with `feat/esign-upgrade`). Owner go-ahead 2026-10-03: "continue working until all features on the roadmap are properly completed … implemented in the most beneficial way to the user". Code map verified 2026-10-03 against the `feat/quote-expiration` working tree, where Phase 32 is uncommitted. Nothing built. **The SDK, the entitlement, Info.plist permission strings, Stripe Dashboard changes, privacy-label changes and legal wording all wait for owner approval (§12).**
**Origin:** `docs/post-launch-feature-roadmap.md` Phase 18, build order #13 ("Existing Stripe, plus an Apple entitlement and the Stripe Terminal SDK")
**Builds on:** Stripe Connect (Express accounts, direct charges), the payment ledger and union trigger (`2026-07-18-deposits-partial-payments-design.md`, `2026-07-18-server-side-ledger-merge-design.md`), the Connect webhook, the Phase 24–28 scoping notes (`2026-10-02-phase-24-28-scoping-notes.md`)
**Build target:** the native SwiftUI app and the Worker. **No React Native changes.** No migration.

## 0. Preconditions verified against the repo

`N/` means `native/TradeReadyNative/`.

**Stripe today**
- Collection is Stripe Payment Links, created as **direct charges on the owner's connected Express account** through the `stripeAccount` option (`backend-workers/src/routes/createPaymentLink.js:94-121`). The API version is pinned to `2023-10-16` in every constructor (`:90-93`, `backend-workers/src/routes/stripe/webhook.js:53-56`).
  - The only metadata is `{invoiceId}` (`createPaymentLink.js:118`).
  - The server checks only `amount > 0`. It does no ownership check and no balance check (`:84-85`).
- Connected accounts are Express with `card_payments` and `transfers` requested (`backend-workers/src/routes/stripe/createConnectAccount.js:45-51`). `stripe_accounts` maps `user_id` to `stripe_account_id`. `connect-status` returns `connected`, `details_submitted` and `display_name`, and **never reads `charges_enabled`** (`backend-workers/src/routes/stripe/connectStatus.js:45-61`).
- The Connect webhook acts only on `checkout.session.completed` with `payment_status === 'paid'` (`webhook.js:69-79`). Ownership is `event.account` against the owner's row (`webhook.js:136-148`, `backend-workers/lib/stripe/webhookOwnership.js:28-40`).
  - The ledger id is `stripe_<session.id>`, with an idempotency short-circuit (`webhook.js:150,166`).
  - The date is the **UTC** day (`:168-172,192`).
  - `method: 'stripe'` is reserved for Stripe-reconciled entries, so the history can tell them from a card keyed in by hand (`:185-195`).
- The write is read-modify-write and relies on the union trigger (`webhook.js:5-14,217-231`). The trigger unions by id: a void wins, otherwise the incoming copy wins (`supabase/migrations/20260718_invoice_payment_merge.sql:18-21,100-112`). Whether it has been applied is **unclear** (`docs/deposits-resume-here.md:58`; scoping notes "Webhook").

**Ledger consumers of `method`** (why this spec does not add a new method value; see §3)
- Native display: `displayPaymentMethod` maps anything unknown, **including `stripe`, to "Other"** (`N/Domain/UIModelAdapters.swift:1201-1206`). The invoice payment row prints that string (`N/InvoicesView.swift:406`). This is pre-existing: Stripe-link payments show as "Other" today.
- Customer PDF: `methodLabel` maps `card`/`stripe` to "Card", and **returns any other raw string verbatim** (`N/NativeInvoicePDF.swift:95-105`). A new value such as `card_present` would print as-is on a customer document.
- Profitability flags `feesUnknown` only for `.stripe` (`N/Domain/FinancialDomain.swift:868-871`). The accountant package derives the source from the `stripe_` id prefix (`N/Domain/NativeAccountingPackage.swift:70-74`). Analytics has a closed `PaymentMethod` enum (`N/NativeAnalyticsEvents.swift:278-287`, `N/NativeAnalytics.swift:99`). RN's union is `stripe|cash|check|card|other` (`types/models.ts:436`).
- A new device payment goes through `newCanonicalPayment`, which writes only `id, amount, date, method, note, voidedAt` (`N/Domain/UIModelAdapters.swift:1224-1232`). Existing payments keep unknown keys through the baseline merge (`:893-902,1213-1222`). Extra fields such as a payment intent id therefore need a dedicated write path.

**Native app**
- Invoice detail:
  - The Payments section is at `N/InvoicesView.swift:399-447`, with "Record payment" at `:436`.
  - Swipe-to-void is at `:422-429`. `AppStore.voidPayment` (`N/AppStore.swift:4474`) voids in the ledger only and moves no money.
- The manual `PaymentEditor` offers Cash, Cheque, Card and Other (`N/InvoicesView.swift:616-670`). `AppStore.recordPayment` is at `N/AppStore.swift:4437-4453`, committing through `commitInvoicePayment` (`:9852`).
- The Stripe Connect client is `N/NativeStripeConnect.swift:21-90`. The status is published at `N/AppStore.swift:343`. The Payments settings page is `N/SettingsView.swift:500-560`.
- Entitlements are Sign in with Apple and the app group only (`N/TradeReadyNative.entitlements`).
- `native/Info.plist` declares only the camera usage string (`:30`) and background `fetch` (`:34`). There is **no location permission today**.
- `N/PrivacyInfo.xcprivacy` declares no location and no payment-info data type.
- The deployment target is iOS 17.0 (`native/TradeReadyNative.xcodeproj/project.pbxproj:358`). There are four SPM packages: GoogleSignIn, RevenueCat, PostHog and Sentry (`:268-271`).
- Scoping notes flag a suspected bug: `generateInvoicePaymentLink` mints a link and then throws `.invalidAmount` for deposits (`N/AppStore.swift:2347-2390`). It is unrelated, but it is on the same screen.

**External facts (fetched 2026-10-03)**
- **Entitlement.** `com.apple.developer.proximity-reader.payment.acceptance`, requested at `developer.apple.com/contact/request/tap-to-pay-on-iphone/`.
  - It needs an **organization** developer account, requested by the **Account Holder**. Individual accounts are not eligible.
  - There are two steps: a development entitlement first, then a distribution entitlement requested by replying to Apple's email after testing.
  - Sources: [Apple, setting up the entitlement](https://developer.apple.com/documentation/proximityreader/setting-up-the-entitlement-for-tap-to-pay-on-iphone), [Apple Tap to Pay](https://developer.apple.com/tap-to-pay/).
- **Lead time and review** (Stripe's Tap to Pay guide, linked from Stripe's docs, not an Apple document):
  - The development entitlement is usually granted in 1–2 business days.
  - For distribution, Apple answers in 1–2 weeks, typically with 1–2 rounds of feedback, and wants screen recordings of the new-user, existing-user and checkout flows.
  - **TestFlight needs the distribution entitlement**, so there is no external beta before Apple's review passes.
  - The guide's checklist also covers terms accepted only by an admin, merchant education, a progress indicator during configuration, a Tap to Pay button that is never hidden or disabled, clear result screens and a digital receipt. For public apps it adds a launch email, a launch splash screen and a push notification.
- **Devices.** iPhone XS or later, on an iOS version released within the last year (older versions error). A passcode is required. No iPad. PIN entry needs iOS 16.4+. Source: [Stripe: Tap to Pay setup](https://docs.stripe.com/terminal/payments/setup-reader/tap-to-pay?platform=ios). The exact current minimum iOS version is unverified (Apple's table needs JavaScript).
- **SDK.** Stripe Terminal iOS **5.8.0** (2026-08-18). The minimum iOS is 15.0 since 5.0.0. It installs through SPM (`stripe-terminal-ios-spm`) and has shipped a privacy manifest since 3.5.0. The release zip is about 29.7 MB for all architectures; the real app-size impact is unverified. Sources: [stripe-terminal-ios](https://github.com/stripe/stripe-terminal-ios), [CHANGELOG](https://raw.githubusercontent.com/stripe/stripe-terminal-ios/master/CHANGELOG.md).
- **Direct charges with Terminal.** Connection tokens, Locations, readers and PaymentIntents all live on the connected account (`Stripe-Account` header). Source: [Terminal with Connect](https://docs.stripe.com/terminal/features/connect?connect-charge-type=direct).
  - Tap to Pay connects with a `locationId` (`TapToPayConnectionConfiguration`). US Locations need a full address.
  - On 2023-10-16, PaymentIntents take `payment_method_types: ['card_present']`. The newer `allowed_payment_method_types` exists only from API version 2026-07-29.
  - Confirmation must happen through the SDK on the device.
  - A Connect webhook receives `payment_intent.succeeded` with `event.account` ([Connect webhooks](https://docs.stripe.com/connect/webhooks)).
- **Merchant terms.** Each connected account accepts Apple's Tap to Pay terms on first connect, with an Apple ID. After that it is not asked again on other devices. `isTapToPayAccountLinked` exists from SDK 5.5.0. The platform is also subject to [Stripe's Apple acceptance platform terms](https://stripe.com/legal/apple-acceptance-platform).
- **Runtime.** The reader disconnects in the background, so payment needs the app in the foreground. First configuration can take minutes, so the docs say to prepare early and show progress. `NSLocationWhenInUseUsageDescription` is **required**: payments are disabled without location access. `NSBluetoothAlwaysUsageDescription` is required by App Store processing because the SDK links CoreBluetooth.
- **Testing.** A simulated Tap to Pay reader exists (`setSimulated(true)`). Stripe's example app uses it without an entitlements file, but no doc states that it works without the entitlement, so that is unverified. Real taps in test mode need the development entitlement. Source: [Terminal testing](https://docs.stripe.com/terminal/references/testing?terminal-sdk-platform=ios).
- **Pricing (US).** 2.7% + 5¢ per transaction, plus $0.10 per Tap to Pay authorization ([stripe.com/pricing](https://stripe.com/pricing)). With direct charges, fees are billed to the connected account ([fee payer behavior](https://docs.stripe.com/connect/direct-charges-fee-payer-behavior)).
- **Refunds** are server-side through the Refunds API on the PaymentIntent, with the `Stripe-Account` header ([Terminal refunds](https://docs.stripe.com/terminal/features/refunds?terminal-sdk-platform=ios)). Offline Tap to Pay is a US private preview and is not used here.
- **Platform caution.** Stripe's Connect docs say direct charges are **not recommended for legacy (v1) Express accounts** and suggest Accounts v2 or destination charges ([charge types](https://docs.stripe.com/connect/charges)). TradeReady's payment links already use that model.

## 1. Recommendation: GO, in approval-gated stages

**Go.** Getting paid on the spot is a real friction point for a solo trade, and Tap to Pay needs no hardware. **The calendar is set by Apple, not by engineering:**
- Development entitlement: 1–2 business days.
- Build and test with the SDK: about 2–3 weeks.
- Distribution review: 1–2 weeks plus 1–2 feedback rounds.
- Then App Review.

**Realistic total: 4–8 weeks after the owner approves the SDK and requests the entitlement**, and only if the developer account is an organization (§12 Q1).

**Shape.** Keep the payment-link model so the two paths never fork:
- **Direct charge on the owner's connected account**: the same account, fees and webhook ownership rule as payment links.
- **The server creates every PaymentIntent.** It checks invoice ownership and the remaining balance. That is stricter than payment links, which check neither, and it stamps server-authored metadata.
- **One ledger entry id for both writers:** `stripe_<payment_intent_id>`. The device records it the moment the SDK reports success, and the webhook records it if the device never does. The union trigger collapses the two copies.
- **No new `method` value.** Use `method: "stripe"` plus `channel: "card_present"` (§3).

**What can be built before any approval** (stage A, §8) is everything except the code that imports the SDK: three Worker routes, the webhook branch, the ledger and display changes, the reader protocol with an "unavailable" implementation and a test fake, and the UI behind a capability flag that is off by default.

## 2. Architecture

```
Device (SwiftUI)                         Worker (Hono)                     Stripe (connected acct)
────────────────                         ─────────────                     ───────────────────────
Settings ▸ Tap to Pay ▸ Set up ─────────▶ POST /api/terminal/location ───▶ list/create Location
App foreground (flag on) ───────────────▶ POST /api/terminal/connection-token ▶ connection_tokens
  SDK.discover(TapToPay) → connect(locationId, merchantDisplayName)
Invoice ▸ "Tap to Pay on iPhone" ───────▶ POST /api/terminal/payment-intent ─▶ PI {card_present,
  (amount ≤ balance, operationId)          (owns invoice? amount ≤ balance?)      metadata:{invoiceId,
                                                                                   userId, localDate,
  SDK.retrievePaymentIntent(secret)                                                source:'tap_to_pay'}}
  SDK.collectPaymentMethod → confirm ◀──── customer taps card/phone ────────▶ succeeded
  recordCardPresentPayment(stripe_<pi>) ──▶ (normal sync push; union trigger)
                                          webhook payment_intent.succeeded ◀─ event.account
                                          (source=tap_to_pay) → same ledger id, skipped if present
```

### 2.1 Worker routes (all JWT-authed, `appCors`, per-user `createRateLimiter`)

A shared helper `backend-workers/lib/stripe/connectedAccount.js` verifies the JWT, looks up `stripe_accounts` and builds the pinned Stripe client. It replaces the copy-pasted blocks for the new routes only; existing routes are not touched.

| Route | Does | Limits |
|---|---|---|
| `POST /api/terminal/connection-token` | `stripe.terminal.connectionTokens.create({}, {stripeAccount})` and returns `{secret}`. Never cached server-side | 30/min per user |
| `POST /api/terminal/location` | `{action: 'status' \| 'ensure', address?, displayName?}`. Lists Locations on the connected account and picks the one with `metadata.tradeready = 'default'`. `ensure` creates it from an owner-confirmed structured US address (`line1, line2?, city, state, postal_code, country:'US'`) and `display_name` = business name. Returns `{locationId, address}`. Stripe is the authority, so **no table and no migration** | 10/min per user |
| `POST /api/terminal/payment-intent` | `{invoiceId, amount, localDate, operationId}`. See below | 10/min per user |

`payment-intent` runs these steps in order:
1. Fetch the invoice by `id` **and** `user_id` (not deleted). Return 404 if it is missing, or 422 `not_synced` with the payment-link copy ("Open the app while online…").
2. Compute `balanceDue` with `backend-workers/lib/paymentMath.js` (legacy fallback included).
3. Require `0 < amount ≤ balanceDue + 0.005`, else 400 `amount_exceeds_balance` with the balance.
4. Require `localDate` to match `YYYY-MM-DD` and fall within one day of the server's UTC date.
5. Create the PaymentIntent with:
   - `amount` in cents, `currency: 'usd'`, `payment_method_types: ['card_present']`, `capture_method: 'automatic'`
   - `description: 'Invoice <number>'`
   - `metadata: { invoiceId, userId, localDate, source: 'tap_to_pay' }`
   - `{ stripeAccount, idempotencyKey: 'ttp_' + operationId }`
6. Return `{paymentIntentId, clientSecret, amount}`.
- No `application_fee_amount`, matching payment links (decision D7).

### 2.2 Webhook

In `webhook.js`, add a branch before the `checkout.session.completed` filter:
- **`payment_intent.succeeded` with `metadata.source === 'tap_to_pay'` and `metadata.invoiceId`.** It goes through the same `recordStripePayment` core, refactored to take a normalized `{ledgerId, amount, date, extra}`:
  - `ledgerId = 'stripe_' + pi.id`, `amount = pi.amount_received / 100`, `date = metadata.localDate`.
  - The `date` comes from the device's local day, so this path drops the UTC-date limitation.
  - `extra = { stripePaymentIntentId: pi.id, channel: 'card_present' }`.
  - The same ownership check (`event.account`), legacy materialization, zero-amount guard and idempotency short-circuit apply.
- **Every other `payment_intent.*` event is skipped (200).** This is load-bearing: Payment Link checkouts also create PaymentIntents. Booking those would double-count link payments under a second id (`stripe_pi_…` beside `stripe_cs_…`). Tests pin it (§9).
- The refactor keeps the checkout path byte-identical. Its tests are characterization tests written first, because no Worker webhook tests exist today (scoping notes).

### 2.3 `connect-status` (additive)

Also return `charges_enabled` and `card_payments_capability` (`account.capabilities.card_payments`). The existing three keys stay unchanged. The native status gains two optional fields.

## 3. Ledger entry (decision: `method: "stripe"`, not a new method)

```jsonc
// invoices.data.payments[] — identical bytes from the device and the webhook
{ "id": "stripe_pi_3Q…", "amount": 412.5, "date": "2026-10-14", "method": "stripe",
  "stripePaymentIntentId": "pi_3Q…", "channel": "card_present" }
```

**Why not `method: "card_present"`.** The kickoff brief floated it. §0 lists seven readers of `method`:
- The **customer PDF would print the raw string**.
- Profitability would stop flagging Stripe fees.
- Analytics and RN would bucket it as "other".

`stripe` is already "money that arrived through Stripe, reconciled automatically" (`webhook.js:185-188`). That is exactly what a Tap to Pay payment is: Stripe deducts the fees and Stripe pays it out. `channel` carries the in-person distinction additively. RN and older native builds ignore it, and the union trigger and baseline merge preserve it.

**Native changes**
- `NativeCardPresentPayment.ledgerEntry(paymentIntentId:amount:localDate:)` builds the canonical payment with exactly the keys above. It has **no `note` or `voidedAt` nulls**, so the device copy and the webhook copy are byte-identical, and an id collision in the union trigger is a no-op.
- `AppStore.recordCardPresentPayment(invoiceID:entry:)` appends the canonical payment straight onto the canonical invoice (the `commitInvoicePayment` path), bypassing `newCanonicalPayment`, which would drop the extra keys. It returns the same `Result` and emits `paymentRecorded(method: "stripe")`.
- Display fix (also fixes today's "Other" for link payments):
  - `displayPaymentMethod` maps `stripe` to "Card (online)".
  - It maps `stripe` with `channel == "card_present"` to "Tap to Pay". This needs the UI `Payment` to carry `channel`; it gains an optional `channel` populated by the adapter.
  - The PDF label stays "Card" for both.
- Void: for a `stripe` entry, the void confirmation adds "Voiding only changes your records. It doesn't refund the card. Refund it in your Stripe dashboard." This applies to link payments too.

**Convergence cases**
| Order | Result |
|---|---|
| Device push, then webhook | The webhook sees the id and skips (`webhook.js:166`) |
| Webhook, then device push | Union: same id, NEW (device) wins, identical bytes |
| Device crashed after tap, before recording | The webhook records it. The device pulls it on next sync |
| Tap succeeded but the webhook endpoint isn't subscribed yet | The device records it. The ledger is correct, with no server copy until push |
| Customer later also pays the old payment link | Prevented in practice: the cached link amount no longer equals the balance, so the portal and email hide it (`portalAssemble.js:149-160`). Otherwise the existing overpaid warning shows |

## 4. Native design

### 4.1 Capability flag and reader seam (buildable now)

- **`NativeTapToPayCapability.isAvailable`** is true only when all of these hold:
  - the build setting `TradeReadyTapToPayEnabled` is `YES` (Info.plist key; absent means false; no committed configuration sets it);
  - `#if canImport(StripeTerminal)`;
  - the runtime device check (iPhone, OS supported, via the SDK) passes;
  - the owner turned Tap to Pay on in Settings.
- **Protocol `NativeCardReader`:**
  - `prepare(locationId:merchantName:) async throws`
  - `var state: NativeCardReaderState { get }` (unsupported, notConfigured, preparing(progress), ready, busy)
  - `collect(clientSecret:) async throws -> NativeCardCollectResult` (succeeded(piId, amount), declined(reason), canceled, timedOut)
  - `isAccountLinked() async -> Bool?`
- Implementations:
  - `NativeUnavailableCardReader` is the only one compiled into Release before stage B. It always reports `unsupported`.
  - `NativeFakeCardReader` lives in tests and DEBUG previews and is scriptable for every outcome.
  - `NativeStripeTerminalCardReader` sits in `N/NativeStripeTerminalCardReader.swift`, wrapped in `#if canImport(StripeTerminal)`. **It is written in stage B, not before**, so no untestable SDK code lands early.
- Location permission is requested only when the owner turns Tap to Pay on, never at launch. That keeps the prompt away from owners who never use the feature (§10 R4).

### 4.2 Screens

- **Settings ▸ Payments ▸ "Tap to Pay on iPhone"** appears only when the flag is on. It is a setup checklist:
  1. Stripe connected and `charges_enabled`. Otherwise it shows "Complete Stripe setup" (the existing flow).
  2. Business address for card payments: a structured form prefilled from `settings.address`, then `location ensure`.
  3. Location access: the system prompt, with a pre-prompt explaining why ("Card payments need your location to protect against fraud").
  4. Accept Apple's Tap to Pay terms: SDK connect, shown only to the owner (always the admin in a solo app). Status comes from `isAccountLinked`, never stored locally.
  5. "How to tap" education: `ProximityReaderDiscovery` (iOS 18+), always reachable afterwards from this page.
  6. A configuration progress indicator while `preparing`.
- **Invoice detail**: when the flag is on and the invoice is unpaid, a "Tap to Pay on iPhone" button (`wave.3.right.circle` symbol) sits at the top of the Payments section. It is never hidden behind scrolling, per Apple's checklist.
  - The sheet takes an amount (default: the balance; editable down for a deposit or partial payment) and confirms.
  - It then shows: "Preparing…" (the PI is created), then the system tap UI, then **Approved / Declined / Timed out** with retry.
  - On approval: record the payment (§3) and offer "Send receipt", which shares the updated invoice PDF (paid-to-date shown) through the existing share/email composer. No new service is involved.
- `operationId` is minted once per sheet. A retry after a network error reuses it, so Stripe's idempotency returns the same PaymentIntent.

### 4.3 Lifecycle

- The reader is prepared on foreground only when the flag is on and setup is complete. It disconnects on background, as the SDK does.
- A missed `prepare` never blocks the invoice screen. The button shows "Getting ready…" with progress instead of disabling.

## 5. Reconciliation and money surfaces

- Cash-basis reports, tax set-aside, the CSV export and the accountant package need no change: the entry is a normal non-voided `stripe` payment.
- Profitability keeps `feesUnknown`. That is correct, since the fees are real and not in the ledger.
- The accountant package `Source` is `stripe` by id prefix. A `Channel` column is an optional additive follow-up (decision D6).
- The Phase 23 API exposes it as `method: stripe` with `processorReference = pi id`. Adding `channel` there is additive.
- **Phase 28 tips** on Tap to Pay are out of scope. If added, the tip goes in a separate field, never in `amount` (scoping notes).

## 6. Security and abuse

- No raw card data ever touches TradeReady. The SDK and Apple handle the card, so PCI scope stays with Stripe and Apple.
- Connection tokens are short-lived and scoped to the owner's own connected account. The route is JWT-authed and rate-limited. Tokens are never logged or stored.
- PaymentIntent creation validates invoice ownership and the balance on the server. A modified client cannot charge against another owner's invoice or attach metadata naming one.
- The webhook's `event.account` check stays, so a PI on account A can never settle owner B's invoice even with forged metadata.

## 7. Legal, privacy and store items (all owner approval, §12)

- **Info.plist:**
  - `NSLocationWhenInUseUsageDescription`. Proposed text: "TradeReady uses your location when you take a card payment with Tap to Pay on iPhone, as required by the payment processor for fraud prevention."
  - `NSBluetoothAlwaysUsageDescription`. Proposed text: "TradeReady's card-payment component includes Bluetooth support for card readers. TradeReady doesn't use Bluetooth for Tap to Pay on iPhone."
  - Exact wording to be approved.
- **Privacy label and manifest:** declare location, payment info, and the data the Stripe SDK collects, per the SDK's privacy manifest and [Stripe's mobile SDK privacy details](https://support.stripe.com/questions/stripe-mobile-sdk-privacy-details). This is reconciled at stage B against the manifest actually bundled.
- **Privacy policy §4 "Stripe" bullet:** add in-person payments, and that location and device data go to Stripe and Apple when the owner takes a Tap to Pay payment.
- **Terms §4 "Payment Processing":** add Tap to Pay, the owner's acceptance of Apple's terms, and that refunds and disputes are handled in Stripe.
- **Naming:** always "Tap to Pay on iPhone" (or "Tap to Pay" when space is short). Never "Apple Tap to Pay", and no Apple logo ([marketing guidelines](https://developer.apple.com/tap-to-pay/marketing-guidelines/)). Store listing claims only after device smoke (roadmap claims discipline).

## 8. Stages: what is buildable now and what is not

| Stage | Contents | Needs approval? |
|---|---|---|
| **A — now** | Worker: `connection-token`, `location`, `payment-intent` routes; the webhook `payment_intent.succeeded` branch plus characterization tests for the checkout path; `connect-status` additive fields. Native: `NativeCardPresentPayment` (eligibility, amount rules, ledger entry, display mapping, the "Other" display fix), `recordCardPresentPayment`, the `NativeCardReader` protocol with the unavailable and fake readers, `NativeTapToPayCapability`, the Settings setup checklist and invoice sheet driven by the fake reader in previews and tests, all hidden while the flag is off, plus the void copy. All tests | **No.** Nothing calls the new routes until the flag ships. The routes are dark even if deployed, and deploying them is still the owner's call |
| **B — SDK** | Add `stripe-terminal-ios-spm` pinned to `5.8.x`. Write `NativeStripeTerminalCardReader`. Add the two Info.plist strings and the privacy manifest and label reconciliation. Simulated reader (`setSimulated(true)`) in DEBUG builds | **Q2** (dependency), **Q4** (permission strings), **Q5** (privacy label) |
| **C — dev entitlement** | Entitlement in `TradeReadyNative.entitlements` (Debug first) and the App ID capability. Real device test mode: physical test cards, PIN amounts ending in .03, Apple terms linking, education, the full checklist, the three screen recordings | **Q1** (account type and request), **Q3** (webhook subscription) |
| **D — distribution** | Reply to Apple with the recordings and get the distribution entitlement. Then TestFlight, App Review and turning the flag on in Release | **Q1**, **Q6** (legal wording), **Q7** (launch email, splash, push) |
| E — follow-ups | In-app refund (`POST /api/terminal/refund`, which moves money), a `Channel` column in exports, tips | Separate approval |

**Cannot be built before approval:** anything that imports `StripeTerminal`, the entitlement file change, the Info.plist keys, ProximityReader education on a real device, a real or simulated tap, the Dashboard webhook subscription, and anything Apple must review.

## 9. Testing

- **Worker** (`backend-workers/tests/terminal.test.cjs` with a stubbed Stripe client, plus root Jest `__tests__/stripeWebhookWorkers.test.js` under `TZ=America/Phoenix`):
  - Connection token on the right `stripeAccount`, 401 without a JWT, 422 with no connected account.
  - Location: list-pick by metadata, create-once, address validation.
  - PaymentIntent: ownership (another owner's invoice gives 404), amount ≤ balance including the legacy fallback, a zero or negative amount, idempotency key from `operationId`, `localDate` window, exact metadata, `card_present`.
  - Webhook:
    - Characterization of the existing checkout path first, byte-for-byte.
    - A `tap_to_pay` PI is recorded once with the exact entry shape.
    - **A PI without `source=tap_to_pay` (a payment-link PI) is skipped.**
    - An `event.account` mismatch is skipped. A redelivery or a device-first write is a no-op. A zero `amount_received` is skipped.
- **Native** (`run-tap-to-pay-tests.sh`, registered):
  - Eligibility matrix: flag, connect status, `charges_enabled`, a paid invoice, amount limits.
  - The ledger entry has exact keys, and both copies are byte-identical (shared fixture with the Worker test).
  - `recordCardPresentPayment` keeps `channel` and `stripePaymentIntentId` through an edit round-trip (adapter baseline merge).
  - Display labels ("Tap to Pay", "Card (online)", PDF "Card").
  - Sheet state machine with `NativeFakeCardReader`: approved, declined, canceled, timed out, a retry that reuses `operationId`, a network failure before collect.
  - Fees warning unchanged. Cash-basis and accountant-package totals include the entry.
- **Stage B/C** (manual, recorded): simulated reader, then device test mode with physical test cards, then Apple's three recordings.
- **Gates:** `sh native/run-all-domain-tests.sh`, the Release compile (with and without the flag), `cd backend-workers && npm test`, the targeted Jest under `TZ=America/Phoenix`, and `sh native/run-doc-reference-check.sh`.

## 10. Risks

| # | Risk | Likelihood / impact | Mitigation |
|---|---|---|---|
| R1 | The developer account is Individual, so it can't request the entitlement. Converting to an organization needs a legal entity and a D-U-N-S number | Unknown / blocks the phase | Confirm first (Q1). Stage A is still useful (the ledger display fix, server-validated PaymentIntents) |
| R2 | Apple rejects or delays the distribution entitlement | Medium / delays launch | Follow the checklist exactly, record the flows early, keep the flag off |
| R3 | Stripe steers legacy Express platforms away from direct charges (and toward Accounts v2) | Medium / platform drift affects payment links too | Same model as today, so there is no new divergence. A charge-model or accounts migration is a separate platform decision (§11) |
| R4 | The location prompt and privacy-label change worry users. Users who deny it can't take payments | Medium / adoption | Prompt only on opt-in, with a pre-prompt explaining why. All other features never ask |
| R5 | OS rule (iOS released within the last year) and iPhone XS+ exclude some owners | Medium / reach | Runtime check with a clear "needs iOS N" message. Payment links remain |
| R6 | SDK size (~30 MB zip, real impact unknown) and yearly SDK upgrades as Stripe retires versions | High / maintenance | Pin a minor version and add an upgrade item to `docs/ops-monthly-checklist.md` |
| R7 | Webhook double-counts payment-link PaymentIntents | Low / money reports wrong | `metadata.source` filter plus a test |
| R8 | Union trigger not applied, so the webhook read-modify-write races a device push | Unknown / lost ledger entry | **Verify `20260718_invoice_payment_merge.sql` is applied before subscribing the webhook to `payment_intent.succeeded`** (Q3 precondition), using its verify script |
| R9 | The owner voids a Tap to Pay payment expecting a refund | Medium / customer complaint | Void copy (§3). In-app refund is stage E |
| R10 | Fees: $0.10 per authorization on top of 2.7% + 5¢, billed to the connected account | Certain / owner cost | Shown in setup ("Stripe's in-person rates apply"). Rates are not hard-coded in UI copy |
| R11 | First `prepare` takes minutes on site | Medium / awkward first use | Setup flow prepares once at home. Progress UI. Pre-warm on foreground |
| R12 | Card disputes and chargebacks on in-person payments | Low / owner handles in Stripe | Out of app scope; terms wording (Q6) |
| R13 | Apple's checklist requires a launch email, splash screen and push notification for public apps | Certain / marketing work | Owner decision (Q7). These are content, not engineering, and land in stage D |

## 11. Accepted residuals

- No in-app refunds in v1. Refunds happen in the Stripe dashboard.
- No offline Tap to Pay (private preview).
- No tips on Tap to Pay.
- No `channel` in exports yet.
- The pre-existing payment-link gaps stay as they are: no ownership or balance check, and a link can be paid twice (scoping notes). The new PaymentIntent route does **not** share them. Fixing links belongs with Phase 24.
- The `clientIp` XFF spoofability (Phase 23 spec §0) doesn't touch these routes, which key their limits on the user id.
- The charge model (direct charges on legacy Express) is inherited, not re-decided (R3).

## 12. Decisions

**Decided (recommendations; owner may override)**
| # | Decision | Choice |
|---|---|---|
| D1 | Provider | Stripe Terminal Tap to Pay on iPhone, on the existing Connect accounts. No hardware readers in v1 |
| D2 | Charge type | Direct charge on the connected account (payment-link parity) |
| D3 | PaymentIntent creation | Server-side, with ownership and balance checks, `card_present`, automatic capture, idempotent on `operationId` |
| D4 | Ledger | `id: stripe_<pi>`, `method: "stripe"`, plus `stripePaymentIntentId` and `channel: "card_present"`. Device and webhook write identical bytes |
| D5 | Payment date | Device local day, carried in PI metadata for the webhook copy |
| D6 | Display | "Tap to Pay" in the app, "Card" on the PDF, and fixing `stripe` → "Card (online)" (today it shows "Other") |
| D7 | Platform fee | None (`application_fee_amount` unset), same as links |
| D8 | Terminal Location | One per connected account, found by metadata, created from an owner-confirmed address. No table |
| D9 | Receipt | Share the updated invoice PDF via the existing composer. No new email service |
| D10 | Partial payments | Allowed (amount ≤ balance), so deposits work in person |
| D11 | Location prompt | Only after the owner opts in on the Tap to Pay setup page |

**NEEDS OWNER APPROVAL**
| # | Item | Question | Recommendation |
|---|---|---|---|
| Q1 | Apple entitlement | Is the Apple Developer account (team `96J48TJWX3`) an **Organization**, and will you, as Account Holder, request the Tap to Pay development entitlement now (1–2 business days), so it is ready when stage B starts? | **Yes, request it now** if the account is an Organization. Lead time is the critical path. If it's Individual, decide on converting before anything else |
| Q2 | New dependency | Add Stripe Terminal iOS SDK `5.8.x` (SPM, `stripe-terminal-ios-spm`, about 30 MB zip, iOS 15+) as the fifth package? | **Yes, at stage B,** pinned to a minor version with a yearly upgrade item |
| Q3 | Stripe Dashboard | Add `payment_intent.succeeded` to the existing Connect webhook endpoint's events, accept Stripe's Apple acceptance platform terms if the Dashboard asks, and confirm the union trigger is applied first? | **Yes, at stage C,** after running `supabase/migrations/verify/20260718_invoice_payment_merge_verify.sql` |
| Q4 | Info.plist permission strings | Approve the location and Bluetooth usage strings in §7 (the first location permission the app has ever asked for)? | **Yes**, with the opt-in-only prompt (D11) |
| Q5 | Privacy label and manifest | Update the App Store privacy label (location, payment info, and SDK-collected device data) to match the Stripe SDK's bundled manifest? | **Yes, at stage B,** reconciled against the actual manifest. The label goes live with the release that enables the flag |
| Q6 | Terms and privacy wording | Approve additions to `terms.html` §4 and `privacy.html` §4 (in-person payments, Apple terms, location and device data to Stripe and Apple, refunds and disputes in Stripe)? | **Yes**, published with stage D |
| Q7 | Apple's public-app marketing requirements | Will you send a launch email, show a launch splash and send a push announcing Tap to Pay, as Stripe's guide says Apple requires for public apps? | **Yes, minimal versions.** A What's-new splash and push already fit existing patterns. The email needs a list you have consent to email, so confirm that first |
| Q8 | Charge model (inherited) | Accept direct charges on legacy Express for now, given Stripe's caution, and leave an Accounts v2 or destination-charge migration as a separate platform decision? | **Yes.** Don't fork Tap to Pay from links. Revisit with Phase 24, which touches the same surface |
