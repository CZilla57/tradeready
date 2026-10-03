# Quote Expiration Dates (Roadmap Phase 32) — Design Spec

**Date:** 2026-10-03
**Status:** BUILT 2026-10-03 in the working tree of local `feat/quote-expiration` (native + Worker) and, for `estimate.html`/`portal.html`, uncommitted in `tradeready-legal`. Nothing committed, pushed, deployed or applied; see §12 for the build record. Scoped as: builds on `feat/quote-expiration`, stacked on `feat/lead-source` (owner go-ahead 2026-10-03: "continue working until all features on the roadmap are properly completed … implemented in the most beneficial way to the user"). Code map verified 2026-10-03 against `feat/lead-source` at HEAD `2909fe5` plus its uncommitted lead-source work.
**Origin:** `docs/post-launch-feature-roadmap.md` Phase 32, build order #3 ("New services needed: None")
**Builds on:** estimate approval loop (`2026-07-17-estimate-approval-loop-design.md`), good/better/best options (`2026-10-02-quote-options-design.md`, Phase 25), portal requests (`2026-08-07-portal-completion-design.md`), estimate follow-up policy (`NativeEstimateFollowUp`), Today insights (`NativeTodayInsights`)
**Build target (owner, 2026-10-02):** native SwiftUI app, the Worker, and `estimate.html` / `portal.html` in `CZilla57/tradeready-legal` (stacked on that repo's `feat/quote-options` work). **No React Native changes.** The dormant Vercel twin (`backend/`) and the owner web app (`web/`) are not changed.

## 0. Preconditions verified against the repo

- **The 30-day promise is hard-coded and only printed.** `NativeEstimatePDF.swift:426-431` draws "This estimate is valid for 30 days." Nothing stores or enforces a date. The RN twin is `utils/pdfTemplates.ts:393`, which is out of scope.
- **An estimate is a `Job` blob.** `Canonical.Job` (`Domain/CanonicalModels.swift:936-1008`) has `estimateSentAt` (`:957`), a local `YYYY-MM-DD` written by `stampEstimateSent` (`AppStore.swift:2552-2581`) via `Date.dateOnlyString`, which uses the local calendar (`Models.swift:526-534`). Settings are also a blob (`Canonical.Settings`, `CanonicalModels.swift:1585+`). New optional keys need **no migration**.
- **Only one function moves an existing job to `estimate_sent`: `stampEstimateSent`.** (CSV import and sample data create jobs already in that status, with no send stamp.) It has three callers: `markEstimateSent` (`AppStore.swift:2491`), `recordEstimateDelivery` (`:2508`) and `createEstimateApprovalLink` (`:2584`). `advanceJobLifecycle` only moves `estimate_sent`/`scheduled` forward (`:4365`).
- **The approval snapshot is device-authored and frozen.**
  - `CanonicalUIAdapters.estimateApprovalSnapshot` (`Domain/UIModelAdapters.swift:320-364`) has exactly three callers (`AppStore.swift:1258, 2531, 2629`). Each one rebuilds the snapshot from the canonical job and compares it with `estimateApprovalSnapshotsMatch` (`UIModelAdapters.swift:533-552`).
  - The match compares typed fields plus preservation, so **any new typed snapshot field must be added to the match**.
  - The declined-revision guard in `estimateReviewDraft` (`AppStore.swift:1263-1268`) also uses the match.
- **The Worker trusts the snapshot.**
  - `create-link` (`backend-workers/src/routes/estimate/createLink.js:67-75`) validates only Phase 25 `options` before touching the DB.
  - `planApprovalWrite` (`lib/estimateStore.js:79-91`) keeps the token and replaces `snapshot`/`sentAt` unless the estimate is approved.
  - `view` spreads the snapshot and adds `snapshotDigest` (`src/routes/estimate/view.js:38-50`).
  - `snapshotDigest` hashes the whole canonical snapshot (`lib/estimate/quoteOptions.js:117-133`), so a new snapshot key is covered automatically.
- **`respond` has no clock seam and no expiry.** `consentAt` is `new Date().toISOString()` (`respond.js:71`). The terminal lock lives in `nextApproval` (`:39-53`). The digest check runs before selection resolution (`:89-103`), and the write is conditional with 3 attempts (`:76-119`).
- **The Worker already has owner-zone date helpers.** `nowInZone(timeZone, nowMs)` and `zonedTimeToUtc` live in `backend-workers/lib/booking/availability.js:263-325`, exported at `:327-334`. They are used by booking slots. Workers' `Intl` has full IANA data.
- **There is an insert-only, customer-triggered request channel to reuse.**
  - `portal-request` writes a `bookingRequests` row with `status: "portal_change_requested"`, `jobRef` and `portalKind` (`lib/estimate/portalRequest.js:89-101`). It uses `insertPortalRequest` with ignore-duplicates (`lib/estimate/portalRequestStore.js:18-31`) and emails the owner through the existing Resend path (`lib/booking/notifyOwner.js`).
  - Native surfaces unhandled rows of that status as an actionable Today row with "Mark done" (`Domain/NativeBookingAttention.swift:91-101, 188`). The presentation verb is hard-wired to cancel/reschedule (`Domain/NativeTodayBriefing.swift:433, 471`). Intake never converts these rows (`NativeBookingIntake.swift:23`).
- **The Phase 25 approval-preserve trigger** (`supabase/migrations/20261002_job_approval_preserve.sql:108-118`, not yet applied) protects only server-written approval keys. `snapshot` and `sentAt` are frozen once approved. A same-token snapshot replacement before approval passes through (rule 3).
- **`revise-declined`** strips `approval` and `estimateSentAt` and nothing else (`lib/estimateRevision.js:32`). The native response validator requires `estimateSentAt == nil` (`NativeEstimateApprovalLink.swift:204-210`, `AppStore.swift:2457-2468`).
- **Duplicate and recurring copies.**
  - `duplicateJob` is a whitelist (`UIModelAdapters.swift:231-272`), so a new job key is excluded automatically.
  - The recurring occurrence initializer assigns every stored property (`Domain/NativeRecurringJobs.swift:139-188`). A new `Canonical.Job` property must be set to `nil` there; the compiler enforces this.
- **Page behavior today.**
  - `estimate.html` sends `snapshotDigest` only for option estimates (`tradeready-legal/estimate.html:236-239`), and handles 409 only for them (`:247`). It shows no date and no business contact.
  - `portal.html` already formats owner-naive dates through UTC getters (`fmtDate`, `:218-222`). Its "needs review" count is every undecided estimate (`:410`).
- **The follow-up policy.**
  - One-shot `est_<jobId>` reminder at 9:00 local, 3 days after send (`NativeEstimateFollowUp.swift:41, 57-83, 106-125, 209-226`).
  - The coordinator owns every identifier with the `est_` prefix (`NativeEstimateFollowUpNotifications.swift:486-494, 713-715`).
  - The reschedule key folds in each `estimate_sent` job's `estimateSentAt`, customer name and title (`AppStore.swift:1303-1316`).
- **Today insights.**
  - `NativeTodayInsights.select` runs rules in priority order (`Domain/NativeTodayInsights.swift:125-146`). The `due_soon` rule is the model for a date window (`:272-314`).
  - Kinds are mirrored in the card policy (`Domain/NativeInsightsCardPolicy.swift:18-20, 39-50`). They are also in the analytics catalog `InsightKind` enum (`NativeAnalytics.swift:102`), which a host test proves equal to `docs/native-phase-11-platform-hardening-contract-decisions.md:1308`.
- **The PDF host suite compiles only the pure document model.** The renderer is `#if canImport(UIKit)` (`NativeEstimatePDF.swift:120`), so customer copy that must be tested belongs in `NativeEstimatePDFDocument`.
- **There is no Phase 25 "reset" operation.** The only estimate reset is `revise-declined`.

## 1. Recommendation (summary)

A sent estimate carries a **calendar date it is valid until, inclusive, in the owner's time zone**. The date is chosen when the owner sends the estimate. It defaults to *today + `estimateValidityDays`* (30 unless changed; 0 means no expiry) and can be edited per estimate in the review sheet.

The date is stored in two places:
- **On the job** as `estimateValidUntil`. Today, the follow-up reminder, job detail and the PDF read it. It works with or without an approval link.
- **Inside the frozen approval snapshot** as `validUntil` plus `validUntilTimeZone`. It is part of what the customer was shown and agreed to, and it is covered by the Phase 25 digest. The Worker enforces it.

The Worker refuses an **approval** after the date with **HTTP 410** (`code: "estimate_expired"`). Declining is still allowed. The customer page then offers **"Request an updated estimate"**. That posts to a new token-gated route, which writes an insert-only `portal_change_requested` row (`portalKind: "quote_update"`). It reuses the existing owner email and Today attention row, so no new service is involved.

The owner has two ways forward:
- **Extend:** a new date, the same token and the same prices. It goes through the existing `create-link`, so the customer's link works again.
- **Re-issue:** edit and resend through the existing review flow, with a fresh date.

The 3-day follow-up mentions the date. A second one-shot reminder fires 2 days before expiry. Two new Today insights cover "expires soon" and "expired".

## 2. Data model (additive-optional; absent = today's behavior)

### 2.1 Settings

```ts
// Settings.estimateValidityDays?: number   — integer 0…365. Absent = 30. 0 = estimates don't expire by default.
```

- The 30-day default keeps the promise the PDF already prints. Previously sent estimates are **not** expired retroactively, because they carry no date.
- `NativeQuoteExpiry.validityDays(settings)` clamps a malformed value into 0…365.

### 2.2 Job

```ts
// Job.estimateValidUntil?: string   — local "YYYY-MM-DD", inclusive. The validity of the MOST RECENT send.
//                                     Absent on a sent estimate = no expiry. Meaningful only while status is
//                                     "estimate_sent"; every reader gates on that status.
```

- It is written **only** together with a send stamp or by an owner extension (§3).
- It is never written when a review sheet is merely opened.

### 2.3 Approval snapshot

```ts
// EstimateApprovalSnapshot.validUntil?: string          — "YYYY-MM-DD", the date the customer is shown
// EstimateApprovalSnapshot.validUntilTimeZone?: string  — IANA id the date is evaluated in, e.g. "America/Phoenix"
// Both present or both absent.
```

- **Why the snapshot, not just the job.**
  - The validity date is a term of the offer. The approval record should show that the customer approved a $X offer valid until Y, before Y.
  - The server must enforce against what the customer saw, not against a mutable job field that any device push can rewrite and the digest does not cover.
  - Because the date sits in the digest, an extension invalidates an open page (409, then reload), and the customer always approves the date they were shown.
- **Compatibility.** Old readers (portal list, `web/`, an old page) ignore the keys. Old native builds keep them in `preservation`.

### 2.4 The expiry rule (one rule, both sides)

> An estimate is **expired** at instant *now* iff it has a `validUntil` **and** `today(now, zone) > validUntil` (string compare of `YYYY-MM-DD`), where `zone` = `validUntilTimeZone` if the runtime resolves it, else `Etc/GMT+12` ("anywhere on Earth": never expires early).

- The last valid moment is 23:59:59.999 local on `validUntil`.
- There is no instant arithmetic, so DST is irrelevant.
- The Worker computes `today` with the existing `nowInZone`. The device computes it with a `Calendar` in that zone.
- Parity vectors live in one shared fixture: `native/QuoteExpiryTests/Fixtures/quote-expiry-vectors.json`.

### 2.5 How the server knows the owner's time zone: options compared

| Option | What is stored | Verdict |
|---|---|---|
| **A. Date + IANA zone (chosen)** | `validUntil` + `validUntilTimeZone` | One source of truth (the calendar date the customer sees is the date enforced). DST-proof without instant math. Server helper already exists and is tested. An unknown zone degrades to "anywhere on Earth", never to an early expiry. |
| B. Absolute end-of-day instant computed on device | `validUntil` + `expiresAt` ISO | Two representations that can disagree. The device's end-of-day computation is exactly the FA-039 bug class. The page still needs the date to display. |
| C. Date only, server uses UTC or anywhere-on-Earth | `validUntil` | UTC expires a Phoenix quote at 17:00 local, which is early, an FA-039 bug. Anywhere-on-Earth lets a US quote be approved 4–10 h after local midnight, so the record would show an approval dated after the stated validity. |

**Zone source:** `TimeZone.current.identifier` when the review draft or extension is built. That is the same zone every other local date in the app (`estimateSentAt`, Today, follow-ups) is computed in, so the device's "expires today" and the server's enforcement agree. `settings.schedule.timeZone` (booking) is deliberately not used; see §10.

## 3. Lifecycle: when the date is set and how it moves

| Situation | Rule |
|---|---|
| Review sheet opens on a `lead` | Proposes `today + validityDays`, or none when `validityDays == 0`. Any stale `estimateValidUntil` on a lead is **ignored**. A revised estimate is a new offer |
| Review sheet opens on an `estimate_sent` job (re-send / re-issue) | Keeps `estimateValidUntil` when it is ≥ today. If it is past or absent, proposes `today + validityDays` |
| Owner edits the date in the review sheet | Any date in today…today+365, or "Doesn't expire". The draft and its snapshot are rebuilt with that value |
| Send stamp (`markEstimateSent`, `recordEstimateDelivery`, `createEstimateApprovalLink`) | `stampEstimateSent` writes `status`, `estimateSentAt` **and** `estimateValidUntil = draft.validUntil` (removes the key for "Doesn't expire") in one save and one upsert |
| Extend (§6.5) | Writes only `estimateValidUntil`. `estimateSentAt` and the follow-up clock are unchanged. If a link exists, the server snapshot is refreshed under the same token |
| `revise-declined` | Worker planner also strips `estimateValidUntil` (§4.7). The device ignores it on leads anyway, so rollout order doesn't matter |
| Approved (link or owner-recorded) | Expiry no longer matters. The frozen snapshot keeps its date as part of the consent record |
| Owner "Mark as approved by customer" after expiry | Allowed: the owner decides to honor it. Job detail shows "This estimate expired on Nov 2. Check your pricing before accepting it." |
| Duplicate / recurring / CSV import / sample data | No date (whitelist, explicit `nil`, never imported) |

## 4. Worker (`backend-workers/`)

### 4.1 New pure module `lib/estimate/estimateExpiry.js` (CommonJS)

- `ANYWHERE_ON_EARTH_ZONE = 'Etc/GMT+12'`.
- `isResolvableTimeZone(tz)`: `new Intl.DateTimeFormat('en-US', { timeZone: tz })` succeeds.
- `validateSnapshotValidity(snapshot, nowMs)` returns `null` or a client-safe error. It runs **only when either key is present**:
  - Exactly one of the two keys → `Valid-until date and time zone must be sent together.`
  - `validUntil` not a real `YYYY-MM-DD` (regex plus a `Date.UTC` round trip) → `The valid-until date is invalid.`
  - `validUntilTimeZone` not a non-empty string of ≤ 64 characters → `The valid-until time zone is invalid.`
  - An *unresolvable* zone is **accepted**: a warning is logged and enforcement uses anywhere-on-Earth. The server must never rewrite a device-authored snapshot, and refusing would block sending over an ICU alias mismatch.
  - `validUntil` < today in the zone → `The valid-until date is in the past.` This stops a link from being born expired.
  - More than 400 days ahead → `The valid-until date is too far in the future.` This is a garbage guard; the UI caps at 365.
- `snapshotExpiry(snapshot, nowMs)` returns `{ validUntil: string|null, expired: boolean }` per §2.4.
- `formatValidUntil(ymd)` returns `"November 2, 2026"` via `Intl.DateTimeFormat('en-US', { dateStyle: 'long', timeZone: 'UTC' })` on `ymd + 'T00:00:00Z'`, so it never shifts a day.

### 4.2 `create-link`

After the options check (`createLink.js:72-75`), and still before any DB contact: `validateSnapshotValidity(snapshot, Date.now())`, returning 400 on error. `planApprovalWrite` is unchanged. Extension and re-issue both reuse it, keeping the token and replacing snapshot and `sentAt` while unapproved.

### 4.3 `view`

- Adds `expired: boolean` = `decision !== 'approved' && snapshotExpiry(a.snapshot, Date.now()).expired`.
- `validUntil` and `validUntilTimeZone` already arrive through the snapshot spread.
- Nothing else changes.

### 4.4 `respond`

- Read `const nowMs = Date.now()` once at the top of the handler, so tests stub `Date.now`.
- Add one check inside the attempt loop, **after** the digest check and **before** `resolveSelection`:
  ```js
  if (decision === 'approved' && existing.decision !== 'approved') {
    const { validUntil, expired } = snapshotExpiry(existing.snapshot, nowMs);
    if (expired) return c.json({ error: expiredMessage(existing.snapshot, validUntil), code: 'estimate_expired', validUntil }, 410);
  }
  ```
- `expiredMessage`: `This estimate expired on ${formatValidUntil(validUntil)}. Please ask ${businessName || 'the business'} for an updated estimate.`
  - The text works on its own, so an **old** page that shows `out.error` degrades gracefully.
- Behavior around the check:
  - An already-approved estimate keeps returning its locked state.
  - A stale page still gets 409 first. It reloads into the expired view.
  - An expired option estimate gets 410, not "Please choose an option."
- **Decline after expiry is allowed.** It tells the owner "no" and the reconciler closes the job. Declined → re-approve after expiry is refused by the same check.
- `nextApproval` and `change-respond` are untouched. Change orders don't expire.

### 4.5 New route `POST /api/estimate/request-update`

`src/routes/estimate/requestUpdate.js` is a thin Hono shell: `applyCors` and `createRateLimiter({ limit: 5 })` per IP. The core logic is `lib/estimate/estimateUpdateRequest.js` `estimateUpdateRequestCore(env, { body, ip, nowMs })`, testable like `portalRequestCore`. It is wired in `src/index.js` before the `/api/estimate/:action` catch-all (`:90`).

Body: `{ jobId, token, note?, website }`.

1. Honeypot: a non-empty `website` returns a fake `200 { ok: true }` and writes nothing.
2. Missing `jobId`/`token` → 400 `Missing link parameters.`. `note` is trimmed and capped at 300 characters.
3. `fetchJob` plus a constant-time token check → 404 `This link is invalid or has expired.`
4. Already approved → 409 `{ error: 'This estimate was already approved.', code: 'already_approved' }`.
5. Not expired → 409 `{ error: 'This estimate is still open. Please reload the page.', code: 'estimate_not_expired' }`.
6. Build the row. Contact fields are not copied, because the owner has them on the job. Less PII moves.
   ```js
   {
     id: `bkeu_${sha256(`${jobId}|${token}|${validUntil}`).slice(0, 20)}`,  // one request per expiry episode
     status: 'portal_change_requested', portalKind: 'quote_update', jobRef: jobId,
     name: cap(snapshot.customerName || data.customerName, 120), phone: '', email: '', address: '',
     details: `Updated estimate requested for "${cap(snapshot.jobTitle, 200)}" (expired ${formatValidUntil(validUntil)})${note ? ` — ${note}` : ''}`,
     preferredTiming: '', createdAt: new Date(nowMs).toISOString(),
     source: 'estimate', sourceCustomerId: typeof data.customerId === 'string' ? data.customerId : undefined,
   }
   ```
7. Insert through a new store helper `insertRequestIfAbsent(env, userId, request) → boolean` in `portalRequestStore.js`. It uses `Prefer: resolution=ignore-duplicates,return=representation`, and returns true only when a row was created.
8. Only when the row was inserted: `notifyOwnerUpdate(env, { userId, settingsData, request, event: 'quote_update', note })`. This is fire-and-forget and uses the existing Resend email (push is a no-op on native today).
9. Return `200 { ok: true }`. A retry or a second click is a silent idempotent success.

Why this shape:
- It is insert-only, so it is outside the job blob's last-write-wins race and needs **no trigger change**.
- One row per expiry episode replaces the portal's daily-cap table, so it needs no `portal_access_log` dependency.
- The owner sees it through the shipped attention pipeline.

### 4.6 Portal (`lib/estimate/portalAssemble.js`)

- `buildEstimates(jobRows, nowMs)` gains `validUntil` (string|null) and `expired` (boolean, false once decided).
- `assemblePortalView` passes its existing `nowMs`.
- The allowlist test is updated for the two keys.

### 4.7 `revise-declined` planner

`planDeclinedEstimateRevision` also drops `estimateValidUntil` (`const { approval, estimateSentAt, estimateValidUntil, ...rest } = job`). The native validator does **not** require its absence, so a new device works against an old Worker.

### 4.8 `notifyOwner.js`

- `UPDATE_TITLES.quote_update = 'Updated estimate requested'`.
- The push `data.jobId` becomes `request.convertedJobId || request.jobRef`.

## 5. Public pages (`tradeready-legal`, branch `feat/quote-expiration` on top of `feat/quote-options`)

### 5.1 `estimate.html`

- **Date display:** `fmtLongDate(ymd)` uses UTC getters (the portal's `fmtDate` precedent) → "Monday, November 2, 2026". When the viewer's resolved zone differs from `validUntilTimeZone`, it appends the owner zone's long name, e.g. "(Mountain Standard Time)", via `Intl` `timeZoneName: 'long'`.
- **Valid, undecided:** under the From/For line, `<p class="muted">Valid until Monday, November 2, 2026</p>`. The single-total and options renderings both get it.
- **`view.expired === true`** (undecided or declined): the expired view replaces the approve UI.
  - Banner (`.banner.warn`, new amber style): "This estimate expired on Monday, November 2, 2026."
  - Copy: "Prices may have changed since {businessName} sent it. Ask for an updated estimate and they'll get back to you."
  - The title, the From/For line, and "Quoted total: $4,200" (options: "Quoted from $1,200", the lowest tier).
  - Optional textarea "Anything to add? (optional)", `maxlength=300`, plus the honeypot.
  - Primary button **"Request an updated estimate"** posts `{ jobId, token, note, website }` to `/request-update`.
    - On 200 the banner becomes ok: "Request sent. {businessName} will get back to you with an updated estimate."
    - On 409 `estimate_not_expired` → the reload banner.
    - On 409 `already_approved` or a 404 → the error text.
  - Secondary button "No longer interested" posts a decline with the digest.
  - Small note: "Your request goes directly to {businessName}."
- **Approve returns 410:** call `load()`, which renders the expired view.
- **Digest:** always sent (legacy included), and 409 shows the reload banner for every estimate. This closes the "approve a snapshot you never saw" window for single-total estimates too, which an extension would otherwise open.
- The consent footer (`:54`) is unchanged.

### 5.2 `portal.html`

- An undecided estimate with `validUntil`: meta "{amount} · Valid until Nov 2".
- An expired estimate:
  - Chip "Expired" (`chip-err`) and meta "{amount} · Expired Nov 2".
  - The action reads "Request an Update" and links to `approvalUrl`, where the estimate page handles it.
  - It is excluded from `needsReview`.

## 6. Native (`native/TradeReadyNative/`)

### 6.1 Canonical models

- `Canonical.Settings.estimateValidityDays: Int?`
- `Canonical.Job.estimateValidUntil: DateString?`
- `EstimateApprovalSnapshot.validUntil: DateString?` and `validUntilTimeZone: String?`
- All use the `ObjectReader`/`ObjectWriter` `optional`/`putOptional` pattern.
- `NativeRecurringJobs` occurrence initializer: `self.estimateValidUntil = nil`.
- `estimateApprovalSnapshotsMatch` compares the two snapshot fields.
  - A new parameter `ignoringValidity: Bool = false` compares as if both were absent.
  - Use `ignoringValidity: true` in the **declined-revision guard** (`AppStore.swift:1263-1268`). Otherwise a fresh date alone would let an unrevised declined estimate be re-sent.
  - Also use it in the extension check (§6.5).
- `estimateApprovalSnapshot(job:customerName:businessName:validUntil:validUntilTimeZone:)`: new parameters defaulting to `nil`. It throws `invalidCanonicalRecord("estimate-validity")` when exactly one is set. The builder stays free of any new file dependency.
- UI model `BusinessSettings.estimateValidityDays = 30`. The settings adapters read it with absent → 30, write it on create, and write it on edit only when changed (`UIModelAdapters.swift:775, 928, 1035`).

### 6.2 New pure domain `Domain/NativeQuoteExpiry.swift` (Foundation only, no app-file dependencies)

```swift
enum NativeQuoteExpiry {
    static let defaultValidityDays = 30, maximumValidityDays = 365
    static let expiringSoonDays = 3, expiredLookbackDays = 14, expiryReminderLeadDays = 2
    static let anywhereOnEarthZoneID = "Etc/GMT+12"
    static func validityDays(_ settings: Canonical.Settings?) -> Int
    static func today(now: Date, calendar: Calendar) -> String                 // local YYYY-MM-DD
    static func addDays(_ ymd: String, _ days: Int) -> String?                 // civil math in a UTC gregorian calendar
    static func days(from: String, to: String) -> Int?
    static func proposedValidUntil(job: Canonical.Job, validityDays: Int, today: String) -> String?   // §3 rules
    static func isSelectable(_ ymd: String?, today: String) -> Bool           // nil, or today…today+365
    enum State: Equatable { case open(validUntil: String, daysLeft: Int), expired(validUntil: String, daysAgo: Int) }
    static func state(job: Canonical.Job, today: String) -> State?             // nil unless estimate_sent with a valid date
    static func isExpired(validUntil: String, timeZoneID: String?, now: Date) -> Bool   // §2.4 parity rule
    static func displayDate(_ ymd: String, style: DisplayStyle) -> String     // .long "November 2, 2026", .medium "Nov 2, 2026", .short "Nov 2"
    static func relativePhrase(daysLeft: Int) -> String                       // "today" / "tomorrow" / "in 3 days"
}
```

`displayDate` builds the date from parsed components and formats it in UTC with `en_US`. It never runs a bare-date `Date` parse in the device zone (FA-039).

### 6.3 Settings UI

`PricingSettings` (`SettingsView.swift:226-251`) gains a section:

- Header **"ESTIMATES"**.
- Row **"Valid for"**: a numeric `TextField` followed by "days". It is clamped to 0…365 on commit.
- Footer: "New estimates get a valid-until date this many days after you send them. Customers can't approve an estimate online after that date. Enter 0 for estimates that don't expire. You can change the date on each estimate before you send it."

### 6.4 Capture: review sheet and send stamping

- **The review draft.**
  - `NativeEstimateReviewDraft` gains `validUntil: String?` and `validUntilTimeZone: String`.
  - `estimateReviewDraft(jobID:validUntil:)` takes an optional override; without it, the date is `proposedValidUntil`. The zone is `TimeZone.current.identifier`.
  - The snapshot is built with both values.
- **The review sheet** (`NativeEstimateReviewView`): `draft` becomes `@State`.
  - The "Estimate" section shows **"Valid until"** with "Nov 2, 2026" or "Doesn't expire".
  - Tapping it opens a `DatePicker` (today…today+365) and a "Doesn't expire" toggle. A change rebuilds the draft through the store.
  - Messages the owner hasn't edited are regenerated. Edited ones keep their text, with the footnote "Your edited message may mention the old date. Use Restore default message to update it."
  - The control is disabled once a link was created in this sheet session.
- **When an undecided link already exists.**
  - The link button reads **"Update approval link"**.
  - If the draft's date differs from the link snapshot's, the sheet notes: "The customer's approval link still shows {old date}. Update the approval link so it matches."
- **Stamping.**
  - `markEstimateSent(id:from:validUntil:on:)`, `recordEstimateDelivery` and `createEstimateApprovalLink` pass `review.validUntil` to `stampEstimateSent`, which writes it per §3.
  - `recordEstimateDelivery` rebuilds with the review's date and zone.
  - `createEstimateApprovalLink` additionally requires `currentJob.estimateValidUntil == review.validUntil` after the post-sync pull. Otherwise it fails with `.estimateChanged`, closed.

### 6.5 Extend and re-issue

**`AppStore.extendEstimateValidity(jobID:validUntil:) async -> NativeEstimateExtensionOutcome`**
- Outcomes: `.extended(link: URL?)`, `.failure(NativeEstimateExtensionError)`.
- Eligible: `status == estimate_sent`, `approval?.decision` absent, and `isSelectable(validUntil)`. Otherwise `.notEligible`: "The customer already responded to this estimate."
- **No approval link:** a local save of `estimateValidUntil` plus an upsert. Done.
- **With an undecided link:**
  1. Run the `createEstimateApprovalLink` guards: sync, then account/subject/binding re-checks, a completed pull, and no queued `jobs` mutation for the job.
  2. Rebuild the snapshot from the pulled job with the **new** date and the current zone.
  3. Require `estimateApprovalSnapshotsMatch(rebuilt, current.approval.snapshot, ignoringValidity: true)`. Otherwise `.pricingChanged`: "This estimate changed after it was sent. Review and resend it so the customer sees the new version and date."
  4. Call `service.createLink`. The token is the same, so the URL is unchanged.
  5. **Only then**, in one save and one upsert, write `estimateValidUntil` and the approval mirror (`estimateApprovalAfterLink`). A failed call leaves the device unchanged, so the device never shows a date the link doesn't have.
- `estimateSentAt` is not re-stamped.

**UI (job detail, `estimate_sent`):**
- The Status section shows "Valid until · Nov 2, 2026 (in 12 days)", or "Expired · Nov 2, 2026" in `tradeWarningText`. Nothing shows when there is no date.
- Button: **"Extend estimate…"** when expired, otherwise **"Change valid-until date…"**. It opens a sheet titled "Valid-until date" with a `DatePicker`, the "Doesn't expire" toggle and Save.
- On success, alert "Estimate extended" with:
  - "Valid until Dec 1, 2026. The customer's approval link works again." (with a link) or "Valid until Dec 1, 2026." (without).
  - Actions **"Let the customer know"** and "Done". The first opens the existing follow-up composer with the extension draft (§6.7) and the returned URL.

**Re-issue** is the existing "Review or resend estimate" after any pricing edit. The draft proposes a fresh date when the current one is past (§3). `create-link` keeps the token, so the customer's old link shows the new estimate. No new route is needed.

### 6.6 Customer documents

- **PDF (`NativeEstimatePDFDocument`).** It gains pure properties so the host suite tests them:
  - `validUntil: String?` and `validUntilDisplay: String?` (medium style).
  - `closingNote: String`:
    - With a date: "This estimate is valid until November 2, 2026. Reply to approve and we'll get you scheduled." For options: "…Reply with the option you'd like and we'll get you scheduled."
    - Without a date: the same sentences minus the validity clause.
  - The renderer draws `closingNote`, replacing `:426-431`. The header block becomes "Date  Oct 3, 2026\nValid until  Nov 2, 2026\nPending approval" (the "Valid until" line only when dated; block height 48).
- **Message drafting (`NativeEstimateMessageDrafting`).**
  - Email: after the total (single estimate) or the last option total, add "This estimate is valid until November 2, 2026."
  - Text: "Valid until Nov 2." before the call to action.
  - Both channels, single and options. Nothing is added when there is no date.

### 6.7 Follow-up reminder and messages

`NativeEstimateFollowUp` (gains `now: Date` / `calendar` parameters where needed):

- **3-day reminder body**, when dated. The phrase is computed for the fire date:
  - Still valid: `Estimate for "{title}" sent 3 days ago with no response. It expires {Nov 2}. Tap to follow up.`
  - Already past: `…It expired {Nov 2}. Tap to follow up.`
- **New expiry reminder** `est_exp_<jobId>`, at 9:00 local on `validUntil − 2 days`.
  - Same `estimate_follow_up` tap type and the same coordinator, since it falls inside the owned `est_` prefix.
  - Title `Estimate expiring — {customerName}`; body `Your estimate for "{title}" expires in 2 days ({Nov 2}). Tap to follow up or extend it.`
  - Scheduled only when its fire date is after the 3-day reminder's and in the future. Short validities fold into the 3-day copy.
  - `upcomingReminders` returns both kinds, and `notificationPlan` keeps its 60 cap.
- **The reschedule key** (`AppStore.swift:1314`) adds `job.estimateValidUntil ?? ""` to each `est_` row.
- **Follow-up message to the customer:**
  - Valid: `Hi {first}, just checking in on the estimate I sent over for {title} ({amount}). It's valid until {November 2}. Happy to answer any questions — want me to get you on the schedule?`
  - Options: `…your quote options for {title} (from {X}). They're valid until {November 2}. …`
  - Expired: `Hi {first}, just checking in on the estimate I sent over for {title}. It expired on {November 2}, but I'm happy to put together an updated one — want me to take another look?`
- **Extension notice** (`extensionDraft`):
  - Body `Hi {first}, good news — I've extended your estimate for {title} ({amount}) until {December 1}. You can review and approve it here: {url}`. Without a link: `… until {December 1}. Just reply to approve and I'll get you on the schedule.`
  - Subject `Your estimate from {businessName} has been extended`.

### 6.8 Today insights (`NativeTodayInsights`)

Both kinds read `NativeQuoteExpiry.state(job:today:)` for non-archived `estimate_sent` jobs. `today` is `NativeCashBasis.ymd(now)`, so the date is local and FA-039 safe.

| Kind | Window | Single row | Aggregate (≥2) | Mute |
|---|---|---|---|---|
| `quote_expiring` | `0 ≤ daysLeft ≤ 3` | id `quote_expiring:<jobId>:<validUntil>`. Title "Estimate for {customer} expires {today/tomorrow/in N days}". Detail "{title} · {amount}". Target `.job` | id `quote_expiring:all`. "{N} estimates expire within 3 days". Target `.jobs` | Not muteable: it resolves on its own |
| `quote_expired` | `1 ≤ daysAgo ≤ 14` | id `quote_expired:<jobId>:<validUntil>`. Title "Estimate for {customer} expired {Nov 2}". Same detail and target | id `quote_expired:all`. "{N} estimates expired in the last 2 weeks" | Dismiss-only: the id carries the date, so an extension re-arms it |

- **Reason text.**
  - Expiring: "You sent '{title}' on {sent} and it's valid until {date}. After that the customer can't approve it online. Follow up now or extend it."
  - Expired: "'{title}' passed its valid-until date ({date}) without a response, so the customer can no longer approve it online. Extend it, send an updated estimate, or let it go. Dismissing hides this until the date changes."
- **Coach prompt (expiring):** "My estimate for '{title}' ({amount}) to {customer} expires {phrase} and they haven't answered. What's a good follow-up, and should I extend it?"
- `{amount}` is "from $X" for undecided options.
- **Priority:** `quote_expiring` right after `due_soon`; `quote_expired` after the schedule rules and before `maintenance_due`.
- **Also updated:** `NativeInsightsCardPolicy` (`muteableKinds` gains `.quoteExpired`; symbols `hourglass` / `hourglass.bottomhalf.filled`), and the analytics catalog `InsightKind` in **both** `NativeAnalytics.swift:102` and the Phase 11 contract doc JSON. The change is additive, so `catalogVersion` stays 1.

### 6.9 Customer requests (`quote_update`)

- `NativeTodayBriefing.bookingRowPresentation` and `bookingRowLabel` special-case `portalKind == "quote_update"`:
  - Title and label: "{name} asked for an updated estimate".
  - Body: the server details. Destination `.job(jobRef)`.
- `NativeBookingAttention` needs no change. The row is a `.portalChange` (or `.missingJob`) with "Mark done", per D-B3-3.
- The owner acts from the job: extend, or edit and resend.

### 6.10 Approval link service

`NativeEstimateApprovalLinkService.createLink` maps **400** to a new `NativeEstimateApprovalLinkError.estimateRejected`: "The approval service couldn't accept this estimate's details. Review the estimate, check its valid-until date, and try again." Today a 400 shows as "unavailable".

## 7. Interactions

| Situation | Behavior |
|---|---|
| Options (Phase 25) | The date is top-level and applies to every tier. `snapshot.options` and the selection math are unchanged. An expired options estimate gets 410 before selection resolution. The portal shows "Expired · quoted from $X" |
| Digest | Covers `validUntil` and its zone with no code change. Extend and re-issue change the digest, so open pages get 409, then reload |
| Decision reconciler / rebase graft (Phase 25 §6.3) | Unchanged. Expiry adds no server decision. A decline after expiry flows through normally |
| Approval-preserve trigger | Unchanged and no migration. The date is device-authored inside `snapshot`, frozen on approval. Pre-approval same-token replacement (extend, re-issue) is rule 3 |
| Customer page open during an extension | 409 reload, then the page shows the new date |
| Request-update racing an extension | 409 `estimate_not_expired`, reload, then the valid page |
| Owner re-sends by composer only while a link exists | The link keeps its old date until "Update approval link". The sheet warns about this (§6.4) |
| Old native build | Preserves every new key as unknown. A re-send from it would drop the snapshot date (no users; accepted) |
| RN client | Spreads preserve `estimateValidUntil` and `estimateValidityDays`. An RN re-send mirrors `{token, sentAt, snapshot}` without a date, which removes expiry server-side. RN labels a `quote_update` row "asked to reschedule" (`screens/TodayScreen.tsx:580`). No RN users and no RN changes; accepted |

## 8. Testing

**New Swift `QuoteExpiryTests`** (runner `native/run-quote-expiry-tests.sh`, executed as `TZ="${TZ:-America/Phoenix}"` like the store runners, registered in `run-all-domain-tests.sh`):
- `validityDays` cases: absent, 0, clamping.
- `addDays`/`days` across month ends, year ends and Feb 29.
- `proposedValidUntil`: every §3 row.
- `isSelectable` bounds.
- `state` windows.
- `displayDate` in a Phoenix calendar: "2026-11-02" stays Nov 2.
- **FA-039:** at `2026-10-03T06:30Z` (Oct 2, 23:30 MST) `today` is `2026-10-02` and +30 is `2026-11-01`, not Nov 2.
- `isExpired` against the shared vectors.

**Shared fixture `quote-expiry-vectors.json`, also loaded by the Worker:**
- Phoenix: `validUntil 2026-11-02` is valid at `2026-11-03T06:30Z` (23:30 local) and expired at `07:00Z`.
- New York across the DST end on 2026-11-01: valid at `2026-11-02T04:59:59Z`, expired at `05:00:00Z`.
- Auckland: expired at `2026-11-02T11:00Z` while the UTC date is still Nov 2.
- Unknown zone `Mars/Olympus` uses anywhere-on-Earth: expired at `2026-11-03T12:00Z`, not before.
- No date: never expires.

**Updated Swift suites. New runner files get `NativeQuoteExpiry.swift`:**
- canonical: round-trip and preservation of the four new keys.
- adapter:
  - The builder parameters and the both-or-neither throw.
  - The match compares validity; `ignoringValidity` ignores it.
  - Settings absent → 30, written only when changed.
- estimate PDF: `closingNote` and `validUntilDisplay`, single and options, with and without a date.
- message drafts: both channels, single and options.
- estimate follow-up: message variants; notification copy; `est_exp_` fire at 9:00 Phoenix; the fold rule; short validity.
- follow-up notifications coordinator: two items per job under `est_`; the cap.
- today insights:
  - Windows, aggregation, archived and status gates, ids.
  - "Expires today" at 23:30 local.
  - Priority order.
- insight card policy and mutes.
- analytics catalog: the fixture equals the doc.
- today briefing: `quote_update` presentation.
- recurring: date is `nil`.
- duplicate: excluded.
- approval link service: the 400 mapping.

**Runner registration.** Add `NativeQuoteExpiry.swift` to:
- `run-appstore-sources-common.sh`
- the estimate-follow-up, estimate-follow-up-notification, appointment-notification, notification-coordinator, notification-permission, review-request, phase10-qualification, today-insights, today-briefing, estimate-pdf and estimate-message-draft runners
- the Xcode project

**New store runner `native/run-quote-expiry-store-tests.sh`** (in-memory Supabase, fake link service):
- Stamping writes or removes the date on all three send paths.
- `recordEstimateDelivery` matches with a custom review date.
- `createEstimateApprovalLink` fails closed when the pulled date differs.
- The declined-revision guard still blocks an unrevised re-send that has a fresh date.
- Extend with no link is local only.
- Extend with a link refreshes under the same token and mirrors.
- Extend is refused with `.pricingChanged` after a pricing edit and leaves the device unchanged.
- Extend is refused once decided.

**Worker `node:test` (`backend-workers/tests/estimateExpiry.test.cjs`, mirroring `quoteOptions.test.cjs` with a stubbed `fetch` and `Date.now`):**
- `validateSnapshotValidity` cases, and `snapshotExpiry` against the shared vectors.
- `create-link` 400s.
- `view.expired`.
- `respond`:
  - Approve is 410 with `code` and message.
  - Decline is 200 after expiry.
  - Already-approved stays locked.
  - A stale digest is 409 before the 410.
  - Options are 410 before "choose an option".
  - Undated estimates are unaffected.
- `estimateRevision.test.cjs`: the planner strips `estimateValidUntil`.

**Root Jest:**
- New `__tests__/estimateUpdateRequestWorkers.test.js`, mirroring `portalRequestWorkers.test.js`:
  - honeypot, 400/404/409 paths
  - the row shape and its deterministic id
  - insert-if-absent drives notify-once
  - the note cap
- `__tests__/portalAssembleWorkers.test.js`: allowlist keys plus valid/expired cases.

**Pages:** a headless jsdom check with a stubbed API, as Phase 25 did:
- Valid shows the date, and under `TZ=America/Phoenix` it doesn't shift.
- The expired view renders and the request body is correct.
- 410 → reload into the expired view; 409 on request → the reload banner.
- The digest is always sent.
- The portal shows the chip, meta and `needsReview` count.
- Markup in names is escaped.

**Gates:**
- `sh native/run-all-domain-tests.sh`
- the Release `xcodebuild` compile
- `cd backend-workers && npm test && npm run check`, also with `TZ=America/Phoenix npm test`, which proves the Worker never reads the process zone
- `TZ=America/Phoenix npm test -- --runInBand --runTestsByPath __tests__/estimateUpdateRequestWorkers.test.js __tests__/portalAssembleWorkers.test.js`
- `sh native/run-doc-reference-check.sh`

## 9. Rollout order

1. **Worker deploy.** It is backward compatible: undated snapshots behave exactly as today, `view` adds `expired: false`, and the new route is unused until the page ships.
2. **`tradeready-legal` pages.** An old page still degrades safely, because a 410's `error` text is complete.
3. **The native build.**

The Phase 25 ship steps (trigger migration first) are unchanged and still gate the native build. Deploys and applies are the owner's. Nothing here is deployed or pushed.

## 10. Accepted residuals

- **Vercel twin** (`backend/lib/estimate/*`): not updated. A rollback to Vercel would accept approvals after expiry.
- **`web/` owner app**: shows no dates.
- **The RN PDF** still prints "valid for 30 days".
- **A stale device push can revert an extension.** A queued edit on another device can push the old same-token snapshot back (trigger rule 3). This is the same window every same-token re-send has today. General conditional device writes remain the unmerged `feat/estimate-conditional-writes`.
- **Owner time zone is the device zone at send.** An owner who sends while travelling gets enforcement in that zone. Using `settings.schedule.timeZone` instead would split the device's Today math from server enforcement, and it is only set for bookable slots.
- **A date chosen in a review sheet closed without sending is not remembered.** The next sheet re-proposes the default. A PDF exported from the abandoned sheet shows the abandoned date.
- **Composer-only re-sends don't refresh an existing link's date.** The sheet warns (§6.4); the owner taps "Update approval link".
- **The request-update page can't show "already requested" after a reload.** A second tap is a silent no-op success.
- **No new analytics events.** Extensions and update requests aren't instrumented this phase.
- **The Jobs list shows no expiry badge.** Job detail, Today and notifications cover it. A list caption is a small follow-up.

## 11. Decisions recorded (recommendations; owner may override)

| # | Decision | Choice |
|---|---|---|
| D1 | Where the date lives | Job `estimateValidUntil` (owner side) **and** snapshot `validUntil` + `validUntilTimeZone` (consent + enforcement, in the digest) |
| D2 | How the Worker knows the owner's zone | Date + IANA zone, evaluated with the existing `nowInZone`. An unresolvable zone uses anywhere-on-Earth (never early) |
| D3 | Zone source | Device `TimeZone.current` when the date is chosen |
| D4 | Default validity | `estimateValidityDays`; absent = 30, 0 = no expiry, max 365; editable per estimate in the review sheet |
| D5 | When it is set | At the send stamp, from the review draft. A re-send keeps a still-valid date, and an expired or absent one gets a fresh proposal |
| D6 | Server enforcement | Approve after expiry → **410** `estimate_expired` with complete error text. Decline still allowed. The approved lock is unaffected |
| D7 | "Request an updated estimate" | New token-gated `POST /api/estimate/request-update` → insert-only `portal_change_requested` row (`portalKind: "quote_update"`) + existing owner email. One per expiry episode. No new service, no migration |
| D8 | Extend vs re-issue | Extend = new date, same token, same prices via the existing `create-link`, refused if anything else changed. Re-issue = the existing review/resend with a fresh date |
| D9 | Reminders | 3-day follow-up copy names the date, **plus** a second one-shot reminder 2 days before expiry |
| D10 | Today insights | Two kinds: `quote_expiring` (≤3 days, self-resolving) and `quote_expired` (≤14 days, dismiss-only) |
| D11 | Job status | No new status. Expiry is derived from the date |
| D12 | Customer-facing word | "estimate" everywhere (matches the PDF, page and app), including "Request an updated estimate" |
| D13 | Page digest | Always sent, for legacy estimates too |
| D14 | Migration | None. All new fields ride existing JSON blobs and the existing `bookingRequests` table |

**Needs the owner (flagged, not blocking scoping):**
- **Legal text.**
  - `terms.html` §8 (estimate approvals) doesn't mention that estimates can expire.
  - `privacy.html` covers approval records (`:114`) but not customer-submitted requests: booking link, portal, and now the update request with an optional note.
  - The spec changes **no** legal text. Adding a sentence to each is recommended but is an owner call.
- **Enforcement starts on the 30-day default.** That default was previously only printed. Owners who relied on it being unenforced should set 0.
- **D9 adds a new notification**, and **D12 picks "estimate" over the roadmap's "quote" wording**. Both are copy and product choices the owner can flip cheaply.
- **The analytics `InsightKind` catalog doc changes** (additive). `catalogVersion` stays 1, following the Phase 11 doc's precedent for additive changes.

## 12. Build record (2026-10-03)

Built in the working tree of local `feat/quote-expiration` (stacked on Phase 25 quote options and Phase 27 lead source). Nothing is committed, deployed or pushed, and no migration was applied. Rollout order is §9.

### 12.1 What was built

**Worker (`backend-workers/`), §4:**
- `lib/estimate/estimateExpiry.js`: the §2.4 rule (`snapshotExpiry`), `validateSnapshotValidity`, `isResolvableTimeZone`, `formatValidUntil` and `expiredMessage`. "Today" always comes from `nowInZone` with an explicit zone, so the process zone is never read.
- `create-link` validates validity before any DB contact and reads `Date.now()` once, for both the check and `sentAt`.
- `view` adds `expired`. `respond` reads the clock once and returns the 410 after the digest check and before selection resolution.
- `POST /api/estimate/request-update`: the thin route `src/routes/estimate/requestUpdate.js`, the core `lib/estimate/estimateUpdateRequest.js`, and `insertRequestIfAbsent` in `portalRequestStore.js`.
- `portalAssemble.js`: `validUntil` and `expired` on each estimate. `estimateRevision.js`: the planner also strips `estimateValidUntil`.
- `notifyOwner.js`: the `quote_update` title, and the push `jobId` falls back to `jobRef`.

**Public pages (`tradeready-legal`), §5:** `estimate.html` and `portal.html`, built by the Worker/pages slice. They sit **uncommitted on that repo's `feat/quote-options` branch**, not on a separate `feat/quote-expiration` branch. This record's audit only cross-read them against the Worker contract:
- the request-update body is `{ jobId, token, note, website }`
- a 410 calls `load()`
- a 409 `estimate_not_expired` shows the reload banner
- the digest is sent whenever the view returned one, which it always does
- the portal shows the "Expired" chip and meta and leaves expired estimates out of `needsReview`

The pages were not edited or re-tested here.

**Native, slice A (domain, documents, reminders, Today):**
- Canonical keys (§6.1).
- `Domain/NativeQuoteExpiry.swift` (§6.2), plus `NativeValidUntilPicker`, the `DatePicker` ↔ `YYYY-MM-DD` bridge. It sits in the same Foundation-only file so the host suite can pin it.
- PDF and message drafting (§6.6).
- Follow-up copy, the `est_exp_` reminder and the extension notice (§6.7).
- Today `quote_expiring` / `quote_expired`, the card policy, the analytics `InsightKind` in code and in the Phase 11 doc (§6.8).
- The `quote_update` briefing row (§6.9).
- The approval-link service maps 400 → `.estimateRejected` (§6.10).

**Native, slice B (store and UI):**
- §3 proposal rules in `estimateReviewDraft(jobID:validUntil:now:)`.
- The three send stamps through `stampEstimateSent`.
- The fail-closed pulled-date check in `createEstimateApprovalLink`.
- The declined guard with `ignoringValidity`.
- `extendEstimateValidity` (§6.5).
- UI:
  - The Pricing settings "ESTIMATES" section (§6.3).
  - The review sheet's "Valid until" row and "Update approval link" (§6.4).
  - The job-detail validity row, the "Extend estimate…" / "Change valid-until date…" sheet and its alert (§6.5).

**Registration:**
- `NativeQuoteExpiry.swift` is listed in `run-appstore-sources-common.sh` and in every standalone runner that compiles a file referencing it: estimate-follow-up, estimate-follow-up-notification, appointment-notification, notification-coordinator, notification-permission, review-request, phase10-qualification, today-insights, today-briefing, estimate-pdf, estimate-message-draft, plus the two new runners.
- The Xcode project needs no edit, because `TradeReadyNative/` is a file-system-synchronized group.
- Both new runners are registered in `run-all-domain-tests.sh`, and `check-runner-registration.sh` passes.

### 12.2 Decisions where the spec was silent

1. **Domain dependencies.** `NativeQuoteExpiry` compiles with `CanonicalModels.swift`, because its §6.2 signatures take `Canonical.Settings`/`Canonical.Job`. "Foundation only" is read as "no other app files".
2. **The review draft's date.** `NativeEstimateReviewDraft.validUntil` / `validUntilTimeZone` are read from the frozen snapshot rather than stored beside it. The date shown, stamped and minted therefore cannot disagree with the snapshot. `validUntilTimeZone` reports the device zone when the draft is undated.
3. **The per-estimate override.** It is `NativeEstimateValidUntilChoice` (`.date(String)` / `.doesNotExpire`), so "no override" and "Doesn't expire" stay distinct. A date outside today…today+365 returns `nil` with "Choose a date between today and one year from today."
4. **A sheet left open past its date:**
   - "Mark estimate as sent" refuses: "The valid-until date has passed. Choose a new date before marking the estimate sent."
   - `createEstimateApprovalLink` returns `.estimateChanged` before stamping, so a link is never born expired.
   - `recordEstimateDelivery` stamps the review's date as it is, because the message already went out with it.
5. **Extension outcomes beyond the spec:**
   - `.invalidDate` (a date outside the selectable range).
   - `.link(NativeEstimateApprovalLinkError)` (the refresh failed; nothing on the device changed).
   - `.notSaved(linkUpdated:)`.
   - A decision found after the pull is `.notEligible`. A token that changed during the pull is `.pricingChanged`.
   - Saving an unchanged date (or still "Doesn't expire") dismisses the sheet without a write or a link refresh.
6. **Extension alert copy.** The spec's copy is kept for its case, an expired estimate given a new date: "Estimate extended" / "Valid until Dec 1, 2026. The customer's approval link works again."
   - Moving an open date later, or to "Doesn't expire", is also "Estimate extended". With a link, it says "…The customer's approval link shows the new date." instead, because the link never stopped working. "Doesn't expire" reads "This estimate no longer expires."
   - Moving a date earlier, or dating an undated estimate, is titled "Valid-until date changed". It offers no "Let the customer know", because that notice says "I've extended your estimate".
   - The notice for "Doesn't expire" reads "…I've extended your estimate for {title} ({amount}), and it no longer expires."
   - The result type (`NativeEstimateExtensionResult`) lives beside the store, so the store suite pins this copy.
7. **The extension notice composer.** It reuses `NativeEstimateFollowUpView` with `purpose: .extensionNotice`:
   - The title is "Let the Customer Know", with neutral sent/failed copy.
   - It does **not** emit `estimate_follow_up_sent`, because the spec adds no analytics events.
   - The screen view still reports `estimate_follow_up`, since it is the same screen.
8. **The settings field:**
   - It commits (clamped to 0…365) when focus leaves it: the shared `SettingsPage` keyboard Done bar, tapping elsewhere, or leaving the page.
   - Non-numeric input restores the saved value.
   - Its width is a `@ScaledMetric`.
9. **The review sheet's "Valid until" control:**
   - It is a `DisclosureGroup` whose label reads "Valid until, {date}" for VoiceOver.
   - The date picker is hidden while "Doesn't expire" is on.
   - Turning "Doesn't expire" off restores the last date chosen while it is still selectable, else today + the default validity (30 when the setting is 0).
   - Refusals use the alerts "Couldn't change the date", "Couldn't mark the estimate sent" and "Couldn't update approval link". Stale store messages are cleared before each attempt.
10. **Today:**
    - Both kinds also skip an estimate whose approval already carries a decision but whose status hasn't been reconciled yet.
    - "You sent '…' on {date}" reads a link-only `approval.sentAt` (a UTC instant) as the local day it fell on (FA-039).
    - A malformed stored date counts as undated everywhere: reminders, state and Today. A review re-proposes a fresh date.
11. **Reminders:**
    - The expiry reminder folds into the 3-day one when its fire instant is not strictly later.
    - An estimate with no send stamp still gets the expiry reminder.
    - The 3-day copy picks "expires" or "expired" by the local day the reminder fires.
12. **Copy:**
    - The job-detail note after expiry uses the medium date: "This estimate expired on Nov 2, 2026. Check your pricing before accepting it."
    - The job-detail expired row is a "⚠ Expired" label (text, not color alone) plus the date, combined into one VoiceOver element.

### 12.3 Deviations from the spec

- **`quote_expired` aggregate id.** The aggregate is `quote_expired:all:<newest validUntil>`, not `quote_expired:all`. The kind is dismiss-only and a dismissal without `until` is permanent. With a constant id, dismissing one batch would have hidden every later batch for good. With the newest date in the id:
  - an older estimate joining the batch keeps it hidden
  - the next estimate to expire brings it back
  
  Single rows keep `quote_expired:<jobId>:<validUntil>`.
- **Worker extras (Worker slice):**
  - The `quote_update` owner email carries the request's `details` line, which names the estimate and includes the note.
  - The Worker/Vercel planner parity test now allows exactly the Phase 32 strip hunk and nothing else.
- **Not run here:** `npm run check` (a `wrangler` dry run), because this build was not allowed any `wrangler` command.

### 12.4 Test results (2026-10-03)

All Swift runners ran one at a time with a scratch `TMPDIR`.

**Phase 32 runners:**

| Runner | Result |
|---|---|
| `run-quote-expiry-tests.sh` (`TZ=America/Phoenix`, shared vectors) | 158/158 checks |
| `run-quote-expiry-store-tests.sh` | 154/154 checks |
| estimate-pdf, estimate-message-draft, estimate-follow-up, estimate-follow-up-notification, estimate-approval-link, today-insights, today-briefing, canonical, adapter, recurring-job, analytics-transport (227 checks, catalog fixture = Phase 11 doc) | all pass |

**Full set.** Every runner in `run-all-domain-tests.sh` was run except `run-analytics-event-tests.sh`, `run-error-redaction-tests.sh` and `run-save-rollback-tests.sh`, which the owner runs in the final gate (app-group privacy prompt). Of the 133 runners run, 131 pass. The other two fail only on known, pre-existing checks:

| Runner | Result | Cause |
|---|---|---|
| `run-accessibility-audit-tests.sh` | 1 of 1978 checks fails | Raw `.borderedProminent` at `N/RootView.swift:234` |
| `run-layout-metrics-tests.sh` | 3 of 887 checks fail | `RootView keeps six tabs`; `cancellationAction 'Done'` at `N/CoachView.swift:68`; the `.keyboardShortcut` count off by one, which is that same CoachView button. The new editor's Cancel/⌘S shortcuts pass the policy |

`run-store-integration-tests.sh` and `run-legacy-reimport-tests.sh` first failed while the Mac's screen was locked (`CGSSessionScreenIsLocked = true`): a missing `store.json` and `NSCocoaErrorDomain 513`. Rerun once it was unlocked, both pass: store integration, including the Phase 32 card-policy block, and legacy re-import with 933 checks.

**Gates:**
- `sh native/check-runner-registration.sh`: pass.
- `node scripts/parity-manifest.mjs --write`, then `sh native/run-fixture-manifest-check.sh`: current.
- `sh native/run-doc-reference-check.sh`: 2364 references, 0 missing.
- Release `xcodebuild` (generic iOS, `CODE_SIGNING_ALLOWED=NO`): **BUILD SUCCEEDED**, with no warnings in Phase 32 files.

**Worker:**
- `cd backend-workers && npm test`: 160/160 passed, and 160/160 again under `TZ=America/Phoenix`.
- Root Jest, `TZ=America/Phoenix npm test -- --runInBand --runTestsByPath __tests__/portalAssembleWorkers.test.js __tests__/estimateUpdateRequestWorkers.test.js __tests__/notifyOwnerUpdateWorkers.test.js`: 3 suites, 48/48 passed.
- The other root suites over the touched Worker modules also pass (portalRequestWorkers, portalStoreWorkers, portalTokensWorkers, portalIcsWorkers, photoSignWorkers, estimateRespond, estimateCreateLink, estimateDispatcherPortal, routeDispatcherGuard, bookingNotify, phase8PortalAdmin86, phase8PortalConcurrencyCharacterization): 12 suites, 141/141.
- Swift and the Worker both load `native/QuoteExpiryTests/Fixtures/quote-expiry-vectors.json` (15 vectors) and agree on every vector.

### 12.5 Still open

- The three privacy-prompt runners (`run-analytics-event-tests.sh`, `run-error-redaction-tests.sh`, `run-save-rollback-tests.sh`) run in the owner's final gate.
- Owner items from §11 are unchanged: the legal text (32-B, `terms.html`/`privacy.html` untouched), the enforced 30-day default, the new notification, and the "estimate" wording.
- Deploys follow §9 and are the owner's: the Worker first, then the `tradeready-legal` pages (to be committed in that repo), then the native build.
