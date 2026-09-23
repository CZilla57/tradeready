# Native Phase 4 Background Refresh

Updated: 2026-09-13

Status: implementation and host verification complete; physical-device task
launch, expiration, and convergence evidence remains required.

## Implemented contract

- Registers `com.gettradereadyapp.tradeready.sync-refresh` before application
  launch finishes and declares both the permitted identifier and `fetch`
  background mode in the app plist.
- Submits an idempotent `BGAppRefreshTaskRequest` whenever the app enters the
  background and again at the start of every delivered task. Its 30-minute
  interval is an earliest eligible time, never a promise that iOS will launch
  at that cadence.
- Runs the same serialized push-then-delta-pull coordinator as foreground sync,
  so durable queue retention, backoff, server-subject verification, cursor
  commits, and account-generation invalidation are unchanged.
- Lets signed-out, offline, or otherwise ineligible wakes finish as safe
  best-effort no-ops. Offline mutation records remain on disk for foreground or
  a later scheduled retry.
- On a cold background launch, attaches credentials only after the saved
  Supabase session passes the existing live verification/refresh path and its
  derived binding exactly matches a completed local onboarding workspace. It
  does not advance onboarding, subscription, or other foreground routing.
- Runs exact-owner job-photo upload/backfill after metadata sync, publishes any
  confirmed `uploadedAt` mutation, then performs widget/Siri replay. The same
  source-preserving and account-invalidation rules apply when iOS expires work.
- Installs an expiration handler that cancels the structured Swift task and
  reports completion exactly once. Logs contain only bounded stage names, not
  task errors, identifiers, URLs, credentials, or record data.

## Automated evidence

Run:

```sh
native/run-background-refresh-tests.sh
native/run-all-domain-tests.sh
```

The focused host suite covers the stable identifier, 30-minute request policy,
exact-binding and completed-workspace gates, successful/skipped/failed result
mapping, and cancellation with exactly-once completion. The aggregate runner
includes it. A generic-iPhone unsigned build verifies the concrete
`BackgroundTasks` adapter and processed plist.

## Required physical-device evidence

Do not mark background refresh verified until all of these are recorded on a
physical iPhone with Background App Refresh enabled:

Run `native/run-phase-4-device-preflight.sh` first and record results in
`native-phase-4-device-runsheet.md`.

- A delivered refresh for a completed signed-in workspace pushes a queued
  local edit and pulls a second client's remote edit without duplication.
- Airplane mode leaves the queue and canonical snapshot intact; a later
  foreground or delivered refresh converges after connectivity returns.
- A signed-out cold launch completes without exposing or mutating a prior
  workspace.
- A task expired during a delayed request completes unsuccessfully exactly once
  and retains unacknowledged queue/cursor state for retry.
- Switching or signing out during an in-flight pass cannot apply, replay, or
  acknowledge work under the new account.
- The system may defer a scheduled request beyond 30 minutes; that is expected
  behavior and not a failure by itself.

Job-photo transfer implementation is documented in
`native-phase-4-job-photo-transfer.md`; physical-device photo and mixed React
Native/Swift interruption evidence remain separate Phase 4 gates.
