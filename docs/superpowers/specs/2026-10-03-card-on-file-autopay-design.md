# Card on File & Autopay for Recurring Invoices (Roadmap Phase 24) — Design Spec

**Date:** 2026-10-03
**Status:** SCOPED. Builds on `feat/autopay`, stacked on the build-order branches before it (`feat/quote-options` → `feat/lead-source` → `feat/quote-expiration` → `feat/job-forms` → `feat/properties-equipment` → `feat/referrals`). Phase 28 (tips, `2026-10-03-tips-design.md`) stacks on top as `feat/tips`. In `CZilla57/tradeready-legal` the page work goes on a `feat/autopay` branch stacked on that repo's in-flight branches. Owner go-ahead 2026-10-03: "continue working until all features on the roadmap are properly completed … implemented in the most beneficial way to the user". The code map was verified 2026-10-03 against the main checkout on `feat/quote-expiration` (HEAD `e922d51` plus another agent's uncommitted Phase 32 work). Line numbers in files that agent is editing (`AppStore.swift`, `SettingsView.swift`, `portalAssemble.js`, `src/index.js`) will drift.
**Origin:** `docs/post-launch-feature-roadmap.md` Phase 24, build order #7 ("None (existing Stripe)"). The roadmap bundles it with Phase 28.
**Builds on:**
- the deposits and payment-ledger design (`2026-07-18-deposits-partial-payments-design.md`) and the server-side ledger merge (`2026-07-18-server-side-ledger-merge-design.md`)
- recurring invoices (`2026-07-31-recurring-invoices-design.md`) and auto-email invoices (`2026-08-06-auto-email-invoice-design.md`)
- portal completion (`2026-08-07-portal-completion-design.md`)
- the facts in `2026-10-02-phase-24-28-scoping-notes.md`, re-verified in §0

**Build target:** the native SwiftUI app, the Worker, and pages in `tradeready-legal`. **No React Native changes.** The dormant Vercel twin (`backend/`) is not changed.

## 0. Preconditions verified against the repo

`N/` means `native/TradeReadyNative/`. `W/` means `backend-workers/`.

### 0.1 Payment links today

- **Each mint creates a Payment Link on the connected account.** `W/src/routes/createPaymentLink.js` creates a Product, a Price and a Payment Link per call (`:97-121`), using the `stripeAccount` header (`:95`). These are direct charges with no application fee.
  - The body is `{amount, invoiceNumber, description, invoiceId}` (`:84`). The only check is `amount > 0` (`:85`). There is no ownership check and no balance check.
  - Links are never deactivated (`:123-129`) and carry no `restrictions`. **One link can be paid any number of times**: every completed session appends a new `stripe_<session id>` entry (webhook `:150`, `:166`).
- **Version pins.** `apiVersion: '2023-10-16'` is set at `createPaymentLink.js:91`, `stripe/webhook.js:54`, `stripe/createConnectAccount.js:38` and `stripe/connectStatus.js:49`.
  - `stripe` is `16.12.0` (`W/package.json`). Its types target `2024-06-20` (`node_modules/stripe/types/lib.d.ts:30`).
  - Webhook payloads use the Dashboard endpoint's version, not the code's.
- **Device storage.** The device stores `paymentLinkUrl` and `paymentLinkAmount` on the invoice:
  - auto-delivery: `N/AppStore.swift:2069-2070`, `:2086-2087`
  - the persist helper: `:2117-2123`
  - manual generation: `:2393-2394`
- **Link gates.** A link is shown only when it is unpaid, on an allowlisted https host, and `|paymentLinkAmount − balanceDue| ≤ 0.005`:
  - allowlist: `W/lib/reminderEmail.js:16-36`
  - portal: `W/lib/estimate/portalAssemble.js:155-160`
  - invoice email: `W/lib/invoiceEmail.js:43-50`
- **Confirmed native bug: Stripe deposit links always fail.** `generateInvoicePaymentLink` (`N/AppStore.swift:2347-2397`) mints the link (`:2383`), then throws `.invalidAmount` unless the requested amount equals the latest balance (`:2387-2391`).
  - A deposit ask is strictly below the balance by construction (`N/Domain/NativeInvoicePaymentLinks.swift:61-66`).
  - So every Stripe deposit leaves an orphaned Product/Price/Payment Link on the owner's Stripe account, and the composer shows "Could not generate a payment link" (`N/NativeInvoiceOutreachView.swift:313-337`).
  - The RN twin has no such check (`utils/invoiceHelpers.ts:156-166`, `:195-240`).
  - The host test only exercises PayPal (`native/StoreIntegrationTests/main.swift:1036-1048`).
  - The comment's intent was "a concurrent payment must not leave a stale-amount link". The right check compares the balance before and after the await.
- **Response decoding.** The native decoder reads only `{url}`, so extra response keys are safe. It rejects URLs that have a fragment (`N/NativeInvoiceDelivery.swift:17-18`, `:27-36`, `:51`).

### 0.2 Webhook and ledger

- **One Connect endpoint.** `W/src/routes/stripe/webhook.js` verifies with `constructEventAsync` (`:57-63`).
  - It handles only `checkout.session.completed` (`:70-72`) with `payment_status === 'paid'` (`:77-79`) and `metadata.invoiceId` (`:81-85`).
  - `event.account` must equal the owner's `stripe_accounts` row (`W/lib/stripe/webhookOwnership.js:28-51`). Mismatches get a 200 skip.
- **`recordStripePayment` (`webhook.js:102-236`):**
  - fetches the invoice by id (`:108-123`)
  - materializes the legacy ledger (`:161`)
  - dedupes on `stripe_<session.id>` (`:150`, `:166`)
  - books `amount_total/100` (gross, `:172`) dated UTC today (`:192`) with `method: 'stripe'`
  - recomputes `paid`/`paidAt` as a cache (`:204-210`)
  - upserts with `merge-duplicates` (`:217-231`)
  - It never reads line items.
- **The union trigger.** `supabase/migrations/20260718_invoice_payment_merge.sql` unions only `payments`, by id (`:75-134`).
  - On a live/live collision the incoming (NEW) row wins **as a whole JSON object** (`:112-116`). So any extra key on a payment entry rides the trigger unchanged.
  - **Its applied status is contradictory.** The roadmap ship table says "migration + backend live" (`docs/post-launch-feature-roadmap.md:51`). `webhook.js:7-14`, `W/lib/paymentMath.js:15-20` and `docs/deposits-resume-here.md:11,42,58` say it is not applied.
  - Every server-side ledger append in this spec depends on it, so this is a ship precondition (§9).
- **No Worker tests cover `createPaymentLink` or the webhook.** `__tests__/stripeWebhookOwnership.test.js` tests the legacy `backend/` handler only.
- **Payment reconciliation contract.** The cutover charter's TH-9 check (`docs/native-phase-12-cutover-charter.md:143`) pins "exactly one `stripe_<session id>` entry per completed session".
- **Native preserves unknown payment keys.**
  - `Canonical.Payment` keeps unknown keys (`N/Domain/CanonicalModels.swift:1154-1173`). `stripeSessionId` is typed.
  - UI edits merge from the baseline JSON, so untouched keys survive (`N/Domain/UIModelAdapters.swift:896-907`, `:1213-1223`).
  - Pull merge keeps whole `Canonical.Payment` values (`N/NativeInitialSync.swift:616-641`).

### 0.3 Connect, recurring invoices and the */15 sweep

- **Connect accounts.** Accounts are Express with `card_payments` + `transfers` (`createConnectAccount.js:45-51`).
  - `stripe_accounts` is `{user_id PK, stripe_account_id, created_at}` with owner-read RLS (`supabase/migrations/20260705_stripe_accounts.sql:5-17`).
  - `connectStatus` doesn't read `charges_enabled` (`connectStatus.js:54-61`).
  - `disconnect` deletes only the row (`disconnect.js:32-48`).
