# Phase 11 — Subagent Implementation Plan

**Date:** 2026-09-21

**Status:** 11.00 contract frozen (2026-09-23); 11.01 and 11.04 done (2026-09-23); 11.02, 11.03 and 11.05 done (2026-09-24); implementation tasks 11.06–11.15 pending. See §7.
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

- **Widget/extension lane:** 11.01–11.04 share the extension target (extension-only
  sources in `native/TradeReadyWidgets/`; shared sources in `N/Widgets/Shared/`; see the
  11.01 file-placement rule in §7),
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

**Own:** new extension target, `native/TradeReadyWidgets/TradeReadyWidgets.swift` (relocated
from `N/Widgets/` by 11.01; see §7),
`N/Widgets/Shared/WidgetSnapshot.swift`, the target membership of
`N/Widgets/Shared/` (compiled into both targets, including 11.04's
`WidgetIntents.swift`), and the extension's `native/TradeReadyWidgets/PrivacyInfo.xcprivacy`;
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

**Own:** new `native/TradeReadyWidgets/NextJobWidget.swift` (extension-only root; 11.01 §7
placement rule) and its provider/timeline; shared view
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

**Own:** new `native/TradeReadyWidgets/JobTimerWidget.swift` (extension-only root; 11.01 §7
placement rule) and the shared timer view. It uses
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

11.00 and 11.01 are done (see §7); tasks **11.02–11.15 are pending**. The source review used to write this plan is
not test execution or an implementation completion. When work starts, maintain one
row per task: status, owner/session, dependency evidence, files, commands, actual
results, blockers, and handoff. Separate **implementation blocked** from **code
complete / Phase 12 evidence deferred**.

| Task | Requirement IDs | Status | Depends on | Deliverable |
|---|---|---|---|---|
| 11.00 | all | Done (contract frozen 2026-09-23; C8 → 11.05, C11/P8 → 11.06 named blockers) | — | Contract decisions + event catalog + intent inventory + baselines — [contract](native-phase-11-platform-hardening-contract-decisions.md) |
| 11.01 | W1, M1 | Done (code complete 2026-09-23; device/extension proof deferred to Phase 12) | 11.00, 10.01, 10.09 | Widget target + snapshot contract + extension manifest |
| 11.02 | W2 | Done (code complete 2026-09-24; device layout proof deferred to Phase 12) | 11.01 | Next Job widget |
| 11.03 | W3 | Done (code complete 2026-09-24; device layout proof deferred to Phase 12) | 11.01, 11.04 | Job Timer widget |
| 11.04 | A1, A2, A3 | Done (code complete 2026-09-23; Siri/device proof deferred to Phase 12) | 11.01 | All ten App Intents + Siri + action queue |
| 11.05 | W4 | Done (code complete 2026-09-24; item 4 routing-after-sign-in handed to 11.06; device/Siri/widget proof deferred to Phase 12) | 11.01-11.04 | Owner/stale/sign-in correctness |
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
    `outstandingTotal` = the 10.01 value in dollars rounded to 2 dp (`FinancialDecimal.cents`
    rounds dollars; it does not convert to cents), and `.sortedKeys`;
  - `ownerTag` = hash of the single owner predicate `derivedStatePublishBinding` (§2.5);
  - the writer gated on that predicate;
  - write triggers (§3.1).
  - **Own-list addition:** a `(canonical, output, expectedOwnerBinding)` observer overload
    in `N/NativeDerivedStatePublisher.swift` and the matching
    `AppStore.registerDerivedStateObserver` overload (§3.2). No separate binding accessor.
  - The extension manifest (§8) and the P3 exception sets (§5.4).
- **11.02 / 11.05:** stale window **86,400 s**. Stale iff `age > 86400`, a negative age,
  or unparseable; exactly 86,400 s is fresh. Stale UI and intent behavior are in §3.3.
- **11.04:**
  - writer rules (§4.3): lock; refuse at 512; exact duplicates are idempotent and
    differing duplicates fail; never overwrite a malformed queue;
  - owner stamp on actions, `activeTrip` and the `pendingOpenUrl` stash; every snapshot
    read happens in the append's lock hold; with no snapshot or tag, refuse with "Open
    TradeReady and sign in first." (§4.5, §6.2);
  - ten intents and phrases (§5), with a single 17.0 floor;
  - OnMyWay routes in-process, never auto-sent (§5.1).
- **11.05:** move the replay gate from the migrated-only owner to the §2.5 predicate
  (gap: native-only accounts never replay today). Drop actions whose `ownerTag` is
  missing or mismatched, including unknown types. Quarantine policy for C8 (§4.6).
- **11.06:** gate order parse → auth → exact owner → exists and not archived. `onmyway`
  also refuses done statuses. Move the deep-link and pending-URL gate to the §2.5
  predicate (gap: migrated-only today, and the consumer runs once per session). Read and
  remove the stash under the lock; tag-based cold-launch parking. Close the
  `handle(url:)` and pending-consumer gaps. Decide P8 (§6).
- **11.07:**
  - Release + key + non-`PLACEHOLDER` gate (a deviation: RN had no dev gate for PostHog);
  - SDK options (§9.2);
  - allow-list enforcement from the §9.5 JSON fixture;
  - widen the seam in place to JSON scalars and string arrays, and add
    identify/reset/screen (§9.6);
  - re-check the PostHog pin.
- **11.08:** 52 events / 70 RN call sites (§9.5), asserting the event set and never a site count; identity lifecycle, including reset on
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
- Gaps with owners (C22): existing replay and pending-URL consume run only for migrated
  (RN-artifact) owners → 11.05 and 11.06.
- Concern: the PostHog 3.81.0 pin was one day old (11.07 re-checks).

**Next ready:** 11.01, since its dependencies are satisfied: 11.00 plus 10.01 and 10.09
from Phase 10. 11.07 and 11.10a are also unblocked by 11.00, but the SDD serial order
runs 11.01 next.

**Fix round 1 (2026-09-23, task review of 55c8357):**
- I1: one owner predicate for the snapshot writer, `ownerTag`, the replay gate and the
  deep-link gate: `derivedStatePublishBinding` (contract §2.5, C22). The migrated-only
  replay and consume gates are recorded as gaps owned by 11.05 and 11.06.
- M1: 70 call sites, not 73.
- M2: `outstandingTotal` wording is dollars rounded to 2 dp.
- M3: the full snapshot read happens in the append's lock hold.
- M4: ClockOut reads `snapshot.timer`; the no-snapshot refusal dialog is defined.
- M5: the overload passes `expectedOwnerBinding`, so no accessor is needed.
- M6: the stash is tagged and removed under the lock, with a cold-launch parking rule.
- M7: `expenseDescription` optionality is recorded as a native choice; untagged
  unknown-type actions are dropped.
- `sh native/run-doc-reference-check.sh` → 1304 path references checked: 0 missing, 50 planned.

### 11.01 — WidgetKit target and the shared snapshot contract (2026-09-23)

**Status:** Done (code complete). The target builds and embeds with the app, and every
host-test item in the packet's "Done when" passes. Device and extension proof (the
widget rendering on a Home Screen, a real App Group container, `WidgetCenter` reloads)
is deferred to Phase 12. It was not claimed as passed.

