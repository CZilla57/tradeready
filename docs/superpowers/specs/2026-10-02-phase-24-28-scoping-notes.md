# Phase 24 (card on file/autopay) + 28 (tips) — scoping facts (2026-10-02)

## Payment links today
- **Object:** `backend-workers/src/routes/createPaymentLink.js` uses **Payment Links** (Product + Price + PaymentLink per call). These are DIRECT charges on the connected Express account via the `{stripeAccount}` header. No application fee.
  - The only metadata is `{invoiceId}` (it carries over to the Checkout Session).
  - The client sends `{amount, invoiceNumber, description, invoiceId}`. The server checks only `amount > 0`: no balance check, no invoice-ownership check.
- **API version:** pinned `apiVersion: '2023-10-16'` in each constructor (createPaymentLink:91, webhook:54, createConnectAccount:38, connectStatus:49). The SDK is `stripe` 16.12.0 (default 2024-06-20). Webhook payload shape follows the Dashboard endpoint version.
- **No idempotency.** Links are never deactivated and have no `restrictions.completed_sessions`, so ONE LINK CAN BE PAID TWICE (two ledger payments, overpaid).
- **Storage:** the device stores `paymentLinkUrl` and `paymentLinkAmount` on the invoice (`AppStore.swift` ~1976-1994, 2299-2302, `persistInvoiceDeliveryFields` ~2024).
- **Gate:** the portal and email show the link only when `!paid`, the host is allowlisted (`lib/reminderEmail.js:16-23`), and `|paymentLinkAmount - balanceDue| <= 0.005` (`portalAssemble.js:148-153`, `invoiceEmail.js:43-50`).
- **Suspected native bug:** `generateInvoicePaymentLink` (`AppStore.swift` ~2286-2298) mints a Stripe link and then throws `.invalidAmount` unless requested == balance, so a Stripe DEPOSIT link always fails. Verify at kickoff.

## Webhook (`backend-workers/src/routes/stripe/webhook.js`)
- Single Connect endpoint, `STRIPE_CONNECT_WEBHOOK_SECRET`, `constructEventAsync`.
- Handles ONLY `checkout.session.completed` with `payment_status === 'paid'`, and skips sessions without `metadata.invoiceId`.
- Ownership: `event.account` must match `stripe_accounts` (`lib/stripe/webhookOwnership.js`).
- `recordStripePayment`:
  - fetches the invoice and materializes the legacy ledger
  - idempotency id is `'stripe_'+session.id`
  - `amount = session.amount_total/100` (gross)
  - appends `{id, amount, date: UTC today, method:'stripe', stripeSessionId}`, recomputes paid/paidAt, and upserts with merge-duplicates
  - It never reads line items, so a tip would be booked as an invoice payment.
- Union trigger `20260718_invoice_payment_merge.sql` unions ONLY `payments` by id. **Its applied status is unclear** (webhook.js:7-14 and `docs/deposits-resume-here.md:58` say not applied).
- `lib/paymentMath.js` is byte-identical to `backend/lib/paymentMath.js`; parity is pinned by `__tests__/paymentMathParity.test.js`.
- **No tests cover the Worker createPaymentLink or webhook.** `__tests__/stripeWebhookOwnership.test.js` tests the legacy backend with a virtual `jest.mock('stripe')`.

## Connect
- Express accounts (card_payments, transfers).
- `stripe_accounts {user_id PK, stripe_account_id, created_at}`, owner read-only RLS. Nothing else is stored.
- `connectStatus` doesn't read `charges_enabled`.

## Recurring invoices
- `Canonical.RecurringInvoice` (synced table `recurringInvoices`) has a per-rule `autoSendEnabled`; the master setting is `Settings.autoSendRecurringInvoicesEnabled`.
- **Generation is device-only** (`NativeRecurringInvoices.generate`, `AppStore.runRecurringInvoiceGeneration` ~3835, run on foreground and initial sync). It stamps `autoEmailRequestedAt` on the newest occurrence.
- **Link minting is device-side:** `deliverNativeInvoice` (~1932-2013) mints a link for the balance and uploads the PDF to R2.
- **Sending is the Worker** `*/15` cron: `runInvoiceEmails` (`lib/sendInvoiceEmails.js`) with `selectInvoicesToAutoEmail.js`, claims in `auto_invoice_email_log`, and a cap of 25/user/day.
- The autopay toggle belongs next to `autoSendEnabled` (`NativeRecurringInvoicesView.swift` Delivery section ~251-259). An off-session charge would naturally hook into the */15 cron sweep.

## Portal
- `buildInvoices` (`portalAssemble.js:137-171`) has the whitelist `{number, amount, amountPaid, balanceDue, due, paid, paidAt, paymentLinkUrl}`, with an exact-key test.
- `portal.html` `invoiceCard` ~287-303 and `render()` ~403-428. The POST pattern to copy is portal-request / portal-manage.

## Stripe features (SDK 16.12.0 types)
- No existing Customer, SetupIntent or off_session usage anywhere.
- SDK support: `PaymentIntentCreateParams.off_session`/`error_on_requires_action`; PaymentLink `payment_intent_data.setup_future_usage`, `customer_creation`, `consent_collection.payment_method_reuse_agreement`, `custom_text`; Price `custom_unit_amount {enabled, minimum, maximum, preset}`; PaymentLink `line_items[].adjustable_quantity`.
- `optional_items` is NOT in the types.
- **Tips:** a custom_unit_amount price probably must be the sole line item (verify in the Stripe docs). The alternative is Checkout Sessions created per payment with a server-known invoice amount, or a separate tip link.

## Money surfaces that read payments
- `NativeCashBasis.collected` / `collectedByPeriod`
- `NativeMoneyReports.summarizeInvoices`
- `TaxEstimateEngine.summarize` → `PaymentLedger.collected` (FinancialDomain ~740-787, 470-480)
- `NativeCSVExport.buildIncomeCsv` (~90-116)
- `NativeAccountingPackage` (`buildInvoicesCsv`, `buildPaymentActivityCsv`, overpayment warning, `summary.json` `cash_collected`, README)
- profitability `feesUnknown`

**Ledger payment wire shape:** `{id, amount, date, method, note?, stripeSessionId?, voidedAt?}`. `amountPaid` sums `amount`, so a TIP MUST BE A SEPARATE FIELD (e.g. `tipAmount` on the payment entry, which rides the union trigger) and never part of `amount`.

## Legal / privacy
- `tradeready-legal/privacy.html` §1 (~106-115), §4 Stripe (~132).
- `terms.html` §4 Payment Processing (~121-122), §8 e-sign consent precedent (~141-142).
- `PrivacyInfo.xcprivacy` declares OtherFinancialInfo (Analytics) and PurchaseHistory; no PaymentInfo.
