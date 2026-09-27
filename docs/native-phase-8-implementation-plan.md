# Phase 8 — Subagent Implementation Plan

**Date:** 2026-09-20

**Status:** Ready for contract characterization; no implementation tasks completed.

**Spec:** [Calendar, booking, routes and portals](native-phase-8-calendar-booking-routes-portals-spec.md).

## 1. Execution contract

Use one bounded task per subagent session. Read the spec and source references
before editing; existing uncommitted migration/backend files are working inputs,
not disposable scaffolding. Do not commit, deploy, run live migrations or contact
production accounts unless separately instructed.

`N/` means `native/TradeReadyNative/`. Proposed filenames below do not imply files
already exist. Match existing host-test runners and Xcode source inclusion rather
than introducing another package/build system.

Every implementation task must:

1. State satisfied dependencies and the requirement IDs it implements.
2. Keep policy in pure Swift modules and services injectable; use canonical
   preservation, existing owner/environment guards, repository and mutation queue.
3. Resolve current IDs, merge owned fields, check async owner/operation identity,
   and publish success only after the relevant durable/server boundary.
4. Add meaningful fixture/failure tests, run focused checks, and compile when
   touching UI/platform wiring. Report exact commands and actual results.
5. Return files changed, test counts/results, limitations/blockers and next-ready
   task IDs. A blocked task stays blocked; no placeholder action counts as done.

### Shared-file ownership

- **Integration lane:** only tasks 8.08–8.13 edit `AppStore.swift`, `TodayView.swift`,
  `SettingsView.swift`, `CustomersView.swift`, `RootView.swift` and navigation state.
  Run those tasks serially even when their policy dependencies are ready.
- **Backend lane:** 8.04–8.06 run serially; they share stores, SQL and router
  registration. Keep changes compatible with existing RN requests.
- **Pure/service lane:** 8.01, 8.02, 8.03 and later 8.07 use separate files and can
  run in parallel where dependencies permit. They return integration contracts;
  they do not opportunistically edit shared UI/store files.
- The coordinating agent owns aggregate runner/project membership and document
  updates. A task may propose the exact additions; serialize their application.
  Separate worktrees are preferred for concurrent writers; never merge by
  overwriting another task's shared-file edits.

## 2. Dependency graph and waves

```text
8.00 contract/characterization baseline
 ├─ 8.01 schedule/calendar domain ─────────────┐
 ├─ 8.02 booking/portal intake domain ─────────┼─ 8.08 canonical integration
 ├─ 8.03 route domain + MapKit adapter        │    ├─ 8.09 calendar UI
 └─ 8.04 reservation/lifecycle backend       │    ├─ 8.10 schedule/booking UI
      └─ 8.05 booking authority              │    ├─ 8.11 request UI
           └─ 8.06 portal authority          │    └─ 8.13 portal UI
                └─ 8.07 owner transports ────┘
8.03 ── 8.12 route UI
8.04–8.13 ── 8.14 qualification ── 8.15 closeout
```

The diagram expresses interface dependencies, not a requirement to wait for every
backend implementation before useful integration. Task 8.08 may implement/test
local schedule and conversion slices after 8.01/8.02 while remote adapters remain
blocked; it is complete only after integrating 8.07. Likewise 8.09 and 8.12 can
proceed before remote work once the coordinator releases the shared-file lane.

Recommended waves:

1. 8.00. Freeze independent native interfaces even if a backend decision remains open.
2. Parallel 8.01 / 8.02 / 8.03 and backend lane 8.04 → 8.05 → 8.06.
3. 8.07 after server contracts are frozen; its mocks can precede backend completion,
   but its acceptance cannot claim unimplemented server behavior.
4. Shared-file lane 8.08 → 8.09 → 8.10 → 8.11 → 8.12 → 8.13.
5. 8.14 → 8.15. Start characterization/race probes in 8.00, not at closeout.

## 3. Task packets

### 8.00 — Freeze contracts and characterize gaps

**Depends on:** none. **Owner:** coordinating agent/backend design subagent.

Read roadmap Phase 8, the spec, RN scheduling/booking/portal sources and existing
Workers stores/routes/SQL. Record current behavior in fixtures without changing
implementation. Create `docs/native-phase-8-contract-decisions.md` with:

- Exact proposed `/api/booking/admin` request/response, operation replay lifetime,
  secure raw-token recovery/storage, version/conflict and error contract.
- SQL transaction/RPC boundaries for per-owner reservation and lifecycle; lock
  ordering, duration/buffer predicate, job/settings concurrent-write semantics,
  request/hold rollback and legacy Data API field protection.
