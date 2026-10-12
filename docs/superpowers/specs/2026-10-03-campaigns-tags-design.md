# Past-Customer Campaigns & Customer Tags (Roadmap Phase 33) — Design Spec

**Date:** 2026-10-03
**Status:** SCOPED. Builds on `feat/campaigns`, stacked on the build-order branches before it (`feat/quote-options` → `feat/lead-source` → `feat/quote-expiration` → `feat/job-forms` → `feat/properties-equipment` → `feat/referrals` → the Phase 24/28 branch). Owner go-ahead 2026-10-03: "continue working until all features on the roadmap are properly completed … implemented in the most beneficial way to the user". Code map verified 2026-10-03 against `feat/quote-expiration` at HEAD `e922d51` (Phase 27 committed) plus its uncommitted Phase 32 work. Phases 20, 21, 24, 28 and 34 are scoped but not built on this tree.
**Origin:** `docs/post-launch-feature-roadmap.md` Phase 33, build order #9 ("None if sent from the phone; existing Resend if bulk email")
**Builds on:** lead source (`2026-10-02-lead-source-design.md`, built), referral program (`2026-10-03-referral-program-design.md`, scoped, build #6), contextual AI (`2026-08-07-contextual-ai-design.md`), reviewed outreach (`NativeInvoiceOutreach`), bulk invoice reminders, review requests, booking link, `maintenance_due` Today insight
**Build target:** native SwiftUI app, a small Worker validator change, `book.html` in `CZilla57/tradeready-legal`, and one Supabase migration **file** (not applied). **No React Native changes. No deploys. No new provider.** Stage 2 (§10, server-side email) is designed here but is **not** part of v1 and needs owner approval before any of it is built.

## 0. Preconditions verified against the repo

`N/` means `native/TradeReadyNative/`. `BW/` means `backend-workers/`.

**Customers and jobs**
- `Canonical.Customer` (`N/Domain/CanonicalModels.swift:1253-1290`) has `id, name, email, phone, address, notes`, `createdAt?`, `portal?`, `archivedAt?`, `importBatchId?` and Phase 27's `leadSource?` (`:1274`, reader `:1281`, writer `:1288`). There is **no tags, labels, opt-out or marketing field** anywhere in native, RN (`types/models.ts:584-620`), the Worker or Supabase.
- Customers are JSON blobs, so new optional keys need no migration. Unknown keys survive through `Preservation` (`:67-79`), `ObjectReader.finish()` (`:227-288`) and `ObjectWriter` (`:290-318`).
- UI `Customer` is `N/Models.swift:56-70`. The adapters are `canonical(from value:)` (`N/Domain/UIModelAdapters.swift:165-174`), `canonical(from edit:)` (`:833-846`, which starts from the baseline JSON so canonical-only keys survive an editor save) and `customer(from:)` (`:996-1001`). `updateOptional` handles `String?` only (`:1123-1125`); there is **no array updater**.
- **There is no job type.** `Canonical.Job` (`:943-1020`) has no `trade`, `serviceType`, `category`, `templateId` or `completedAt`. Applying a template or pricebook item stamps nothing on the job. The only proxy is `title`; CSV import even maps a "service" header to the title (`N/Domain/NativeImportMapping.swift:76`).
- **Last service date already has a rule.** `maintenance_due` (`N/Domain/NativeTodayInsights.swift:502-580`) links jobs by `customerId` only (`:532`), takes the max `scheduledDate` of jobs in `complete | invoiced | paid` (`:108`, `:537-543`), skips customers with active-pipeline work (`:109-111`, `:533`) or an active recurring job (`:534`), requires a phone or email (`:529-531`) and measures whole local calendar months with `monthsBetween` (`:504-510`, FA-039 safe). With several customers the row targets the plain Customers list (`maintenance_due:all`, `.customers`, `:572-578`), which has no filtered view.
- Server job writes are `jsonb_set` on `approval`/`changeOrders` only (`supabase/migrations/20261002_job_approval_preserve.sql:201-216`), so a new optional job key survives them.

**Customers UI**
- The list (`N/CustomersView.swift`) searches name, email and phone (`:30-38`, `.searchable` `:150`). It has no filters or sort options; the top section holds counts and "Show archived" (`:73-80`). The toolbar has only Add (`:151-159`). Rows are `NativeCustomerListEntry`, which includes invoice-derived entries with no stored customer.
- Detail order: header, Overview with "Found you via" (`:334-341`), Contact (`:343-349`), Customer Portal (`:352-368`), Jobs, Invoices, Notes, Merge, Delete. `CustomerEditor` (`:605-804`) puts `leadSourceSection` (`:677`, built `:758-803`) right before Notes (`:678-681`).
- There is no wrapping chip layout in the app. Capsule chips in a horizontal `ScrollView` already exist (`N/NativeInvoiceOutreachView.swift:118-133`).
- Merge (`N/NativeCustomerIdentity.swift:317-482`) keeps the winner's values, fills blanks from the loser (`:333-346`), and **discards the loser's other keys**, so tags and opt-out need explicit merge code. Undo stores full before/after records (`:105-121`) and requires wire equality (`:643-648`).

**Outreach, composers and the review-request flow**
- `NativeInvoiceOutreach` (`N/Domain/NativeInvoiceOutreach.swift:3-10`) is the reviewed-outreach contract: deterministic content, a user-reviewed system composer, never an automatic send. Only an explicit `.sent` records delivery (`:96-108`).
- `NativeMessageComposer` (`N/NativeMessageComposer.swift:6-75`) presents `MFMessageComposeViewController`/`MFMailComposeViewController` with exactly one recipient (`:24`, `:30`) and maps results to `NativeMessageComposeOutcome` (`.sent | .cancelled | .saved | .failed`, `N/NativeEstimateDelivery.swift:3-8`). `canPresent` checks `canSendText()`/`canSendMail()` (`:10-15`).
- **A sequential composer queue already ships.** Bulk invoice reminders chain one composer sheet per invoice via `sheet(item:onDismiss:)` (`N/InvoicesView.swift:223-238`, `startBulkRemind` `:290-307`, `advanceBulkQueue` `:309-326`). It has no progress display, no pause and no resume, and it is not persisted.
- Review requests: `NativeReviewRequestView` holds an editable message and sends only through the composer (`N/NativeReviewRequestView.swift:55-65`, `:115-135`). Their one-shot records live in an account-bound, on-device file store that never syncs (`N/NativeReviewRequestStore.swift:11-24`).

**AI**
- **Native has no AI message drafting.** Estimate, outreach and review copy are templates (`docs/native-parity-matrix.md:83`). The closest pattern is the `maintenance_due` "Ask coach" prefill (`N/Domain/NativeTodayInsights.swift:568-569`), which only fills the chat input. The RN "AI draft with template fallback" helper is `utils/oneShotAI.ts:23-39`.
- `NativeCoachTransport.sendMessage(messages:systemPrompt:anthropicKey:groqKey:sessionBytes:)` (`N/NativeCoachTransport.swift:154`) tries the user's Anthropic key, then the user's Groq key, then the backend (`:145-149`). The backend body is `{messages, systemPrompt?}` with a Supabase bearer (`sendBackend` `:248-281`). `sendCoachMessage` always attaches the coach's BUSINESS DATA prompt (`N/AppStore.swift:13149-13168`), so campaign drafting must call the transport directly.
- The Worker's `/api/ai-chat` (`BW/src/index.js:61`, `BW/src/routes/aiChat.js`) runs Groq `openai/gpt-oss-20b` (`:13`), takes `systemPrompt` as a system message (`:66-75`), logs no content (`:98`), and is capped at 200/day per user under the `ai-chat` key (`BW/lib/aiUsage.js:29-33`), shared with the coach.
- The `tradeready-ai-layer` skill named in the roadmap (`docs/post-launch-feature-roadmap.md:572`) is not on disk. The practiced rule is one named model constant per provider, changed only in a separately reviewed edit (`N/NativeCoachTransport.swift:41-46`). This spec changes no model id.

**Analytics**
- The native allowlist is the JSON at `N/NativeAnalytics.swift:93-164`. It must stay byte-identical to `docs/native-phase-11-platform-hardening-contract-decisions.md` §9.5 (enforced by `native/run-analytics-event-tests.sh`). Typed constructors are in `N/NativeAnalyticsEvents.swift`; the bulk-reminder precedent is `bulkInvoiceReminderRun(channel:presentedCount:)` (`:157`).

**Worker email and legal (relevant to §10 only)**
- Resend is called with a plain `fetch` to `api.resend.com/emails`, keyed by the `RESEND_API_KEY` secret (`BW/wrangler.toml:2-5`). Current mail is transactional only: reminders (`BW/lib/reminderEmail.js`, From `"<Biz> via TradeReady" <reminders@…>`, `:8`, `:111`, Reply-To the owner `:116`) and invoices (`BW/lib/invoiceEmail.js:15`, `:74-80`). Each is capped at 25 per user per day and once per invoice through `unique(user_id, invoice_id)` log tables (`supabase/migrations/20260806_auto_invoice_email_log.sql:9-24`, `20260715_auto_reminder_log.sql:5-20`).
- **No unsubscribe, suppression, bounce or complaint handling exists anywhere**, no `List-Unsubscribe` header is set, and no email carries a postal address. Earlier designs deferred these deliberately (`docs/superpowers/specs/2026-07-14-overdue-auto-outreach-design.md:202-203`, `2026-07-14-overdue-auto-outreach-phase2-email-design.md:147`).
- No route lets the app send arbitrary email; all manual sends go through the on-device composer.
- Resend is on the free tier: 100/day and 3,000/month (`docs/ops-monthly-checklist.md:37`); the paid step is about $20/month for 50k (`:57`). The same domain also carries Supabase auth mail (`docs/email-templates/README.md:47-50`), and DMARC may not be published yet (`:58-59`).
- A **Business address** setting already exists (`Canonical.Settings.address`, `N/Domain/CanonicalModels.swift:1626`; `N/SettingsView.swift:215`). It prints on the invoice PDF but appears in no email.
- `tradeready-legal/terms.html` already forbids using the app to send "unsolicited commercial messages (spam)" (`:115`), makes the owner responsible for reviewing AI drafts (`:135-136`) and for legally required consents (`:139`). `privacy.html` covers AI-drafted "outreach messages" (`:120`), lists Anthropic (`:134`) and Groq (`:135`), and **does not list Resend or Cloudflare** in its provider list (`:128-139`), even though invoice and reminder emails already go through Resend.
- `PrivacyInfo.xcprivacy` already declares EmailAddress, Name, PhoneNumber and PhysicalAddress (`N/PrivacyInfo.xcprivacy:149-185`). `docs/app-store-listing.md:236-268` justifies Email Address as sign-in identity (`:259`) and omits Resend from its recipients (`:238-246`). The labels are not yet entered in App Store Connect (`docs/native-phase-12-release-readiness.md:284-305`).

**Booking link**
- The booking validator is a whitelist with Phase 27's `cleanLeadSource` after the `CAPS` loop (`BW/lib/booking/validate.js:5-37`). `submit` and `reserve` spread `checked.value` into the stored request (referral spec §0).
- `book.html` reads `?b=` and `?src=` and reserves `?r=` for referrals (`tradeready-legal/book.html:55-60`). `contactPayload()` (`:143-152`) feeds both submit and reserve. `?c=` is unused.
- Sharing needs a fresh verified booking-link status (`AppStore.reconcileBookingLinkForSharing`, `N/AppStore.swift:11364`). `NativeBookingAdministrationService.bookingURL(token:)` and `isValidBookingURL` are at `N/NativeBookingAdministration.swift:437-458`.

**Sync**
- Synced collections are owner-RLS blob tables `{id, user_id, data, updated_at, deleted}` (`supabase/migrations/20260803_local_collections_sync.sql`). **A missing cloud table wedges every push and fails the initial pull** (same file's release-gate note; Phase 20 spec §1).
- Adding a collection touches the standard plumbing listed in the job-forms spec §6: `NativeSupabasePush.collectionTables` (`N/NativeSupabasePush.swift:94-97`), `NativeSyncBackfill.collectionTables` (`N/NativeSyncBackfill.swift:37-39`), the `NativeInitialSync` collection enum (`N/NativeInitialSync.swift:113`), `CanonicalSnapshot` take/put (`N/Domain/CanonicalSnapshot.swift:67-85`), the AppStore rebase and table list (`N/AppStore.swift:9529`, `:10071`) and `NativeRejectedChangeStore` labels (`N/NativeRejectedChangeStore.swift:249`, `:269`).

## 1. Recommendation

| Question | Answer |
|---|---|
| Send channel (v1) | **On-device, one Apple composer per recipient**, driven by a persisted, resumable send queue with progress (§7). Texts and email both work. No provider, no cost, nothing server-side. |
| Server-side bulk email | **Stage 2, optional, NEEDS OWNER APPROVAL** (§10). Email only, through the existing Resend account, behind a suppression list, one-click unsubscribe, a postal-address footer, a paid plan, a separate sending subdomain and legal updates. Recommended: defer until usage shows email-heavy lists. |
| Tags | Free-form labels on the customer blob: at most 10 per customer, 24 characters each, case-insensitive. Edited from customer detail and the editor; filterable in the Customers list. |
| Opt-out | A "Do not contact for marketing" flag on the customer blob. Every segment honors it, and so does the `maintenance_due` insight. Texts end with "Reply STOP to opt out." and email ends with an address-and-unsubscribe footer. The owner records opt-outs by hand in v1. |
| Segments | A pure evaluator over customers, jobs, invoices and campaigns: last-service window, job-title keywords, tags, lead source and referral, plus fixed exclusions (archived, opted out, unreachable, duplicate contact) and default-on guards (open work, maintenance plan, contacted in the last 30 days). Shows a live count and a per-recipient preview. |
| Drafting | AI drafts a **template with merge fields** from the owner's short brief, through the existing transport and `/api/ai-chat`. **No customer data goes to the AI.** Deterministic rendering, validation and a template fallback. The owner edits; nothing auto-sends. |
| Storage | A new synced `campaigns` collection (one migration file, which the owner applies before shipping, as Phase 20 did). Tags and opt-out live on the customer, so compliance state syncs even without the table. |
| Results | Derived, never stored: bookings through the campaign's link (`?c=` code → `job.campaignId`), plus new non-recurring jobs for a recipient within 30 days of their send (last touch wins). Shows won jobs and collected cash. Replies can be marked by hand. |

### 1.1 Why on-device first (the evaluate-first comparison)

| | (a) On-device sequential | (b) Server-side email via existing Resend |
|---|---|---|
| Channels | Text **and** email | Email only. Texts would need an SMS provider, and Phases 10/16 are out of scope. |
| Sender the customer sees | The owner's own number or mailbox, which they recognize; replies reach the owner directly | `"<Business> via TradeReady" <campaigns@…>` with Reply-To set to the owner. Lower recognition, higher complaint risk. |
| Deliverability at 20–50 recipients | Good: 1:1 personal mail and texts from an established account | Shared platform reputation. Today it is the **same domain** as auth, invoice and reminder mail, so a complaint spike hurts invoice delivery for every owner. Needs a separate subdomain, DMARC and complaint monitoring. |
| Owner time | About 8–12 seconds per recipient (review, tap Send) with auto-advance: roughly 7–10 minutes for 50. Resumable. | One tap for any size |
| Cost | None | Free tier is 100/day, shared with auth and invoice mail, so one 50-person campaign uses half of it. A paid plan (~$20/month) is required first. Re-verify current Resend pricing and its marketing-mail policy (it may require its contact-priced Broadcasts product). |
| Unsubscribe / CAN-SPAM | Opt-out line plus business address in the footer (§6.3). Opt-outs arrive as replies and the owner records them. | Must add a one-click unsubscribe (RFC 8058 `List-Unsubscribe` + `List-Unsubscribe-Post`), a suppression table, bounce and complaint webhooks, and a mandatory postal address. |
| New dependency / services | None | No new provider, but a paid plan, DNS records, a webhook secret, 2 migrations and 3–4 routes |
| Privacy label / legal | No change (§11) | No new data type, but the listing doc's recipients and justification change, and the privacy policy and terms need updates (§10.6) |
| Abuse surface | The owner's own accounts; carrier and mailbox-provider limits apply to them | A compromised account could spam through TradeReady's domain. Needs caps, recipient-ownership checks and a kill switch. |

For a solo operator with 20–50 past customers, (a) is the better product. It reaches people by text, which (b) can't; it comes from a sender the customer knows; replies land where the owner already works; and it costs nothing. (b) only wins on time for email-heavy lists of roughly 75 or more, and that benefit comes with legal and deliverability obligations TradeReady carries for every owner. v1 therefore ships (a) end to end, and (b) is a separately approvable stage (§10, A1–A6).

## 2. Data model

```ts
// Customer (customers.data). All optional, so no migration.
tags?: string[]                 // 1–10 labels, normalized (§3.1), sorted by key; absent when none
marketingOptOutOn?: string      // local YYYY-MM-DD; present = "Do not contact for marketing"
marketingOptOutVia?: string     // "asked" | "text_stop" | "email_reply" | "imported"
                                //   Stage 2 adds "unsubscribe_link" | "complaint" | "bounced"

// Job (jobs.data)
campaignId?: string             // set only by booking intake from a resolved campaign code (§9)

// BookingRequest (bookingRequests.data)
campaignCode?: string           // from ?c=; format-checked and lowercased by the Worker

// Campaign (new synced collection "campaigns", campaigns.data)
{
  id: string,                   // "cmp_" + UUID v4 (row ids are global across accounts)
  name: string,                 // ≤ 60 characters
  code: string,                 // 16 lowercase Crockford base32 characters (Phase 34 encoder), for ?c=
  createdAt: string,            // ISO instant
  status: "draft" | "sending" | "done",
  segment: CampaignSegment,     // §5.1
  channelPlan: "text_first" | "email_first" | "text_only" | "email_only",
  message: {
    goal?: "tune_up" | "check_in" | "offer" | "seasonal" | "custom",
    brief?: string,             // ≤ 500 characters, the owner's description; the only free text sent to AI
    text?: string,              // SMS template with merge fields (§6.1)
    emailSubject?: string,
    emailBody?: string,
    aiDrafted?: boolean,
    lockedAt?: string           // ISO; set at the first sent recipient (C3)
  },
  frozenOn?: string,            // local YYYY-MM-DD the audience was frozen
  recipients?: [{
    customerId: string,
    name: string,               // display snapshot only
    channel: "text" | "email",
    status: "pending" | "sent" | "skipped" | "failed",
    skipReason?: string,        // "opted_out" | "archived" | "no_contact" | "deleted" | "owner" | "ended"
    sentAt?: string,            // ISO instant
    manual?: boolean,           // marked sent by hand (copy or URL-scheme fallback)
    repliedOn?: string          // local YYYY-MM-DD, owner-marked
  }],
  manualExclusions?: string[],  // customer ids the owner unticked in the preview
  endedAt?: string
}
```

**Swift changes**
- `Canonical.Customer` gains `tags: [String]?`, `marketingOptOutOn: String?` and `marketingOptOutVia: String?`, with reader/writer lines following `leadSource`.
- `Canonical.Job` gains `campaignId: String?`; `Canonical.BookingRequest` gains `campaignCode: String?`.
- `Canonical.Campaign` (new) with nested `Segment`, `Message` and `Recipient`, each `Codable` with `Preservation` (the `Customer.Portal` shape). `CanonicalSnapshot` gains `campaigns`.
- UI `Customer` gains `tags: [String]?`, `marketingOptOutOn: String?` and `marketingOptOutVia: String?`, because the editor sets them. The edit adapter needs a new `updateOptionalStringArray(&fields, "tags", …)`; the two opt-out fields use the existing `updateOptional`. `job.campaignId` stays canonical-only.
- These are **typed** properties. Merge copies structs and drops a loser's unknown keys (§0), so nothing here may live only in `Preservation`.

**Invariants**
- **C1:** Recipients are materialized only from a segment evaluation (§5). At freeze, nobody who is opted out, archived or unreachable is included. Every recipient is re-validated live before their composer opens (§7.3).
- **C2:** `status = sent` only on a composer `.sent` outcome or an explicit "Mark as sent".
- **C3:** The message is editable until the first recipient is sent, then locked. "Duplicate campaign" makes an editable copy.
- **C4:** At most 200 recipients per campaign (blob size, and a sanity bound for a one-person send session).
- **O1:** A customer is opted out exactly when `marketingOptOutOn` is non-empty. Merge never clears it (§4.4).

## 3. Tags

### 3.1 Normalization (`N/Domain/NativeCustomerTags.swift`, new, Foundation-only)

```swift
enum NativeCustomerTags {
    static let maxPerCustomer = 10
    static let maxLength = 24
    static func normalize(_ raw: String?) -> String?          // one label
    static func key(_ label: String) -> String               // matching key
    static func normalizeList(_ raw: [String]?) -> [String]?  // stored form
    static func vocabulary(_ customers: [Canonical.Customer]) -> [Entry]   // display, key, count
    static func merged(winner: [String]?, loser: [String]?) -> [String]?
}
```

- `normalize`:
  - strips control characters, turns commas and semicolons into spaces (they are the separators in the editor and in CSV), collapses whitespace and trims;
  - drops a leading `#`;
  - truncates to 24 characters on a grapheme boundary;
  - empty becomes `nil`.
- `key` is the label folded for case and diacritics (`"Spring AC"`, `"spring ac"` and `"Spríng AC"` are one tag).
- `normalizeList` normalizes each label, de-duplicates by key (first spelling wins), keeps the first 10, and sorts by key so the wire order is stable. An empty result is `nil`, so the key is absent.
- **Vocabulary** is derived from existing customers; there is no settings list (Phase 27 D2 precedent, `NativeLeadSource.customLabels` at `N/Domain/NativeLeadSource.swift:118`). Each key's display spelling is the one used on the most customers, with ties broken alphabetically. It is sorted by count descending, then display.

### 3.2 Editor UX

- **Customer detail:** a "Tags" section after Overview (`N/CustomersView.swift:334-341`). Tags show as capsule chips in a horizontal scroller (the `NativeInvoiceOutreachView` chip style), with "Edit tags". With no tags, the section reads "Add tag".
- **`N/NativeCustomerTagsSheet.swift` (new):**
  - current tags as removable chips, with "3 of 10";
  - an "Add a tag" field; return or comma adds;
  - suggestions below the field: the vocabulary filtered by prefix (by key), excluding tags already on the customer, top 8 by count;
  - a typed tag whose key matches the vocabulary snaps to the existing spelling, so spellings converge;
  - at 10 tags the field disables with "Up to 10 tags per customer".
  - Save calls `store.setCustomerTags(customerID:tags:)`, a canonical write plus `enqueueUpsert(table: "customers", …)`.
- **`CustomerEditor`:** a "Tags" section between `leadSourceSection` and Notes (`:677-681`), using the same chip and add-field components. This is the path for new customers.

### 3.3 Filtering in the Customers list

- A "Filter" menu button joins the toolbar (`:151-159`), next to Add. It offers:
  - **Tags**: multi-select, matching any of the selected tags; the vocabulary with counts, searchable when there are more than 12;
  - **Do not contact for marketing**;
  - **No phone or email**.
- Active filters show as a dismissible chip row at the top of the list, with "Clear". They combine with search and "Show archived" (AND).
- Pure `NativeCustomerListFilter.apply(_ entries:, customers:, filter:)`. Invoice-derived entries with no stored customer never match a tag or opt-out filter.
- Rows show up to 3 tags as a secondary caption ("AC · VIP · Gate code +2") and a small "No marketing" badge when opted out.
- Filter state is per session and not persisted.

### 3.4 Import and export

- CSV import: `fieldDefs[.customers]` (`N/Domain/NativeImportMapping.swift:27-35`) gains:
  - `tags` (synonyms `tags`, `tag`, `labels`, `customer tags`, `client tags`), split on `,`, `;` or `|`;
  - `marketingOptOut` (synonyms `do not contact`, `do not market`, `marketing opt out`, `unsubscribed`, `email opt out`, `opted out`), where truthy values (`yes`, `y`, `true`, `1`, `x`, `unsubscribed`, `opted out`) set `marketingOptOutOn = import date` and `marketingOptOutVia = "imported"`.
  - Opt-**in** columns (e.g. "Receives marketing emails") are not mapped because their polarity is ambiguous.
- `NativeImportEngine.upsertCustomer` (`N/Domain/NativeImportEngine.swift:111-158`) handles matched customers this way:
  - tags union through `merged`;
  - an opt-out fills only when absent, and an import never clears one.
  - Phase 27's push-gap fix already enqueues matched customers whose fields changed.
- The accountant package customers CSV (`N/Domain/NativeAccountingPackage.swift:181`) gains trailing `Tags` (labels joined with `; `) and `Marketing opt-out` (the local date or blank) columns, after Phase 34's `Referred by`. They use the import synonyms above, so a customer list round-trips.

## 4. Opt-out ("Do not contact for marketing")

### 4.1 Recording it
- **Customer detail:** a "Marketing" row after Contact. It shows a toggle, "Do not contact for marketing", with the footer "Campaigns skip this customer. Invoices, estimates and appointment messages are not affected."
  - Turning it on opens a reason picker: Asked me · Replied STOP to a text · Replied to an email.
  - It saves `marketingOptOutOn = today (local)` and the matching `via`.
  - Turning it off asks for confirmation: "Only do this if Sam asked to hear from you again."
- **`CustomerEditor`:** the same toggle in the Tags section (the reason defaults to "asked").
- **Send session:** a "They asked to stop" action on the current recipient (§7.2) sets it immediately and skips them.
- **Campaign results:** each sent recipient's row has "Mark opted out".

### 4.2 How a customer opts out (v1)
- **Text:** the rendered text always ends with `Reply STOP to opt out.` (§6.3). A STOP reply lands in the owner's Messages app. Peer-to-peer texts from a personal number get no carrier-level STOP handling, so the owner records it with the toggle. Campaign detail reminds them: "Got a STOP or 'no thanks' reply? Mark that person opted out."
- **Email:** the footer says `Reply "unsubscribe" and we won't email you about offers again.` A reply-to address is a permitted CAN-SPAM opt-out mechanism. The owner records it the same way.
- **Stage 2 only:** a one-click unsubscribe link and webhook suppressions set it automatically (§10.3).

### 4.3 What honors it
- Every segment evaluation (§5.2) and the live check before each composer opens (§7.3).
- `maintenance_due` (`N/Domain/NativeTodayInsights.swift:528`) skips opted-out customers, because its "Ask coach" action drafts a check-in text. The insight shares the segment's service-history helper (§5.3).
- Phase 34's referral share sheet: when built, it disables Send for an opted-out customer and explains why. Asking for referrals is promotional.
- **Not blocked:** invoices, payment reminders, estimates, appointment messages and review requests. These are transactional or relationship messages. The review-request sheet shows an informational line ("Sam asked not to get marketing messages") but does not block.

### 4.4 Merge
Opt-out is sticky: if either record is opted out, the winner is too, with the **earlier** date and that record's `via`. Tags merge through `NativeCustomerTags.merged`: winner's tags first, then the loser's in key order until 10. Both are inline in `NativeCustomerIdentity.merge` after the Phase 27 source fill. Undo already restores full records.

## 5. Segments

### 5.1 Definition

```swift
struct CampaignSegment: Codable, Equatable {        // Canonical.Campaign.Segment, with Preservation
    enum Service: String { case any, served, neverServed }
    var service: Service = .served
    var minMonthsSinceService: Int?                 // inclusive; e.g. 6
    var maxMonthsSinceService: Int?                 // inclusive; e.g. 15
    var jobKeywords: [String] = []                  // any-of, matched against delivered job titles
    var tagsAny: [String] = []                      // tag keys
    var tagsNone: [String] = []                     // tag keys
    var leadSources: [String] = []                  // Phase 27 bucket keys, including "unknown"
    var referral: Referral = .any                   // .any | .cameFromReferral | .hasReferred (Phase 34)
    var excludeOpenWork = true
    var excludeMaintenancePlans = true
    var excludeContactedWithinDays = 30             // 0 = off
}
```

**Job type.** There is no structured job type (§0), so "job type" is a keyword match on the titles of the customer's delivered jobs. The match is case- and diacritic-insensitive, and any keyword can match. The builder offers the 20 most frequent words from delivered job titles (stop-words and words under 3 characters removed) as one-tap chips, plus free entry. A structured `job.serviceType` is a residual (§14).

### 5.2 Evaluation (`N/Domain/NativeCampaignSegments.swift`, new, pure)

`evaluate(segment:channelPlan:customers:jobs:recurringJobs:campaigns:manualExclusions:canEmail:now:) -> NativeCampaignAudience`

Every stored customer is tested in this order. The first failing rule is recorded as its exclusion reason.
1. **Fixed exclusions** (not overridable): `archived`, `optedOut` (O1).
2. **Filters** (AND across kinds):
   - service window. `served` needs at least one delivered job, and the min/max months apply to the last service date (§5.3). A customer with delivered jobs but no dated one matches only when no month bound is set. `neverServed` means no delivered job at all.
   - keywords
   - tagsAny / tagsNone
   - lead source (via `NativeLeadSource.bucketKey`)
   - referral (`.cameFromReferral` = normalized source is `referral`; `.hasReferred` = some customer's `referredByCustomerId` is this customer, available once Phase 34 lands and hidden before)

   A customer who fails a filter is simply not matched; it is not an exclusion.
3. **Guards** (default on, owner-toggleable):
   - `openWork`: any non-archived job in `lead | estimate_sent | approved | scheduled | in_progress` (the `activePipelineStatuses` set)
   - `maintenancePlan`: an active recurring job
   - `recentlyContacted`: a `sent` recipient in any campaign within the last N local days
4. **Reachability under the channel plan:**
   - A phone counts when it has at least 10 digits. An email counts when it matches the booking validator's `EMAIL_RE` shape (`BW/lib/booking/validate.js:6`), ported to Swift.
   - `text_first` → text, else email. `email_first` → the reverse. `*_only` → that channel or `noContact`.
   - When `canEmail` is false (no Business address, §6.3), email counts as unreachable. The audience reports how many more would be reachable once the address is set.
5. **Duplicate contact:** recipients sharing phone digits (last 10) or a lowercased email collapse to one. The one with the most recent service date is kept, then the earliest `createdAt`, then the smallest id. The others are excluded as `duplicateContact(of:)`.
6. `manualExclusions` → `removedByOwner`.

The output holds recipients (id, name, first name, channel, contact, last service date, last job title) sorted by name, then id; exclusions with reasons; and counts (`matched`, `reachable`, `byText`, `byEmail`, per-reason exclusions). It is fast enough to recompute on every change: it is a linear pass with jobs pre-grouped by `customerId`.

### 5.3 Service history (`N/Domain/NativeServiceHistory.swift`, new)
`lastService(customerID:jobsByCustomer:) -> (date: String, title: String)?` is exactly `maintenance_due`'s rule: link by `customerId`, delivered statuses, max `scheduledDate`, and its title. `selectMaintenanceDue` is refactored to call it, as a pure refactor guarded by the existing TodayInsights vectors. The insight and the "Due for maintenance" preset therefore always agree on who qualifies.

### 5.4 Presets
| Preset | Segment |
|---|---|
| Due for maintenance | served, ≥ 6 months, open work and maintenance plans excluded. Same set as `maintenance_due`. |
| Annual check-in | served, 11–13 months |
| It's been a while | served, ≥ 18 months |
| Everyone I've worked for | served, no month bound |
| Never booked | neverServed (leads and estimates that never became work) |
| Custom | blank, served |

### 5.5 Builder UI (live count and preview)
- **Step 1, Audience:**
  - a preset picker, then each filter as a row: months stepper pair, keyword chips, tag chips, lead-source multi-select, referral picker, and the three guard toggles;
  - a sticky footer with the live count: "31 will receive it · 27 by text · 4 by email";
  - "9 excluded" opens the exclusion list grouped by reason, with names ("Opted out (3)", "Archived (2)", "No phone or email (1)", "Same phone as Dana Ortiz (1)", "Open work (2)").
- **Preview:** the recipient list (name, channel icon, "Last service: Mar 2026"). Unticking a row adds it to `manualExclusions`. Tapping a row shows that person's fully rendered message once the message step has content.
- **Entry points:**
  - Customers toolbar → "Campaigns" (megaphone) → the campaign list, with drafts, in progress ("22 of 34 sent · Resume") and done;
  - the `maintenance_due:all` insight row: its target becomes the new `NativeInsightTarget.newCampaign(preset: "due_for_maintenance")`, so "N customers haven't been serviced" opens the builder already filtered (the routing switches are at `N/AppStore.swift:13627`, `:13744`, `:13857`). The single-customer row keeps `.customer`.

## 6. Message and drafting

### 6.1 Merge fields (`N/Domain/NativeCampaignMessage.swift`, new, pure)

| Field | Value | When missing |
|---|---|---|
| `{firstName}` | First word of the name, if it is mostly letters and the name has no business suffix (LLC, Inc, Co, Corp, Company) | `there` |
| `{name}` | Full name | (never missing) |
| `{businessName}` | Settings | Send is blocked until it is set |
| `{ownerName}` | `settings.contactName` | `{businessName}` |
| `{businessPhone}` | `settings.phone` | The line is dropped, and the preview warns |
| `{lastJob}` | Last delivered job title (§5.3) | `your last service` |
| `{lastServiceMonth}` | e.g. "March 2026", from the local date | `a while back` |
| `{bookingLink}` | The verified booking URL plus `&c=<campaign code>` (§9) | Send is blocked until the booking link is on, or the field is removed |

- `render(template:recipient:business:bookingLink:) -> Rendered` returns the text plus the list of fallbacks used. The preview flags recipients whose message used a fallback.
- `validate(template:)` reports:
  - unknown `{…}` tokens (blocking);
  - an empty body (blocking);
  - an email subject starting with `Re:`, `Fw:` or `Fwd:` (blocking; a deceptive subject);
  - a text over 320 characters ("may arrive as several texts"; a warning).
- `{bookingLink}` resolves once per session through `reconcileBookingLinkForSharing`. The states are Phase 34's: off, unverified with Retry, or ready.

### 6.2 AI drafting
- **Brief:** a goal picker (Seasonal tune-up · Check-in · Special offer · Seasonal note · Custom), a "Details" field of up to 500 characters (e.g. "$89 AC tune-up, book by April 30"), a tone (Friendly · Professional), and the channel to draft. One call drafts one message kind (text, or email subject plus body), which keeps it inside the 600-token user-key budget.
- **Transport:** `AppStore.draftCampaignMessage(brief:kind:)` calls `NativeCoachTransport.sendMessage` directly with a dedicated system prompt. It never goes through `sendCoachMessage`, so no BUSINESS DATA block is sent. Provider order and auth are unchanged (user key, else backend `/api/ai-chat`). **No Worker change, no new model id.** Backend calls count against the shared `ai-chat` 200/day cap; campaign drafting is a handful of calls per campaign.
- **Exactly what is sent:** business name, `settings.trade`, goal, tone, channel, the owner's Details text, and the allowed merge-field list. **Nothing about any customer**: no names, contacts, addresses, tags, segment members, counts or amounts. The Details field's footer says: "Only your business name, trade and this description are sent to the AI. Don't include customer names."
- **System prompt rules:**
  - write one message for a {trade} business named {businessName};
  - use only these placeholders;
  - never invent prices, discounts, dates or facts that are not in the details;
  - no "Re:"/"Fwd:";
  - don't add opt-out text or an address (the app adds them);
  - keep a text under 300 characters;
  - reply exactly as `SUBJECT: …` (email only), then `BODY:` and the body.
- **Parse and check:** `NativeCampaignDrafting.parse(_:)` extracts the subject and body; failure goes to the fallback. `validate` runs on the result. A deterministic **fact check** warns when the draft contains a money amount, percentage or date that does not appear in the Details text: "The draft mentions $79. Your details said $89. Check it before sending." This is a warning, not a block.
- **Fallback:** any transport error, a 429, an unparseable reply or no network loads the goal's built-in template (`NativeCampaignDrafting.template(goal:kind:)`), with the notice "AI drafting isn't available right now, so we started you from a template." The never-throw contract follows `utils/oneShotAI.ts`.
- **Editing:** the subject and body are plain `TextEditor`s with an "Insert field" menu. "Draft again" replaces the body only after confirmation when the owner has edited it.

### 6.3 Compliance text (deterministic, appended at render, not editable)
- **Text:** `\n\nReply STOP to opt out.`
- **Email footer:**
  ```
  —
  {businessName} · {settings.address}
  You're getting this because you're a past customer of {businessName}.
  Reply "unsubscribe" and we won't email you about offers again.
  ```
- **Email needs a Business address.** While `settings.address` is blank, `canEmail = false` (§5.2). The message step says: "Add your business mailing address in Settings → Business profile to email customers. US law (CAN-SPAM) requires a postal address in marketing emails. A PO box works." Texts are unaffected. A dedicated campaign-only mailing address setting is A4.
- The editor and every recipient preview show the appended text, so the owner sees exactly what each customer will receive.
- Wording note in-app (settings-free): "TradeReady adds an opt-out line and your address to help you follow anti-spam rules. It isn't legal advice."

## 7. Sending, Stage 1: the on-device queue

### 7.1 Review step
"Review & send" summarizes:
- the recipient count by channel;
- the message (both kinds if the plan uses both);
- device capability (`canSendText()`/`canSendMail()`). When one is false, the screen offers the URL-scheme fallback (§7.4) or a different plan;
- a hint when more than 50 recipients are by text: "Sending many identical texts from a personal number can trip carrier spam filters. Personalized messages help, and you can pause and finish tomorrow."

"Start sending" freezes the audience (`recipients`, `frozenOn`, `status = sending`), persists it and enqueues the upsert.

### 7.2 Send session (`N/NativeCampaignSendView.swift`, new, full-screen)
- **Header:** "12 of 34 sent · 2 skipped", with a progress bar.
- **Current recipient card:** name, channel and contact, last service, and the fully rendered message, including the compliance text.
- **Primary button:** "Open in Messages" or "Open in Mail". It presents `NativeMessageComposer` with **exactly one recipient**. It never builds a group text or a multi-address email, so customers never see each other's numbers or addresses.
- **Secondary actions:** "Skip" (`skipped`, reason `owner`), "They asked to stop" (sets O1, skips with reason `opted_out`), "Copy message", and "Mark as sent" (for copy-and-paste sends; `manual = true`).
- **Toggle "Open the next one automatically"** (default on): after a `.sent`, the next composer presents as soon as the previous sheet's dismissal completes. That is the `InvoicesView` `onDismiss` chaining pattern (§0), so each recipient costs one review and one Send tap.
- **Pause:** closes the session. The campaign list shows "Paused · 22 left · Resume", and resuming opens at the first `pending` recipient. Pending state lives in the synced blob, so the session resumes after an app kill, on another device, or the next day.
- **Done:** a summary ("Sent 31 · Skipped 3: 2 opted out, 1 no phone"), then `status = done`. "End campaign" marks the remaining `pending` as `skipped`/`ended`.

### 7.3 Outcome policy (`NativeCampaignQueue`, pure, in `NativeCampaignSegments.swift`)

| Outcome | Recipient | Auto-advance |
|---|---|---|
| `.sent` | `sent`, `sentAt = now` | Yes, when the toggle is on |
| `.cancelled` | stays `pending` | No. The card stays, so this is the pause point. |
| `.saved` (Mail draft) | stays `pending`, notice "Saved as a draft in Mail. It wasn't sent. Use Mark as sent after you send it." | No |
| `.failed` | `failed`; "Retry" makes it `pending` again | No |

- **Before each composer opens,** the live customer is re-checked: the customer exists, is not archived, is not opted out, and the channel's contact is still present. A failure auto-skips the recipient with the reason and a toast. The composer always uses the **live** contact, not the snapshot.
- Each outcome persists immediately (canonical write, then `enqueueUpsert(table: "campaigns", …)`), so a crash loses at most the in-flight recipient. A `.sent` that fails to persist shows "Sent, but couldn't save progress. Mark Sam as sent before continuing." It never re-presents automatically.
- **Quiet hours:** outside 8:00–20:00 device-local time, the session shows (without blocking) "It's 9:14 PM. Many states restrict marketing texts in the evening. Consider resuming tomorrow." The owner's timezone stands in for the customers'.
- The first `.sent` sets `message.lockedAt` (C3).

### 7.4 Composer-unavailable fallback
When `canSendText()` or `canSendMail()` is false, which is common for owners who use the Gmail app instead of Apple Mail, the button becomes "Open in Messages app" or "Open in your mail app". It opens an `sms:` URL with `&body=` or a `mailto:` URL with subject and body (percent-encoded; the default mail app opens). There is no completion callback, so the card then shows "Did you send it?" with **Sent** / **Not sent**. Sent sets `manual = true`. The other recipients are never included.

## 8. Results and attribution (`N/Domain/NativeCampaignResults.swift`, new, pure)

`make(campaign:campaigns:jobs:invoices:customers:now:) -> NativeCampaignResults`, derived and never stored.

- **Booked via link:** jobs with `campaignId == campaign.id` (§9). This includes new people who used a forwarded link.
- **New work within 30 days:** non-archived jobs for a `sent` recipient (by `customerId`) that meet all of these:
  - the job's `createdAt` local date (`NativeCashBasis.parseLocalDate` → `ymd`) is within `[sent date, sent date + 30]`;
  - `recurringJobId == nil` (plan-generated work would have happened anyway);
  - not explicitly attributed to another campaign.

  When the customer was sent several campaigns, the latest send on or before the job's creation date wins (last touch). A job is counted once, across all campaigns.
- **Won:** attributed jobs whose `NativeMoneyReports.statusOrdinal` ≥ approved.
- **Collected:** Σ non-voided payments, to date, on the invoices linked through `job.invoiceId`, using `NativeCashBasis.collected` math over an all-time range.
- **Replied:** count of `repliedOn`, which the owner marks on a recipient row.
- **Campaign detail → Results:** "Sent 31 · Replied 4 · Booked 6 (2 via link) · Won 5 · $3,140.00 collected". The per-recipient list shows status, a "Booked Oct 12" badge, and "Replied" / "Mark opted out" actions. A footer explains attribution: "Counts jobs booked through this campaign's link, or created for someone within 30 days of their message."
- **Lead source:** past customers keep their first-touch source (Phase 27 D1). Only a **new** customer created from a campaign link gets the new preset `campaign` (§9.2), so the Lead sources card shows campaigns that bring in new people.
- **Not in v1:** a Money card or a coach block for campaigns (§14).

## 9. Worker and pages (Stage 1: campaign code pass-through)

### 9.1 Worker
`BW/lib/booking/validate.js`, beside `leadSource` (and Phase 34's `referralCode`):

```js
const CAMPAIGN_CODE_RE = /^[0-9a-hjkmnp-tv-z]{16}$/;
// Optional campaign code (?c=). An opaque attribution tag: never looked up,
// logged or echoed; unusable input is dropped, never rejected.
function cleanCampaignCode(raw) {
  if (typeof raw !== 'string') return '';
  const code = raw.trim().toLowerCase();
  return CAMPAIGN_CODE_RE.test(code) ? code : '';
}
const campaignCode = cleanCampaignCode(src.campaignCode);
if (campaignCode) value.campaignCode = campaignCode;
```

- `submit` and `reserve` need no edits, and every response stays byte-identical.
- `BW/lib/booking/notifyOwner.js` (Worker copy): when `request.campaignCode` is set, both email variants gain `Came in through one of your campaign links. Open TradeReady to see which one.` The push body is unchanged.
- The dormant Vercel twins are not changed (Phase 27 precedent).

### 9.2 Native intake
- **Code generation:** `Campaign.code` is generated at campaign creation with Phase 34's `NativeReferrals.makeCode` and the `SecRandomCopyBytes` source (`NativeReferralRandom.systemBytes`). Phase 34 is build #6, so it lands first. If it is descoped, those two helpers move into a shared `NativeAttributionCode`.
- **Intake:** `NativeBookingIntake` gains `campaignDecision(for:campaigns:)`. The code is resolved by exact match among the owner's campaigns; zero or more than one match resolves to none.

| Request | Lead job | Customer source |
|---|---|---|
| No code, or an unresolvable code | unchanged | Phase 27 / 34 rules |
| Code resolves; the booking **creates** a customer | `campaignId` set | `"campaign"`, unless a Phase 34 referral code also resolves, in which case the referral wins |
| Code resolves; the booking **matches** an existing customer | `campaignId` set | **unchanged, and never filled**. A past customer's acquisition predates the campaign, so a campaign must not stamp a blank source. |
| Portal request | unchanged | unchanged |

- `NativeScheduleBookingPolicy.recheckedIntakePlan` applies the same `campaignId` to the lead job.
- `NativeLeadSource.presets` gains `campaign` (display "Text or email campaign"; aliases `email campaign`, `text campaign`, `sms campaign`, `email blast`, `newsletter`). This is additive; existing keys are never renamed.

### 9.3 `book.html`
Read `var camp = (params.get('c') || '').trim();` beside `src`, and in `contactPayload()` add `if (camp) payload.campaignCode = camp;`. The page shows no visible change. Update the reservation comment to list `?r=` (referral) and `?c=` (campaign).

The `{bookingLink}` URL is `bookingURL(token:)` plus the query item `c=<code>`. `isValidBookingURL` checks only `b`, so it still accepts it. If the Worker or page isn't deployed yet, links still work; the code is dropped and only window attribution applies.

## 10. Stage 2 (optional, NEEDS OWNER APPROVAL): server-side email via the existing Resend account

Nothing in this section is built in v1. It is designed so it can be approved and built as one separate stage, behind a per-campaign choice in the review step ("Send emails from TradeReady" vs "Send from my phone"). Texts always stay on-device.

### 10.1 Prerequisites (all owner actions or approvals)
1. Approval to send marketing email on owners' behalf (A1).
2. A dedicated sending subdomain (e.g. `mail.gettradereadyapp.com`) verified in Resend with SPF and DKIM, and DMARC published on the root (A2). This keeps campaign complaints off the auth, invoice and reminder domain.
3. A paid Resend plan, after re-verifying current pricing and whether Resend requires its Broadcasts/Audiences product for marketing mail (A3).
4. A postal-address setting the server can enforce (A4).
5. Terms and privacy updates published (A5).
6. Abuse limits (A6).

### 10.2 Worker
- **`POST /api/campaigns/email/send`** (Supabase JWT). The body is `{campaignId, items: [{customerId, subject, text}]}`, at most 50 items per call; the device renders the messages.
  - For each item, the server loads the caller's `customers` row with the service role and requires: it exists and isn't deleted; `data.email` passes `isPlausibleEmail` (`BW/lib/selectInvoicesToRemind.js:28-31`); no `marketingOptOutOn`; and no suppression row.
  - It appends the footer server-side (business name, mailing address and the unsubscribe URL), so it can't be removed.
  - It sends with From `"<Biz> via TradeReady" <campaigns@mail.…>` (`sanitizeFromPhrase`, `BW/lib/reminderEmail.js:44-50`), Reply-To the owner's `settings.email`, and the headers `List-Unsubscribe: <https://…/api/u/<token>>, <mailto:unsubscribe@mail.…?subject=<token>>` and `List-Unsubscribe-Post: List-Unsubscribe=One-Click`.
- **Idempotency:** a `campaign_email_log` table with `unique(user_id, campaign_id, customer_id)`, claimed before sending (the `BW/lib/sendInvoiceEmails.js:152-156` pattern).
- **Caps:**
  - a per-owner daily cap counted from the log (recommended: 200/day);
  - the `EMAIL_CAMPAIGNS_ENABLED` kill switch;
  - optionally, paid TradeReady subscribers only (A6).
- **`GET /api/u/:token`** shows a minimal confirmation page; **`POST /api/u/:token`** is one-click (RFC 8058) and records a suppression with no other step.
  - The token is `HMAC-SHA256(secret, user_id|customer_id|lower(email))` in base64url: stateless and unguessable.
  - The page names the business only. The opt-out must keep working for at least 30 days after the send (CAN-SPAM), and stateless tokens never expire.
- **`marketing_suppressions(user_id, email_hash, customer_id, via, created_at)`.** RLS lets owners select their own rows; writes use the service role. Add it to `supabase/verify/account_deletion_cascade.sql`.
- **`POST /api/resend/webhook`** (svix-signed, new `RESEND_WEBHOOK_SECRET`): `email.complained` → suppression with `via = complaint`; a hard `email.bounced` → suppression with `via = bounced`.

### 10.3 Native
- `GET /api/campaigns/suppressions` (JWT) runs on campaign-list open and after sync. The device sets `marketingOptOutOn`/`Via` on matching customers through a normal customer write, so the server never writes customer blobs and there is no whole-blob race.
- The send route checks the suppression table itself, so a stale device can never cause a send.
- Server-sent recipients are marked `sent` from the route's per-item result. The Stage 1 results logic is unchanged.

### 10.4 Cost
- Example load: 50 owners × 2 campaigns × 40 recipients = 4,000 emails a month. That already exceeds the free tier's 3,000/month and 100/day, which are shared with transactional mail.
- The paid tier is about $20/month for 50k (`docs/ops-monthly-checklist.md:57`), but re-verify it.
- Engineering: 2 migrations, 4 routes, 1 secret, DNS, a footer renderer with parity tests, and the review-step toggle.

### 10.5 Deliverability
Gmail and Yahoo bulk-sender rules apply to the platform domain's aggregate volume. They require SPF, DKIM and DMARC alignment, one-click unsubscribe, and a spam-complaint rate under 0.3%. A single owner's poorly targeted campaign raises the complaint rate for everyone on the subdomain, which is why the subdomain, caps and kill switch are prerequisites.

### 10.6 Legal and store
- **Terms:**
  - the owner is the sender and advertiser of campaign messages;
  - the owner must message only their own customers (no bought lists), keep their mailing address accurate, honor opt-outs and comply with CAN-SPAM, TCPA and state law;
  - TradeReady may suspend campaign sending.
- **Privacy:**
  - add Resend (and Cloudflare) as processors;
  - describe sending email to the owner's customers on the owner's behalf;
  - state that suppression records are kept to honor opt-outs until the account is deleted.
- **Privacy label:** no new data type. EmailAddress and Name are already declared. Update the listing doc's justification (`docs/app-store-listing.md:259`) and its recipients (`:238-246`) before labels are entered.
- **Pre-existing gap (fix regardless of Stage 2):** `privacy.html`'s provider list (`:128-139`) already omits Resend and Cloudflare, even though invoice and reminder emails use them today.

## 11. Privacy (v1)

| Where | What it sees or stores |
|---|---|
| AI provider | The business name, trade, goal, tone, channel and the owner's Details text. No customer data (§6.2). Covered by `privacy.html:120` ("outreach messages") and the provider lines `:134-135`. |
| Worker / `book.html` | The 16-character `c` code in the booking URL, which is random and carries no PII. It is format-checked, stored on the owner's booking request, and never looked up, logged or echoed. |
| Supabase | Tags, opt-out fields and campaign rows (recipient ids, display names, statuses), all in owner-RLS blobs. Rendered messages and contact snapshots are **not** stored. |
| Composer | One recipient per message; the owner's own carrier or mail account delivers it. |
| Analytics | `campaign_drafted(kind: text\|email, source: ai\|template)` and `campaign_send_session(channel_plan, presented, sent)`, with no ids, names, codes or amounts. Add them to the allowlist JSON, the §9.5 doc and `NativeAnalyticsEvents` together; otherwise skip them. |

v1 needs **no** privacy-policy, terms or privacy-label change: there is no new processor, no new data type and nothing sent from TradeReady's servers. A clarifying terms line about marketing messages is recommended in A5 but is not a v1 prerequisite.

## 12. Testing

### New Swift suites (`TZ="${TZ:-America/Phoenix}"`, registered in `native/run-all-domain-tests.sh`)
- **`native/CustomerTagsTests/main.swift` + `run-customer-tags-tests.sh`:**
  - normalization: `#`, commas, control characters, the 24-character grapheme cut, diacritic/case keys, empty;
  - `normalizeList`: dedupe keeps first spelling, cap 10, sort, `nil` when empty;
  - vocabulary spelling and count ties;
  - `merged` (winner first, cap) and sticky opt-out merge (earlier date wins);
  - the list filter (tags any-of, opted out, no contact, invoice-derived entries never match);
  - import mapping and engine for tags and opt-out (truthy table, union on match, never clears).
- **`native/CampaignTests/main.swift` + `run-campaign-tests.sh`:**
  - segments: every filter; min/max months at the local-midnight boundary (a job on the 3rd, run at 23:30 local on the 2nd vs 00:10 on the 3rd); `neverServed`; dated-vs-undated delivered jobs; each fixed exclusion and guard with its reason; email unreachable while the address is blank; duplicate-contact tie-breaks; manual exclusions; the channel-plan matrix; the 200 cap.
  - **Parity:** the "Due for maintenance" preset selects exactly `selectMaintenanceDue`'s customers on a shared fixture.
  - rendering: each merge field and fallback; unknown placeholders block; subject prefixes block; the 320-character warning; the booking link with `c`; exact compliance text for both channels.
  - drafting: **the prompt contains none of the fixture customers' names, phones, emails or addresses**; parse success and failure; template fallback; the fact-check warning (`$79` vs `$89`).
  - queue: the outcome table; live re-validation skips (opted out, archived, contact removed, deleted); resume at the first pending recipient; `lockedAt` on the first send; End campaign.
  - results: explicit vs window attribution; last touch across two campaigns; recurring jobs excluded; a job on day 30 is in and day 31 is out (Phoenix); a voided payment is excluded; a deleted invoice; each job counted once across campaigns.
  - quiet-hours boundaries.

### Updated Swift suites
- **CanonicalTests:** the customer gains `tags` and the opt-out fields; the job gains `campaignId`; the booking request gains `campaignCode`; a `canonical-rich` campaign with unknown keys inside `segment`, `message` and `recipients[]` round-trips exactly.
- **AdapterTests:** the editor round-trips tags and opt-out; canonical-only `campaignId` survives.
- **CustomerIdentityTests:** merge tags union and sticky opt-out; undo.
- **BookingIntakeTests and ScheduleBookingRecoveryTests:** the §9.2 table, including a match never filling the source, a referral code beating a campaign code, and an unresolvable code.
- **LeadSourceTests:** the `campaign` preset and its aliases.
- **TodayInsightsTests:** `maintenance_due` skips opted-out customers; the aggregate row targets `.newCampaign`; the single row is unchanged.
- **StoreIntegrationTests:** `setCustomerTags`, the opt-out toggle and campaign create/freeze/outcome writes each persist and enqueue; a failed persist after `.sent` surfaces the notice.
- **Sync suites:** the push and backfill table lists, initial-sync collection, mutation classification, and two-device convergence on one campaign (LWW).
- **ImportMapping/Engine, AccountingPackageTests** (the two columns) and the analytics event tests (if the events are added).
- Add the new Domain files to every runner that compiles a dependent: intake, today-insights, appstore-sources-common, money/snapshot where `NativeLeadSource` changes, and import. Then run `node scripts/parity-manifest.mjs --write`.

### Worker (root Jest, `TZ=America/Phoenix npm test -- --runInBand --runTestsByPath …`)
- New `__tests__/bookingValidateCampaign.test.js`:
  - absent → no key;
  - a valid code is kept; case and whitespace are normalized;
  - wrong lengths, `i`/`l`/`o`/`u`, and non-strings are dropped while the booking still validates;
  - it coexists with `leadSource` and `referralCode`.
- `__tests__/bookingSlotsReserve.test.js` gains campaign-code cases.
- New `__tests__/bookingNotifyCampaign.test.js` checks the extra line.
- `cd backend-workers && npm test` stays green.

### `book.html`
A jsdom scratch check, as Phase 27/34 did: `?b=tok&c=<code>` sends `campaignCode` in both modes, `?c=%20` sends no key, and the rendered text is identical with and without `c`.

### Gates
- `sh native/run-all-domain-tests.sh`
- the Release compile
- the targeted Jest files under Phoenix
- `cd backend-workers && npm test`
- `sh native/run-doc-reference-check.sh`

## 13. Ship steps (owner)
1. Apply `supabase/migrations/<build-date>_campaigns.sql` (a copy of the `20260803_local_collections_sync.sql` table block, plus the `set_updated_at` trigger as Phase 20 does) and add it to `supabase/verify/local/bootstrap.sql`. **Release gate:** do this before shipping the build, or every push wedges and new-device sign-in fails.
2. Deploy the Worker (the validator and notify line).
3. Publish `book.html`.
4. Ship the native build.

Steps 2 and 3 are optional for v1 to work: without them, campaign links still open and window attribution still applies.

## 14. Accepted residuals
- **No structured job type.** Keyword match on titles only. A `job.serviceType` stamped from the pricebook category or template is a follow-up.
- **Undated delivered jobs** (no `scheduledDate`) don't give a last-service date. This is the same rule as `maintenance_due`, kept so the two never disagree.
- **Booking-job `createdAt`** is still a UTC date prefix (Phase 27 residual), so window attribution can be one day late at the edges for evening bookings.
- **Opt-outs are manual in v1.** STOP and "unsubscribe" replies need the owner to flip the flag. CAN-SPAM's 10-business-day window is the owner's responsibility, and the in-app reminder copy says so.
- **Quiet hours use the owner's timezone**, not each customer's.
- **Replies aren't detected.** The app can't read Messages or Mail; "Replied" is owner-marked.
- **URL-scheme fallback** relies on the owner's word: "Sent" is self-reported.
- **Two devices sending one campaign at the same moment** resolve by whole-blob LWW. A recipient could be shown twice. This is unlikely for one operator, and the live "recently contacted" guard catches it after sync.
- **An RN client in the field would drop the new customer keys on edit**, as it would `leadSource`. There are no current app users (`CLAUDE.md`), and RN gets no changes.
- **Not in v1:** bulk-tag from the list (multi-select), a Money "Campaigns" card, a coach CAMPAIGNS block, scheduled sends, A/B variants and postcards.
- **Separate findings, out of scope:**
  - `NativeCoachModel.groq = "llama-3.1-8b-instant"` (`N/NativeCoachTransport.swift:45`) is a retiring model on the user-key path, while the Worker moved to `openai/gpt-oss-20b`. Needs a separately reviewed model-id edit.
  - `privacy.html` omits Resend and Cloudflare (§10.6).
  - The contextual-AI spec's cost note (`2026-08-07-contextual-ai-design.md:249`) is stale.

## 15. Decisions

### Decided (recommended defaults, no owner approval needed)

| # | Decision | Choice |
|---|---|---|
| D1 | v1 send channel | On-device, one composer per recipient, with a persisted, resumable queue and auto-advance (§7) |
| D2 | Campaign storage | New synced `campaigns` collection; migration file written; the owner applies it before shipping (the Phase 20 D1 precedent). The fallback, if the owner refuses a migration, is a device-local account-bound store (the `NativeReviewRequestStore` pattern). It loses history across devices and reinstalls. |
| D3 | Tags | Free-form, max 10 × 24 characters, case- and diacritic-insensitive keys, sorted on the wire, vocabulary derived from customers, no settings list |
| D4 | Opt-out | `marketingOptOutOn`/`Via` on the customer. Sticky on merge, never cleared by import. Blocks campaigns, `maintenance_due` and Phase 34 referral sharing; does not block transactional messages or review requests. |
| D5 | Job type | Keyword match on delivered job titles, with frequency-based suggestions |
| D6 | Last service date | `maintenance_due`'s exact rule, shared through `NativeServiceHistory` |
| D7 | Default guards | Open work, maintenance plan, contacted in the last 30 days: all on, all toggleable |
| D8 | AI drafting | Templates with merge fields through `NativeCoachTransport` and the existing `/api/ai-chat` (no Worker or model change). No customer data. Fact-check warning plus template fallback. |
| D9 | Compliance text | Always appended: "Reply STOP to opt out." on texts, and the address-plus-unsubscribe footer on email. Email is unavailable until Business address is set. |
| D10 | Attribution | Booking-link code (`?c=` → `job.campaignId`) plus a 30-day last-touch window, excluding recurring jobs; derived, never stored |
| D11 | Lead source | New preset `campaign`, set only for **new** customers created through a campaign link. Never fills a matched customer's blank source. |
| D12 | Message lock | Editable until the first send, then locked; "Duplicate" to change |
| D13 | Recipient cap | 200 per campaign |
| D14 | Quiet hours | Warn outside 8:00–20:00 device-local; never block |

### NEEDS OWNER APPROVAL (Stage 2 and related; v1 works without any of these)

| # | Question | Recommended answer |
|---|---|---|
| A1 | Should TradeReady send campaign **email from its servers** through the existing Resend account (Stage 2, §10), or keep all campaign sending on the owner's phone? | **Not now.** Ship Stage 1. Revisit when `campaign_send_session` data shows owners regularly sending more than 50 email recipients, then approve A2–A6 together. Texts stay on-device either way. |
| A2 | If Stage 2 is approved: will you set up a dedicated sending subdomain (e.g. `mail.gettradereadyapp.com`) in Resend with SPF/DKIM, and publish DMARC on the root domain? | **Yes, as a hard prerequisite.** Marketing complaints must not touch the domain that carries sign-in, invoice and reminder mail. |
| A3 | If Stage 2 is approved: will you move Resend to a paid plan (about $20/month for 50k) after re-verifying current pricing and whether Resend requires its Broadcasts/Audiences product for marketing mail? | **Yes, before launch.** The free 100/day is shared with transactional mail and one campaign would exhaust it. |
| A4 | Add a separate "Mailing address for marketing emails" setting (a PO box allowed, defaulting to Business address), which Stage 2 enforces server-side? | **Yes, with Stage 2 only.** v1 uses the existing Business address field for the on-device footer and blocks email campaigns until it is set. |
| A5 | Update `terms.html` (owner is the sender; own customers only; honor opt-outs; CAN-SPAM/TCPA/state-law responsibility; TradeReady may suspend sending) and `privacy.html` (Resend and Cloudflare as processors; sending on the owner's behalf; suppression retention)? | **Yes, required for Stage 2. Also add Resend and Cloudflare to `privacy.html` now**, since invoice and reminder emails already use them. The terms clarification is recommended for v1 but not required. |
| A6 | Stage 2 abuse limits: a per-owner daily cap, recipients limited to the owner's own customer records, a global kill switch, and whether to restrict server-side campaigns to paying subscribers. | **200 emails per owner per day, ownership check and kill switch: yes.** Subscriber-only is your business call; recommended yes, because it removes the free-account spam vector. |

Owner answer (2026-10-03, `docs/roadmap-owner-decisions-2026-10-03.md`): "approve all recommendations". A1 is "not now", so A2–A6 stay deferred with Stage 2. 33-P (add Resend and Cloudflare to `privacy.html`) is approved; it is done in the separate `tradeready-legal` pass, not on this branch.

## 16. Build record (2026-10-03)

Stage 1, native only, on `feat/campaigns` (stacked on Phase 20 forms, Phase 27 lead source, Phase 25 quote options and Phase 32). §9.1 (Worker) and §9.3 (`book.html`) are **not built here**: they follow Phase 34's `book.html` work. §10 (Stage 2) is not built.

### 16.1 What was built (`N/` = `native/TradeReadyNative/`)

**Data model and sync (§2)**
- `N/Domain/CanonicalModels.swift`: `Customer.tags`, `marketingOptOutOn`, `marketingOptOutVia`; `Job.campaignId`; `BookingRequest.campaignCode`; the new `Canonical.Campaign` with nested `Segment`, `Message` and `Recipient`, each with `Preservation`; `Customer.isMarketingOptedOut` (O1).
- The `campaigns` collection is wired like Phase 20's `forms`: `CanonicalSnapshot`, `SnapshotRepository` record counts, `NativeSupabasePush` and `NativeSyncBackfill` table lists, `NativeInitialSync` collection, the AppStore rebase, row count and safe diagnostic key names, `NativeRejectedChangeStore` labels, `NativeRecordDeletion` (`.campaign`, 8 s undo) and the undo banner icon.
- `supabase/migrations/20261003_campaigns.sql` (written, **not applied**), `supabase/verify/local/bootstrap.sql`, and the release-gate entry in `docs/release-checklist.md`.
- UI `Customer` (`N/Models.swift`) and the adapters carry tags and the opt-out; the edit adapter gains `updateOptionalStringArray`. `job.campaignId` stays canonical-only.

**Pure domain files (Foundation and canonical models only)**
- `N/Domain/NativeCustomerTags.swift`: `NativeCustomerTags` (normalize, key, normalizeList, split, vocabulary, snapped, suggestions, merged, caption), `NativeMarketingOptOut` (reasons, import values, sticky merge) and `NativeCustomerListFilter`.
- `N/Domain/NativeServiceHistory.swift`: the shared last-service rule and guards. `NativeTodayInsights.selectMaintenanceDue` now calls it (a pure refactor) and skips opted-out customers. The aggregate `maintenance_due:all` row targets `.newCampaign(preset: "due_for_maintenance")`; the single-customer row is unchanged.
- `N/Domain/NativeCampaignSegments.swift`: `NativeCampaignContact`, `NativeCampaignAudience`, `NativeCampaignSegments` (presets, evaluate, keyword suggestions) and `NativeCampaignQueue` (freeze, outcome table, live check, skip, retry, end, replied, duplicate, quiet hours, summary).
- `N/Domain/NativeCampaignMessage.swift`: merge fields, validation, rendering and the compliance text.
- `N/Domain/NativeCampaignDrafting.swift`: prompt, parse, fact check and the goal templates.
- `N/Domain/NativeCampaignResults.swift`: derived attribution and results.
- `N/Domain/NativeAttributionCode.swift`: the 16-character Crockford code (see 16.2).

**Store (`N/NativeCampaignsStore.swift`, plus primitives in `N/AppStore.swift`)**
- Tags and opt-out: `setCustomerTags`, `setMarketingOptOut`, `clearMarketingOptOut`.
- Campaigns: `makeCampaignDraft`, `saveCampaignDraft`, `updateCampaignDraft`, `duplicateCampaign`, `startCampaignSending`, `prepareCampaignRecipient`, `recordCampaignOutcome`, `markCampaignRecipientSent`, `skipCampaignRecipient`, `campaignRecipientAskedToStop`, `retryCampaignRecipient`, `endCampaign`, `setCampaignRecipientReplied`, `deleteCampaign`.
- Reads: audience, results, render, message issues, vocabulary and keyword suggestions.
- `resolveCampaignBookingLink()` goes through `reconcileBookingLinkForSharing`. `draftCampaignMessage` calls `NativeCoachTransport.sendMessage` directly (`sendCampaignDraftRequest`), never `sendCoachMessage`.
- Every write goes through `commitMarketingRecords`: durable save, then publish, then one queue batch (customers first, then the campaign).

**Capture points**
- Customer merge (`N/NativeCustomerIdentity.swift`): tags union, sticky opt-out. Customer save normalizes tags and drops a reason without a date.
- Booking intake (`N/Domain/NativeBookingIntake.swift`): `campaignDecision(for:campaigns:)` and the §9.2 table. `recheckedIntakePlan` carries the planned lead job, so `campaignId` survives the recheck.
- `NativeLeadSource` gains the `campaign` preset and its aliases.
- CSV import mapping and engine: `tags` and `marketingOptOut` columns.
- Accountant package `customers.csv`: trailing `Tags` and `Marketing opt-out` columns (the parity matrix's Accountant package row is updated).

**Screens**
- `N/NativeCustomerTagsSheet.swift`: chip label, chip row, the tag editor and the Edit tags sheet.
- `N/NativeCustomerMarketingViews.swift`: the detail Tags and Marketing sections, the editor's Tags section, the row caption with the "No marketing" badge, the Filter menu, the active-filter chips and the searchable tag picker.
- `N/NativeCampaignListView.swift`: the list, with "Paused · 22 of 34 sent · 12 left · Resume", Duplicate, Delete and the preset picker.
- `N/NativeCampaignBuilderView.swift`: Audience, Message and Review, the live count bar, the exclusions sheet and the per-recipient preview.
- `N/NativeCampaignSendView.swift`: the full-screen send session.
- `N/NativeCampaignDetailView.swift`: results and per-recipient actions.
- Short insertions in shared files:
  - `N/CustomersView.swift`: the Filter menu, the Campaigns toolbar button, the chips section, the row caption, the detail sections and the editor section.
  - `N/TodayView.swift` and `N/AppStore.swift`: routing the `.newCampaign` target.
  - `N/NativeReviewRequestView.swift`: the informational opt-out line.
  - `N/Components.swift`: the undo icon.

### 16.2 Decisions where the spec was silent

- **Attribution code.** Phase 34 is not on this branch, so the encoder lives in `NativeAttributionCode` (the spec's descoped-34 fallback). It uses `SystemRandomNumberGenerator`, which is the kernel CSPRNG on Apple platforms, so the Domain file stays Foundation-only; tests inject bytes. `makeUniqueCode` retries against the owner's existing codes. **On merging Phase 34**, keep one encoder: point `NativeReferrals.makeCode` and this file at the same implementation.
- **Raw strings on the wire.** Enum-like campaign fields (`status`, `channelPlan`, `service`, `referral`, `channel`, `skipReason`) are stored as raw strings and read through typed accessors. A value written by a newer client then round-trips instead of failing the whole `campaigns` pull.
- **"Has referred someone"** reads `referredByCustomerId` from the customer's preserved unknown keys and is only offered when some customer has one. **On merging Phase 34**, switch `NativeCampaignSegments.referrerID` to the typed property, or the filter silently matches nobody.
- **"Never booked" preset** starts with the open-work guard **off**: its audience is leads and open estimates, which that guard would otherwise remove. The other two guards stay on.
- **Unsaved new drafts.** A new draft from a preset is stored on its first change, so opening the builder and backing out writes nothing.
- **Saving in the builder.** Discrete edits save immediately. Typed text saves when its field loses focus, before drafting or sending, and when the screen closes.
- **Keyword match.** Whole words, case- and diacritic-folded. A multi-word keyword must appear contiguously. A plain `s`/`es` plural also matches. Suggestions drop a stop-word list, words under 3 characters and pure numbers.
- **Duplicate contact.** Keyed on the customer record's phone (last 10 digits) **and** email, whichever channel was chosen. Groups are transitive (A shares a phone with B, B shares an email with C).
- **Recently contacted** means a send fewer than N whole local days ago. A send exactly 30 days ago no longer excludes.
- **Business name.** The app's default placeholder business name counts as unset, so Send stays blocked until a real name is set.
- **AI drafting.**
  - `{bookingLink}` is offered to the AI only when the link is ready.
  - The parser canonicalizes field case (`{FirstName}` becomes `{firstName}`), removes any opt-out lines the model added and strips reply prefixes from the subject.
  - The fact check covers money, percentages, "Month day" and `m/d` dates.
  - A stray placeholder in an AI draft is kept and shown as a blocking issue rather than silently discarded.
- **Rendering.**
  - The 320-character warning is measured with the opt-out line included.
  - A multi-line Business address is joined with ", " in the email footer.
  - The URL fallback uses `sms:<digits>&body=` and `mailto:` with subject and body.
- **Quiet hours.** No warning from 8:00 up to (not including) 20:00. Before 8:00 the warning has a morning wording.
- **Queue.**
  - `.failed` makes the recipient `failed` with Retry. A failed recipient keeps the campaign from auto-completing.
  - "Mark as sent" also works on a failed recipient.
  - "End campaign" skips pending and failed recipients as `ended`.
  - "They asked to stop" records the reason `asked`.
- **Results.**
  - Link attribution counts a job even when it is archived.
  - A job whose `campaignId` names a deleted campaign is never window-attributed to another campaign.
  - Last-touch ties are broken by the send instant, then the campaign id.
  - "Booked <date>" shows only on sent recipients.
- **Import.**
  - The opt-out column also accepts a `YYYY-MM-DD` (what the export writes), so a list round-trips.
  - Several tag columns are allowed; each cell is split on `,`, `;` or `|`.
- **Export.** `Marketing opt-out` is blank when the customer is not opted out.
- **Analytics.** `campaign_drafted` and `campaign_send_session` are **not** added (§11 allows skipping), so the allowlist and the §9.5 doc are unchanged.
- **List filter.** "No phone or email" uses the entry's raw fields: no digit in the phone and a blank email. This differs from the segment's stricter reachability rule.
- **`maintenance_due` vs. the preset.** Both use the same matched set. The preset can still exclude someone the insight counts, for an unusable contact (fewer than 10 digits, or a malformed email) or a campaign send in the last 30 days. Those people appear in the exclusion list with the reason.

### 16.3 §9.2 wire contract (what the Worker and `book.html` must produce)

- **`bookingRequests.data.campaignCode`** (optional string): the booking link's `?c=` value, trimmed and lowercased by the Worker. It is stored only when it matches `^[0-9a-hjkmnp-tv-z]{16}$`; otherwise the key is absent and the booking still succeeds.
- **Native resolution** (`NativeBookingIntake.campaignDecision`):
  - trims and lowercases again;
  - matches exactly against `campaigns[].code`; zero or several matches resolve to none;
  - a request with `source == "portal"` never resolves.
- **When it resolves:**
  - the lead job (`jbk_<requestId>`) gets `campaignId = <campaign id>`;
  - a customer the booking **creates** gets `leadSource = "campaign"`;
  - a **matched** customer's `leadSource` is never filled, even when blank.
- **Links in messages:** `{bookingLink}` is `NativeBookingAdministrationService.bookingURL(token:)` with the query item `c=<campaign.code>` (an existing `c` is replaced). `isValidBookingURL` checks only `b`.
- **`book.html`** must read `?c=` and send it as `campaignCode` from `contactPayload()` in both submit and reserve, with no visible change.
- **Until then:** campaign links still open, and only the 30-day window attributes bookings.

### 16.4 Left for later

- **§9.1 Worker** (after Phase 34's booking work merges):
  - `cleanCampaignCode` in `BW/lib/booking/validate.js` beside `leadSource` and `referralCode`;
  - the notify-owner email line in `BW/lib/booking/notifyOwner.js`;
  - the Jest files listed in §12.
- **§9.3 `book.html`:** `?c=` plus the jsdom check.
- **On merging Phase 34:**
  - "a referral code beats a campaign code" in intake (§9.2 table, row 2);
  - one shared code encoder;
  - the typed `referredByCustomerId` in segments;
  - the referral share sheet's opt-out block (§4.3).
- **Residuals added by this build:**
  - Merging two customers does not re-point campaign recipients from the loser to the winner. The loser's pending recipient is skipped as `deleted` at send time, and window attribution and the recently-contacted guard keep counting the loser's id.
  - In the customer editor, a tag typed but not confirmed with return or a comma is not saved. The section footer says "Press return after each tag". The Edit tags sheet does save it.

### 16.5 Test results (2026-10-03, `TZ=America/Phoenix` from the runners)

- **New suites:**
  - `sh native/run-campaign-tests.sh`: PASS (270 checks);
  - `sh native/run-customer-tags-tests.sh`: PASS (112 checks).
- **Required list:**
  - PASS: `run-store-integration-tests.sh`, `run-canonical-tests.sh`, `run-adapter-tests.sh`, `run-snapshot-tests.sh`, `run-csv-import-tests.sh`, `run-csv-export-tests.sh`;
  - `run-accessibility-audit-tests.sh`: 2047 of 2048. The one failure is the pre-existing raw `.borderedProminent` at `N/RootView.swift:234`;
  - `run-layout-metrics-tests.sh`: 944 of 947. The three failures are pre-existing: RootView six tabs, the CoachView `Done` shortcut, and the `.keyboardShortcut` count off by one.
- **Every other runner that compiles a file changed here, or whose `main.swift` changed:** 90 more runners, run one at a time, all PASS. They include:
  - booking intake, schedule-booking recovery (1483 checks), customer identity, lead source (289), today insights and briefing;
  - initial sync, delta sync, mutation push and queue, sync backfill, two-device convergence, record deletion, rejected changes (185), repository;
  - accounting package, import mapping, engine and history, the phase 9/10/11 qualification suites, support diagnostics (239) and poor network (422).
- **Not run here** (the brief reserves them for the final gate): `run-analytics-event-tests.sh`, `run-error-redaction-tests.sh`, `run-save-rollback-tests.sh`. No analytics event was added.
- **Checks:**
  - `node scripts/parity-manifest.mjs --write` wrote 137 runners and 222 RN oracles;
  - `sh native/run-fixture-manifest-check.sh` reports current;
  - `sh native/check-runner-registration.sh` passes;
  - `sh native/run-doc-reference-check.sh` reports 0 missing.
- **Release compile:** `xcodebuild … -configuration Release -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build` gives BUILD SUCCEEDED, with no warnings in Phase 33 files.
- **Not run:** Worker Jest and `book.html` checks, since §9.1 and §9.3 are not in this build.

### 16.6 Review fixes (2026-10-04, `fix/campaigns-optout`)

- **Opt-out is per contact (§4.3, D4).** An opt-out on any live customer record now suppresses every record sharing its normalized phone (for text) or email (for email), using the duplicate-contact step's keys (`NativeCampaignContact.phoneKey`/`emailKey`). The check runs in segment evaluation after the channel is chosen (reason `opted_out`), in `NativeCampaignQueue.liveCheck`, and in the referral share. Who is marked opted out is unchanged. `NativeCampaignContact` moved into `N/Domain/NativeCustomerTags.swift` (next to `NativeMarketingOptOut.block(for:medium:among:)`) so the referral runner can compile it.
- **Referral share (§4.3).** `NativeReferralShareView` disables Continue and Copy for a blocked customer and shows `NativeMarketingOptOut.Block.explanation`.
- **Overlapping campaigns.** `liveCheck` also takes the campaign, all campaigns and today: a recipient another campaign sent to on or after this one's `frozenOn`, inside `excludeContactedWithinDays`, is skipped with the new skip reason `recently_contacted` ("contacted recently"). Pending-only overlaps still do not block at freeze.
- **Tags.** `normalize` turns `|` into a space as well as `,` and `;`, so every stored tag survives export (`; `) and import (`,;|`).
- **Intake.** A booking with a referral code that resolves to a referrer and a campaign code now fills a matched blank-source customer's `leadSource` and `referredByCustomerId` exactly like a referral-only booking (§9.2 row 2).
