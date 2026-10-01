# Native Migration — Fix Implementation Plan

**Created:** 2026-09-21

**Status:** Drafted from code review; no fix tasks implemented yet. F4 and F5 were
superseded by later work (10.11, P12-015); the rest are tracked in the Phase 12 defect
list (charter §10, P12-023 to P12-034) as of 2026-09-28 — see the status table in
`docs/native-migration-fix-tasklist.md`.

**Source punch-list:** [native-migration-fix-tasklist.md](native-migration-fix-tasklist.md)
(review date 2026-09-20).

**Related plans:** [Phase 8 implementation plan](native-phase-8-implementation-plan.md),
[Phase 8 contract decisions](native-phase-8-contract-decisions.md),
[migration roadmap](native-ios-migration-roadmap.md).

## 1. Purpose and scope

The punch-list found that Phase 8 shipped domain/store logic that compiles and
passes focused host tests, but that is **not reachable, not race-safe, and not
deployable**. This plan turns every actionable punch-list item into a bounded,
dependency-ordered task with explicit evidence requirements.

In scope (all Phase 8 punch-list items plus the P3 process gap):

- P0-1 Booking-request history erasure on owner response.
- P0-2 Owner advisory lock does not serialize ordinary job/settings writes.
- P0-3 Authority/replay table privilege boundary and helper-function grants.
- P1-1 8.11 attention is visible but routes nowhere.
- P1-2 8.11 reschedule Resolve uses an invalid draft and cannot perform a
  reviewed replacement.
- P1-3 8.11 destructive/exception paths do not meet done criteria.
- P1-4 8.12 route view unreachable and map/handoff contract incomplete.
- P1-5 Unknown-outcome admin mutations cannot replay the same operation.
- P1-6 Read-only link reconciliation can publish stale cross-account UI.
- P1-7 Snapshot-then-queue commit claims non-durable recovery.
- P2-1 Reconcile dead/disabled TODO control.
- P3-1 Missing app-build, reachability, grant, and race gates.

Out of scope (tracked, not fixed here; see §9):

- Phase 6 device verification, Phase 7 device verification.
- Phase 7 simultaneous-offline recurring-invoice divergence (decision, not fix).
- Phase 6 analytics/reporting sub-features owned by later phases.

This plan does **not** authorize deployment, live migration application, or
contact with production accounts. As with Phase 8, all server work stops at
"ready to apply after an isolated staging project exists" until the owner
provides one.

## 2. Execution contract

Use one bounded task per session; read the punch-list, this plan, and the cited
source before editing. Existing uncommitted migration/backend/native files are
working inputs, not disposable scaffolding. Do not commit, deploy, run live
migrations, or open production accounts unless separately instructed.

`N/` means `native/TradeReadyNative/`.

Every task must:

1. State the punch-list item and requirement IDs it closes (G1/G2/B3/B4/P3 as
   used in the Phase 8 spec).
2. Keep policy in pure Swift modules / injectable services; preserve canonical
   and unknown fields; use the existing owner/environment guards, repository,
   and mutation queue.
3. Re-resolve IDs, merge owned fields only, check async owner/operation identity
   across every suspension, and publish success only after the relevant
   durable/server boundary.
4. Add failing-first fixture/failure tests, run the focused suites, and compile
   when touching UI/platform wiring. Report exact commands and actual results.
5. Return files changed, test counts/results, limitations/blockers, and the
   next-ready task IDs. A blocked task stays blocked; no placeholder action
   counts as done.

### Shared-file ownership (serialize these lanes)

- **Store/integration lane:** all of F1, F4–F11 touch `AppStore.swift`,
  `NativeBookingRequestsView.swift`, `NativeRouteView.swift`,
  `NativeBookingSettingsView.swift`, `NativeCustomerPortalView.swift`,
  `TodayView.swift`, or `SettingsView.swift`. Run these **serially**; never merge
  by overwriting another task's shared-file edits.
- **SQL/backend lane:** F2 and F3 share `supabase/migrations/`,
  `supabase/verify/`, and Worker route registration. Run F3 → F2 serially.
