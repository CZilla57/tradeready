# Tips on Online Payments (Roadmap Phase 28) — Design Spec

**Date:** 2026-10-03
**Status:** SCOPED. Builds on `feat/tips`, stacked on `feat/autopay` (Phase 24, `2026-10-03-card-on-file-autopay-design.md`), which is stacked on the earlier build-order branches. In `CZilla57/tradeready-legal` the `pay.html` changes go on a `feat/tips` branch on top of that repo's `feat/autopay`. Owner go-ahead 2026-10-03: "continue working until all features on the roadmap are properly completed … implemented in the most beneficial way to the user". The code map was verified 2026-10-03 against the main checkout on `feat/quote-expiration` (HEAD `e922d51` plus another agent's uncommitted Phase 32 work). Line numbers in `AppStore.swift` and `SettingsView.swift` will drift.
**Origin:** `docs/post-launch-feature-roadmap.md` Phase 28, build order #8 ("None (existing Stripe)"), "consider bundling with #24".
**Builds on:**
- the Phase 24 pay page and per-visit Checkout Session (autopay spec §1, §4.2–§4.5): this phase adds a step to it
- the payment ledger (`2026-07-18-deposits-partial-payments-design.md`)
- cash-basis Money and the tax set-aside
- CSV export (`2026-07-31-csv-export-design.md`) and the accountant package (`2026-08-07-accountant-package-design.md`)

**Build target:** the native SwiftUI app, the Worker, and `pay.html` in `tradeready-legal`. **No React Native changes. No migration.** The dormant Vercel twin is not changed.

## 0. Preconditions verified against the repo

`N/` means `native/TradeReadyNative/`. `W/` means `backend-workers/`. The Stripe facts shared with Phase 24 are in autopay spec §0.

### 0.1 Why a tip can't ride today's links

- **Each link charges exactly what was minted.** A Payment Link has one fixed-price line item (`W/src/routes/createPaymentLink.js:97-121`).
- **The webhook books the whole session as an invoice payment.** It books `amount_total/100` as the payment `amount` (`W/src/routes/stripe/webhook.js:172`, `:189-195`) and never reads line items. A tip on today's path would be recorded as an invoice payment and make the invoice **overpaid**.
- **Every "paid" figure sums the payment `amount`:**
  - Worker: `amountPaid` sums `amount` (`W/lib/paymentMath.js:43-49`).
  - Native: `PaymentLedger.amountPaid` (`N/Domain/FinancialDomain.swift:379-386`) and `overpaidAmount = amountPaid − amount` (`:400-402`).
  - The accountant package warns on any overpayment (`N/Domain/NativeAccountingPackage.swift:229-232`).
  - **A tip therefore must be a separate field on the payment entry and never part of `amount`.**
- **A new key on a payment entry survives every writer:**
  - The union trigger keeps the winning entry as a whole JSON object (`supabase/migrations/20260718_invoice_payment_merge.sql:97-134`), so `tipAmount` rides through.
  - Native keeps unknown payment keys (`N/Domain/CanonicalModels.swift:1154-1173`; UI edits merge from the baseline JSON at `N/Domain/UIModelAdapters.swift:896-907`, `:1213-1223`).
  - RN spreads payment objects (`utils/invoicePayments.ts:223-226`).
  - Money readers still need a **typed** field to see it.

### 0.2 Who reads payments (native)

| Reader | Location | Today |
|---|---|---|
| Cash-basis collected | `N/Domain/NativeCashBasis.swift:224-243` (ledger mapping), `:257-264` (`collected`), `:267-283` (`collectedByPeriod`) | Σ non-voided `amount` |
| Ledger collected (tax path) | `N/Domain/FinancialDomain.swift:470-480` | Σ non-voided `amount` |
| Tax set-aside | `TaxEstimateEngine.summarize` (`FinancialDomain.swift:740-785`), called from `NativeMoneyCardModels.swift:880` and `NativeBusinessSnapshot.swift:177` | `collectedIncome = PaymentLedger.collected` |
| Money summary (income / profit) | `NativeMoneyCardModels.swift:120`, `:128` | `NativeCashBasis.collected` |
| Money income chart / trend | `NativeMoneyCardModels.swift:208`, `NativeMoneyReports.swift:344` | `collectedByPeriod` |
| Coach revenue series | `NativeBusinessSnapshot.swift:110` | `collectedByPeriod` |
| Revenue by customer / top customers | `NativeMoneyReports.swift:296`, `NativeMoneyReportsReadModels.swift:22` | per-invoice `collected` |
| Lead-source report (control total = `collected`) | `NativeLeadSourceReport.swift:22`, `:126` | per-invoice `collected` |
| CSV income export | `NativeCSVExport.swift:97-117` | one row per payment |
| Accountant package | `NativeAccountingPackage.swift`: invoices CSV `:85-115`, payment activity `:132-153`, warnings `:229-232`, summary `:269-299`, `summary.json` `:303-320`, README `:334-360` | payment rows; `cash_collected = NativeCashBasis.collected` |
| Job profitability | `FinancialDomain.swift:850-871` (`fees_unknown` on Stripe payments) | `amountPaid` |
| Payment history UI | `N/InvoicesView.swift:399-401`; UI `Payment` at `N/Models.swift:97-104` | amount, method, note |

