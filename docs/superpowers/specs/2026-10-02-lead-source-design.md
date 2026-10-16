# Lead Source Tracking & Revenue by Source (Roadmap Phase 27) — Design Spec

**Date:** 2026-10-02
**Status:** BUILT 2026-10-03 on local branch `feat/lead-source` (stacked on `feat/quote-options`) and, for `book.html`, uncommitted in `tradeready-legal` (see §11). Nothing pushed or deployed. (Owner go-ahead 2026-10-02 to scope, then implement.) Code map verified 2026-10-02
**Origin:** `docs/post-launch-feature-roadmap.md` Phase 27, build order #2
**Builds on:** CSV import (`2026-08-06-data-import-design.md`), booking link (`2026-08-04-booking-link-design.md`, `2026-08-07-calendar-availability-booking-design.md`), Money reports, coach grounding (tax set-aside block pattern)
**Build target (owner, 2026-10-02):** native SwiftUI app, the Worker, and `book.html` in `CZilla57/tradeready-legal`. **No React Native changes.**

## 0. Preconditions verified against the repo

- Nothing in the repo records a lead source today (`leadSource`, `utm_`, `referrer`, "how did you hear" all absent).
- Customers, jobs and booking requests are JSON blobs (`customers.data`, `jobs.data`, `bookingRequests.data`), so new optional keys need **no migration**. `Canonical.Customer` already preserves unknown keys.
- The booking validator is a whitelist (`backend-workers/lib/booking/validate.js` `CAPS`), so a new request field is dropped unless added there. `reserve` uses the same validator.
- Portal requests always relink an **existing** customer (`sourceCustomerId`); they never acquire one.
- Booking intake fills repeat-customer blanks in two places: `NativeBookingIntake.upsertCustomer` and `NativeScheduleBookingPolicy.recheckedIntakePlan`.
- CSV import commit enqueues only *created* records. A matched customer whose blank fields get filled is saved locally but never pushed (`AppStore.swift` import commit).
- There is no approval date on a job. `estimateSentAt` (local YYYY-MM-DD) or `approval.sentAt` is the only dated estimate event.

## 1. Recommendation: customer-level, first-touch source

The kickoff asks whether the source belongs on the customer, the job, or both. **Recommendation: customer only, first touch.**

- The question the owner is answering is "which marketing brings me customers". That is acquisition, and acquisition is a property of the customer. Jobber models it the same way.
- A returning customer's later revenue is credited to the channel that first brought them in. That is the lifetime-value view a solo operator needs for marketing spend.
- The only "different channel" a repeat customer uses in this app is the portal or the booking link. Neither is marketing; both are ways an existing customer reaches you.
- One field keeps every report deterministic and the UI to one picker.

So portal requests do **not** change a customer's source. Booking-link requests tag only customers the booking creates, or matched customers whose source is blank.

## 2. Data model

```ts
// Customer.leadSource?: string   — absent/empty = "Unknown"
// Preset keys (stable, never renamed on the wire):
//   referral | google | facebook | nextdoor | yelp | thumbtack_angi |
//   signage | website | booking_link | mailer
// Anything else is a custom label, stored verbatim after normalization.
```

`NativeLeadSource.normalize(_ raw: String?) -> String?`:
- Trim the value and collapse internal whitespace. Empty becomes `nil`.
- A preset key, or a preset display name / alias (case-insensitive), becomes that preset key. Aliases include "word of mouth", "referral", "friend" → `referral`; "google ads", "google search", "gbp", "google business profile" → `google`; "angi", "angie's list", "homeadvisor", "thumbtack" → `thumbtack_angi`; "truck", "yard sign", "vehicle wrap" → `signage`; "flyer", "door hanger", "postcard", "mailer" → `mailer`.
- Anything else is kept as a custom label, capped at 40 characters, with control characters stripped.

**Report bucket key:** preset key, or `custom:<lowercased label>` (so "Home show" and "home show" merge), or `unknown`. The display name is the preset's display name or the first-seen custom spelling.

Display names: Referral / word of mouth · Google · Facebook · Nextdoor · Yelp · Thumbtack / Angi · Truck or yard sign · Website · Online booking link · Flyer or mailer · Unknown.

## 3. Capture points

