# Phase 8 — Calendar, Booking, Routes, and Portals: Implementation Spec

**Date:** 2026-09-20

**Status:** Specified; implementation and verification pending.

**Execution plan:** [native-phase-8-implementation-plan.md](native-phase-8-implementation-plan.md)

**Scope authority:** [Native migration roadmap, Phase 8](native-ios-migration-roadmap.md#phase-8--calendar-booking-routes-and-portals).

## 1. Outcome and boundaries

An owner can plan a day/week, schedule work, configure public availability, manage
booking and customer-portal links, handle customer requests, and navigate a daily
route from the Swift app. Existing customer-facing booking and portal pages
continue using compatible Workers contracts.

Phase 8 owns:

- Calendar, schedule-only edits, working hours, buffers, gap suggestions, time off.
- Daily route planning with MapKit preview and navigation handoff.
- Booking-link administration, slot configuration, request conversion and owner
  responses; backend correctness needed for reservation and revocation promises.
- Customer portal administration and incoming portal requests; integration proof
  for existing estimates, invoices, appointments, change orders and visible photos.

The hosted `book.html`, `booking.html`, and `portal.html` pages belong to the
separate `tradeready-legal` deployment. Native owner controls and API compatibility
are in this repository; browser changes/evidence require that repository. Do not
interpret an unavailable hosted repository as proof those flows passed.

Route optimization, persistent route ordering, mileage writes, EventKit calendar
sync, a new customer-facing Swift app, and general Today redesign are outside
this phase. Booking/portal attention rows are included. Remote push transport and
analytics infrastructure remain later-phase integrations; expose typed navigation
and action boundaries for them and record the outstanding evidence.

### Completion levels

1. **Code complete:** deliverables, fixture parity, fault/concurrency coverage and
   native Release compilation pass; unresolved backend correctness gates prevent
   their dependent workflows being called complete.
2. **Parity verified:** physical-device, isolated-staging, hosted-browser and
   cross-client evidence also pass. Per the roadmap's 2026-09-16 owner decision,
   physical-device and isolated-staging evidence is deferred to Phase 12, not
   waived. Do not require staging provisioning to implement pure/native work,
   substitute production accounts, or mark mocked concurrency as database proof.

## 2. Grounded baseline

Paths in this document are repository-relative. `N/` below means
`native/TradeReadyNative/`; it is documentation shorthand, not a real directory.

| Area | Existing foundation | Required change |
|---|---|---|
| Data | `N/Domain/CanonicalModels.swift`, `CanonicalSnapshot.swift`: schedule, blackouts, booking link, customer portal, booking requests/slots/history | Reuse loss-preserving canonical shapes; no second persisted scheduling model |
| Calendar | `N/TodayView.swift` contains a selected-day `CalendarView` | Day/week layout, untimed section, queue, schedule actions and feedback |
| Schedule settings | `N/SettingsView.swift`, `Models.swift`, `Domain/UIModelAdapters.swift` | Replace lossy integer-hour/default/day-number projection with canonical schedule editing |
| Booking controls | `N/SettingsView.swift` has placeholder share/rotate actions | Real authenticated administration and truthful publication state |
| Sync | `N/NativeInitialSync.swift`, `NativeMutationQueue.swift`, `NativeSupabasePush.swift`, `NativeSyncBackfill.swift` | Booking collection already supported; add safe conversion/handled-field integration |
| Store | `N/AppStore.swift`: canonical snapshot, repository save, queue, owner checks, refresh, exact-ID navigation | Field-scoped schedule/portal commits and atomic multi-record conversion |
| Maps | `N/NativeAddressLookup.swift` | Reuse lookup patterns; add route-specific search/directions and UI |
| Portal content | Existing estimate/change-order/invoice workflows and `N/NativeJobPhotosView.swift` | Reuse `setJobPhotoVisibility`; validate server presentation rather than duplicate content |
| Messaging | `N/NativeMessageComposer.swift`, `NativeCustomerContactActions.swift`, `NativeAppointmentMessaging.swift` | Reviewed link sharing/contact actions; sharing is not delivery evidence |

Concrete prototype hazards:

- Canonical weekdays are ISO **Monday = 1, Sunday = 7**; existing native settings
  labels assume Sunday = 1.
- RN defaults are Monday–Saturday, 08:00–17:00, 60-minute appointments and zero
  buffer; prototype native values differ.
- Canonical `HH:MM` must retain minutes. Editing one schedule option must not
  round all working hours or overwrite token/configuration fields.
- A dated job without a time is **untimed**, not a midnight appointment. The
  current `scheduledAt` UI projection cannot make that distinction reliably.
- The projected `bookingEnabled` Boolean is not authoritative link publication.

## 3. Architecture and invariants

### 3.1 Pure policies, thin services, canonical commits

Add dependency-free Swift planners under `N/Domain/`, injectable network/MapKit
adapters under `N/`, and dedicated feature views. Proposed names and ownership
appear in the plan. Pure planners accept an injected clock, date frame, IDs and
canonical inputs and return projections or mutation plans; no network or store
writes occur inside views/planners.

Use existing repository and mutation-queue infrastructure. Resolve IDs against
the latest snapshot at commit, merge only fields owned by the action, and retain
unknown fields, null/absent distinctions, pricing, approvals, history and unrelated
concurrent edits. Reject a deleted record rather than recreate it. Multi-record
conversion commits customers, jobs and requests in one snapshot transaction.
Queue publication must recover from interruption between snapshot and queue
writes; test this boundary rather than assuming two file saves are atomic.

For network work, capture exact verified owner/workspace, target ID and operation
identity. Recheck after every suspension and before local publication. Follow
the existing `NativeChangeOrderApprovalLink.swift` authentication/environment
pattern: current bearer, bounded refresh retry for auth rejection, typed bounded
errors, no capability tokens/contact details in diagnostics, no production writes
from development configuration. Serialize mutations per target and disable
duplicate UI submissions. A timeout after a mutation is an **unknown outcome**,
not evidence of failure or permission to rotate/mint again automatically.

### 3.2 Authority and offline behavior

| Data/action | Authority and behavior |
|---|---|
| Owner schedule, schedule settings, blackout drafts | Local-first durable canonical save; pending sync visible |
| Displayed slot suggestions | Advisory; public server recomputes/claims authoritative availability |
| Booking/portal capability creation and revocation | Online server-acknowledged operation; local copies are display data |
| Booking status, reservation, history | Server-owned lifecycle; refresh after owner response; never replay stale whole blobs as decisions |
| Conversion IDs and portal `handledAt` | Native-owned fields merged without overwriting server lifecycle |
| Route order/geocoding | Session state; no job, invoice, trip or mileage mutation |

Keep cached content usable offline. Link actions requiring the server explain
offline/unavailable state. Do not show a local disable as cloud revocation, share
a fabricated URL, or call an unsynced schedule change published availability.
Server success followed by local-save failure must retain a truthful recovery
state; retry display-copy persistence without repeating destructive server work.

## 4. Scheduling contract (S1–S4)

Sources: `utils/scheduleConfig.ts`, `scheduleSmarts.ts`, `calendar.ts`,
`availability.ts`; `screens/CalendarScreen.tsx`, `SettingsScheduleScreen.tsx`.

### S1 — Resolved configuration and availability

- Defaults: ISO days `[1,2,3,4,5,6]`, `08:00`–`17:00`, duration 60 minutes,
  buffer 0, lead 24 hours, horizon 14 days, zone null, slots disabled, no blackouts.
- Match RN fallback handling, including valid zero lead/buffer. Preserve raw
  canonical data; resolving invalid legacy values is not an automatic rewrite.
- Dates are owner-naive `YYYY-MM-DD`; time arithmetic uses minutes since midnight.
  Viewing on a device in another zone must not shift the stored business date.
- Availability uses a fixed 30-minute grid; the entire duration must fit. Respect
  workdays, inclusive blackout bounds, lead equality, horizon and busy reservations.
- Terminal `complete/invoiced/paid/declined` jobs and missing-start jobs do not
  block availability. Missing end uses `max(laborHours, 1 hour)`, capped at midnight.
- Match oracle buffer behavior exactly; do not double the required separation.
- Owner IANA zone determines server UTC slots. Pin DST tests: spring-gap starts
  omitted, fall-fold uses earlier occurrence, missing end instant falls back to
  naive duration. Local scheduling remains representable independently of DST.
- New zone edits must validate as IANA zones before enabling slots; existing invalid
  zones remain recoverable and surface a configuration error, not a fabricated offer.

### S2 — Calendar and planning projections

- Day and Monday–Sunday week; previous/next increments day/week, Today resets.
- Render working-hour axis plus out-of-hours appointments, overlap-cluster lanes,
  untimed dated jobs, terminal history, blackout labels and nonworking days.
- Needs-scheduling queue: approved, no date, not archived, oldest first.
- Do not apply a blanket archive filter where the RN selector does not. Pin the
  current per-selector behavior before proposing a cross-client correction.
- Strict interval overlap: touching endpoints are allowed. Owner conflicts warn
  and never prevent saving. Show affected jobs and buffer context.
- `largestFreeGap` is the RN advisory helper: no buffer/blackout/workday filtering,
  no suggestion on empty days, earlier equal gap wins, UI threshold 30 minutes.
  Label it a gap suggestion, not a guaranteed reservable/fitting appointment.
- Job selection uses exact-ID routing; missing/deleted records show a recoverable
  state. Reuse refresh, empty, error and cached/offline presentation.

### S3 — Schedule-only mutation

A schedule draft carries job ID, baseline schedule/lifecycle, date, optional start
and end. Commit re-resolves current state and changes only the schedule fields;
only `approved → scheduled` is automatic. Booked leads stay leads. A concurrent
schedule/lifecycle change requires refresh/review instead of silent replacement;
unrelated pricing/contact/photo changes survive. Failed save retains the draft.
Use the RN editor's valid date/time constraints, and cover clearing date/time and
untimed jobs explicitly rather than relying on `DatePicker` defaults.

### S4 — Settings and time off

Draft/save/cancel working days, minute-precise hours, appointment duration, buffer,
lead time, horizon and timezone. Prevent removing the final working day and
invalid hour ranges; use oracle-compatible values. Enabling slots preserves an
existing valid zone or stamps device zone with UTC fallback. Blackouts have
stable IDs, inclusive dates and optional reason; only **Add** inserts the draft.
Removing one blackout preserves all others and nested unknown fields. Settings
save merges owned fields into the latest settings and retains booking credentials.

## 5. Booking contract (B1–B4)

### B1 — Existing HTTP contracts

Workers implementations: `backend-workers/src/routes/booking/` and
`backend-workers/lib/booking/`. The legacy `backend/api/booking/[action].js`
only exposes mint/config/submit; target Workers for this phase.

| Endpoint | Authentication/input | Current success |
|---|---|---|
| `POST /api/booking/mint` | Owner bearer; no required body | `{token}` (48 hex chars); stateless, not publication |
| `GET /api/booking/config?b=…` | Public capability | `{businessName}` |
| `POST /api/booking/submit` | `{b,name,phone,email,address,details,preferredTiming,website}` | `{ok:true}` |
| `GET /api/booking/slots?b=…` | Public capability | `{businessName,timeZone,slots:[{date,start,end,startUtc,endUtc}]}` |
| `POST /api/booking/reserve` | Submission fields plus `slot:{date,start}` | `{ok:true,manageToken,slot}` including zone/UTC fields |
| `GET /api/booking/manage?m=…` | Per-booking capability | `{businessName,status,slot}`; `format=ics` returns attachment |
| `POST /api/booking/manage` | `{m,action,note?}` | `{ok:true,status}` |
| `POST /api/booking/respond` | Owner bearer; `{requestId,action}` | `{ok:true,status}` |

Invalid input is 400; owner auth failure 401; unknown/disabled/foreign records 404;
stale slot/state 409 (`slot_taken` / `invalid_state`); rate limit 429; server failure
5xx. Do not retry rate limits in a tight loop. Public fields/limits, honeypot and
email validation remain governed by `booking/validate.js`.

### B2 — Owner link administration

Create, copy/share, disable/re-enable and explicitly confirmed rotate. URLs use
`https://gettradereadyapp.com/book.html?b=…` with URLComponents encoding. Keep
slot enablement separate from whether the booking link accepts quote requests.

**Required improvement:** server-authoritative booking administration is needed
for the roadmap's revocation criterion. Proposed additive owner endpoint:
`POST /api/booking/admin` with `{action: mint|set_enabled|rotate, enabled?,
operationId}`. Required response: `{ok:true, enabled, token?, revision}`; creation/
rotation must support recovering the same operation after response loss without
creating another capability. This endpoint does **not** exist today.

Task 8.00 must freeze its storage, operation replay and legacy-sync compatibility
contract before dependent implementation. Preserve old mint and public request
shapes for the RN release. Authority must prevent a stale settings push from
resurrecting a disabled/rotated token. Define revocation's linearization point:
after acknowledged commit, subsequent old-token resolutions fail; a mutation
authorized before it must be serialized/revalidated under the same authority.
Existing per-booking manage links remain independent capabilities.

The old stateless-mint/whole-settings flow cannot by itself distinguish intentional
RN rotation from delayed stale publication. Freeze post-adoption RN administration
semantics explicitly: legacy public access, pre-adoption mint/rotate, post-adoption
mint/rotate/enable and delayed settings writes each need a compatibility row.
Either supply a server-verifiable discriminator or document the exact legacy
administration limitation; do not promise both behaviors without a mechanism.

Booking and portal administration also require an authoritative read/reconciliation
contract: current enabled state/revision, validation of the local display token,
and whether current raw-token recovery is available. Mutation replay alone cannot
discover another device's later rotation. Share/adopt only a display token proven
current; otherwise show recovery/unavailable state. Freeze this contract in 8.00.

### B3 — Conversion and request intake

Source: `utils/storage/bookingConversion.ts`, `bookingAttention.ts`,
`storage/bookingRequests.ts`, `bookingRespond.ts`, `screens/TodayScreen.tsx`.

- Port the existing explicit convertible states first: `new`, and `booked` with
  `kind == booked` and no `convertedJobId`. Unknown states stay intact/inert.
- Deterministic job ID `jbk_<requestId>`; never overwrite an existing job on replay.
  Free-text becomes an unscheduled lead, title “Quote request”, status `converted`.
  Slot request becomes a **lead with slot schedule**, title “Booked appointment”;
  preserve booking status and stamp conversion IDs.
- Reuse source customer when present and valid; otherwise existing customer
  identity/backfill rules. Carry description, timing, provenance and pricing
  defaults exactly. Commit all changed records once; no-op enqueues nothing.
- Run after verified workspace + successful initial/delta pull and foreground
  refresh; serialize runs and recheck current records before applying a plan.
- `portal_change_requested` never becomes a lead. Portal follow-up `new` requests
  can convert and retain `sourceCustomerId`.
- Attention shows reschedule requests and applicable cancel/decline notices;
  use the RN current-job comparison. Portal Done only updates `handledAt`.
- Server lifecycle/history must survive conversion/handled updates arriving late
  from either client. Existing history union alone does not establish that.

**Characterization gates:** current RN conversion skips `confirmed` and
`reschedule_requested` before initial conversion; two devices may create duplicate
customers despite a deterministic job ID. Task 8.00 records these as compatibility
decisions, with fixtures. Do not silently broaden terminal-state conversion or
claim globally unique customer creation. At minimum surface unconverted active
bookings for inspection so a confirmed booking cannot disappear from owner intake.

### B4 — Lifecycle and reschedule

| Actor/action | Allowed prior state | Next state | Current reservation behavior |
|---|---|---|---|
| Customer confirm | booked (confirmed retry succeeds) | confirmed | retained |
| Customer request_reschedule | booked, confirmed | reschedule_requested | retained |
| Customer cancel | booked, confirmed, reschedule_requested | cancelled | released |
| Owner resolve_reschedule | reschedule_requested | confirmed | released |
| Owner decline | booked, confirmed, reschedule_requested | declined | released |

Customer note is capped at 300 characters. History is server authored. Owner
response requires an explicit action; on 409 refresh authoritative state rather
than forcing the captured status. Server decline may email the customer: do not
send a duplicate native notification email.

Current resolve accepts no replacement slot and does not change the job or request
slot. Native must durably save and successfully publish the revised job schedule
before releasing the old reservation. Cancellation/decline must explain that the
linked job is unchanged and offer its schedule action; do not silently delete it.
Publication proof must identify the exact intended schedule/mutation, not merely
a completed sync pass. Task 8.00 defines server preconditions, acknowledgment and
revalidation after concurrent edits, including behavior for legacy RN calls that
carry no schedule proof. A superseded schedule must not trigger native resolution.
Whether manage/ICS returns the original booked slot or a replacement is a required
contract decision in 8.00, not an assumption inside the UI.

## 6. Routes contract (R1)

Reference: `screens/RouteScreen.tsx`, `utils/storage/dailyOps.ts`.

Show today's jobs in local-date context, initially ordered by start time with
untimed jobs last. Match the source status/archive membership. Up/down reorder
and reset are session-local; refresh/re-entry restores source ordering. Include
missing-address rows but exclude them from navigation destinations.

Native addition: MapKit stop preview and sequential driving-leg preview for the
chosen order, with cancellable address resolution/directions. No optimization or
automatic reschedule. A failed/ambiguous address remains editable/viewable; map
failure cannot hide the stop list. Ignore stale geocoding after date/order/owner
changes. No location permission is required simply to view stored addresses.

Per-stop Apple Maps handoff; full-route URL preserves RN waypoint order and uses
business address as origin, otherwise first usable stop. Retain the RN Google
Maps web multi-stop fallback where Apple Maps cannot express the route. Encode
addresses safely, report open failure and offer address copy. Route labels must
distinguish preview estimates from actual navigation. Never mutate schedule or
mileage as a side effect of opening Maps.

## 7. Portal contract (P1–P3)

### P1 — Owner administration

Sources: `utils/portalLink.ts`, `screens/CustomerDetailScreen.tsx`,
`backend-workers/src/routes/estimate/portalManage.js`,
`backend-workers/lib/estimate/portalManage.js`, `portalTokenStore.js`.

`POST /api/estimate/portal-manage`, owner bearer:

- `{action:"mint",customerId}` → `{ok:true,token}`.
- `{action:"set_enabled",customerId,enabled}` → `{ok:true,enabled}`.
- `{action:"rotate",customerId}` → `{ok:true,token}`.
- 409 `already_exists` on stale Create means refresh authority and adopt only a
  matching current display copy, never implicit rotate.

Require a saved customer; invoice-derived identities first use explicit customer
promotion. Create/share/enable/disable/rotate appear in customer detail. Rotate
requires confirmation. Use `https://gettradereadyapp.com/portal.html?p=…`.
Server acts first; merge only the returned portal display fields into the latest
customer after rechecking owner/existence. Do not re-save a captured customer array.
Use reviewed mail/system share; sharing never means delivered.

Per-customer serialization is necessary but not sufficient: backend must enforce
single-current-token and atomic rotation across devices. Handle local mirror
failure/response loss without silently issuing a replacement token. A missing raw
token may require explicit recovery rotation; label that limitation until the
replay contract is implemented. Disable must not wait behind unrelated queue work
once the server customer exists.

### P2 — Hosted content and authority

Workers routes: `portal-view`, `portal-ics`, `portal-request`, `portal-manage` under
`/api/estimate/`; public signed images under `/api/photos-public/:photoId`.

Validate `portal-view?p=…` whitelist: business/customer names, appointments,
estimates, change orders, invoices and photos. Preserve frozen approval snapshots,
shared invoice balance/payment-link rules, cancelled-change exclusion, appointment
window and customer/owner filters. Native publishing reuses existing records.
Photos require explicit visibility, uploaded bytes and valid signed URL. Local
visibility change is pending until metadata/bytes synchronize.

Token table stores hashes; raw tokens also exist in canonical display copies.
Known revoked/disabled table rows must block legacy fallback. The Vercel legacy
portal-view does not provide the same authority as Workers: integration must prove
the public page uses the intended Worker. Portal entry revocation does not revoke
previously issued estimate/payment/manage links or signed photos (15-minute URL
TTL and existing private cache). State these boundaries in verification evidence.

Unknown-token legacy fallback must also be restricted to customers not yet adopted
into server authority. Current lookup can return a blob token even when its
best-effort backfill fails; a single-current-token constraint alone cannot fix
that. Adoption/backfill and administration must share the authority boundary.
After adoption, an unknown stale blob token must fail, including a backfill racing
rotation. Test failed/conflicting backfill without granting capability access.

ICS uses floating local times, or all-day for untimed appointments. Audit the
backend `archived` checks against canonical `archivedAt`; freeze the intended
appointment visibility/actionability fixture before changing behavior.

### P3 — Customer requests

`POST /api/estimate/portal-request` accepts
`{p,kind:followup|reschedule|cancel,note,jobRef?,requestKey,website?}`. Identity comes
from the scoped customer, not user-supplied contact fields. Follow-up requires
note and creates `new`; appointment changes require a customer-owned scheduled
job and create `portal_change_requested`. They **request** action, not directly
cancel/reschedule the job. The server's deterministic request ID deduplicates
inserts; retries can still duplicate logging/notification, which needs explicit
qualification. Native shows request/customer/job context, contact/open-job actions
and Done (`handledAt`), with missing-job handling and concurrent sync preservation.

## 8. Backend correctness gates (G1–G4)

These findings are source-based, not claims of reproduced production incidents.
They require characterization before fixes. Backend changes remain compatible
with the RN release; implementation tasks do not authorize deployment.

| Gate | Current limitation | Required implementation/evidence |
|---|---|---|
| G1 Reservation integrity | `20260807_booking_reservations.sql` only uniquely indexes owner + identical start; reserve writes hold then request separately | Atomic availability recheck + reservation/request commit; serialize competing owner claims or equivalent interval constraint covering buffers; no orphan hold on failure; same-start, different-start overlap and buffer-only races have one winner |
| G2 Lifecycle authority | Manage/respond release hold and patch whole request separately; device blobs can be stale | Transactional state/hold/history transition with expected-state/version conflict handling; compatible server-field protection on legacy device upserts; retry cannot duplicate transition/history/side effects |
| G3 Booking revocation | Stateless mint then eventual settings sync | Server-acknowledged admin and legacy handoff, idempotent operation recovery; stale RN/Swift settings writes cannot restore revoked capability |
| G4 Portal token integrity | Read-then-mint and revoke-then-insert; no single-active constraint | Transactional per-customer mint/toggle/rotate with invariant enforced in DB; concurrent operations deterministic; insertion failure rolls back; disabled tokens cannot all reactivate unexpectedly |

Preferred booking design is a database transaction/RPC serialized per owner that
rechecks current token/configuration/busy intervals before claiming and inserts
both records atomically. Terminal lifecycle operations use the same consistency
boundary. Merely checking availability again in JavaScript or adding client locks
does not satisfy G1. A constraint/lock design must explicitly address concurrent
job/settings updates, legacy direct Data API writes and buffer changes. Owner
manual conflicts remain allowed; document their ordering relative to claims.

Task 8.00 freezes the exact SQL/API/recovery contracts and compatibility matrix;
8.04–8.06 implement them. Unresolved design entries block those dependent tasks,
not independent calendar/routes work. Real database concurrency and deployed
migration evidence may remain deferred to Phase 12; report that separately from
local harness coverage and from unfinished implementation.

## 9. Acceptance matrix and traceability

| ID | Acceptance | Primary oracles under `__tests__/` | Tasks |
|---|---|---|---|
| S1 | Defaults, ISO days, minute precision, timezone/DST, slots/reservations match | `scheduleConfig.test.ts`, `availability.test.ts`, `availabilityParity.test.ts`, `bookingAvailability.test.js` | 8.01 |
| S2 | Day/week/lanes/untimed/queue/gaps/history and exact navigation | `calendar.test.ts`, `calendarScreen.test.tsx`, `scheduleSmarts.test.ts` | 8.01, 8.09 |
| S3 | Latest-ID schedule-only save; conflict warning; failure keeps draft | `calendarScreen.test.tsx`, native store integration | 8.08, 8.09 |
| S4 | Minute-safe settings; Add-only time off; credentials preserved | `settingsScheduleScreen.test.tsx`, native adapter/store | 8.08, 8.10 |
| B1–B2 | Real published links; offline truth; rotate/disable revoke after acknowledgment | `bookingMint.test.js`, `bookingLink.test.ts`, `bookingLinkSettings.test.tsx` | 8.00, 8.05, 8.07, 8.10 |
| B3 | Replay-safe conversion; portal change inert; server history/status preserved | `bookingConversion.test.ts`, `bookingAttention.test.ts`, `bookingRequestsStorage.test.ts` | 8.02, 8.08, 8.11 |
| B4 | Explicit legal responses; published reschedule before release; conflict refresh | `bookingManage.test.js`, `bookingRespond.test.js`, `bookingRespondClient.test.ts` | 8.04, 8.07, 8.11 |
| R1 | Ordered map/list, missing address, handoff fallback, no business-data writes | `RouteScreen.tsx` behavior; new native route fixtures | 8.03, 8.12 |
| P1 | Saved identity, stale Create 409, server-first toggle, confirmed rotate | `portalLink.test.ts`, `portalLinkCustomerDetail.test.tsx`, `portalTokensWorkers.test.js` | 8.06, 8.07, 8.08, 8.13 |
| P2 | Scoped portal content/ICS/photo visibility and capability boundaries | `portalAssembleWorkers.test.js`, `portalStoreWorkers.test.js`, `portalIcsWorkers.test.js`, `photoSignWorkers.test.js` | 8.14 |
| P3 | Follow-up conversion; changes only requests; handled convergence | `portalRequestWorkers.test.js`, booking storage/conversion | 8.02, 8.08, 8.11, 8.14 |
| G1–G4 | Real competing operations, interruption recovery, stale clients | `bookingSlotsReserve.test.js`, portal token tests plus new transaction/concurrency harnesses | 8.00, 8.04–8.06, 8.14 |

Every async suite includes account switch, record deletion, malformed success,
401 refresh, 404, 409, 429, timeout/unknown outcome and persistence failure where
applicable. Every canonical mutation suite includes unknown-field preservation.

Deferred device/staging checklist, to be expanded in task 8.15: iPhone/iPad,
light/dark, large Dynamic Type, VoiceOver/keyboard, day/week reschedule, real Maps
handoff, share/mail cancellation, offline/relaunch, timezone change, public booking
race, disable/rotate before normal sync, RN↔Swift edits, portal requests/content,
photo visibility, ICS and approval/payment navigation. Record build/environment,
steps, expected/actual, evidence location and pass/fail/deferred for each row.
