# Phase 11 — Subagent Implementation Plan

**Date:** 2026-09-21

**Status:** 11.00 contract frozen (2026-09-23); implementation tasks 11.01–11.15 pending. See §7.
Revised 2026-09-22 per [native-phase-10-12-plan-review.md](native-phase-10-12-plan-review.md).

**Phase entry dependency:** Phase 10 closeout (10.15) for 11.08 and 11.10a, and
10.01 (`NativeBusinessSnapshot` / `PaymentLedger` rollup) for 11.01 step 3. The
accessibility audit must run against the rewritten `TodayView`/`CoachView`
(10.11–10.13), 11.08 instruments the `insight_*` events 10.12 emits through its
no-op seam, and the widget's `outstandingTotal` must reuse 10.01's rollup rather
than fork the math. The widget mirror plugs into 10.09's post-sync-commit seam.

**Upgrade identity:** there are no current users, so the native widget
extension, widget `kind` strings, intent type names, and shortcut phrases are
**not** required to match the RN build. Choose them for correctness and
clarity (review finding 11-1 intentionally not applied).

**Roadmap goal (Phase 11):** Complete platform integration and operational visibility.

**Scope source:** [native-ios-migration-roadmap.md](native-ios-migration-roadmap.md)
Phase 11 (Deliverables and Exit criteria) plus the parity rows in
[native-parity-matrix.md](native-parity-matrix.md) "Platform and operations"
(WidgetKit, App Intents/Siri, Deep links, Analytics, Crash reporting,
Accessibility, Release migration) and the "Today and planning" / "Coach" rows
whose events the analytics catalog mirrors. Design sources:
[widget-plan.md](widget-plan.md), `utils/widgetBridge.ts`, `utils/widgetActions.ts`,
`targets/widget/` (`Widgets.swift`, `JobTimer.swift`, `_shared/SiriIntents.swift`),
`utils/analytics.ts`, `utils/deepLinks.ts`, and `App.tsx` (Sentry/PostHog init).

**Carried in from Phase 10 (final review I4, 2026-09-23):** the parity-matrix
"Settings › AI Assistant" row assigns Phase 11 the missing native UI for RN's
"Advanced" Groq/Anthropic key entry (`SettingsAIScreen`). Before execution,
add an 11.xx task for it (secure field, Keychain storage, redaction per
11.00), or record a dated cutover waiver in 12.00. Do not leave it unowned.
**Owned by 11.15** (added 2026-09-23 at SDD start).

## 1. Execution contract

Use one bounded task per subagent session. Read this plan, the roadmap Phase 11
section, the parity rows above, and the listed source/tests before editing.
Existing uncommitted migration/backend files are working inputs, not disposable
scaffolding. Do not commit, deploy, submit to App Store Connect, or contact
production accounts unless separately instructed.

`N/` means `native/TradeReadyNative/`. Proposed filenames below do not imply files
already exist. Match the existing host-test runners (`native/run-*.sh`) and Xcode
source inclusion rather than introducing another build system. Adding the
widget/app-intent target is a deliberate Xcode-project change owned by 11.01; it
must not be faked with a plain group or a second package.

**Third-party SDKs:** Swift Package Manager dependencies are permitted for the
Sentry Cocoa SDK and the PostHog iOS SDK, following the existing SPM precedent
(RevenueCat, GoogleSignIn in `project.pbxproj`). Because the `native/run-*.sh`
host runners cannot import these SDKs, the event catalog, property schema, and
redaction policy live in Foundation-only files, and each SDK sits behind a small
protocol adapter that host tests replace with a fake.

Every implementation task must:

1. State satisfied dependencies and the requirement IDs it implements.
2. Keep policy in pure Swift modules and services injectable. No widget snapshot
   projection, event catalog, or redaction policy in a view.
3. Preserve the exact-owner/workspace boundary across every extension and cold
   launch: an extension runs in a separate process and cannot trust app state.
4. Add meaningful fixture/failure tests, run focused checks, and compile when
   touching UI/platform wiring. Report exact commands and actual results.
5. Return files changed, test counts/results, limitations/blockers, and
   next-ready task IDs. A blocked task stays blocked; no placeholder action
   counts as done.

Physical-device verification is deferred per the roadmap's
[2026-09-16 verification-deferral decision](native-ios-migration-roadmap.md)
(Phase 12 owns device, TestFlight, and store evidence). Phase 11 must *produce*
the runsheet rows and the code, and must not claim them as passed. WidgetKit,
App Intents, and extension targets cannot be fully validated in a generic
simulator build; that limitation is recorded, not waived.

### Requirement IDs

- **W1** Native WidgetKit target and the App Group snapshot contract (shared
  schema, app-side projection writer, timeline reload).
- **W2** Next Job widget (small + medium) with its deep link.
- **W3** Job Timer widget (interactive iOS 17+, read-only fallback) driven by the
  action queue.
- **W4** Widget correctness across sign-in changes and stale data (owner gating,
  scrub, stale-snapshot handling).
- **A1** App Intents/Siri: on-my-way.
- **A2** App Intents/Siri job actions — the full RN inventory: Next Job
  (read-only), Start Trip / Stop Trip (the `activeTrip` private session that
  ends in a `trip_log` action), Clock In / Clock Out, Log Expense, Outstanding
  ("how much am I owed", read-only), plus the widget's Start Timer / Stop Timer
  button intents (10 intents including On My Way).
- **A3** Intent action-queue contract: append pending actions under the shared
  lock, replay through the normal save paths, never write canonical data directly
  from the extension.
- **L1** Complete cold and warm deep-link routing with authentication gates.
- **L2** Fail-closed routing to the exact native record after sign-in changes.
- **P1** Analytics transport with build/config gating.
- **P2** Event parity: identical RN event names and properties.
- **P3** User-identification lifecycle (identify on sign-in, reset on sign-out,
  account switch, and deletion).
- **P4** Privacy controls: no secure keys or unintended customer data in events,
  breadcrumbs, or diagnostics.
- **R1** Crash/error reporting lifecycle with release symbols.
- **R2** Secret and customer-data redaction before upload.
- **R3** Non-`Error`/plain-object error reporting parity.
- **H1** Accessibility audit and remediation (VoiceOver, Dynamic Type, contrast,
  Reduce Motion, touch targets, keyboard navigation, switch control).
- **M1** Privacy manifests (`PrivacyInfo.xcprivacy`) for the app and the widget
  extension: required-reason API declarations (e.g. `UserDefaults` for the App
  Group suite, file timestamps) and collected-data types.