- Booking token legacy handoff, initial backfill and stale-settings behavior;
  portal single-current-token/disabled-token rules and rotation recovery.
- Post-adoption RN administration matrix: distinguish intentional old-client
  create/rotate/enable from stale whole-settings replay with a specified mechanism,
  or name the precise compatibility limitation. Do not assume both are achievable
  from an indistinguishable legacy payload.
- Authoritative booking/portal reconciliation: read/status method, enabled state,
  revision, local-token validation and raw-token recovery availability. Define
  adoption-gated legacy fallback, including backfill racing rotation.
- Exact replacement-schedule publication proof for reschedule resolution: server
  preconditions, native acknowledgment/revalidation and superseding-edit refusal;
  explicitly specify legacy calls without that proof.
- Decisions for confirmed-before-conversion, cross-device customer duplication,
  rescheduled manage/ICS slot presentation and `archived`/`archivedAt` semantics.
- Additive deployment order, database constraints/backfill validation, rollback
  behavior and RN compatibility tests. No token/schema rewrite by assumption.

**Deliver:** contract decision table (chosen/blocked with reason), fixture index,
characterization tests for G1–G4 and an API/type handoff for independent native work.
Suggested new backend tests: booking integrity, booking admin, portal concurrency.

**Done when:** every backend-dependent task has an exact contract or named blocker;
existing oracle behavior and proposed intentional differences are distinct. Tests
expose different-start overlaps, pre-conversion confirmation, stale capability
push, rotate failure and lifecycle race. A mocked 409 is not database race evidence.

### 8.01 — Pure schedule, availability and calendar engine

**Depends on:** 8.00 native contract freeze. **Requirements:** S1, S2.

**Read:** `utils/{scheduleConfig,scheduleSmarts,calendar,availability}.ts`, their
spec-indexed tests; `N/Domain/CanonicalModels.swift`, `UIModelAdapters.swift`.

**Own:** new `N/Domain/NativeSchedule.swift`, `NativeCalendar.swift`,
`NativeAvailability.swift`; `native/ScheduleTests/main.swift`,
`CalendarTests/main.swift`, `AvailabilityTests/main.swift` and focused runners.

1. Define owner-local date/time value helpers and resolved schedule projection.
2. Port defaults, busy windows, conflicts, gaps, slots and date/week selectors.
3. Add timed/untimed rows, axis/lane layout, queue and immutable edit-draft input.
4. Export deterministic fixtures shared with RN/Workers where practical.

**Done when:** default/null/zero/minute/ISO-day, endpoint-touch, buffer, terminal,
archive-per-selector, midnight, DST/zone, blackout, horizon/lead and overlap-cluster
vectors pass. No mutation occurs merely by resolving legacy configuration.

### 8.02 — Pure request conversion and attention policies

**Depends on:** 8.00 intake decisions. **Requirements:** B3, P3.

**Read:** `utils/storage/bookingConversion.ts`, `bookingRequests.ts`,
`utils/bookingAttention.ts`, `screens/TodayScreen.tsx`; native customer identity.

**Own:** `N/Domain/NativeBookingIntake.swift`, `NativeBookingAttention.swift`,
`native/BookingIntakeTests/main.swift`, `BookingAttentionTests/main.swift`, runners.

Return an explicit canonical mutation plan (expected source records, changed
customers/jobs/requests), not a second store. Port deterministic job identity,
customer linking, exact defaults/provenance and status gating. Model actionable,
handled, missing-job and unconverted-active attention states. Preserve unknown
statuses and portal-change requests. Incorporate only the explicit 8.00 decisions.

**Done when:** repeat/no-op, existing job, deleted source customer, malformed
request, slot lead, portal follow-up, portal-change inertness, cancellation
comparison and confirmed-before-conversion fixtures pass. Document the two-device
customer-duplication limitation if the compatibility decision retains it.

### 8.03 — Route policy and MapKit service

**Depends on:** 8.00 route contract. **Requirements:** R1.

**Read:** `screens/RouteScreen.tsx`, `utils/storage/dailyOps.ts`,
`N/NativeAddressLookup.swift`.

**Own:** `N/Domain/NativeRoutePlanning.swift`, `N/NativeRouteMapService.swift`,
`native/RoutePlanningTests/main.swift`, focused runner/platform tests as needed.