- **Pure/service lane:** the policy-only parts of F1/F10 (`NativeScheduleBookingPolicy`,
  pending-work store) use separate files and may run in parallel, returning
  integration contracts rather than editing shared UI.
- The coordinating agent owns aggregate runner/project membership and document
  updates; a task may propose exact additions, which the coordinator serializes.

## 3. Dependency graph

```text
F0 baseline & guardrail harness
 ├─ F3 authority/replay grants (SQL)        ── F2 reservation protocol (SQL)
 ├─ F1 history-safe status merge            ── F5 reschedule replacement
 ├─ F10 durable stage+replay                ── F6 destructive/exception paths
 ├─ F9 owner/customer/token recheck          ── F8 durable operation IDs
 └─ F4 attention reachability ── F11 reconcile control ── F7 route view
        (F4/F5/F6/F7/F8/F11 share the store+UI lane and run serially)
F1+F2+F3+F4..F11 ── F12 process gates ── closeout
```

Interface dependencies, not strict sequencing. F3 and F2 both change SQL but
touch different statements; run F3 first (deterministic, narrow) so F2's
concurrency proof runs on an already-hardened grant model. F1 must land before
F5/F6 so the response UI merges against a history-safe store entry point.

## 4. Waves

1. **F0** — freeze contracts, add the guardrail harness, characterize current
   behavior in fixtures. No production changes.
2. **SQL lane:** **F3** → **F2** (server protocol; both require isolated staging
   for their exit evidence).
3. **Store-safety lane:** **F1** → **F10** → **F9** (pure policy first, then
   integration onto shared files).
4. **UI lane (serial):** **F4** → **F5** → **F6** → **F8** → **F11** → **F7**.
5. **F12** gates, then closeout. Start characterization/race probes in F0, not
   at closeout.

## 5. P0 task packets (release-blocking)

### F1 — Never republish a stale booking-request document after an authoritative response

**Priority:** P0. **Depends on:** F0. **Requirement refs:** G2, B3, B4.

**Current behavior.** `AppStore.transition_booking` appends lifecycle history
server-side and returns only the new status. `mergeBookingRequestStatus`
(`AppStore.swift`) copies only `status` into the local pre-response row, then
calls `enqueueUpsert(table: "bookingRequests", …, record: merged)` with the whole
row. `stampBookingRequestHandled` does the same for `handledAt`. Because the
local copy lacks the server-appended history, the next mutation push can
overwrite it.

**Approach.**

- Add field-scoped server RPCs (or revision/`updated_at`-predicated writes) for
  owner status and `handledAt`, so a repair can never rewrite lifecycle/unknown
  fields. If a scoped RPC is not feasible, pull/install the authoritative row
  and merge against the fresh server copy before any enqueue.
- Gate the local enqueue on a merged copy that is proven to be server-fresh
  (revision match), not merely a local struct copy.
- Keep `handledAt` and `status` repairs idempotent; no-op when already applied.

**Tests.** Server history/unknown fields that arrive between read and write must
survive a subsequent owner response. Add an end-to-end mutation-push test that
asserts the pushed document retains server-authored history.

**Acceptance.** No code path enqueues a whole booking-request row after an
authoritative lifecycle response unless it is first reconciled against the
server row; fixtures pin both the status and `handledAt` paths.

### F2 — One server-side reservation protocol so G1 no-overbooking holds

**Priority:** P0. **Depends on:** F0, F3. **Requirement refs:** G1.

**Current behavior.** `20260920_booking_lifecycle_rpcs.sql` takes
`booking_take_lock` before reading jobs/settings, but native/RN sync writes those
blob tables through ordinary PostgREST upserts that never take the lock. A
non-participating writer can commit a schedule/availability change around the
claim snapshot. `transition_booking` also takes the request row lock *before*
the owner lock, reversing the documented owner-first order.

**Approach.**

- Make every relevant writer participate in one protocol: a lock-aware/versioned
  RPC (or an equivalent database-enforced fence) that all job/settings blob
  writes must go through when reservation-relevant.
- Acquire the owner lock **before** any row lock in every participating RPC;
  fix `transition_booking` lock order.