### 0.3 Settings and the Worker

- **Settings is a synced blob** (`Canonical.Settings`, `CanonicalModels.swift:1596+`). A new optional key needs no migration.
- **The Worker already reads settings server-side** with the service role (`W/lib/sendInvoiceEmails.js:72`). The pay page can therefore read the owner's tip setting at view and checkout time.
- **Where the toggle goes.** The Stripe section of Settings is at `N/SettingsView.swift:516-545`.

### 0.4 What the pinned Stripe version actually offers for tips (checked, not assumed)

| Mechanism | Finding | Source |
|---|---|---|
| Customer-chosen price (`custom_unit_amount`) on a Payment Link or Checkout Session | **"You can't add any other line items and the quantity can only be 1."** It also can't be combined with optional items. A tip can't sit next to the fixed invoice line | [Pay what you want](https://docs.stripe.com/payments/checkout/pay-what-you-want?payment-ui=stripe-hosted) |
| `optional_items` on Checkout | **Absent from SDK 16.12.0's types** (checked in `node_modules/stripe/types/Checkout/SessionsResource.d.ts`). The current reference lists it, but it takes Prices, so preset amounts only. Using it would mean an SDK bump | [Create a Checkout Session](https://docs.stripe.com/api/checkout/sessions/create) |
| Adjustable quantity on a "$1 tip" item | Possible, but the customer would see "Tip × 15". Rejected on UX | same |
| Stripe tipping features | Terminal (in-person readers) only | [Collect tips](https://docs.stripe.com/terminal/features/collecting-tips/overview) |
| Inline `price_data` line items on a Checkout Session | Supported. Any number of server-priced lines, with no persistent Product or Price | [Create a Checkout Session](https://docs.stripe.com/api/checkout/sessions/create), [Direct charges](https://docs.stripe.com/connect/direct-charges?platform=web&ui=stripe-hosted) |
| Stripe's rule for tips | "a tip must be given for a good or service that has been provided" | [Requirements for accepting tips](https://support.stripe.com/questions/requirements-for-accepting-tips-or-donations) |

**Verdict:** the pinned API supports tips only as a **second inline line item on a Checkout Session the server creates after the customer picks the tip**. That is exactly the Phase 24 pay-page flow. No version bump, no SDK bump, no new dependency, no Dashboard setting, no new webhook event.

### 0.5 Privacy manifest

`N/PrivacyInfo.xcprivacy:87-98` declares OtherFinancialInfo for **Analytics only**. Invoice and payment amounts are already synced for app functionality, so this is a pre-existing gap. Tips don't add a data category (§7).

## 1. Recommendation

The customer picks an optional tip on the TradeReady pay page. The Worker adds it to the Checkout Session as a second line item, "Tip". The webhook records it on the **same** ledger entry, as `tipAmount`, with `amount` holding only the invoice portion.

So:
- the balance, paid, overpaid, reminder, portal and PDF logic is **untouched by construction**
- income, cash and tax surfaces add tips explicitly

**Options considered**

| Option | Verdict |
|---|---|
| **A. Tip step on the pay page → second inline Checkout line item (chosen)** | Clear UX; exact split known server-side; no Stripe objects per link |
| B. A custom-amount Payment Link whose excess over the balance counts as the tip | The amount field would be the invoice, not a tip, so the UI is confusing. The split is inferred, not chosen. A typo becomes a "tip". Rejected |
| C. `optional_items` with preset tip prices | Needs an SDK bump (owner approval) and preset amounts only. Rejected |
| D. "$1 × quantity" tip item | Customer-hostile display. Rejected |
| E. A separate "add a tip" link after payment | A second card entry and a second fee; rarely completed. Rejected |

## 2. Owner setting

- **`Settings.tipsEnabled: Bool?`** Absent or false = off (the default). It is typed in `Canonical.Settings` and has an encode/decode round trip.
- **UI.** In Settings → Payments → STRIPE (`N/SettingsView.swift:516-545`), shown only when Stripe is connected:
  - Toggle **"Let customers add a tip"**.
  - Caption: "Customers paying an invoice online can add an optional tip (10%, 15%, 20% or their own amount). Tips are recorded separately from the invoice and count as income. Not offered on deposits or automatic payments."
- **No presets setting in v1.** Fixed presets keep Settings small (§11 T4).

## 3. Customer experience (`pay.html`, `t` mode)

**When it is offered:**
- `tipsEnabled === true`
- the payment is for the **full remaining balance**, not a deposit (`a` absent or ≥ balance − 0.005)
- the invoice is unpaid

**When it is never offered:**
- on setup or manage pages
- on autopay charges, where the customer isn't present
- on the legacy Payment Link fallback path

**Deposits are excluded** because Stripe ties tips to service already provided (§0.4).

**The tip step**, above the Pay button:
- Heading: "Add a tip for {Business}? (optional)"
- Choices: **No tip** (selected by default) · 10% ($12.00) · 15% ($18.00) · 20% ($24.00) · Custom
- **Preset amounts** are a percent of the amount being paid, rounded half-up to cents.
- **Custom** is a dollar field. Validation: 0.01 ≤ tip ≤ the amount being paid; above that it says "That's more than the invoice. Please check the amount."
- A running total: "Invoice $120.00 · Tip $18.00 · **Total $138.00**". The button reads "Pay $138.00".
- **With the Phase 24 autopay box ticked**, one line is added under the tip: "Tips apply to this payment only. Automatic payments never include a tip."

**On Stripe Checkout:** the order summary lists "Invoice INV-12 $120.00" and "Tip $18.00".

**Return page** (`view` with `session_id`): "Payment received. Thank you! You paid $138.00: $120.00 for invoice INV-12 and an $18.00 tip."

## 4. Worker

### 4.1 `GET /api/pay/view` (`p` kind)

- Adds `tips: null | { presetsPercent: [10, 15, 20], baseAmount }`. `baseAmount` is the amount being paid.
- The return-path `receipt` block gains `invoiceAmount` and `tip`.
- The exact-key test is updated.

### 4.2 `POST /api/pay/checkout`

- **Accepts** `tipCents` (integer, optional, default 0).
- **Re-reads `tipsEnabled`.** If tips were turned off since the page loaded, it returns 409 "Tips are no longer offered. Please reload."
- **Refuses a tip** on a deposit, or when `tipCents > invoiceCents`.
- **When `tipCents > 0`:**
  - adds `{price_data: {currency: 'usd', unit_amount: tipCents, product_data: {name: 'Tip'}}, quantity: 1}`
  - sets `metadata.tr_tip_cents`
  - includes `tipCents` in the idempotency key
- Everything else is the Phase 24 flow: one open session per invoice, card only, 30-minute expiry.
- Session metadata is server-set, so the split never depends on client-supplied data at webhook time.

### 4.3 Webhook split (`checkout.session.completed`, paid)

```
invoiceCents = int(metadata.tr_invoice_cents); tipCents = int(metadata.tr_tip_cents || 0)
if (both parse && invoiceCents + tipCents === session.amount_total):
    amount = invoiceCents / 100; tipAmount = tipCents > 0 ? tipCents / 100 : (omit)
else:                                   # legacy Payment Link sessions, or (never expected) a mismatch
    amount = session.amount_total / 100 # today's behavior; log 'tip_split_mismatch' when tr_ keys were present
```

- The entry is written through `recordStripePayment` with `extra.tipAmount` (autopay spec §4.1). Its id stays `stripe_<session.id>`, so TH-9 is unchanged.
- The mismatch path never loses money: it books everything as the invoice payment, which at worst shows as overpaid for the owner to correct.
- `paid` / `paidAt` are computed from `amount` only, through the unchanged `paymentMath.js`. **No server math change**, so the paymentMath parity test is untouched.

### 4.4 Receipt

The Phase 24 payment receipt email (autopay spec §4.7) itemizes:
- Invoice payment $120.00
- Tip $18.00
- Total charged $138.00
- Card Visa •••• 4242
- Remaining balance $0.00

It is sent once, on the `appended` outcome, to the Checkout-entered email.

## 5. Data model (no migration)

```ts
// Ledger payment entry (invoices.data.payments[]):
//   amount: number      — invoice portion only (unchanged meaning)
//   tipAmount?: number  — dollars, > 0, 2 dp; absent = no tip. Written only by the Stripe webhook.
// Settings blob:
//   tipsEnabled?: boolean — absent/false = off
```

**Voiding.** Voiding a payment voids its tip too (`voidedAt` covers the whole entry). That matches a full refund. A tip-only refund isn't modelled; the app has no refund concept (accountant README).

## 6. Native

### 6.1 Models

- `Canonical.Payment.tipAmount: Decimal?` is typed. The decoder and encoder add one optional key, and preservation is unchanged.
- `Canonical.Settings.tipsEnabled: Bool?` is typed.
- UI `Payment` (`N/Models.swift:97-104`) gains `tip: Double?`. The adapter maps it, and nothing in the UI edits it. The merge-from-baseline path (`UIModelAdapters.swift:1213-1223`) leaves it untouched, so editing a note or voiding keeps the tip.
- `LedgerPayment` (`FinancialDomain.swift:346-354`) gains `tip: Decimal? = nil`. `NativeCashBasis.ledgerInvoice` (`NativeCashBasis.swift:224-243`) maps it. The other mapping sites leave it nil, because they only compute balances.

### 6.2 Ledger math

- **Unchanged:** `amountPaid`, `balanceDue`, `isFullyPaid`, `overpaidAmount`, `derivingPaidFields`, `merge`. New tests pin that a tip never changes any of them.
- **New:**
  - `PaymentLedger.tips(from:from:through:)`
  - `PaymentLedger.received(from:from:through:)` = collected + tips, non-voided only
  - `NativeCashBasis.tipsCollected(invoices:start:end:)`, `received(invoices:start:end:)`, `receivedByPeriod(invoices:ranges:)`, sharing the FA-039-safe local-date filter

### 6.3 Surfaces

The principle: **income, cash and tax surfaces count tips. Invoice, receivables and customer-attribution surfaces don't.**

| Surface | Change |
|---|---|
| Money summary card (`NativeMoneyCardModels.swift:120`, `:128`) | Income = `received`; net profit follows. When tips > 0, a caption reads "Includes $Y in tips" |
| Money income chart / trend (`:208`, `NativeMoneyReports.swift:344`) | `receivedByPeriod` |
| Tax set-aside (`TaxEstimateEngine.summarize`, `FinancialDomain.swift:763-767`) | `collectedIncome = PaymentLedger.received`. Tips are business income. The card and the coach tax block follow automatically (`NativeMoneyCardModels.swift:880`, `NativeBusinessSnapshot.swift:177`) |
| Coach revenue series (`NativeBusinessSnapshot.swift:110`) | `receivedByPeriod` |
| Revenue by customer, top customers, lead-source report | **Unchanged** (`collected`). The lead-source control total still equals `NativeCashBasis.collected` |
| Invoice paid / balance / overpaid, PDF, portal, reminders, Today | **Unchanged** |
| Job profitability | **Unchanged** (§10) |
| Payment history (`N/InvoicesView.swift:399-401`) | Row reads "$120.00 · Stripe · + $18.00 tip"; VoiceOver: "plus 18 dollars tip" |
| CSV income export (`NativeCSVExport.buildIncomeCsv`, `:97-117`) | After each payment with a tip, an extra row: same Date / Customer / Invoice # / Description / Method, Note "Tip", Amount = tip. The header is unchanged, and Σ Amount = cash actually received |
| Accountant `active-payments.csv` | Same builder, same tip rows |
| Accountant `payment-activity.csv` (`:132-153`) | Tip rows with Source `tip`. A voided payment's tip row shows Voided = Yes |
| Accountant `invoices.csv` | **Unchanged.** Amount Paid excludes tips, so invoice totals reconcile |
| `summary.json` (`:269-299`, `:303-320`) | `cash_collected` = `received` (it matches Σ active-payments rows again). New key `tips_collected`, emitted **always** right after `cash_collected`, so the schema is stable. `net_cash` follows |
| README (`:334-360`) | New line: "Tips appear as separate rows with Note "Tip". They are income but not invoice payments, so invoices.csv Amount Paid excludes them." |
| Export warnings | None new. A tip can never trigger `overpayment_present` |

**Parity.** The accountant package and CSV now diverge from RN bytes whenever tips exist, and `summary.json` always gains `tips_collected`. Record this as an intentional difference in `docs/native-parity-matrix.md` (Accountant package and CSV rows), following the Phase 27 `Lead source` precedent.

### 6.4 Settings UI

See §2. The toggle is written through the existing settings save path and pushed with the settings blob.

## 7. Legal and store

- **Stripe's tip rule is met by design:** tips only on final invoice payments for completed work, never on deposits (§3).
- **Terms.** `terms.html` §4 already covers payments through Stripe. **No change is required.** If the owner wants it explicit, the optional sentence is: "Tips your customers add through a TradeReady payment page are paid to you with the payment; TradeReady takes no share." (Q2)
- **Privacy.** Tips are payment amounts on invoices, already covered by "App data: … invoices" (`privacy.html` §1). No change.
- **App Store privacy label.** Tips add no data type. The pre-existing OtherFinancialInfo purpose gap is Q1.

## 8. Testing

**Worker** (node:test, fake Stripe; extends the Phase 24 suites):
- `payView.test.cjs`: `tips` block present only when enabled + full balance + unpaid; absent for deposits and other kinds; receipt split.
- `payCheckout.test.cjs`:
  - tip line added only when `tipCents > 0`
  - cap and deposit refusals
  - 409 when tips were turned off mid-session
  - metadata and idempotency key include the tip
- `stripeWebhookTips.test.cjs`:
  - split booked as `amount` + `tipAmount`
  - zero tip omits the key
  - legacy session with no `tr_` keys → today's whole-amount behavior
  - mismatch → whole amount + log
  - `paid` derived from `amount` only (an invoice paid exactly with a tip is not overpaid)
  - duplicate delivery → no second entry, no second receipt
- `autopayEmails.test.cjs`: receipt itemization with and without a tip.

**Native:**
- New `native/TipsTests/main.swift` + `run-tips-tests.sh`, registered in `run-all-domain-tests.sh`:
  - ledger invariants with tips: balance, paid, overpaid, merge unchanged
  - `tips` / `received` / `receivedByPeriod`, including voided tips excluded and Phoenix local-date range edges
  - CSV tip rows (ordering, header unchanged, Σ Amount = received)
- Updated suites:
  - Canonical (`tipAmount` and `tipsEnabled` round trip + preservation; an unknown key next to `tipAmount` survives)
  - adapters (note edit and void keep the tip)
  - Money cards (income caption)
  - tax (income includes tips)
  - business snapshot
  - accounting package (tip rows, `tips_collected` always present, `cash_collected` = Σ active rows, README)
  - CSV export
  - lead-source control total unchanged with tips present

**Gates:**
- `sh native/run-all-domain-tests.sh`, the Release compile
- `cd backend-workers && npm test`
- targeted Jest under `TZ=America/Phoenix`
- `sh native/run-doc-reference-check.sh`

**Owner test-mode smoke:**
- pay with a 15% tip → one ledger entry (`amount` + `tipAmount`), invoice paid (not overpaid), Money income includes the tip, the CSV has the tip row
- deposit link → no tip step
- toggle off → no tip step

## 9. Rollout (owner ship steps)

1. **Phase 24's steps 1–6 must be done**, so the pay page is live.
2. **Deploy the Worker.** It is inert until an owner sets `tipsEnabled`, which only the new native build can do.
3. **Publish `pay.html`** with the tip step. The view's `tips` block is null until the setting is on, so the order of 2 and 3 doesn't matter.
4. **Ship the native build.** The toggle, the reader of `tipAmount` and the Money changes ship together. A tip can therefore never be recorded before a build that shows it, except on a second device still running an older build (§10).

Nothing here is deployed, published or pushed by the build session.

## 10. Accepted residuals

- **Older builds on another device and RN ignore `tipAmount`.** They preserve it, but their Money and tax figures under-count tips until they update.
- **No manual tip recording** (a cash tip at the door). The owner can record it as a separate manual payment today, but that counts as an invoice payment. A "Tip" field on the record-payment sheet is a small follow-up.
- **No tips on deposits or autopay**, by design (§3).
- **Tip refunds** aren't modelled. Voiding the payment voids the tip with it.
- **Job profitability excludes tips.** A per-job "tips received" line is a follow-up. Stripe's fee on the tip is covered by the existing `fees_unknown` warning.
- **The coach doesn't name tips.** Its revenue series and tax block include them.
- **Fixed presets** (10 / 15 / 20 %). Configurable presets are a follow-up if owners ask.

## 11. Decisions made by recommendation (owner may override)

| # | Decision | Choice |
|---|---|---|
| T1 | Collection mechanism | Tip chosen on the TradeReady pay page, added as a second inline Checkout line item "Tip" (custom amounts, `optional_items` and the quantity hack were rejected after checking the pinned API) |
| T2 | Owner setting | `Settings.tipsEnabled`, default off, in Settings → Payments → STRIPE |
| T3 | When tips are offered | Final full-balance invoice payments only. Never deposits, setup, manage, autopay or legacy links |
| T4 | Presets | No tip (default) / 10% / 15% / 20% of the amount being paid / Custom; capped at 100% of the payment |
| T5 | Recording | `tipAmount` on the same ledger entry; `amount` = invoice portion; split from server-set session metadata checked against `amount_total`; mismatch → today's whole-amount booking |
| T6 | Money / tax | Income, cash and tax surfaces use `received` (payments + tips). Invoice, receivables, customer and lead-source surfaces stay on invoice payments |
| T7 | Exports | Tip rows in income / active-payments / payment-activity CSVs (header unchanged); `summary.json` `cash_collected` = received plus an always-present `tips_collected`; README line |
| T8 | Customer receipt | The Stripe Checkout summary shows the "Tip" line; the pay-page return screen and the TradeReady receipt email itemize invoice / tip / total |
| T9 | Void semantics | Voiding a payment voids its tip |
| T10 | API / SDK / dependencies / Dashboard / webhook events / migration | None |

## 12. NEEDS OWNER APPROVAL

| # | Question | Recommended answer |
|---|---|---|
| Q1 | **App Store privacy label (pre-existing gap, surfaced here).** `PrivacyInfo.xcprivacy` declares OtherFinancialInfo for Analytics only, but invoice and payment amounts (and now tips) sync for app functionality. Add the **App Functionality** purpose to OtherFinancialInfo in the manifest and the App Store Connect label? | **Yes**, at the same label update as autopay's Q5. Tips themselves add no new data type. |
| Q2 | **Terms of Service.** Add the optional sentence "Tips your customers add through a TradeReady payment page are paid to you with the payment; TradeReady takes no share." to `terms.html` §4? | **Not required.** The existing §4 covers it. Add it only if you want the no-share point explicit. |

Everything else in this phase is decided by recommendation (§11). It needs no migration, API or SDK bump, new dependency, Stripe setting, or new webhook event.

## 13. Build record (2026-10-03)

### Worker and pages

#### 13.1 Contract for the native client (settled first)

No new app-facing route. The app and the Worker meet in two synced blobs.

**Owner setting: how it reaches the Worker.** The app writes `tipsEnabled` into its existing settings blob, and the existing settings sync pushes it to Supabase `settings.data` (one row per user). The Worker reads that row with the service role at `GET /api/pay/view` and again at `POST /api/pay/checkout` (`W/lib/autopay/store.js` `fetchSettings`). There is no separate endpoint, cache or webhook.

```json
// settings.data (excerpt)
{ "businessName": "Rector HVAC", "tipsEnabled": true }
```

- The key is exactly `tipsEnabled`, a JSON boolean. Only `true` turns tips on. Absent, `false`, `null`, `"true"` or `1` all mean off.
- Turning it off takes effect on the next page load. A page that was already showing the tip step gets 409 `tips_off` ("Tips are no longer offered. Please reload.") when the customer clicks Pay with a tip. A payment with no tip still goes through.
- Encode it only when the owner has set it, or always as a boolean. Both are fine. Never encode it as a string.

**Ledger entry with a tip** (`invoices.data.payments[]`, written only by the Stripe webhook, `W/src/routes/stripe/webhook.js` → `W/lib/stripe/recordPayment.js`):

```json
{
  "id": "stripe_cs_test_a1B2c3",
  "amount": 120,
  "date": "2026-10-03",
  "method": "stripe",
  "stripeSessionId": "cs_test_a1B2c3",
  "tipAmount": 18
}
```

- `amount`: the invoice portion only, in dollars. Its meaning is unchanged, and it is the only field the balance, `paid`, `paidAt` and overpaid math reads (`W/lib/paymentMath.js` is unchanged).
- `tipAmount`: the tip in dollars, a JSON number `> 0` with at most 2 decimal places (it is `tipCents / 100`, for example `18`, `12.34` or `0.5`). It is **absent** when there is no tip. It is never `0` and never `null`. Decode it through the same path as `amount` and round to cents.
- `id` is `stripe_<Checkout Session id>`, exactly as before (TH-9 unchanged). One Checkout payment is always one entry, and the tip is never a second entry.
- `date` is the UTC date the webhook ran (unchanged Phase 24 behavior). `method` is `"stripe"`.
- Voiding (`voidedAt`) voids the tip with the payment. The Worker never writes `voidedAt`.
- `tipAmount` appears only on pay-page payments (`stripeSessionId` set). It never appears on autopay entries (`channel: "autopay"`), legacy Payment Link entries, or manual entries.
- The cached `paid` / `paidAt` on the invoice blob are derived from `amount` only. An invoice paid exactly, with a tip on top, is `paid: true` and not overpaid.

#### 13.2 Checkout rules the Worker enforces (`POST /api/pay/checkout`)

Recorded after review; the code is `W/lib/pay/payService.js`. The native client and `pay.html` meet these responses.

| Request | Response | Notes |
|---|---|---|
| `baseCents` present and not equal to the amount the Worker would charge now | 409 `changed` | `baseCents` is optional. The page sends the amount it based the tip on, so a balance that moved since the page loaded (a part-payment, an edit) cannot carry a tip computed from the old amount. Absent, it is not checked. The tip is still capped against the live amount. |
| `tipCents` malformed (negative, fractional, a string, boolean, object, array, `NaN`, or above `MAX_CENTS`), or above the invoice amount being paid | 400 `tip_invalid` | Checked before any Stripe call. 100% of the amount is allowed, one cent more is not. `null`, absent and `0` mean no tip and never fail, even when tips are off. |
| `tipCents > 0` while `tipsEnabled` is not `true`, or on a link that offers no tip | 409 `tips_off` | See §13.1 for the setting. |

- **A link minted as a deposit never offers a tip, even after the deposit is paid.** A link stamped as a partial ask (`b` in the token payload; or an `a` below the live balance) charges the live balance once the deposit is paid, but it is still a deposit link: the view returns `tips: null` and a checkout with `tipCents > 0` gets 409 `tips_off`. The same link without a tip still pays the balance. The customer who wants to tip uses the full-balance link.
- **One payment in flight per invoice.** Before it creates a session, checkout lists the owner's completed Checkout Sessions (the helper in `W/lib/autopay/sessions.js`, the same call and 8-day window the autopay sweep uses) and refuses with 409 `in_flight` when one for this invoice has no `stripe_<session id>` ledger entry yet: the customer paid and the webhook has not booked it. Without this, a second checkout with a different tip got a fresh idempotency key and a second session, and the invoice ended up overpaid. A completed session that is booked does not block a later payment of a remaining balance. The response is the one the page already shows for an autopay charge in flight; its text no longer says "automatic" ("A payment for this invoice is being processed. Please check back in a few minutes.").
- **Replayed sessions are checked live.** Stripe replays the cached original create response for a repeated key, and that response says `open` even after the session was expired. Switching the tip A, then B, then A inside one 10-minute bucket therefore returned A's dead session. After every create the Worker retrieves the session's live status (if that read fails it uses the create response); an expired session is replaced under `<key>:r<last 12 chars of the dead session id>`, up to three times, and a session that completed gives 409 `maybe_paid`. Two identical requests still share one session: the key is deterministic, and `expireOtherOpenSessions` leaves `<key>` and `<key>:r…` sessions alone.

**Fixes 2026-10-04.** The two behaviors above (in-flight refusal on an unbooked completed session; live-status check with a fresh key on a replayed expired session) were added after the Phase 28 review, with the `in_flight` text change. No contract change for the ledger entry or the view.