Implement exact daily membership, ordering/reorder/reset, missing-address
projection, safely encoded handoff URLs and injectable address/directions service.
MapKit preview follows selected order with cancellable sequential legs; stale
results cannot change a newer route. Return partial/error map states separately
from usable stop-list data. No optimization or canonical writes.

**Done when:** empty/one/many/untimed/addressless jobs, Unicode URL encoding,
business-origin fallback, reorder/reset, partial lookup, route failure and stale
request/owner cancellation pass. Platform code compiles for the current target.

### 8.04 — Atomic reservations and booking lifecycle

**Depends on:** 8.00 frozen G1/G2 SQL and compatibility contract.

**Read/own:** `backend-workers/lib/booking/{reserve,manage,respond,store}.js`,
corresponding route wrappers, additive `supabase/migrations/` SQL and verification
queries; native sync/legacy upsert changes only via coordinating integration task.

Implement transactional revalidation/claim/request creation and atomic lifecycle,
history and reservation release. Add expected-state/version conflict handling,
retry/recovery semantics and field protection from the frozen design. Preserve
existing public payloads and owner 404 isolation. Model response-loss and duplicate
notification handling explicitly. Existing old routes must remain compatible.

**Done when:** concurrent identical-start, overlapping-different-start, buffer-only
and disjoint/cross-owner cases; write failure/rollback; confirm-vs-cancel/respond;
stale device push; retry and reschedule-publication ordering pass the available
transaction harness at the server-precondition level, including defined legacy
call behavior. Native ordering belongs to 8.08/8.11 and end-to-end proof to 8.14;
8.04 does not wait for those downstream implementations. Check in commands for
actual PostgreSQL concurrency proof;
if not run locally, label it deferred, not passed. No migration deployment here.

### 8.05 — Server-authoritative booking links

**Depends on:** 8.04; 8.00 frozen G3 contract.

**Own:** new Workers booking admin core/route, router registration, booking token
authority/store integration, additive SQL and tests; retain existing mint route.

Implement create/enable/disable/rotate and replay by operation ID. Make public
config/submit/slots/reserve use the same authority; validate revocation at claim
commit. Implement legacy adoption and stale-settings guard from 8.00, not a
native-only convention. Implement authoritative status/token validation from
8.00 and return the exact frozen responses needed for native reconciliation.

**Done when:** acknowledged disable/rotate rejects the old token before ordinary
client sync; RN stale settings cannot resurrect it; retry returns same operation;
lost response and partial failure recover; legacy links and old RN administration
match every row of the 8.00 compatibility matrix. Existing manage tokens remain
independent. Add route-level auth/error tests.

### 8.06 — Transactional portal token administration

**Depends on:** 8.05 for backend-lane serialization; 8.00 frozen G4 contract.

**Read/own:** `backend-workers/lib/estimate/{portalManage,portalTokenStore}.js`,
`src/routes/estimate/portalManage.js`, portal token migration follow-up and tests.

Enforce the chosen single-current-token invariant through transactional
mint/toggle/rotate and database constraints, including disabled/legacy rows.
Preserve existing endpoint payloads/409 behavior; add replay support only as frozen
in 8.00. Add authoritative state/local-token validation. Keep known revoked-token
lookup from falling through to blob fallback and restrict unknown-token fallback
to unadopted customers; conflicting/failed backfill cannot authorize a stale token.

**Done when:** simultaneous mint/rotate/toggle, insertion failure after revoke,
legacy backfill, stale display copy, disabled old tokens and response-loss recovery
are covered, including unknown stale blob tokens after adoption and lazy-backfill
racing rotation. Explicitly test unknown/foreign customer 404. Note public signed-photo
and independent capability expiry limits rather than claiming global revocation.

### 8.07 — Native owner HTTP transports

**Depends on:** frozen interfaces in 8.00; acceptance requires 8.04–8.06.
**Requirements:** B1, B2, B4, P1.

**Read:** `N/NativeChangeOrderApprovalLink.swift`, `BuildEnvironment.swift`,
`utils/{bookingLink,bookingRespond,portalLink}.ts`, updated Workers routes.

**Own:** `N/NativeBookingAdministration.swift`, `NativeBookingResponse.swift`,
`NativePortalAdministration.swift`; separate focused transport test directories
and runners. Return operation identity and typed results; no AppStore/UI edits.

Implement injected loaders, strict URL/response decoding, current verified bearer,
bounded auth-refresh integration interfaces, environment boundary and error mapping.
Differentiate definitive refusal, transient error and unknown mutation outcome.
Never automatically retry a destructive non-idempotent operation.
Implement the frozen authoritative status/local-token validation API for both
link families; an eventually synced display copy is not proof of current validity.