**Files:**
- New, compiled into both targets (`N/Widgets/Shared/`):
  - `N/Widgets/Shared/WidgetAppGroup.swift`: the suite name, the keys, the account-key
    list, the lock file name, and `WidgetAppGroupLock`, the single §4.2 `flock`
    implementation;
  - `N/Widgets/Shared/WidgetSnapshot.swift`: the §2.2/§2.3 schema, decode and encode,
    `load(from:)`, `isStale(now:)`, and the local-frame `startDate`.
- New, extension only (`native/TradeReadyWidgets/`, its own synchronized root):
  - `native/TradeReadyWidgets/TradeReadyWidgets.swift`: the `@main WidgetBundle`, which
    holds one placeholder widget that 11.02/11.03 replace;
  - `native/TradeReadyWidgets/Info.plist`;
  - `native/TradeReadyWidgets/PrivacyInfo.xcprivacy`;
  - `native/TradeReadyWidgets/TradeReadyWidgets.entitlements`.
- New, app only:
  - `N/Domain/NativeWidgetSnapshot.swift`: the pure projection and `NativeWidgetOwnerTag`;
  - `N/NativeWidgetMirror.swift`: the writer, `NativeWidgetTimelineReloading`, and
    `NativeWidgetMirrorOutcome`.
- Edited:
  - `N/AppStore.swift`: the write triggers, the owner gate, the injectable reloader,
    and the sign-out/delete reload;
  - `N/NativeDerivedStatePublisher.swift`: the commit-observer overload;
  - `N/NativeAppGroupInbox.swift`: the scrubber now uses `WidgetAppGroup` and
    `WidgetAppGroupLock`, and the scrub runs under the lock;
  - `N/TradeReadyNativeApp.swift`: installs the mirror;
  - `native/TradeReadyNative.xcodeproj/project.pbxproj`: the extension target, the
    embed phase, the dependency, and both synchronized roots;
  - `native/Info.plist`: the version keys now come from build settings.
- Tests: `native/WidgetSnapshotTests/main.swift` and `native/run-widget-snapshot-tests.sh`
  (both new). The runner is registered in `native/run-all-domain-tests.sh`.
  `native/run-appstore-sources-common.sh` and `native/run-app-group-pending-open-url-tests.sh`
  gained the new sources.
- `N/TradeReadyNative.entitlements` already carried the App Group, so it is unchanged.

**Interface handoff (11.02–11.05):**
- **File-placement rule (contract §5.4 amendment):**
  - extension-only code goes in `native/TradeReadyWidgets/` (for example
    `NextJobWidget.swift` and `JobTimerWidget.swift`);
  - code shared by the app and the extension goes in `N/Widgets/Shared/` (11.04's
    `WidgetIntents.swift`). It joins both targets with no project-file edit, so it must
    compile in both;
  - never put an extension-only file anywhere else under `N/Widgets/`, because it would
    join the app target;
  - the extension compiles with `TRADEREADY_WIDGET_EXTENSION` set, for the rare guard;
  - no later task edits the target definition.
- **Owner tag:** `NativeWidgetOwnerTag.make(binding:)` is lowercase hex SHA-256 of
  `"tradeready.widget.owner.v1:" + binding`. It lives in the app target only; the
  extension compares tags and never derives one. Test vector: `bind-11.01` →
  `1e5d7fb08a5be400f0b4515415ee7a0cc66d76a13b46baf11bc2df299128e19f`.
- **Lock:** `WidgetAppGroupLock.withExclusiveLock(at:_:)`, with the file at
  `WidgetAppGroup.liveLockFile()`. 11.04's append and 11.05's replay must use this
  exact helper, never a second `flock` implementation.
- **Schema:**
  - `WidgetSnapshot.load(from:)` works for display readers without the lock. Intent
    writers must read inside their own lock hold (§4.5);
  - `isStale(now:)` applies the §3.3 rule. 11.02 owns the stale UI and the boundary
    tests, and 11.05 owns the stale behavior of intents;
  - `NextJob.startDate(timeZone:)` parses in the local frame.
- **AppStore API:**
  - `widgetMirrorOwnerBinding` is `derivedStatePublishBinding`. It is nil while a
    sign-out or delete scrub is in progress, while the scrub is blocked, or while a
    scrub is pending;
  - `refreshWidgetMirror(force:now:)` returns a `NativeWidgetMirrorOutcome?`;
  - `installWidgetMirror(_:)`;
  - `registerDerivedStateObserver(committed:)`, the §3.2 overload.
- **Triggers now wired:**
  - canonical writes: `snapshot` didSet → one coalesced, non-forced write per main-actor
    turn;
  - owner and gate changes;
  - foreground refresh (after replay);
  - background refresh (after replay);
  - the 10.09 seam observer. It writes the committed canonical tagged with
    `expectedOwnerBinding`, or the live snapshot if a local write landed during the
    publish (fix round 1).
  - Only the launch-time install write is forced; every other write uses the 1-hour dedupe.
- **Publishing:** every AppStore publish site calls `publishDerivedState(expectedOwnerBinding:)`
  (fix round 1). Never call `derivedStatePublisher.publish` directly from `AppStore`.
- **Reloads:** timelines reload after every write, after sign-out and delete, after
  `retryAccountScrub`, and after scrub recovery at launch. All go through
  `NativeWidgetTimelineReloading`.

**Commands and results:**
- `TZ=America/Phoenix sh native/run-widget-snapshot-tests.sh` → passed. It covers:
  - F1–F6 through both the native decoder and a verbatim RN `BridgeSnapshot`;
  - F4 byte-identical encoding and the explicit-null shape;
  - projections equal to F1, F2 and F3, plus the RN `selectNextJob`/`selectActiveTimer`
    vectors and the FA-039 evening edge;
  - stale boundaries at 86,399, 86,400 and 86,401 seconds, a negative age, and garbage;
  - outstanding = the 10.01 value (160, 1234.55);
  - the owner-tag vector;
  - the writer: nil and mismatched owner, written, unchanged versus forced, unavailable;
  - the lock: a concurrent `flock` holder blocks the writer, and its actions write
    survives;
  - the scrub race → `skippedOwnerChanged` with an empty suite;
  - the commit-observer overload;
  - the AppStore triggers: sign-in gate, `clockIn`, seam, mismatch;
  - sign-out → wipe + reload, with no write in the post-scrub window.
  Two mutation checks confirmed the suite fails when the in-lock owner re-check or the
  account-boundary suspension is removed.
- `TZ=America/Phoenix sh native/run-all-domain-tests.sh` → exit 0, all runners passed (the widget-action batch planner, App Group pending-open-URL, background refresh, widget snapshot and canonical AppStore integration pass lines are all present). This includes
  `run-widget-action-replay`, `run-app-group-pending-open-url`, `run-store-integration`
  and `run-background-refresh`.
- `TZ=America/Phoenix npm test -- --runInBand --runTestsByPath __tests__/widgetBridge.test.js`
  → 1 suite and 18 tests passed.