| Path | Rule |
|---|---|
| Customer editor (create/edit) | "How they found you" picker: presets, previously used custom labels (derived from existing customers, no settings field), "Other…" free text, and "Not set" |
| Customer merge | The winner keeps its source; it fills from the loser only when blank |
| Booking link, new customer | `normalize(request.leadSource) ?? "booking_link"`. A portal follow-up whose `sourceCustomerId` dangles also creates a customer; it passes no source |
| Booking link, matched customer with blank source | Same fill (both `upsertCustomer` and `recheckedIntakePlan`) |
| Booking link, matched customer with a source | Unchanged (first touch) |
| Portal request | Unchanged (existing customer) |
| CSV import, created customer | `normalize(mapped value)` |
| CSV import, matched customer | Fill only when blank. **Fix:** matched customers whose fields changed are now enqueued for push too. This fixes the push gap for all filled fields, not just source |
| Auto-invoice / sample data | Not set (Unknown) |

**Worker:**
- `backend-workers/lib/booking/validate.js` gains an optional `leadSource`, handled after the `CAPS` loop (never `''`):
  - A non-string or empty value is dropped silently. It is a marketing URL param, so it never fails a booking.
  - Control characters are stripped, whitespace is collapsed, and the value is truncated to 40 characters.
- `submit` and `reserve` spread `checked.value` into the request blob, so they need no route edits.
- The dormant Vercel twin `backend/lib/booking/validate.js` is not changed. New Jest cases target the Worker copy in a new file; the legacy `__tests__/bookingValidate.test.js` keeps covering the twin.

**`book.html`:**
- Reads `?src=<value>` and sends it as `leadSource` from the shared `contactPayload()`, covering submit and reserve. The owner can share `…/book.html?b=<token>&src=nextdoor`. The booking URL carries `?b=<token>`, and `isValidBookingURL` tolerates extra params.
- `?r=` is reserved for Phase 34 referral codes.

## 4. CSV import mapping

- Add a `leadSource` target to `fieldDefs[.customers]`.
- Synonyms: `lead source`, `source`, `referral source`, `how did you hear`, `how did you hear about us`, `marketing source`, `lead channel`.
- Vectors are added to `ImportMappingTests` for Jobber-style ("Lead source") and Housecall-style ("Lead Source") headers. Exact competitor header names are unverified (no real export fixtures exist), so the synonym list is deliberately broad.

## 5. Lead-source report (Money tab)

Pure `NativeLeadSourceReport.make(customers:jobs:invoices:start:end:)`. It uses the same `NativeMoneyDateFilter` range as every Money card and `NativeCashBasis` local-date parsing (FA-039 safe). Per bucket:

| Column | Definition |
|---|---|
| New customers | Customers whose `createdAt` (local date) is in range |
| Estimates sent | Jobs whose estimate send date (`estimateSentAt`, else `approval.sentAt` as a local date) is in range |
| Jobs won | The subset of those sent in range whose status is approved or later (`NativeMoneyReports.statusOrdinal` ≥ approved; `declined` is ordinal 1). This is a sent-in-period cohort, because there is no approval date |
| Close rate | won ÷ sent, `nil` when sent = 0 (shown as "—") |
| Collected | Σ non-voided ledger payments dated in range (exactly `NativeCashBasis.collected` math), attributed by `invoice.customerId`, falling back to a normalized-name match like `customerRollup` |

- **Attribution:** a job or invoice maps to its customer, and the customer maps to its bucket. Unattributable records go to **Unknown**, which is a real bucket and never an error.
- **Control total:** Σ bucket collected == `NativeCashBasis.collected(invoices, range)` (tested).
- **Sort:** collected descending, then new customers descending, then display name. Unknown always sorts last.
- **UI:** a "Lead sources" card in MoneyView's "Customers & invoices" section, hidden when there are no customers. It shows every bucket row: name, collected, won/sent, close rate.

## 6. Coach

- `NativeBusinessSnapshot` gains an optional `leadSources` block: year-to-date rows (top 6 by collected, plus Unknown when non-zero) with collected, won, sent and close rate.
- `NativeCoachPrompt` appends a LEAD SOURCES block after BUSINESS DATA (following the tax block pattern), ending with: "These lead-source figures are computed from the owner's records. Cite them exactly; never estimate figures for a source that isn't listed."
- The block is absent rather than zeroed when no customer has a source.

## 7. Export

The accountant-package customers CSV gains a trailing `Lead source` column (display name; custom labels verbatim), so a source survives export → re-import.

## 8. Testing

- New Swift `LeadSourceTests` (runner `run-lead-source-tests.sh`, registered):
  - normalize (presets, aliases, custom, caps, empty)
  - bucket keys
  - every capture rule in §3 at the domain level
  - report math including Unknown, cohort won/sent, close-rate `nil`, the control total, local-date edges (a payment at 23:30 local on the last day of the range), and the name-match fallback
  - coach block present/absent
