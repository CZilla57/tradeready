# Referral Program (Roadmap Phase 34) — Design Spec

**Date:** 2026-10-03
**Status:** BUILT 2026-10-03; verified, reviewed and committed 2026-10-12 on local `feat/referrals`, stacked on `feat/properties-equipment`. Gate green on its own branch tip against the master baseline (accessibility-audit and layout-metrics fail on master too); Worker `npm test`, doc reference check and the Release compile pass. Independent review: no P1/P2; one P3 left for an owner rule (a referral re-pointed or removed after its credit is applied can double-credit; see the roadmap ledger). Nothing pushed, deployed or applied. Build record: §10.
**Origin:** `docs/post-launch-feature-roadmap.md` Phase 34, build order #6 (needs #27)
**Builds on:** lead source (`2026-10-02-lead-source-design.md`), booking link (`2026-08-04-booking-link-design.md`, `2026-08-07-calendar-availability-booking-design.md`), review requests, customer merge, invoice-from-job, Today insights, coach grounding
**Build target:** native SwiftUI app, the Worker, and `book.html` in `CZilla57/tradeready-legal`. **No React Native changes. No migration. No deploys.**

## 0. Preconditions verified against the repo

Phase 27 state is read from the uncommitted working tree, and §5–§6 of the lead-source spec are designed against the spec, not the in-progress files. `N/` means `native/TradeReadyNative/`.

**Worker and public pages**
- The booking validator is a whitelist. Phase 27 adds `cleanLeadSource` after the `CAPS` loop and sets the key only when it is non-empty (`backend-workers/lib/booking/validate.js:5,13-24,36-37`). A `referralCode` is dropped today.
- `submit` and `reserve` spread `checked.value` into the stored blob (`backend-workers/src/routes/booking/submit.js:49-54`, `backend-workers/lib/booking/reserve.js:106-122`). The claim RPC stores `p_request` verbatim (`supabase/migrations/20260920_booking_lifecycle_rpcs.sql:373`), so neither route needs edits.
- No public response echoes request fields:
  - `config` returns only `businessName` (`backend-workers/src/routes/booking/config.js:34`).
  - `submit` returns `{ ok: true }` (`submit.js:69`).
  - `reserve` returns `{ ok, manageToken, slot }` (`reserve.js:165,198`).
  - Manage GET returns `businessName`, `status` and `slot` only (`backend-workers/lib/booking/manage.js:53-59`). Its legacy write spreads `...row.data`, so unknown keys survive.
  - The portal takes only the customer's name from the customer blob (`backend-workers/lib/estimate/portalAssemble.js:198`) and job titles (`:69`), never notes.
- The booking token is a 48-hex capability minted server-side (`backend-workers/src/routes/booking/mint.js:35`) and resolved through the adoption-gated state table (`backend-workers/lib/booking/store.js:46-73`). Rotating it kills every URL that carries the old `b`.
- `book.html` reads `?b=`, and Phase 27 adds `?src=` with a comment that reserves `?r=` (`tradeready-legal/book.html:55-60`). `contactPayload()` (`:143-152`) feeds both `submitRequest` (`:169-190`) and `submitReserve` (`:235-273`). The page renders nothing from the URL except what `config` returns.
- `tradeready-legal/_headers` says Referrer-Policy is injected at the platform level. The CSP needs no change because there are no new hosts.

**Native**
- `NativeBookingAdministrationService.bookingURL(token:)` builds `https://gettradereadyapp.com/book.html?b=<token>` (`N/NativeBookingAdministration.swift:135,437-443`). `isValidBookingURL` checks only `b` and tolerates extra params (`:445-458`).
- Links are shared only after a fresh verified status read (`AppStore.reconcileBookingLinkForSharing`, `N/AppStore.swift:11018-11038`). The settings screen never shares a stale token (`N/NativeBookingSettingsView.swift:131-145,209-216`). The rotate dialog copy is at `:89`.
- The device has a CSPRNG: `SecRandomCopyBytes` plus base64url in `N/NativeAppleSignIn.swift:18-35` and `N/NativePasswordRecovery.swift:72-81`. The booking-link spec's "the device has no secure RNG" note is about RN, not Swift.
- `Canonical.Customer` (`N/Domain/CanonicalModels.swift:1242-1279`) and `Canonical.BookingRequest` (`:1372-1424`) carry Phase 27's `leadSource` as typed optionals. Merge copies structs and drops a deleted loser's unknown keys (Phase 21 spec §0), so every new field must be a typed property.
- Booking intake:
  - Portal requests link by `sourceCustomerId`; everything else goes through a name-keyed upsert (`N/Domain/NativeBookingIntake.swift:119-142`).
  - `leadSourceCandidate(for:)` is at `:197-200`.
  - `upsertCustomer` fills blanks first-touch (`:218-257`).
  - `NativeScheduleBookingPolicy.recheckedIntakePlan` repeats the fills (`N/NativeScheduleBookingStore.swift:283-376`).
- Merge and delete:
  - Merge hard-deletes the loser (`N/NativeCustomerIdentity.swift:471`) and re-points jobs, invoices and recurring records. Nothing re-points a reference from one customer to another today.
  - Customers can also be deleted outright (`N/AppStore.swift:4182`).
- Review request:
  - `NativeReviewRequests.buildMessage` renders the template (`N/NativeReviewRequests.swift:92-114`).
  - The sheet holds an editable `message` and sends only through the system composer (`N/NativeReviewRequestView.swift:55-65,115-135`).
  - `AppStore.reviewRequestDraft` carries `customerID` (`N/AppStore.swift:1474-1514`).

**Money**
- Payments are cash:
  - `PaymentLedger.amountPaid` sums non-voided payments (`N/Domain/FinancialDomain.swift:379-386`).
  - `NativeCashBasis.collected` (`N/Domain/NativeCashBasis.swift:257`) feeds Money, the lead-source report and tax set-aside.
  - So a credit recorded as a payment would overstate all three.
- Negative invoice lines already exist. Approved descope change orders become `"Change order — <title>"` lines with negative amounts (`N/Domain/JobInvoiceDomain.swift:261-265`, `N/NativeChangeOrders.swift:272-277`). They render cleanly everywhere:
  - The PDF prints each line, with `invoice.amount` as the total (`N/NativeInvoicePDF.swift:51-59`).
  - The line-items CSV prints the category verbatim (`N/Domain/NativeAccountingPackage.swift:117-129`).
  - The invoice email lists the lines (`backend-workers/lib/invoiceEmail.js:30-38`).
  - Nothing enforces Σ lines == amount.
- Invoice-from-job:
  - It recomputes lines from the job on every save. In finalize mode it replaces the existing invoice's lines (`N/AppStore.swift:1679-1722`).
  - `canSave` requires `amount > 0` (`N/NativeCreateInvoiceFromJobView.swift:21-23`).
- A `marketing` expense category exists (`N/Domain/NativeCSVExport.swift:20`).

**Reports, insights and coach**
- The lead-source report attributes invoices by id first. It falls back to the normalized name only when every customer with that name shares a bucket (`NativeLeadSourceReport.Attribution`, `N/Domain/NativeLeadSourceReport.swift:182-214`, in progress).
- Today insight kinds are at `N/Domain/NativeTodayInsights.swift:17-26`, with selection order at `:125-148`. The muteable set and icons are at `N/Domain/NativeInsightsCardPolicy.swift:18-20,38-49`. Phase 21 adds `warrantyExpiring`.
- The coach already names top customers (`N/Domain/NativeCoachPrompt.swift:83-89`) and appends Phase 27's LEAD SOURCES block after the tax block (`:127-131`).

## 1. Recommendation

| Question | Answer |
|---|---|
| Code | One random 80-bit code per customer, stored on the customer as 16 lowercase Crockford base32 characters. It is generated on the device the first time the owner shares that customer's link. |
| Server validation | Format check and pass-through only. The Worker never looks a code up, so it can't leak or confirm who owns one. The device resolves the code at intake. |
| Attribution | First touch: `leadSource = "referral"` plus `referredByCustomerId`. Self-referral is detected. An unknown code still counts as a referral, with no referrer. |
| Owner view | A "Referrals" section on customer detail, a Money "Referrals" card plus a "who referred whom" screen, and a Today "say thanks" prompt after the referred customer's first payment. |
| Sharing | A reviewed composer from customer detail, plus "Add their referral link" in the review request sheet. Never auto-sent. |
| Rewards | (a) A record on each referral. A credit becomes a negative "Referral credit" line through invoice-from-job, only when the owner taps it, and never a payment entry. |
| Coach | Yes. A year-to-date REFERRALS block after LEAD SOURCES, in the same pattern. |