- `xcodebuild -project native/TradeReadyNative.xcodeproj -scheme TradeReadyNative -configuration Release -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build`
  → `** BUILD SUCCEEDED **`, with 7 pre-existing warnings and none in new files. Membership was checked from the SwiftFileLists:
  - the app list has the Shared files, the projection and the mirror, and not
    `TradeReadyWidgets.swift`;
  - the extension list is exactly `WidgetAppGroup.swift`, `WidgetSnapshot.swift` and
    `TradeReadyWidgets.swift`;
  - `TradeReadyNative.app/PlugIns/TradeReadyWidgets.appex` carries bundle id
    `com.gettradereadyapp.tradeready.widgets`, version 1.0 (1), MinimumOSVersion 17.0,
    and `PrivacyInfo.xcprivacy`.
- `sh native/run-doc-reference-check.sh` → 1341 path references checked: 0 missing, 41 planned.

**Deviations (recorded; contract amended where it named paths):**
1. **Sibling-root layout.** Extension-only files live in `native/TradeReadyWidgets/`, not
   `N/Widgets/` (the P3 fallback). Xcode 26.6 exception sets ignore folder and glob
   paths. The contract §5.4 and §8 amendments and the 11.02/11.03 Own lists were
   updated.
2. **Scrubber lock refactor.** `NativeAppGroupAccountScrubber` now takes the lock through
   the shared `WidgetAppGroupLock`, and its error mapping is unchanged. This leaves one
   lock implementation for 11.04 and 11.05.
3. **Extra writer gate.** `widgetMirrorOwnerBinding` also returns nil across the sign-out
   and delete scrub window. During `await subscriptionService.logOut()`, `O` is still
   set and memory still holds the old account's records. The predicate is still §2.5;
   this only closes a window where it would be stale.
4. **Coalescing and dedupe.** Canonical-write triggers are coalesced to one write per
   main-actor turn. Every trigger except the launch-time install skips a write whose
   content is unchanged while the stored copy is under 1 hour old. The foreground,
   background and seam triggers became non-forced in fix round 1. A copy an hour old or
   older is always rewritten, so `updatedAt` never nears the 24-hour window while the
   app is in use.
5. **Empty start time.** An empty `scheduledStartTime` projects as `null`. When neither
   job has a time, ties keep input order; RN's comparator is inconsistent in that case.
6. **Stale rule in the schema.** `isStale` is implemented in the shared schema so 11.02
   and 11.05 share one rule.
7. **Placeholder widget.** It exists only because a bundle needs a widget. It shows no
   account data.
8. **Version keys.** `native/Info.plist` now reads `$(MARKETING_VERSION)` and
   `$(CURRENT_PROJECT_VERSION)` (still 1.0 and 1), so the app and the extension cannot
   drift apart.

**Runsheet rows (Phase 12; not run, not claimed):**
- The extension installs, and the placeholder or real widgets appear in the gallery.
- A signed-in app writes `widgetSnapshot` into the real App Group container, and
  timelines refresh.
- Sign-out and delete empty the container and blank the widgets.
- The privacy manifest is present in the archived `.appex` (12.01).

**Concerns:**
- Nested synchronized roots (`N/Widgets/Shared/` is both inside the app root and its own
  extension root) are verified with `xcodebuild` only. Behavior in the Xcode IDE file
  inspector was not checked.
- A timer whose `end` is `""` is treated as not running natively. This is the existing
  `NativeTimeTracking.activeSession` behavior, and RN would show it as running.

**Next ready:** 11.04 (App Intents and the action queue; it uses `WidgetAppGroupLock` and
the owner tag) and 11.02 (Next Job widget). 11.03 needs 11.04, and 11.05 needs 11.01–11.04.

**Fix round 1 (2026-09-23, task review of c35c248):**
- **I1 (seam rollback).** The seam write could overwrite a newer local write with the
  older canonical captured before `notifySynchronize`.
  - Fix (controller ruling, contract §3.2 amendment): `snapshot.didSet` bumps
    `canonicalWriteRevision`. The new `AppStore.publishDerivedState(expectedOwnerBinding:)`
    records the revision it captured, and all three AppStore publish sites now call it.
  - `writeWidgetMirrorFromSeam` projects the live snapshot when the revision moved on,
    and the delivered canonical otherwise. `lastWidgetSeamSource`
    (`NativeWidgetSeamSource`) records which one it used, for tests.
- **Minor (duplicate writes per pass).** The seam write is non-forced. The foreground and
  background trigger-2 writes are non-forced too: both run after the pass's seam write,
  so making only the seam non-forced would still leave one duplicate write and reload
  per pass. §3.3 is still met, because the 1-hour dedupe rewrites any copy that old.
- **Test.** `testSeamProjectsNewestCanonical` in `native/WidgetSnapshotTests/main.swift`
  uses a fake `notifySynchronize` that suspends, and clocks in during the suspension.
  It asserts:
  - the resumed seam keeps the timer and projects the live snapshot;
  - the delivered path writes (and reloads once) when nothing moved on;
  - an unchanged follow-up publish neither writes nor reloads;
  - a mismatched owner is refused.
- **Mutation checks:**
  - moved-on detection disabled → 4 failures, including the timer dropped;
  - seam forced → 2 failures (the dedupe tests).
  The source was restored byte-identical.
- **Commands:**
  - `TZ=America/Phoenix sh native/run-widget-snapshot-tests.sh` → passed;
  - `sh native/run-store-integration-tests.sh` → PASS;
  - `sh native/run-background-refresh-tests.sh` → passed;
  - `sh native/run-phase10-qualification-tests.sh` → passed;
  - Release generic `xcodebuild` → BUILD SUCCEEDED, with only the 7 pre-existing
    warnings;
  - `sh native/run-doc-reference-check.sh` → 1342 path references checked: 0 missing, 41 planned.
- **Deferred by the controller (not addressed):** `flock` on the main actor, the
  visibility of the raw binding accessor, the scrub-race test's manual wipe, and the
  second `lockFileName` constant (→ 11.05).

### 11.04 — App Intents, Siri, and the action-queue contract (2026-09-23)

**Status:** Done (code complete). All ten intents exist once each, the eight Siri
shortcuts carry the §5.2 phrases, and every queue write follows §4.3 under the single §4.2
lock. Host tests prove that every action the intents write passes the real
`NativeWidgetActionBatchPlanner`, and that it replays through `NativeWidgetActionReplayer`.
Siri, device and extension proof are deferred to Phase 12. They were not claimed as passed.

**Files:**
- New, compiled into both targets (`N/Widgets/Shared/`):
  - `N/Widgets/Shared/WidgetActionQueue.swift`: `WidgetIntentEngine`, which holds all intent
    policy and is Foundation-only;
  - `N/Widgets/Shared/WidgetIntents.swift`: `StartTimerIntent` and `StopTimerIntent`.
- New, app only:
  - `N/NativeAppIntents.swift`: `TradeReadyShortcuts`, the single `AppShortcutsProvider`;
  - `N/Intents/JobActionIntents.swift`: seven Siri intents plus `SiriExpenseCategory`
    (§5.3);
  - `N/Intents/OnMyWayIntent.swift`;
  - `N/Intents/SiriIntentDialogs.swift`: the spoken text;
  - `N/Intents/NativeIntentURLRouter.swift`: the in-process hand-off to `AppStore.handle(url:)`.