**Done when:** request method/body/header fixtures, malformed/oversized or invalid
token/URL results, missing configuration, auth refresh, 404/409/429/5xx and timeout
pass; no secrets in diagnostics. Include server-success/local-mirror handoff tests.

### 8.08 — Canonical AppStore integration

**Depends on:** 8.01, 8.02 and 8.07 (local slices may start earlier).
**Requirements:** S3, S4, B2–B4, P1, P3.

**Own:** serialized edits to `N/AppStore.swift`, minimal adapters/queue/sync hooks,
`native/StoreIntegrationTests/main.swift`; extracted coordinator files if useful.

Add typed entry points for schedule-only commit, schedule-settings commit, atomic
intake, handled timestamp, owner responses, and booking/portal administration.
Use stable IDs and baseline conflict checks. Apply intake after verified pull;
serialize overlapping refreshes. Integrate current server authority/field merges.
Remote actions recheck owner/record after suspension; reschedule response waits
for exact intended job-mutation acknowledgment and revalidates against superseding
schedule edits as specified in 8.00. Reconcile link authority before adopting or
sharing a local display copy. Persist/recover incomplete local mirror or queue
publication work; scrub owner-bound pending work on account boundary.

**Done when:** injected snapshot/queue failure at each boundary, relaunch, no-op,
simultaneous refresh, unrelated edits, schedule conflict, webhook/lifecycle during
conversion, customer deletion, account switch and stale response pass. Do not
publish a whole stale booking request to repair one owned field. Refresh updates
reminder scheduling through existing infrastructure without inventing another sender.