**Why the code is stored on the device and needs no lookup:**
- The code grants nothing. It is an attribution hint, not a capability like the portal token.
- A server lookup has four costs:
  - an unindexed `customers.data->>referralCode` scan on the public path
  - a new failure mode that must never fail a booking
  - a race with codes created on the device but not yet pushed
  - an existence oracle to defend
- The device already holds every code. Resolving at intake costs nothing, and it handles merge aliases and self-referral using customer data the server never sees.

**Why rewards are a record, and a credit is a line rather than a payment:**
- The payments ledger is cash. Recording a credit there would inflate collected, the lead-source "Collected" column and the tax set-aside.
- A negative line lowers `invoice.amount`, so collected cash, tax and the receivable are all right automatically. The PDF, email and CSV already handle negative lines because of descope change orders.
- The one thing to teach the code is that a finalize recompute must keep earlier credit lines.

## 2. Data model

```ts
// Customer (customers.data). All optional, so no migration.
referralCode?: string           // this customer's own code: /^[0-9a-hjkmnp-tv-z]{16}$/
referralCodeAliases?: string[]  // codes inherited from merged-away duplicates (merge only)
referredByCustomerId?: string   // who referred this customer; meaningful only when leadSource == "referral"
referralReward?: {              // the owner's record of thanking the referrer for THIS referral
  kind: "thank_you" | "gift_card" | "invoice_credit" | "other",
  amount?: number,              // > 0; required for invoice_credit, absent for thank_you
  note?: string,                // ≤ 200 characters
  recordedOn: string            // local YYYY-MM-DD
}

// BookingRequest (bookingRequests.data)
referralCode?: string           // from ?r=; format-checked and lowercased by the Worker

// Invoice line item (invoices.data.lineItems[]); no shape change
{ description: "Referral credit — thank you!", amount: -25, category: "referral_credit" }
```

**Swift changes**
- `Canonical.Customer` gains:
  - `referralCode: String?`
  - `referralCodeAliases: [String]?`
  - `referredByCustomerId: String?`
  - `referralReward: ReferralReward?` — a nested `Codable` with `Preservation`, shaped like `Customer.Portal`
- `Canonical.BookingRequest` gains `referralCode: String?`.
- Reader and writer lines follow the `leadSource` pattern.
- UI `Customer` (`N/Models.swift`) gains only `referredByCustomerId: String?`, because the editor sets it. The adapter needs three edits, as for `leadSource`:
  - `canonical(from value:)`
  - `canonical(from edit:)` via `updateOptional(&fields, "referredByCustomerId", …)`
  - `customer(from:)`
- The other three fields stay canonical-only. Only dedicated AppStore entry points write them (§5.2, §5.6), and the edit adapter's baseline merge keeps them across editor saves.

**Invariants**
- **R1:** If `referredByCustomerId` is set, then `NativeLeadSource.normalize(leadSource) == "referral"` and the referrer is not the customer itself. Intake, the editor save plan and merge enforce this. The reports and the insight ignore any record that breaks it.
- **R2:** Every code and alias matches the format and is unique among the owner's customers. Generation checks for collisions; resolution fails closed on a duplicate.
- **R3:** A reward shows only while the customer has a referrer. If the owner changes who referred them, the reward moves with the referral.

There is no settings change, no new table and no migration.

## 3. Worker

`backend-workers/lib/booking/validate.js`:

```js
const REFERRAL_CODE_RE = /^[0-9a-hjkmnp-tv-z]{16}$/;

// Optional referral code (the booking page's ?r= param). An opaque attribution
// tag, not a credential: the Worker never looks it up, so a valid, unknown or
// garbage code behaves identically for the person booking (no oracle).
// Unusable input is dropped, never rejected.
function cleanReferralCode(raw) {
  if (typeof raw !== 'string') return '';
  const code = raw.trim().toLowerCase();
  return REFERRAL_CODE_RE.test(code) ? code : '';
}
// in validateBookingPayload, beside leadSource:
const referralCode = cleanReferralCode(src.referralCode);
if (referralCode) value.referralCode = referralCode;
```

- **`submit` and `reserve`:** no edits, because both spread `checked.value`. Every response body stays byte-identical.
- **`lib/booking/notifyOwner.js` (Worker copy):** when `request.referralCode` is set, both email variants gain the line `Came in through a customer's referral link — open TradeReady to see who referred them.` just before the closing line. The push body is unchanged.
- **Unchanged:** the dormant Vercel twins `backend/lib/booking/validate.js` and `notifyOwner.js`, following the Phase 27 precedent.
- **Not added:** a store function, a lookup or a log line for codes.

## 4. Pages (`tradeready-legal`)

`book.html`. Replace the "(?r= is reserved …)" comment:

```js
// Referral code: a customer's personal link adds &r=<code>. It is opaque and
// never displayed; the Worker format-checks it and the owner's app resolves
// it. Valid, unknown and malformed codes look identical on this page.
var ref = (params.get('r') || '').trim();
// in contactPayload(), after the leadSource line:
if (ref) payload.referralCode = ref;
```

- The page has no visible change, and the `config`/`slots` requests don't change.
- One edit covers request mode, slot mode and the "describe your timing instead" swap.
- `booking.html`, `portal.html`, `estimate.html` and `_headers` are unchanged.

## 5. Native

### 5.1 `N/Domain/NativeReferrals.swift` (new, pure)

This file depends on `CanonicalModels` and `NativeLeadSource` only. Randomness is injected.

```swift
enum NativeReferrals {
    static let codeAlphabet = Array("0123456789abcdefghjkmnpqrstvwxyz")
    static let codeByteCount = 10            // 80 bits
    static let codeLength = 16
    static let creditLineCategory = "referral_credit"
    static let creditLineDescription = "Referral credit — thank you!"
    static let thanksWindowDays = 60

    static func encodeCode(_ bytes: [UInt8]) -> String?      // exactly 10 bytes → 16 chars, MSB first
    static func normalizeCode(_ raw: String?) -> String?     // trim + lowercase + format check
    static func makeCode(existing: Set<String>, randomBytes: (Int) -> [UInt8]?) -> String?
                                                             // ≤ 3 attempts; nil = fail closed
    static func allCodes(in customers: [Canonical.Customer]) -> Set<String>   // codes + aliases
    static func resolveReferrer(code: String?, customers: [Canonical.Customer]) -> Canonical.Customer?
                                                             // exact code/alias match; nil on 0 or >1 matches
    static func isSelfReferral(referrer: Canonical.Customer, matchedCustomerID: String?,
                               email: String, phone: String) -> Bool
    static func referralURL(bookingURL: URL, code: String) -> URL?
    static func renderShareMessage(customerName: String, businessName: String, link: URL) -> String
    static func appendingReferralParagraph(to message: String, link: URL) -> String
    static func creditBalance(referrerID: String, customers: [Canonical.Customer],
                              invoices: [Canonical.Invoice]) -> CreditBalance   // promised, applied, owed
}
```

**Self-referral.** Any of these counts:
- the name-matched customer *is* the referrer
- trimmed, lowercased emails are equal and non-empty
- phone digits are equal (strip non-digits, compare the last 10, require at least 7)

**`referralURL`.**
- Requires a `b` item and no existing `r`.
- Appends `URLQueryItem(name: "r", value: code)`.
- Returns nil unless `normalizeCode(code) == code`.
- `isValidBookingURL` still accepts the result.

**Message copy.**
- Share message: `Hi {customerName}, thanks again for choosing {businessName}! If you know anyone who needs a hand, here's a booking link you can pass along: {referralLink}` followed by a new line and `When they book through it, we'll know they came from you.`
- Review paragraph: `Know someone who could use a hand? Pass along your personal booking link: {referralLink}`
- Appending is a no-op when the message already contains the link. Otherwise it is `trimmed message + "\n\n" + paragraph`.

**Credit balance.** Derived, never stored.
- **promised:** Σ `referralReward.amount` with kind `invoice_credit`, over customers referred by this referrer (R1).
- **applied:** Σ −`amount` of `referral_credit` lines on invoices attributed to the referrer, using the report's id-first / unique-name rule.
- **owed:** `max(0, promised − applied)`.
- Deleting an invoice re-opens its credit. A merge moves both sides to the winner.

