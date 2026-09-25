# Phase 11 — Subagent Implementation Plan

**Date:** 2026-09-21

**Status:** 11.00 contract frozen (2026-09-23); 11.01 and 11.04 done (2026-09-23); 11.02, 11.03, 11.05, 11.06, 11.07, 11.08, 11.09, 11.15, 11.10a, 11.11 and 11.12 done (2026-09-24); 11.10b done (2026-09-24; A29 fixed after the controller ruling, H1 closed); 11.13 and 11.14 pending. See §7.
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
| 11.06 | L1, L2 | Done (code complete 2026-09-24; C11/P8 resolved; device proof deferred to Phase 12) | 11.00, 11.05 (owner-gate API) | Deep-link routing + auth gates |
| 11.07 | P1, P4 | Done (code complete 2026-09-24; PostHog iOS 3.81.0 linked, app target only; no key committed, so analytics is off until a release key is supplied; device proof deferred to Phase 12) | 11.00 | Analytics transport + privacy |
| 11.08 | P2, P3 | Done (code complete 2026-09-24; all 52 catalog events have typed constructors, 49 wired (the booking push opens await native push; `tax_settings_saved` is unreachable until a native tax-settings editor exists); identity lifecycle and m1–m3 fixed; device proof deferred to Phase 12) | 11.07, 10.15 | Event parity + identity lifecycle |
| 11.09 | R1, R2, R3, M1 | Done (code complete 2026-09-24; Sentry Cocoa 9.29.0 linked, app target only; no DSN committed, so crash reporting is off until a release DSN is supplied; app manifest written; dSYM upload script for `tradeready-3r/tradeready-ios`; device proof deferred to Phase 12) | 11.07 | Crash reporting + redaction + app manifest |
| 11.15 | P4, R2 | Done (code complete 2026-09-24; Groq/Anthropic key entry behind RN's "Advanced" switch, Keychain-only through `NativeKeychainSecureSettingsStore`, owner-wiped with migrated keys at sign-out, deletion, account switch and password-recovery exits (fix round 1); live provider proof deferred to Phase 12) | 11.00, 11.09 | Settings › AI Assistant advanced key entry |
| 11.10a | H1 | Done (code complete 2026-09-24; all four §12 release-blocking candidates fixed and host-tested (contract §12.1); hardware keyboard handed to 11.11; A15–A18, A22 and A24 to 11.10b; fix round 1 closed I1–I3 and m1–m6; VoiceOver/Switch Control/AX5 proof deferred to Phase 12; H1 stays open until 11.10b) | 11.00, 10.15 | Accessibility audit + fixes |
| 11.11 | H2 | Done (code complete 2026-09-24; RN `contentColumn` (700pt) on all 58 scroll roots and 12 fixed-chrome sites, measured on the Simulator; one `TabView`, no split view, no pushed `NavigationStack`; multitasking manifest checked unchanged; §12.1 A11 hardware-keyboard shortcuts done (contract §12.2); Split View/Slide Over/Stage Manager/rotation/keyboard proof deferred to Phase 12) | 11.10a | iPad layouts + multitasking |
| 11.12 | H3, H4 | Done (code complete 2026-09-24; eight privacy-safe `OSSignposter` intervals (launch, snapshot load, migration, initial sync, delta pull, background refresh, two list projections) behind a pinned call-site inventory; poor-network suite over the real coordinator, queue, push, pull and AppStore commit: offline→online, throttle/timeout, mid-pass drop, 5/5 mutations caught; one data-loss finding (an edit saved during an in-flight delta pull was reverted by the pull commit and could be lost), **fixed in fix round 1 (`36a08dc`) and round 2 (`22f35fd`, review I1: a push acknowledged during a direct-caller pull)**: the pull commit rebases onto the live snapshot and takes the server's version only for records the device has not touched (pending at start or commit, or changed locally), holding a table's cursor where it keeps a local record over a fetched row, with scenarios D–G and table-driven merge cases running by default (229 checks; see §7); measurement and soak protocol with Phase 12 owners in [performance](native-phase-11-performance.md); device numbers deferred to Phase 12 Stage A) | 11.10a, 11.11 | Performance + poor-network host tests + soak protocol |
| 11.10b | H1 | Done (code complete 2026-09-24). The re-audit after 11.11 and 11.12 is done (contract §12.3). A13, A15–A18 and A24–A29 are fixed, A22 is accepted with a rationale, and the scanner covers all 59 view files. A29 (success, warning and status colors as text) is fixed with native text tokens after the controller ruling. Fix round 1 fixed the 12 in-row destructive buttons (I1) and minors m1–m7. A30 (PDF stamps) is owned by 11.13 and A31 (system dialogs) is accepted. **H1 is closed:** zero release-blocking findings remain. VoiceOver, Switch Control and AX5 proof is deferred to Phase 12 | 11.11, 11.12 | Accessibility re-audit (closes H1) |
| 11.13 | all | Done (code complete 2026-09-24). The six areas are qualified against RN (contract §17), and every gap has coverage or a named owner. The new suite `native/Phase11QualificationTests` (318 checks) proves four things. RN's own `BridgeSnapshot` and `SiriSnapshot` decoders, extracted from `targets/`, read every fixture and every native write. Every RN widget-action and deep-link vector runs through the native planner, replayer and parser. The RN `track(` sites equal the catalog, with 49 of 52 events live natively and 3 named exclusions. The RN secure fields and §10.1 deny rows are stripped everywhere, and no §12.1 row is open. A30 (PDF stamps and accent) is fixed as a native difference, with every pairing at 5.67:1 or better. Six known issues are carried to the final review and are not qualified. Device, extension, Siri and store proof is deferred to Phase 12 | 11.01-11.12, 11.15 | Cross-client qualification |
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

### 11.06 — Cold and warm deep-link routing with authentication gates (2026-09-24)

**Outcome:** code complete for L1 and L2. Cold (App Group `pendingOpenUrl` stash) and warm
(`onOpenURL`, the launch URL and the in-process On My Way router) links for `job` and
`onmyway` pass one gate, applied in this order:
1. intercept (Google, then password recovery);
2. parse;
3. read and remove the stash under the lock;
4. authenticate, else park;
5. exact owner (O);
6. the record exists and is not archived or finished.

Any failure fails closed. The 11.05 handoffs and the 11.04 double-presentation handoff are
closed, and C11/P8 is decided. Device, widget and Siri proof is deferred to Phase 12 and
was not claimed.

**Files:**
- New: `native/TradeReadyNative/NativeDeepLinkRouting.swift`. It holds the pure policy
  (`NativeDeepLinkRoutingPolicy.decide`, the parking-discard rule and the analytics type)
  and the `NativeOpenURLDispatch` Google-first order.
- Edited:
  - `native/TradeReadyNative/AppStore.swift`: `handle(url:)`,
    `consumePendingOpenURLStash`, parking on the gate `didSet`, the not-found notice,
    `clearDeepLinkRouteState()` at every account boundary, and the consumer injection.
  - `native/TradeReadyNative/NativeAppGroupInbox.swift`: `NativePendingOpenURLConsumer`
    does `take` / `takeMatching` under `WidgetAppGroupLock`.
  - `native/TradeReadyNative/NativeDeepLinkParser.swift`: `ownerTag`, size bounds and the
    identifier rule.
  - `native/TradeReadyNative/NativeEstimateFollowUp.swift` (P8).
  - `native/TradeReadyNative/RootView.swift`: the "Job not found" sheet.
  - `native/TradeReadyNative/TradeReadyNativeApp.swift`: dispatch, consume at launch and
    on every activation, discard the parked route on background.
- Tests:
  - New: `native/DeepLinkRoutingTests/main.swift` and
    `native/run-deep-link-routing-tests.sh`, registered in
    `native/run-all-domain-tests.sh` after the owner-gating runner.
  - Updated fixtures: `native/WidgetOwnerGatingTests/main.swift`,
    `native/AppIntentQueueTests/main.swift`, `native/StoreIntegrationTests/main.swift`,
    `native/AppGroupPendingOpenURLTests/main.swift` and
    `native/EstimateFollowUpTests/main.swift`.
  - Runner source lists: `native/run-appstore-sources-common.sh`,
    `native/run-app-group-pending-open-url-tests.sh` and
    `native/run-next-job-widget-tests.sh`.

**P8 decision (C11 resolved):** an archived `estimate_sent` job's delivered `est_`
notification **opens** its editable follow-up review.
- The archive check was removed from `NativeEstimateFollowUp.canOpenNotification`.
- Why: `upcomingReminders` still schedules `est_` for archived jobs, as RN
  `selectEstimateFollowUps` does, and RN's tap routes with no archive check. Refusing
  the tap made a notification the app itself delivered into a dead tap, which Phase 10
  §9.6 rules out for every other family.
- Still fails closed: a missing job, an answered estimate, or a workspace that is
  signed out or not the exact owner's.
- The same principle is used for the widget links: a surface the app is still producing
  must route; a stale link to a record that is no longer produced fails closed.
  Recorded in contract §6.3.

**Handoff closure:**
- **(a)** `consumeVerifiedPendingOpenURLIfNeeded` is gone.
  - `consumePendingOpenURLStash` runs at launch, on every activation, and on each
    `.signedIn` arrival (starting point, identity outcome, subscription gate). There is
    no once-per-session flag.
  - Routing requires O and `.signedIn`, so native-only accounts route.
- **(b)** The stash is read and removed in one hold of the single `WidgetAppGroupLock`,
  valid or not (no new lock).
  - An untagged, stale, future, malformed or oversized stash is dropped.
  - The tag must equal `hash(O)`.
  - A locked-out read changes nothing.
- **(c)** `handle(url:)` now has the full gate.
  - Not signed in: it parks (at most one route; the newest wins). Each warm link records
    its arrival O; a stash route keeps its tag.
  - Entering `.signedIn` applies the parked route.
  - Entering `.signedOut`, `.accountMismatch` or `.unavailable` discards it, as does
    backgrounding.
  - A route parked under A never applies under B.
- **(d)** `useAnotherAccount` clears every held route and one-shot target (`deepLinked*`,
  `pending*JobID`, the parked route and the notice). It clears before its first await and
  again after its awaits. Sign-out, deletion and scrub retry share the same
  `clearDeepLinkRouteState()`.
- **(e)** The owner-gating fixtures were updated deliberately:
  - (a) now asserts parking with no arrival owner, then resolution in the current
    (emptied) data;
  - (b) is rewritten for the new consumer: the stash is removed at once, parks with A's
    tag, and is discarded when B signs in;
  - (c) pins parking, newest wins and the real `signOut` discard;
  - (d) is a hard assertion. The KNOWN GAP line is removed and nothing is printed.
- **11.04:** a warm `onmyway` link removes the matching stash (same parsed route) under
  the lock and carries its tag as extra owner proof. The intent writes the stash and
  hands the URL to the router on the main actor with no suspension, so the cold consumer
  never presents the same review again.
  - The `native/AppIntentQueueTests/main.swift` assertion now expects the stash to be
    removed and a following `consumePendingOpenURLStash()` not to re-present.
  - On My Way stays an editable review and is never sent automatically; the test checks
    that no bytes are written to the canonical file.

**Deviations (recorded in contract §6.3):**
1. A `job` link to an archived job with a running timer routes, because the Job Timer
   widget still shows that job. `onmyway` never gets this exception.
2. Oversize bounds: a URL over 1,024 bytes or a stash over 4,096 bytes is dropped. The id
   must also pass `WidgetActionFieldRules.isValidIdentifier`.
3. A record failure shows a "Job not found" sheet (the Jobs title and symbol). Owner and
   freshness failures are silent.
4. A closed gate discards a parked route on **entering** it. A link that arrives while
   the gate is already closed parks until sign-in.
5. Account boundaries also clear the customer, invoice, outreach, appointment, review and
   estimate one-shot targets, not only the job and On My Way routes.
6. P8 (above).

**Commands and results:**
- `TZ=America/Phoenix sh native/run-deep-link-routing-tests.sh` → "Deep-link routing
  tests passed". It covers:
  - the pure policy matrix;
  - gate-phase mapping for every gate state;
  - Google-first dispatch;
  - recovery-link priority;
  - malformed, oversized and stale links and stashes with no side effects;
  - cold and warm × signed in, signed out, owner mismatch and no exact workspace ×
    missing, archived, archived with a timer, and done, for both `job` and `onmyway`;
  - the parking lifecycle;
  - no double On My Way;
  - `useAnotherAccount` clearing;
  - analytics;
  - P8 through `requestEstimateFollowUpReview`.
- Mutation checks: 18, each applied, run, restored and verified identical with `cmp`. All
  were killed:
  - tag check, arrival-binding check, archived check, running-timer exception,
    done-status check, freshness, signed-in gate, O-nil check;
  - discard on entering a closed gate, Google-first order, warm `takeMatching`, the early
    `useAnotherAccount` clear, flush on `.signedIn`;
  - the not-found notice, analytics, P8 reverted, the parser size bound and the
    identifier rule.
- Also passing with `TZ=America/Phoenix`: widget-owner-gating, app-intent-queue,
  store-integration, app-group-pending-open-url, estimate-follow-up,
  estimate-follow-up-notification, appointment-notification, next-job-widget,
  job-timer-widget, widget-snapshot and widget-action-replay.
- RN oracle: `TZ=America/Phoenix npm test -- --runInBand --runTestsByPath __tests__/deepLinks.test.js`
  → 39 passed.
- `xcodebuild ... -configuration Release -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build`
  → `** BUILD SUCCEEDED **`.
- `TZ=America/Phoenix sh native/run-all-domain-tests.sh` → exit 0.
- `sh native/run-doc-reference-check.sh` → 0 missing.

**Runsheet rows (Phase 12; not run, not claimed):**
- A cold launch from a Next Job or Job Timer widget tap while signed in opens the exact
  job. While signed out, the same tap opens it after the same owner signs in, and
  signing in as a different owner opens nothing.
- Siri "On My Way" presents one editable review (never twice, never sent automatically),
  both warm and from a cold launch.
- A widget tap on an archived or deleted job shows "Job not found". An archived job with
  a running timer opens that job.
- Google Sign-In completes while a widget link is parked.
- An archived estimate's `est_` notification opens its follow-up review.
- The "Job not found" sheet is presented from `RootView` while another sheet is already
  up (an On My Way review, an estimate follow-up, a job editor): it appears on top or
  after that sheet closes, never silently lost, and Done dismisses only it.

**Concerns:** none blocking. The "Job not found" sheet is a new small surface: it reuses
the existing title and symbol but is presented from `RootView` rather than inside Jobs
navigation.

**Next ready:** 11.07 (analytics transport; `widget_deep_link_opened {type}` now goes
through the `NativeAnalytics` seam).

**Fix round 1 (2026-09-24):**
- **I1: a cold launch while signed out dropped the parked route (fixed).** The store
  starts at `.loading`, so a launch stash or launch URL parked, and activation's
  `.loading` → `.signedOut` then counted as entering a closed gate and discarded it.
  - Controller ruling (the brief wins over the §6.2 wording): only leaving a session in
    which an owner was active discards a parked route. That covers sign-out, account
    switch, scrub, deletion, and a mismatch or outage reached after sign-in. The launch
    resolution is not a boundary.
  - `NativeDeepLinkRoutingPolicy.discardsParked` takes `ownerWasActive`.
    `AppStore.deepLinkOwnerWasActive` is set whenever `O` holds at a gate change and is
    reset by the boundary.
  - The tag check and the 300 s window still protect the owner. Contract §6.2 step 4 and
    §6.3 are amended. Deviation 4 above is superseded.
  - New fixtures, for both the stash and the launch-URL paths:
    - `.loading → park → .signedOut → .signedIn(A)` opens A's record, once;
    - the same sequence with `.signedIn(B)` discards silently;
    - a route older than 300 s at apply time discards;
    - launch → `.accountMismatch` keeps the parked route;
    - leaving an active owner's session for `.signedOut`, `.accountMismatch` or
      `.unavailable` (including `signedIn → .loading → .signedOut`) discards, and the
      flag is consumed by that boundary.
- **Spec gap:** the §2.5 11.06 bullet, the §4 OnMyWay gap bullet, the §6.2 "Gaps 11.06
  must close" list and the C22 row are marked closed, each citing what closed it.
- **M1:** a warm link that arrived with no owner (arrival binding nil, no stash tag),
  whose record the signing-in owner lacks, is dropped silently
  (`missingRecordUnownedArrival`). A missing record under `O` still shows not-found.
  The owner-gating fixture (a) expectation was updated deliberately.
- **M2:** `takeMatching` reuses `NativeDeepLinkParser.decodePendingOpenURLPayload`, the
  one payload decoder and size bound (the `Loose` decoder is gone). New assertions: an
  oversized stash, or one without `at`, is never matched.
- **M3:** the malformed-URL loop fails on an entry `URL(string:)` rejects, and asserts
  the handled count (22 = 11 × 2).
- **M4:** a new fixture sends a link from inside `logOut`, between `clearSession` and the
  owner teardown. The link is applied mid-switch, and the clear after the awaits removes
  it.
- **M5:** a Phase 12 runsheet row for the not-found sheet over another sheet (above).
- **Mutation checks (7, all caught; each restored and confirmed identical with `cmp`):**

  | Mutation | Failures caught |
  |---|---|
  | never discard on a closed gate | 9 |
  | `ownerWasActive` ignored (launch resolution discards) | 12 |
  | owner flag never set | 8 |
  | owner flag never reset | 1 |
  | M1 reverted | deep-link 3, owner-gating 1 |
  | second `useAnotherAccount` clear removed | 1 |
  | shared payload size bound removed | 2 |
- **Commands (`TZ=America/Phoenix`):** deep-link-routing, widget-owner-gating,
  app-intent-queue, store-integration and app-group-pending-open-url all pass. The Release
  generic `xcodebuild` gives `** BUILD SUCCEEDED **`, and
  `sh native/run-doc-reference-check.sh` reports 0 missing.

### 11.07 — Analytics transport and privacy controls (2026-09-24)

**Outcome:** code complete for P1 and P4. The Phase 10 seam `N/NativeAnalytics.swift` was
widened in place (ruling P6), and every existing call site is unchanged. The real
transport sits behind that seam:
- the §9.2 gate;
- one `track` choke point enforcing the §9.5 allow-list and the §10.1 analytics column;
- PostHog iOS behind a Foundation-only adapter.

Debug emits nothing. A missing or `PLACEHOLDER` key disables analytics without a crash.
Adapter failures are swallowed. Sentry is not touched (11.09); no screen or identity
instrumentation was added (11.08).

**Final SDK pin:** PostHog iOS `https://github.com/PostHog/posthog-ios` **3.81.0**,
`exactVersion` (revision `2771b92c2e7b5471c196d24d5bc4997e26cafbcd`).
- The re-check found no 3.81.x patch. 3.82.0 exists but is a new minor and was not
  adopted (contract §7).
- The product `PostHog` is linked to the app target only. The widget extension links no
  package: its binary has no PostHog symbols.

**Key configuration:**
- The RN key (`app.json` `expo.extra.posthogApiKey`) is a real `phc_` production project
  key. It was read to learn the mechanism and was **not** copied.
- The native path mirrors that mechanism: Info.plist `TradeReadyPostHogAPIKey` ←
  `$(TRADEREADY_POSTHOG_API_KEY)` and `TradeReadyPostHogHost` ← `$(TRADEREADY_POSTHOG_HOST)`,
  read by `BuildEnvironment.postHogAPIKey`/`postHogHost`.
- Neither build configuration defines either setting (no pbxproj build-setting edit), so
  the Debug and the Release (staging, `https://staging.invalid`) builds both resolve to
  disabled.
- A reporting release supplies `TRADEREADY_POSTHOG_API_KEY=<key>` at build time (for
  example on the `xcodebuild` command line or in an uncommitted xcconfig). The staging
  config leaves it empty (§9.2).

**Files:**
- Edited:
  - `native/TradeReadyNative/NativeAnalytics.swift` (in place): `NativeAnalyticsValue`,
    the widened protocol, the embedded §9.5 fixture, `NativeAnalyticsEventCatalog`,
    `NativeAnalyticsPrivacyPolicy`, `NativeAnalyticsDiagnostic`,
    `NativeAnalyticsSDKAdapter` and `NativeAnalyticsTransport`.
  - `native/TradeReadyNative/BuildEnvironment.swift`: the two config accessors.
  - `native/TradeReadyNative/AppStore.swift`: the convenience `init(analytics:)`,
    defaulting to the no-op.
  - `native/TradeReadyNative/TradeReadyNativeApp.swift`:
    `AppStore(analytics: NativeAnalyticsTransport.live())`.
  - `native/Info.plist`: the two keys.
  - `native/TradeReadyNative.xcodeproj/project.pbxproj` (ruling P7): the package
    reference, the product dependency and the app Frameworks build file only.
  - `native/TradeReadyNative.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`.
  - `native/run-all-domain-tests.sh`: registration after the deep-link runner.
- New:
  - `native/TradeReadyNative/NativeAnalyticsConfiguration.swift`: the pure gate and
    `makeTransport`.
  - `native/TradeReadyNative/NativeAnalyticsPostHog.swift`: the only `import PostHog`,
    plus `NativeAnalyticsTransport.live()`.
  - `native/AnalyticsTransportTests/main.swift`.
  - `native/run-analytics-transport-tests.sh`.
- Docs: contract §1 (C12 and C16 status), §7 re-check, §8.3 and §9.7; this plan (status,
  §6 row, this entry).

**Interface handoff:**
- **11.08:**
  - Inject nothing new: `AppStore.analytics` is already the live transport.
  - Call `analytics.identify(<Supabase user id>)`, `analytics.reset()` and
    `analytics.screen(<RN route name>)` on the seam.
  - Send typed values (`["days": 30]`, `["kinds": ["due_soon"]]`).
  - Until the call sites migrate, the stringified `doneCount`, `days`, `kinds` and `ids`
    are **stripped** as `wrongType` (the event still sends), as the host test pins. The
    Debug assertion fires on any event name outside the catalog.
- **11.09:**
  - Contract §8.3 has the analytics collected-data types.
  - It lists two decisions: Financial Info/Purchase History for amounts and
    `subscription_purchased`, and Device ID for PostHog's anonymous install id.
  - It records the PostHog required-reason APIs (UserDefaults `CA92.1`, System Boot Time
    `35F9.1`, File Timestamp `C617.1`, confirmed from the built bundle) and the
    unlisted-but-inert `PostHog_PHPLCrashReporter.bundle` manifest (Crash Data, Other
    Diagnostic Data).
  - PostHog exception autocapture is off; Sentry stays the only crash reporter.
  - The `NativeAnalyticsPrivacyPolicy` value screens (credential prefixes, email/phone,
    URL/data URI, identifier charset) are reusable input for `NativeErrorRedaction`.

**Recorded deviations and additions** (contract §9.7):
- **SDK options beyond §9.2,** each off because it sends data the catalog does not
  declare:
  - rage-click autocapture (default on in 3.81.0);
  - push-token upload and push-open capture;
  - feature-flag preload and `$feature_flag_called`;
  - a `beforeSend` event-name allow-list.
- A non-empty invalid PostHog host disables analytics (fail closed).
- Catalog `string` values are held to an identifier grammar. A bare 7–12-digit value is
  treated as a phone number.
- A sanitized payload over 4,096 bytes of JSON is rejected whole.

**Commands and results:**
- `TZ=America/Phoenix sh native/run-analytics-transport-tests.sh` → "Analytics transport
  tests passed (225 checks)". It covers:
  - the §9.5 fixture byte-identical to the contract and parsed (52 events);
  - the gate matrix: Debug; missing, blank or unexpanded key; `PLACEHOLDER`; invalid host.
    Each gives zero emits, an SDK adapter that is never built, and one setup diagnostic;
  - an adapter setup failure;
  - the Info.plist and pbxproj config: no key committed, 3.81.0 `exactVersion`, app-only
    link;
  - exact payloads for a configured release (15 events, with variants, optional keys and
    arrays) plus identify, screen and reset;
  - 27 secure, PII, document and oversize value classes and 13 secure, PII and document
    key classes, stripped and diagnosed, never observed in payloads or logs;
  - the diagnostic bound (8 issues + omitted count, ≤ 512 characters);
  - the 4 KB payload rejection; unknown events dropped and flagged;
  - identify and screen validation;
  - the `beforeSend` allow-list;
  - every adapter throw swallowed;
  - a legacy string-only conformer, and the verbatim AppStore call-site shapes;
  - the real `AppStore` call sites firing through the transport.
- Mutation checks: 9, each applied, run and restored, then confirmed identical with
  `cmp`. All were killed:
  - the Debug gate, the `PLACEHOLDER` guard, the secret screen, the PII screen and the
    payload cap;
  - raw properties passed to the SDK, `beforeSend` allowing everything, unknown keys
    kept, and `identify` unvalidated.
- `TZ=America/Phoenix`: build-environment, deep-link-routing (legacy recording fake) and
  store-integration (legacy `@MainActor` recording fake) pass. Its `ConformanceIsolation`
  warning is pre-existing and reproduces against the HEAD seam.
- RN oracle: `TZ=America/Phoenix npm test -- --runInBand --runTestsByPath __tests__/analytics.test.ts`
  → 9 passed.
- `xcodebuild -project native/TradeReadyNative.xcodeproj -resolvePackageDependencies` →
  PostHog resolved @ 3.81.0.
- `xcodebuild ... -configuration Release -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build`
  → `** BUILD SUCCEEDED **`, with no warning in the new files. The app bundle carries
  `PostHog_PostHog.bundle` and `PostHog_PHPLCrashReporter.bundle`. `nm` on the widget
  extension finds 0 PostHog symbols.
- `TZ=America/Phoenix sh native/run-all-domain-tests.sh` → exit 0 (every suite passed, including `Analytics transport tests passed (225 checks)`; only pre-existing compiler warnings).
- `sh native/run-doc-reference-check.sh` → 1431 path references checked: 0 missing, 28 planned.

**Runsheet rows (Phase 12; not run, not claimed):**
- A Release build with a real key sends catalog events, `Application Opened`/`Backgrounded`
  and `$identify` to the PostHog project. A Debug build and a keyless Release build send
  nothing (proxy or PostHog live view).
- No `$autocapture`, `$rageclick`, `$exception`, push or feature-flag event arrives from a
  device session.

**Concerns:**
- The four stringified Phase 10 properties are stripped until 11.08 migrates them.
- 11.09 owns the Financial Info and Device ID manifest decisions (§8.3).
- The Release build logged a non-fatal `appintentsnltrainingprocessor` "Could not
  archive SSU artifacts" line. It comes from App Intents metadata, not these files.

**Next ready:** 11.08 (event parity and identity lifecycle) and 11.09 (crash reporting),
both unblocked by 11.07.

### 11.08 — Event parity and the identity lifecycle (2026-09-24)

**Outcome:** code complete for P2 and P3.
- All 52 §9.5 events have typed constructors in `N/NativeAnalyticsEvents.swift`. The
  store and views emit them through one `AppStore.emitAnalytics`, after the durable
  commit RN tracks after.
- 49 events are wired (corrected in fix round 1; the first count was 50).
  - `booking_request_opened` and `booking_update_opened` fire on RN push taps only,
    and native has no remote-push surface yet.
  - `tax_settings_saved` is emitted by `commitTaxSettings`, but nothing in
    production calls that. It is unreachable until a native tax-settings editor
    exists.
- The identity lifecycle, the `$screen` map and the gate-driven onboarding/paywall
  events are in place.
- 11.07 review findings m1–m3 are fixed, and the 11.07 handoff is closed: `doneCount` and
  `days` are numbers, and `kinds`/`ids` are string arrays.
- Nothing was built for Sentry (11.09). Analytics stays outside the commit path: the
  seam never throws, and the transport swallows adapter failures.

**Identity lifecycle** (contract §9.4, refined in §9.7):
- `identify(<Supabase user id>)` runs when the verified subject is applied
  (`applyAuthenticatedIdentityOutcome`, and the background activation). It is
  re-asserted as a no-op when the gate enters `.signedIn`.
- A different verified id resets first.
- `reset` runs:
  - in `applyCompletedSignOutState` (sign-out, paywall sign-out, retried scrub);
  - in `useAnotherAccount`, before its first await;
  - in `deleteAccount`, as soon as the server confirms (before the scrub and the
    RevenueCat logout; this covers the scrub-failure path too).
- Back-to-back boundaries reset once. The id is the only thing ever identified.

**Files:**
- New:
  - `native/TradeReadyNative/NativeAnalyticsEvents.swift`: the constructors,
    `NativeAnalyticsIdentityLifecycle`, `NativeAnalyticsGatePolicy` and
    `NativeAnalyticsScreen`.
  - `native/TradeReadyNative/NativeAnalyticsScreenModifier.swift`:
    `.nativeAnalyticsScreen(_:)`, app target only.
  - `native/AnalyticsEventTests/main.swift`.
  - `native/run-analytics-event-tests.sh`.
- Edited:
  - `native/TradeReadyNative/NativeAnalytics.swift`: m1, m2 and m3.
  - `native/TradeReadyNative/AppStore.swift`: surgical changes.
    - the analytics state and section;
    - the gate `didSet` hook and the identity hooks;
    - `finishInteractiveSignIn`;
    - emission after each commit, where the commit functions that return results gained
      a private `perform…` core;
    - source parameters on the review, follow-up, appointment and overdue opens;
    - two test seams.
  - `native/TradeReadyNative/TradeReadyNativeApp.swift`: notification `daysPastDue`.
  - Views:
    - `JobsView`, `MoneyView` and `InvoicesView`;
    - `NativeMessageComposer`, `NativeReviewRequestView`, `NativeEstimateFollowUpView`,
      `NativeChangeOrdersView`, `NativeInvoiceOutreachView` and `NativeExpenseEditor`;
    - one screen modifier each on 42 destination views, including `SettingsView` and
      its pages.
  - `native/run-appstore-sources-common.sh`.
  - `native/run-all-domain-tests.sh`: registered after the transport runner.
  - `native/run-calendar-editor-tests.sh` and
    `native/run-schedule-booking-settings-tests.sh`: these compile view files, so
    they now also compile the screen modifier.
  - Test fakes in `native/StoreIntegrationTests`, `native/DeepLinkRoutingTests` and
    `native/AnalyticsTransportTests` (section 7 now pins the typed values).
- Docs: contract §9.7 (the 11.08 block); this plan (status, §6 row, this entry).

**Interface handoff:**
- **11.09:**
  - `NativeAnalyticsIdentityLifecycle` and the three boundary sites are where Sentry's
    `setUser({id})` / `setUser(nil)` belong. RN pairs both with the PostHog calls.
  - Add them beside `applyAnalyticsIdentityActions`. Do not add a second lifecycle.
  - `NativeAnalyticsDiagnostic.sanitizedName` (m3) and the value screens are reusable
    for `NativeErrorRedaction`.
- **Native push (future):** emit `.bookingRequestOpened` / `.bookingUpdateOpened` from
  the push-tap route.
- **Tax settings UI (future):** `commitTaxSettings` already emits `tax_settings_saved`.

**Recorded native differences** (contract §9.7):
- Review and follow-up sends fire on `.sent` only.
- `estimate_sent` also fires on the composer-confirmed delivery stamp.
- The composer-opened events fire at composer presentation.
- Notification-open events fire only when the guarded route opens.
- `bulk_invoice_reminders.count` counts the sheets presented.
- The paywall is always `onboarding_gate`.
- Screens are RN leaf routes. A sheet dismissal does not re-send the parent screen.
- Pull-to-refresh drops its event across an owner change.

**Commands and results:**
- `TZ=America/Phoenix sh native/run-analytics-event-tests.sh` → "Analytics event tests
  passed (454 checks)". It covers:
  - every event and every variant built by a constructor and sent unchanged by the
    shipped policy, with no diagnostic; the name set equals the catalog;
  - the value normalizations;
  - m2 (a manual invoice carrying the auto flags keeps `source: manual`) and m3
    (secret-shaped and long-digit names are redacted, and no diagnostic or violation
    echoes them);
  - the lifecycle policy, the gate policy, and every screen name found in `App.tsx`;
  - the real AppStore journey: sign-out gate → password sign-in → Today → customers,
    job, lifecycle advance, clock-in, expense, payment, void, settle → sign-out, asserted
    as the exact ordered adapter sequence;
  - apple sign-in → `useAnotherAccount` (run for real) → google sign-in, with the reset
    before the next owner's events;
  - a direct id change; the deletion boundary (one reset) plus a source-order check of
    `deleteAccount`;
  - contextual sources and opens;
  - a throwing adapter, with commits verified on disk after a relaunch.
- Mutation checks: 9, each applied, run and restored byte-identical. All were killed.
  The m2 mutation first survived, because the stray-key case did not separate the two
  rankings; the test now uses RN's two-flag case.
  - the switch reset, the sign-out reset, the deletion early reset, and identify at
    verification;
  - the m2 discriminator, the m3 secret screen, and boundary idempotence;
  - `customer_created` on edit, and a stringified `doneCount`.
- `TZ=America/Phoenix sh native/run-analytics-transport-tests.sh` → "Analytics transport
  tests passed (226 checks)".
- `TZ=America/Phoenix sh native/run-store-integration-tests.sh` → "PASS: canonical
  AppStore integration tests".
- `sh native/run-deep-link-routing-tests.sh` → "Deep-link routing tests passed".
- RN oracle: `TZ=America/Phoenix npm test -- --runInBand --runTestsByPath __tests__/analytics.test.ts`
  → 9 passed.
- `xcodebuild -project native/TradeReadyNative.xcodeproj -scheme TradeReadyNative -configuration Release -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build`
  → `** BUILD SUCCEEDED **`. There are no new warnings; the unused-`binding` warning in
  `AppStore.swift` is pre-existing.
- `TZ=America/Phoenix sh native/run-all-domain-tests.sh` → exit 0 (every suite passed, including `Analytics transport tests passed (226 checks)` and `Analytics event tests passed (454 checks)`; only pre-existing compiler warnings). The first run failed to compile `run-calendar-editor-tests.sh` (its view sources lacked the new screen modifier); fixed by adding `NativeAnalyticsScreenModifier.swift` to that runner and `run-schedule-booking-settings-tests.sh`, then the full run was repeated.
- `sh native/run-doc-reference-check.sh` → 1445 path references checked: 0 missing, 26 planned.

**Runsheet rows (Phase 12; not run, not claimed):**
- With a real key: password, Apple and Google sign-in each show `$identify` with the
  Supabase id and `sign_in{method}` in PostHog. Sign-out, "Use another account" and
  account deletion each show a reset (a new anonymous distinct id) before the next
  owner's first event.
- Navigating the tabs and detail screens sends `$screen` with the RN leaf route names.
- A notification tap for an estimate follow-up, an overdue invoice or an appointment
  sends its `*_opened` event once.
- Onboarding sends `welcome` → `business` → `starting_point`, and the paywall sends
  `subscription_paywall_shown{onboarding_gate}` once per presentation.

**Concerns:**
- `booking_request_opened` and `booking_update_opened` are constructed but unwired until
  native push exists.
- The real `deleteAccount` and the provider sign-ins cannot run in the host test. Their
  analytics tails are covered through the real private methods, via seams, plus a
  source-order check. Device proof is in Phase 12.
- §9.4's "identify … when the gate enters `.signedIn`" is implemented as identify at
  verification (earlier) plus a no-op re-assert at `.signedIn`, for RN parity. This is
  recorded in §9.7 for the reviewer.

**Next ready:** 11.09 (crash reporting, redaction, app manifest).

**Fix round 1 (2026-09-24, task review of f6ffb31):**
- **I1: `$screen` dropped pop-backs and repeat visits (fixed).**
  - The tab roots (Today, Jobs, Invoices, Customers, Money, Coach) and Settings now
    attach `.nativeAnalyticsScreen` to the stack's root content, not the
    `NavigationStack`, so a pop re-fires `onAppear`.
  - `AppStore.trackScreen` no longer dedupes consecutive repeats. The modifier holds
    `NativeAnalyticsScreenAppearance`, a pure type in `N/NativeAnalyticsEvents.swift`.
    It drops only SwiftUI's duplicate `onAppear` within one appearance.
  - JobList → JobDetail(A) → back → JobDetail(B) now sends all four, as RN does.
  - New fixtures:
    - list → detail → back → detail;
    - a repeat Settings → SettingsBusiness visit;
    - a duplicate `onAppear` within one appearance;
    - two direct `trackScreen` calls;
    - a source check that each tab root attaches inside its stack.
  - Contract §9.7 now lists the two differences that remain: a sheet dismissal does
    not re-send the parent, and a same-route state change does not re-send.
- **Spec gaps:**
  - `NativeRecurringInvoiceEditor` now applies `.recurringInvoiceEditor`
    (`AddRecurringInvoice`). A new check requires every signed-in destination with an
    RN route to be applied by some view.
  - The wired count is corrected to 49 in §6 and in the 11.08 entry.
    `tax_settings_saved` is unreachable until a native tax-settings editor exists
    (contract §9.7).
- **M4:**
  - Pull-to-refresh now has coverage.
    - The real `performPullToRefresh` sends for Jobs and Money after the sync, and sends
      nothing with no screen.
    - Through `testPerformPullToRefresh`, the real private tail with its sync step
      injected: a sign-out during the sync drops the event. So does an owner switch
      A → B during the sync; nothing is sent under B.
  - `testFinishInteractiveSignIn` gained `landingGate`. A sign-in that lands on
    `.accountMismatch` emits exactly `identify(B)` and `sign_in`, then signing out
    resets.
- **M6:** the bulk-reminder rule moved out of `InvoicesView`.
  - The view reports only the finished chain, through
    `recordBulkInvoiceReminderRunCompleted(channel:presentedCount:)`.
  - `NativeAnalyticsEvent.bulkInvoiceReminderRun` owns the channel mapping and the
    count, and fires even at 0 (RN tracks every started run).
  - `Domain/NativeInvoiceBulk.swift` joined `native/run-appstore-sources-common.sh`.
- **M7:** `overdue_outreach_opened` sends with no key when the payload has no
  `daysPastDue`. The §9.5 fixture key is now `daysPastDue?` in both the contract and
  the embedded catalog.
- **M9:** the unused `binding` at `AppStore.swift` (booking mirror guard) is replaced
  by `capture.binding != nil`.
- **Tests:**
  - `TZ=America/Phoenix sh native/run-analytics-event-tests.sh` → `Analytics event tests passed (536 checks)`.
  - `TZ=America/Phoenix sh native/run-all-domain-tests.sh` → exit 0. That covers
    transport 226 checks, store integration, deep-link routing, calendar editor and
    schedule/booking settings.
  - Release generic `xcodebuild` → `** BUILD SUCCEEDED **`. The unused-`binding`
    warning is gone, and no warning comes from a line this task changed.
  - `sh native/run-doc-reference-check.sh` → 0 missing.
  - Mutations, each applied and then restored, all killed:
    - reinstating the store's consecutive dedupe;
    - removing the appearance guard;
    - removing the pull-to-refresh owner guard;
    - dropping the nil-`daysPastDue` open;
    - unwiring the recurring editor;
    - attaching the Jobs modifier to the stack.

### 11.09 — Crash reporting and redaction (2026-09-24)

**Outcome:** code complete for R1, R2, R3 and M1 (app manifest).
- Sentry Cocoa **9.29.0** (`exactVersion`, revision
  `d9df1c4e8d8466c7f8b3c56150378927dadf1b8e`) is linked to the app target only, following
  the PostHog pattern of e5d3940: one package reference, one product dependency and one
  Frameworks entry. The widget extension links nothing. 9.29.1 appeared the same day and
  was not adopted (contract §7 re-check).
- The DSN is wired like the PostHog key: `TradeReadySentryDSN` = `$(TRADEREADY_SENTRY_DSN)`
  in `native/Info.plist`, read by `BuildEnvironment.sentryDSN`. No configuration sets the
  build setting, so both builds report nothing until a release supplies a DSN. The RN DSN
  (`app.json:100`) is not copied. Staging stays `https://staging.invalid`.
- `NativeCrashReportingGate` disables reporting in Debug and for a missing, blank,
  unexpanded, `PLACEHOLDER` or malformed DSN. Enabled, the adapter gets exactly the §10.2
  options: traces 0.2, auto sessions on, `sendDefaultPii` false, no screenshot or view
  hierarchy, replay rates 0, failed-request capture off, `environment`, and
  `releaseName = <bundle id>@<short>+<build>`.
- `beforeSend`, `beforeBreadcrumb` and `beforeSendSpan` run `NativeErrorRedaction`
  (contract §10.4 lists where it is stricter than §10.2). The user is `{id}` only.
- `reportError` parity: an `Error` is captured as is; any other value is wrapped in a
  titled `NativeReportedError`, with `rawError` reduced to `{code, message, hint}` and the
  extras allow-listed. Capture and `setUser` run on a private serial queue and swallow
  every failure, so reporting is off the commit path.
- `setUser` rides the 11.08 lifecycle in `applyAnalyticsIdentityActions`; there is no
  second identity path.
- Call sites wired: `pushQueue` and `pullRemote` (once per sync pass, in
  `AppStore.applySyncStatus`) and `deleteAccount` (`SettingsView`). The other RN sites
  are recorded, not mapped (contract §10.4).
- The app manifest `native/TradeReadyNative/PrivacyInfo.xcprivacy` is written (below).

**Decisions:**
- **Native Sentry project slug:** `tradeready-ios` in org `tradeready-3r` (the RN slug
  `react-native` is not reused).
- **dSYM upload:** `native/scripts/upload-sentry-dsyms.sh <App.xcarchive | dSYMs dir>`,
  run by hand on a Release archive. It calls `sentry-cli debug-files upload`, takes the
  token from `SENTRY_AUTH_TOKEN` only, and exits 0 with a message when the token or the
  slug is absent. Source bundles are opt-in (`SENTRY_INCLUDE_SOURCES=1`, off by default;
  fix round 1). There is no run-script build phase and no token in the repo.
- **§8.3:** Other Financial Info and Purchase History are declared (linked, Analytics).
  Device ID is not declared (PostHog's id is a rotating per-install UUID, not the IDFA or
  IDFV, and flags are off). The inert `PostHog_PHPLCrashReporter.bundle` manifest is left as
  shipped; its types are already declared.
- **§8.1 correction:** File Timestamp `C617.1` is declared.
  `NativeWidgetActionReplay.swift` reads `.contentModificationDateKey` of the App Group
  claim files; the 11.00 grep missed it. The widget extension reads no timestamp, so its
  manifest is unchanged.
- **Final pin:** Sentry Cocoa 9.29.0; PostHog stays 3.81.0.

**App manifest** (`N/PrivacyInfo.xcprivacy`): no tracking, no tracking domains.
- APIs: UserDefaults `CA92.1` and `1C8F.1`; File Timestamp `C617.1`.
- Collected, all tracking no:
  - User ID: linked; Analytics and App Functionality.
  - Product Interaction, Other Usage Data, Other Financial Info and Purchase History:
    linked; Analytics.
  - Crash Data, Performance Data and Other Diagnostic Data: linked; App Functionality.

**Files:**
- New:
  - `native/TradeReadyNative/NativeErrorRedaction.swift`: `NativeSensitiveData` (shared with
    analytics), the payload mirrors, `NativeErrorRedaction`, `NativeReportedError` and
    `NativeCrashReportBuilder`.
  - `native/TradeReadyNative/NativeCrashReporting.swift`: options, gate, adapter protocol,
    the no-op and the queued reporter.
  - `native/TradeReadyNative/NativeCrashReportingSentry.swift`: the only `import Sentry`
    (an addition to the Own list, mirroring 11.07's `NativeAnalyticsPostHog.swift`).
  - `native/TradeReadyNative/PrivacyInfo.xcprivacy`.
  - `native/ErrorRedactionTests/main.swift` and `native/run-error-redaction-tests.sh`.
  - `native/scripts/upload-sentry-dsyms.sh`.
- Edited:
  - `native/TradeReadyNative/NativeAnalytics.swift`: the shared screens forward to
    `NativeSensitiveData` (the lists are unchanged).
  - `native/TradeReadyNative/AppStore.swift`: the `crashReporting` dependency and init
    parameter, `setUser` beside the analytics identity actions, `reportError`,
    `applySyncStatus` (the coordinator's `statusChanged` now goes through it) and one test
    seam.
  - `native/TradeReadyNative/SettingsView.swift`: the `deleteAccount` report.
  - `native/TradeReadyNative/TradeReadyNativeApp.swift`: `NativeCrashReporter.live()`
    starts first and is injected into the store.
  - `native/TradeReadyNative/BuildEnvironment.swift`: `sentryDSN`.
  - `native/Info.plist`: `TradeReadySentryDSN`.
  - `native/TradeReadyNative.xcodeproj/project.pbxproj` and `Package.resolved`: the package.
  - `native/run-appstore-sources-common.sh` and `native/run-all-domain-tests.sh`.
- Docs: contract (header, C12/C13/C18, §7, §8.1, §8.3, §10.2, §10.4, §15); this plan.

**Commands and results:**
- `TZ=America/Phoenix sh native/run-error-redaction-tests.sh` → "error-redaction tests:
  567/567 checks passed". It covers:
  - the gate (Debug, missing, blank, unexpanded, `PLACEHOLDER` and malformed DSNs each
    build no adapter and report nothing) and the exact §10.2 options on the fake adapter,
    including traces 0.2 and auto sessions on; a failed start leaves an inert reporter;
  - every §10.1 value class in strings (credential prefixes, JWTs, bearer and API-key
    headers, `key=value` secrets, emails, phones, portal/booking/payment URLs, query
    strings, fragments, user info, data URIs, base64), with ids, UUIDs, dates and times
    preserved;
  - every deny key class, case-insensitive and nested, plus `Data`, arbitrary objects,
    non-finite numbers, and the depth and array caps;
  - one poisoned payload through the event (message, exception, mechanism data, extras,
    tags, contexts, breadcrumbs, request, user, server name, transaction), a breadcrumb and
    a span, with no secret surviving anywhere;
  - the extras allow-list and the reduced `rawError`; the 1 KB cap on every field and on
    keys, cut on a character boundary;
  - the wrapper titles (`[code] message`, numeric and Bool codes, redacted JSON, `null`,
    non-JSON types, redaction and cap), the `NSDebugDescriptionErrorKey` title and the
    fingerprint;
  - the reporter's ordering, id sanitizing, and a throwing adapter;
  - `setUser` at sign-in, re-verification, sign-out, double boundary, id change,
    `useAnotherAccount` (run for real) and deletion;
  - a throwing adapter with commits verified on disk after relaunch, and a blocked
    (slow) adapter while a commit and two reports return at once;
  - the sync call sites: one report per failed or partial push or failed or partial pull,
    none for completed passes, early exits or a republished status;
  - source checks: the `deleteAccount` site, the launch order, one `import Sentry`, the
    app-only link and the 9.29.0 pin, `Package.resolved`, no DSN or run-script phase, the
    Info.plist key, staging, the dSYM script, and both manifests parsed.
- Mutation checks: 35, each applied to a scratch copy of `native/`, run and restored. All
  were killed. They covered each §10.2 option and gate, synchronous capture (the slow-SDK
  test deadlocks, which is the failure it guards), id sanitizing, both `setUser` calls, the
  sync dedupe and pull rule, the `deleteAccount` site, each string scrub, token path
  markers, URL queries, payment hosts, the 1 KB cap, bytes, the extras allow-list, the
  `rawError` reduction, `{id}`-only users, case-insensitive and nested keys, request
  headers, server name, event breadcrumbs, spans, and both wrapper-title rules.
- `TZ=America/Phoenix sh native/run-analytics-transport-tests.sh` → "Analytics transport
  tests passed (226 checks)".
- `TZ=America/Phoenix sh native/run-analytics-event-tests.sh` → "Analytics event tests
  passed (536 checks)".
- `TZ=America/Phoenix sh native/run-store-integration-tests.sh` → "PASS: canonical AppStore
  integration tests".
- `xcodebuild -project native/TradeReadyNative.xcodeproj -resolvePackageDependencies -packageAuthorizationProvider netrc`
  → resolved Sentry 9.29.0 (the default keychain provider hung, contract §7).
- `xcodebuild -project native/TradeReadyNative.xcodeproj -scheme TradeReadyNative -configuration Release -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build`
  → `** BUILD SUCCEEDED **`. The first build warned that the `Breadcrumb.data` setter is
  deprecated; the adapter now uses `setData(value:key:)`, and the rebuild has no warning
  from a file this task touched. The `appintentsnltrainingprocessor` "Could not archive
  SSU artifacts" line does not fail the build and comes from the App Intents metadata step.
- Built-app inspection (`Release-iphoneos/TradeReadyNative.app`):
  - `PrivacyInfo.xcprivacy` at the bundle root, byte-identical to the source (the
    synchronized root group picked it up with no project edit);
  - `Frameworks/Sentry.framework/PrivacyInfo.xcprivacy` (UserDefaults `CA92.1`, System
    Boot Time `35F9.1`, File Timestamp `C617.1`; Crash, Performance and Other Diagnostic
    Data);
  - `PostHog_PostHog.bundle` and `PostHog_PHPLCrashReporter.bundle` manifests present;
  - `PlugIns/TradeReadyWidgets.appex`: its manifest is unchanged, `nm` finds no Sentry
    symbol, and `otool -L` shows no Sentry or PostHog;
  - `Info.plist` `TradeReadySentryDSN` expands to an empty string, so the build reports
    nothing.
- `TZ=America/Phoenix sh native/run-all-domain-tests.sh` → exit 0, including "error-redaction
  tests: 567/567 checks passed".
- `sh native/run-doc-reference-check.sh` → 0 missing.

**Runsheet rows (Phase 12; not run, not claimed):**
- Create the Sentry project `tradeready-ios` in org `tradeready-3r`, build a Release
  archive with `TRADEREADY_SENTRY_DSN` set, then run
  `SENTRY_AUTH_TOKEN=… sh native/scripts/upload-sentry-dsyms.sh <App.xcarchive>`. Sentry
  lists the app and widget dSYMs. Add `SENTRY_INCLUDE_SOURCES=1` only if uploading
  source bundles (app source code) to Sentry is intended; the default sends none.
- Trigger a test crash and a `deleteAccount` failure. Each arrives symbolicated with
  `release = <bundle>@<version>+<build>`, `environment`, user `{id}` only, no email, IP or
  device name, and a `[Filtered]` URL token.
- An offline-then-failing sync push reports one `pushQueue` issue titled
  `[<code>] Sync push left changes queued`.
- Sessions appear under Release Health, and traces sample at about 20%.
- A Debug build and a Release build without the DSN send nothing.
- App Store Connect privacy labels match `PrivacyInfo.xcprivacy`; resolve the §8.3
  App Functionality concern (email, synced records, photos) there.

**Concerns:**
- Contract §8.2 omits the App Functionality data the app sends to its own backend (the
  sign-in email, synced customer and job records, job photos). The manifest follows the
  contract; 12.01 must decide these with the App Store labels (contract §8.3).
- Only three of about 74 RN `reportError` sites are mapped; the rest are recorded in
  contract §10.4.
- Sentry 9.29.1 is out and was not adopted.
- Package resolution needs `-packageAuthorizationProvider netrc` on this machine; the
  plain command hangs on a keychain lookup.

**Next ready:** 11.15 (AI Assistant advanced key entry) and 11.10a (accessibility audit).

**Fix round 1 (2026-09-24):** five review minors, one commit.
- URL redaction is idempotent. A `[Filtered]`, `[email]` or `[phone]` path segment is
  kept, and placeholders are encoded before parsing. Before this fix, a second pass
  (`beforeBreadcrumb` then `beforeSend`) turned `[Filtered]` into `%5BFiltered%5D`.
- For a non-`http(s)`/`ws(s)` scheme the host counts as the first route segment, so
  `tradeready://portal/Ab12Cd34` and every other marker route filter a short token.
  `reset-password` joins the markers.
- `upload-sentry-dsyms.sh`: `--include-sources` is opt-in via `SENTRY_INCLUDE_SOURCES=1`.
  `SENTRY_ORG` now defaults only when unset, so the empty-org no-op is reachable.
- Tests:
  - the `expect(true, …)` no-op check is removed;
  - the slow-adapter fake waits at most 3 s per call and counts timeouts, so a
    synchronous-capture regression fails instead of hanging the aggregate;
  - new idempotence, custom-scheme and dSYM-script behaviour checks (fake `sentry-cli`).
- `identifierCharacters` has one definition, in `NativeSensitiveData`; analytics forwards
  to it.
- `error-redaction tests: 687/687 checks passed`. The analytics runners, the aggregate
  and the Release compile pass (see the task report).

### 11.15 — Settings › AI Assistant advanced key entry (2026-09-24)

**Outcome:** code complete for P4 and R2 on the "Settings › AI Assistant" row; this closes
the Phase 10 I4 carry-in. Live provider proof is deferred to Phase 12.
- RN's intro hint and "Advanced" switch (a11y "Advanced AI settings") are on the page, with
  RN's copy verbatim. The switch starts off on every visit, as RN's `useState(false)`
  does. Turned on, it shows a Groq card and then an Anthropic card. Each card has the RN
  hint, a `SecureField` (placeholder `gsk_...` / `sk-ant-...`, a11y "Groq API key" /
  "Anthropic API key"), a status row that shows only "Saved" or "Not set", Save key,
  Remove key (shown only when a key is saved), and the RN note "Stored only on your
  device. Never share this key."
- Keys are stored only through `NativeKeychainSecureSettingsStore`, in the existing
  accounts `anthropicKey` and `groqKey` (contract §11). Saving is a verified upsert and
  removing is a verified remove. No second Keychain wrapper exists: the store gains an
  extension in `NativeAIProviderKeyStore.swift`.
- A save or remove republishes `AppStore`. `coachProviderSummary`, the page's saved state
  and the next coach request (and the receipt and pricebook Anthropic reads) follow at
  once, with the transport's precedence (Anthropic, then Groq, then backend).
- Owner-bound: a change is refused unless an owner is signed in and no account boundary
  is running (`authenticationOperationInFlight`, a blocked scrub or a pending scrub).
  `AppStore` now takes one injected `secureSettingsStore` (default: the system Keychain).
  The key reads and writes and every scrub wipe use it: launch recovery, `retryAccountScrub`,
  `signOut` and `deleteAccount`. So entered keys are wiped with migrated keys by
  `clearAccountValues()` (sign-out) and `clearAllValues()` (deletion).

**Decisions (contract §11.1):**
- **Masked display:** RN has no masked format, so the page shows the provider name and
  "Saved". It never shows the last 4 characters.
- **Validation:** a key must be trimmed, carry the provider prefix (`gsk_` or `sk-ant-`),
  use only `[A-Za-z0-9_-]` and be 20–512 characters long. The shared redaction screens then
  always recognize the whole key.
- **Clearing:** an empty trimmed entry is still a clear in the policy (contract §11). The
  page offers only the explicit Remove, because the field never holds the saved key.
- **Analytics hardening:** `NativeAnalyticsPrivacyPolicy.screenNameRejection` now applies
  `containsSecret`. The 11.15 redaction test found that a 56-byte Groq key passed the
  `$screen` route-name check and would have reached the SDK. `NativeSensitiveData` already
  covered both key shapes and is unchanged.

**Files:**
- New:
  - `native/TradeReadyNative/NativeAIProviderKeyPolicy.swift`: Foundation-only. It holds
    `NativeAIProviderKeyKind`, `NativeAIProviderKeyChange` and `NativeAIProviderKeyPolicy`
    (copy, trim and validation, the save/clear outcome, the masked status, the stored-value
    rule and precedence).
  - `native/TradeReadyNative/NativeAIProviderKeyStore.swift`: the
    `NativeKeychainSecureSettingsStore` extension (read, save, clear).
  - `native/AIProviderKeyTests/main.swift` and `native/run-ai-provider-key-tests.sh`.
- Edited:
  - `native/TradeReadyNative/AppStore.swift`: the `secureSettingsStore` init parameter and
    property, the scrub sites, `advisoryAnthropicKey`/`advisoryGroqKey`,
    `aiProviderKeyIsSaved`, `setAIProviderKey`, `clearAIProviderKey` and the owner gate.
  - `native/TradeReadyNative/SettingsView.swift`: `AISettings` and `AIProviderKeySection`.
  - `native/TradeReadyNative/NativeAnalytics.swift`: the screen-name secret check.
  - `native/run-appstore-sources-common.sh` and `native/run-all-domain-tests.sh`.
- Docs: contract (C19, §11.1, §15), `docs/native-parity-matrix.md` (row "AI Assistant")
  and this plan.

**Interface handoff:** `AppStore.setAIProviderKey(_:entry:)`, `clearAIProviderKey(_:)` and
`aiProviderKeyIsSaved(_:)` return or read `NativeAIProviderKeyChange`/`Bool`.
`AppStore.init(…, secureSettingsStore:)` is the injection point for host tests. 11.13
qualifies the row with the runner below.

**Commands and results:**
- RED: `TZ=America/Phoenix sh native/run-ai-provider-key-tests.sh` failed to compile before
  the implementation. The errors were "cannot find 'NativeAIProviderKeyKind' in scope" and
  "value of type 'AppStore' has no member 'setAIProviderKey'". After the policy and wiring,
  and before the view, the run failed 5 of 224 checks. Four were view checks. The fifth
  was a real finding: "a Groq key is not a valid screen name".
- GREEN: `TZ=America/Phoenix sh native/run-ai-provider-key-tests.sh` → "ai-provider-key
  tests: 224/224 checks passed". It covers:
  - the RN copy;
  - trim and validation, and blocked changes;
  - messages that never echo the entry;
  - the masked display and the stored-value rule;
  - apply with throwing stores;
  - precedence equal to `NativeCoachTransport.provider`;
  - the secure store over an in-memory backing (save, clear, read-back verification,
    migrated whitespace);
  - the owner wipe (`clearAccountValues` and `clearAllValues`, alongside a migrated key);
  - the AppStore wiring: signed out is refused; save, remove and empty-save each change
    the summary, and the coach request goes to Anthropic with `x-api-key`, then to Groq
    with `Bearer`, then to the backend; a Keychain failure is surfaced;
  - the real `signOut(revokeRemote: false)` wipe (the next owner inherits no key), and
    the real launch recovery of a pending `.all` (deletion) scrub;
  - analytics: the real `ai_chat_sent` carries `provider` only; with the key in every
    property, name, identify and screen slot, nothing reaches the adapter or diagnostics;
  - crash payloads: reports via `NativeCrashReporter` plus `redactEvent` over each
    report's error, extras, tags, contexts, breadcrumbs and request carry no key;
  - storage: no key in `UserDefaults.standard`, the App Group suite, the widget snapshot,
    the business-data files, `recordedDiagnostics` or `BusinessSettings`;
  - source checks: no logging, defaults or telemetry in the key files, `SecureField`
    only, and every scrub site uses the injected store.
- Mutation checks: 4, applied in place, run and restored. All four were killed:
  - no republish after a change (2 failures);
  - the owner gate always open (5);
  - no prefix check (6);
  - no character check (4).
- `TZ=America/Phoenix sh native/run-all-domain-tests.sh` → exit 0. The run includes
  "ai-provider-key tests: 224/224 checks passed", "Analytics transport tests passed (226
  checks)", "Analytics event tests passed (536 checks)", "error-redaction tests: 689/689
  checks passed" and "Widget owner gating tests passed".
- `xcodebuild -project native/TradeReadyNative.xcodeproj -scheme TradeReadyNative -configuration Release -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build`
  → `** BUILD SUCCEEDED **`, with no warning from a file this task touched.
- `sh native/run-doc-reference-check.sh` → 0 missing.

**Runsheet rows (Phase 12; not run, not claimed):**
- Settings › AI Assistant: switch Advanced on, save a real Groq key and then a real
  Anthropic key. After each save the Provider row reads Groq and then "Anthropic
  (Claude)", and a coach message is answered by that provider. Remove the Anthropic key:
  the coach answers through Groq. Remove both: the coach uses TradeReady AI (backend).
- VoiceOver reads "Advanced AI settings", "Groq API key" and "Anthropic API key". The
  secure field shows dots, the status reads only "Saved", and the key is never spoken.
- Sign out and sign back in: both keys are gone. Account deletion also leaves no key.
- Fix round 1: save both keys. Then take "Use another account" from "Cloud data
  unavailable" and sign in as a second account: the page shows "Not set" for both keys
  and the Provider row reads TradeReady AI. Repeat with the password-recovery link:
  cancel it (and, separately, finish it with a new password). No key survives either
  exit.
- With a Release DSN and PostHog key set: after key entry and a coach send, no Sentry
  event or PostHog event or `$screen` payload contains the key.

**Concerns:**
- ~~`useAnotherAccount` and `cancelPasswordRecovery` clear only the session and keep
  provider keys.~~ **Resolved by fix round 1 (below).** The controller ruled that keys are
  owner-bound, so both paths now wipe them.

**Next ready:** 11.10a (accessibility audit).

### 11.15 fix round 1 — owner-bound keys across switch and recovery (2026-09-24)

**Controller ruling:** AI provider keys are owner-bound, and migrated keys follow the same
rule. There are no current users, so correctness wins.

**I1 (Important), fixed:**
- `useAnotherAccount` removes `anthropicKey` and `groqKey` through the injected store
  before its first await and again after its last.
- It also holds a new `accountSwitchInFlight` flag for the whole switch, and
  `canChangeAIProviderKeys` refuses a save while it is set. The gate stayed `.signedIn`
  across `clearSession`/`logOut`, so a save could land mid-switch.
- `applyRecoverySignedOutState` wipes both keys. It is where both
  `updateRecoveredPassword` and `cancelPasswordRecovery` end.
- `dismissInvalidPasswordRecovery` wipes them when it drops an active recovery session.
- The first round's "keys kept" entries are reversed in contract §11.1, the parity row
  and the 11.15 concerns above.

**Minors:**
- **M1:** every remaining `NativeKeychainSecureSettingsStore()` in AppStore now uses the
  injected store. That covers the recovery session reads, the initial-sync and push
  session reads, and the schedule/booking session reads. The three production activator
  constructions and the test activator seam now pass `sessionStore: secureSettingsStore`.
- **M2:** the deletion fixture seeds `auxiliary-account-binding-key.v1` before the
  relaunch. The sign-out fixture now asserts the key survives (`.live`).
- **M3:** contract §11.1 notes that a new provider prefix must go into both
  `requiredPrefix` and `NativeSensitiveData.secretValuePrefixes`.
- **M4:** the status row makes one Keychain read per provider per render
  (`aiProviderKeyState`). Left as is: there are two small reads and no cache that
  could go stale.
- **M5:** new `NativeAIProviderKeyPolicy.SavedState` (`saved`, `notSet`, `unreadable`).
  A Keychain read error shows "Unavailable", not "Not set", and Remove is still offered.
  The coach still treats the key as absent.
- **M6:** the source scan brace-matches each function body to its end, skipping the
  parameter list, which can hold a default closure. It now also covers
  `useAnotherAccount`, both recovery exits and `dismissInvalidPasswordRecovery`.

**Tests (AppStore level):**
- **`useAnotherAccount`** (real success path, with the `scheduleBookingTestSeedIdentityActivator`
  seam):
  - owner A has an entered Anthropic key and an untrimmed migrated Groq key;
  - inside the `logOut` await, both keys are already gone and the summary is backend;
  - a save attempted there returns `.rejected(.groq, .unavailable)`;
  - a key written straight to the backing mid-switch is wiped after the awaits;
  - owner B inherits no key, the summary is backend, and B can then save.
- **`cancelPasswordRecovery`:** both keys wiped, summary backend, owner B inherits none.
- **`updateRecoveredPassword`:** covered by source check only. Its success path needs a
  live-configured auth client. The check proves it ends in `applyRecoverySignedOutState`,
  which wipes the keys.

**Commands and results:**
- Mutations (each applied in place, run and restored with a `cmp` check). All six were
  killed:

  | Mutation | Failures |
  |---|---|
  | Gate ignores the switch | 2 |
  | No wipe after the awaits | 5 |
  | No wipe before the first await | 3 |
  | No recovery wipe | 4 |
  | A read error shown as Not set | 1 |
  | An own store in `signOut` | 2 |

- `TZ=America/Phoenix sh native/run-ai-provider-key-tests.sh` → `ai-provider-key tests: 274/274 checks passed`
- `TZ=America/Phoenix sh native/run-widget-owner-gating-tests.sh` → `Widget owner gating tests passed`
- `TZ=America/Phoenix sh native/run-store-integration-tests.sh` → `PASS: canonical AppStore integration tests`
- `TZ=America/Phoenix sh native/run-all-domain-tests.sh` → exit 0. The output includes
  `Analytics transport tests passed (226 checks)`,
  `Analytics event tests passed (536 checks)`,
  `error-redaction tests: 689/689 checks passed`, `ai-provider-key tests: 274/274 checks passed`
  and node `fail 0`.
- Release `xcodebuild … CODE_SIGNING_ALLOWED=NO build` → `** BUILD SUCCEEDED **`, with no
  warnings from touched files.
- `sh native/run-doc-reference-check.sh` → 0 missing.

**Residual concern:** the boundary wipe uses `try?` for each account, so a Keychain
remove failure is not fatal to the switch or the recovery exit. The switch's second wipe
retries it. A persistent remove failure would leave the key until the next sign-out or
deletion scrub, which does fail closed.

**Next ready:** 11.10a (accessibility audit).

### 11.10a — Accessibility audit and remediation (2026-09-24)

**Status:** Done (steps 1–4). All four §12 release-blocking candidates are fixed and
host-tested. Contract §12.1 lists 19 findings: 0 release-blocking findings are open, A14–A18
go to 11.10b, A11 goes to 11.11, and A12, A13 and A19 are deferred to device. **H1 is not
closed.** 11.10b re-audits after 11.11 and 11.12.

**Controller rulings applied:**
- (a) `tradeReady` has a dark variant, and the light value is unchanged. Contrast is proven
  by a pure luminance computation in the host suite.
- (b) Step 4 is the audit plus focus-order fixes. Keyboard shortcuts go to 11.11.

**Files:**
- New policy file: `N/Domain/NativeAccessibilityAudit.swift` (Foundation-only). It holds:
  - the WCAG luminance, contrast and compositing math;
  - the palette and the contrast-requirement table;
  - the Reduce Motion policy;
  - the 44pt touch target;
  - the RN label catalog.
- New view helpers: `N/NativeAccessibilityViews.swift`. They are
  `tradeReadyProminentButtonStyle()`, `NativeAccessibilityAdaptiveRow` and
  `NativeAccessibilityColumnDivider`.
- New tests: `native/AccessibilityAuditTests/main.swift` and
  `native/run-accessibility-audit-tests.sh`. The runner is registered in
  `native/run-all-domain-tests.sh`.
- `native/run-schedule-booking-settings-tests.sh` now compiles the audit file, because
  `NativeScheduleSettingsView.swift` uses its touch-target constant.
- Palette:
  - `N/Models.swift`: dynamic `tradeReady`, plus the new `tradeReadyFill`.
  - `N/Assets.xcassets/AccentColor.colorset/Contents.json`: light and dark tint.
- Views: `CoachView`, `Components`, `CustomersView`, `InvoicesView`, `JobsView`,
  `MoneyView`, `NativeAuthView`, `NativeBookingRequestsView`, `NativeChangeOrdersView`,
  `NativeEstimateFollowUpView`, `NativeEstimateReview`, `NativeExpenseEditor`,
  `NativeExportDataView`, `NativeImportView`, `NativeInteractionState`,
  `NativeInvoiceOutreachView`, `NativeMessageComposer`, `NativeMileageLogView`,
  `NativeMoneyCards`, `NativeOnboardingView`, `NativePasswordRecoveryView`,
  `NativePaywallView`, `NativePricebookView`, `NativeRecurringInvoicesView`,
  `NativeReviewRequestView`, `NativeRouteView`, `NativeScheduleSettingsView`,
  `NativeTimeTrackingView`, `NativeTodayComponents`, `NativeTripEditor`, `RootView` and
  `SettingsView`. Every edit is a local modifier or label change. No view was restructured,
  and none now holds policy.
- Untouched: the 11.08 `$screen` analytics and the 11.15 Settings › Advanced section.

**Interface handoff:**
- **Color:**
  - `Color.tradeReady` is for text, icons, outlines and graphics.
  - `Color.tradeReadyFill` is for any opaque surface under white text or icons.
  - Use `.tradeReadyProminentButtonStyle()`, never raw `.borderedProminent`. The only
    exception is the time-tracking re-tint.
  - The suite fails on a new raw prominent button. It also fails on a new opaque
    `tradeReady` fill outside the allowlist: `NativeMoneyCards` 3 and
    `NativeTodayComponents` 2 (chart bars and dots).
- **Motion:** every `withAnimation`/`.animation(` in `N/` must pass
  `NativeAccessibilityAudit.allowsCustomMotion(reduceMotion:)`.
- **Type:**
  - No `.font(.system(size: <literal>))` outside `N/Widgets/`.
  - Use `@ScaledMetric` or a text style.
  - For multi-column figure rows, use `NativeAccessibilityAdaptiveRow` (it stacks at AX
    sizes) with `NativeAccessibilityColumnDivider`.
- **Labels:**
  - Every icon-only `Button`, `Menu`, `NavigationLink`, `ShareLink` or `Link` needs an
    `.accessibilityLabel`. The scan reads each construct to the end of its trailing
    closures and modifier chain.
  - New RN-backed strings go in `NativeAccessibilityAudit.labelCatalog`.
- **For 11.11:** hardware keyboard shortcuts and iPad keyboard commands (A11). The
  `@FocusState` chains in auth and recovery are what those shortcuts build on.
- **For 11.10b:** A14–A18, plus the re-audit after 11.11 and 11.12.

**Commands and results:**
- RED: the new suite run against the pre-fix views → 117 of 439 checks failed.
- GREEN: `TZ=America/Phoenix sh native/run-accessibility-audit-tests.sh` →
  `accessibility-audit tests: 421/421 checks passed`.
  - The count differs from RED because many checks run once per matching source site,
    so the number of checks follows the source being scanned.
  - The suite scans at least 100 files and 300 controls.
  - A built-in fixture checks the scanner itself: 7 controls, 4 icon-only, unlabeled
    lines [12, 15].
- Mutations (each applied in place, run and restored with a `cmp` check). All nine were
  killed:

  | Mutation | Failures |
  |---|---|
  | Dark tint reverted to the light value | 1 |
  | `addJob` label removed | 4 |
  | Coach scroll ignores Reduce Motion | 1 |
  | A raw `.borderedProminent` | 1 |
  | Working day back to 36pt | 1 |
  | Email Next does nothing | 1 |
  | White text on the dark tint | 2 |
  | A fixed 8pt font | 1 |
  | Route menu label removed | 4 |

- `TZ=America/Phoenix sh native/run-schedule-booking-settings-tests.sh` →
  `ScheduleBookingSettingsTests: all checks passed`
- `TZ=America/Phoenix sh native/run-interaction-state-tests.sh` → pass
- `TZ=America/Phoenix sh native/run-all-domain-tests.sh` → exit 0. The output includes
  `accessibility-audit tests: 421/421 checks passed`, `ai-provider-key tests: 274/274 checks passed`,
  `error-redaction tests: 691/691 checks passed`, `ScheduleBookingSettingsTests: all checks passed`
  and node `fail 0`.
- Release `xcodebuild … CODE_SIGNING_ALLOWED=NO build` → `** BUILD SUCCEEDED **`, with no
  warnings from touched files.
- `sh native/run-doc-reference-check.sh` → 0 missing.

**Deviations (native differences from RN, recorded in contract §12.1):**
- The dark `tradeReadyFill` `#2f78c4` is native only. RN puts white text on `#5b9bdb`,
  which measures 2.93:1.
- The auth email field's return key moves to the password field. RN uses "done".
- The recovery "New password" field's return key moves to the confirmation field.
- The Today week strip is capped at AX1.
- The booking "Text {name}" label and the route "Route order options" label are native
  only. RN has no matching icon button for either.
- `AccentColor` changed from `(0.05, 0.53, 0.85)` to the brand tint with a dark variant.
- `run-schedule-booking-settings-tests.sh` gained one source line. It is outside the listed
  runner work, but the runner does not compile without it.

**Runsheet rows (Phase 12; not run, not claimed):**

| Row | Step | Pass when |
|---|---|---|
| A11-VO-1 | VoiceOver sweep of the tabs Today, Jobs, Invoices, Customers, Money and Settings, plus the booking, route and recurring plus buttons | Every control reads a meaningful label, and none reads as "Button" or "plus" |
| A11-VO-2 | Today job card: reach "On my way" with VoiceOver (A13) | It is reachable and actionable; if not, open an 11.10b item |
| A11-VO-3 | Reading order on Today, Money and the Job detail screen (A12) | Order follows the visual layout |
| A11-AX5-1 | AX5 on the Money cards (summary, receivables, forecast, customer mix, seasonal, avg job, expense trends), the Today stats, the Jobs stats and the Invoices metrics | Rows stack, and no amount is truncated or split |
| A11-AX5-2 | AX5 on the auth and recovery submit buttons, the paywall and onboarding | Labels are not clipped, and the buttons grow |
| A11-AX5-3 | AX5 on the week strip | It is capped at AX1 without overlap, and VoiceOver reads each day |
| A11-DARK-1 | Dark mode: tint text and outlines, prominent buttons, selected chips, week day, Today hero, working days | Text is legible, the selected state is visible, and white labels sit on the fill |
| A11-RM-1 | Reduce Motion on: Money section expand, coach scroll-to-bottom | The change happens without animation |
| A11-SC-1 | Switch Control on auth (email → password → submit), schedule working days and route reorder | Items are reachable in order, and the 44pt targets can be activated |
| A11-KB-1 | Hardware keyboard auth and recovery: Return chains (with 11.11 shortcuts) | Email → password → submit; new password → confirmation → submit |
| A11-TT-1 | Touch targets: week arrows, route chevrons, working days | Each reliably hits on the first tap |
| A11-IC-1 | Increase Contrast on and off, in light and dark | No regressions against the §12.1 table |
| A11-W-1 | Widgets at AX sizes (A9) | The fixed canvas is legible, matching RN |

**Concerns:**
- Device-only proof (VoiceOver, Switch Control, AX5, Increase Contrast) is deferred to
  Phase 12, as the rows above record. None is claimed as passed.
- A14–A18 are non-blocking and go to 11.10b.

**Next ready:** 11.11 (iPad layouts, multitasking and rotation).

### 11.10a fix round 1 — week-strip cap, hero contrast, Money card VoiceOver (2026-09-24)

**I1 (Important), fixed:**
- The day circle's `@ScaledMetric` sat on `NativeTodayWeekStripView`, outside the
  `.dynamicTypeSize(...accessibility1)` cap on the inner HStack. At AX5 it reached about
  98pt and pushed the arrows off-screen.
- Each day is now a `NativeTodayWeekDayButton` built inside the capped subtree, and the
  metric lives there. The circle is also clamped:
  `NativeAccessibilityAudit.WeekStrip.dayCircleSize(scaled:)` has a 34pt maximum.
- The clamp is sized for a 375pt phone: 375 − 40pt of chrome (16×2 screen padding and
  4×2 card padding) − two 44pt arrows leaves 247pt, and 247 ÷ 7 = 35.3pt per column. On a
  393pt phone each column gets 37.9pt.
- The days and both arrows now use `.accessibilityShowsLargeContentViewer()`.

**I2 (Important), fixed:**
- The Today hero subtitle is solid white. At 85% it measured 3.76:1 on the dark fill.
- New `contrastRequirements` rows: hero subtitle on the fill (light 6.82, dark 4.56) and
  the hero icon on its 18% white disc (4.53 and 3.34, against the 3:1 UI minimum).
- New scan: no translucent white foreground anywhere outside `N/Widgets/`. The only other
  site in the diff was the hero disc, which is a fill and is covered by the icon row.

**I3 (Important), fixed; A14 corrected in contract §12.1:**
- `NativeMoneyCard` has two open branches:
  - with an RN label: `.accessibilityLabel` plus `.accessibilityValue`;
  - without one: `.accessibilityElement(children: .combine)` plus the button trait, so
    the title and figures are read.
- Mileage and Pricebook use the second branch. RN `MileageCard.tsx` and
  `PricebookCard.tsx` set no label, and the test asserts that.
- The tax card passes RN's exact "Tax set-aside — open settings" label
  (`Label.taxSetAsideOpen`, catalog-checked against `components/money/TaxSetAsideCard.tsx`),
  with `card.reserveText` as the value.
- The native tax card has no open action yet, because there is no native tax-settings
  screen. It stays a static card that VoiceOver reads in full. The label takes effect once
  a destination is wired.

**Minors:**
- **m1:** the test asserts the body of `submitEmail()`. The file-wide
  `focusedField = .password` search is gone, because Show/Hide also contains that
  assignment.
- **m2:**
  - Every animation must pass `allowsCustomMotion(reduceMotion: reduceMotion)` with the
    environment binding.
  - `hasAccessibilityLabel` counts only a non-empty label on the control's own chain or
    label closure, so `""`, a label on a Button nested in a Menu, and a label in the
    action closure do not count.
  - The fixture grew to 11 controls, 8 icon-only, and unlabeled lines
    [12, 15, 18, 19, 22].
- **m3:** fixed rather than deferred. The undo-banner dismiss and the time-off trash
  button now have 44×44 targets (A21).
- **m4:** recorded as A22. The rows grow and the layout is accepted for now; the 11.11
  layout pass handles it and 11.10b re-checks.
- **m5:** the Show/Hide refocus runs in `Task { @MainActor in … }`, the next turn (A23).
  Device proof is in rows A11-KB-1 and A11-SC-1.
- **m6:** A24 records that step 4 audited only the auth and recovery forms. The other
  editors' return-key chains go to 11.10b.

**Commands and results:**
- Mutations (applied in place with `perl`, run and restored with a `cmp` check). All 11
  were killed:

  | Mutation | Failures |
  |---|---|
  | Clamp removed | 1 |
  | Clamp at 40pt | 2 |
  | Metric back on the strip | 1 |
  | Subtitle at 85% | 2 |
  | "{title}, open" label restored | 4 |
  | Tax label dropped | 2 |
  | `submitEmail` gutted | 1 |
  | Coach passes a literal `false` | 1 |
  | `addJob` label `""` | 4 |
  | Trash back to glyph size | 1 |
  | Refocus in the same update | 1 |

- `TZ=America/Phoenix sh native/run-accessibility-audit-tests.sh` →
  `accessibility-audit tests: 471/471 checks passed`
- `TZ=America/Phoenix sh native/run-all-domain-tests.sh` → exit 0. The output includes `accessibility-audit tests: 471/471 checks passed`,
  `ScheduleBookingSettingsTests: all checks passed` and node `fail 0`.
- Release `xcodebuild … CODE_SIGNING_ALLOWED=NO build` → `** BUILD SUCCEEDED **`, with no
  warnings from touched files.
- `sh native/run-doc-reference-check.sh` → 0 missing.

**Open for 11.10b:** A15–A18, A22 and A24 (all non-blocking). Release-blocking findings
open: 0. H1 stays open.

**Next ready:** 11.11 (iPad layouts, multitasking and rotation).

### 11.11 — iPad layouts, multitasking and rotation (2026-09-24)

**Status:** Done (steps 1–3, plus contract §12.1 A11). The native analog of RN
`layout.contentColumn` is on every list, form and scroll screen. The navigation structure
and the multitasking manifest are verified. The hardware-keyboard shortcut policy is in
place. Device proof is deferred to Phase 12 (rows below). Contract §12.2 holds the
constants, the measured SwiftUI behavior, the screen disposition and the recorded native
differences.

**Controller rulings applied:**
- The shared metric is 700pt, centered, and full width below that. The width math is
  Foundation-only in `N/NativeLayoutMetrics.swift`, and the small view modifiers sit in
  the same file, guarded by `canImport(SwiftUI)` (so the macOS host runners that compile
  view files compile them too).
- The default structure is kept: one `TabView` plus a centered column, with no
  `NavigationSplitView`.
- A11 scope: an audit, Tab/Return focus behavior, and standard shortcuts on existing
  toolbar save, cancel and new actions. No custom command menus.
- A16, A22 and A24 stay with 11.10b. The 11.08 `$screen` modifiers are untouched.

**Files:**
- New policy file: `N/NativeLayoutMetrics.swift`. It holds `contentMaxWidth` (700),
  `listMinimumSideInset` (20), `horizontalContentMargin(for:in:)` and
  `columnWidth(for:in:)`. Under `#if canImport(SwiftUI)` it also defines
  `.nativeContentColumn(.list|.scroll)` (`contentMargins` plus `onGeometryChange`) and
  `.nativeContentColumnFrame()`.
- New tests: `native/LayoutMetricsTests/main.swift` and
  `native/run-layout-metrics-tests.sh`. The runner is registered in
  `native/run-all-domain-tests.sh`. `native/run-calendar-editor-tests.sh` and
  `native/run-schedule-booking-settings-tests.sh` compile view files on macOS, so they
  now also compile `N/NativeLayoutMetrics.swift`.
- New shared test support: `native/HostTestSupport/SwiftSourceScan.swift` holds
  `SourceFile`, `SourceMasker`, `loadSources`, `read`, `functionBody` and `structText`.
  It was moved unchanged out of `native/AccessibilityAuditTests/main.swift`, and
  `native/run-accessibility-audit-tests.sh` compiles it.
- Views (58 scroll roots, 12 fixed-chrome sites and 46 shortcuts, all local modifier
  edits): `CoachView`, `Components`, `CustomersView`, `InvoicesView`, `JobsView`,
  `MoneyView`, `NativeAuthView`, `NativeBookingRequestsView`, `NativeBookingSettingsView`,
  `NativeCalendarView`, `NativeChangeOrdersView`, `NativeCreateInvoiceFromJobView`,
  `NativeCustomerPortalView`, `NativeEstimateFollowUpView`, `NativeEstimateReview`,
  `NativeExpenseEditor`, `NativeExportDataView`, `NativeGlobalSearch`, `NativeImportView`,
  `NativeInvoiceOutreachView`, `NativeJobPhotosView`, `NativeJobProfitabilityView`,
  `NativeMessageComposer`, `NativeMileageLogView`, `NativeOnboardingView`,
  `NativePasswordRecoveryView`, `NativePaywallView`, `NativePricebookEntryView`,
  `NativePricebookView`, `NativePricingCalculator`, `NativeRecurringInvoicesView`,
  `NativeRecurringJobsView`, `NativeReviewRequestView`, `NativeRouteView`,
  `NativeScheduleEditorView`, `NativeScheduleSettingsView`, `NativeTemplatePickerView`,
  `NativeTripEditor`, `RootView`, `SettingsView` and `TodayView`.
  - No view was restructured, and none holds policy.
  - `RootView` gained only an Esc shortcut on the deep-link notice's Done.
  - `SettingsView` lost its hand-rolled `.frame(maxWidth: 700)`.
- Unchanged: `native/Info.plist` (checked), `project.pbxproj`, and everything under
  `targets/`, `backend*/`, `__tests__/`, `supabase/`, `utils/` and `types/`.

**Interface handoff:**
- **New screens:**
  - Put `.nativeContentColumn(.list)` directly on a screen's `List`/`Form`, or
    `.nativeContentColumn(.scroll)` on its vertical `ScrollView`.
  - Put `.nativeContentColumnFrame()` on non-scrolling chrome, before its background.
  - Then add the root to `scrollRootInventory` in `native/LayoutMetricsTests/main.swift`.
    The suite fails on an unknown root, a missing root, a wrong kind, or a column placed
    only on a nested view.
  - A host runner that compiles a view using the column must also compile
    `N/NativeLayoutMetrics.swift`. The suite checks every `native/run-*.sh`, honoring its
    `-D` flags.
- **Width caps:** no new literal `maxWidth:` of 300pt or more. No fixed `width:`,
  `minWidth:` or `idealWidth:` of 320pt or more (Slide Over). No `UIScreen` sizing and no
  `.ignoresSafeArea(.keyboard)`.
- **Navigation:**
  - Keep one `TabView` and no split view.
  - A view whose body is a `NavigationStack` may only be a tab root, a gate root or
    presented (`.sheet`, `.fullScreenCover`, `.popover`). Never push it.
- **Keyboard:** a new toolbar action follows the §12.2 table:
  - Esc on cancel or dismiss;
  - ⌘S on save;
  - ⌘N on an existing "new" action;
  - nothing on a destructive action.

  The suite counts every `.keyboardShortcut` in `N/`, and custom command menus fail it.
- **For 11.10b:** re-audit A16, A22 and A24 with the column in place. Return-key chains for
  the other editors are still open (A24).
- **For 11.12:** `onGeometryChange` runs once per scroll root on each size change. The
  Stage Manager resize row covers layout thrash on device.

**Commands and results:**
- Probe (throwaway app in the scratchpad, iOS 26 Simulator, not committed):
  - Before the modifier: `contentMargins` on a `List` replaces the row inset and is
    measured from the outer edge. On a landscape Pro Max, a margin of 30 was clamped to
    the 62pt safe area, and a margin of 100 put the row edge at 100. On a `ScrollView`
    the margin is added inside the safe area. `safeAreaPadding` does not move `List`
    rows.
  - With `.nativeContentColumn`:
    - iPad 11-inch portrait (834pt): list rows 67…767 and scroll content 83…751.
    - Pro Max landscape: list rows 128…828 and scroll content 144…812.
    - Phone portrait: unchanged.
- RED: the new suite against HEAD's views, with the policy file present →
  `layout-metrics tests: 119 of 752 checks FAILED`. The failures were 58 scroll roots, 12
  chrome sites, the Settings literal cap, 41 toolbar shortcuts, 5 ⌘N sites and the
  shortcut total. The inventory, navigation, manifest and fixed-width checks already
  passed. Two scanner false positives (a `NavigationStack` inside a type's own `.sheet`)
  were fixed in the scanner before GREEN.
- GREEN: `TZ=America/Phoenix sh native/run-layout-metrics-tests.sh` →
  `layout-metrics tests: 752/752 checks passed`. After the host-runner check was added
  (see the aggregate below), the result is `757/757 checks passed`.
- `TZ=America/Phoenix sh native/run-accessibility-audit-tests.sh` →
  `accessibility-audit tests: 472/472 checks passed`. It was 471/471 before the
  extraction and after it. The +1 is the per-file scan of the new
  `N/NativeLayoutMetrics.swift` (471 with that file moved aside).
- Mutations (applied in place with `perl`, run and restored with a `cmp` check). All 20
  were killed:

  | Mutation | Failures |
  |---|---|
  | Jobs list column removed | 1 |
  | Today scroll kind → `.list` | 1 |
  | `SettingsPage` column removed | 1 |
  | Coach composer frame removed | 1 |
  | Editor Save loses ⌘S | 2 |
  | Destructive delete gets Return | 2 |
  | Recurring jobs pushed instead of presented | 1 |
  | Split view adopted in `RootView` | 1 |
  | 400pt fixed width | 1 |
  | `UIScreen` sizing | 1 |
  | New uncapped `List` screen | 3 |
  | Hand-rolled 700pt cap | 1 |
  | Custom command menu | 1 |
  | Policy: list inset floor 0 | 3 |
  | Policy: list margin measured inside the safe area | 9 |
  | Policy: 768pt column | 33 |
  | `UIRequiresFullScreen` added to `Info.plist` | 1 |
  | Coach ⌘N removed | 2 |
  | Calendar editor runner drops `NativeLayoutMetrics.swift` | 1 |
  | Schedule/booking settings runner drops `NativeLayoutMetrics.swift` | 1 |

- Aggregate: `TZ=America/Phoenix sh native/run-all-domain-tests.sh`.
  - First run: exit 1 at `native/run-schedule-booking-settings-tests.sh`, with `error: value
    of type 'some View' has no member 'nativeContentColumnFrame'` (see Deviations).
  - After the fix: `aggregate exit=0`. The run includes `accessibility-audit tests: 472/472
    checks passed`, `layout-metrics tests: 757/757 checks passed`,
    `ScheduleBookingSettingsTests: all checks passed` and `PASS: native calendar editor
    tests`. The trailing node suite reports `fail 0`.
  - The run covers the working tree, including other agents' uncommitted backend changes.
- Release `xcodebuild … CODE_SIGNING_ALLOWED=NO build` → `** BUILD SUCCEEDED **`. The only
  warnings in touched files are pre-existing ones on untouched lines:
  `NativeChangeOrdersView.swift` 391/464/465/477 (Swift 6 isolation) and `TodayView.swift`
  335/361 (unused `MainActor.run` result).
- `sh native/run-doc-reference-check.sh` → 0 missing.

**Deviations:**
- Native differences 1–8 are recorded in contract §12.2: list row width, the retained form
  cards, Settings padding, chrome backgrounds, the calendar cap, tab-bar placement on
  iPadOS 18+, native-only shortcuts, and list engagement at 740pt.
- The source model moved into `native/HostTestSupport/SwiftSourceScan.swift`, so the
  11.10a suite's source changed (a pure move, 471 checks unchanged). This is outside the
  listed Own files. It keeps one masker instead of two copies.
- The first aggregate run failed (exit 1) at
  `native/run-schedule-booking-settings-tests.sh`. That runner and
  `native/run-calendar-editor-tests.sh` compile `NativeCalendarView`,
  `NativeScheduleEditorView`, `NativeScheduleSettingsView` and `NativeBookingSettingsView`
  on macOS, where the `canImport(UIKit)` modifiers did not exist. The fix:
  - the modifiers are now guarded by `canImport(SwiftUI)`, which is identical on iOS;
  - both runners compile `N/NativeLayoutMetrics.swift`;
  - the layout suite gained a host-runner check (RED: the two runner mutations above).

  The second aggregate run is recorded above.
- The change-order Confirm uses ⌘⏎ rather than a bare Return, so recording a customer's
  decision takes a deliberate key chord.

**Runsheet rows (Phase 12; not run, not claimed):**

| Row | Step | Pass when |
|---|---|---|
| IPAD-L-1 | iPad 11-inch (portrait and landscape) and iPad mini (portrait): Today, Jobs, Invoices, Customers, Money, Coach, Settings and one editor sheet | Content is in a centered column of about 700pt; the scroll area, indicators and backgrounds are full width; nothing is clipped |
| IPAD-L-2 | iPad 13-inch landscape, and a large sheet under Stage Manager | Sheet content is capped at 700pt, and the calendar and route sheets read correctly |
| IPAD-L-3 | iPhone Pro Max landscape: Jobs and Today | The column is 700pt inside the safe areas, and portrait is unchanged |
| IPAD-L-4 | iOS 17 floor (iPhone SE-class; an iPad on iPadOS 17): a list wider than 740pt | Rows sit at the computed margin as measured on iOS 26; if not, open an 11.10b item |
| IPAD-MT-1 | Split View at 1/3, 1/2 and 2/3 beside another app, in both orientations | No clipping; narrow widths are full width; one tab bar and one navigation bar |
| IPAD-MT-2 | Slide Over (320pt): every tab plus the job, invoice and expense editors | Everything is usable without horizontal clipping |
| IPAD-MT-3 | Stage Manager: drag a window's width slowly across 690–760pt on a list and a scroll screen; also open a wide screen (and a large sheet) fresh | The column engages without a jump or a layout loop. On first appearance the column's geometry starts at zero, so the first layout pass uses the system inset and the column applies on the next pass (`onGeometryChange` reports in the same update); record any visible one-frame shift (review M6; not seeded, because the container width is unknown before layout) |
| IPAD-ROT-1 | Rotate through all four iPad orientations with a pushed detail, an open sheet and the keyboard up | State is kept, no second navigation bar appears, the focused field stays visible, and the Coach composer rises with the keyboard |
| IPAD-KB-1 | Hardware keyboard: Esc on Cancel/Done in editors and sheets, ⌘S to save, ⌘⏎ on the change-order Confirm, ⌘N on Jobs, Invoices, Customers, Maintenance plans and Coach. Then: ⌘N with each owner's sheets, dialogs and alerts up (the maintenance-plan edit sheet in particular); ⌘N on Maintenance plans pushed on the Invoices stack (two ⌘N buttons in one `NavigationStack`); ⌘N on a pushed job, invoice or customer; Esc with a UIKit child sheet (message composer, share sheet) over an editor | Each fires once, only for the visible screen. ⌘N does nothing while its owner presents anything or has a screen pushed over it (fix round 1 gating; Simulator-verified on iPadOS 26.5, see the fix round 1 entry), and on Maintenance plans it opens a new plan, not a new invoice. Esc dismisses only the top sheet and never runs the parent editor's Cancel. No key triggers the delete-account Delete |
| IPAD-KB-2 | Tab and Shift-Tab through the job, invoice, customer and expense editors; Return in a single-line field and in the Coach field | Focus follows the visual order; Return ends editing (a newline in Coach). Pairs with A11-KB-1 |
| IPAD-AX-1 | AX5 Dynamic Type on iPad in 1/2 Split View: Money cards, Today stats, editors | The column and the 11.10a AX stacks do not clip |

**Concerns:**
- SwiftUI's `contentMargins` behavior on a `List` was measured on the iOS 26 runtime only
  (row IPAD-L-4 covers the iOS 17 floor).
- ~~⌘N under a sheet is harmless~~ — wrong, corrected by fix round 1. The presenter's
  ⌘N does fire under its own sheet (measured), and in the maintenance-plan editor that
  turned an open edit into a create. Every ⌘N is now gated; see the fix round 1 entry.


### 11.11 fix round 1 — gated ⌘N, confirmation-title allowlist, focus scan (2026-09-24)

**Status:** Done. This round fixes review finding I1 (Important) and minors M1–M4 and M6.
M5 (optional) is partly done.

**I1: ⌘N under a modal was not harmless (fixed).**
- **Measured.** The iPadOS 26.5 Simulator received real hardware-key events: System Events
  keystrokes to the Simulator window, with the Simulator's hardware keyboard connected and
  ⌘N and Esc unbound in its menus. The target was a throwaway probe app mirroring these
  structures, not the signed-in app: `TabView` → Invoices `NavigationStack(path:)` →
  Maintenance plans → shared edit/new sheet. Each scenario ran twice with a ⌘J canary that
  logs which screen received the key.
  - With the edit sheet open, ungated ⌘N fired the list's "+", and the open editor's plan
    became `nil`, so Save would take the create branch.
  - With the plans screen pushed, ungated ⌘N fired the *hidden* Invoices "+" instead of the
    visible plans "+" (review M4). Two ⌘N buttons in one stack resolve to the root's.
  - Gated, both cases behave correctly: nothing fires under the sheet, and the plans "+"
    fires when pushed.
- **Fix.** All five ⌘N owners (`JobsView`, `InvoicesView`, `CustomersView`,
  `NativeRecurringInvoicesView` and `CoachView`) now declare:
  - `isPresentingAnything`: every state driving one of their sheets, dialogs, alerts or
    confirmations, plus the Invoices bulk-reminder queue between composer sheets;
  - `newShortcut`: `nil` while anything is presented, while the stack path is non-empty,
    or while the root is not visible.

  `isRootVisible` is maintained by the root's `onAppear` and `onDisappear`, which covers
  the path-less maintenance-plans push. The button uses `.keyboardShortcut(newShortcut)`,
  and its action starts with `guard !isPresentingAnything else { return }`.
- **Maintenance-plan editor.** It moved to one `sheet(item:)` carrying the plan
  (`PlanEditorTarget.new` / `.edit(plan)`). The probe showed that `sheet(isPresented:)` with
  a separate `editingRule` opens "Edit plan" as the create form whenever the body does not
  otherwise read that state, which the shipped code did not (a pre-existing latent bug with
  the same duplicate-plan outcome).
- **Other presenters' Esc.** Esc under a SwiftUI or UIKit child sheet dismisses only the
  child, and the parent editor's Cancel did not run (measured). Esc in a sheet with
  `interactiveDismissDisabled` runs that sheet's `.cancelAction` Cancel. The only such
  sheet is delete-account, whose Cancel is disabled while deleting. A `TabView`-level sheet
  (RootView's notices) does not leak ⌘N to the tab under it. No other gating was needed.
- **New suite check** (`testNewShortcutGating`). For each ⌘N site it reads every
  presentation the owner makes: `sheet`, `fullScreenCover`, `popover`, `alert`,
  `confirmationDialog`, `nativeConfirmation`, file and photo pickers, and `inspector`.
  Presentations nested inside another presentation's content are excluded. The check
  fails if:
  - a presentation's driving state is not in `isPresentingAnything`;
  - a presentation's driver cannot be read, so a new binding shape fails loudly;
  - the path or root-visibility gate is missing;
  - the action guard is missing.

**Minors:**
- **M1.** The stale "UIKit-only / excluded" wording in
  `native/run-layout-metrics-tests.sh` and in the 11.11 entry now names
  `canImport(SwiftUI)`.
- **M2.** `expectedShortcut` uses a title allowlist (`confirmationShortcutPolicy`). An
  unlisted `.confirmationAction` title fails instead of defaulting to ⌘S, and the scanner
  fixture covers it.
- **M3.** The suite fails on `.focusable`, `.focusDisabled` or `.focusEffectDisabled` in
  `N/`. None exist, so "N/ never disables focus" is now enforced.
- **M4.** The two ⌘N buttons in one stack are resolved by the root-visibility gate
  (measured above). Row IPAD-KB-1 now covers them, pushed-detail ⌘N and Esc over a UIKit
  child sheet.
- **M6.** Recorded in IPAD-MT-3, not seeded, because the container width is unknown
  before the first layout pass.
- **M5 (optional).** The two unused `MainActor.run` results in `N/TodayView.swift` are
  fixed. The `NativeChangeOrdersView` Swift 6 isolation warnings are not trivial and are
  left as they are.

**Commands and results:**
- RED: after adding the checks, against the ungated views →
  `layout-metrics tests: 15 of 780 checks FAILED`. The failures were five ungated ⌘N
  sites, five missing action guards and five missing gates.
- GREEN: `TZ=America/Phoenix sh native/run-layout-metrics-tests.sh` →
  `layout-metrics tests: 821/821 checks passed`
- `TZ=America/Phoenix sh native/run-accessibility-audit-tests.sh` →
  `accessibility-audit tests: 472/472 checks passed`
- Mutations: 11 applied in place with `perl`, run and restored with a `cmp` check. All
  were caught, each with one failure unless noted:

  | Mutation | Result |
  |---|---|
  | Jobs gate drops `confirmationRequest` | caught |
  | Customers `newShortcut` ignores `path` | caught |
  | Invoices `onDisappear` dropped | caught |
  | Recurring action guard dropped | caught |
  | Invoices gate drops `bulkQueue` | caught |
  | Customers adds an ungated `.alert` | caught |
  | Coach adds a `.sheet` with an unreadable driver | caught |
  | Coach `newShortcut` ungated | caught |
  | Jobs literal ⌘N | caught |
  | M2: "Close" renamed "Dismiss" | caught (2 failures) |
  | M3: `.focusable(false)` | caught |

- Release compile (`xcodebuild … -configuration Release -destination 'generic/platform=iOS'
  CODE_SIGNING_ALLOWED=NO build`) → `** BUILD SUCCEEDED **`, with no warnings in the six
  touched views.
- `TZ=America/Phoenix sh native/run-all-domain-tests.sh` → `aggregate exit=0` (62 `PASS`
  lines). This included the layout-metrics suite (821/821) and the accessibility suite
  (472/472). The working tree includes other agents' uncommitted backend changes.
- `sh native/run-doc-reference-check.sh` → `1551 path references checked: 0 missing, 17
  planned (not yet created).`

**Phase 12 (not claimed):**
- The probe is not the signed-in app. IPAD-KB-1 repeats these cases on device in the
  real screens.
- A programmatic pop in the probe left no key focus in either build, so the pop-back case
  is measured only through the tab hop. IPAD-KB-1 covers a user pop.

**Next ready:** 11.12 (performance, launch time and device soak).

### 11.12 — Performance, launch time and device soak (2026-09-24)

**Status:** Done (steps 1–4). Signposts are in place, the three required
poor-network scenarios pass, and the measurement and soak protocol names a Phase 12
owner for every row (`docs/native-phase-11-performance.md`). No behavior changed in the
first commit (`c4e040a`). One real data-loss bug was found (the finding below) and was
**fixed** in fix round 1 (`36a08dc`, entry below). Device numbers are deferred to
Phase 12 Stage A (12.04).

**Finding D: an edit during an in-flight delta pull is reverted and can be lost (fixed in `36a08dc`; see fix round 1 below).**
- **Contract.** `N/NativeSyncCoordinator.swift`: "Never let a remote pull overwrite
  canonical records that still have a local mutation waiting to reach the server." The
  pass checks the queue *before* the pull.
- **Defect.** `pullDeltaAndCommit` (formerly the body of `pullDeltaIfPossible`) merges
  into `localSnapshot`, which it captured before its network await, and commits that
  result. An edit saved during the await is queued (and its trigger coalesces), but the
  commit reverts it in memory and on disk. Online, the coalesced rerun pushes it and
  pulls it back, so the revert is transient. If the link drops first, the device shows
  the old value. A second edit to the same record is then built from the reverted
  record, and last-writer-wins replaces the queued first edit, which is lost.
- **Evidence (before the fix).** In `native/PoorNetworkTests/main.swift` scenario D (a
  held first page, an edit, then a drop), then gated behind an environment switch, gave
  `poor-network tests: 3 of 150 checks FAILED`:
  - the memory title after the commit is the pre-edit value;
  - the disk title is the pre-edit value;
  - after reconnecting, the server title is the pre-edit value (the first edit is
    lost).

  At this commit the repro was gated (a `SKIP: D …` line); fix round 1 removed the gate.
- **Options put to the controller** (the ruling chose a variant of the second, and
  rejected the third):
  - discard a pull whose base snapshot changed during the await, and leave the
    cursors;
  - re-apply pending queue items over the candidate before commit;
  - skip commit while the queue is non-empty (this also changes the booking/portal
    recovery callers).

  Superseded by fix round 1 below.

**Files:**
- New facade: `N/NativePerformanceMetrics.swift`.
  - `NativePerformanceInterval` has eight cases, each with a `StaticString` name.
  - `NativePerformanceOutcome` has four words.
  - `NativePerformanceMetrics.shared` provides `begin`/`end` (idempotent), `measure`
    (rethrows; a throw ends as `failed`), `beginLaunch`/`endLaunch` (once per process)
    and `metadata(count:outcome:)`, which is the only renderer.
  - `NativeOSSignpostSink` wraps `OSSignposter` (`com.tradeready.native`, Points of
    Interest).
- Instrumented sites (the pinned inventory):
  - `N/AppStore.swift`:
    - `SnapshotLoad` around the init `load`;
    - `LegacyMigration` measured around the launch `migrate`;
    - `InitialSync` in the gate task (explicit ends, plus a deferred `skipped`
      fallback);
    - `DeltaPull` wrapping the unchanged body, moved verbatim to
      `pullDeltaAndCommit`;
    - `BackgroundRefresh` wrapping the unchanged body, moved verbatim to
      `runBackgroundRefresh`;
    - a private record-count helper and outcome mappers.
  - `N/TradeReadyNativeApp.swift`: `beginLaunch` at the top of `init`, and a root
    `.onAppear` calling `endLaunch`.
  - `N/JobsView.swift` (`listState`) and `N/InvoicesView.swift` (`invoices`): measured
    projections.
- New tests:
  - `native/PerformanceMetricsTests/main.swift` and
    `native/run-performance-metrics-tests.sh`;
  - `native/PoorNetworkTests/main.swift` and `native/run-poor-network-tests.sh`.

  Both are registered in `native/run-all-domain-tests.sh`.
  `N/NativePerformanceMetrics.swift` was added to `native/run-appstore-sources-common.sh`.
- Shared test support:
  - `native/HostTestSupport/InMemorySupabase.swift` was moved unchanged out of
    `native/TwoDeviceConvergenceTests/main.swift`, and
    `native/run-two-device-convergence-tests.sh` compiles it.
  - `native/HostTestSupport/RecordingSignpostSink.swift` is new.
- `N/AppStore.swift` gained the test hook `testPullDeltaIfPossible()`, which calls the
  real `pullDeltaIfPossible`. The host harness has no `BuildEnvironment`, so the suite
  builds the same coordinator `syncCoordinatorIfConfigured` builds, around this hook.
- Docs:
  - new `docs/native-phase-11-performance.md`;
  - contract §13 (Pro Max and soak rows) and §15;
  - parity rows "Supabase sync" and "Background refresh" narrowed (status unchanged);
  - this ledger row.
- Unchanged: `project.pbxproj` (the app target uses synchronized groups, so the new
  file is picked up), `native/Info.plist`, and everything under `targets/`,
  `backend*/`, `__tests__/`, `supabase/`, `utils/` and `types/`. The roadmap has no
  Phase 11 progress bullet, so it was not edited (11.14 owns the closeout).

**Interface handoff:**
- **New interval:** add a case to `NativePerformanceInterval` and call
  `NativePerformanceMetrics.shared.begin/measure(.case …)`. Then update both the catalog
  and `expectedInventory` in `native/PerformanceMetricsTests/main.swift`. The suite
  fails on:
  - an unlisted site;
  - a string literal or `await` in a call's arguments;
  - any label other than `count`/`outcome`;
  - an `await` inside a measured closure;
  - any other `N/` file touching `OSSignposter`.
- **Metadata** is counts and the four outcome words only. Never widen the facade to
  take a `String`.
- **Poor-network harness:** `Harness` + `PoorNetworkLink` in
  `native/PoorNetworkTests/main.swift` is the place for any future degraded-network
  case. The link sits in front of the shared `InMemorySupabase`, so don't start a
  second fake stack.
- **For 11.10b:** there are no UI changes. The only view edits wrap existing
  computed properties.
- **For 11.13/11.14:** the §13 soak and launch rows now point at PERF-1 to PERF-10 and
  SOAK-1 to SOAK-6. 11.14 copies them into the device runsheet.
- **For Phase 12:** see the owner summary in the performance doc. The threshold
  tension is recorded there: this plan's step 4 says thresholds come "from the current
  Expo app's production metrics", while Phase 12.00 says no Expo production baseline
  exists and thresholds are absolute targets. The doc follows 12.00 and sets no
  numbers.

**Commands and results:**
- RED:
  - `sh native/run-performance-metrics-tests.sh` failed to compile before the facade
    existed.
  - With the facade and no call sites, the result was
    `performance-metrics tests: 1 of 118 checks FAILED` (the pinned inventory was
    empty).
  - `sh native/run-poor-network-tests.sh` before instrumentation gave
    `poor-network tests: 4 of 98 checks FAILED`: three `DeltaPull` signpost checks,
    plus one wrong expectation of mine. `sync` returns the coalesced rerun's outcome
    (`pushed: 0`), and the assertion was corrected to that documented behavior.
- GREEN:
  - `TZ=America/Phoenix sh native/run-performance-metrics-tests.sh` →
    `performance-metrics tests: 171/171 checks passed`
  - `TZ=America/Phoenix sh native/run-poor-network-tests.sh` →
    `poor-network tests: 140/140 checks passed`, plus the `SKIP: D …` line (at
    `c4e040a`)
  - D on request (the since-removed gate) →
    `poor-network tests: 3 of 150 checks FAILED` (Finding D; fixed in `36a08dc`)
- Neighbors, all passing:
  - two-device convergence (after the move);
  - store integration;
  - sync coordinator;
  - background refresh;
  - `layout-metrics tests: 822/822 checks passed`;
  - `accessibility-audit tests: 473/473 checks passed`.
- Mutations: five applied to production code, run, and restored from a copy
  (`git status` clean for those files):

  | Mutation | Result |
  |---|---|
  | Push drops `resolution=merge-duplicates` | caught (2 failures: the replay gets a 409 and never completes) |
  | The coordinator reconciles with every started item (re-sends acknowledged changes) | caught (6+ failures) |
  | The delta pull swallows a collection failure | at first **survived**, because settings and notes also failed in the drop. Case C3 (one throttled table) was added, and it is now caught (2 failures) |
  | The coordinator pulls over pending writes | caught (2 failures) |
  | A dropped table wipes its committed rows | caught (4 failures) |

- Release compile (`xcodebuild … -configuration Release -destination 'generic/platform=iOS'
  CODE_SIGNING_ALLOWED=NO build`) → `** BUILD SUCCEEDED **`, with no warnings in the
  touched files. `DEBUG_INFORMATION_FORMAT = dwarf-with-dsym` for Release.
- `TZ=America/Phoenix sh native/run-all-domain-tests.sh` → `aggregate exit=0` (65 `PASS` lines, including `performance-metrics tests: 171/171` and `poor-network tests: 140/140`, and the backend-workers `npm test` 26/26). This ran before the gated D repro was added; the default output is unchanged apart from the `SKIP: D …` line, which was re-run separately. The working tree includes other agents' uncommitted backend changes.
- `sh native/run-doc-reference-check.sh` → `1603 path references checked: 0 missing, 14 planned (not yet created).`

**Deviations (recorded, no policy change):**
- Outside the Own list, as test and tooling support:
  - `native/PerformanceMetricsTests/` and its runner, which provide the metadata-shape
    proof the brief asks for;
  - the two `native/HostTestSupport/` files;
  - the `InMemorySupabase` move, a pure extraction that reuses the fake instead of
    building a parallel one;
  - the `testPullDeltaIfPossible()` hook.
- `PoorNetworkLink` models PostgREST's 409 for a plain insert of an existing id. This is
  the one server rule the shared fake lacks, and it is what makes the idempotent-replay
  assertion meaningful. It lives in the test file, so the shared fake is unchanged.

**Observations (not bugs under the current contract; not changed):**
- Under a 429 the push still sends every queued item once per pass (there is no early
  stop). This is bounded by one attempt per item per pass plus backoff. Whether to stop
  at the first throttle is a policy question for Phase 12 monitoring.
- Finding D (above) was first suspected from code reading, then proven with the
  probe that became scenario D.

### 11.12 fix round 1 — Finding D (2026-09-24)

**Status:** Fixed (`36a08dc`). Controller ruling: fix it in 11.12 as a bug fix that
restores the coordinator contract ("never let a remote pull overwrite canonical records
that still have a local mutation waiting to reach the server"). Skipping the commit
while the queue is non-empty was rejected. The Phase 11 contract has no sync section,
so this entry is the record of the decision.

**Fix (`N/AppStore.swift`, `pullDeltaAndCommit` only).**
- After the pull's last await (and after the existing owner/blocked-workspace guard),
  the commit re-reads the live `snapshot` and the live `mutationQueue`, and calls the
  new `AppStore.rebasePulledDelta(base:pulled:live:pendingKeys:)`. There is no await
  between the rebase and the commit.
- The rebase works per record, keyed `<table>/<id>` exactly like the queue's
  `MutationKey` (collections by `Collection` raw value, settings as
  `settings/settings`, customer notes as `customer_notes/<customerKey>`):
  - a record with a pending mutation keeps its live state, including a pending
    delete (the local pending edit wins until it is pushed, even if the server changed
    the same record);
  - a record the pull did not change keeps its live state (an edit made during the
    await whose queue item was already pushed is not reverted either);
  - every other record takes the pulled (server) state, including tombstones.
- When nothing is pending in a table and the live collection still equals the base,
  the pulled collection is committed unchanged, so the common case is byte-for-byte
  today's commit.
- `pullBase` tracks the snapshot the successful `pullDelta` call merged into (the
  session-refresh retry reads a fresh `snapshot`).
- Cursors advance as before.
- **Fallback:** if the rebase throws (records are compared by sorted-key JSON
  encoding), the candidate is discarded with `pull/local-rebase`, nothing is applied or
  saved and the cursor is not advanced, so the next pull refetches. No caller hits
  this in practice (Canonical records always encode), so **no caller uses the fallback**.

**Caller audit (same merge/commit path).**
- Coordinator pass (`syncCoordinatorIfConfigured` → `pullDeltaIfPossible` →
  `pullDeltaAndCommit`): fixed. The coordinator's pre-pull queue check stays; the
  rebase covers edits that land during the await.
- Background refresh (`runBackgroundRefresh` → `syncNowAndWait` → coordinator): fixed
  by the same path.
- Booking/portal recovery (`runBookingIntakeAfterVerifiedPull` and the other direct
  `pullDeltaIfPossible` calls after booking/portal writes): the same commit path, and
  these callers can pull with a non-empty queue, so pending records are now kept
  instead of overwritten. **Corrected in fix round 2 (review I1):** these calls are not
  single-flight with the coordinator, so a change pending at the pull's start can be
  pushed, and leave the queue, before the pull commits. Round 1 then took the older
  server row the pull had fetched. Round 2 protects those keys too (see below).
- Initial sync (`NativeSupabaseInitialSyncService` via the launch gate): a separate
  commit with the same capture-before-await shape, left unchanged. RootView shows the
  loading screen, deep links park, widget replay has no publish binding yet, and
  background refresh needs a completed workspace. **Corrected in fix round 2 (review
  M3):** scene activation still runs `performForegroundRefresh`, whose recurring
  generation could generate and enqueue during the initial-sync await. **Corrected
  again and fixed in fix round 3:** that was not benign. Recurring job ids carry a
  timestamp (`LocalIDGenerator.recurringJobID`: `j<ms>_<rule>_<occurrence>`), not just
  the rule and occurrence, and invoice ids are random. An occurrence generated during
  the await is dropped by the commit while it stays queued, so it could be generated
  again under a new id, and generating against the pre-sync snapshot can also repeat
  an occurrence another device already generated. Fix round 3 gates every recurring
  generation entry point on the post-initial-sync state (see below).
- Two overlapping pulls can at most regress the cursor, which only causes an
  idempotent refetch.

**Tests (`native/PoorNetworkTests/main.swift`).** The environment gate is removed (no
other repro used it). Scenario D runs by default, and two cases were added:
- **D (coordinator):** an edit during a held pull, then writes fail. The edit is kept
  in memory and on disk and stays queued; a concurrent remote customer rename still
  applies. After a second edit and reconnect, the server has the edit and the queue
  drains.
- **E (direct caller):** one change queued before the pull and one made during it.
  Both are kept in memory and on disk, both stay queued, the remote customer change
  applies, and the pull is `.completed`.
- **F (same record):** the server and the device both change one job's title. The
  local pending title wins in memory and on disk until it is pushed, and then the
  server, memory and disk all agree on the local title.

**Commands and results (TZ=America/Phoenix):**
- RED (fix absent, gate removed): `poor-network tests: 10 of 182 checks FAILED` (9
  Finding D failures across D, E and F, plus one wrong assertion of mine: it read
  `lastPullResult` after the coalesced rerun, which clears it, and it was removed).
- GREEN: `poor-network tests: 181/181 checks passed`.
- Mutation (drop the pending-key skip): 4 failures (E pre-queued edit, F same record),
  restored from a copy.
- `run-sync-coordinator-tests.sh`, `run-delta-sync-tests.sh`,
  `run-mutation-push-tests.sh`, `run-initial-sync-tests.sh`,
  `run-sync-backfill-tests.sh`, `run-store-integration-tests.sh`: all PASS.
  `performance-metrics tests: 171/171 checks passed` (inventory unchanged).
- `TZ=America/Phoenix sh native/run-all-domain-tests.sh` → `exit=0` (65 PASS lines,
  including `poor-network tests: 181/181 checks passed`).
- Release compile → `** BUILD SUCCEEDED **`.
- `sh native/run-doc-reference-check.sh` → `1605 path references checked: 0 missing, 14 planned (not yet created).`

**Unchanged rulings:** thresholds follow 12.00's absolute targets; the 429
per-pass push behavior is carried to Phase 12 monitoring.

### 11.12 fix round 2 — review I1 and minors (2026-09-24)

**Status:** Fixed (`22f35fd`). This is a local change to `pullDeltaAndCommit`'s rebase;
no restructure was needed.

**I1: a push acknowledged during a direct-caller pull.**
- **Defect in round 1.** Job X has a queued edit L when a direct booking/portal pull
  reads its base (base[X] = L). The five-minute cursor overlap refetches the older
  server X. The coordinator pushes L, so X leaves the queue, and then the direct pull
  commits. X was not pending at commit, and the pulled row differed from the base, so
  the older server row replaced L in memory and on disk. A follow-up edit built from
  it then lost L on the server.
- **Mechanism (the simplest correct one).** The server's version of a record is taken
  only when this device has not touched it. A record is protected when any of these
  holds:
  - its key was pending when the pull read its base (`pendingAtStart`, re-read on the
    session-refresh retry);
  - its key is pending at commit;
  - its live state differs from the base (edited during the pull, whether or not it
    has been pushed since).

  Together these cover every change pushed during the pull. A change pushed during the
  pull was either queued at the start, or made during the pull, which changes the live
  record. So no push-acknowledgement log is needed.
- **Cursor hold.** Where the commit keeps a local record over a server row this pull
  fetched (the pulled row differs from both base and live), that collection's cursor
  watermark stays at its pre-pull value. The next pull then fetches the row again. That
  matters when another device changed the record after our push: that change is not
  lost behind an advanced watermark. Settings and customer notes have no cursor and are
  refetched on every pass.
- `rebasePulledDelta(base:pulled:live:protectedKeys:)` now returns the snapshot plus
  `heldCursorTables`. The fallback (`pull/local-rebase`, no commit, no cursor advance)
  is unchanged, and no caller uses it.

**Minors.**
- **M1:** table-driven cases of the pure merge (`rebaseRules` in
  `native/PoorNetworkTests/main.swift`):
  - nothing touched;
  - a pending delete against a server update;
  - a create during the pull (kept first, with a new remote row after);
  - a server tombstone against a pending upsert;
  - a tombstone for an untouched record;
  - pending at start and then pushed;
  - edited and pushed during the pull;
  - a kept record the server agrees with (no hold);
  - pending, untouched and locally changed settings;
  - per-key customer notes.
- **M2:** the merge keeps the live order (an expense or trip created during the pull stays
  at the front, where `performExpenseEdit`/`performTripEdit` insert it); rows only the pull has follow in
  pulled order.
- **M3:** the initial-sync audit is corrected above. The recurring-invoice
  observation raised here (and the same exposure for jobs) was ruled on and fixed in
  fix round 3.
- **M4:** the harness coordinator now passes `statusChanged` through the existing
  `testApplySyncStatus` hook. Comments in `syncCoordinatorIfConfigured` and
  `Harness.init` link the two.
- **M5:** the performance doc's Thresholds section states the ruling (12.00 absolute
  targets).
- **M6:** both signpost gaps are recorded in the performance doc. The background-only
  cold launch is fixed: `NativePerformanceMetrics.endLaunchInBackground()` (no
  arguments) ends `Launch` as `skipped` at the start of `performBackgroundRefresh`,
  and is a no-op after a foreground launch. It is in the pinned inventory with a unit
  test.

**Tests and commands (TZ=America/Phoenix):**
- RED: scenario G (a direct pull whose first page is served and then held while the
  coordinator pushes X) gave `poor-network tests: 5 of 198 checks FAILED`. The edit
  was lost on screen, on disk and, after a follow-up edit and reconnect, on the
  server.
- GREEN: `poor-network tests: 229/229 checks passed`, and
  `performance-metrics tests: 178/178 checks passed`.
- Mutations, each restored from a copy:

  | Mutation | Result |
  |---|---|
  | Drop `pendingAtStart` | G caught (5 failures) |
  | Do not apply the cursor hold | G caught (1) |
  | Drop the locally-changed rule | table cases caught (2) |

- sync-coordinator, delta-sync, mutation-push, mutation-queue, initial-sync,
  sync-backfill, two-device convergence, background-refresh and store-integration:
  all PASS.
- `TZ=America/Phoenix sh native/run-all-domain-tests.sh` → `exit=0` (65 PASS lines,
  backend-workers `fail 0`).
- Release compile → `** BUILD SUCCEEDED **`.
- `sh native/run-doc-reference-check.sh` → `1606 path references checked: 0 missing, 14 planned (not yet created).`

### 11.12 fix round 3 — recurring generation waits for the initial sync (2026-09-24)

**Status:** Fixed in the commit "fix(native): 11.12 fix round 3 - recurring generation
waits for the initial sync". It is a local guard plus a reorder of the post-commit
calls. The initial-sync commit (`apply`/`save`) is unchanged.

**Ruling (controller).** Recurring job and invoice generation must not run before the
initial sync commits. Generating against an incomplete snapshot can duplicate
occurrences another device already generated. It also caused the drop-then-duplicate
issue: an occurrence generated during the await is dropped by the commit but stays
queued, and it is generated again under a new id.

**Fix (`N/AppStore.swift`).**
- **Gate.** `mayGenerateRecurringRecords` is `derivedStatePublishBinding != nil`,
  meaning:
  - the signed-in-family gate states (`signedIn`, `subscriptionLoading`, `paywall`,
    `startingPoint`, `onboarding`);
  - plus the exact workspace (a migrated owner or a completed persisted workspace).

  This is the same state derived-state publishing and widget replay use.
  `refreshRecurringJobs()` and the new `refreshRecurringInvoices()` return early
  without it. The generators themselves (`runRecurringJobGeneration`,
  `runRecurringInvoiceGeneration`) are unchanged, and direct callers such as tests
  are unaffected.
- **Entry points, all gated:**
  - `performForegroundRefresh` (scene activation): jobs and invoices.
  - The delta-pull commit hook in `pullDeltaAndCommit`: jobs. It covers the
    coordinator, background refresh (through `syncNowAndWait`) and the
    booking/portal recovery pulls. Background refresh has no other generation call.
  - The returning-user launch path in `applyAuthenticatedIdentityOutcome`: jobs, now
    called after `advancePastInitialSync` so the gate can hold.
  - The initial-sync task's post-commit generation: now
    `runRecurringGenerationAfterInitialSync()` (jobs **and invoices**; invoices were
    missing there), called after `markInitialSyncCompleted` and
    `advancePastInitialSync`. It stays synchronous and before the publish, so no
    suspension point is added (10.09 fix round 2 ordering).
- **Effect when the gate ends elsewhere.** When the gate ends in `.onboarding` or
  `.startingPoint` without a completed workspace, generation is deferred to the next
  foreground or pull commit once the workspace completes. It is delayed, never lost,
  because rules keep their due dates. When the gate ends in `.accountMismatch` or
  `.unavailable`, nothing is generated into another owner's workspace.

**Test (`native/PoorNetworkTests/main.swift` scenario H).**
- **Setup.** Another device of the account (a second harness on the same server) has
  already generated this period's occurrence for one job rule and one plan. This
  device holds all four due rules locally, not queued.
- **During the initial sync.** With the gate in `.initialSyncLoading` (set through the
  existing `testSetAuthenticationGateState` hook), the real `performForegroundRefresh`
  generates no job or invoice, queues nothing and advances no rule. The delta-pull
  commit generates nothing either.
- **After the commit.** Once the gate advances, the post-commit generation (through
  `testRunRecurringGenerationAfterInitialSync`) makes exactly one occurrence per due
  rule. That includes the rules whose occurrence came from the other device. A later
  foreground refresh adds nothing, and after a push the server holds one occurrence
  per rule.
- **Limits.** The initial-sync task is not drivable in the host binary (the
  `BuildEnvironment` guard; see StoreIntegrationTests "10.09 fix round 2"). The real
  delta pull from an empty cursor stands in for its merge, and a source check pins the
  task's order: no generation call before the gate advances, and
  `runRecurringGenerationAfterInitialSync()` after `advancePastInitialSync`.

**Commands and results (TZ=America/Phoenix):**
- RED (post-commit method present, no gate or reorder):
  `poor-network tests: 13 of 258 checks FAILED`. Generation happened during the
  initial sync, the server ended with duplicates of the other device's job and invoice
  occurrences, and the source pin failed.
- GREEN: `poor-network tests: 258/258 checks passed`.
- Mutation (drop the invoice gate): 7 failures, restored from a copy.
- The recurring-job and recurring-invoice suites, sync-coordinator, delta-sync,
  mutation-push, mutation-queue, initial-sync, sync-backfill, two-device convergence,
  background-refresh and store-integration all PASS.
  `performance-metrics tests: 178/178 checks passed`.
- Release compile → `** BUILD SUCCEEDED **`.
- `TZ=America/Phoenix sh native/run-all-domain-tests.sh` → `exit=0` (65 PASS lines,
  backend-workers `fail 0`).
- `sh native/run-doc-reference-check.sh` → `1608 path references checked: 0 missing, 14 planned (not yet created).`

**Next ready:** 11.10b (accessibility re-audit).

### 11.10b — Accessibility re-audit (2026-09-24)

**Status:** Done. The re-audit after 11.11 and 11.12 is done, and the §12.1 items
handed forward are resolved (contract §12.3):

- **Fixed:** A13, A15, A16, A17, A18 and A24.
- **Accepted with a rationale:** A22, because RN stacks its route move buttons the same way.
- **Found and fixed:** A25–A28, and A29 after the controller ruling (see "A29 fix" below).

**H1 is closed.** Zero release-blocking findings remain. A29 was the last one: success,
warning and status colors used as text measured 2.1–4.1:1 in light mode, and RN's own
palette fails the same way (success 4.20, warning 3.21, status colors 2.15–3.68). The
controller ruled that native moves to darker light-mode text colors, because parity does
not extend to inaccessible colors. A12 and A19 stay Phase 12 device rows.

**Regressions checked in 11.11 and 11.12** (contract §12.3 table):
- **Found:** the four ⌘N "+" buttons had no text title for the iPad shortcut HUD. Fixed:
  `Label(<RN label>, systemImage: "plus")` with `.labelStyle(.iconOnly)`, and every one of
  the 46 shortcut controls must have a text title.
- **Not found:**
  - label changes from shortcuts;
  - AX5 clipping from the content column (it limits width only);
  - new unlabelled controls, animations or focus changes.

**Files:**
- New: `N/NativeKeyboardDoneBar.swift`. It adds `.nativeKeyboardDoneBar()`, RN
  `KeyboardDoneBar`: a "Done" button labelled "Dismiss keyboard" above the keyboard,
  which resigns first responder.
- Policy: `N/Domain/NativeAccessibilityAudit.swift`.
  - Palette: `dangerFill*`, `dangerText*`, `systemRed*`.
  - 15 new contrast rows.
  - `PhotoThumbnail` clamp.
  - Chart summary API: `ChartPoint`, `chartSummary`, `spokenMonth`, `changePhrase`.
  - Labels: `onMyWay`, `chart`, `dismissKeyboard`, plus the catalog entry checked
    against RN.
- Palette: `N/Models.swift` gains `tradeDangerFill` and `tradeDangerText`.
- Tests: `native/AccessibilityAuditTests/main.swift`. New tests:
  - view inventory, including the widget-target sources;
  - shortcut titles;
  - return keys and the keyboard Done bar;
  - the runner compile check;
  - chart summaries;
  - fixed frames;
  - re-audit sites;
  - danger text.
- Runner: `native/run-schedule-booking-settings-tests.sh` compiles the Done bar, because
  `NativeScheduleSettingsView` uses it.
- Views, by concern:
  - **⌘N titles:** `JobsView`, `InvoicesView`, `CustomersView`,
    `NativeRecurringInvoicesView`.
  - **Charts:** `NativeMoneyCards`.
  - **Frames:** `MoneyView`, `SettingsView`, `NativeTodayComponents`,
    `NativeJobPhotosView`, `NativeRouteView`, `NativeBookingRequestsView`.
  - **Today card:** `NativeTodayComponents`.
  - **Danger colors:** 22 files where system red was replaced, including the
    `NativeTimeTrackingView` clock-out tint.
  - **Done bar:** 25 screens in 20 files.

**Commands and results (TZ=America/Phoenix):**
- RED, with the tests written before the view changes:
  `accessibility-audit tests: 88 of 1103 checks FAILED`. That covers the ⌘N titles,
  inventory, Done bar, charts, frames, photo error, Today card, map number and A18 tint.
  - The runner-compile check failed before the runner line was added:
    `1 of 1131 checks FAILED`.
  - The A28 scan was written after the replacement. Its RED is the mutation below.
- GREEN: `accessibility-audit tests: 1131/1131 checks passed`.
- Mutations, each restored from a copy (`accessibility-audit` unless noted):
  - system red put back in `NativeAuthView`: 1 failure;
  - card action removed: 1 failure;
  - duplicate Done bar: 1 failure;
  - new unreviewed view file: 1 failure;
  - new decimal-pad field with no Done bar: 2 failures;
  - one chart value removed: 1 failure;
  - ⌘N "+" back to an image label: 4 failures.
- `layout-metrics tests: 817/817 checks passed`.
- `ScheduleBookingSettingsTests: all checks passed`.
- `TZ=America/Phoenix sh native/run-all-domain-tests.sh` → `exit=0` (65 PASS lines, backend-workers `fail 0`).
- Release compile → `** BUILD SUCCEEDED **`.
- `sh native/run-doc-reference-check.sh` → `1616 path references checked: 0 missing, 14 planned (not yet created).`

**Runsheet rows (Phase 12; not run, not claimed):**

| Row | Step | Pass when |
|---|---|---|
| A11B-KB-1 | iPad with a hardware keyboard: hold ⌘ on Jobs, Invoices, Customers, Maintenance plans and Coach | The shortcut HUD lists "Add new job", "Add new invoice", "Add new customer", "Add maintenance plan" and "New chat", not a blank entry |
| A11B-KB-2 | Done bar: a price, rate or phone field, and a notes field, in the job, invoice, expense, trip and pricebook editors and in Settings → Pricing | "Done" shows above the keyboard, VoiceOver reads "Dismiss keyboard", tapping it dismisses the keyboard, and exactly one Done button shows |
| A11B-VO-1 | VoiceOver on the Money charts (Last 6 Months, 12-Month Trend, Expense Trends) | One element per chart reads "{title} chart" followed by every month with its figures |
| A11B-VO-2 | VoiceOver on the Today job card: swipe up or down for actions | "On my way to {name}" is offered and sends the message |
| A11B-VO-3 | VoiceOver on a job photo whose delete or visibility change failed | The error text is read after "Open job photo" |
| A11B-DARK-1 | Dark mode: clock out, error text in a sheet form, the Money danger tone, the booking "Cancelled" kind | Rust text and fills are legible, and white text sits on the fill |
| A11B-AX5-1 | AX5: Today schedule, booking requests, route list and preview, job photos, the Settings avatar and sync badge | The time and kind sit above their rows, nothing clips, and at least one photo fits the row |
| A11B-TT-1 | Tap the Today card's "On my way" at its edge | It sends "On my way" rather than opening the job |

**A29 fix (controller ruling, 2026-09-24).** The ruling: WCAG AA text contrast is a
release requirement, parity does not extend to inaccessible colors, and native moves to
darker light-mode text colors (the 11.10a `#2f78c4` dark fill is the precedent).

- **Tokens** (`N/Models.swift`, literals mirrored in the audit palette and parsed by the
  suite). Each is dynamic.
  - Text: `tradeSuccessText`, `tradeWarningText`, `tradeInfoText`, `tradeMintText`,
    `tradeIndigoText`, `tradePurpleText` and `tradeCyanText`.
  - `tradeDangerText` light is darkened to `#a63c27`, because `#b8432b` measured 4.05:1 on
    a 13% wash. Dark is `#ee917a`.
  - Fills under white: `tradeSuccessFill` and `tradeWarningFill`.
  - Every text token holds at least 4.70:1 on each light ground and its 13% wash, and at
    least 4.71:1 on each dark ground and wash. The rows are generated in
    `semanticColorRequirements`.
- **Views** (29 files: 78 system-hue sites, 4 swipe tints and 6 destructive swipe tints).
  - Every system hue became a token, including the helpers: `JobStatus.color`,
    `NativeMoneyPalette`, the change-order tone, the booking `kindColor`, Settings
    `statusColor`, the sync banner accent and the Today stat tint.
  - Non-text dots, bars and the calendar conflict block take the text tokens, since
    system green, orange, mint and cyan fail 3:1 on white.
  - Swipe actions: Edit and Restore use `tradeReadyFill`, Archive `tradeWarningFill`, Mark
    paid `tradeSuccessFill`, and the six destructive swipes `tradeDangerFill`.
- **Tests:** `testSemanticColors`, plus `testPaletteLiteralsShipped` over every token. The
  test checks:
  - the generated rows, and baselines showing why each system hue failed;
  - no system hue in a non-widget view, with the `.mint` portal/booking action allowlisted
    per file;
  - foreground styles carry only text tokens or the tint;
  - fills, the ink and the canvas appear only inside tint, background, fill or overlay
    calls, so a helper that returns a fill fails;
  - no text token is used as a tint;
  - all 10 swipe buttons have a fill tint;
  - background washes stay at or below 13%;
  - the detector fixtures.
- **RED:** tests and palette written first, before the Models tokens and view changes:
  `accessibility-audit tests: 137 of 1863 checks FAILED`.
- **GREEN:** `accessibility-audit tests: 1873/1873 checks passed`.
- **Mutations**, each restored:
  - system green back in `NativeRouteView`: 1 failure;
  - `kindColor` returning `tradeReadyFill`: 1 failure;
  - a drifted `tradeSuccessText` literal: 1 failure;
  - untinted destructive swipe in `MoneyView`: 1 failure;
  - text token as a swipe tint: 2 failures;
  - status wash at 20%: 1 failure;
  - a fill as a foreground: 2 failures.
- **Runs**, in order:
  - accessibility-audit `1873/1873`;
  - `layout-metrics tests: 817/817 checks passed`;
  - `TZ=America/Phoenix sh native/run-all-domain-tests.sh` → `exit=0` (65 PASS lines,
    backend-workers `fail 0`);
  - Release compile → `** BUILD SUCCEEDED **`;
  - `sh native/run-doc-reference-check.sh` → `1618 path references checked: 0 missing, 14 planned (not yet created).`
- **Phase 12 row** (not run, not claimed):

| Row | Step | Pass when |
|---|---|---|
| A11B-LIGHT-1 | Light mode: job status pills (every status), Money success and warning tones, overdue and lead counts, booking kinds, Settings sync and subscription status, the paywall badges, and each swipe action | Every colored label is legible on its row and wash, the hue reads as before (green, orange, blue, mint, indigo, purple, cyan), and white swipe labels are legible |

**Concerns:**
- Visible changes:
  - Error and destructive text moved from system red to RN's rust, darkened in light mode
    (A29).
  - Success, warning and status text is darker in light mode than the system hues and
    RN's palette (A29, native difference). Swipe actions use the fill tokens.
  - The Today card's status row is 44pt tall because of the "On my way" target.
- Device proof stays in Phase 12 (the rows above and the 11.10a rows).
- Not fixed here, per the brief: the `NativeRecurringInvoicesView` "Cancel plan" /
  "Delete plan" `actionRule` bug is still flagged for the final review.

**Next ready:** 11.13 (qualification), then 11.14 (closeout).

### 11.10b fix round 1 (2026-09-24)

The review found one Important issue and seven minors. All are fixed except m5, which the
controller ruled is owned by 11.13.

- **I1: in-row destructive buttons** (contract §12.1 A28 corrected, A31 added).
  - The A28 pass removed every `.red` token but missed 12 app-drawn
    `role: .destructive` buttons, which still rendered system red text (3.55:1). The
    bordered booking Decline was red on a red wash (2.90:1).
  - Each keeps its role. Its label takes `.nativeDestructiveText()`
    (`N/NativeAccessibilityViews.swift`): `tradeDangerText`, or the secondary color while
    disabled, applied inside the label.
  - The buttons: Delete customer; the AI key Remove; Settings Sign out and Delete
    account; the delete sheet's toolbar Delete (found by the new scan, not in the
    review); paywall Sign out; Delete expense; Remove receipt photo; Delete trip; Delete
    service; the job-photo trash; and Decline.
  - Decline also tints its `.bordered` wash with `tradeDangerText`. There are rows for a
    15% own wash and a 15% system-red wash, with a minimum of 4.54:1.
  - The scan: every `role: .destructive` must be inside an alert, confirmation dialog,
    swipe action or context menu, or inside a listed dialog-only helper whose every
    call is checked, or else carry the label modifier. The 12 in-row buttons are pinned.
  - A31 records the system-drawn dialog buttons as accepted.
- **m1: washes in any context.** Every literal opacity above 13% in an app view must be
  a reviewed non-text or proven use: 10 entries, each matched at its call. This covers
  helper-returned washes and trailing closures. The coach user bubble's 18% wash under
  primary text has rows.
- **m2: tints.** A fill tint is allowed only on a swipe action or a `.borderedProminent`
  chain. A text-token tint is allowed only on a `.bordered` chain.
- **m3: UIKit spellings.** `systemRed`, `systemGreen` and the other hues fail the scan.
- **m4: `.mint`.** The action is matched per use by call shape (`action: .mint`,
  `administer(.mint`, `case .mint:` and so on), not by a per-file count.
- **m5: PDF stamps.** Contract §12.1 A30 is owned by 11.13 and outside H1's app-view
  scope. The measurements: PAID 2.90, OUTSTANDING 3.09, PARTLY PAID 4.28 and accent 4.02.
  Not fixed here.
- **m6:** the contract's dark `tradeDangerText` is corrected to `#ee917a`.
- **m7: "On my way".**
  - The link keeps a 44pt minimum width, and its hit shape is padded
    `InlineLink.verticalOutset` (16pt) above and below.
  - The padding is taken back out of layout, like RN's `hitSlop`, so the status row no
    longer grows.
  - The test pins the pattern, the absence of `minHeight`, and 13 + 2 × 16 ≥ 44.

**Commands and results (TZ=America/Phoenix):**
- RED, with the tests and policy written first: `accessibility-audit tests: 21 of 1800
  checks FAILED`. Two of those were the test's own calendar allowlist markers, which
  shared a line and were corrected to match at the opacity call.
- GREEN: `accessibility-audit tests: 1809/1809 checks passed`.
- Mutations, each restored:
  - an unstyled destructive label: 1 failure;
  - `Color(.systemGreen)`: 1 failure;
  - `.mint` as a color: 1 failure;
  - a fill tint on a `.bordered` chain: 1 failure;
  - a 20% coach error wash: 1 failure;
  - the Decline untinted: 1 failure;
  - the "On my way" `minHeight` back: 2 failures;
  - the booking dialog helper outside a dialog: 1 failure.
- Runs, in order:
  - accessibility-audit `1809/1809`;
  - `layout-metrics tests: 817/817 checks passed`;
  - `TZ=America/Phoenix sh native/run-all-domain-tests.sh` → `exit=0` (65 PASS lines,
    backend-workers `fail 0`);
  - Release compile → `** BUILD SUCCEEDED **`;
  - doc check → `1621 path references checked: 0 missing, 14 planned (not yet created).`

**Runsheet rows (Phase 12; not run, not claimed):**

| Row | Step | Pass when |
|---|---|---|
| A11B-FR1-1 | Light and dark mode: Settings Sign out and Delete account, the delete sheet's toolbar Delete (enabled and disabled), the paywall Sign out, the editor Delete rows, Remove receipt photo, the job-photo trash, and a booking Decline | Each label is rust, not system red. A disabled one reads as disabled, and VoiceOver still announces it as destructive |
| A11B-FR1-2 | Tap 12pt above and below the Today card's "On my way" text | It sends "On my way", and the card's status row is no taller than a card without the link |

### 11.13 Cross-client and platform qualification (2026-09-24)

**Status:** done, code complete. The six areas are qualified against RN, and every gap
has coverage or a named owner (contract §17). A30 is fixed. Device, extension, Siri and
store proof is deferred to Phase 12.

**Files:**
- New suite: `native/Phase11QualificationTests/main.swift` and
  `native/run-phase11-qualification-tests.sh`, registered in
  `native/run-all-domain-tests.sh`.
- A30: `native/TradeReadyNative/Domain/NativeAccessibilityAudit.swift` (`DocumentPalette`,
  `documentContrastRequirements`), `native/TradeReadyNative/NativeInvoicePDF.swift`,
  `native/TradeReadyNative/NativeEstimatePDF.swift`, and
  `native/AccessibilityAuditTests/main.swift` (`testDocumentPDFContrast`).
- Docs: contract §12.1 A30, C20, §12.3 and the new §17; `docs/native-parity-matrix.md`
  (the PDF generation, Deep links, WidgetKit, App Intents/Siri, Analytics, Crash
  reporting and Accessibility rows).
- Nothing under `targets/`, `backend*/`, `__tests__/`, `supabase/`, `utils/` or `types/`
  was edited. The runner reads the RN decoders from `targets/` in the working tree,
  including another agent's uncommitted `SiriIntents.swift`, and writes its extract
  only to `$TMPDIR`.

**Handoff (per area; details in contract §17.1):**
- **Q1 widget snapshot.** RN `BridgeSnapshot` and `SiriSnapshot` decode F1–F5 and three
  mirror-written native projections field for field. F6 is rejected by the widget and
  degraded by Siri, as in RN. The native schema is RN's plus `ownerTag`.
- **Q2 replay.** Every `widgetActions.test.js` vector passes through the planner and
  replayer. Rejecting the whole batch is asserted as the §4.3 difference.
- **Q3 deep links.** Every `deepLinks.test.js` vector passes.
- **Q4 analytics.** RN `track(` (70 sites) equals the 52-event catalog. A call graph over
  `N/` finds 49 of 52 events live. The three wired-nowhere events:
  - `booking_request_opened` and `booking_update_opened` (G1): no native push;
  - `tax_settings_saved` (G2): its chain `emitTaxSettingsSaved` ← `commitTaxSettings`
    has no caller.
  
  These are named exclusions whose owners 11.14 must schedule. **The 11.08 note
  "`tax_settings_saved` is emitted by `commitTaxSettings`" is refined:** the emission
  sits in the private helper `emitTaxSettingsSaved`. A one-hop reachability check
  therefore missed it, and the first RED run exposed that.
- **Q5 redaction.** RN `SECURE_FIELDS` and 33 §10.1 deny-row keys are denied by analytics,
  the crash redactor and the widget snapshot.
- **Q6 accessibility.** No §12.1 row is open.
- **A30.** PAID 5.86:1, OUTSTANDING 5.74:1, PARTLY PAID 5.67:1, accent 6.37:1 on white and
  5.91:1 on the total wash. RN's template keeps 2.88–4.33:1, so this is a recorded native
  difference.

**Known issues not qualified (final review):**
1. the `NativeRecurringInvoicesView` "Cancel plan"/"Delete plan" `actionRule` bug;
2. the `NativeSupabasePush` non-auth 4xx queue wedge;
3. the parity row "Tax set-aside … ported", which overstates (G2);
4. the `useAnotherAccount` scrub fail-open;
5. the silent AI-key wipe failure;
6. `deepLinkOwnerWasActive` keyed on O.

None was changed.

**Commands and results (TZ=America/Phoenix):**
- RN oracles (§4):
  `TZ=America/Phoenix npm test -- --runInBand --runTestsByPath __tests__/widgetBridge.test.js __tests__/widgetActions.test.js __tests__/deepLinks.test.js __tests__/analytics.test.ts`
  → 4 suites, 123 tests passed, exit 0. There was a haste-map duplicate-mock warning
  from a `.claude/worktrees` copy, and it did not affect the result. No failure came
  from other agents' RN or backend edits.
- A30 RED: `run-accessibility-audit-tests.sh` failed to compile, because
  `DocumentPalette` and `documentContrastRequirements` were missing. A30 GREEN:
  `accessibility-audit tests: 1859/1859 checks passed`.
- Qualification suite:
  - first run: harness bugs (duplicate JSON keys in fixture builders, optional promotion
    in `expectEqual`, the one-hop reachability miss above, and the diagnostic's
    8-issue cap), all fixed in the test;
  - RED on the unchanged contract: `1 of 318 checks FAILED` (A30 open);
  - GREEN: `phase11-qualification tests: 318/318 checks passed`.
- Mutations (scratch copy of the root, run by the compiled binary; the repo was not
  touched), each caught:
  - `.tripLogged` emission dropped: 2 failures;
  - A5 reopened: 1;
  - RN `BridgeSnapshot` field added: 3;
  - new RN `track` event: 1;
  - new RN secure field: 1;
  - `commitTaxSettings` given a caller: 4.
  
  Restored: 318/318.
- Focused runners, each exit 0:
  - `phase11-qualification` 318/318;
  - `widget-snapshot`, `next-job-widget`, `job-timer-widget` and `widget-action-replay`
    passed;
  - `app-intent-queue`, `widget-owner-gating`, `app-group-pending-open-url` and
    `deep-link-routing` passed;
  - `analytics-transport` (226 checks) and `analytics-event` (536 checks) passed;
  - `error-redaction` 694/694, `ai-provider-key` 274/274,
    `accessibility-audit` 1859/1859, `layout-metrics` 817/817;
  - `invoice-pdf`, `estimate-pdf`, `background-refresh`, `snapshot` and
    `store-integration` passed.
- `TZ=America/Phoenix sh native/run-all-domain-tests.sh` → exit 0 (341 output lines, 65 `PASS` lines, `phase11-qualification tests: 318/318 checks passed`, no FAILED/error lines; backend-workers `npm test`: tests 26, pass 26, fail 0).
- Release compile → `** BUILD SUCCEEDED **`.
- Doc check → `1659 path references checked: 0 missing, 16 planned (not yet created).` (the planned count includes the Phase 12 `docs/native-phase-11-device-runsheet.md`).

**Deviations:**
- No behavior change beyond A30. G1 and G2 are named blockers, not fixes.
- The optional simulator smoke (§13) was not run.

**Phase 12 deferrals (not run, not claimed):**

| Row | Step | Pass when |
|---|---|---|
| Q11-P12-1 (device) | On the §13 iPhone and iPad rows, install the Release build. Sign in, create a job and an invoice, clock in, then sign out | The Next Job and Job Timer widgets show the owner's data, then clear on sign-out; nothing from the previous owner appears after a new sign-in |
| Q11-P12-2 (extension) | Add Next Job (small and medium) and Job Timer to the home screen. Use the interactive timer button; leave the device a day | The widgets render, the button starts and stops the timer through the queue, and a snapshot older than 24 h shows the stale state |
| Q11-P12-3 (Siri) | Speak each of the ten App Intent phrases (contract §5), including on-my-way, from a cold and a warm app | Each intent's action replays once into the app (trip `t_siri_`, expense `e_siri_`, timer), and on-my-way routes to the job composer |
| Q11-P12-4 (store) | A StoreKit sandbox or TestFlight purchase and restore; Release PostHog and Sentry keys supplied on staging | `subscription_purchased` and the catalog events arrive with allow-listed properties only, and Sentry receives a redacted event |
| Q11-P12-5 (PDF) | Share an invoice PDF in each status and an estimate PDF, and view them on the device and in Mail | Stamps and accent use the A30 colors and stay legible when printed |

**Next ready:** 11.14 (aggregate verification and closeout). 11.14 must schedule owners
for G1 (native remote push) and G2 (a native tax-settings editor), and collect the rows
above into `docs/native-phase-11-device-runsheet.md`.