- Prove competing claim vs. job/settings writes against **real Postgres** using
  `supabase/verify/booking_lifecycle_concurrency.sh` (currently DEFERRED/M1).
  Record two-session transcripts as evidence.
- Correct the false "serializes behind the claim" statement in
  `native-phase-8-contract-decisions.md` to match the implemented protocol.

**Acceptance.** A competing job/settings write cannot interleave a claim
snapshot; the owner-first lock order is asserted; the Phase 8 concurrent
reservation exit criterion is only marked complete after the staging proof.

**Blocker.** Real-Postgres proof needs an owner-approved isolated staging
project. Do not substitute production.

### F3 — Least-privilege authority/replay tables and helper functions

**Priority:** P0. **Depends on:** F0. **Requirement refs:** G1, B2, P1.

**Current behavior.** `20260921_booking_admin_state.sql` and
`20260922_portal_token_admin.sql` add owner `FOR ALL` RLS policies to
`booking_link_state`, `booking_operations`, and `portal_operations`, even though
devices must never touch those server-authority tables. On projects with Data
API grants, an authenticated client can alter its authority/replay rows and
bypass the server-first admin contract; on no-auto-grant projects, Worker REST
reads can fail because no table access is granted. `booking_take_lock` is left
executable by `PUBLIC`, letting callers hold arbitrary owner advisory locks.

**Approach.**

- Explicitly revoke authority/replay table privileges from `anon` and
  `authenticated`; grant only the least privileges `service_role` needs.
- Replace the owner `FOR ALL` policies with no client-facing policy (these tables
  are server-only).
- Revoke `booking_take_lock` (and any helper) execution from `PUBLIC`/client
  roles; keep `service_role`-only, matching `claim_booking_slot` /
  `transition_booking`.
- Extend `supabase/verify/booking_admin_state.sql` (and the lifecycle verify SQL)
  to assert **grants** as well as RLS policies.

**Acceptance.** Verification SQL fails if any client role can read/write the
authority tables or execute the lock helper; RLS and grant assertions both pass
on an isolated staging project.

## 6. P1 task packets (broken/incomplete workflows)

### F4 — Make 8.11 attention reachable

**Priority:** P1. **Depends on:** F0. **Requirement refs:** B3.

**Current behavior.** `NativeBookingRequestsView` has no presenter. `TodayView`
shows a booking-attention count but tapping it opens the root `SettingsView`,
which has no Booking Requests row; the accessibility hint promises
"Settings → Booking Requests."

**Approach.** Present `NativeBookingRequestsView` directly from Today (as a
sheet or pushed destination), or add a real Settings destination and deep-link
to it. Fix the accessibility hint to match the actual destination.

**Tests.** Add a view-level reachability test asserting the attention control
presents the request view (not Settings).

**Acceptance.** Every booking-attention row kind is reachable from Today with at
least one inspected/recovery path; the hint is truthful.

### F5 — Real reviewed reschedule replacement

**Priority:** P1. **Depends on:** F0, F1, F4. **Requirement refs:** B3, B4, G2.

**Current behavior.** `NativeBookingRequestsView.resolveReschedule` supplies nil
schedule baselines, uses the booking-request status as the job baseline status,
and writes the request's original immutable slot. Converted booking jobs are
created as `lead` with that slot already scheduled, so
`NativeScheduleBookingPolicy.applyScheduleOnly` rejects the draft as a baseline
conflict. There is no UI for selecting/reviewing a replacement schedule, the
busy guard starts only after the prepare awaits, non-success outcomes are
silently discarded, and `scheduleBookingOwnerCapture()` is captured after the
sync awaits so it can never detect an account change.

**Approach.**

- Open a schedule editor pinned to the current linked job; pass the exact
  baseline plus the user-reviewed replacement (never the request's immutable
  slot).
- Mark the row busy **before** the first await; surface every prepare/resolve
  outcome (needsReview/superseded/unknown/missing/failed).
- Resolve only after the exact publication proof succeeds; capture the owner
  **before** prepare's sync awaits.

**Tests.** Baseline-conflict, superseded, unknown-outcome, and owner-change
during the operation. Converted-job (`lead` + scheduled slot) case must succeed
with a reviewed replacement.