### 5.2 Codes and links (`AppStore`)

**Code entry points**
- `referralCode(customerID:) -> String?` reads the code.
- `ensureReferralCode(customerID:) -> String?`:
  - Returns the existing code.
  - Otherwise it calls `NativeReferrals.makeCode`, fed by `SecRandomCopyBytes` in a small `NativeReferralRandom.systemBytes(_:)` (the `NativeAppleSignInNonce` pattern).
  - It writes the canonical customer: `repository.save` → `apply` → `enqueueUpsert(table: "customers", …)`.
  - It runs only after the booking link verifies (below), so codes never exist for customers who were never shared.
- `resetReferralCode(customerID:) -> Bool` generates a new code. The old one is dropped, not aliased.

**`referralShareLink(customerID:) async -> NativeReferralLinkState`**, where `enum NativeReferralLinkState: Equatable { case ready(URL), bookingLinkOff, unverified, unavailable }`:
1. Call `reconcileBookingLinkForSharing()`.
2. A nil status → `.unverified`.
3. No share URL, or `status.enabled != true` → `.bookingLinkOff`. A disabled link would show the new customer "This link is invalid."
4. Otherwise ensure the code and return `.ready(referralURL(bookingURL:code:))`.
5. A missing customer or failed generation → `.unavailable`.

**Rotate dialog copy** (`N/NativeBookingSettingsView.swift:89`): "The current link stops working immediately, including referral links your customers have shared. Share the new link afterwards."

### 5.3 Intake

Add `NativeBookingIntake.referralDecision(for request:, customers:) -> ReferralDecision`, where `ReferralDecision` is `{ leadSource: String?, referredByCustomerId: String? }`. It replaces the direct `leadSourceCandidate` call on the upsert path:

| Request | Source candidate | Referrer candidate |
|---|---|---|
| Portal (`source == "portal"`) | nil (Phase 27) | nil |
| No code, or a code the device's format check rejects | Phase 27: `normalize(leadSource) ?? "booking_link"` | nil |
| Code resolves to R, and the booker *is* R (self-referral) | Phase 27 default | nil |
| Code resolves to R, and the booker is someone else | `"referral"` | R.id |
| Code resolves to nobody (unknown, reset, deleted or ambiguous) | `"referral"` | nil |

- A code wins over `?src=`. The name match for self-referral uses the same `normalizedName` key the upsert uses.
- `upsertCustomer(…, leadSource:, referredByCustomerId: String? = nil, …)`:
  - **Create:** sets both fields. The referrer is set only when the source is `referral`.
  - **Match:** Phase 27 first fills a blank source. Then `referredByCustomerId` fills only when it is blank, the merged source normalizes to `referral`, and the candidate is not this customer. A matched customer with another source keeps both fields (first touch).
- `recheckedIntakePlan` makes the same referrer fill right after its lead-source fill. It is a guarded upsert, so a value set since the plan was built wins.
- Lead jobs are unchanged. No referrer name goes into any job field: the portal shows job titles, and notes are owner-only anyway.

### 5.4 Editor, merge, delete

**Editor (`CustomerEditor`, `N/CustomersView.swift`)**
- When "How they found you" is Referral / word of mouth, a "Referred by" row opens a searchable customer picker:
  - every customer except this one
  - archived customers included and labelled
  - "None"
- `NativeCustomerIdentity.editorSavePlan` clears `referredByCustomerId` when the source isn't `referral` or the value equals the customer's own id.
- This is how most referrals get recorded: by word of mouth, with no link.

**Merge (`NativeCustomerIdentity.merge`)**, after the Phase 27 source fill. The logic stays inline, so `run-customer-identity-tests.sh` gains no source file.
1. **Codes:** the winner keeps `referralCode` and takes the loser's when its own is nil. Every leftover loser code (its code, plus its aliases) goes into `winner.referralCodeAliases`, deduped and sorted.
2. **Referrer:** the winner fills `referredByCustomerId` from the loser only when its own is blank and the post-merge source is `referral`. It is then dropped if it equals `winnerID` or `loserID` (a duplicate that "referred" itself).
3. **Reward:** the winner keeps `referralReward` and takes the loser's when nil and the winner still has a referrer.
4. **Re-point:** every other customer whose `referredByCustomerId == loserID` gets `winnerID`. Each is an upsert in `mutations`.
5. **Undo:** `NativeCustomerMergeUndo.Records` gains `referredCustomers`. Undo restores them under the existing wire-equality guard; any that changed since raise `undoConflict`.

**Delete**
- Deleting a customer does not cascade.
- People they referred keep a dangling `referredByCustomerId`. It reads "Referred by a former customer" and is grouped under "Former customer" in reports.
- Deleting a referred customer removes their reward with them.

**Archive.** An archived referrer's code still attributes bookings, and the referrer shows an "Archived" label.

### 5.5 Sharing

**`N/NativeReferralShareView.swift` (new)** opens as a sheet from customer detail → "Share referral link". It follows the shape of `NativeReviewRequestView`:
- **Recipient:** Text/Email segmented picker.
- **"Referral message":** a `TextEditor` prefilled by `renderShareMessage`.
- **Send:** "Continue to Messages/Mail" (`NativeMessageComposer`) and "Copy for manual sending".
- **Link state** (from `referralShareLink` on appear):
  - while loading: "Checking your booking link…"
  - `.bookingLinkOff`: "Turn on your booking link in Settings → Booking link to share referral links."
  - `.unverified`: "Couldn't verify your booking link. Check your connection and try again." plus Retry
  - `.ready`: the editor and send buttons are enabled
- **Footer:** "Nothing is sent automatically. People who book through this link never see who referred them."
- A send records nothing. Sharing is not delivery evidence and implies no reward.

**Review request (`N/NativeReviewRequestView.swift`)**
- A "Referral link" section sits between "Review message" and the send buttons. It shows only when `draft.customerID` resolves to a stored customer.
- "Add their referral link" calls `referralShareLink`. On `.ready(url)` it sets `message = NativeReferrals.appendingReferralParagraph(to: message, link: url)` and becomes "Referral link added" (disabled). Other states show the same inline copy as the share view.
- **Footer:** "Adds a personal booking link to the message above. You can edit it before sending."
- The one-shot record, `markReviewRequestSent` and analytics are unchanged. There is no `{referralLink}` template placeholder and no settings field in v1 (D7).

### 5.6 Rewards and credits

**Recording a reward (`N/NativeReferralRewardSheet.swift`).** It opens from customer detail → a referral row → "Record thank-you".
- **Fields:**
  - kind picker: Thank-you note · Gift card · Credit on their next invoice · Other
  - amount (`CurrencyField`): hidden for a thank-you note, required > 0 for a credit
  - note: optional, ≤ 200 characters
  - date: defaults to today, local
- **Save** → `store.recordReferralReward(referredCustomerID:reward:)`, a canonical write plus enqueue. "Remove record" clears it.
- **Footer:** "TradeReady only keeps a record. It never sends gifts, credits or money."
- **Gift card or Other with an amount:** a secondary button, "Log as a Marketing expense", opens `NativeExpenseEditor` for a new expense. It is prefilled with category `marketing`, the amount, and notes "Referral thank-you for <referrer>"; the owner saves it. This needs an additive `prefill: Expense? = nil` on the editor, used only when `opened == nil`. The point is that the gift card's cost reaches the books.

**Applying a credit (`NativeCreateInvoiceFromJobView`)**
- **Where it appears:** modes `.create` and `.finalize` only, when `creditBalance(referrerID: <job's customer>).owed > 0` and the job produced at least one line.
- **Section "Referral credit":** a toggle, "Apply $25.00 referral credit".
  - Footer: "Adds a “Referral credit” line and lowers this invoice. Nothing is applied unless you turn this on."
  - Turning it on subtracts `owed` from `draft.amount`; turning it off adds it back.
  - It is disabled when `owed >= draft.amount`, with "This credit is more than the invoice. Apply it to a larger one." Partial application is not in v1.
- **Draft:** `NativeInvoiceFromJobDraft` gains `var referralCreditToApply: Decimal = 0`.
- **Lines:** a new pure helper, `JobInvoiceDomain.appendingReferralCredit(_ jobLines:, existingInvoiceLines:, credit:)`, returns:
  - the job lines
  - plus, in finalize, the existing invoice's `referral_credit` lines, so the recompute never drops them
  - plus, when `credit > 0`, `{ "Referral credit — thank you!", -credit, "referral_credit" }`

  `commitInvoiceFromJob` uses it in both modes.