- Edited: `N/TradeReadyNativeApp.swift` installs the router after the widget mirror.
- Tests: `native/AppIntentQueueTests/main.swift` and `native/run-app-intent-queue-tests.sh`
  (both new). The runner is registered in `native/run-all-domain-tests.sh`.

**Behavior:**
- Stale rule (§3.3):
  - Next Job, Clock In, On My Way and Outstanding refuse a snapshot older than 86,400 s
    ("Open TradeReady to refresh your schedule.");
  - Clock Out, Start Trip, Stop Trip and Log Expense are not refused;
  - a `nextJob` dated before local today is never "next".
- Owner rule (§4.5):
  - every writer reads the snapshot's `ownerTag` inside the same lock hold as its write;
  - with no snapshot or no tag it refuses ("Open TradeReady and sign in first.") and writes
    nothing;
  - the extension never derives a tag.
- Writer rules (§4.3):
  - refuse at 512 entries;
  - an exact duplicate id is an idempotent success, and a differing duplicate fails;
  - a malformed queue is never overwritten;
  - the new action is validated before the append;
  - existing entries keep their exact bytes (the new entry is spliced in).
- Trip session (§4.4): `activeTrip` is stamped with the owner. Stop persists
  id/stopAt/odometerEnd first, appends, and then removes the session. A session older than
  86,400 s is replaced on start or discarded on stop, and never logged. A session belonging
  to another owner (or an untagged one) is discarded.
- Read-only intents: Next Job and Outstanding read only `widgetSnapshot`, take no lock
  and write nothing.
- On My Way:
  - it stashes `{url, at, ownerTag}` to `pendingOpenUrl` in the same lock hold as the
    snapshot read;
  - it opens the app, and the router calls `AppStore.handle(url:)`, which presents the
    existing editable `NativeOnMyWayReviewView`;
  - nothing is ever sent automatically.

**Interface handoff:**
- **11.03 (Job Timer widget):** use `Button(intent: StartTimerIntent(jobId:))` and
  `StopTimerIntent`. Both reload timelines outside the lock only when the queue was written
  (`WidgetIntentTimelines.reloadIfNeeded`).
- **11.05:**
  - the writer only appends actions for this owner, so replay gating can rely on
    `ownerTag`;
  - an untagged or foreign queued `timer_start` is ignored by the "on the clock" check;
  - replay is still migrated-only (`replayVerifiedWidgetActionsIfPossible`);
  - the second `lockFileName` constant is still open.
- **11.06:**
  - the stash is also written on the warm route (the direct router path), so a consumer that
    runs on every activation should clear or dedupe it rather than show the review twice;
  - the existing consumer ignores the extra `ownerTag` key, and the owner gate is 11.06's to
    add.

**Commands:**
- `TZ=America/Phoenix sh native/run-app-intent-queue-tests.sh` → "App intent queue tests
  passed".
- Mutation checks, each restored byte-identical:
  - cap raised to 513 → 4 failures;
  - expense floor removed → 3 failures;
  - Clock In stale check removed → 2 failures;
  - trip owner check removed → 4 failures.
- Release generic `xcodebuild` (`CODE_SIGNING_ALLOWED=NO`) → BUILD SUCCEEDED, with no new
  warnings. The SwiftFileLists show both targets compiling `WidgetActionQueue.swift` and
  `WidgetIntents.swift`, and only the app compiling `Intents/` and `NativeAppIntents.swift`.
- `TZ=America/Phoenix sh native/run-all-domain-tests.sh` → exit 0; every runner passed.
- `sh native/run-doc-reference-check.sh` → 0 missing.

**Deviations:**
1. **Policy module.** Intent policy lives in `N/Widgets/Shared/WidgetActionQueue.swift`
   (Foundation-only), and the intents are thin wrappers. The brief's Own list did not name
   it, nor `SiriIntentDialogs.swift` or `NativeIntentURLRouter.swift`.
2. **Shared field rules.** The string rules (identifier, local date) live once, in
   `N/Widgets/Shared/WidgetActionFieldRules.swift`, and both the writer and the planner call
   them (see fix round 1). The numeric ranges stay on each side, because the planner is
   app-only (it depends on `Canonical.JSONValue` and CryptoKit) and uses `Decimal`. The tests
   run the writer's output and boundary vectors through the real planner, so the two sides
   cannot drift silently.
3. **Native bounds.**
   - Odometers are capped at 10,000,000 miles. Larger values decode as `Decimal` failures
     in the planner (at 1e128 and above), which would fail the whole batch.
   - Expense amounts must be at least 1e-19, the planner's floor.
   - RN had neither bound.
4. **Read failures.** Next Job and Outstanding say "couldn't check that" on a container
   failure, not "couldn't save".

**Runsheet rows (Phase 12; not run, not claimed):**
- All eight shortcuts appear in the Shortcuts app, and each §5.2 phrase triggers its intent
  through Siri.
- The Start/Stop timer buttons in the widget queue an action and the app replays it on
  foreground.
- Start Trip → Stop Trip through Siri logs one trip with the right miles, once.
- Log Expense through Siri shows the §5.3 category labels, and replays with the spoken
  amount.
- On My Way through Siri, cold and warm, opens the review sheet for the next job and sends
  nothing.
- After sign-out, every writing intent says "Open TradeReady and sign in first." and the
  container stays empty.

**Concerns:**
- On My Way takes the `flock` on the main actor for a brief hold. This is the same class of
  issue as the deferred 11.01 minor.
- `WidgetActionQueue.swift` is about 840 lines, which is larger than the plan implied.

**Next ready:** 11.03 (Job Timer widget; needs 11.01 and 11.04) and 11.02. 11.05 needs
11.02 and 11.03.

**Fix round 1 (2026-09-24, task review of 3ef7e88):**
- **I1 (duplicated planner rules).** New file
  `N/Widgets/Shared/WidgetActionFieldRules.swift` (Foundation-only, both targets). It holds
  the one copy of `isValidIdentifier`, `isValidLocalDate` and `maximumIdentifierLength`.
  - The planner's `validIdentifier` and `validLocalDate` now call it, and
    `NativeWidgetActionBatch.maximumIdentifierLength` aliases it. The writer calls it
    directly.
  - Choice: the planner adopts the stricter ASCII-digit date check. Before this, `Int(_:)`
    let signed pieces through, so `+026-08-03` was accepted as year 26. No writer has ever
    produced such a date (the RN writer used zero-padded digits), and there are no current
    users, so one strict rule costs nothing.
  - `native/run-appstore-sources-common.sh` and `native/run-widget-action-replay-tests.sh`
    compile the new file.
- **M2.** On a crash retry, Stop Trip no longer validates the new reading when a persisted
  `odometerEnd` exists. The persisted value is the one that gets logged.
- **M4.** `WidgetNextJobOutcome.nextJob` carries the engine's `now` and time zone, and
  `SiriIntentDialogs.nextJob` uses them. The spoken day therefore always matches the
  engine's upcoming check.