**Acceptance.** Resolve performs a reviewed replacement against the exact linked
job baseline and cannot silently discard a non-success outcome.

### F6 — Truthful destructive/exception paths

**Priority:** P1. **Depends on:** F0, F1, F4. **Requirement refs:** B3, B4.

**Current behavior.** Decline has no confirmation; unknown/offline/failure
outcomes produce no user feedback; cancellation says only "Booking was
cancelled" without clarifying the linked job was not deleted/rescheduled; and
unconverted-active rows have no conversion/recovery action.

**Approach.**

- Add explicit decline confirmation.
- Surface unknown/offline/failure outcomes with truthful, non-retrying guidance.
- Distinguish customer request history from job state in cancellation copy.
- Give every attention kind (`unconvertedActive`, `missingJob`, etc.) a useful
  inspected/recovery path; distinguish "customer request history" from "job
  state."

**Tests.** Each outcome maps to a distinct, truthful message; no outcome silently
does nothing.

**Acceptance.** Every destructive/exception path has confirmation or truthful
recovery state; done criteria for 8.11 are met.

### F7 — Wire 8.12 route view and complete its map/handoff contract

**Priority:** P1. **Depends on:** F0, F4 lane. **Requirement refs:** S5.

**Current behavior.** `NativeRouteView` has no external references (Today never
presents it). `previewCoordinate` always returns nil, so a "Complete" preview
renders an empty map. Only per-stop Apple Maps URLs exist: no full-route action
(`fullRouteURL` unused), no exact-job navigation, and no Google/copy fallback
when `UIApplication.open` fails. Each refresh creates a new
`NativeRoutePreviewRunner`, defeating the actor's generation-based stale-result
suppression.

**Approach.**

- Add the Today destination.
- Carry resolved coordinates in preview output so `previewCoordinate` returns
  real values.
- Retain one runner/task and cancel obsolete work on reorder.
- Implement exact-job, per-stop, and full-route handoffs with
  completion-handler fallback + copy.

**Tests.** zero/one/many stops, partial lookup, reorder race (older lookup must
not replace a newer reordered route), device URL-open failure fallback.

**Acceptance.** Route view is reachable; the map shows coordinates/polylines for
a complete preview; every handoff has a fallback; stale results cannot win.

### F8 — Durable pending operation IDs for unknown-outcome admin mutations

**Priority:** P1. **Depends on:** F0. **Requirement refs:** B2, P1, P2.

**Current behavior.** `NativeBookingSettingsView` and `NativeCustomerPortalView`
create `operationId: UUID().uuidString` inside every button attempt. After a
timeout they tell the user to check status but retain neither the operation ID
nor a retry that reuses it; a second tap is a new mutation (especially
dangerous for rotate).

**Approach.**

- Persist owner/action/target-bound pending operation IDs **before** the
  request.
- Reuse the exact ID after unknown outcome or relaunch; clear it only after a
  validated replay/status reconciliation.
- Add a retry action that replays the same operation ID.

**Tests.** Timeout → relaunch → replay uses the same ID; rotate never re-mints a
new capability on retry.

**Acceptance.** Unknown-outcome admin mutations are replayable by exact ID and
never re-issued as a new capability.

### F9 — Exact-owner recheck for link reconciliation publishing

**Priority:** P1. **Depends on:** F0. **Requirement refs:** P1, B2.

**Current behavior.** `reconcileBookingLinkForSharing` captures neither owner nor
display state across its status request. `NativeCustomerPortalView.refresh`
calls the service directly and installs status/share state without re-resolving
the exact customer or owner, so an account switch/removal during the request can
leave an old owner's verified URL on screen.

**Approach.**

- Move portal status reconciliation behind an exact-owner store entry point.
- Capture owner/customer/token before suspension; recheck all three before
  publishing status or a share URL (mirror the `scheduleBookingOwnerCapture`
  pattern).

**Tests.** Account switch/removal during the status request must not publish a
stale URL.

**Acceptance.** No read-only reconciliation path publishes cross-account state
after an await.