- **Never applied by:** auto-invoice on complete, deposit requests, recurring invoices, the manual New Invoice screen, or the payments ledger.
- Collected, tax set-aside and the lead-source math are unchanged by construction. The PDF, email and line-items CSV already render negative lines.

### 5.7 Owner views

**Customer detail → "Referrals" section.** It sits after Phase 21's Properties section, or after Contact if Phase 21 hasn't landed. It reads `AppStore.referralSummary(customerID:)`, which wraps `NativeReferralReport.customerSummary(…)` (all time).
- "Referred by" links to the referrer, or reads "a former customer". It shows only when R1 holds.
- When this customer has referred others:
  - a summary, "Referred 3 · $4,120.00 collected"
  - "Credit owed: $25.00" when greater than zero
  - one row per referred customer: name, "Joined <local createdAt>", collected, and reward status ("Thanked · $25.00 credit · Oct 3", or "Not thanked yet" with "Record thank-you")
- **Actions:**
  - "Share referral link"
  - "Reset referral link", shown only when a code exists. It asks first: title "Reset Sam's referral link?", message "Links Sam already shared still open your booking page, but new bookings from them won't be credited to Sam."

**Money → "Referrals" card and screen.** The report lives in `N/Domain/NativeReferralReport.swift` (new). It stays out of `NativeMoneyCardModels.swift` so the coach runner can compile it.

`NativeReferralReport.make(customers:invoices:start:end:)` works like this:
- **Attribution:**
  - An invoice's collected amount (`NativeCashBasis.collected(invoices: [invoice], …)`) counts only when the Phase 27 bucket attribution puts it in `referral`.
  - It then goes to a referrer row by the same id-first / unique-name rule, keyed on the customer's referrer.
  - An ambiguous or missing referrer goes to "Referrer not recorded".
  - A dangling referrer goes to "Former customer".
  - To share one rule, generalize `NativeLeadSourceReport.Attribution` to `init(customers:key:)`, with the bucket as the default key. This is a pure refactor, guarded by the §5 control-total test in the lead-source spec.
- **Row fields:**
  - referrer name
  - new referred customers in range (`createdAt` via `NativeCashBasis.isInRange`)
  - referred customers all time
  - collected in range
  - credit owed
- **Totals:** rewards recorded in range, by `recordedOn`, as a count and Σ amount.
- **Control total (tested):** Σ collected over all rows, including the two catch-all rows, equals the lead-source report's `referral` row for the same range.
- **Sort:** collected descending, then new referred descending, then name. The two catch-all rows go last.

The card and screen:
- `NativeMoneyReferralCard.make(…)` is nil unless at least one customer has a referrer. It becomes `NativeMoneyOverview.referrals`, rendered in `customersSection` right after Lead sources (`N/MoneyView.swift:182-196`).
- The card shows the top 5 rows ("Sam Ortiz · 2 new · 5 total · $1,800.00") and the footer "Rewards recorded: 2 ($50.00)".
- Opening the card shows `N/NativeReferralsView.swift`, the "who referred whom" screen:
  - one section per referrer, with each referred customer's name, joined date, collected in range and reward status
  - the same Money date filter
  - rows link to customer detail

**Today insight `NativeInsightKind.referralThanks = "referral_thanks"`**
- **Selection:**
  - referred customers with a live referrer (R1, not dangling) and no `referralReward`
  - whose first non-voided payment falls within the last 60 local days
  - payments attributed by id first, then by unique name
- **Cap:** at most one row: the most recent first payment, with ties broken by name and then id. It runs last in `select`.
- **Behavior:** muteable, dismiss-only, no snooze. Icon `gift`. Recording a reward clears it.
- **Copy:**
  - id: `referral_thanks:<referredCustomerId>`
  - title: "Thank Sam for referring Alex"
  - detail: "Alex has paid $1,240.00 so far."
  - reason: "Alex was referred by Sam and paid for the first time on Sep 28. No thank-you is recorded yet."
  - target: `.customer(customerId: <referrer>)`
  - coach prompt: "Help me write a short thank-you text to Sam for referring Alex."
- **Why first payment:** prompting at booking would thank people for leads that never turn into work.

### 5.8 Coach

**Snapshot.** `NativeBusinessSnapshot` gains `referrals: NativeReferralSnapshotBlock?`, built in `NativeBusinessSnapshotEngine.make` from a year-to-date `NativeReferralReport` (`NativeCashBasis.range(for: "this_year")`). It holds:
- new referred customers
- collected from referred customers
- the top 3 referrers, each with referred all time and collected YTD
- rewards recorded, as a count and Σ amount

It is nil when no customer has a referrer, so the block is absent rather than zeroed.

**Prompt.** `NativeCoachPrompt` appends the block after LEAD SOURCES, in whole dollars via `toFixed0`:

```
REFERRALS (year to date): 3 new referred customers; $2400 collected from referred customers. Top referrers: Sam Ortiz (2 referred, $1800 collected); Ana Lee (1 referred, $600 collected). Rewards recorded: 1 ($25). These referral figures are computed from the owner's records. Cite them exactly; never estimate figures for a referrer who isn't listed. Rewards are recorded by the owner; never promise, calculate or send a reward on the owner's behalf.
```

### 5.9 Export

- The accountant package customers CSV gains a trailing `Referred by` column after Phase 27's `Lead source`. It holds the referrer's name, "Former customer" when the referrer is gone, or blank. Codes and rewards are not exported.
- Credit lines already reach `invoice-line-items.csv` with category `referral_credit`.
- There is no import mapping for this column (§8).

## 6. Privacy

| Where | What it sees or stores |
|---|---|
| The person booking (`book.html`) | Nothing referral-related. The page and every response are identical for valid, unknown and malformed codes, so there is no oracle. |
| URL | `b`, the owner's existing public booking capability, and `r`, 16 random characters not derived from any customer data. There is no other PII. |
| Worker | Format-checks the code and stores `referralCode` on the owner-scoped `bookingRequests` row. It never resolves, logs or echoes it. |
| Owner email | "Came in through a customer's referral link". There are no names, because the server never knows them. |
| Portal and manage page | Whitelisted fields only (§0). No referral field is exposed. |
| The referrer | Gets nothing automatically. The app never messages them. |
| Job and invoice text | Never names the referrer or the referred person. The credit line reads "Referral credit — thank you!". |
| Coach | Referrer names and figures appear in the REFERRALS block. Top customers are already named in the prompt. |
| Analytics (optional) | `referral_link_shared(channel, source)` and `referral_reward_recorded(kind)`, with no ids, codes, names or amounts. Add them only if the analytics event contract allowlists them; otherwise skip. |

## 7. Testing

### New Swift suite

Add `native/ReferralTests/main.swift` and `native/run-referral-tests.sh`.
- **Runner:** model it on `run-lead-source-tests.sh`. Add `NativeReferrals.swift` and `NativeReferralReport.swift`, and run with `TZ="${TZ:-America/Phoenix}"`. Register it in `native/run-all-domain-tests.sh` after the lead-source line.
- **Encoding:**
  - `encodeCode` vectors:
    - ten `0x00` bytes → `0000000000000000`
    - ten `0xFF` bytes → `zzzzzzzzzzzzzzzz`
    - `00 44 32 14 C7 42 54 B6 35 CF` → `0123456789abcdef`
    - a wrong byte count → nil
  - `normalizeCode`: case-folds and trims; rejects `i`, `l`, `o`, `u`, 15- and 17-character codes, nil and empty.
  - `makeCode`: retries a collision with injected bytes; returns nil after 3 collisions and nil when the RNG fails.
- **Resolution:**
  - `resolveReferrer`: by code, by alias, archived referrer, no match, and a duplicate code → nil.
  - `isSelfReferral`: by id, email (case), phone (formatting), and a short phone ignored.
- **Links and copy:**
  - `referralURL`: appends `r` and keeps `b`; rejects a bad code or a URL with no `b` or an existing `r`; `isValidBookingURL` still accepts the result.
  - Message rendering, and append idempotence.
- **Intake and credit:**
  - The `referralDecision` matrix (§5.3).
  - `creditBalance`: promised, applied and owed; a partial amount; a deleted invoice re-opens the credit; name-fallback attribution; non-credit kinds ignored.
