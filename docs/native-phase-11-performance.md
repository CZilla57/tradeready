# Native Phase 11 — performance, launch time and soak protocol (task 11.12)

**Status (2026-09-24):** definitions and host evidence only. This document defines
what Phase 12 measures on devices, how, and who owns each measurement. **No device
number is claimed here**, and no threshold is set here (see [Thresholds](#thresholds)).
Requirements H3 (poor network, memory, battery) and H4 (performance profiling and
launch time) in [the Phase 11 plan](native-phase-11-implementation-plan.md) §11.12.
Device rows follow the roadmap verification deferral (2026-09-16) and the contract's
§13 device matrix.

## 1. What exists now

### 1.1 Signposts (`N/NativePerformanceMetrics.swift`)

Eight `os_signpost` intervals through `OSSignposter`, subsystem
`com.tradeready.native`, category Points of Interest. They show in the Instruments
App Launch, Points of Interest, os_signpost and Time Profiler tracks, in Debug and
in Release. Release builds with `DEBUG_INFORMATION_FORMAT = dwarf-with-dsym`
(checked with `xcodebuild -showBuildSettings`), so a Release trace symbolicates.

| Interval | Begins | Ends | Metadata |
|---|---|---|---|
| `Launch` | first line of `TradeReadyNativeApp.init` | the root view's first `onAppear` (once per process); for a background-only cold launch, the start of `performBackgroundRefresh` instead | `outcome=completed`; `outcome=skipped` for a background-only launch (not a launch-time sample) |
| `SnapshotLoad` | before `AppStore.load(seedIfMissing:)` in `AppStore.init` | after it | record count; `failed` when the snapshot was unreadable |
| `LegacyMigration` | around `LegacyMigrationCoordinator.migrate` at launch (only when it runs) | same call | `completed`, or `failed` when it throws |
| `InitialSync` | the initial-sync gate starts the first full pull | the atomic commit | record count; `failed` on a thrown pull or commit; `skipped` when a stale account or generation drops the pass |
| `DeltaPull` | each `pullDeltaIfPossible` (coordinator pull and the booking/portal recovery calls) | after the commit | record count; the pull result's state (`completed`, `partial`, `failed`, `skipped`) |
| `BackgroundRefresh` | `performBackgroundRefresh` (one `BGAppRefreshTask` pass) | its result | `completed`, `skipped` or `failed` |
| `JobListProjection` | the Jobs list filter/sort/stats projection (`NativeJobList.state`) | same call | visible row count |
| `InvoiceListProjection` | the Invoices list filter/sort | same call | visible row count |

Rules the host suite enforces (`native/PerformanceMetricsTests/main.swift`):

- **Privacy (contract §10.1).** An interval name is a compile-time `StaticString`. The
  only metadata is `count=<0…999999999>` and/or `outcome=<word>`, rendered by one
  function. No API takes a string, so no customer data, id, email, token or key can
  reach a signpost. The OS message is marked `.public` only for that rendered string.
- **Nothing is sent.** Signposts stay in the unified log for a developer's
  Instruments session. There is no analytics, Sentry or MetricKit upload hook.
- **Non-invasive.** Calls are synchronous, never suspend and never trap. No call site
  adds an `await` or reorders work. `DeltaPull` and `BackgroundRefresh` wrap the
  bodies (`pullDeltaAndCommit`, `runBackgroundRefresh`) without changing them (the
  later Finding D fix changed only `pullDeltaAndCommit`'s commit). With no recorder
  attached, `OSSignposter.isEnabled` is false and a call costs one flag read.
- **Pinned inventory.** No other `N/` file touches `OSSignposter` or the sink types,
  and the ten call sites are an exact list, so a new interval is a deliberate test
  edit.

Known signpost gaps (review M6, recorded):

- **`JobListProjection` fires several times per render.** `JobsView.listState` is
  read more than once per body, so one render records several intervals. PERF-8
  reads their durations; a count of intervals is not a count of renders.
- **Background-only cold launch (fixed in fix round 2).** A process launched only
  for a background refresh never shows the root view, so `Launch` stayed open.
  `performBackgroundRefresh` now ends it as `skipped` (a no-op after a foreground
  launch). PERF-1 and PERF-2 read only `outcome=completed` launches.

### 1.2 Poor-network host suite (`native/PoorNetworkTests/main.swift`)

The suite drives the real `NativeSyncCoordinator`, the real durable
`NativeMutationQueue` that `AppStore` writes on every edit, the real push transport,
the real delta pull and the real `AppStore` pull commit. The only fake is the network:
the shared in-memory server (`native/HostTestSupport/InMemorySupabase.swift`, the
two-device convergence model) behind a `PoorNetworkLink`. The link is the
coordinator's reachability and both HTTP loaders. It can be offline, throttle (429 or
503), time out before or after the server commits, drop after N requests, throttle one
table, or report optimistic reachability over a dead link. It also models PostgREST's
primary-key conflict for a plain insert.

| Scenario | Proven on the host |
|---|---|
| A. Offline → online | Offline triggers send nothing and leave the queue file byte-identical. Offline is not counted as a failure. Reconnecting drains the queue once, in queue order, including a last-writer-wins re-edit. The pull runs only after every write. Later passes and triggers coalesced during an in-flight pass never re-send. |
| B. Throttled / timed out | A 429 gives a typed `.partial` and the bounded `http-response/jobs/429` code, with one attempt per change, nothing committed, no pull and exponential backoff — the harness's 30 s test base, doubling (`native/PoorNetworkTests/main.swift:225`); the app's real default is a 5 s base doubling to a 300 s cap (`N/NativeSyncCoordinator.swift:140-141,388`). *2026-09-26 (Phase 12 ruling R19):* "no pull" no longer holds: since 12.00b.1 a push pass that reaches per-item results pulls afterward, so a throttled pass also pulls (and its reads are throttled too), and scenario B now asserts it (`native/PoorNetworkTests/main.swift:540`; contract §17.2, I2). A throttled pass sends N push requests plus at least 12 pull reads (`docs/native-phase-12-monitoring.md` §5). A timeout before the server gives `transport/jobs` and no commit. A timeout **after** the server committed keeps and replays the change, and the idempotent upsert leaves one server row and one local record. |
| C. Mid-pass drop | A pull drop after the jobs page commits jobs and advances their cursor. The dropped tables keep their committed records and cursors, and the pull is `.partial` with a bounded code. A dead link behind optimistic reachability leaves the snapshot and cursor unchanged. One throttled table is `.partial` with its own code and keeps its record and cursor. A push drop keeps exactly the unacknowledged remainder in order. Reconnecting recovers each case without re-sending acknowledged changes. |
| D. Edit during a pull (coordinator) | An edit saved while the pull waits on the network is kept in memory and on disk and stays queued, while a remote change to another record still applies. After a drop and reconnect the server gets the edit. |
| E. Edit during a pull (direct caller) | Through the booking/portal-recovery entry point, a change queued before the pull and one made during it are both kept and both stay queued, and server changes to other records apply. |
| F. Same record changed on both sides | The local pending edit wins in memory and on disk until it is pushed, and then the server, memory and disk agree. |
| G. Push acknowledged during a direct pull | A change queued when a booking/portal-recovery pull starts is pushed by the coordinator while that pull is in flight, and the pull's page (read before the push) carries the older server row. The commit keeps the pushed edit on screen and on disk, keeps the jobs watermark so the row is fetched again, and still applies another job's server change. After a follow-up edit and reconnect, the server keeps the edit. |

`DeltaPull` signposts from these passes are checked for pairing and for
count-and-outcome-only metadata. Five mutations of production code were each caught
(the 11.12 entry in the plan's §7 lists them).

**Finding D (fixed in `36a08dc`, 11.12 fix round 1; hardened in `22f35fd`, fix round 2).** An edit saved while a delta pull
was waiting on the network was reverted, in memory and on disk, when that pull
committed, because the pull merged into the snapshot captured before its await. If the
link dropped before the rerun pushed the edit, a second edit to the same record replaced
the queued first one, which was lost. The pull commit now rebases the pulled delta onto
the live snapshot and takes the server's version only for records this device has not
touched: not pending at the pull's start or at commit, and unchanged locally since the
pull's base. Where it keeps a local record over a fetched server row, that table's
watermark stays put so the next pull fetches the row again (fix round 2 added the
pull-start and locally-changed rules for review finding I1). Scenarios D to G above and
table-driven cases of the merge rule prove it and run by default. SOAK-3 on device should still
include an edit made during a slow pull.

## 2. Environments

| Environment | Use |
|---|---|
| Build | Release configuration, signed, the TestFlight build of the stage (12.04 records the build number). Signposts need no special build. Never use a Debug build for timing. |
| Devices (contract §13) | iPhone SE-class on iOS 17.x (floor); a standard iPhone on iOS 18.x; iPhone 16 Pro Max on iOS 27.0 (the existing row in `docs/native-phase-3-device-matrix.md`); iPad 11-inch and iPad mini on iPadOS 27. Launch timing uses the SE-class device (slowest) and the Pro Max. |
| Backend | The trusted isolated staging environment only (Phase 12 12.03 records whether it exists; never substituted, never production). Synthetic team accounts only (Stage A). |
| Data tiers | **Empty** (new account). **Typical** (synthetic history of a small trade business). **Large**: at least four pull pages (page size 500) in jobs and invoices, so at least 2,000 each, plus at least 1,000 customers, with photos on a subset. These tiers are test fixtures, not thresholds. |
| Network | Wi-Fi; Network Link Conditioner (device Settings › Developer) profiles "3G", "Very Bad Network" and "100% Loss"; airplane mode. |
| Power | Charged above 50 %, not charging, for battery rows; Low Power Mode on or off as the row states; thermal state nominal at the start. |

## 3. Measurements

Record every run in the Phase 12 evidence index (build, device, OS, data tier, run
count, median, max, and the trace file name). Five runs per cell unless a row says
otherwise.

| ID | Measurement | Steps | Record | Phase 12 owner |
|---|---|---|---|---|
| PERF-1 | Cold launch | Reboot or force-quit and wait 60 s. Profile with Instruments › App Launch (or `xcrun xctrace record --template 'App Launch'`). One launch per trace, per data tier. | App Launch time to first frame; the `Launch`, `SnapshotLoad` and (first run after upgrade) `LegacyMigration` intervals | **12.04** (captures); 12.00 (threshold) |
| PERF-2 | Warm launch | Launch, background, force-quit from the switcher, relaunch within 10 s. Same template. | Same as PERF-1 | **12.04** |
| PERF-3 | `XCTApplicationLaunchMetric` | Only if a UI-test target exists. None does: `native/TradeReadyNativeTests` is a unit-test bundle, and 11.12 adds no target. Adding one is a Phase 12 decision. | `measure(metrics: [XCTApplicationLaunchMetric()])` results, if added | **12.02** (decide and add); 12.04 (run) |
| PERF-4 | Field launch, hangs, memory, disk writes, battery | Xcode Organizer (Launch Time, Hang Rate, Memory, Disk Writes, Battery, Terminations) and the MetricKit aggregates Apple collects from TestFlight users who share analytics. The app adds no MetricKit subscriber (nothing is sent). | Organizer percentiles per build, and "insufficient data" where the cohort is too small | **12.02** (source); **12.05** (Stage B read); 12.07 (production watch) |
| PERF-5 | Migration timing | During the 12.04 upgrade (Expo build → native, no delete), profile the first native launch. | `LegacyMigration` and `SnapshotLoad` durations and counts; migration outcome | **12.04** |
| PERF-6 | Initial sync timing | Sign in on a fresh install for each data tier. | `InitialSync` duration, outcome and count | **12.04** |
| PERF-7 | Delta pull and sync error rate | Foreground and manual sync on typical and large tiers; the SOAK rows below. | `DeltaPull` durations and the outcome mix; the Cloud Sync status diagnostic codes | **12.02** (monitored signal: sync errors and pending-queue growth); **12.04** (baseline) |
| PERF-8 | List rendering | Large tier: scroll Jobs and Invoices top to bottom, type a search, switch every filter. Use Instruments Time Profiler plus Hangs (and the SwiftUI template where the Xcode version provides it). | `JobListProjection` and `InvoiceListProjection` durations (several `JobListProjection` intervals per render; see the gaps above); hitches or hangs | **12.04** |
| PERF-9 | Crash-free sessions | From Sentry (11.09) once a release DSN is supplied. | Crash-free session rate per build | **12.02** (source); 12.04 / 12.05 (read) |
| PERF-10 | Expo reference (optional) | On the same device, before the 12.04 upgrade, run PERF-1 and PERF-2 on the installed App Store Expo build. | App Launch time to first frame | **12.04**. A reference only, never a threshold (see [Thresholds](#thresholds)) |

## 4. Soak protocol

| ID | Soak | Steps | Pass evidence | Phase 12 owner |
|---|---|---|---|---|
| SOAK-1 | Background refresh under throttling | Typical tier, 5 queued edits, "Very Bad Network". Background the app. Trigger `com.gettradereadyapp.tradeready.sync-refresh` from the debugger (`BGTaskScheduler` `_simulateLaunchForTaskWithIdentifier:`), then let iOS schedule it naturally for 2 h. Repeat once with "100% Loss". | `BackgroundRefresh` intervals and outcomes; each task completed exactly once (expiration included); server rows = local records (no duplicates); pending count reaches 0 after the network recovers. Cross-check the rows in `docs/native-phase-4-background-refresh.md`. | **12.03** (index row); **12.04** (run) |
| SOAK-2 | Large collections | Large tier, 30 min: scroll lists, search, open and save editors, open job photos, pull to refresh. Profile with Allocations and Leaks. | Memory high-water and growth across repeated passes (no unbounded growth); no leaks attributed to `N/` types; PERF-8 values; no jetsam | **12.04** |
| SOAK-3 | Offline → online (with a mid-pass drop) | Airplane mode. Make 10 edits across jobs, invoices, customers and expenses, including a re-edit and a delete. Force-quit, relaunch offline, check the pending count, reconnect. Repeat, switching "100% Loss" on 1 s into a sync. | Each change on the server once, in order; no local record lost or duplicated; the Cloud Sync page moves offline → syncing → synced, or shows a bounded code and then recovers. This is the device counterpart of scenarios A and C. | **12.04**; **12.05** (offline-heavy cohort) |
| SOAK-4 | Low Power Mode | Low Power Mode on, typical tier, 60 min of mixed use plus 2 h idle in the background. | Foreground sync still works; background refresh deferral is recorded (not a failure); Instruments Energy/Power profile shows no busy loop while idle; battery % over the window | **12.04** |
| SOAK-5 | Stage Manager `onGeometryChange` thrash (11.11 IPAD-MT-3) | iPad in Stage Manager. Drag a Jobs window and a Settings scroll window slowly across 690–760 pt for 60 s, then stop. Profile with Time Profiler (and the SwiftUI template where available). | CPU returns to idle once the drag stops (no sustained layout work, so no layout loop); the column engages without a jump; record any one-frame shift (IPAD-MT-3 M6) | **12.03** (index row); **12.04** (team iPad); 12.05 (iPad cohort) |
| SOAK-6 | Long session memory and lifecycle | Typical tier, 60 min with 20 background/foreground cycles, a sign-out and sign-in, and widget refreshes. | Memory footprint stays level across cycles; no crash; Organizer terminations for the build (PERF-4) | **12.04**; 12.05 |

A soak row passes only on a physical device with the stage's build. The host suite
does not close any soak row.

## Thresholds

This document sets **no numeric threshold**. Phase 12.00 owns them in the cutover
charter (`docs/native-phase-12-cutover-charter.md`, created by 12.00), and 12.02 wires
each one to a monitored source.

**Ruling (controller, 11.12): thresholds are Phase 12.00's absolute targets.** The
Phase 11 plan (§11.12 step 4) said 12.00 would set provisional thresholds "from the
current Expo app's production metrics". There are no production users, so no Expo
production baseline exists, and 12.00 step 2's absolute targets govern. Stage A's
native baselines (12.04 step 5, the measurements above) refine those targets, and the
owner re-ratifies them before Stage B. PERF-10 gives only a same-device Expo launch
reference from one team device; it is never a threshold.

## Phase 12 owner summary

| Owner | Measurements |
|---|---|
| 12.00 | Thresholds for launch, migration, sync errors and crash-free sessions (absolute targets; see above) |
| 12.02 | Sources and alerts for PERF-4, PERF-7 and PERF-9; the PERF-3 UI-test-target decision |
| 12.03 | Evidence-index rows for every PERF and SOAK ID here (Stage A or B eligibility); SOAK-1 and SOAK-5 index rows |
| 12.04 | PERF-1, 2, 5, 6, 7, 8 and 10; SOAK-1 to 6 on team devices; hands the baselines to the owner |
| 12.05 | PERF-4 field data; SOAK-3, SOAK-5 and SOAK-6 in the cohort |
| 12.07 | PERF-4 production watch during the phased release |

## Host commands

```sh
TZ=America/Phoenix sh native/run-performance-metrics-tests.sh
TZ=America/Phoenix sh native/run-poor-network-tests.sh
```

Both runners are registered in `native/run-all-domain-tests.sh`.