- Updated suites: canonical (customer fixture with `leadSource`), import mapping/engine, booking intake, money cards, coach prompt, business snapshot, accounting package CSV.
- Worker: a new root Jest file `__tests__/bookingValidateLeadSource.test.js` targets the Worker validator (the legacy `bookingValidate.test.js` keeps covering the dormant twin), and `bookingSlotsReserve.test.js` gains `leadSource` cases.
- Gates: `sh native/run-all-domain-tests.sh`, the Release compile, the targeted Jest Worker tests under `TZ=America/Phoenix`, `cd backend-workers && npm test`, and `sh native/run-doc-reference-check.sh`.

## 9. Accepted residuals

- No job-level channel (see §1). If the owner later wants per-job attribution, `job.leadSource` overriding the customer's is an additive follow-up.
- Booking-job `createdAt` is still the UTC date prefix of the server timestamp (pre-existing FA-039-class issue in `NativeBookingIntake.makeLeadJob`). The report doesn't use job `createdAt`, so it's out of scope here; flagged separately.
- Competitor CSV header names are unverified.

## 10. Owner decisions recorded

| # | Decision | Choice |
|---|---|---|
| D1 | Customer vs job | Customer-level, first touch |
| D2 | Custom sources | Free text, re-offered from existing customers; no settings list |
| D3 | Booking link source | `?src=` param; default "Online booking link" |
| D4 | "Won" definition | Sent-in-period cohort that reached approved |
| D5 | Import push gap | Fixed for all matched-customer fills |

## 11. Build record (2026-10-03)

**Built (native, `feat/lead-source`):**
- `Domain/NativeLeadSource.swift` (Foundation-only normalizer). Placeholder values ("Unknown", "N/A", "-", "none", "not set") normalize to no source, so they never create a second Unknown row.
- `Canonical.Customer.leadSource` and `Canonical.BookingRequest.leadSource` (typed), the UI model and adapters.
- Capture: the customer editor's "How they found you" picker (presets, custom labels already in use, "Other…") with a read-only "Found you via" row on customer detail; merge fill; booking intake (`NativeBookingIntake.leadSourceCandidate`, `upsertCustomer(leadSource:)`, the recheck fill; portal requests never take a source); CSV import mapping and engine; the import push-gap fix (`AppStore.importFilledCustomers`) for the customers, jobs and invoices imports.
- Report: `Domain/NativeLeadSourceReport.swift`, the Money "Lead sources" card (`NativeMoneyLeadSourceCard` / `NativeMoneyLeadSourceCardView`), the coach LEAD SOURCES block (after the tax block) and the accountant-package `Lead source` column.
- Decisions made while building:
  - Every bucket a customer belongs to shows, even with no activity in the period.
  - Archived customers and archived jobs count. A deleted customer's records fall back to a name match, else Unknown, so the control total always holds.
  - A name shared by customers in different buckets resolves to Unknown rather than a guess.
  - When no customer has a source the card still shows, with a one-line hint to set "How they found you".
  - A customer that the Expo build created from a booking (no source) is filled with `booking_link` when native intake matches it (ScheduleBookingRecoveryTests K5).
- Tests: `run-lead-source-tests.sh` (normalizer, capture rules, report math under Phoenix time, coach block) plus the canonical, adapter, customer-identity, booking-intake, schedule-booking-recovery, import mapping/engine/CSV, store-integration, money-card, business-snapshot, coach-prompt and accounting-package suites.

**Built (Worker):** `backend-workers/lib/booking/validate.js` cleans an optional `leadSource` after the `CAPS` loop and never fails a booking over it.

**Built (`tradeready-legal`, uncommitted):** `book.html` reads `?src=` and sends `leadSource` from `contactPayload()` only when non-blank. The auto-mode classifier blocked local commits in that repo, so the owner commits it (it sits beside the uncommitted Phase 25 `estimate.html`/`portal.html` changes).

**Intentional native difference:** the accountant package's `customers.csv` gains a trailing column, so that archive is no longer byte-identical to RN's (`docs/native-parity-matrix.md`, Accountant package row).

**Ship steps (owner):** deploy the Worker, publish `book.html`, then ship the native build. Older pages simply send no source, which falls back to "Online booking link".

**Residuals found while building:**
- `?src=` text is customer-controlled. It is capped at 40 characters and control-stripped, then reaches the customers CSV and the coach prompt the same way booking-supplied names already do.
- Undoing an import keeps blank-field fills on matched customers (pre-existing for email, phone and address).