- **Report:**
  - referrer rows, Former customer, and Referrer not recorded (both missing and ambiguous)
  - R1 violators ignored
  - **the control total equals the lead-source `referral` row**
  - voided payments excluded
  - a payment at 23:30 local on the last day of the range is in, and the next day is out
- **Insight:**
  - first payment inside and outside 60 days (Phoenix day boundary)
  - a recorded reward clears it
  - a dangling referrer suppresses it
  - the one-row cap and its tie-break
- **Coach block:** the exact string, and absent when no customer has a referrer.

### Updated Swift suites

- **CanonicalTests:** the `canonical-rich.json` customer gains all four fields, with an unknown key inside `referralReward`. The booking request gains `referralCode`. Both round-trip exactly.
- **AdapterTests:** an editor save keeps the three canonical-only fields; `referredByCustomerId` round-trips.
- **BookingIntakeTests:**
  - a new customer via a code
  - a matched customer with a blank source
  - a matched customer with another source, unchanged
  - a matched referral with no referrer, which gets filled
  - self-referral by name, and by email or phone
  - an unknown code
  - a portal request carrying a code, which is ignored
  - a slot booking
- **ScheduleBookingRecoveryTests (K10b style):** the recheck fills the referrer, and a value set since the plan was built wins.
- **CustomerIdentityTests:**
  - merge: code carry and aliases, re-pointing, dropping a self-reference, reward carry
  - undo restores re-pointed customers, and conflicts when one has changed
  - `editorSavePlan` clears the referrer for another source or for self
- **InvoiceFromJobTests:** `appendingReferralCredit` for create, finalize carry-over, and zero credit (no line).
- **StoreIntegrationTests:**
  - `ensureReferralCode` persists and enqueues once, and is idempotent
  - `resetReferralCode`
  - `recordReferralReward` enqueues
  - `commitInvoiceFromJob` with a credit writes the line and the lowered amount
  - auto-invoice never adds a credit line
- **Insights:** TodayInsightsTests; InsightMuteTests (muteable, dismiss-only, icon).
- **Money and coach:** MoneyCardsTests (overview with the card nil and present); BusinessSnapshotTests; CoachPromptTests (LEAD SOURCES then REFERRALS; existing exact strings unchanged when nil); Phase10QualificationTests (snapshot constructors).
- **AccountingPackageTests:** the `Referred by` column.

### Runner registration

Add `NativeReferrals.swift`, plus `NativeReferralReport.swift` where needed, to every runner that compiles a dependent:
- intake: `run-booking-intake`, `run-booking-attention`, `run-phase10-qualification`, `run-today-briefing`
- AppStore: `APPSTORE_TEST_SOURCES` in `run-appstore-sources-common.sh`
- snapshot: `run-coach-prompt`, `run-business-snapshot`
- money overview: `run-money-card`, `run-mileage-log`
- insights: `run-today-insights`, and any other runner that compiles `NativeTodayInsights.swift`

Then run `node scripts/parity-manifest.mjs --write`.

### Worker (root Jest, `TZ=America/Phoenix npm test -- --runInBand --runTestsByPath …`)

- **New `__tests__/bookingValidateReferral.test.js`**, targeting the Worker copy:
  - absent → no key, and the key set is unchanged
  - a valid code is kept
  - uppercase is lowercased; whitespace is trimmed
  - 15 or 17 characters, `i`/`l`/`o`/`u`, punctuation, and non-strings (number, object, array, boolean, null) are all dropped while the booking still validates
  - it coexists with `leadSource`
- **`__tests__/bookingSlotsReserve.test.js`:** `referralCode` lands in the stored request; garbage leaves no key and never fails the booking.
- **New `__tests__/bookingNotifyReferral.test.js`**, targeting the Worker `notifyOwner`: the referral line appears in both variants only when a code is present; the push body is unchanged.
- **`cd backend-workers && npm test`:** stays green. It has no booking coverage, so nothing changes there.

### `book.html` headless check

Use a jsdom check, the same approach as the Phase 27 check: load the real `tradeready-legal/book.html`, stub `fetch`, and drive both modes.

| URL | Expected body |
|---|---|
| `?b=tok&r=<valid>` | `referralCode` present, in both request and slot mode |
| `?b=tok&r=%20%20` | no `referralCode` key |
| `?b=tok&src=nextdoor&r=<code>` | both keys |
| `?b=tok` | neither key |

Also assert the rendered text is identical with and without `r`. `tradeready-legal` has no test harness, so this runs as a scratch check unless the owner wants one committed.

### Gates

- `sh native/run-all-domain-tests.sh`
- the Release compile
- the targeted Jest files under Phoenix
- `cd backend-workers && npm test`
- `sh native/run-doc-reference-check.sh`

## 8. Accepted residuals

- **Rotation breaks links.** Rotating the booking link breaks every referral link already shared, because they carry the old `b`. The rotate copy says so. A code-only link would need server-side resolution, which §1 rejects.
- **No offline sharing.** Sharing needs a verified, enabled booking link, the same rule as the booking settings screen.
- **Concurrent code generation.** Two devices can each generate a code for the same customer before syncing. Whole-record LWW keeps one; links carrying the other count as "referral, referrer not recorded". The owner can fix the referrer in the editor.
- **Unsynced code.** A code generated on one device and booked through before that customer's push lands is unresolved on another device. It's rare, and recorded the same way.
- **Self-referral misses.** Detection misses a referrer who books under a different name *and* different contact details. Duplicate detection plus merge (§5.4 step 2) clears it.
- **Forwarded links.** A forwarded link still credits the link's owner. That is by design.
- **Rewards aren't bookkeeping.** A gift card reaches the books only if the owner logs the Marketing expense.
- **Narrow credit application.** Credits apply only through invoice-from-job: not the manual New Invoice screen, auto-invoice or deposits, and never partially.
- **No import mapping.** There is no CSV import mapping for "Referred by", because names can't be resolved to ids reliably.
- **Web analytics.** If Cloudflare Web Analytics is enabled on Pages, it may record query strings. That is the same exposure class as the existing `b`, and codes carry no PII.
- **Dormant twins.** The Vercel twins stay unchanged and dormant.

## 9. Decisions