- **H2** iPad layouts, multitasking, rotation.
- **H3** Memory, battery, and poor-network behavior.
- **H4** Performance profiling and launch-time measurement.

### Shared-file ownership

- **Widget/extension lane:** 11.01–11.04 share the `N/Widgets/` extension target,
  the App Group shared-source files, `N/TradeReadyNative.entitlements`,
  `native/Info.plist`, and `native/TradeReadyNative.xcodeproj/project.pbxproj`. Run
  serially; only 11.01 edits the project file/target definition.
- **Intent ownership:** every `AppIntent` type is defined exactly once, by 11.04.
  Intents a widget invokes (Start Timer / Stop Timer) live in
  `N/Widgets/Shared/WidgetIntents.swift`, which 11.01 adds to **both** targets'
  membership (mirroring RN's `_shared/`). Siri-only intents live in the new
  `N/Intents/` (app target). `AppShortcutsProvider` lives in the app target only.
  11.03 consumes the timer intents; it does not define them.
- **App-target lane:** 11.05–11.09 share `N/TradeReadyNativeApp.swift`,
  `N/AppStore.swift`, `N/BuildEnvironment.swift`, and `N/RootView.swift`. Run
  serially even though their policy modules are independent.
- **Pure/service lane:** the snapshot projection, action planner, event catalog,
  and redaction policy live in separate Foundation-only files and can run in
  parallel. They return integration contracts; they do not edit the shared files
  above.
- The coordinating agent owns aggregate runner/project membership and document
  updates. Separate worktrees are preferred for concurrent writers; never merge
  by overwriting another task's shared-file edits.

### Existing code this phase builds on (do not duplicate)

- **App Group and replay foundations already exist:** `N/NativeAppGroupInbox.swift`
  (read-only inbox + `NativeAppGroupAccountScrubber` under the advisory lock),
  `N/NativeWidgetActionReplay.swift` (strict, loss-preserving planner for
  `timer_start`/`timer_stop`/`trip_log`/`expense_log` batches), and
  `N/NativeDeepLinkParser.swift` (`tradeready://job/<id>`,
  `tradeready://onmyway/<id>`, and the five-minute `pendingOpenUrl` freshness
  window).
- **Routing/gating already exist:** `N/AppStore.swift` (`handle(url:)`,
  `routeToOnMyWay`, `deepLinkedJobID`/`CustomerID`/`InvoiceID`/`OutreachInvoiceID`,
  `consumeOutreachDeepLink`), `N/RootView.swift` (auth/onboarding/subscription
  gate), `N/NativeAuthenticatedIdentity.swift`, `N/NativeTypedAccountState.swift`,
  `N/NativeSubscription.swift`.
- **Entitlements/config already exist:** `N/TradeReadyNative.entitlements` has the
  App Group; `native/Info.plist` registers the `tradeready` URL scheme,
  `BGTaskSchedulerPermittedIdentifiers`, and `UIBackgroundModes`; the app target is
  already `TARGETED_DEVICE_FAMILY = "1,2"` and iOS 17.0.
- **RN reference contracts:** `targets/widget/Widgets.swift` (the `BridgeSnapshot`
  schema and the `widgetSnapshot` key the native app must reproduce),
  `targets/widget/JobTimer.swift`, `targets/widget/_shared/SiriIntents.swift`
  (RN compiles `_shared/` into **both** the app and the widget extension;
  `AppShortcutsProvider` itself must live in the main app per Apple DTS),
  `modules/widget-bridge/ios/WidgetBridgeModule.swift`, `utils/widgetBridge.ts`,
  `utils/widgetActions.ts`, `docs/widget-plan.md`.

Known gaps the app-target lane must close (found in source review):

- There is **no native app-side widget snapshot writer**. The native app only
  scrubs the suite (`NativeAppGroupAccountScrubber`); it never mirrors
  `widgetSnapshot`, so a native WidgetKit target would read nothing. The RN JS
  bridge currently owns that write and must be replaced.
- There is **no WidgetKit target or App Intents** in the native Xcode project
  (only `TradeReadyNative` and `TradeReadyNativeTests`).
- There is **no analytics, no crash reporting, and no privacy manifest**
  (grep: none under `N/`; no `PrivacyInfo.xcprivacy`).
- Deep links route, but cold-launch gating through the full
  auth/onboarding/subscription state machine is not proven, and warm/cold
  behavior after a sign-in change is untested.
- Accessibility is ad hoc (`accessibilityLabel` on some components); there is no
  audit, no Dynamic Type/contrast/motion/touch-target pass, and no
  keyboard/switch-control work.

## 2. Dependency graph and waves

```text
11.00 contract freeze + baselines (snapshot, action queue, intents, event catalog, redaction, a11y, SDKs)
 |- 11.01 widget foundation + extension manifest (W1, M1) [needs 10.01, 10.09 seam]
 |    |- 11.04 App Intents + queue, all intent types (A1-A3)
 |    |    |- 11.03 Job Timer widget (W3)
 |    |- 11.02 Next Job widget (W2)
 |    11.01-11.04 -- 11.05 owner/stale/sign-in (W4)
 |                     |- 11.06 deep-link routing + auth gates (L1,L2)
 |- 11.07 analytics transport + privacy (P1,P4)
 |    |- 11.08 event parity + identity lifecycle (P2,P3) [needs Phase 10 closeout]
 |    |- 11.09 crash reporting + redaction + app manifest (R1-R3, M1)
 |         |- 11.15 Settings AI advanced key entry (P4, R2)
 |- 11.10a accessibility audit + fixes (H1) [needs Phase 10 closeout]
 |    |- 11.11 iPad layouts + multitasking (H2)
 |         |- 11.12 performance + network host tests + soak protocol (H3,H4)
 |              |- 11.10b accessibility re-audit (H1)
11.01-11.12 (incl. 11.10b, 11.15) -- 11.13 qualification -- 11.14 closeout
```

The diagram expresses interface dependencies, not a requirement to wait for every
pure module before useful integration. 11.02 can build against the frozen
snapshot schema from 11.00 while 11.01 finishes the target wiring. 11.06 needs
only the 11.05 owner-gate API, not all of 11.05's fixtures.

Recommended waves:

1. **11.00.** Freeze interfaces and baselines.
2. **Widget lane 11.01 → 11.04 → (11.02 / 11.03) → 11.05 → 11.06**, in parallel
   with **11.07 → (11.08 / 11.09)** and **11.10a → 11.11 → 11.12 → 11.10b**
   (11.08 and 11.10a wait for Phase 10 closeout).
3. **11.13 → 11.14.**

## 3. Task packets

### 11.00 — Freeze contracts and baselines

**Depends on:** none. **Owner:** coordinating agent/design subagent.
**Requirements:** all (characterization only).

Read roadmap Phase 11, the parity rows, `docs/widget-plan.md`, the RN bridge/action
sources, `utils/analytics.ts`, `App.tsx` init, and the existing native App
Group/routing code. Create
`docs/native-phase-11-platform-hardening-contract-decisions.md` with:

- **Snapshot schema:** the exact `BridgeSnapshot` fields (`version`, `updatedAt`,
  `nextJob.{id,customerName,title,scheduledDate,scheduledStartTime,address}`,
  `timer.{jobId,jobTitle,customerName,startedAt}`, `outstandingTotal`), the
  `widgetSnapshot`/`widgetActions`/`activeTrip`/`pendingOpenUrl` keys, the
  app-group id, and the minimal-projection rule (never whole collections).
- **Snapshot write semantics:** when the mirror is written (jobs/timer writes, app
  foreground, and the 10.09 post-sync-commit seam), the sign-out wipe the writer
  must preserve, and a single **stale-snapshot window** value (check
  `docs/widget-plan.md` for an existing one; otherwise decide it here). 11.02's
  stale UI and 11.05's fixtures both test that one boundary.
- **Action-queue contract:** the four `PendingActionType` values, the JSON shape,
  the `.tradeready-widget-actions.lock` advisory-lock protocol, the 512-action cap,
  the `activeTrip` private-session rule, and the replay ordering/idempotency the
  native `NativeWidgetActionBatchPlanner` already enforces.
- **Intent contract:** all ten intents (`NextJobIntent`, `StartTripIntent`,
  `StopTripIntent`, `OnMyWayIntent`, `ClockInIntent`, `ClockOutIntent`,
  `LogExpenseIntent`, `OutstandingIntent` from `_shared/SiriIntents.swift`;
  `StartTimerIntent`, `StopTimerIntent` from `JobTimer.swift`) with each one's
  phrases, parameters, App Group write or read-only behavior, `openAppWhenRun`
  use, and target membership (widget-invoked intents in both targets;
  `AppShortcutsProvider` in the main app target per Apple DTS). Native type
  names and phrases may differ from RN (no current users).
- **SDK decision:** confirm Sentry Cocoa and PostHog iOS via SPM behind
  Foundation-only protocol adapters (§1), and record the SDK versions.
- **Privacy manifest contract:** the required-reason APIs each target uses and
  the collected-data types the app declares, including what the SDKs contribute.
- **Deep-link contract:** the two URL shapes, strict parsing, the five-minute
  freshness window, and the required gate order
  (parse → authenticate → verify exact owner → verify local record exists/archived).
- **Analytics contract:** the full event catalog (name + properties) extracted
  from `track(` call sites, the PostHog host/project config, the `enabled: !DEV`
  gating analog, and the exact `identify`/`reset` callsites.
- **Redaction contract:** the list of secure fields (`providerKey`, `providerKeys`,
  `anthropicKey`, `groqKey`, RevenueCat/stripe keys), the sensitive-document
  rule (invoice/estimate/receipt bytes and customer PII never leave in an event or
  breadcrumb), and the user-id-only identity sent to Sentry.
- **Accessibility baseline:** an inventory of current labels/hints, Dynamic Type
  usage, fixed frames that break at large sizes, contrast pairs, and motion.
- **Device matrix:** the iPhone/iPad/OS rows 11.13–11.14 will require, and which
  of them Phase 12 owns.

**Deliver:** contract decision table (chosen/blocked with reason), event-catalog
fixture, redaction allow/deny table, and a per-row parity-matrix source map.

**Done when:** every task has an exact contract or a named blocker; the snapshot
schema decodes byte-compatibly against the RN widget's `BridgeSnapshot`; and the
event catalog enumerates every `track(` name with its properties.

### 11.01 — WidgetKit target and the shared snapshot contract

**Depends on:** 11.00 W1 contract; 10.01 (`NativeBusinessSnapshot` /
`PaymentLedger` rollup); 10.09 (post-sync-commit seam). **Requirements:** W1
(pure projection + target), M1 (extension manifest).

**Read:** `docs/widget-plan.md`, `targets/widget/Widgets.swift`,
`targets/widget/expo-target.config.js`, `modules/widget-bridge/ios/WidgetBridgeModule.swift`,
`utils/widgetBridge.ts`, `__tests__/widgetBridge.test.js`;
`N/NativeAppGroupInbox.swift`, `N/AppStore.swift` (write hooks + scrub),
`N/Domain/NativeBusinessSnapshot.swift`, `N/NativeDerivedStatePublisher.swift`
(10.09), `N/TradeReadyNative.entitlements`, `native/Info.plist`.

**Own:** new `N/Widgets/` extension target, `N/Widgets/TradeReadyWidgets.swift`,
`N/Widgets/Shared/WidgetSnapshot.swift`, the target membership of
`N/Widgets/Shared/` (compiled into both targets, including 11.04's
`WidgetIntents.swift`), and the extension's `N/Widgets/PrivacyInfo.xcprivacy`;
new `N/Domain/NativeWidgetSnapshot.swift`
(pure projection) and `N/NativeWidgetMirror.swift` (App Group writer); edits to
`native/TradeReadyNative.xcodeproj/project.pbxproj`,
`N/TradeReadyNative.entitlements`, `native/Info.plist`, and the app-side write hooks in
`N/AppStore.swift`/`N/TradeReadyNativeApp.swift`. Only this task edits the target
definition.

1. Create the WidgetKit app-extension target (bundle id sibling, iOS 17.0, App
   Group entitlement on **both** targets) and a `@main WidgetBundle`.
2. Port the `BridgeSnapshot` schema exactly (field names, optionality, the
   `local-frame` date parsing) into a shared source file compiled into both the app
   and the extension; unknown/extra JSON keys must not fail the decode.
3. Implement the pure projection (`nextJob` = earliest non-terminal scheduled job
   with a date; `timer` = the active session or nil; `outstandingTotal` =
   `NativeBusinessSnapshot.outstandingTotal` from 10.01, never a re-derived sum;
   `version`/`updatedAt`).
4. Implement the app-side writer: serialize the projection into
   `widgetSnapshot` under the shared advisory lock on the existing
   jobs/timer/foreground write paths and as an observer registered on the 10.09
   post-sync-commit seam, then `WidgetCenter.shared.reloadAllTimelines()`.
   Never write while signed out or owner-mismatched; the existing
   `NativeAppGroupAccountScrubber` remains the wipe authority.
5. Keep the projection minimal (no collections, no PII beyond the displayed
   fields) per the widget-plan rule.
6. Add the widget extension's `PrivacyInfo.xcprivacy` with its required-reason
   API declarations (App Group `UserDefaults`, plus any file-timestamp use) per
   the 11.00 manifest contract.

**Done when:** the target builds with the app; the schema decodes the RN fixture
JSON unchanged; the projection fixtures (no next job, no timer, both, stale
`updatedAt`) match; `outstandingTotal` equals the 10.01 snapshot value on the
same fixture; the seam observer writes after a committed pass; the extension
manifest is present; the writer is a no-op when signed out and never clobbers a
concurrent extension write (lock held); signing out wipes the suite and reloads
timelines. Device/extension proof stays deferred.

### 11.02 — Next Job widget

**Depends on:** 11.01. **Requirements:** W2.

**Read:** `targets/widget/Widgets.swift` (Next Job small/medium),
`utils/widgetBridge.ts#selectNextJob`; `N/Widgets/Shared/WidgetSnapshot.swift`.

**Own:** new `N/Widgets/NextJobWidget.swift` and its provider/timeline; shared view
components in `N/Widgets/Shared/`.

1. Render customer, time, and address for small and medium families from the
   shared snapshot, with the read-only, no-job, and stale-snapshot states.
2. Deep-link the whole card to `tradeready://job/<id>` using
   `widgetURL`/`Link`; the id must be the exact projected job id (no locale/format
   guessing).
3. Provide a sensible timeline policy (refresh on the next job boundary and on
   timeline reload) without self-scheduling background work.

**Done when:** all families/state fixtures render, the deep-link string matches the
parser's grammar exactly, and a missing/blank snapshot degrades to an explicit
empty state. Device layout proof stays deferred.

### 11.03 — Job Timer widget

**Depends on:** 11.01, 11.04 (defines the Start/Stop Timer intents).
**Requirements:** W3.

**Read:** `targets/widget/JobTimer.swift`, `utils/widgetActions.ts`
(`timer_start`/`timer_stop`), `N/NativeWidgetActionReplay.swift`,
`N/Widgets/Shared/WidgetIntents.swift` (11.04).

**Own:** new `N/Widgets/JobTimerWidget.swift` and the shared timer view. It uses
11.04's timer intents and defines no `AppIntent` type of its own.

1. Interactive start/stop on iOS 17+ using `Button(intent:)` with 11.04's
   `StartTimerIntent`/`StopTimerIntent`, which append a
   `timer_start`/`timer_stop` `PendingAction` to `widgetActions` under the lock —
   never touching canonical state directly.
2. Live elapsed via `Text(.date, style: .timer)` when a timer is running.
3. The read-only fallback (deep-link to the app) where interactive widgets are
   unavailable, and the "no job to clock into" state.

**Done when:** start/stop produce the exact action JSON the replay planner
accepts, the button is idempotent-safe for double taps (duplicate action ids are
rejected by the planner), and the read-only/no-job fixtures render. Device proof
stays deferred.

### 11.04 — App Intents, Siri, and the action-queue contract

**Depends on:** 11.01. **Requirements:** A1, A2, A3.

**Read:** `targets/widget/_shared/SiriIntents.swift` (in full),
`targets/widget/JobTimer.swift`, `utils/widgetActions.ts`,
`utils/deepLinks.ts#parsePendingOpenUrl`, `__tests__/widgetActions.test.js`;
`N/NativeWidgetActionReplay.swift`, `N/NativeDeepLinkParser.swift`,
`N/AppStore.swift` (replay integration + on-my-way route).

**Own:** every `AppIntent` type in the phase: new `N/NativeAppIntents.swift`
(`AppShortcutsProvider`, **app target only**), `N/Intents/OnMyWayIntent.swift`,
`N/Intents/JobActionIntents.swift` (Siri-only intents, app target), and
`N/Widgets/Shared/WidgetIntents.swift` (Start/Stop Timer, compiled into both
targets via 11.01's membership); wire the replay/consumption in
`N/AppStore.swift`/`N/TradeReadyNativeApp.swift` only as needed.

1. Port all ten intents from the 11.00 inventory: Next Job (read-only from the
   snapshot), Start Trip / Stop Trip (the private `activeTrip` session, ending in
   a `trip_log` action), Clock In / Clock Out and Start/Stop Timer
   (`timer_start`/`timer_stop`), Log Expense (`expense_log`), Outstanding ("how
   much am I owed", read-only from the snapshot), and On My Way
   (`openAppWhenRun`; stash `pendingOpenUrl` and open
   `tradeready://onmyway/<id>`).
2. Keep `AppShortcutsProvider` in the main app target (Apple DTS). Intents a
   widget invokes are compiled into both targets so `Button(intent:)` can run
   them in the extension process. Use a single consistent availability floor
   (17.0) to avoid the documented mixed-availability crash.
3. Enforce the action-queue contract: append under the shared advisory lock with
   unique ids, cap at 512, never write canonical state; the app replays the batch
   through its normal save paths on next foreground/launch.
4. Confirm Outstanding and Next Job read only the projected snapshot fields (no
   customer list, no records) and mutate nothing.
5. Trip session: Start Trip writes only the private `activeTrip` key; Stop Trip
   converts it to one `trip_log` action and clears it; a stale session (older
   than the RN one-day cutoff) is discarded, never logged.

**Done when:** each of the ten intents produces a replay-planner-valid action, the
exact `pendingOpenUrl`/deep-link handoff, or a read-only answer; each intent type
is defined once and the timer intents build in both targets;
malformed/oversized batches are rejected; Outstanding and Next Job are read-only;
the trip session start/stop/stale fixtures pass; and the on-my-way intent results in an editable,
never-auto-sent review. Device/Siri proof stays deferred.

### 11.05 — Widget/Siri owner gating and stale/sign-in correctness

**Depends on:** 11.01–11.04. **Requirements:** W4.

**Read:** exit criterion "Widget and Siri actions remain correct across sign-in
changes and stale data"; `N/NativeAppGroupInbox.swift`,
`NativeAppGroupAccountScrubber` (in `N/NativeAppGroupInbox.swift`), `N/AppStore.swift` scrub paths,
`N/NativeWidgetActionReplay.swift`, `N/TradeReadyNativeApp.swift`.

**Own:** app-target edits to the scrub/write/replay paths; new
`native/WidgetOwnerGatingTests/main.swift` and runner.

1. Prove the write gate: no snapshot is written without an exact signed-in
   workspace; sign-out / account switch / deletion scrub the suite and reload
   timelines before any new owner can read it.
2. Prove the replay gate: a queued action from a previous account is dropped
   (owner-mismatch fails closed) rather than applied to the new owner.
3. Handle stale snapshots: a snapshot older than the 11.00 stale-snapshot window, or one whose
   job no longer exists, must not route into a wrong record — the app re-resolves
   the exact id and fails closed.
4. Prove a widget deep link opened while signed out defers/queues correctly and
   either routes after sign-in or is discarded, never leaking another account's
   record.

**Done when:** every cross-sign-in and stale-data fixture resolves to
route-or-discard with no cross-owner leak on the widget, Siri, or deep-link paths.

### 11.06 — Cold and warm deep-link routing with authentication gates

**Depends on:** 11.00 L1/L2 contract; the 11.05 owner-gate API (not all of
11.05's fixtures). **Requirements:** L1, L2.

**Read:** `utils/deepLinks.ts`, `__tests__/deepLinks.test.js`,
`N/NativeDeepLinkParser.swift`, `N/AppStore.swift` (`handle(url:)`,
`routeToOnMyWay`, `deepLinked*`, `consumeOutreachDeepLink`),
`N/RootView.swift` (gate state machine), `N/NativeAppGroupInbox.swift`.

**Own:** app-target edits to `N/AppStore.swift`/`N/RootView.swift`/`N/TradeReadyNativeApp.swift`;
new `native/DeepLinkRoutingTests/main.swift` and runner.

1. Prove both cold (App Group `pendingOpenUrl` within freshness, or launch URL)
   and warm (`onOpenURL`) routing for `job` and `onmyway`.
2. Gate strictly in order: parse → authenticate → verify exact owner → verify the
   local record exists and is not archived/terminal; otherwise fail closed and
   surface the existing not-found/no-account state rather than a wrong record.
3. Handle the not-yet-signed-in case: defer the pending route across the
   auth/onboarding/subscription gate and apply it only once the same owner is
   active, or discard a stale/mismatched one.
4. Preserve the Google Sign-In URL interception ordering (a Google callback must
   never be consumed as a widget link).

**Done when:** cold/warm × signed-out/signed-in × owner-mismatch ×
missing/archived-record matrices resolve correctly, and a malformed/oversized/
stale link is dropped without side effects.

### 11.07 — Analytics transport and privacy controls

**Depends on:** 11.00 P1/P4 contract. **Requirements:** P1, P4.

**Read:** `utils/analytics.ts`, `App.tsx` (PostHog provider/init),
`app.json` (`posthogApiKey`), `context/AuthContext.tsx` (identify),
`screens/PaywallScreen.tsx`/`screens/SettingsAccountScreen.tsx` (reset),
`N/BuildEnvironment.swift`, `N/NativeTypedAccountState.swift` (secure fields).

**Own:** new `N/NativeAnalytics.swift` (transport + `track`/`identify`/`reset`),
`N/NativeAnalyticsConfiguration.swift`; app-target wiring in
`N/TradeReadyNativeApp.swift`/`N/BuildEnvironment.swift`. No screen instrumentation
here (that is 11.08).

1. Implement a PostHog transport (PostHog iOS SDK via SPM behind a protocol
   adapter, per §1) with a build/env gate mirroring `enabled: !DEV`
   and a `PLACEHOLDER`-key guard, disabled by default in Debug, and never
   crashing the app on failure (swallow like RN).
2. Enforce the redaction boundary at the single `track` choke point: reject/strip
   secure fields and sensitive document/customer payloads; allow only the finite
   property schema the catalog declares.
3. Fail closed when configuration is missing (no events, no crash).
4. Record the analytics collected-data types and any SDK-contributed
   required-reason APIs for the app manifest, which 11.09 writes (M1).
5. Replace Phase 10's no-op `NativeAnalytics` seam with this transport without
   changing its call sites.

**Done when:** a Debug build emits nothing; a configured release emits the exact
event/property payload; a secure-field or oversize/PII payload is stripped or
rejected with a bounded diagnostic; a missing key disables analytics without a
crash.

### 11.08 — Event parity and the identity lifecycle

**Depends on:** 11.07; Phase 10 closeout (10.15), since the `insight_*`,
`sample_job_opened`, and coach `insight_prefill` call sites come from 10.12/10.13.
**Requirements:** P2, P3.

**Read:** the full `track(` catalog (section 11.00 output), the RN screens each
event originates from, `context/AuthContext.tsx`,
`N/NativeAuthenticatedIdentity.swift`, `N/AppStore.swift` (sign-in/out/deletion),
`N/NativeAccountDeletion.swift`.

**Own:** new `N/NativeAnalyticsEvents.swift` (typed event constructors) and the
app-target instrumentation of each event; `native/AnalyticsEventTests/main.swift`
and runner.

1. Instrument every catalog event with the identical name and properties, from the
   same business moment RN fires it (after the durable commit, not on tap).
2. Implement the identity lifecycle: `identify` the Supabase user id on sign-in,
   `reset` on sign-out, account switch, and deletion, and never send PII or secure
   keys.
3. Cover the contextual events (insight shown/tapped/dismissed/snoozed,
   onboarding steps, widget deep-link opened, estimate/booking/change-order
   opening) that the newer phases added.
4. Keep analytics failures non-fatal and out of the mutation-commit path.

**Done when:** a fixture run emits the exact expected event sequence for the
sign-in → work → sign-out journey, every event name/property matches the catalog,
and identity is set/reset at each boundary.

### 11.09 — Crash reporting and redaction

**Depends on:** 11.07. **Requirements:** R1, R2, R3, M1 (app manifest).

**Read:** `utils/analytics.ts#reportError`, `App.tsx` (Sentry init +
`ErrorBoundary`), `app.json` Sentry plugin config, `N/BuildEnvironment.swift`,
secure-field handling in `N/NativeTypedAccountState.swift`.

**Own:** new `N/NativeCrashReporting.swift`, `N/NativeErrorRedaction.swift`
(Foundation-only), the app's `N/PrivacyInfo.xcprivacy`;
app-target wiring in `N/TradeReadyNativeApp.swift`; `native/ErrorRedactionTests/main.swift`
and runner.

1. Initialize the crash reporter (Sentry Cocoa SDK via SPM behind a protocol
   adapter, per §1) with DSN/env gating (`enabled: !DEV`, `PLACEHOLDER` guard)
   and release symbols/dSYM-upload configuration. Set performance-trace sampling
   to RN's `tracesSampleRate: 0.2` (`App.tsx`). Separately, enable auto-session
   tracking (release health), which the Phase 12 crash-free-sessions metric
   depends on. These are two different settings.
2. Implement `reportError` parity, including the non-`Error` wrapper that turns
   Supabase/PostgREST plain objects into a titled `Error` with the raw object as
   extra, so the issue title carries the real message.
3. Install a `beforeSend`/breadcrumb scrubber that removes secure fields, request
   bodies, customer PII, and document bytes; set only the user id.
4. Keep crash reporting out of the business-commit path (a reporting failure never
   blocks a save).
5. Write the app's `PrivacyInfo.xcprivacy` (M1): required-reason APIs the app
   uses (App Group and standard `UserDefaults`, file timestamps, any others found
   in 11.00) and the collected-data types from 11.07 and this task. Confirm the
   Sentry and PostHog SDKs ship their own manifests.

**Done when:** the redaction test proves no secure field, customer PII, token, or
document byte can survive into an event, breadcrumb, or exception payload; plain
objects report with a meaningful title; Debug reports nothing; traces sample at
0.2 with session tracking on; the app manifest exists and matches the 11.00
contract.

### 11.15 — Settings › AI Assistant advanced key entry

**Depends on:** 11.00 redaction contract; 11.09 (redaction/scrubber in place).
**Requirements:** P4, R2 (secure-key handling); parity row "Settings › AI Assistant".
Added 2026-09-23 to own the Phase 10 final-review I4 carry-in. Runs in the
app-target lane after 11.09.

**Read:** `screens/SettingsAIScreen.tsx` (the "Advanced" toggle and Groq/Anthropic
key entry), the RN key storage it writes, `N/NativeCoachTransport.swift`
(provider precedence), `N/AppStore.swift` (`coachProviderSummary`), the native
Settings AI Assistant page, and the existing native Keychain/secure-key store
that migrated keys are read from.

**Own:** the native Settings › AI Assistant "Advanced" section (view edits) and
any pure validation helper; a host test runner for the key-entry policy.

1. Add the "Advanced" section with secure (`SecureField`) Groq and Anthropic key
   entry, matching RN's copy and behavior (save, clear, masked display of a saved
   key), storing keys only in the existing Keychain store the coach transport
   reads. No key ever enters `UserDefaults`, the App Group, analytics, crash
   payloads, logs, or the widget snapshot.
2. Saving or clearing a key updates the provider summary and the coach transport's
   provider selection with the same precedence the transport uses.
3. Keys are owner-bound per the existing secure-store rules and are wiped on
   sign-out/account deletion the same way migrated keys are.

**Done when:** save/clear/precedence/owner-wipe fixtures pass, a redaction test
proves an entered key cannot reach an analytics or crash payload, the parity row's
"Remaining gap" is closed or narrowed with evidence, and the app compiles. Live
provider proof stays deferred to Phase 12.

### 11.10 — Accessibility audit and remediation (11.10a, 11.10b)

**Depends on:** 11.00 H1 baseline and Phase 10 closeout (10.15), so the audit
covers the rewritten `TodayView`/`CoachView`. **Requirements:** H1.

Run in two parts: **11.10a** audits and fixes (steps 1–4 below); **11.10b**
re-audits after 11.11 and 11.12 land and fixes any regressions they introduced.
11.10b closes H1.

**Read:** the parity row "Accessibility"; every `N/*.swift` view (inventory from
11.00); `components/`/`screens/` for the RN labels/hints that must match.

**Own:** app-wide accessibility edits across view files (a distinct serialized
pass; do not entangle with the analytics work), new
`N/Domain/NativeAccessibilityAudit.swift` (labels/hints source of truth where
useful), and `native/AccessibilityAuditTests/main.swift` and runner.

1. VoiceOver: labels/hints/traits for every actionable row, button, and image-only
   control; correct reading order; no unlabeled icon buttons.
2. Dynamic Type: remove fixed heights/truncation that clip at the largest sizes;
   verify `minimumScaleFactor`/`lineLimit` choices.
3. Contrast, Reduce Motion (honor the setting for custom animations/transitions),
   and touch targets ≥ 44×44.
4. Keyboard navigation (iPad/hardware keyboard) and switch control focus order.

**Done when:** the audit inventory has zero release-blocking findings and each
fix has a test or a documented manual step; label/hint text matches RN where the
row requires parity. Full VoiceOver/switch-control proof stays deferred to device.

### 11.11 — iPad layouts, multitasking, and rotation

**Depends on:** 11.10a. **Requirements:** H2.

**Read:** the parity row "Accessibility" (iPad), `N/RootView.swift` tab/stacks,
the `layout.contentColumn` analog, `native/Info.plist` orientation keys.

**Own:** app-wide layout edits; new `N/NativeLayoutMetrics.swift` where a shared
width cap helps; `native/LayoutMetricsTests/main.swift` and runner.

1. Adopt a max content width / adaptive column so list and form screens do not
   stretch edge-to-edge on iPad, matching RN's `contentColumn`.
2. Verify Split View/Slide Over, rotation (all declared orientations), and
   keyboard-avoidance on iPad.
3. Confirm no fixed-width/frame regression at large Dynamic Type.

**Done when:** the shared width metric is applied consistently, rotation and
multitasking hosts render without clipping or duplicate navigation, and no
screen remains a full-width stretched list. Device layout proof stays deferred.

### 11.12 — Performance, launch time, and device soak

**Depends on:** 11.10a, 11.11. **Requirements:** H3, H4.

**Read:** `N/NativeInitialSync.swift`, `N/NativeSyncCoordinator.swift`,
`N/NativeBackgroundRefresh.swift`, `N/LegacyDataImporter.swift`,
`N/LegacyMigrationCoordinator.swift`, and the injected transports from Phases 4–7.

**Own:** new `N/NativePerformanceMetrics.swift` (launch-time/measurement hooks and
any opt-in signposting), a non-invasive instrumentation pass,
`native/PoorNetworkTests/main.swift` and runner, and
`docs/native-phase-11-performance.md` with the measurement protocol. No behavioral
policy changes.

1. Define and capture launch-time measurement (cold/warm) and a small set of
   performance signposts (migration, initial sync, list rendering) that run in
   release-with-dSYM builds.
2. Define the memory/battery/poor-network soak protocol: background refresh under
   throttling, large collections, offline→online transitions, and low-power mode.
3. Add host-level poor-network tests now, using the injected transports:
   offline→online transitions (queued mutations drain once, in order), a
   throttled/timeout transport (typed failure, no duplicate commit), and a
   mid-pass connectivity drop (the prior committed state is retained).
4. Define the native measurements Phase 12 will capture. Phase 12.00 sets
   provisional thresholds from the current Expo app's production metrics; the
   native baselines from Stage A refine them (see Phase 12.00).

**Done when:** the protocol document lists exact steps, environments, and the
measurements to capture; the poor-network host suite passes; instrumentation is
non-invasive and debug-safe; and every measurement has a named Phase 12 owner.
Device numbers are captured during Phase 12 Stage A.

### 11.13 — Cross-client and platform qualification

**Depends on:** 11.01–11.12. **Requirements:** all.

**Own:** focused integration fixtures and evidence appended to
`docs/native-phase-11-platform-hardening-contract-decisions.md`; no opportunistic
rewrite.

Exercise: widget snapshot parity against the RN `BridgeSnapshot` fixture, action
batch replay round-trips, deep-link matrices, the full event catalog against RN
callsites, redaction denylist, and the accessibility/layout metrics. Re-run the
RN oracles in section 4 after any compatibility change.

**Done when:** every source-discovered gap has coverage or a named blocker, and
remaining device/extension/Siri/store proof is explicitly deferred to Phase 12.

### 11.14 — Aggregate verification and evidence closeout

**Depends on:** 11.13.

Register new focused runners in `native/run-all-domain-tests.sh`, verify Xcode
target membership for the app + widget extension, run the aggregate suite, and
record a signed generic-device Release build result (the widget extension must be
included). Create `docs/native-phase-11-device-runsheet.md` from the parity rows
and link it into the Phase 12 checklist. Update the roadmap and parity matrix with
completed code versus deferred evidence, never a blanket "Verified".

**Done when:** each requirement has code/test/evidence references; the widget
extension and app intents are real; no dependency is silently waived; device rows
have steps, expected result, environment/build, and evidence placeholders. No
store submission is part of this task.

## 4. Verification commands

Run from repository root. New focused Swift runners must be created by their task
before being invoked. Use only relevant oracles per task; run the full aggregate
at closeout.

```sh
# Widget bridge, actions, deep links, and analytics (RN oracle)
TZ=America/Phoenix npm test -- --runInBand --runTestsByPath __tests__/widgetBridge.test.js __tests__/widgetActions.test.js __tests__/deepLinks.test.js __tests__/analytics.test.ts

# Existing native foundations
sh native/run-widget-action-replay-tests.sh
sh native/run-app-group-pending-open-url-tests.sh
sh native/run-background-refresh-tests.sh
sh native/run-snapshot-tests.sh
sh native/run-store-integration-tests.sh

# Integration closeout (app + widget extension)
sh native/run-all-domain-tests.sh
xcodebuild -project native/TradeReadyNative.xcodeproj -scheme TradeReadyNative -configuration Release -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

Because the widget target and App Intents need signing and a device, the closeout
records which checks ran unsigned/without a device and defers the rest. Do not
invoke any App Store Connect or deploy command to validate a build.

## 5. Reusable subagent prompt

> Implement **task 11.XX only** from `docs/native-phase-11-implementation-plan.md`.
> Read its dependency results,
> `docs/native-phase-11-platform-hardening-contract-decisions.md`, and the listed
> source/tests first. Report missing prerequisites before touching dependent code.
> Respect the task file ownership and any existing uncommitted work. Reuse the
> existing App Group/replay/deep-link foundations (`N/NativeAppGroupInbox.swift`,
> `N/NativeWidgetActionReplay.swift`, `N/NativeDeepLinkParser.swift`,
> `N/AppStore.swift` routing) and the RN `BridgeSnapshot`/`PendingAction`
> contracts rather than re-inventing them. Extensions run out-of-process: never
> trust app state, never write canonical data directly, and never leak a prior
> owner. Analytics/crash payloads must expose no secure keys, tokens, customer
> PII, or document bytes. Add meaningful oracle/failure tests and run focused
> checks, compiling app and widget targets. Record actual commands/results.
> Return requirement IDs covered, files changed, interface handoff, evidence,
> unresolved blockers, and next-ready tasks. Do not edit another task's shared
> files or the Xcode target definition, weaken determinism tests, commit, deploy,
> or submit to the store.

## 6. Initial execution ledger

11.00 is done (see §7); tasks **11.01–11.15 are pending**. The source review used to write this plan is
not test execution or an implementation completion. When work starts, maintain one
row per task: status, owner/session, dependency evidence, files, commands, actual
results, blockers, and handoff. Separate **implementation blocked** from **code
complete / Phase 12 evidence deferred**.

| Task | Requirement IDs | Status | Depends on | Deliverable |
|---|---|---|---|---|
| 11.00 | all | Done (contract frozen 2026-09-23; C8 → 11.05, C11/P8 → 11.06 named blockers) | — | Contract decisions + event catalog + intent inventory + baselines — [contract](native-phase-11-platform-hardening-contract-decisions.md) |
| 11.01 | W1, M1 | Pending | 11.00, 10.01, 10.09 | Widget target + snapshot contract + extension manifest |
| 11.02 | W2 | Pending | 11.01 | Next Job widget |
| 11.03 | W3 | Pending | 11.01, 11.04 | Job Timer widget |
| 11.04 | A1, A2, A3 | Pending | 11.01 | All ten App Intents + Siri + action queue |
| 11.05 | W4 | Pending | 11.01-11.04 | Owner/stale/sign-in correctness |
| 11.06 | L1, L2 | Pending | 11.00, 11.05 (owner-gate API) | Deep-link routing + auth gates |
| 11.07 | P1, P4 | Pending | 11.00 | Analytics transport + privacy |
| 11.08 | P2, P3 | Pending | 11.07, 10.15 | Event parity + identity lifecycle |
| 11.09 | R1, R2, R3, M1 | Pending | 11.07 | Crash reporting + redaction + app manifest |
| 11.15 | P4, R2 | Pending | 11.00, 11.09 | Settings › AI Assistant advanced key entry |
| 11.10a | H1 | Pending | 11.00, 10.15 | Accessibility audit + fixes |
| 11.11 | H2 | Pending | 11.10a | iPad layouts + multitasking |
| 11.12 | H3, H4 | Pending | 11.10a, 11.11 | Performance + poor-network host tests + soak protocol |
| 11.10b | H1 | Pending | 11.11, 11.12 | Accessibility re-audit (closes H1) |
| 11.13 | all | Pending | 11.01-11.12, 11.15 | Cross-client qualification |
| 11.14 | all | Pending | 11.13 | Aggregate verification + closeout |

Exit criteria traceability (roadmap Phase 11):

- "Widget and Siri actions remain correct across sign-in changes and stale data" —
  11.05 (owner/stale/sign-in) and 11.06 (routing gates), confirmed by 11.13.
- "Analytics and diagnostics contain no secure keys or sensitive document data" —
  11.07 (transport privacy), 11.08 (event parity), and 11.09 (redaction),
  confirmed by 11.13.
- "Accessibility and device-matrix audits have no release-blocking findings" —
  11.10a/11.10b, 11.11, 11.12, with the device runsheet collected in 11.14 and
  executed in Phase 12.
- Roadmap Stage C "privacy manifests" prerequisite — 11.01 (extension) and 11.09
  (app), verified in Phase 12.01.

## 7. Execution log

### 11.00 — Freeze contracts and baselines (2026-09-23)

**Status:** Done. The contract is frozen; this was characterization only (no Swift, no
tests, no project or RN edits). Two items are named blockers with owners: C8 (replay
wedge on a malformed or duplicate queue → 11.05) and C11/P8 (`est_` archived dead tap →
11.06).

**Files:**
- `docs/native-phase-11-platform-hardening-contract-decisions.md` (new, created by 11.00);
- this plan: line-5 status, the §6 row, and this §7.

**Interface handoff** (contract §15 has the full list):
- **11.01:**
  - schema and fixtures F1–F6 (§2.4);
  - the writer rules, including explicit `null`s, `address` always a string,
    `outstandingTotal` = `FinancialDecimal.cents` of the 10.01 value, and `.sortedKeys`;
  - `ownerTag`;
  - write triggers (§3.1).
  - **Own-list addition:** a `(canonical, output)` observer overload in
    `N/NativeDerivedStatePublisher.swift` plus a narrow binding accessor in
    `N/AppStore.swift` (§3.2).
  - The extension manifest (§8) and the P3 exception sets (§5.4).
- **11.02 / 11.05:** stale window **86,400 s**. Stale iff `age > 86400`, a negative age,
  or unparseable; exactly 86,400 s is fresh. Stale UI and intent behavior are in §3.3.
- **11.04:**
  - writer rules (§4.3): lock; refuse at 512; exact duplicates are idempotent and
    differing duplicates fail; never overwrite a malformed queue;
  - owner stamp (§4.5);
  - ten intents and phrases (§5), with a single 17.0 floor;
  - OnMyWay routes in-process, never auto-sent (§5.1).
- **11.05:** drop actions whose `ownerTag` is missing or mismatched; quarantine policy
  for C8 (§4.6).
- **11.06:** gate order parse → auth → exact owner → exists and not archived. `onmyway`
  also refuses done statuses. Parking across the gate. Close the `handle(url:)` and
  pending-consumer gaps. Decide P8 (§6).
- **11.07:**
  - Release + key + non-`PLACEHOLDER` gate (a deviation: RN had no dev gate for PostHog);
  - SDK options (§9.2);
  - allow-list enforcement from the §9.5 JSON fixture;
  - widen the seam in place to JSON scalars and string arrays, and add
    identify/reset/screen (§9.6);
  - re-check the PostHog pin.
- **11.08:** 52 events / 73 RN sites (§9.5); identity lifecycle, including reset on
  account switch (§9.4); the `$screen` route-name map (§9.3); m6 gaps
  (`first_action_tapped`, `on_my_way_sent`) and the stringified properties.
- **11.09:** Sentry 9.29.0 config (§10.2): 0.2 traces, auto sessions,
  `sendDefaultPii = false`, failed-request capture off, redactor hooks. `reportError`
  parity with allow-listed extras and a reduced `rawError` (§10.3). The app manifest (§8).
- **11.15:** Keychain accounts `anthropicKey`/`groqKey` via
  `NativeKeychainSecureSettingsStore`; masked display; the redaction test (§11).
- **11.10a/11.11/11.12/11.10b:** a11y baseline and release-blocking candidates (§12):
  - `tradeReady` on the dark canvas at 2.61;
  - six unlabeled icon buttons;
  - Reduce Motion ignored in two places;
  - no scaled metrics.
  Device rows are in §13.
- **11.13/11.14:** Phase 11 rows (host, unsigned build, signed local build, optional
  simulator). Phase 12 owns every physical row (§13).

**Commands and results:**
- `TZ=America/Phoenix npm test -- --runInBand --runTestsByPath __tests__/widgetBridge.test.js __tests__/widgetActions.test.js __tests__/deepLinks.test.js __tests__/analytics.test.ts`
  → 4 suites and 123 tests passed.
- Scratchpad-only `swiftc` decode of F1–F6 against a verbatim copy of RN
  `BridgeSnapshot` → F1–F5 decode, F6 rejected, as expected. Nothing was added to the repo.
- `git ls-remote --tags` plus the GitHub releases API → Sentry Cocoa 9.29.0 and PostHog
  iOS 3.81.0 are the latest stable. PrivacyInfo was read at the tags.
- Node check: the §9.5 fixture has 52 events, matching the 52 distinct RN `track(`
  names exactly, and every event has a catalog table row.
- `sh native/run-doc-reference-check.sh` → 1299 path references checked: 0 missing, 50 planned.

**Deviations and blockers:**
- Native analytics Debug gate (RN sent from dev).
- `onmyway` refuses done statuses.
- Untagged (RN-written) queued actions are dropped by replay (no current users).
- Writers refuse at 512 and never overwrite a malformed queue (RN JobTimer overwrote).
- Blocked: C8 (11.05) and C11/P8 (11.06).
- Concern: the PostHog 3.81.0 pin was one day old (11.07 re-checks).

**Next ready:** 11.01, since its dependencies are satisfied: 11.00 plus 10.01 and 10.09
from Phase 10. 11.07 and 11.10a are also unblocked by 11.00, but the SDD serial order
runs 11.01 next.