- **Recurring invoices are a synced blob.**
  - `Canonical.RecurringInvoice` lives in the `recurringInvoices` table (`id text` PK, `data jsonb`; `supabase/migrations/20260803_local_collections_sync.sql:35-50`).
  - Fields: `customerId`, `amount`, `dueDays`, `cadence`, `isActive` and the per-rule `autoSendEnabled` (`CanonicalModels.swift:1518-1551`).
  - The master switch is `Settings.autoSendRecurringInvoicesEnabled` (`:1648`).
- **Generation is device-only.**
  - `NativeRecurringInvoices.generate` (`N/Domain/NativeRecurringInvoices.swift:49-146`) is called from `AppStore.runRecurringInvoiceGeneration` (`N/AppStore.swift:4370-4428`).
  - A generated invoice copies `rule.amount`, `recurringInvoiceId` and `occurrenceNumber`. Its `due` is the occurrence date plus `dueDays`.
  - Only the newest occurrence per run is stamped for auto-email (`:127-137`).
- **Sending is the Worker `*/15` cron.**
  - `scheduled()` (`W/src/index.js:117-131`) runs `runInvoiceEmails` (`W/lib/sendInvoiceEmails.js:54-205`).
  - It uses the claim-row pattern on `auto_invoice_email_log` (insert-first, `on_conflict`, `ignore-duplicates`; `:150-167`) with a cap of 25 per user per day (`:22`).
  - The selector gates recurring invoices on `autoSendRecurringInvoicesEnabled` (`W/lib/selectInvoicesToAutoEmail.js:29-39`).
- **Reminder rules can be 0 days past due** (`W/lib/selectInvoicesToRemind.js:51-58`). The daily reminder trigger fires at 15:00 UTC (`W/wrangler.toml` `[triggers]`).
- **Owner alerts already exist.** Booking alerts send an email to the auth email via the admin API and an Expo push to `settings.pushToken` (`W/lib/booking/notifyOwner.js:62-110`). Both are fire-and-forget.
- **The plan editor.** Its "Delivery" section is at `N/NativeRecurringInvoicesView.swift:251-259`.

### 0.4 Public pages and legal

- **portal.html.**
  - It calls `https://tradeready-backend.tradeready.workers.dev/api/estimate` (`:185`).
  - The `invoiceCard` Pay button links to `paymentLinkUrl` (`:301-317`, `:308`). `render()` is at `:418-445`.
  - The portal view whitelist is pinned by `__tests__/portalAssembleWorkers.test.js:87` (top-level keys) and `:111` (invoice keys).
- **The CSP blocks Stripe.js and frames** (`tradeready-legal/_headers:10-11`): `default-src 'self'`, `script-src` without `js.stripe.com`, `Permissions-Policy: payment=()`, `form-action 'self'`.
  - Embedding Stripe Elements would need a CSP change.
  - A top-level navigation to Stripe-hosted Checkout needs none.
- **Browser CORS.** The allowlist for browser calls already includes `https://gettradereadyapp.com` (`W/lib/estimate/cors.js:28-33`).
- **terms.html.** §4 says TradeReady "does not process payments, hold funds, or act as a payment intermediary" (`:121-122`). §8 is the e-consent record precedent (`:141-142`).
- **privacy.html.**
  - §1 lists collected data, with end-customer approval records at `:114`.
  - §4 Stripe is at `:132`.
  - The deletion copy is at `:151`.
- **PrivacyInfo.xcprivacy.** `N/PrivacyInfo.xcprivacy` declares OtherFinancialInfo and PurchaseHistory, both for Analytics only (`:87-110`). It declares no Payment Info.

### 0.5 Stripe behavior checked (pinned `2023-10-16`, SDK `16.12.0`)

Stripe's reference pages render the latest API version. Pinned-version safety was checked three ways:
- The breaking-change lists for every release from the pin to the SDK's version: [2023-10-16](https://docs.stripe.com/changelog/2023-10-16), [2024-04-10](https://docs.stripe.com/changelog/2024-04-10), [2024-06-20](https://docs.stripe.com/changelog/2024-06-20).
  - The only Payments breaking change is the default `capture_method` becoming `automatic_async` in 2024-04-10. Nothing here sets or depends on it.
- Stripe's policy that new optional request parameters are backward-compatible ([upgrades](https://docs.stripe.com/upgrades)).
- The SDK 16.12.0 type definitions.

The test-mode smoke in §8 is the final proof.