| # | Decision | Recommendation |
|---|---|---|
| D1 | Code storage and generation | A random 80-bit code on the Customer, generated on the device at first share |
| D2 | Server-side existence check | None. The Worker format-checks and passes through; the device resolves. |
| D3 | Revocation | "Reset referral link" drops the old code. Merge keeps a loser's codes as aliases. |
| D4 | Unknown or reset code | Source `referral`, with no referrer |
| D5 | Self-referral | A name match or a matching email/phone means no referral |
| D6 | Rewards | **Owner call.** Recommended: a per-referral record, plus invoice credits as a negative `referral_credit` line through invoice-from-job, never a payment. The alternative is a record-only v1 (drop §5.6's credit application; the credit just stays "owed"). |
| D7 | Saved referral template in Settings | Not in v1. Default copy, editable on every send. |
| D8 | When to prompt "say thanks" | After the referred customer's first payment, within a 60-day window |
| D9 | Coach | Yes: a year-to-date block naming the top 3 referrers, following the top-customers precedent |
| D10 | Manual (word-of-mouth) referrals | A "Referred by" picker in the editor when the source is Referral |

## 10. Build record (2026-10-03)

This section covers the Worker, pages and Worker-test slice. The native slice (§5, the Swift suites in §7) is built separately against the contract in §10.3.

### 10.1 What was built

**Worker (`feat/referrals`, uncommitted)**
- `backend-workers/lib/booking/validate.js`:
  - `REFERRAL_CODE_RE` and `cleanReferralCode`, per §3, tightened as described in §10.2 item 1.
  - `validateBookingPayload` sets `value.referralCode` right after `leadSource`, only when the cleaned code is non-empty.
  - `cleanReferralCode` and `REFERRAL_CODE_RE` are also exported, so the fixture test can pin the pattern.
- `backend-workers/lib/booking/notifyOwner.js` (Worker copy): both email variants gain `Came in through a customer's referral link — open TradeReady to see who referred them.` directly above the closing line, when `request.referralCode` is a non-empty string. The code is never in the email. The subject, the push and `notifyOwnerUpdate` are unchanged.
- **No route edits:**
  - `submit`, `reserve` (both the claim RPC and the legacy path), `config`, `slots`, `manage` and `portal-request` are unchanged.
  - The submit and reserve responses are identical for a valid, unknown, malformed or absent code (tested).
- **Unchanged, as §3 requires:**
  - the Vercel twins (`backend/lib/booking/validate.js`, `notifyOwner.js`)
  - no store function, no lookup and no log line for codes
  - no migration

**Shared fixture:** `native/ReferralTests/Fixtures/referral-code-vectors.json`. §7 names no path, so it uses the `QuoteOptionsTests/Fixtures` convention.
- It holds the alphabet, sizes and pattern.
- 9 `encode` vectors, including all four of §7's.
- 32 `normalize` vectors. Five are `jsOnly`: non-string inputs that Swift's typed `String?` API cannot express.
- The Worker suite checks every vector, including the `jsOnly` ones. A JS reference encoder checks the `encode` vectors, so a typo in the fixture fails before the native suite reads it.

**Tests**
- `backend-workers/tests/referralCode.test.cjs` (new). §7 expected this suite to stay unchanged; the test was added because the shared fixture and the ESM `submit` route can only be run here. It covers:
  - the fixture, as above
  - the validator
  - the real `bookingSubmitHandler`, driven through a fake Hono context: the stored row, no-oracle responses, an identical 404 for a bad token, the email line, and that the code never appears in the push or in any log
- Root Jest. The files are named `*Workers.test.js` to mark that they target the Worker copy; this stands in for §7's `bookingValidateReferral.test.js` and `bookingNotifyReferral.test.js`.
  - `__tests__/bookingValidateReferralWorkers.test.js`: every §7 validator case, plus the fixture vectors.
  - `__tests__/bookingNotifyReferralWorkers.test.js`: the line's position in both variants, everything else unchanged, no line for an absent, empty or non-string code, the code never echoed, the push body unchanged, and failures still swallowed.
  - `__tests__/bookingSlotsReserve.test.js`, which gains four tests:
    - the code lands lowercased beside `leadSource`
    - garbage leaves no key and never fails the booking
    - reserve responses are identical for any code
    - on the claim RPC path the code rides in `p_request`, never in `p_reservation`
  - `__tests__/bookingReferralPrivacyWorkers.test.js` (extra privacy pins for §0 and §6):
    - a portal request sent with `referralCode` or `r` stores neither, and its owner email has no referral line
    - the manage view returns only `businessName`, `status` and `slot`
    - the legacy confirm and cancel writes keep `referralCode` (and `leadSource`) on the blob
- **Mutation check:** the new tests were run against the pre-change `validate.js` and `notifyOwner.js`, with a spec-literal `cleanReferralCode` substituted. 19 Jest tests and the matching Worker tests failed, including the Kelvin-sign vector. The files were then restored.

**Pages (`tradeready-legal`, uncommitted, working tree only)**
- `book.html`:
  - The "(?r= is reserved …)" comment is replaced by §4's referral comment.
  - It reads `var ref = (params.get('r') || '').trim();`.
  - `contactPayload()` adds `if (ref) payload.referralCode = ref;` after the `leadSource` line.
  - This sits on top of Phase 27's uncommitted `?src=` edit, which is kept.
- `estimate.html` and `portal.html` keep their uncommitted Phase 25/32 edits, untouched by this phase.
- Not edited: `booking.html`, `_headers`, `terms.html`, `privacy.html`.

### 10.2 Decisions where the spec was silent

1. **ASCII only, checked before lowercasing.**
   - `toLowerCase()` (and Swift's `lowercased()`) maps U+212A KELVIN SIGN to `k`, so the literal §3 code accepts `K` plus 15 valid characters.
   - The Worker checks the trimmed input against `/^[0-9A-HJKMNP-TV-Za-hjkmnp-tv-z]{16}$/` first, then lowercases it.
   - Full-width digits, accented letters and emoji are rejected the same way.
   - A fixture vector pins this, and the native `normalizeCode` must match it (§10.3).
2. **Trim set.** The Worker uses `String.prototype.trim()`.
   - The shared vectors pin only space, tab, LF, CR and U+00A0, where JS trim and Swift `.whitespacesAndNewlines` agree.
   - U+FEFF (only JS trims it) and U+0085 (only Swift trims it) are outside the shared contract.
   - This is harmless: the device only ever normalizes Worker-stored values, which are already canonical, and its own generated codes.
3. **Wire key.** Only the body key `referralCode` is read. A body `r` or `ref` key is ignored; the page maps `?r=` to `referralCode`.
4. **The page does no format check.** It sends the trimmed `?r=` value as-is, per §4. The Worker is the only gate, and it drops anything unusable, so there is one rule in one place.
5. **The email line's condition** is "a non-empty string". The validator only ever stores a canonical code.
6. **Test layout:** as named in §10.1. One extra Jest file holds the privacy pins.

### 10.3 Contract for the native engineer (§5 builds against this)

**Wire (`book.html` → Worker)**
- `book.html?b=<booking token>&r=<code>[&src=<tag>]`.
- The page sends `referralCode: <trimmed r>` in the JSON body of both requests, only when the trimmed value is non-empty:
  - `POST /api/booking/submit`: request mode, and the "describe your timing instead" swap
  - `POST /api/booking/reserve`: slot mode
- `GET /api/booking/config?b=` and `GET /api/booking/slots?b=` never carry it.

**Worker normalization (`cleanReferralCode`)**
1. A non-string is dropped.
2. Trim.
3. The result must be exactly 16 ASCII characters from `0-9 a-h j k m n p-t v-z`, in either case. Otherwise the code is dropped.
4. Lowercase.
5. Store.

A dropped code never fails or changes the booking. There are **no referral-specific errors or error codes**; a code can never produce a 4xx.

**Stored shape**
- `bookingRequests.data.referralCode`: a string matching `^[0-9a-hjkmnp-tv-z]{16}$`.
- It is present only when valid, and **absent** otherwise: never `null` and never `""`.
- It can appear on:
  - plain requests (`status: "new"`, no `kind`)
  - slot bookings (`status: "booked"`, `kind: "booked"`, on both the claim-RPC and legacy paths)
- It coexists with `leadSource`, and either key can be absent.
- Customer manage actions keep it, because the legacy write spreads the blob and the RPC preserves blob fields.
- Portal rows (`source: "portal"`) never carry it, because the Worker builds them from a whitelist. §5.3 still says to ignore a code on a portal request; keep that as defense in depth.

**Responses** are unchanged, and identical whatever the code:

| Route | Status | Body |
|---|---|---|
| `submit` | 200 | `{ "ok": true }` |
| `reserve` | 200 | `{ "ok": true, "manageToken", "slot" }` |
| either | 400 | `{ "error": <field message> }`, `"Missing link parameters."`, or `"Invalid slot."` (reserve) |
| either | 404 | `{ "error": "This link is invalid." }` |
| `reserve` | 409 | `{ "error": "slot_taken" \| "slot_changed" }` |
| `submit` | 429 | `{ "error": "Too many requests. Please wait a moment." }` |
| either | 500 | `{ "error": "Database error" }` |

The honeypot (`website` non-empty) returns `200 { "ok": true }` and stores nothing.

**Owner alerts**
- Email: the line above, directly before the closing line. No names, no code.
- Push: unchanged. The title is "New quote request" or "New booked appointment", the body is the name plus the details or slot, and the data is `{ "type": "booking_request" }`.

**Never:** the code is never looked up, logged, or echoed by `config`, `slots`, `submit`, `reserve`, the manage view or the portal.

**Device rules (`NativeReferrals`)**
- `normalizeCode(_:)` must pass every non-`jsOnly` vector in `normalize`:
  1. `nil` → `nil`.
  2. `trimmingCharacters(in: .whitespacesAndNewlines)`.
  3. Require every scalar to be ASCII, **before** lowercasing (the Kelvin-sign vector).
  4. `lowercased()`.
  5. Match `^[0-9a-hjkmnp-tv-z]{16}$`.
- `encodeCode(_:)` must pass every `encode` vector, where `bytesHex` is most-significant byte first and `expect: null` means nil.
- Intake should still pass `request.referralCode` through `normalizeCode`, which covers rows written by an older Worker or edited by hand. A value that fails is the §5.3 "no code" row.
- Swift field: `Canonical.BookingRequest.referralCode: String?`, JSON key `referralCode`.

**Ship order:** deploy the Worker, publish `book.html`, then ship the native build. Any order is safe:
- An older Worker silently drops `referralCode`, so the booking succeeds with no attribution.
- An older page never sends it.
- The RN conversion (`utils/storage/bookingConversion.ts`) reads named fields only, so it ignores the new key.

### 10.4 Verification (2026-10-03, worktree `feat/referrals`)

| Command | Result |
|---|---|
| `cd backend-workers && npm test` | 163/163 pass (was 110; `referralCode.test.cjs` adds 53) |
| `TZ=America/Phoenix npm test -- --runInBand --runTestsByPath __tests__/bookingValidateReferralWorkers.test.js __tests__/bookingNotifyReferralWorkers.test.js __tests__/bookingReferralPrivacyWorkers.test.js __tests__/bookingSlotsReserve.test.js` | 4 suites, 99/99 pass |
| The same command over every `__tests__/booking*`, `phase8Booking*` and `portal*Workers` file | 30 suites, 363/363 pass |
| `book.html` jsdom check (scratch, not committed; §7) | 24/24 runs pass |
| `sh native/run-doc-reference-check.sh docs/superpowers/specs/2026-10-03-referral-program-design.md` | 68 references checked, 6 missing. All 6 are native-slice files that §5 and §7 introduce and that don't exist yet; there were 7 before this record. |

The `book.html` check loads the real page, stubs `fetch`, and drives request mode, slot mode and the swap for 8 URLs:
- `?b=tok&r=<valid>` and an uppercase, space-padded code → `referralCode` present, sent as given
- `r=%20%20` and `r=` → no key
- `src=nextdoor&r=<code>` → both keys
- `?b=tok` → neither key
- `src` only → `leadSource` only
- an HTML-injection `r` → sent as given, never rendered, and dropped by the Worker

It also asserts that the `config`/`slots` GETs and the rendered text at every stage are identical with and without `r`. It fails against the page without the edit.

**Open gate:** `node scripts/parity-manifest.mjs --check` now reports the manifest stale. It hashes every `__tests__/*.test.*` file, and this slice adds three and edits one. The `--write` that §7 already schedules after the native runner registration picks them up, together with the new `native/run-referral-tests.sh`, which should pass the fixture path as an environment variable the way `run-quote-options-tests.sh` does.

### 10.5 Privacy wording for the owner (not applied)

`privacy.html` and `terms.html` were not edited; owner decisions are open, see `docs/roadmap-owner-decisions-2026-10-03.md`. If the owner approves, this paragraph would sit with 32-B's sentence on customer-submitted requests, and it states only what §6 guarantees:

> **Referral links.** A business that uses TradeReady may give you a personal booking link to pass along. The link contains a random code with no personal information in it. When someone books through it, the code is saved with their request so the business can see who referred them. TradeReady's servers don't look the code up. The person booking is never shown who referred them, and TradeReady never contacts the person who shared the link. Any thank-you or credit is recorded by the business in its own records; TradeReady doesn't send gifts, credits or money.

### 10.6 Native slice (2026-10-03, worktree `feat/referrals`, uncommitted)

This covers §5 and the Swift parts of §7, built against §10.3. Owner decision 34-D6 is still open; its recommendation (credits as invoice credit lines in v1) is what was built.

**New files**
- `N/Domain/NativeReferrals.swift` (pure; depends on `CanonicalModels` and `NativeLeadSource` only):
  - codes: `encodeCode`, `normalizeCode`, `makeCode` (≤ 3 draws, injected RNG, nil = fail closed), `allCodes`, `resolveReferrer` (code or alias; nil on 0 or > 1 matches)
  - `isSelfReferral` (D5), `referralURL`, `renderShareMessage`, `referralParagraph`, `appendingReferralParagraph`
  - R1 helpers (`validReferrerID`, `sanitizedReferrer`, `anyReferrer`), the id-first / unique-name `CustomerResolver`, `creditBalance` (promised, applied, owed) and `appliedCredit`
  - `RewardKind`, `makeReward` (validated record), `rewardStatusText`, and the shared link-state copy; `NativeReferralLinkState` (§5.2)
- `N/Domain/NativeReferralReport.swift`: `make` (rows, catch-alls, rewards in range), `groups` ("who referred whom"), `customerSummary` (§5.7, all time), `snapshotBlock` (§5.8, year to date), `joinedText`.
- `N/NativeReferralsStore.swift` (AppStore extension): `referralCode`, `ensureReferralCode`, `resetReferralCode`, `referralShareLink`, `recordReferralReward`, `removeReferralReward`, `referralReward`, `referralSummary`, `referralCreditOwed`, `referralGroups`; `NativeReferralRandom.systemBytes` (`SecRandomCopyBytes`).
- Views: `N/NativeReferralShareView.swift` (§5.5), `N/NativeReferralRewardSheet.swift` (§5.6), `N/NativeCustomerReferralsSection.swift` (the customer-detail section, the editor's "Referred by" row and its searchable picker), `N/NativeReferralsView.swift` (Money › Referrals).
- Tests: `native/ReferralTests/main.swift`, `native/run-referral-tests.sh` (registered after the lead-source line; fixture passed as `REFERRAL_CODE_VECTORS`; `TZ="${TZ:-America/Phoenix}"`).

**Edits to shared files (short insertions)**
- `N/Domain/CanonicalModels.swift`: `Customer` gains `referralCode`, `referralCodeAliases`, `referredByCustomerId` and `ReferralReward` (nested, with `Preservation`); `BookingRequest` gains `referralCode`.
- `N/Models.swift` and `N/Domain/UIModelAdapters.swift`: UI `Customer.referredByCustomerId` and the three adapter edits; `NativeInvoiceFromJobDraft` gains `referralCreditAvailable` and `referralCreditToApply`.
- `N/AppStore.swift`: `commitCanonicalCustomers` (save, publish, one upsert each), the invoice-from-job credit (draft and commit), and the analytics guard for `referral_thanks` (below).
- `N/CustomersView.swift`: one line for the detail section, three for the editor row.
- `N/Domain/NativeBookingIntake.swift` (`referralDecision`, the upsert's referrer fill), `N/NativeScheduleBookingStore.swift` (the recheck fill), `N/NativeCustomerIdentity.swift` (editor rule, merge steps 1-5, undo), `N/Domain/NativeLeadSourceReport.swift` (`Attribution(customers:key:)`, now internal; the default key is still the bucket), `N/Domain/JobInvoiceDomain.swift` (`appendingReferralCredit`), `N/Domain/NativeTodayInsights.swift` and `N/Domain/NativeInsightsCardPolicy.swift` (`referralThanks`), `N/Domain/NativeBusinessSnapshot.swift` and `N/Domain/NativeCoachPrompt.swift` (REFERRALS block), `N/Domain/NativeMoneyCardModels.swift`, `N/NativeMoneyCards.swift` and `N/MoneyView.swift` (card and destination), `N/Domain/NativeAccountingPackage.swift` (`Referred by`), `N/NativeReviewRequestView.swift` (the Referral link section), `N/NativeCreateInvoiceFromJobView.swift` (the credit toggle), `N/NativeExpenseEditor.swift` (additive `prefill:`), `N/NativeBookingSettingsView.swift` (rotate copy).

**How a credit flows**
- A reward of kind `invoice_credit` is only a record on the referred customer. `creditBalance` derives owed = Σ promised − Σ applied (lines on invoices attributed to the referrer by id first, then a unique name).
- Invoice-from-job (`.create` and `.finalize` only, and only when the job produced a line) offers the owed credit. Turning it on subtracts it from `draft.amount`. `commitInvoiceFromJob` re-checks it against what is owed now (refusing with "The referral credit changed while this invoice was open…" otherwise) and writes the job lines plus `{ "Referral credit — thank you!", -credit, "referral_credit" }`. In finalize, earlier `referral_credit` lines are carried over, and a change-order re-derived amount adds them back, so a recompute never drops or double-counts a credit.
- `invoice.amount` is the lowered figure, so balance due, paid/partly-paid status, payments, collected cash, the lead-source and referral reports and the tax set-aside all follow by construction; nothing is written to the payments ledger. The PDF prints the negative line under Additional Charges with the lowered total; `invoice-line-items.csv` exports it verbatim with category `referral_credit`; `invoices.csv` exports the lowered amount, paid and balance. Auto-invoice, deposits, recurring invoices and the manual New Invoice screen never apply a credit. All of this is pinned by tests (below).

**Decisions where the spec was silent**
1. **Trim set.** Apple's Foundation trims U+200B ZERO WIDTH SPACE as whitespace, but JavaScript `trim()` does not, and the shared vector requires it to be rejected. `normalizeCode` trims `.whitespacesAndNewlines` minus U+200B; every other non-`jsOnly` vector passes unchanged.
2. **Analytics.** `referral_thanks` is not in the §9.5 catalog's `InsightKind` enum (which mirrors RN). `NativeInsightKind.isInAnalyticsCatalog` keeps it out of the insight events: `insight_shown` lists only catalog kinds (and is skipped when none are visible), and tapped, coach-opened, reason-viewed and dismissed are not sent for it. The optional `referral_link_shared` / `referral_reward_recorded` events were not added (§6: not allowlisted).
3. **First names in copy.** The share message ("Hi Sam, …"), the reset dialog and the insight use the first word of the trimmed name; the card, report rows and summaries use full names. A blank customer name reads "Hi there", a blank business name "us".
4. **Insight window.** The first payment's local day must fall from 60 days before today through today (today − 60 is in, today − 61 out; a future-dated payment is out). Day strings are compared, never parsed `YYYY-MM-DD` dates (FA-039). "Paid so far" sums non-voided payments (legacy paid invoices materialized as in Money).
5. **Report details.** Rows exist for every referrer with at least one referred customer (all time), plus Former customer and Referrer not recorded whenever they have customers or collected money. A customer with a Referral source but no valid referrer (missing, or a self-reference) counts under Referrer not recorded. Rewards in range count R1 referrals only and Σ any amount. The top 3 coach referrers exclude the catch-all rows; the block omits the "Top referrers" sentence when none are left and reads "Rewards recorded: none." when nothing was recorded.
6. **Merge R1.** After the referrer fill, the winner's referrer is also dropped when the merged source is not Referral (merge enforces R1, as §2 requires). Code aliases are carried verbatim (deduped, sorted, minus the winner's own code); resolution normalizes them anyway.
7. **Rewards.** A thank-you note drops any amount; a gift card or Other amount is optional (> 0 when given); a credit needs > 0. Notes are trimmed and capped at 200 characters. `recordReferralReward` refuses a customer with no referrer (R3). The sheet edits an existing record ("Edit thank-you") as well as recording one. "Log as a Marketing expense" pre-fills description "Referral gift card"/"Referral thank-you", the amount, `marketing` and the note; nothing is saved until the owner taps Save.
8. **Reset.** `resetReferralCode` refuses a customer with no code and never re-draws the old code.
9. **Picker.** The editor's "Referred by" row pushes a searchable list (name, email, phone) of every other customer, archived ones labelled "Archived", plus None; a dangling value reads "A former customer".
10. **Accountant package.** `Referred by` re-pins the package bytes like Phase 27 did: `,Referred by` (12 bytes) on the header plus one empty field per row; new CRC-32 pins 972 477 102 (sample) and 2 008 743 930 (empty).

**Suites updated (§7)**: CanonicalTests (`canonical-rich.json`: all four customer fields, an unknown key inside `referralReward`, the booking request's `referralCode`; exact round trips), AdapterTests, BookingIntakeTests, ScheduleBookingRecoveryTests (K10b), CustomerIdentityTests, InvoiceFromJobTests, StoreIntegrationTests (codes, reset, share-link states through the booking-admin stand-in, rewards, auto-invoice never credits, create and finalize credits through payments, the PDF and collected cash; the insight policy row), TodayInsightsTests, MoneyCardsTests, BusinessSnapshotTests, CoachPromptTests, AccountingPackageTests, plus InvoicePDFTests and TaxSettingsTests (credit through the PDF totals and the set-aside), AccessibilityAuditTests (inventory, Done-bar coverage, in-row destructive count 17) and LayoutMetricsTests (four scroll roots). InsightMuteTests does not compile the card policy, so the muteable/dismiss-only/icon row lives in StoreIntegrationTests beside the existing ones. Phase10QualificationTests needed no edit: `NativeBusinessSnapshot.referrals` defaults to nil.

**Runner registration**: `NativeReferrals.swift` added to booking-attention, booking-intake, today-briefing and today-insights (with `NativeLeadSource.swift`); both new domain files to business-snapshot, coach-prompt, mileage-log, money-card and phase10-qualification; all three new non-view files to `run-appstore-sources-common.sh`.

**Review on resume.** The native engineer was cut off before verifying. A second engineer re-read the whole native diff against §2, §5, §7 and §10.3 and found no code to change. The one doc fix: the `docs/native-parity-matrix.md` "Accountant package" row now records both intentional columns (`Lead source` and `Referred by`), 3957 vs RN's 3931 bytes for the fixture.

### 10.7 Native verification (2026-10-03, worktree `feat/referrals`)

Swift runners ran one at a time with `TMPDIR` set to a scratch folder. Every runner that compiles a changed or new source, or whose `main.swift` changed, was run: 100 runners. `CanonicalModels.swift` changed, so that is almost all of them.

| Command | Result |
|---|---|
| `sh native/run-referral-tests.sh` (new) | 235/235 checks pass |
| `run-store-integration`, `run-canonical`, `run-adapter`, `run-lead-source` (265 checks), `run-booking-intake`, `run-invoice-pdf`, `run-csv-export`, `run-accounting-package`, `run-money-report`, `run-tax-settings`, `run-business-snapshot`, `run-coach-prompt`, `run-customer-identity`, `run-invoice-from-job`, `run-money-card`, `run-today-insights`, `run-schedule-booking-recovery` (1484 checks) | all pass |
| `sh native/run-accessibility-audit-tests.sh` | 2012/2013. The one failure is the known pre-existing `raw .borderedProminent at N/RootView.swift:234` |
| `sh native/run-layout-metrics-tests.sh` | 905/908. The three failures are the known pre-existing ones: `RootView keeps six tabs`, `cancellationAction 'Done' at N/CoachView.swift:68`, and the off-by-one `.keyboardShortcut` total (54 vs 55) |
| The other 80 affected runners (AppStore-compiling ones included, from account-deletion to zip-archive) | 80/80 pass. Reported counts include ai-provider-key 480/480, analytics-transport 226, legacy-reimport 933, phase11-qualification 514/514, poor-network 422/422, quote-options-store 122, quote-options 235, rejected-changes 183, rollback-readiness 310, support-diagnostics 239/239 and job-forms 537 |
| `sh native/check-runner-registration.sh` | pass (`run-referral-tests.sh` is registered) |
| `cd backend-workers && npm test` | 163/163 pass |
| `TZ=America/Phoenix npm test -- --runInBand --runTestsByPath __tests__/bookingValidateReferralWorkers.test.js __tests__/bookingNotifyReferralWorkers.test.js __tests__/bookingReferralPrivacyWorkers.test.js __tests__/bookingSlotsReserve.test.js` | 4 suites, 99/99 pass |
| Release compile (`xcodebuild … -configuration Release -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build`) | BUILD SUCCEEDED. No warnings in any file this phase touched |
| `node scripts/parity-manifest.mjs --write`, then `sh native/run-fixture-manifest-check.sh` | Written (136 runners, 225 RN oracles), then "current". The §10.4 open gate is closed: the manifest now holds `run-referral-tests.sh`, its fixture and the three new Worker Jest files |
| `sh native/run-doc-reference-check.sh` (all `docs/native-*.md`) | 2363 references checked, 0 missing |
| `sh native/run-doc-reference-check.sh docs/superpowers/specs/2026-10-03-referral-program-design.md` | 100 checked, 1 missing, 2 planned. The two planned paths are §7's original Jest names, built as the `*Workers.test.js` files (§10.1). The missing path is the owner-decisions doc that §10.5 cites. It is committed on `feat/quote-expiration` (`c2df0b7`) but not in this branch's history, so it resolves on merge |

**Not run here:**
- `run-analytics-event`, `run-error-redaction` and `run-save-rollback` hang on a macOS privacy prompt under a custom `TMPDIR`. They are left to the final gate. analytics-event covers the `isInAnalyticsCatalog` guard; the referral suite pins that guard directly.
- The aggregate `run-all-domain-tests.sh`, which includes those three. Its other runners either ran above or compile no file this phase changed.
- Device evidence, which is deferred to Phase 12 as for every phase.