**Note (2026-09-26, Phase 12 task 12.00b.2-I, defect `P12-013`):** the "recover"
half of the pending-work requirement was missing. Work was staged, but
`recoverScheduleBookingPendingWork` had no caller, so after a relaunch nothing finished
a staged link mirror or cleared a reschedule proof. It now runs for the verified owner at
launch (the signed-in gate-open points, after the initial sync) and on every activation
(`performForegroundRefresh`). It re-checks the account generation and owner after every
await. A mirror is read and merged only after a pull has committed in that launch or
activation (the initial sync on a cold launch; on a warm activation the foreground
refresh's own pull, since the gate-open points fire before it), because the merge queues
the whole settings or customer record and the push runs before the pull; until then, or
when that pull fails, it waits (review fix round 1). It is applied only when a fresh
`status` read (contract §6) says the token it writes back is current: the staged token
after a Create or Rotate, the local link's token after an Enable or Disable. Otherwise it
is dropped without a write. It never sends a mutation. A reschedule proof is kept only
while its resolve can still succeed (contract §7); recovery never resolves. Host evidence:
`native/run-schedule-booking-recovery-tests.sh`. Phase 12 final review (M1, M5, 2026-09-27): that
pull must also have started under the current account generation and after the scene last entered
the background, and a pull taken before or while a gate waits for the owner does not count, as for
intake below; a failed recovery save is reported with the sync status code `recovery/local-commit`,
never in `migrationMessage`.

**Note (2026-09-27, Phase 12 task 12.00b.2-K, defect `P12-016`):** "Apply intake after verified
pull" had no production caller: `runBookingIntakeAfterVerifiedPull` ran only in host tests, so a
pulled booking never became a job on a native-only account. Intake now runs where RN converts
(`App.tsx:396`, `context/AuthContext.tsx:118-120`): where the subscription gate opens the signed-in
gate straight after the initial sync's commit (a cold launch), and in `performForegroundRefresh`
after its sync, before pending-work recovery. It runs only for the verified owner after the initial sync, and only after a
pull that committed every table in that launch or activation and started under the current account
generation; it converts from that pull (`runBookingIntakeIfPossible`) instead of pulling again. A
failed or partial pull converts nothing: a pull that missed the jobs table could miss the job another
device made from the booking, and the push after a conversion would replace it.
`runBookingIntakeAfterVerifiedPull` keeps its own pull for the host tests; both run the same intake.
A failed intake save is reported with the sync status code `intake/local-commit`, not in
`migrationMessage`. Review fixes (same date): a pull taken before or while a gate waits for the owner
(onboarding, the starting point, the paywall) does not count, so a gate that opens after a wait leaves
conversion to the next activation; and the recheck links a request to a `jbk_` job already on the
device and carries a repeat customer's blank-field fill, as RN does (contract §8 note). Phase 12 final
review (M1, M3, 2026-09-27): the scene entering the background clears the mark, and a pull still in
flight then does not set it; a cold launch's request stamp is guarded with the initial sync's own
watermark (contract §8 note). Host evidence: `native/run-schedule-booking-recovery-tests.sh` section K
and section Z.

### 8.09 — Calendar UI

**Depends on:** 8.01 and schedule slice of 8.08. **Requirements:** S2, S3.

**Own:** `N/NativeCalendarView.swift`, `NativeScheduleEditorView.swift`; replace
prototype calendar wiring in `TodayView.swift` through integration lane.

Implement day/week navigation, lanes/axis, untimed section, unscheduled queue,
time-off labels, conflict warnings, gap suggestions and exact-job navigation.
Use schedule-only draft/save and stale-state recovery. Cached data remains usable
through refresh errors. Provide accessible list/labels alongside visual grid.

**Done when:** UI covers all domain states, warn-and-save behavior, missing job,
failure-keeps-draft and cancel-without-write; navigation hits the correct ID.
Compile and record focused host/UI checks; device layout proof remains deferred.

### 8.10 — Schedule and booking settings UI

**Depends on:** 8.08, 8.09 (shared-file serialization), 8.05/8.07.
**Requirements:** S4, B2.

**Own:** `N/NativeScheduleSettingsView.swift`, `NativeBookingSettingsView.swift`,
replace relevant `SettingsView.swift` destinations/prototype controls.

Implement ISO day labels, minute hours, duration/buffer/lead/horizon/zone, explicit
blackout Add/remove and draft save/cancel. Separate slot availability from link
enablement. Implement real create/copy/share/disable/enable/confirmed rotate with
published/pending/unavailable/recovery states and per-action busy protection.

**Done when:** no empty button actions; token preserved during settings save;
offline changes do not claim public publication; 409/response-loss/local-save
failures produce truthful recovery. Share cancellation changes no delivery state.

### 8.11 — Booking and portal request attention UI

**Depends on:** 8.02, 8.08, 8.10 (shared-file serialization).
**Requirements:** B3, B4, P3.

**Own:** `N/NativeBookingRequestsView.swift`, minimal Today attention integration.

Show request/customer/job/timing, unconverted-active cases, view-job/contact,
reschedule review, explicit resolve/decline, portal Done and missing-record states.
Distinguish customer request from completed job change. A resolved reschedule is
sent only after schedule publication; cancelled booking does not imply job deletion.
Use existing reviewed contact composers and exact-ID routing.

**Done when:** status changes while sheet open, 409 refresh, offline response,
decline confirmation, portal request duplication/handled merge and deleted linked
job behave correctly. Actions cannot apply to a different owner after suspension.

### 8.12 — Route UI and navigation handoff

**Depends on:** 8.03; integration lane availability (normally after 8.11).
**Requirements:** R1.

**Own:** `N/NativeRouteView.swift`, Today destination wiring.

Implement map plus ordered accessible stop list, move up/down/reset, addressless
rows, per-stop navigation and full-route handoff. Preserve list on partial map
failure; offer copy on unsupported/open failure. Show progress for lookup and
cancel obsolete work. Keep business-data mutations out of route screen.

**Done when:** zero/one/many stops, reorder/reset, lookup error, handoff fallback
and exact-job navigation pass focused checks and compilation. Device Maps/URL
behavior gets explicit deferred rows, not assumed simulator proof.

### 8.13 — Customer portal administration UI

**Depends on:** 8.06–8.08; 8.12 for shared-file serialization.
**Requirements:** P1.

**Own:** `N/NativeCustomerPortalView.swift`, customer-detail integration in
`CustomersView.swift`.

Implement saved-customer guard/promotion, create/adopt, email/share, server-first
enable/disable and confirmed rotate; surface authoritative versus local mirror
state. Re-resolve customer after awaits. `already_exists` refreshes/adopts and
does not rotate. Missing raw token shows the explicit recovery path.
Adopt only a display token validated against current server authority; a present
but stale token needs the same recovery handling as a missing one.

**Done when:** derived identity, stale Create, enabled/disabled, foreign/deleted
customer, account switch, double tap, local-save failure and share/composer cancel
are covered. No stale customer-array write or implied global capability revocation.

### 8.14 — Cross-client and hosted-contract qualification

**Depends on:** 8.04–8.13. **Requirements:** all; especially P2 and G1–G4.

**Own:** focused integration fixtures/tests, test harness additions and evidence
in `docs/native-phase-8-contract-decisions.md`; no opportunistic UI rewrite.

Exercise RN→Swift and Swift→RN schedules/settings/conversion/handled mutations;
stale lifecycle push; two-device link operations; timeout after server commit;
owner switching; end-to-end exact schedule publication before reservation release.
Qualify portal assembly/ICS/customer scoping, invoice payment
URLs, approved snapshots, change orders and existing visible-photo publication.
Test real route wrappers in addition to pure cores. Add deterministic competing
database sessions to the runnable concurrency harness.

**Done when:** host/model tests pass, every source-discovered gap has implemented
coverage or a named blocker, and remaining database/staging/hosted-browser proof
is explicitly deferred to Phase 12. External HTML absent is a dependency, not a
passing test. Re-run affected RN oracles after compatibility changes.

### 8.15 — Aggregate verification and evidence closeout

**Depends on:** 8.14.

Register new focused runners in `native/run-all-domain-tests.sh`, verify target
membership, run aggregate and Release build, and record results. Create
`docs/native-phase-8-device-runsheet.md` from the spec checklist; link it into the
consolidated Phase 12 checklist. Update roadmap and parity matrix with completed
code versus deferred evidence, never blanket “Verified”. Record signed and
unsigned build results separately and preserve any unresolved implementation gate.

**Done when:** each requirement has code/test/evidence references; every route and
button is real; no dependency is silently waived; device/staging rows have steps,
expected result, environment/build and evidence placeholders. No deployment or
App Store cutover is part of this task.

## 4. Verification commands

Run from repository root. The following commands exist today; new focused Swift
runners must be created by their task before being invoked. Use only relevant
oracles per task; run full aggregate at integration closeout.

```sh
# Scheduling reference behavior
npm test -- --runInBand --runTestsByPath __tests__/scheduleConfig.test.ts __tests__/scheduleSmarts.test.ts __tests__/calendar.test.ts __tests__/availability.test.ts __tests__/availabilityParity.test.ts __tests__/bookingAvailability.test.js

# Booking lifecycle / intake reference behavior
npm test -- --runInBand --runTestsByPath __tests__/bookingSlotsReserve.test.js __tests__/bookingManage.test.js __tests__/bookingRespond.test.js __tests__/bookingConversion.test.ts __tests__/bookingAttention.test.ts __tests__/bookingRequestsStorage.test.ts

# Portal contracts
npm test -- --runInBand --runTestsByPath __tests__/portalTokensWorkers.test.js __tests__/portalLink.test.ts __tests__/portalAssembleWorkers.test.js __tests__/portalRequestWorkers.test.js __tests__/portalIcsWorkers.test.js __tests__/portalStoreWorkers.test.js __tests__/photoSignWorkers.test.js

# Existing persistence/integration foundations
sh native/run-adapter-tests.sh
sh native/run-store-integration-tests.sh
sh native/run-two-device-convergence-tests.sh

# Integration closeout
sh native/run-all-domain-tests.sh
xcodebuild -project native/TradeReadyNative.xcodeproj -scheme TradeReadyNative -configuration Release -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

For RN edits, run `npm run typecheck` plus affected screen tests. Backend tasks
must supply the exact local database setup/concurrency command and Worker build
command appropriate to the existing package scripts; mocks alone cannot close
transaction invariants. Do not invoke a deploy command to validate a build.

## 5. Reusable subagent prompt

> Implement **task 8.XX only** from `docs/native-phase-8-implementation-plan.md`.
> Read its dependency results and `docs/native-phase-8-calendar-booking-routes-portals-spec.md`
> plus the listed source/tests first. Report missing prerequisites before touching
> dependent code; independent work may continue. Respect the task file ownership
> and existing uncommitted work. Use canonical data and field-scoped current-ID
> mutations; preserve unknown/concurrent server fields. Reuse owner/environment,
> persistence, sync and reviewed-composer boundaries. No business policy in views.
> Add meaningful oracle/failure tests and run focused verification, compiling UI/
> platform changes. Record actual commands/results, not expected passes. Return
> requirement IDs covered, files changed, interface handoff, evidence, unresolved
> blockers and next-ready tasks. Do not edit another task's shared files, invent
> backend guarantees, weaken race tests, commit or deploy.

## 6. Initial execution ledger

All tasks **8.00–8.15 are pending**. The source review used to write this plan is
not test execution or an implementation completion. When work starts, maintain
one row per task: status, owner/session, dependency evidence, files, commands,
actual results, blockers and handoff. Separate **implementation blocked** from
**code complete / Phase 12 evidence deferred**.