| Behavior relied on | Verified | Source |
|---|---|---|
| Checkout Sessions on a connected account via the `Stripe-Account` header; branding from the connected account; `checkout.session.completed` arrives on the Connect endpoint | Yes | [Direct charges](https://docs.stripe.com/connect/direct-charges?platform=web&ui=stripe-hosted), [Connect authentication](https://docs.stripe.com/connect/authentication) |
| Customers and PaymentMethods can be created on the connected account (same header) | Yes | [Connect authentication](https://docs.stripe.com/connect/authentication) (the `/v1/customers` example uses the header) |
| A Checkout Session `expires_at` is between 30 minutes and 24 hours; its `url` carries a `#fid…` fragment | Yes | [Create a Checkout Session](https://docs.stripe.com/api/checkout/sessions/create) |
| `payment_intent_data.setup_future_usage: 'off_session'` with a `customer` attaches the PM, and Checkout shows a notice that details will be saved for future payments | Yes | Same page; [Save during payment](https://docs.stripe.com/payments/checkout/save-during-payment?payment-ui=stripe-hosted) |
| `saved_payment_method_options.payment_method_save` is for **prefill / redisplay**, not off-session charging; `setup_future_usage` saves with `allow_redisplay: limited` | Yes | [Save during payment](https://docs.stripe.com/payments/checkout/save-during-payment?payment-ui=stripe-hosted) |
| Setup-mode Checkout saves a card without a payment | Yes | Same pages (`mode: setup`; `currency` is only required when `payment_method_types` is unset) |
| `custom_text.submit` / `after_submit` up to 1,200 chars with Markdown links; the default reuse-agreement text can stay | Yes | [Custom components](https://docs.stripe.com/payments/checkout/custom-components?platform=web&payment-ui=stripe-hosted) |
| Off-session charge: `off_session: true` only with `confirm: true` on create (or on `/confirm`). A failure returns 402 with the PI in `requires_payment_method`; `authentication_required` means the customer must come back on-session | Yes | [Create PI](https://docs.stripe.com/api/payment_intents/create?query=off_session), [Confirm PI](https://docs.stripe.com/api/payment_intents/confirm?query=off_session), [Save and reuse](https://docs.stripe.com/payments/save-and-reuse?payment-ui=elements) |
| Compliance for off-session use: explicit opt-in, the agreement, timing and frequency, how the amount is set, cancellation, and a kept record | Yes | [Save and reuse → Compliance](https://docs.stripe.com/payments/save-and-reuse?payment-ui=elements) |
| Idempotency keys replay the first result, **including errors**. Keys may be pruned after 24 h. Differing parameters error | Yes | [Idempotent requests](https://docs.stripe.com/api/idempotent_requests) |
| `checkout.sessions.list` filters by `status` and `created`; `expire` works on `open` sessions only | Yes | [List](https://docs.stripe.com/api/checkout/sessions/list), [Expire](https://docs.stripe.com/api/checkout/sessions/expire) |
| Payment Links: `restrictions.completed_sessions.limit`, `active`, `inactive_message` on update. **No `customer` parameter** on create, so a link can't bind a saved card to a known Customer | Yes | [Update payment link](https://docs.stripe.com/api/payment-link/update?query=restrictions); SDK `PaymentLinkCreateParams` |
| Test cards for off-session SCA and declines (`4000002500003155`, `4000002760003184`, `4000003800000446`, `4000000000009995`, `4000000000000069`, `4000000000000341`) | Yes | [Testing](https://docs.stripe.com/testing) |

**Version verdict:** no API version bump and no SDK bump. Every call used is in SDK 16.12.0's types. Customers, PaymentIntents (`off_session`, `confirm`), Checkout Sessions (`customer`, `setup_future_usage`, `custom_text`, `expires_at`, `mode: setup`, `list`/`expire`) and Payment Link `restrictions`/`inactive_message` are long-standing or additive. **No new webhook event type** is needed (§4.5).

### 0.6 Corrections to the scoping notes

- **The deposit-link bug is confirmed**, with exact lines in §0.1.
- **Line drift:**
  - `deliverNativeInvoice` is now at `AppStore.swift:2049-2107`.
  - `runRecurringInvoiceGeneration` is now at `:4370`.
  - `buildInvoices` is at `portalAssemble.js:144-178`.
  - `invoiceCard` is at `portal.html:301-317`.
- **New finding: Payment Links can't take `customer`.** So "save the card on the existing link" can't attach the card to a Customer we already know. And `custom_unit_amount` must be the only line item ([pay what you want](https://docs.stripe.com/payments/checkout/pay-what-you-want?payment-ui=stripe-hosted)). Both push the design toward per-visit Checkout Sessions (§1).
- **New finding: a Checkout Session URL can't be the stored invoice link.** It expires in ≤ 24 h and has a fragment that the native decoder rejects.

## 1. Recommendation: a TradeReady pay page that creates a Checkout Session per visit

Every Stripe invoice link becomes `https://gettradereadyapp.com/pay.html?t=<signed token>`. The page shows the invoice, offers the per-visit choices, then calls the Worker. The Worker creates a Checkout Session **at that moment**, from the live ledger balance, and redirects the customer to Stripe-hosted Checkout:
- this phase adds "save this card for automatic payments"
- Phase 28 adds a tip

This one change carries Phase 24, Phase 28, and both link defects:

- **Consent** happens on a page we control. It has an explicit unchecked opt-in, exact authorization text, and a server-side record (text, version, time, IP, user agent), following the estimate e-consent precedent.
- **The saved card lands on a known Customer.** The Worker creates or reuses one Stripe Customer per (owner, TradeReady customer) on the connected account and passes it to the session. That is impossible with Payment Links (§0.6).
- **Double payment is closed.** The amount comes from the live balance at click time, a paid invoice shows "Paid", and at most one Checkout Session per invoice is open at a time (§4.4).
- **No ownership or balance trust in the client.** The token binds owner and invoice, the page looks the invoice up under that owner, and it charges `min(requested, live balance)`.
- **No Stripe clutter.** Minting a link is now an HMAC. No Product, Price or Payment Link is created until a customer actually pays.
- **No CSP change and no PCI scope change.** Card entry stays on Stripe's hosted page (a redirect, not an iframe).

**Options considered**

| Option | Consent / known Customer | Tips (Phase 28) | Double-pay | Verdict |
|---|---|---|---|---|
| **A. Pay page + per-visit Checkout Session (chosen)** | Our opt-in + record; `customer` param | Second inline line item | Live balance, one open session | Chosen |
| B. Keep Payment Links; mint a second "pay and set up autopay" link with `setup_future_usage` + `customer_creation` | Stripe's notice only; creates a new Customer per payment; no way to record which plan it covers | Not possible (custom amount must be the sole item) | `restrictions.completed_sessions.limit = 1` | Rejected: no plan-scoped consent, no tips |
| C. Stripe Elements embedded in `portal.html` | Full control | Possible | Possible | Rejected: CSP and `Permissions-Policy` changes, Stripe.js dependency, larger PCI surface |
| D. Store Checkout Session URLs on the invoice | n/a | n/a | n/a | Impossible: ≤ 24 h expiry and a fragment |

**Autopay in one paragraph.** The owner switches on "Offer autopay" on a maintenance plan. When the customer next pays an invoice from that plan (or uses "Set up automatic payments" in the portal), they can tick a box that authorizes charging future invoices on that plan. The Worker's existing `*/15` sweep then charges each later invoice off-session **on its due date**, up to the authorized amount. A success lands in the ledger through the same function as a link payment and the customer gets a receipt. A failure gets no automatic retry: the customer is emailed a normal pay link and the owner is alerted.

## 2. Customer flows

### 2.1 Pay an invoice (all Stripe invoices)

1. The customer opens `pay.html?t=…`. The page calls `GET /api/pay/view?t=…` and shows the business name, invoice number and description, amount due (or "Deposit requested: $X") and due date.
2. When autopay is offered for this invoice (§2.2), an **unchecked** box and its authorization text appear above the button.
3. **Pay $X** → `POST /api/pay/checkout` → `{url}` → `location.assign(url)`. This is a top-level navigation, not a form post, so `form-action 'self'` doesn't apply.
4. Stripe Checkout. The success URL is `pay.html?t=…&session_id={CHECKOUT_SESSION_ID}`, and the page shows a confirmation from `view` (§4.4). The cancel URL is `pay.html?t=…`.
5. **Other states** (complete copy, no dead ends):
   - Paid: "Paid on <date>. Thank you."
   - Not yet synced: "This invoice isn't ready yet. Please try again in a few minutes."
   - Deleted or not found: "This link is no longer valid. Contact <Business>."
   - Owner disconnected from Stripe: "Online payment isn't available. Contact <Business>."

### 2.2 When autopay is offered

The checkbox appears only when all of these hold:
- the invoice has `recurringInvoiceId`
- the plan row exists, is not deleted, is active, and has `autopayEnabled === true`
- the plan's `customerId` is set
- this is a **full-balance** payment, not a deposit
- the plan has no active enrollment, **or** the active enrollment's ceiling is below the plan's current amount. In that case the text reads "Update automatic payments to $NEW", and completing it replaces the old enrollment.

### 2.3 Authorization text (needs owner approval: Q4)

The text is rendered by the Worker (`W/lib/autopay/consentText.js`, version `autopay-consent-v1`). The page shows it verbatim. On submit, the server re-renders it and stores exactly what was shown.

> **Pay future invoices for this plan automatically with this card**
> I authorize {Business} to save this card and charge it automatically, without asking me each time, for invoices under my "{plan description}" plan ({$amount} {every month}). Each charge is made on the invoice's due date, including any unpaid invoice under this plan that comes due after today, and is never more than {$amount} unless I approve a new amount. I'll get an email receipt for every charge. I can turn off automatic payments at any time using the link in any receipt, from my customer portal, or by contacting {Business}. Turning it off stops future charges. My card details are stored by Stripe, {Business}'s payment processor; {Business} sees only the card brand, last four digits and expiry date.

- **Cadence phrases:** "every day / week / month / 3 months / year" from `daily | weekly | monthly | quarterly | annually`.
- **On Stripe Checkout:** Stripe's default reuse-agreement notice stays (we don't hide it). `custom_text.submit.message` repeats the key terms in ≤ 1,200 chars with a Markdown link to the manage page: "By paying, you also authorize {Business} to charge this card for future {plan} invoices on their due dates (up to {$amount} each) until you turn automatic payments off. [Manage automatic payments]({manage URL})".

This covers each item in Stripe's off-session checklist (§0.5): the agreement, timing and frequency, how the amount is set, and cancellation. The record is kept (§3.1).

### 2.4 Set up without paying (portal)

The portal shows an "Automatic payments" card for each of the customer's plans that offer autopay (§4.9).
- **"Set up automatic payments"** opens `pay.html?s=<setup token>`. The page shows the plan summary, the same authorization text with a **required** checkbox, and "Continue to secure card entry".
- That opens a setup-mode Checkout Session with the same `custom_text`. Any unpaid plan invoice due after today is then charged on its due date, as the text says.

### 2.5 Turn off or change the card

- **Where:** the manage link `pay.html?m=<manage token>` appears in every autopay email and on the portal card. It shows "Automatic payments are on for {plan} with Visa ending 4242 (exp 08/27)".
- **Turn off automatic payments** → confirm → `POST /api/pay/autopay-off`:
  - the enrollment becomes `revoked` (by `customer`)
  - the PM is detached on Stripe
  - the customer gets a confirmation email
  - the owner gets an email + push alert
- **Use a different card** runs the setup flow, which replaces the enrollment.
- **Contacting the business** works too, because the owner can remove the card in-app (§6.3).

## 3. Data model

### 3.1 Migration `supabase/migrations/20261003_autopay.sql` (needs owner approval: Q1)

These are server-owned tables. Only the Worker writes them (service role). RLS is enabled with **owner-read** policies only, following `20260806_auto_invoice_email_log.sql`. A verify script `supabase/migrations/verify/20261003_autopay_verify.sql` follows the `20260718` verify-script pattern (psql with `ON_ERROR_STOP=1`, seeded rows rolled back).

```sql
create table if not exists public.autopay_enrollments (
  id                    uuid primary key default gen_random_uuid(),
  user_id               uuid not null references auth.users(id) on delete cascade,
  stripe_account_id     text not null,           -- account at consent; must equal stripe_accounts at charge time
  customer_id           text not null,           -- TradeReady customers.id (plan.customerId at consent)
  recurring_invoice_id  text not null,           -- TradeReady plan id
  stripe_customer_id    text not null,           -- cus_… on the connected account
  payment_method_id     text,                    -- pm_…; null while pending
  card_brand            text, card_last4 text, card_exp_month int, card_exp_year int, card_wallet text,
  billing_email         text,                    -- Checkout-entered email (receipts fall back to it)
  max_amount_cents      integer not null check (max_amount_cents > 0),
  status                text not null check (status in ('pending','active','revoked','replaced')),
  consent_version       text not null,
  consent_text          text not null,           -- exactly what was shown
  consented_at          timestamptz not null default now(),
  consent_ip            text, consent_user_agent text,
  checkout_session_id   text unique,
  activated_at          timestamptz, revoked_at timestamptz,
  revoked_by            text check (revoked_by in ('customer','owner','system')),
  revoke_reason         text,
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now()
);
create unique index if not exists autopay_one_active_per_plan
  on public.autopay_enrollments (user_id, recurring_invoice_id) where status = 'active';
create index if not exists autopay_by_customer on public.autopay_enrollments (user_id, customer_id);

create table if not exists public.autopay_charges (
  id                 uuid primary key default gen_random_uuid(),
  user_id            uuid not null references auth.users(id) on delete cascade,
  invoice_id         text not null,
  enrollment_id      uuid not null references public.autopay_enrollments(id) on delete cascade,
  attempt            smallint not null default 1,
  amount_cents       integer not null,
  status             text not null check (status in ('claimed','succeeded','failed','skipped')),
  payment_intent_id  text,
  failure_code       text, decline_code text, failure_message text,
  customer_notified_at timestamptz, owner_notified_at timestamptz,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  unique (user_id, invoice_id, attempt)
);
-- RLS: enable on both; "read own …" select policies using (auth.uid() = user_id). No write policies.
```

- **One automatic attempt per invoice, ever.** v1 only writes `attempt = 1`. The column exists so a later owner-triggered retry is additive.
- **Pending rows** are created when a consenting checkout starts. A pending row that never completes stays inert. The sweep marks pending rows older than 48 h as `revoked` (`system`, `abandoned`).
- **The consent record survives revocation** for dispute evidence. Rows hold no card numbers. They cascade on account deletion.
- **Dormant twin:** none. The Vercel backend never reads these tables.

### 3.2 Synced blobs (no migration)

- `Canonical.RecurringInvoice.autopayEnabled: Bool?` is typed, absent means off, and is set by the plan editor (§6.2). The Worker reads it at charge time and at pay-view time.
- Invoices gain **no** new field. Eligibility is derived server-side (§4.6). A device stamp would add nothing: the due-date window already excludes catch-up backlog.

### 3.3 Ledger entry for an autopay charge

```json
{ "id": "stripe_pi_3Q…", "amount": 120.00, "date": "2026-11-01", "method": "stripe",
  "stripePaymentIntentId": "pi_3Q…", "channel": "autopay", "note": "Autopay · Visa •••• 4242" }
```

- The entry uses the same writer, ownership check, legacy materialization, dedupe and union trigger as link payments (§4.1).
- Link payments keep `stripe_<session id>` (TH-9 unchanged). Autopay payments use `stripe_<pi id>`. The two never collide because autopay PaymentIntents aren't created by Checkout.
- The id and the `stripePaymentIntentId` / `channel` keys match the entry shape the Phase 18 tap-to-pay spec uses (`2026-10-03-tap-to-pay-design.md` §3, `channel: "card_present"`). TH-9 then extends naturally: every succeeded autopay or card-present PaymentIntent has exactly one `stripe_<pi id>` entry.
- `stripePaymentIntentId` and `channel` ride as preserved keys natively (§0.2). Nothing reads them in v1, so they aren't typed.

## 4. Worker

### 4.1 Shared Stripe plumbing (refactor first, behavior-neutral)

- **`W/lib/stripe/client.js`.** `makeStripe(env)` returns `new Stripe(key, { apiVersion: '2023-10-16', httpClient: Stripe.createFetchHttpClient() })`.
  - Every route and the sweep take an injectable `stripeFactory`, so tests run against a fake.
  - The four existing constructors switch to it. The pin itself is unchanged.
- **`W/lib/stripe/recordPayment.js`.** `recordStripePayment(env, { invoiceId, connectedAccountId, ledgerId, amount, date?, extra })` is extracted unchanged from `webhook.js:102-236`.
  - `date` defaults to today's UTC date, as today.
  - This is the same normalized shape the Phase 18 tap-to-pay spec proposes (`2026-10-03-tap-to-pay-design.md` §2.2). Phase 24 is earlier in the build order, so it lands here first and Phase 18 reuses it.
  - `extra` merges optional keys: `stripeSessionId`, `stripePaymentIntentId`, `channel`, `note`, and Phase 28's `tipAmount`.
  - It returns `{ outcome: 'appended' | 'duplicate' | 'not_found' | 'ownership_skip' | 'zero_amount', invoice }`, so callers can send receipts only on `appended`.
- **Characterization tests land before any behavior change** (§8): the webhook as it is today, plus `createPaymentLink`.

### 4.2 Signed tokens (`W/lib/pay/payToken.js`, pure)

- **Format:** `<kind>.<base64url(JSON payload)>.<base64url(HMAC-SHA256(secret, "tr-pay|" + kind + "|" + payload))>`, compared with `constantTimeEqual` (`W/lib/constantTime.js`). It follows the `W/lib/photoSign.js` precedent.

| Kind | Payload | Used by |
|---|---|---|
| `p` (pay) | `{v:1, u: userId, i: invoiceId, a?: requestedCents}` | invoice links; no expiry (liveness is checked at view time) |
| `s` (setup) | `{v:1, u, r: planId, x: expiresAtSec}` | portal "Set up"; minted per portal view, 7-day expiry |
| `m` (manage) | `{v:1, u, e: enrollmentId}` | every autopay email and the portal card; no expiry. It can only view brand/last 4 and turn autopay off |

- **The secret** is a new Worker secret `PAY_LINK_SIGNING_SECRET` (owner op, §9). It is not shared with the portal photo secret, so rotations stay independent.
- **The secret doubles as the rollout switch.** With it unset, `create-payment-link` keeps minting Payment Links (§4.3), so the Worker can deploy before `pay.html` is published.
- **`u` exposure.** Embedding the owner's user id follows the public photo URLs (`?u=`). Binding `u` means a token minted by owner A for owner B's invoice id resolves to 404.

### 4.3 `create-payment-link` (same route, same response shape)

- **Auth is unchanged.** It still requires the JWT and a `stripe_accounts` row (422 otherwise).
- **New ownership check.** If the invoice row exists and belongs to another user, it returns 404. If the row doesn't exist yet (an unsynced device), it still mints, because `view` re-checks.
- **With `PAY_LINK_SIGNING_SECRET` set** it returns `{ url: PAY_PUBLIC_BASE + '?t=' + token }`, where `a = round(amount*100)`. `PAY_PUBLIC_BASE` defaults to `https://gettradereadyapp.com/pay.html`, derived like `CHANGE_PUBLIC_BASE`. **No Stripe call is made.** Rate limit unchanged.
- **Without the secret** it mints the legacy Payment Link exactly as today, plus `restrictions: { completed_sessions: { limit: 1 } }`. That one line closes the double-pay hole on the fallback path.
- **Host allowlist.** `isAllowedPaymentLink` (`W/lib/reminderEmail.js:27-37`) also accepts `https://gettradereadyapp.com` / `www.` **only** with path `/pay.html` or `/pay` (Pages strips `.html`).
  - That keeps the anti-phishing intent: the domain is ours and the path is fixed.
  - The portal and both emails inherit it. Existing amount gates are unchanged, and minting is now free, so the device simply re-mints after a partial payment.

### 4.4 Pay routes (browser-facing, `applyCors`, rate-limited, `W/src/routes/pay/*`, logic in `W/lib/pay/*`)

**`GET /api/pay/view?t=|s=|m=[&session_id=]`** returns a whitelisted JSON shape with an exact-key test:
- `p`: `{ kind:'invoice', businessName, invoiceNumber, description, amountDue, depositRequested?, due, paid, paidAt?, autopay: null | { offer: {planDescription, amount, cadence, consentText, consentVersion, isUpdate}, active?: {card:'Visa ending 4242'} } }`
  - The Phase 28 `tips` block is added there.
  - With `session_id`, the Worker retrieves that session on the owner's account. It returns a `receipt` block only when `session.metadata.invoiceId` matches the token: `{ status: 'paid'|'processing', amountPaid, total, cardBrand?, last4? }`.
- `s`: `{ kind:'setup', businessName, planDescription, amount, cadence, consentText, consentVersion }`, or `expired`.
- `m`: `{ kind:'manage', businessName, planDescription, status, card, canTurnOff }`.
- **What the view never returns:** customer name, email, address, Stripe ids, other invoices.

**`POST /api/pay/checkout`** takes `{t, autopay?: {consentVersion}}` or `{s, consentVersion}`:
1. Verify the token. Re-read the invoice (or plan), `stripe_accounts` and settings. Refuse when paid, deleted, the owner is disconnected, or the autopay offer changed (409 "Please reload": a stale consent version or a changed amount).
2. **Amount.** `cents = min(a ?? balance, balance)`, where balance is `balanceDue` from `paymentMath.js`. Refuse when it is ≤ 0. Refuse when an `autopay_charges` row for this invoice is `claimed`, because an autopay charge is in flight.
3. **One open session per invoice.** List the connected account's `open` sessions from the last 24 h and `expire` any whose `metadata.invoiceId` matches. An expire error (already completed) aborts with 409 "This invoice may have just been paid. Reload."
4. **Autopay opt-in.**
   - Find a reusable Stripe Customer for (user, `plan.customerId`) among existing enrollment rows, else `customers.create({name, email: plausible invoice email or omitted, metadata: {tr_user, tr_customer}})`.
   - Insert a `pending` enrollment with the consent record. The IP comes from `clientIp(c)` and the UA from the header.
   - Compute its manage token for `custom_text`.
5. **Create the session** with an idempotency key `tr-co:<invoiceId>:<cents>:<flags>:<10-minute bucket>`, so a double-click returns the same session:
   - `mode: 'payment'`, `payment_method_types: ['card']`
     - This pins card, so the Phase 30 dynamic-ACH risk can't reach new links. Apple Pay and Google Pay are card wallets in Checkout; the smoke test confirms they appear.
   - `line_items: [{price_data: {currency:'usd', unit_amount: cents, product_data: {name: 'Invoice ' + number}}, quantity: 1}]`
   - `metadata: {invoiceId, tr_kind:'invoice', tr_invoice_cents, tr_enrollment?}`
   - `payment_intent_data: {metadata: {invoiceId, source: 'pay_page'}, description: 'Invoice ' + number, setup_future_usage?: 'off_session'}`, plus `customer` when opted in
   - `expires_at: now + 30 min` (the minimum), `success_url`, `cancel_url`, `custom_text.submit` when opted in
   - The setup kind uses `mode: 'setup'`, `customer`, `payment_method_types: ['card']`, `setup_intent_data.metadata: {tr_enrollment}`, `metadata: {tr_kind:'autopay_setup', tr_enrollment}`.
6. Store `checkout_session_id` on the pending enrollment. Return `{url}`.

**`POST /api/pay/autopay-off {m}`** revokes the enrollment (`customer`), detaches the PM, sends the customer a confirmation, alerts the owner, and is idempotent.

### 4.5 Webhook (same endpoint, same event type)

Still only `checkout.session.completed`. Changes:
- **Paid payment sessions** (unchanged guard). Call `recordStripePayment` with the existing id `stripe_<session.id>` and the amount from `amount_total`. Phase 28 splits it (tips spec §4.3).
  - When `metadata.tr_enrollment` is set, activate the enrollment (below).
  - On `appended`, send the payment receipt (§4.7) to `session.customer_details.email`.
- **Setup sessions** (`mode === 'setup'`, `status === 'complete'`, `metadata.tr_kind === 'autopay_setup'`): activate the enrollment.
- **Activation:**
  1. Retrieve the PI or SetupIntent with `expand: ['payment_method']` on `event.account`.
  2. Require `event.account === enrollment.stripe_account_id === stripe_accounts row`.
  3. Write PM id, brand, last 4, expiry, wallet, `billing_email` and `status: 'active'`.
  4. Any prior active enrollment for the plan becomes `replaced`, and its PM is detached (unless the same PM id).
  5. Send the customer the "Automatic payments are on" email, which repeats the terms and carries the manage link.
- **Legacy Payment Link sessions** (`session.payment_link` set): after a successful append, deactivate the link best-effort with `paymentLinks.update(id, {active: false, inactive_message: 'This invoice has been paid. Thank you!'})`.
  - Every link ever minted is single-purpose, so this closes the double-pay hole for links already in inboxes.
  - A failure is logged. It never changes the 200.
- Activation and deactivation failures are logged and acknowledged with 200. They are not retried: the ledger write already succeeded, and Stripe retries are reserved for ledger errors.

**No new webhook event types.** Autopay charges are confirmed synchronously (§4.6). PM card updates are refreshed at charge time. Refunds and disputes stay out of scope (§10).

**Forward compatibility with Phase 18.** The tap-to-pay spec later subscribes `payment_intent.succeeded` and books only PIs with `metadata.source === 'tap_to_pay'` (`2026-10-03-tap-to-pay-design.md` §2.2). That spec's filter is what prevents double-booking.
- Pay-page PIs carry `source: 'pay_page'` and autopay PIs carry `source: 'autopay'`, so that filter skips both.
- Even if an autopay PI were booked there, its id `stripe_<pi id>` equals the sweep's, so the union collapses the two copies.
- A pay-page PI must **never** be booked from a PaymentIntent event, because its ledger id is the session's.

### 4.6 Autopay sweep (`W/lib/autopay/runAutopayCharges.js`; pure selector `selectInvoicesToCharge.js`)

**Scheduling.** `scheduled()` `*/15` runs `runAutopayCharges(env)` and **then** `runInvoiceEmails(env, { autopayHandled })` in one `waitUntil`. A manual fallback route `/api/cron/run-autopay` sits behind `CRON_SECRET`.

**Fetch:** active enrollments, then only those users' plan rows and their invoices: `data->>recurringInvoiceId=in.(…)` and `deleted=is.false`.

**Eligible when all hold:**

| Rule | Why |
|---|---|
| Enrollment `active`; `stripe_account_id` equals the current `stripe_accounts` row | Never charge into a different account (account-switch protection) |
| Plan row exists, not deleted, `autopayEnabled === true`, `plan.customerId === enrollment.customer_id` | The owner's toggle is read at charge time; a reassigned plan never charges the first customer |
| Invoice `recurringInvoiceId === enrollment.recurring_invoice_id`, no `importBatchId` | Plan invoices only |
| `due >= activated_at` (UTC date) | Consent covers invoices coming due after consent |
| Now is within **[`due` 14:00 UTC, `due` + 7 days 14:00 UTC]** | On the due date in every US zone (14:00 UTC = 6–10 am) and never before the due date anywhere (no zone is behind UTC−12). Runs ahead of the 15:00 UTC reminder trigger. A late-generated invoice outside the window just follows the normal email/link path |
| `balanceDue > 0.005`, and `balanceCents <= max_amount_cents` | Never charge above the authorized amount |
| No `autopay_charges` row for (user, invoice) | One attempt ever |
| Fewer than 25 claims for the user today | Same blast-radius cap as the invoice emails |

Rows failing only the amount rule get a `skipped` claim with `failure_code: 'amount_above_authorized'` and the fallback (below). That happens once.

**Per invoice:**
1. **Claim:** insert `autopay_charges` (`claimed`) with `on_conflict=user_id,invoice_id,attempt` and `ignore-duplicates`. An empty result means another run has it, so skip.
2. **Refresh the card:** `paymentMethods.retrieve(pm)` and update the stored brand, last 4 and expiry (card account updater). A missing or detached PM → enrollment `revoked` (`system`, `payment_method_missing`), claim `failed`, fallback.
3. **Charge:** `paymentIntents.create({amount: cents, currency: 'usd', customer, payment_method, off_session: true, confirm: true, payment_method_types: ['card'], description: 'Invoice ' + number, metadata: {invoiceId, source: 'autopay', tr_enrollment}}, {stripeAccount, idempotencyKey: 'tr-autopay:' + invoiceId + ':1'})`.
4. **Succeeded:**
   - `recordStripePayment` with `ledgerId: 'stripe_' + pi.id`, `extra: {stripePaymentIntentId, channel: 'autopay', note: 'Autopay · <Brand> •••• <last4>'}`
   - claim `succeeded` with `payment_intent_id`
   - the customer's autopay receipt (§4.7)
   - no owner alert: the payment syncs into the app like any other
5. **Card error (402):** claim `failed` with `code` / `decline_code` / message. Then:
   - Cancel the failed PI best-effort, so nothing can confirm it later.
   - **Hard failures** (`expired_card`, `decline_code` ∈ {`lost_card`, `stolen_card`, `pickup_card`, `invalid_account`, `restricted_card`}) set the enrollment to `revoked` (`system`), so later invoices don't keep failing.
   - **Soft failures** (insufficient funds, generic, `do_not_honor`, `authentication_required`, processing) keep the enrollment for the next invoice.
   - **Fallback:** email the customer a server-minted `p` token link for the full balance, with reason-specific copy:
     - `authentication_required`: "your bank asked you to confirm this payment"
     - expired: "the card on file has expired"
     - otherwise: "your card was declined"
   - The email suggests ticking "pay automatically" to save a new card. Alert the owner by email + push.
6. **Unknown outcome** (network error, Stripe 5xx, 429): leave the claim `claimed`.
   - The next sweep replays the **same idempotency key**, and Stripe returns the stored result (§0.5). This is an idempotent re-read of one charge, not a retry of a decline.
   - A claim still unresolved after 6 h (well inside the 24 h key-pruning window) is listed on the connected account by `customer` + `created` and matched on `metadata.invoiceId`. If no PI is found, it is marked `failed` (`unknown`) and the owner is alerted to check Stripe.
7. **No automatic retry of a failed charge, ever.** The customer pays through the link, or the owner records the payment.

**Housekeeping** (same run, silent):
- Enrollments whose plan is deleted or missing, or whose plan's customer changed, are revoked (`system`) and their PM detached. This is how plan or customer deletion in the app cleans up without a device call.
- Pending rows older than 48 h are expired.

### 4.7 Emails and alerts (existing Resend; pure builders in `W/lib/autopay/emails.js`)

- **Sender and safety.** Customer mail goes from `"{Biz} via TradeReady" <invoices@gettradereadyapp.com>`, with `reply_to` set to the owner's settings email. It reuses `sanitizeFromPhrase` / `sanitizeSubject` and the link allowlist.
- **Templates.** All are deterministic and template-only, with no AI:
  - **Payment receipt** (pay-page payments): business, invoice number, amount paid, card brand / last 4 (from the PI's charge), remaining balance, date. One send per `appended` outcome, so a webhook redelivery can't duplicate it.
  - **Autopay receipt:** the same, plus "Paid automatically with your saved card" and the manage link.
  - **"Automatic payments are on"**: repeats the authorization text and the manage link. This is the record of the agreement Stripe's checklist asks for.
  - **Charge failed:** reason, pay link and manage link.
  - **"Automatic payments are off"**: says who turned it off (you / {Business}).
- **Recipient.** Receipts go to the Checkout-entered email (link payments), or to `billing_email` falling back to the plausible invoice email (autopay). No plausible address means no mail, logged.
- **Owner alerts** (`W/lib/ownerAlert.js`: auth email + Expo push, fire-and-forget, following `notifyOwner.js:62-110` without touching that file, which another agent is editing):
  - autopay failed or skipped (customer, invoice, reason, "we emailed them a payment link")
  - the customer turned autopay off
  - a card was removed by the system (hard decline or missing PM)
- **Owner alert sender:** `TradeReady <payments@gettradereadyapp.com>`. It is the same verified domain, so no new service.

### 4.8 Owner routes (JWT, `appCors`)

- `GET /api/autopay/status` returns `{ enrollments: [{id, recurringInvoiceId, customerId, status, card: {brand, last4, expMonth, expYear, wallet}, maxAmount, activatedAt, revokedAt, revokedBy, revokeReason}], charges: [{invoiceId, status, amount, failureReason, at}] }`.
  - Charges cover the last 120 days. Consent IP and UA are not sent, but the consent time is.
- `POST /api/autopay/manage {action: 'remove', enrollmentId}` revokes (`owner`), detaches the PM, emails the customer "turned off by {Business}" and is idempotent.

### 4.9 Portal (`portalAssemble.js`, `portalStore.js`)

- **New fetches.** The customer's plan rows `recurringInvoices?user_id=eq.U&data->>customerId=eq.C&deleted=eq.false`, plus their enrollments.
- **New top-level whitelist key `autopay`:** `[{ description, amount, cadence, status: 'on' | 'available', card: 'Visa ending 4242' | null, setupUrl | null, manageUrl | null }]`. It covers only plans with `autopayEnabled` that are active.
- **Exact-key test updates:** `__tests__/portalAssembleWorkers.test.js:87` (top level) and a new per-entry key assertion.
- **Coordination.** `portalAssemble.js` is being edited by the Phase 32 agent, so this lands after that work merges.

### 4.10 Invoice email and reminders interplay

- **`buildInvoiceEmail`** (`W/lib/invoiceEmail.js`): when the invoice will be charged by an active enrollment (eligible except for timing), it adds a line.
  - The line reads: "This invoice will be charged automatically to your Visa ending 4242 on {due}. Nothing to do. Manage automatic payments: {manage URL}".
  - The pay line stays, worded "Prefer to pay now with another card? {link}".
  - The sweep passes in a precomputed `autopayByInvoice` map, so the builder stays pure.
- **`runInvoiceEmails`** receives `autopayHandled` (invoice ids that got a failure or skip email this run). For those it writes its claim row with status `superseded` instead of sending, so the customer gets one email, not two.
- **`runReminders`** excludes invoices with an active enrollment whose autopay window is open and that have no claim yet. This defends against a 0-day reminder racing the charge (§0.3).

### 4.11 Disconnect and account deletion

- **`POST /api/stripe/disconnect`:** before deleting the row, revoke every active or pending enrollment (`system`, `stripe_disconnected`) and detach their PMs on the old account, best-effort. The account is the owner's, but TradeReady can no longer honor "turn off" for it.
- **Account deletion** (`W/src/routes/deleteAccount.js`, before the core runs): does the same best-effort. Rows cascade.
  - `W/lib/accountDeletion.js` stays vendor-free, as its header requires.

## 5. Pages (`tradeready-legal`, `feat/autopay`)

- **New `pay.html`:**
  - Same fonts, tokens and header as `portal.html`; `noindex`; no external scripts; no `_headers` change.
  - Four modes: `t`, `t`+`session_id`, `s`, `m`.
  - Complete error copy for 400/404/409/410/429/500. A visible "Powered by TradeReady. Card entry is handled by Stripe." footer.
  - The checkbox is unchecked by default. The button label tracks the choice ("Pay $120.00" / "Pay $120.00 and turn on automatic payments").
- **`portal.html`:**
  - The Invoices Pay button is unchanged (the URL is now a pay-page URL).
  - New "Automatic payments" section rendered from `autopay[]`: per plan, status, card, and a "Set up" or "Manage" link.
- **`terms.html` / `privacy.html`:** the text in §7, **only after owner approval**.

## 6. Native

### 6.1 Deposit-link fix (in scope; small; lands first)

In `generateInvoicePaymentLink`:
- capture `balanceBefore = PaymentLedger.balanceDue(ledgerInvoice(record))` before the await
- after it, refuse only when `|latestBalance − balanceBefore| > epsilon` (a payment arrived) or `requested > latestBalance + epsilon`

A StoreIntegration test with an injected Stripe delivery service covers:
- full balance
- 50% deposit (now succeeds)
- a concurrent payment during the await (refused)
- a requested amount above the balance (refused)

### 6.2 Plan editor and model

- **Model.** `Canonical.RecurringInvoice.autopayEnabled: Bool?` is typed, with the manual initializer extended so preservation stays intact (`N/Domain/NativeRecurringInvoices.swift:227-268`).
- **New "Payment" section** after "Delivery" (`N/NativeRecurringInvoicesView.swift:251-259`):
  - Toggle **"Offer autopay"**, default off. It is enabled only when Stripe is connected and is the selected provider. Otherwise a caption says "Connect Stripe in Settings → Payments to offer autopay."
  - Turning it on shows a confirmation dialog: "Your customer can choose to save a card when they pay an invoice from this plan, or from their portal. Later invoices are then charged on their due date, up to the plan amount. They can turn it off any time."
  - Turning it off shows: "Stops automatic charges for this plan. The saved card stays until you or the customer removes it."
- **No generation change.** Server eligibility needs no stamp (§3.2).

### 6.3 Autopay status and controls

- **`N/NativeAutopayService.swift`.** Status and remove endpoints via `BuildEnvironment.endpoint`, with the delivery service's session-refresh retry pattern.
- **`N/Domain/NativeAutopay.swift`** (Foundation-only, pure):
  - status per plan: `off | offered | on(card) | removed(by, reason) | lastCharge(failed(reason, date))`
  - display strings: "Visa •••• 4242 · exp 08/27"
  - per-invoice banner text
- **AppStore** keeps `@Published autopayStatus` in memory. It refreshes on foreground at most every 10 minutes, on opening the plans list, and after remove.
- **Plans list rows** show "Autopay on · Visa •••• 4242", "Autopay offered", or "Autopay failed Nov 1: card declined".
- **The plan action dialog** gains "Remove saved card" (destructive confirmation, using the existing `NativeRecurringPlanActionState` pattern) when a card is on file.
- **Invoice detail** for a plan invoice shows a one-line banner:
  - "Will be charged automatically on {due} (Visa •••• 4242)"
  - or "Autopay failed: {reason}. {Customer} was emailed a payment link."
- Successful autopay payments show in the existing Payments section (`N/InvoicesView.swift:399-401`) with the note "Autopay · Visa •••• 4242".
- **Not in v1:** an owner-entered card, an owner "retry charge" button, and autopay for non-plan invoices.

### 6.4 Privacy manifest (only if Q5 is approved)

Add `NSPrivacyCollectedDataTypePaymentInfo` (Linked: true, Tracking: false, Purposes: AppFunctionality) to `N/PrivacyInfo.xcprivacy`, plus the matching App Store Connect label.

## 7. Legal and store (all need owner approval; drafts below)

- **Terms (Q2)** — `terms.html` §4 Payment Processing (`:121-122`). Add:
  > **Automatic payments.** If you offer automatic payments, your customer may authorize you to save their card with Stripe and charge it for invoices under a recurring plan. TradeReady initiates those charges on your behalf, on the terms your customer accepted, and records their authorization. You are responsible for honoring cancellations and handling refunds and disputes. TradeReady does not hold funds; payments go directly to your Stripe account.

  The existing sentence "does not process payments … or act as a payment intermediary" should become "does not hold funds or act as a payment intermediary". TradeReady now **initiates** charges.
- **Privacy (Q3)** — `privacy.html`:
  - Add a §1 bullet:
    > **Automatic-payment records:** if your customer turns on automatic payments, we store the card brand, last four digits and expiry date (never the full card number, which stays with Stripe), Stripe identifiers, the authorization text they accepted, and the time, IP address and browser user-agent of that authorization, plus a record of each automatic charge attempt.
  - Extend the §4 Stripe bullet with ", including saving your customers' payment methods for automatic payments they authorize".
  - Retention: kept until the owner deletes their account. The §7 deletion copy already covers it.
- **App Store privacy label (Q5):** see §6.4. The recommendation is to declare. It is conservative, because the app displays partial payment-card data about the owner's customers.

## 8. Testing

**Worker** (`backend-workers/tests/*.test.cjs`, node:test; Stripe and `fetch` are injected fakes):
- `stripeWebhookCharacterization.test.cjs` lands first: today's behavior (signature failure → 400, non-completed and non-paid skip, ownership skip, idempotent duplicate, legacy materialization, zero amount).
- `createPaymentLink.test.cjs`: legacy path with `restrictions`, pay-page path, ownership 404, 422 when not connected.
- `payToken.test.cjs`: round trip, tamper, kind confusion, `s` expiry, constant-time compare.
- `payView.test.cjs`: exact keys per kind, paid / unsynced / deleted / disconnected states, deposit vs full, autopay-offer matrix (§2.2), session receipt only on a metadata match.
- `payCheckout.test.cjs`:
  - min(requested, balance)
  - refusal while claimed
  - other open sessions expired; an expire failure → 409
  - Customer reuse
  - pending enrollment holds the exact consent text, IP and UA
  - stale consent version → 409
  - setup mode
- `autopaySelect.test.cjs`: every eligibility row, the 14:00 UTC window edges, amount ceiling, plan reassignment, account switch, daily cap.
- `autopaySweep.test.cjs`:
  - success → ledger entry shape + receipt
  - decline, insufficient funds, `authentication_required`, expired card (each → fallback email + owner alert, with revoke for hard declines)
  - PM missing
  - unknown outcome → idempotent replay → resolved; the 6 h list fallback
  - claim conflict
  - `superseded` email claim
- `stripeWebhookAutopay.test.cjs`: payment-mode activation, setup-mode activation, replacement detaches the old PM, legacy link deactivation (best-effort), receipt only on `appended`.
- `autopayEmails.test.cjs`: deterministic templates, header sanitizing, allowlisted links only.

**Root Jest:** `__tests__/portalAssembleWorkers.test.js` (new `autopay` key and entry keys), `reminderEmailHardening.test.js` and `invoiceEmailHardening.test.js` (pay-page host + path only; autopay line).

**Native:**
- New `native/AutopayTests/main.swift` + `run-autopay-tests.sh`, registered in `run-all-domain-tests.sh`: status mapping, display strings, banner text.
- Updated suites:
  - Canonical (`autopayEnabled` round trip + preservation)
  - StoreIntegration (deposit-link fix vectors, plan toggle persistence and push, remove flow with an injected service)
  - RecurringInvoice (initializer preservation)

**Gates:**
- `sh native/run-all-domain-tests.sh`, the Release compile
- `cd backend-workers && npm test`
- targeted Jest under `TZ=America/Phoenix`
- `sh native/run-doc-reference-check.sh`

**Owner test-mode smoke** (Stripe test mode, synthetic Express account; this is the version-safety proof):
1. Pay a pay-page link with 4242 → one ledger entry; the link shows Paid; a second tab's session is expired.
2. Opt in with `4000002500003155` → enrollment active → due-date sweep charges off-session successfully.
3. Enroll `4000002760003184` → off-session `authentication_required` → fallback email → pay via link.
4. `4000000000009995` → decline → no retry.
5. `4000000000000341` → attaches, then the charge fails.
6. Portal setup + turn off; owner remove.
7. Apple Pay is visible in Checkout with `payment_method_types: ['card']`.

## 9. Rollout (owner ship steps, in order)

1. **Confirm the ledger union trigger is applied.** Run `supabase/migrations/verify/20260718_invoice_payment_merge_verify.sql` with psql and `ON_ERROR_STOP=1` (`docs/deposits-resume-here.md` §4). Server-side appends (pay page, autopay, tips) must not run on unprotected rows.
2. **Confirm** the Connect webhook endpoint in the Stripe Dashboard targets the Worker's `/api/stripe/webhook` and lists `checkout.session.completed`. This is verification only; nothing changes.
3. **Apply** `20261003_autopay.sql`, then run its verify script (Q1).
4. **Deploy the Worker.** Without `PAY_LINK_SIGNING_SECRET` it behaves as today, plus `restrictions.limit = 1` and legacy link deactivation.
5. **Publish** `pay.html` and the `portal.html` update. Publish legal text if Q2/Q3 are approved; the legal text must be live **before** step 6 so autopay never runs under terms that don't describe it.
6. `wrangler secret put PAY_LINK_SIGNING_SECRET` turns on pay-page links.
7. **Ship the native build.** The plan toggle is the only way autopay can be offered, so nothing is charged before this step.

Nothing here is deployed, applied or pushed by the build session.

## 10. Accepted residuals

- **Generation is still device-only.** A plan invoice exists only after the owner's app generates it. If that happens more than 7 days past the due date, autopay skips it and the normal email/link path applies. Server-side generation is a separate project.
- **Cards only.** Bank accounts (ACH) need Phase 30, which the owner build order puts out of scope.
- **Legacy Payment Links in inboxes** stay payable once each. They are deactivated after their first payment. One minted before a manual cash payment can still overpay once, the same as today.
- **The two-tab window is narrowed, not eliminated.** At most one open session exists per invoice. A customer mid-checkout on an expired session sees Stripe's "expired" page and reloads the pay page.
- **Refunds and disputes** remain manual: the owner voids in-app. No `charge.refunded` or `charge.dispute.*` handling.
- **Express accounts and direct charges** are the pre-existing architecture. Stripe recommends direct charges for accounts with full Dashboard access ([direct charges](https://docs.stripe.com/connect/direct-charges?platform=web&ui=stripe-hosted)). Express owners can't manage saved cards in Stripe, so the app is the only management surface. The platform carries Express negative-balance and dispute exposure, as it does today.
- **Possible duplicate receipts.** If an Express account has Stripe's own successful-payment emails on, the customer may get both Stripe's receipt and ours. The owner can check in the Express dashboard. Cosmetic.
- **Dates are UTC.** Ledger dates for server-recorded payments are UTC (the existing accepted limitation at `webhook.js:168-171`).
- **The RN client, if still in the field,** shows the plan without the toggle and ignores enrollments. Charges still land in its ledger normally.
- **No Today insight for autopay failures** in v1. Email, push, the plan row and the invoice banner cover it.
- **The dormant Vercel twin** is not updated: a rollback to Vercel loses the pay page and the sweep, and keeps the legacy links.

## 11. Decisions made by recommendation (owner may override)

| # | Decision | Choice |
|---|---|---|
| D1 | Link mechanism | TradeReady pay page + per-visit Checkout Session; the secret gates the switch, and the fallback keeps Payment Links with `limit: 1` |
| D2 | Link tokens | Stateless HMAC (`p`/`s`/`m`) with a dedicated `PAY_LINK_SIGNING_SECRET`; no link table |
| D3 | Where consent is captured | The pay page (opt-in on a plan invoice payment) **and** the portal ("Set up", setup-mode Checkout), both rendering the same server-owned text; record stored server-side |
| D4 | Consent scope | Per plan; ceiling = plan amount at consent; charged on the due date; covers unpaid plan invoices due after consent; a higher amount needs re-consent |
| D5 | Stripe shape | One Customer per (owner, TradeReady customer) on the connected account, created lazily; PM saved by Checkout `setup_future_usage: off_session` or `mode: setup`; off-session PI with `confirm: true`; card only |
| D6 | Who charges | The Worker `*/15` sweep, not the device; window [due 14:00 UTC, due + 7 d] |
| D7 | Never charged twice | Claim row (unique user/invoice/attempt) + Stripe idempotency key + ledger id `stripe_<pi>`; pay checkout refuses while a charge is claimed |
| D8 | Ledger landing | Shared `recordStripePayment` (extracted from the webhook) with the same union trigger; note "Autopay · Brand •••• last4" |
| D9 | Failure handling | One attempt; cancel the failed PI; hard declines revoke the card; customer emailed a fresh pay link; owner email + push; an unknown outcome is re-read idempotently ≤ 6 h; no retry loop |
| D10 | Owner controls | Per-plan "Offer autopay" (default off); brand / last 4 / expiry display; remove card; no owner-entered cards or retry button in v1 |
| D11 | Customer emails | Receipts (pay-page and autopay), "autopay on/off" confirmations and failure notices via the existing Resend sender |
| D12 | Double-pay fix | In scope: live balance, one open session per invoice, legacy link deactivation, `limit: 1` on the fallback mint |
| D13 | Deposit-link bug | In scope (§6.1) |
| D14 | Stripe API / SDK / dependencies / Dashboard | No version bump, no SDK bump, no new dependency, no Dashboard setting change; **no new webhook event type** |
| D15 | Disconnect / account deletion | Revoke enrollments and detach PMs best-effort |
| D16 | Payment methods on new sessions | Pinned to `['card']` |

## 12. NEEDS OWNER APPROVAL

| # | Question | Recommended answer |
|---|---|---|
| Q1 | **Migration.** May the build add `supabase/migrations/20261003_autopay.sql` (two server-owned tables, `autopay_enrollments` and `autopay_charges`, owner-read RLS, no client writes) plus its verify script, for you to apply before the Worker deploy? | **Yes.** Autopay needs durable consent records and a charge claim that can't live in device-owned blobs (a stale device push would clobber them). |
| Q2 | **Terms of Service.** Approve the §7 "Automatic payments" paragraph for `terms.html` §4, and reword "does not process payments" to "does not hold funds or act as a payment intermediary"? | **Yes, as drafted.** TradeReady will initiate charges, so the current sentence would be inaccurate. |
| Q3 | **Privacy Policy.** Approve the §7 "Automatic-payment records" bullet for §1 and the §4 Stripe addition? | **Yes, as drafted.** New end-customer data (card brand / last 4 / expiry, consent IP and UA) must be disclosed. |
| Q4 | **Customer authorization wording.** Approve the §2.3 text (pay page, portal setup, Checkout `custom_text`, and the "autopay on" email), including "charged on the due date" and "never more than the plan amount"? | **Yes, as drafted.** It covers Stripe's off-session checklist: agreement, timing and frequency, amount, cancellation and record. |
| Q5 | **App Store privacy label and `PrivacyInfo.xcprivacy`.** Declare **Payment Info** (linked, App Functionality, not tracking), because the app will show customers' card brand / last 4 / expiry? | **Yes, declare it.** Partial card data shown in-app is the conservative reading of Apple's "Payment Info". |

**Owner operations (not decisions, listed so nothing is missed):**
- set the `PAY_LINK_SIGNING_SECRET` Worker secret (§9 step 6)
- run the union-trigger verify script (§9 step 1)
- check the webhook endpoint target (§9 step 2)
- the deploy / publish / ship order in §9
