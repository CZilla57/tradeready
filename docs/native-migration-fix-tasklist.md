# Native iOS Migration — Fix / Finish Task List

_Review date: 2026-09-20. Scope: the most recent additions to the SwiftUI native
migration (Phases 6, 7, and 8). This is a working punch-list of gaps found by
code review; it does not replace the phase plans or the roadmap._

## Status at `3d26fad` (reconciled 2026-09-28)

Every open item below was re-checked by reading the code at `3d26fad`. Tracking has
moved to the Phase 12 defect list
([`native-phase-12-cutover-charter.md`](native-phase-12-cutover-charter.md) §10, "New in
Phase 12"), where an open S1 or S2 blocks Stage A entry. The checkboxes below are left as
written on 2026-09-20; this table is the current state.

| Item | State at `3d26fad` | Tracked as |
|---|---|---|
| P0 booking history replay (F1) | Status paths fixed by P12-015 and P12-017; `stampBookingRequestHandled` still queues the whole row | P12-030 (S3) |
| P0 owner lock and job/settings writes (F2) | Fix landed 2026-09-30 (write-fence triggers, lock order), proved on a local PostgreSQL; staging proof owed | P12-025 (S2) |
| P0 authority/replay privileges (F3) | Fix landed 2026-09-30 (working tree), host-proved; staging check owed | P12-023 (S1) |
| (found in the re-check) | Fixed 2026-09-30: the typo, plus `digest` schema and `for update` with `count` that only a real Postgres exposed | P12-024 (S2) |
| P1 8.11 attention reachability (F4) | Superseded: Today shows each attention row with its actions since 10.11; the unused requests view is P12-018 | P12-018, P12-026 |
| P1 8.11 reschedule Resolve (F5) | Superseded by P12-015 (accept after the owner moves the job) | P12-015 (Fixed); P12-033 for the progress indicator |
| P1 8.11 destructive and exception paths (F6) | Deleted-linked-job rows fixed 2026-09-30 (P12-026); progress indicator remains | P12-026 (S2, Fixed), P12-033 (S3) |
| P1 8.12 route view (F7) | Reachable from Today; empty map preview, no full-route action or fallback, runner race remain | P12-032 (S3) |
| P1 unknown-outcome admin replay (F8) | Fixed 2026-09-30 (host tests) | P12-027 (S2) |
| P1 link reconciliation owner recheck (F9) | Open; no reachable leak (RootView teardown) | P12-031 (S3) |
| P1 snapshot-then-queue recovery (F10) | Fixed 2026-09-30 (host tests) | P12-028 (S2) |
| P2 Reconcile dead control (F11) | Open, in the unused requests view | P12-033 with P12-018 |
| Phase 7 simultaneous-offline recurring generation | Accepted permanent limitation 2026-09-30 (charter §9 row 18); P7-25 reconciled | P12-029 (S3, Closed) |
| Phase 6 and 7 verification pending | Device rows in `native-phase-12-evidence-index.md` (P6, P7) | Evidence index |
| Phase 6 scoped-out sub-features | Not defects | — |
| P3 process gates (F12) | Open | P12-034 (S3) |

## Method

- Ran the relevant host test suites for each phase (all listed below **pass**).
- Built the full SwiftUI app target with a generic iOS Debug destination and
  signing disabled (**passes**). This proves compilation, not device behavior.
- Checked every new view for reachability (is it presented/navigated to?).
- Scanned for dead/disabled/placeholder controls (constraint #4: "treat every
  placeholder button as incomplete even when its screen exists").
- Cross-checked built files against the phase plans' task packets.

Phase 8's new gaps are **not limited to UI integration**. The focused suites
compile domain and store logic headlessly, but do not exercise the real SwiftUI
action wiring, a deployed Postgres privilege model, or competing live writers.
The full app build catches view compilation only. "All tests green" ≠ "feature
reachable, race-safe, or deployable."

---

## Phase 8 — Calendar, booking, routes, portals (most gaps)

Test suites run — **12/12 PASS**: schedule, calendar, availability,
calendar-editor, booking-administration, portal-administration,
booking-response, schedule-booking-settings, route-planning,
booking-attention, booking-intake, and store-integration. The generic iOS Debug
app build also passes. None of that closes the live-database, browser, Maps, or
physical-device gates.

### P0 — Release-blocking data integrity / authorization

- [ ] **Owner responses can erase the server-authored booking history they just
  created.** `transition_booking` appends lifecycle history atomically and returns
  only the new status. `AppStore.mergeBookingRequestStatus` then changes that
  status in the pre-response local request and calls `enqueueUpsert` with the
  **entire** request blob. Because that local copy does not contain the history
  appended by the RPC, the next mutation push can overwrite it. The same
  whole-record replay exists in `stampBookingRequestHandled`, despite its
  field-scoped comment. This violates the Phase 8 G2/B3 rule that status and
  `handledAt` repairs must never republish a stale booking-request document.
  **Fix:** do not enqueue whole request blobs after authoritative lifecycle
  responses. Pull/install the authoritative row, or add field-scoped RPCs with a
  revision/`updated_at` predicate for owner status and `handledAt`; add a test
  that server history/unknown fields arriving between read and write survive.

- [ ] **The owner advisory lock does not serialize ordinary job/settings writes,
  so the G1 no-overbooking claim is not established.**
  [`20260920_booking_lifecycle_rpcs.sql`](../supabase/migrations/20260920_booking_lifecycle_rpcs.sql)
  takes `booking_take_lock` before reading jobs/settings, but native/RN sync writes
  those blob tables through ordinary PostgREST upserts that never take that lock.
  A non-participating writer can therefore commit a schedule or availability
  change around the claim snapshot; the statement in
  [`native-phase-8-contract-decisions.md`](native-phase-8-contract-decisions.md)
  that the writer "serializes behind the claim" is false for the implemented
  path. `transition_booking` also takes the request row lock before the owner
  lock, reversing the documented owner-first lock order.
  **Fix:** make every relevant writer participate in one server-side protocol
  (lock-aware/versioned RPC or an equivalent database-enforced fence), acquire
  the owner lock before row locks, and prove competing claim vs. job/settings
  writes against real Postgres. Until then, do not mark the Phase 8 concurrent
  reservation exit criterion complete.

- [ ] **New authority/replay tables have an unsafe and project-age-dependent
  privilege boundary.** The migrations add owner `FOR ALL` RLS policies to
  `booking_link_state`, `booking_operations`, and `portal_operations`, even
  though comments say devices must never access those server-authority tables.
  On projects where Data API grants exist, an authenticated client can directly
  alter its authority/replay rows and bypass the server-first admin contract;
  RLS limits the owner but does not limit the operation. On projects using
  Supabase's newer no-auto-grant behavior, Worker REST reads can instead fail
  because the migrations never explicitly grant the required table access.
  `booking_take_lock` is also left executable by `PUBLIC`, allowing callers to
  hold arbitrary owner advisory locks for a transaction. See Supabase's
  [Data API grant change](https://supabase.com/changelog/45329-breaking-change-tables-not-exposed-to-data-and-graphql-api-automatically).
  **Fix:** explicitly revoke authority/replay table privileges from `anon` and
  `authenticated`, grant only the least privileges required by `service_role`,
  revoke helper-function execution from `PUBLIC`/client roles, and extend the
  verification SQL to assert grants as well as RLS policies.

### P1 — Broken or incomplete user workflows

- [ ] **8.11 attention is visible but still routes nowhere.**
  [`NativeBookingRequestsView.swift`](../native/TradeReadyNative/NativeBookingRequestsView.swift)
  still has no presenter. [`TodayView.swift`](../native/TradeReadyNative/TodayView.swift)
  now shows a booking-attention count, but tapping it opens the root
  `SettingsView`; Settings has no Booking Requests row or destination. Its
  accessibility hint nevertheless promises "Settings → Booking Requests."
  **Fix:** present the request view directly from Today (or add and deep-link to
  a real Settings destination) and add a view-level reachability test.

- [ ] **8.11 reschedule Resolve is wired to an invalid draft and cannot perform
  the required reviewed replacement.** The action supplies nil schedule
  baselines, uses the booking-request status as the job baseline status, and
  writes the request's original immutable slot. Converted booking jobs are
  created as `lead` with that slot already scheduled, so
  `applyScheduleOnly` rejects the draft as a baseline conflict. There is no UI
  for selecting/reviewing a replacement schedule, the busy guard starts only
  after the prepare awaits, and non-success outcomes are silently discarded.
  **Fix:** open a schedule editor pinned to the current linked job, pass its exact
  baseline plus the user-reviewed replacement, mark the row busy before the
  first await, surface every prepare/resolve outcome, and only resolve after the
  exact publication proof succeeds. Capture the owner **before** prepare's sync
  awaits; its current post-await `scheduleBookingOwnerCapture()` comparison can
  never detect an account change during the operation.

- [ ] **8.11 destructive/exception paths do not meet their own done criteria.**
  Decline has no confirmation; unknown/offline/failure outcomes produce no user
  feedback; cancellation says only "Booking was cancelled" without clarifying
  that the linked job was not deleted/rescheduled; and unconverted-active rows
  are displayed without a conversion/recovery action. Deleted-linked-job still
  has the dead Reconcile control listed below.
  **Fix:** add explicit confirmation and truthful recovery states, distinguish
  customer request history from job state, and give every attention kind a
  useful inspected/recovery path.

- [ ] **8.12 now exists, but it is unreachable and its primary map/handoff
  contract is incomplete.** `NativeRouteView.swift` has no external references,
  so Today never presents it. Inside the view, `previewCoordinate` always returns
  nil; a "Complete" preview therefore renders a map with no annotations or
  polylines. The screen exposes only per-stop Apple Maps URLs—there is no
  full-route action even though `fullRouteURL` exists, no exact-job navigation,
  and no Google/copy fallback when `UIApplication.open` completes with failure.
  Each refresh also creates a new `NativeRoutePreviewRunner`, defeating that
  actor's generation-based stale-result suppression; an older lookup can replace
  a newly reordered route.
  **Fix:** add the Today destination; carry resolved coordinates in preview
  output; retain one runner/task and cancel obsolete work; implement exact-job,
  per-stop and full-route handoffs with completion-handler fallback/copy; and
  cover zero/one/many stops, partial lookup, reorder races, and device URL opens.

- [ ] **Unknown-outcome admin mutations cannot actually replay the same
  operation from the UI.** Booking and portal views create a fresh UUID inside
  every button attempt. After a timeout they tell the user to check status, but
  retain neither the operation ID nor a retry action that reuses it. A second
  tap is a new mutation (especially dangerous for rotate), contrary to the
  replay-table contract and the code comments.
  **Fix:** persist owner/action/target-bound pending operation IDs before the
  request, reuse the exact ID after unknown outcome or relaunch, and clear it
  only after a validated replay/status reconciliation.

- [ ] **Read-only link reconciliation can publish stale cross-account UI after
  an await.** `reconcileBookingLinkForSharing` captures neither owner nor display
  state across its status request. `NativeCustomerPortalView.refresh` calls the
  service directly and installs status/share state without re-resolving the
  exact customer or owner. An account switch/removal during the request can
  therefore leave an old owner's verified URL on screen.
  **Fix:** move portal status reconciliation behind an exact-owner store entry
  point, capture owner/customer/token before suspension, and recheck all three
  before publishing status or a share URL.

- [ ] **Snapshot-then-queue commits claim recovery that is not durable.**
  `commitScheduleBookingLocal` passes an empty `stageRecovery` closure. If the
  snapshot save succeeds and the mutation batch enqueue fails, it returns
  success and says recovery was staged, but no replay record was written; a later
  edit is merely hoped to re-enqueue it. Booking intake can therefore create
  local customer/job/request records that never reach the server.
  **Fix:** durably stage the exact owner-bound batch before reporting success,
  replay it idempotently on launch/sync, and test interruption between snapshot
  commit and queue append.

### P2 — Dead / misleading control

- [ ] **Reconcile button is a permanently-disabled TODO.**
  [`NativeBookingRequestsView.swift`](../native/TradeReadyNative/NativeBookingRequestsView.swift) —
  the `.missingJob` case renders `Button("Reconcile") { /* TODO: reconciliation
  flow */ }` with `.disabled(true) // TODO: implement`. This is the only dead
  control in the entire native app. The 8.11 done-criteria require deleted-linked-job
  cases to "behave correctly."
  **Fix:** implement the reconciliation flow, or remove the non-functional button
  so a dead control never ships.

---

## Phase 7 — Invoices, payments, customer communication (solid)

Test suites run — all PASS: invoice-from-job, invoice-editing, invoice-list,
invoice-delivery, invoice-pdf, invoice-notification, recurring-invoice,
bulk-invoice, payment-link, stripe-connect, outreach.

All Phase 7 UI is reachable and wired: invoice list/detail/edit, `PaymentEditor`
with `recordPayment`/`settleInvoice`/`voidPayment`, Stripe Connect + provider
settings (`PaymentsSettings` in Settings), PDF renderer, reviewed outreach + bulk
actions, recurring-invoice generation + rule manager. No dead or placeholder
controls found.

### Known gaps (tracked, not "fix now")

- [ ] **Simultaneous-offline recurring generation diverges from React Native.**
  Documented, test-pinned multi-device limitation
  ([`RecurringInvoiceTests/main.swift:95,110`](../native/RecurringInvoiceTests/main.swift)).
  Slated for the Phase 12 staging exercise. Decide: resolve, or formally accept as
  a permanent parity limitation.
- [ ] **Verification pending.** Phase 7 is "code complete" on host evidence only.
  Physical-device interaction evidence and trusted-staging sync proof remain,
  consolidated into Phase 12 per the 2026-09-16 deferral decision.

---

## Phase 6 — Jobs, estimates, field operations (solid)

Test suites run — all PASS: estimate-delivery, estimate-pdf,
estimate-approval-link, estimate-follow-up, change-order,
change-order-approval-link, job-profitability, job-photo-mutation,
review-request, recurring-job, time-tracking.

All Phase 6 UI is reachable: pricing calculator (`NativePricingCalculatorView`),
estimate review (`NativeEstimateReviewView`), change orders (section, editor,
decision sheet, review), job profitability card, job photos (import/view/delete/
visibility), review requests, and create-invoice-from-job. The previously-hidden
job quick-actions are no longer routing to placeholders — the earlier gating was
resolved once the dependent screens landed.

### Known gaps (tracked, not "fix now")

- [ ] **Verification pending.** Phase 6 is "code complete" on host evidence only
  (focused suites + aggregate + signed generic-iPhone Release build, 2026-09-19).
  Device and end-to-end workflow proof for every Phase 6 slice remain, deferred to
  Phase 12.
- [ ] **Documented sub-features still owned by later phases** (per roadmap
  deliverables): change-order analytics, time-tracking aggregate reporting, job
  photo cross-device convergence proof, and recurring/review analytics. These are
  scoped-out, not defects — listed here only so nothing is assumed done.

---

## P3 — Process gap that let the P1/P2 items slip

- [ ] **Add app-build, reachability, migration-grant, and race gates for Phase
  8+.** The shell suites do not compile SwiftUI views, and even a successful app
  build cannot detect an unwired screen, a blank MapKit preview, unsafe SQL
  grants, or a false concurrency assumption. Add the generic `xcodebuild` to the
  aggregate check plus view-action reachability tests, SQL privilege assertions,
  and real-Postgres competing-session proofs before phase closeout.

---

## Summary

| Phase | Tests | UI reachable | Dead controls | Real remaining work |
|-------|-------|--------------|---------------|---------------------|
| 6 | 11/11 pass | Yes | None | Device verification only |
| 7 | 11/11 pass | Yes | None | Recurring divergence decision; device verification |
| 8 | 12/12 pass + app builds | **No** (8.11/8.12 unwired) | **1** (Reconcile) | Fix P0 history/concurrency/grants; complete request/route/replay/recovery flows |

The actionable "fix now" work is entirely in **Phase 8**, but it now includes
backend correctness and authorization work, not just missing destinations. Fix
the three P0 items before deployment, then finish the 8.11/8.12 workflows and
their recovery paths. Phases 6 and 7 remain code-complete with only Phase-12
device verification and one documented recurring-invoice divergence outstanding.