- **M5.** Removed the unused `import WidgetKit`.
- **M6.** The `AppEnum` display representations are now `static let`.
- **Tests (added to `native/AppIntentQueueTests/main.swift`):**
  - signed-date vectors, rejected by the writer, the shared rule and the planner;
  - accepted-date vectors;
  - the identifier cap is the shared one;
  - a source scan finding no second copy of the rules;
  - crash retry with NaN, 1e200 and -3 readings logs the persisted 540;
  - the outcome carries the engine clock and zone;
  - 23:59:59 local speaks "today", and 00:00:01 gives no upcoming job.
- **Mutation checks:**
  - reverting M2 → 3 failures;
  - removing the digit check → 6 failures.
  The sources were restored byte-identical.
- **Commands:**
  - `TZ=America/Phoenix sh native/run-app-intent-queue-tests.sh` → passed;
  - `sh native/run-widget-action-replay-tests.sh` → PASS;
  - Release generic `xcodebuild` → BUILD SUCCEEDED, and the `TradeReadyWidgets`
    SwiftFileList lists `WidgetActionFieldRules.swift`;
  - `TZ=America/Phoenix sh native/run-all-domain-tests.sh` → exit 0; every runner passed;
  - `sh native/run-doc-reference-check.sh` → 0 missing.

### 11.02 — Next Job widget (2026-09-24)

**Status:** Done (code complete). The widget renders both families from resolved policy
state only; state resolution, the deep-link URL and the timeline refresh date are pure
Foundation code with host-test coverage. Device layout proof (the widget on a real Home
Screen) is deferred to Phase 12 and was not claimed as passed.

**Files:**
- New, compiled into both targets (`N/Widgets/Shared/`):
  - `N/Widgets/Shared/NextJobWidgetPolicy.swift`: `NextJobWidgetState`
    (`.missing`/`.stale`/`.noUpcomingJob`/`.job`), `resolveState`, `deepLinkURL`,
    `nextRefreshDate`, `whenLabel` — all pure Foundation, all host-tested;
  - `N/Widgets/Shared/NextJobWidgetView.swift`: `NextJobWidgetView`, the small/medium
    rendering. It switches on the resolved state and adds no policy of its own.
- New, extension only (`native/TradeReadyWidgets/`):
  - `native/TradeReadyWidgets/NextJobWidget.swift`: `NextJobEntry`, `NextJobProvider`
    (`TimelineProvider`) and `NextJobWidget` (`StaticConfiguration`,
    `[.systemSmall, .systemMedium]`).
- Edited:
  - `native/TradeReadyWidgets/TradeReadyWidgets.swift`: the `@main WidgetBundle` now
    holds `NextJobWidget()`; the 11.01 placeholder widget/provider/view were removed
    (11.03 adds `JobTimerWidget()` to the same bundle body).
- Tests: `native/NextJobWidgetPolicyTests/main.swift` and
  `native/run-next-job-widget-tests.sh` (both new). The runner is registered in
  `native/run-all-domain-tests.sh` immediately after
  `run-widget-action-replay-tests.sh`.