### F10 — Durable stage + idempotent replay for snapshot-then-queue

**Priority:** P1. **Depends on:** F0. **Requirement refs:** G2.

**Current behavior.** `commitScheduleBookingLocal` passes an empty `stageRecovery`
closure. If the snapshot save succeeds but the mutation batch enqueue fails, it
returns success and claims recovery was staged, but no replay record is written;
a later edit is merely hoped to re-enqueue it. Booking intake can therefore
create local customer/job/request records that never reach the server.

**Approach.**

- Durably stage the exact owner-bound batch **before** reporting success.
- Replay it idempotently on launch/sync (reuse `NativeScheduleBookingPendingWorkStore`).
- Test interruption between snapshot commit and queue append.

**Tests.** Simulated enqueue failure after snapshot save must yield a durable
pending record that replays to the server.

**Acceptance.** Booking intake cannot claim success for a batch that never
reached the server.

## 7. P2 task packet

### F11 — Remove or implement the Reconcile dead control

**Priority:** P2. **Depends on:** F4, F6. **Requirement refs:** B3.

**Current behavior.** `NativeBookingRequestsView` `.missingJob` renders
`Button("Reconcile") { /* TODO */ }` with `.disabled(true)`. This is the only
dead control in the native app; 8.11 done criteria require deleted-linked-job
cases to behave correctly.

**Approach.** Implement an owner-gated reconciliation/recovery flow, or remove
the non-functional button so a dead control never ships. Prefer removal unless
F6's missing-job recovery path already defines the flow.

**Acceptance.** No permanently-disabled/placeholder control ships.

## 8. P3 task packet — process gates

### F12 — App-build, reachability, grant, and race gates for Phase 8+

**Priority:** P3. **Depends on:** F1–F11. **Requirement refs:** process.

**Current behavior.** Shell suites do not compile SwiftUI views; even a
successful app build cannot detect an unwired screen, a blank MapKit preview,
unsafe SQL grants, or a false concurrency assumption.

**Approach.**

- Add the generic `xcodebuild` (signing disabled) to the aggregate check.
- Add view-action reachability tests (assert the presented destination).
- Add SQL privilege assertions (F3).
- Add real-Postgres competing-session proofs (F2) before phase closeout.

**Acceptance.** The aggregate check fails on an unwired screen, a blank preview,
an over-granted authority table, or an unproven concurrency claim.

## 9. Out of scope (tracked, not fixed)

- **Phase 6 / Phase 7 device + staging verification** — deferred to Phase 12;
  host evidence only.
- **Phase 7 simultaneous-offline recurring-invoice divergence** — decide resolve
  vs. formally accept as a permanent parity limitation; not a fix now.
- **Phase 6 later-phase analytics/reporting sub-features** — scoped-out by the
  roadmap, not defects.

## 10. Traceability (punch-list item → task)

| Punch-list item | Task | Priority |
|-----------------|------|----------|
| Owner responses erase server history | F1 | P0 |
| Owner lock does not serialize job/settings writes | F2 | P0 |
| Authority/replay privilege boundary | F3 | P0 |
| 8.11 attention routes nowhere | F4 | P1 |
| 8.11 reschedule Resolve invalid draft | F5 | P1 |
| 8.11 destructive/exception paths | F6 | P1 |
| 8.12 route view unreachable / map+handoff | F7 | P1 |
| Unknown-outcome admin replay | F8 | P1 |
| Read-only link reconciliation stale publish | F9 | P1 |
| Snapshot-then-queue non-durable recovery | F10 | P1 |
| Reconcile dead control | F11 | P2 |
| App-build/reachability/grant/race gates | F12 | P3 |

## 11. Evidence boundaries

Host suites, focused fixtures, and a generic Release build prove compilation and
domain logic — never physical-device behavior, a deployed Postgres privilege
model, browser/Maps handoffs, or competing live writers. F2 and F3 close only
with isolated-staging SQL evidence; F4–F11 close with host tests plus the app
build, but their device interaction proof remains part of the Phase 12 exit
gate. Do not mark any task done from tests alone when its acceptance names a
server, device, or browser boundary.