**Behavior:**
- State resolution (§3.3), checked in this order: a nil snapshot (missing key or
  undecodable JSON — the 11.02 brief's "missing/blank") → `.missing`; `isStale(now:)` →
  `.stale`; no `nextJob`, or a `nextJob.scheduledDate` before local today (the
  "separately from staleness" rule) → `.noUpcomingJob`; otherwise `.job(nextJob)`.
- `.stale` and `.missing` render no customer name, address or job link — the whole card
  falls back to WidgetKit's default tap behavior (opens the app root) because
  `widgetURL` is nil for every state but `.job`.
- Deep link: `tradeready://job/<id>`, built by percent-encoding the exact projected id
  (with `/` excluded from the allowed set so an embedded `/` cannot smuggle a third path
  component) — never reformatted. A host test round-trips the generated URL through the
  real `NativeDeepLinkParser.parse` for a set of ids including `/`, `?`, `#`, `%`, a
  space, and non-ASCII characters.
- Timeline: one entry per `getTimeline` call. The reload policy is `.after(refreshDate)`
  where `refreshDate = min(updatedAt + 86_400, nextLocalMidnight)`, or `.never` when the
  snapshot is missing or already stale — matching the "no self-scheduled background
  work" requirement; the app's own mirror write still calls
  `WidgetCenter.shared.reloadAllTimelines()` (§3.1) whenever it has fresher data.
- `whenLabel` ports RN's `whenLabel` (`targets/widget/Widgets.swift:75-92`) with `now`
  injected instead of read live, so "Today"/"Tomorrow"/`"EEE, MMM d"` are host-testable;
  an unparseable `scheduledDate` falls back to the raw string.

**Commands and results:**
- `TZ=America/Phoenix sh native/run-next-job-widget-tests.sh` → "Next Job widget policy
  tests passed". Covers:
  - `.missing` for a nil snapshot;
  - the §3.3 boundary: 86,399 s and exactly 86,400 s fresh, 86,401 s stale, a negative
    age (future `updatedAt`) stale, an unparseable `updatedAt` stale;
  - the "separately from staleness" rule: a fresh snapshot with no `nextJob`, with a
    yesterday-dated `nextJob`, a today-dated one, and a future-dated one; and that
    staleness is checked before the scheduledDate rule;
  - the deep-link round trip through the real `NativeDeepLinkParser` for 8 ids
    (including `/`, `?`, `#`, `%`, a space and non-ASCII characters), an empty id
    producing no link, and the exact unencoded-id URL string;
  - `nextRefreshDate`: nil for a missing or already-stale snapshot; the next local
    midnight winning when earlier than `updatedAt + 86,400`; and `updatedAt + 86,400`
    winning when earlier than the next local midnight (the contract's literal case),
    with a sanity assertion that it is exactly 1 hour after `now`;
  - `whenLabel`: today-with-time, tomorrow-without-time, a later date's `"EEE, MMM d"`,
    a later date with time, and the unparseable-date fallback.
- `xcodebuild -project native/TradeReadyNative.xcodeproj -scheme TradeReadyNative -configuration Release -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build`
  → `** BUILD SUCCEEDED **`, 7 pre-existing warnings, none in new files. The
  `TradeReadyWidgets` SwiftFileList is exactly `NextJobWidget.swift`,
  `TradeReadyWidgets.swift`, and the `Widgets/Shared/*.swift` files (including
  `NextJobWidgetPolicy.swift` and `NextJobWidgetView.swift`); the app's SwiftFileList
  has the two `NextJobWidget*` Shared files too, and neither `NextJobWidget.swift` nor
  `TradeReadyWidgets.swift`.
- `TZ=America/Phoenix sh native/run-all-domain-tests.sh` → exit 0; every runner passed,
  including `run-next-job-widget-tests.sh` (individually confirmed passing; the
  aggregate's `set -eu` would have halted before the later runners and the
  `backend-workers` `npm test` tail on any failure).
- `sh native/run-doc-reference-check.sh` → 0 missing (see the plan-wide count in this
  entry's closing command).

**Deviations:**
1. **Placeholder removed, not layered.** The 11.01 doc comment said "11.02 and 11.03
   replace [the placeholder]," implying both. Since a `WidgetBundle` only needs one
   widget and `NextJobWidget` already satisfies that, this task removed the placeholder
   outright rather than carrying it alongside `NextJobWidget` until 11.03 lands.
   `TradeReadyWidgets.swift`'s comment now points 11.03 at the same bundle body.
2. **`whenLabel` takes an injectable `Locale?`.** RN's formatters use the device locale
   implicitly; the native port adds an optional `locale` parameter (default nil = device
   locale) purely so the host test can pin `en_US_POSIX` for a deterministic time
   string. Production call sites never pass it.
3. **Defensive `scheduledDate` re-check.** §3.3's "separately from staleness" rule is
   re-implemented in `NextJobWidgetPolicy` with a small local `localDateString` helper,
   duplicated in miniature from `N/Domain/NativeWidgetSnapshot.swift` (app-target only)
   because the widget's policy file must compile into the extension too.

**Runsheet rows (Phase 12; not run, not claimed):**
- Both widget families (small, medium) appear correctly sized and legible in the
  gallery and on a Home Screen.
- Tapping a `.job` card opens the app at the linked job; tapping any other state opens
  the app root.
- The widget shows the stale state after 24 hours with the app closed, and recovers on
  the next app-triggered reload.

**Concerns:** none.

**Next ready:** 11.03 (Job Timer widget; needs 11.01 and 11.04, done) and 11.05 (needs
11.02 and 11.03).

### 11.03 — Job Timer widget (2026-09-24)

**Status:** Done (code complete). The widget renders from resolved policy state only;
state resolution (including the owner-tagged pending-action precedence), the deep-link
fallback URL and the timeline refresh date are pure Foundation code with host-test
coverage. It uses 11.04's `StartTimerIntent`/`StopTimerIntent` as-is and defines no
`AppIntent` type of its own. Device layout/interactivity proof (the widget on a real
Home Screen) is deferred to Phase 12 and was not claimed as passed.

**Files:**
- New, compiled into both targets (`N/Widgets/Shared/`):
  - `N/Widgets/Shared/JobTimerWidgetPolicy.swift`: `JobTimerWidgetState`
    (`.missing`/`.running`/`.pendingStop`/`.pendingStart`/`.idle`/`.noJob`/
    `.syncNeeded`), `resolveState`, `lastPendingTimerType`, `deepLinkURL`,
    `nextRefreshDate` — all pure Foundation, all host-tested;
  - `N/Widgets/Shared/JobTimerWidgetView.swift`: `JobTimerWidgetView`, the small/medium
    rendering. `Button(intent: StartTimerIntent(jobId:))` /
    `Button(intent: StopTimerIntent(jobId:))` (11.04, same folder) are the only writes;
    the live elapsed time is `Text(since, style: .timer)`. The view switches on the
    resolved state and adds no policy of its own.
- New, extension only (`native/TradeReadyWidgets/`):
  - `native/TradeReadyWidgets/JobTimerWidget.swift`: `JobTimerEntry`, `JobTimerProvider`
    (`TimelineProvider`) and `JobTimerWidget` (`StaticConfiguration`,
    `[.systemSmall, .systemMedium]`).
- Edited:
  - `native/TradeReadyWidgets/TradeReadyWidgets.swift`: the `@main WidgetBundle` body now
    holds `NextJobWidget()` and `JobTimerWidget()`.
- Tests: `native/JobTimerWidgetPolicyTests/main.swift` and
  `native/run-job-timer-widget-tests.sh` (both new). The runner is registered in
  `native/run-all-domain-tests.sh` immediately after `run-next-job-widget-tests.sh`.

**Behavior:**
- State resolution precedence (highest first), matching RN `JobTimer.swift`'s
  `JobTimerState`/`lastPendingTimerType` plus the native-only staleness rule (§3.3):
  1. no snapshot (missing key or undecodable JSON) → `.missing`;
  2. the most recent owner-tagged queued timer action for this snapshot's `ownerTag`
     (§4.5 "last one wins", filtered to this owner because replay drops every other
     entry unapplied) → `.pendingStop` / `.pendingStart`;
  3. `snapshot.timer` present → `.running(timer, since:)`, **even when the snapshot is
     stale** (§3.3: "a running timer stays visible and Stop stays enabled");
  4. stale with no timer → `.syncNeeded` ("Open app to sync"; the idle Start button is
     suppressed even when a `nextJob` is present, per §3.3);
  5. fresh with no timer: an upcoming `nextJob` (§3.3's "separately from staleness"
     scheduledDate rule, same as 11.02) → `.idle(job)`, else `.noJob`.
- `Button(intent: StopTimerIntent(jobId:))` stays present (and thus tappable) for both
  `.running` cases — fresh and stale — matching §3.3; `WidgetIntentEngine.stopTimer`
  itself already allows a stale snapshot (11.04), so the button is never wired to a
  refusal path.
- Deep link fallback (§6.1): `.running` links its own job, `.idle` links the upcoming
  job, every other state opens the app root (`widgetURL` nil, WidgetKit's default).
  Reuses `NextJobWidgetPolicy.deepLinkURL(jobID:)` — no second encoder.
- `nextRefreshDate` calls `NextJobWidgetPolicy.nextRefreshDate` directly: the
  staleness-deadline/next-midnight math is snapshot-generic, not Next-Job-specific, so
  this is reuse, not a second implementation.
- Timeline: `.never` unless a refresh date is scheduled, exactly like 11.02. A button tap
  additionally reloads timelines itself via 11.04's `WidgetIntentTimelines.reloadIfNeeded`
  (outside the lock); the live countup needs no new entry (`Text(_:style:.timer)`).

**Commands and results:**
- `TZ=America/Phoenix sh native/run-job-timer-widget-tests.sh` → "Job Timer widget tests
  passed". Covers:
  - `.missing` for a nil snapshot;
  - a running timer stays `.running` at both a fresh and a stale `updatedAt` (§3.3);
  - stale with no timer is `.syncNeeded` whether or not a `nextJob` is present, and
    exactly 86,400 s stays fresh (11.02 boundary parity);
  - `.idle` for a fresh snapshot with an upcoming job, `.noJob` for no job and for a
    yesterday-dated job (the "separately from staleness" rule);
  - owner-tagged pending-action precedence: a queued stop overrides a running snapshot,
    a queued start overrides an idle snapshot, a foreign-owner-tagged action is ignored,
    and "last one wins" both directions (start-then-stop, stop-then-start);
  - `lastPendingTimerType` degrades to nil (not a crash) for a malformed queue, a nil
    queue, or a nil owner tag;
  - the deep-link fallback for `.running` and `.idle` round-trips through the real
    `NativeDeepLinkParser.parse` to the expected job id; every other state produces no
    link;
  - `nextRefreshDate` matches `NextJobWidgetPolicy.nextRefreshDate` exactly (same
    delegated call) and is nil for a missing snapshot;
  - start and stop each produce exactly one `timer_start`/`timer_stop` action, driven
    through the real 11.04 `WidgetIntentEngine` (not a reimplementation) and accepted by
    the real `NativeWidgetActionBatchPlanner.prepare` (`batch.actions.map(\.kind) ==
    [.timerStart, .timerStop]`);
  - a double tap (same fixed action id) on Start, and separately on Stop, is idempotent:
    the second `WidgetIntentEngine` call returns `.alreadyQueued`, the queue holds
    exactly one entry, and that entry alone still plans successfully.
- `xcodebuild -project native/TradeReadyNative.xcodeproj -scheme TradeReadyNative -configuration Release -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build`
  → `** BUILD SUCCEEDED **`, 0 errors (pre-existing warnings elsewhere in the tree, none
  in the new files). The `TradeReadyWidgets` SwiftFileList includes
  `JobTimerWidget.swift`, `NextJobWidget.swift`, `TradeReadyWidgets.swift`, and the
  `Widgets/Shared/*.swift` files (including `JobTimerWidgetPolicy.swift` and
  `JobTimerWidgetView.swift`); the app's SwiftFileList has the two `JobTimerWidget*`
  Shared files too, and neither `JobTimerWidget.swift` (the extension-only provider) nor
  `TradeReadyWidgets.swift`.
- `TZ=America/Phoenix sh native/run-all-domain-tests.sh` → exit 0; every runner passed,
  including `run-job-timer-widget-tests.sh` and `run-next-job-widget-tests.sh`
  (individually confirmed passing above; the aggregate's `set -eu` would have halted
  before the later runners and the `backend-workers` `npm test` tail on any failure).
- `sh native/run-doc-reference-check.sh` → 0 missing.

**Deviations:**
1. **Two native-only states beyond RN's five.** RN's `JobTimerState` has no concept of a
   stale mirror (it never reads `updatedAt`). This task adds `.missing` (parity with
   11.02's own addition) and `.syncNeeded` (§3.3's stale-with-no-timer rule) on top of
   RN's `running`/`pendingStop`/`pendingStart`/`idle`/`empty` (renamed `.noJob` here for
   clarity against `.noUpcomingJob` in the sibling widget).
2. **Pending-action read is owner-tag filtered, unlike the plain RN `lastPendingTimerType`.**
   RN's version has no owner concept and simply reads the last queued timer type. The
   native version only counts entries whose `ownerTag` matches the snapshot's, because
   §4.5 makes an untagged or foreign-tagged action one that replay will drop unapplied —
   counting it as "pending" would show a state the app will never actually reach.
3. **`isUpcoming`'s local-date compare is duplicated a third time.** It now exists in
   `WidgetIntentEngine.upcomingJob` (11.04, private), `NextJobWidgetPolicy` (11.02, its
   own case) and here — each a small, two-line, Foundation-only compare, and no existing
   file is a shared, cross-target home for it. Noted rather than introduced as a new
   shared file, per the brief's "one clear responsibility per file" and YAGNI guidance;
   flagged here in case a later task wants to consolidate it.

**Runsheet rows (Phase 12; not run, not claimed):**
- Both widget families (small, medium) render correctly sized and legible in the gallery
  and on a Home Screen, in every one of the seven states.
- Tapping Start/Stop on a real device queues the action, the widget shows the pending
  state within one reload, and the app replays it into canonical state on next
  foreground/launch.
- A double tap on a real device (two rapid taps before the first reload lands) never
  produces two applied timer transitions.
- The widget shows the stale-but-running and stale-with-no-timer states after 24 hours
  with the app closed, and recovers on the next app-triggered reload.
- The whole-card fallback tap (when interactive widgets are unavailable, e.g. StandBy)
  opens the correct job or the app root.

**Concerns:** none.

**Next ready:** 11.05 (needs 11.01–11.04, done, and now also 11.02/11.03's UI-side stale
handling as prior art).

### 11.05 — Widget/Siri owner gating and stale/sign-in correctness (2026-09-24)

**Outcome:** code complete for W4. Items 1–3 are closed in the app target and proven by
host fixtures against the real `AppStore`, replay coordinator, claim transport,
`NativeAppGroupAccountScrubber`, `NativeWidgetMirror` and the extension's
`WidgetIntentEngine`. Item 4 (a widget deep link opened while signed out) is proven
route-or-discard against the **existing** routing; "routes after sign-in" for a
cold-launch link needs 11.06 (see the handoff below). Device/Siri/widget proof is
deferred to Phase 12 and was not claimed.

**Files:**
- New: `native/TradeReadyNative/NativeWidgetOwnerGate.swift` — `NativeWidgetOwnerTag`
  (moved here unchanged from `Domain/NativeWidgetSnapshot.swift`, plus `matches`) and
  `NativeWidgetReplayOwnerGate.replayBinding` (O + `.signedIn` + no open account boundary).
- Edited: `native/TradeReadyNative/NativeWidgetActionReplay.swift` (planner owner gate,
  C8 quarantine, one lock, old-binding discard, archived-job refusal, diagnostics),
  `native/TradeReadyNative/AppStore.swift` (replay gate on O, `scrubWidgetAccountState()`,
  diagnostics, two test seams), `native/TradeReadyNative/Domain/NativeWidgetSnapshot.swift`.
- Tests: new `native/WidgetOwnerGatingTests/main.swift` and
  `native/run-widget-owner-gating-tests.sh` (registered in `native/run-all-domain-tests.sh`
  after the Job Timer runner). Fixtures in `native/WidgetActionReplayTests/main.swift`,
  `native/AppIntentQueueTests/main.swift` and `native/JobTimerWidgetPolicyTests/main.swift`
  now carry the owner tag (untagged entries are dropped by design); their runners and
  `native/run-appstore-sources-common.sh` compile the new file.

**Behavior:**
- **Write gate (item 1, §3.1):** every account scrub — sign-out, deletion, retry and
  launch recovery — goes through one `scrubWidgetAccountState()`: wipe the App Group
  suite under the shared lock, reload timelines **immediately** (before any later scrub
  step or the `logOut` await), then remove the app-private replay claims and quarantine
  files. The trailing reloads after `logOut` were removed. The snapshot writer was already
  on O (11.01) and is re-proven for every gate and for missing/unfinished/foreign workspaces.
- **Replay gate (item 2, §2.5/C22):** `widgetActionReplayBinding` = O
  (`derivedStatePublishBinding`) **and** `.signedIn` **and** no open boundary (mirror
  suspended, scrub blocked or pending). The migrated-only requirement is gone, so a
  native-only account replays. The binding is re-checked before every claim.
- **Owner-tag gate (§4.5):** the planner drops (and acknowledges) every entry that is
  not an object or whose `ownerTag` is not exactly `hash(O)`, before id/type/field
  validation and duplicate detection. Untagged and foreign unknown types are dropped;
  only owner-tagged unknown types are retained. Counts go to the in-memory
  `NativeWidgetActionReplayDiagnostics` (no ids, no payloads).
- **C8 quarantine:** a queue the owner can never prepare (malformed JSON, not an array,
  over 512 entries, an owner-tagged malformed/duplicate/invalid action) is re-read and
  re-prepared under the lock; if it still fails, its exact bytes (or only digest and size
  above 1 MiB) are written to an owner-scoped `quarantine-<binding>-<digest>.json` in the
  claims directory (at most 4 per owner, oldest evicted), and only then is the shared
  queue cleared. The app shows "Some widget or Siri actions couldn't be read and were set
  aside." A corrupt claim file is still `invalidClaim` (never quarantined), and a queue
  that became valid between the two holds is claimed normally.
- **Stale and missing records (item 3, §3.3):** the engine's stale refusals and the
  widgets' stale states are fixture-proven at 86,399/86,400/86,401 s, negative age and
  unparseable `updatedAt`. Replay re-resolves the exact job id and ignores a start for a
  missing, done or **archived** job (archived is a native deviation: RN does not check
  it) and a stop for a missing job; `handle(url:)` discards a link to a missing id.
- **One lock (deferred 11.01 minor):** the claim transport's own `flock` and lock-file
  constant are removed; it uses `WidgetAppGroupLock` on `WidgetAppGroup.lockFileName`.

**Decision — in-flight claims keyed by an old binding:** they are discarded, unread.
`claim()` deletes, under the shared lock, every claim and quarantine file keyed by any
binding other than the replaying O before it reads its own; and every account scrub
removes the whole claims directory, because those files hold the scrubbed owner's
actions. An old-binding claim is never replayed into a new owner and never kept for a
later sign-in of the old owner (no current users: correctness over continuity).

**Commands and results:**
- `TZ=America/Phoenix sh native/run-widget-owner-gating-tests.sh` → "Widget owner gating
  tests passed" (stable over 6 further runs). Includes the real scrubber race both ways
  (writers blocked behind the scrubber's lock refuse with `signInRequired`; a mid-append
  writer finishes first and the scrub then wipes its action).
- Mutation checks (each applied, run, restored and verified with `cmp`), all killed:
  migrated-only gate (19 failures), no `.signedIn` requirement (15), owner filter
  removed (9), quarantine removed (6), reload deferred past the `logOut` await (2),
  reload before the scrub (3), old-binding discard removed (1), archived check removed
  (1), claims removal removed (3).
- Also passing with `TZ=America/Phoenix`: widget-action-replay, app-intent-queue,
  store-integration, widget-snapshot, job-timer-widget, next-job-widget,
  app-group-pending-open-url.
- `xcodebuild ... -configuration Release -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build`
  → `** BUILD SUCCEEDED **`.
- `TZ=America/Phoenix sh native/run-all-domain-tests.sh` → exit 0.
- `sh native/run-doc-reference-check.sh` → 0 missing.

**Deviations:**
1. Replay ignores a timer start on an archived job (RN has no archived check).
2. The claims-directory removal during a scrub takes no lock: the directory is
   app-private and only the main actor replays.
3. Quarantine covers the whole queue per owner, not individual entries (C8 left the
   granularity open; per-entry would need a second parser for a queue that does not parse).

**Handoff to 11.06 (item 4 — required before "routes after sign-in" holds):**
- `consumeVerifiedPendingOpenURLIfNeeded` is still gated on the migrated owner and runs
  once per session, so a cold-launch stash never routes for a native-only account.
  Switch it to O + `.signedIn` and drop the once-per-session flag.
- `NativePendingOpenURLConsumer` has no `ownerTag` check and does not take the lock or
  remove the stash. Today a foreign stash is unreachable only because the scrub wipes it
  and the writer reads the snapshot inside its lock hold. Add the `hash(O)` check and the
  in-lock read-and-remove (§6.2).
- `handle(url:)` has no auth, owner or archived gate and no parking. The 11.05 fixtures
  assert only route-or-discard (a kept route must be the exact id in the current owner's
  data; an account boundary clears it), so they stay valid when 11.06 adds parking.
- `useAnotherAccount` keeps `deepLinkedJobID` and `pendingOnMyWayJobID` from the
  previous session (a link parked while signed out survives the account switch). The
  11.05 fixture reports this as a known gap and does not assert it. 11.06 must clear or
  owner-scope every held route at each account boundary (`signOut` already clears them
  in `applyCompletedSignOutState`).
- `handle(url:)` parks the exact id while signed out today (no auth gate); the fixture
  pins that exact behavior, so 11.06's parking change will update it deliberately.

**Runsheet rows (Phase 12; not run, not claimed):**
- Sign out on a device with widgets on the Home Screen: both widgets clear within one
  reload; Siri "Clock in" answers with the sign-in prompt.
- Sign in as a second account: widgets show only that account's data; a widget action
  queued by the first account is never applied.
- A widget/Siri action with a deleted or archived job, and a widget left 24 h without
  the app, fail closed with no wrong-record route.

**Concerns:** item 4's "routes after sign-in" for cold links depends on 11.06.

**Fix round 1 (2026-09-24):**
- **I1 — account switch is an App Group boundary:** `useAnotherAccount` now suspends
  the mirror and replay, and after `clearSession` runs the same
  `scrubWidgetAccountState()` (wipe, immediate timeline reload before the `logOut`
  await, claims removal), then resets the per-owner replay diagnostics. A wipe failure
  does not keep the cleared owner in memory; it is counted
  (`accountSwitchScrubFailureCount`). The local workspace is retained. The earlier
  "`useAnotherAccount` does not scrub" note is superseded.
- **I2 — deep-link fixture asserts exact behavior:** signed out with retained data, a
  link parks exactly `j1` (a missing id never redirects it); the **real** `signOut`
  clears both route fields and B signing in afterwards gets no route; the real
  `useAnotherAccount` path is driven, and its surviving route fields are reported as a
  known 11.06 gap (handoff above), never asserted as correct; the same owner returning
  gets exactly `j1` resolving to A's record.
- **M-archived:** recorded in the contract §4.6 as a native difference (and C8 marked
  resolved there).
- **M-mainactor:** `NativeWidgetActionClaimTransport.removeAllAccountClaims()` is
  `@MainActor`.
- **M-matches:** the planner compares through `NativeWidgetOwnerTag.matches` (the one
  comparison).
- **Tests:** new fixture `testUseAnotherAccountScrubsWidgetState` drives the real
  `useAnotherAccount` (suite empty and timelines reloaded before `logOut`, no snapshot,
  trip or stash for A, NextJob/Outstanding/StopTrip refuse, claims removed, diagnostics
  reset); source scan now expects 4 `scrubWidgetAccountState()` call sites and exactly
  one `reloadAllTimelines()`.
- **Harness:** `native/StoreIntegrationTests/main.swift`'s `seed08Store` now injects a
  throwaway App Group suite and lock file. Its real `useAnotherAccount()` fixtures now
  reach the App Group wipe, and the default scrubber would have touched the real
  container on the developer Mac (the run blocked in `WidgetAppGroupLock` there).
- **Mutation checks (17, all killed):** the 9 earlier ones plus: switch wipe removed
  (12 failures), switch wipe moved after `logOut` (3), switch suspension removed (6),
  switch diagnostics reset removed (1), `signOut` keeping the job route (2) or the On My
  Way route (2), and case-insensitive `matches` (3).
- **Commands:** widget-owner-gating, widget-action-replay, app-intent-queue,
  store-integration and job-timer-widget runners pass with `TZ=America/Phoenix`; Release
  generic `xcodebuild` → `** BUILD SUCCEEDED **`; `sh native/run-doc-reference-check.sh`
  → 0 missing.

**Next ready:** 11.06 (deep-link routing and auth gates; the owner-gate API it needs is
`NativeWidgetOwnerTag.matches` and O).
