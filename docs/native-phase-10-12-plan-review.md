# Phase 10–12 Implementation Plan Review
<!-- doc-ref-check: ignore-file (quotes wrong paths on purpose) -->

**Date:** 2026-09-22
**Documents reviewed:**
[native-phase-10-implementation-plan.md](native-phase-10-implementation-plan.md),
[native-phase-10-today-coach-notifications-contract-decisions.md](native-phase-10-today-coach-notifications-contract-decisions.md),
[native-phase-11-implementation-plan.md](native-phase-11-implementation-plan.md),
[native-phase-12-implementation-plan.md](native-phase-12-implementation-plan.md),
checked against the roadmap Phase 10–12 sections, the
[Phase 0 rollback procedure](native-phase-0-baseline.md), and the repository
source as of this date.

**Method:** every file path, runner, and oracle test the plans cite was checked
for existence, and the behavioral claims were spot-checked against the RN
sources (`screens/TodayScreen.tsx`, `targets/widget/*`, `App.tsx`, `app.json`)
and the native project. No plan was edited; each finding below names the change
to make.

## Application status (2026-09-22)

All findings below were **applied** to the four documents, except:

- **11-1 (widget/intent upgrade identity): not applied, by owner decision.** The
  app has no current users, so matching the RN extension bundle id, widget
  `kind` strings, intent names, and shortcut phrases has no value. The Phase 11
  plan now states this explicitly. The Phase 12 SA2 "placed widgets and
  Shortcuts survive the upgrade" row from 12-7 was dropped for the same reason.

Findings applied with changes because there are no current users:

- **12-4:** there is no Expo production baseline to use, so the charter sets
  provisional absolute targets that Stage A native baselines refine.
- **12-3:** the phased release gates only automatic updates to existing installs,
  so with no installed base the plan treats new installs as the exposed cohort.
  Exposure is controlled through manual release timing and pause/removal from sale.

Severity key: **High** = would produce wrong behavior, data loss, or a
non-executable step if followed as written. **Medium** = a gap or inconsistency
that will cause rework or a disputed "done". **Low** = accuracy or clarity.

---

## Summary of highest-impact changes

| # | Doc | Severity | Change |
|---|---|---|---|
| 12-1 | Phase 12 | High | The rollback model is wrong: App Store Connect cannot "re-promote" an older build. Align with the Phase 0 procedure: pause the phased release, then ship the Expo branch as a new build with a higher version/build number |
| 12-2 | Phase 12 | High | Native→Expo rollback can lose local data. The Expo build would read stale legacy AsyncStorage. The playbook needs a data strategy, not only "confirm it reads" |
| 11-1 | Phase 11 | High | The native widget extension must keep the RN bundle id suffix (`.widgets`) and widget `kind` strings, or users lose the widgets already on their Home Screen at upgrade |
| 11-2 | Phase 11 | High | The intent inventory is incomplete (RN ships 8 Siri intents plus 2 widget timer intents), and interactive-widget intents must compile into the extension too |
| 10-1 | Phase 10 | Medium | Markdown-lite and quick-prompt policy are assigned to the UI task (10.13). That breaks the plan's own "no policy in views" rule and conflicts with the contract doc |
| 10-2 | Phase 10 | Medium | B1 ("regenerate Today/insights in background") has no concrete, testable output |
| 12-3 | Phase 12 | Medium | The threshold baseline is circular (12.00 waits on 11.12, which defers its numbers to Phase 12). Use current Expo production metrics as the baseline |
| X-1 | 11 ↔ 10 | Medium | Phase 11 has no dependency on Phase 10. The accessibility audit, analytics events, and widget `outstandingTotal` all need Phase 10 output |

---

## Phase 10 — implementation plan

### 10-1 (Medium) Move pure coach policy out of the UI task
10.13 steps 2–3 port `formatChatText` and `getQuickPrompts` inside the
`CoachView.swift` rewrite. That contradicts execution-contract rule 2 ("no …
coach-prompt policy in a view"). The contract doc §13 already assigns
`formatChatText` and the quick-prompt branches to 10.10.
**Change:** add `N/Domain/NativeChatMarkdown.swift` and
`N/Domain/NativeCoachQuickPrompts.swift` (with host runners pinning the
`2*4 and 2*6` / spaced-math / `snake_case` fixtures) to 10.10's **Own** list.
10.13 then only renders them. The byte-for-byte markdown oracle then runs on the
host instead of depending on a UI compile.

### 10-2 (Medium) Give B1 a concrete output
Today and insights are computed when the view renders, so "regenerate
Today/insights inputs" in 10.09 has nothing observable to assert.
**Change:** define B1's outputs explicitly:
(a) notification reconcile from the committed snapshot,
(b) the widget snapshot mirror (Phase 11 W1 — cross-link it, and have 10.09
expose a post-pass hook that 11.01 plugs into), and
(c) optionally a cached `NativeBusinessSnapshot` for coach cold-start. Rewrite
the 10.09 "done when" section around those outputs.

### 10-3 (Medium) 10.08 step 2 — don't fold non-notification inputs into the schedule key
Insight mutes, setup-checklist state, and expenses do not change any scheduled
notification. Folding them into `estimateFollowUpNotificationScheduleKey` would
only cause extra reconciles.
**Change:** limit the key to inputs of the five notification selectors plus
toggles. State that Today/insight refresh is reactive through store publishing,
not through the schedule key.

### 10-4 (Medium) 10.04 is missing two pure selectors that 10.11 renders
10.11 renders the "estimates awaiting response" row
(`selectAwaitingFollowUp` + `awaitingResponseLabel`, contract §1.4) and the
greeting/date header. Neither has a pure owner.
**Change:** add both to 10.04 steps and fixtures: the greeting cutoffs at
12:00 and 17:00, the `FOLLOW_UP_DAYS` boundary, and gating on the follow-up
toggle.

### 10-5 (Medium) 10.12 needs a 10.05 dependency
The checklist's `notifications` task is handled in-card: request permission,
then `synchronize()` on grant, or an "Open device settings" alert on refusal
(contract §5). That flow is 10.05's permission surface.
**Change:** set 10.12 **Depends on:** 10.02, 10.03, 10.05, 10.11, and reference
the 10.05 prompt API.

### 10-6 (Medium) Specify the UI behavior when a fail-closed store can't be read
10.03 records that the mute and checklist stores fail closed. RN instead degrades
to `[]`. 10.12 doesn't say what the card does in that state. Showing unfiltered
insights would bring back dismissed rows; hiding everything would drop
self-resolving alerts.
**Change:** add a decision (recommended: render only the five non-muteable
kinds, keep the checklist hidden, and log a bounded diagnostic). Add the
fail-closed-vs-degrade difference to the contract decision table as a recorded
native difference.

### 10-7 (Medium) Point 10.10 at the live backend route
10.10 **Read** lists `backend/api/ai-chat.js`, the legacy Vercel Groq proxy. The
contract (§7) and the live routing (`backend-workers/src/index.js:60` →
`routes/aiChat.js`) use the Worker.
**Change:** make `backend-workers/src/routes/aiChat.js` the authoritative read.
Mention the Vercel file only if its parity with the Worker is still a
requirement.

### 10-8 (Medium) Say who owns analytics
Contract §3.1/§1.5 list `insight_*` and `sample_job_opened` events, and 10.13
"marks the send source for later analytics". No Phase 10 task owns emitting them.
**Change:** add one line to 10.12/10.13: "emit through a no-op
`NativeAnalytics` seam; Phase 11.08 owns transport and parity." That prevents
both double implementation and silent omission.

### 10-9 (Low) Stale status text
The header says "no implementation tasks completed", and §6 says "All tasks
10.00–10.15 are pending". The ledger table and §7 log show 10.00, 10.01, and
10.03 code complete.
**Change:** update the header and the §6 lead sentence to match the ledger.

### 10-10 (Low) Path drift from what was built
- 10.03 **Own** lists `N/NativeSetupChecklist.swift`. The file actually landed at
  `N/Domain/NativeSetupChecklist.swift`. Contract §13 has the same stale path.
- The contract §13 lead-in for 10.10 names `N/NativeCoach*.swift`. Align it with
  the files 10.10 actually owns after change 10-1.

### 10-11 (Low) Verification commands
- Prefix the RN oracle commands with `TZ=America/Phoenix`, as the 10.00 evidence
  run did. Without it, the FA-039 local-date regressions are invisible on a UTC
  CI box.
- Add oracles the tasks cite but the command block omits:
  `__tests__/crossTabNavigation.test.tsx` (D6),
  `__tests__/reviewRequest.test.js` and `__tests__/ReviewRequestScreen.test.tsx`
  (10.07).
- Add the three runners that now exist: `run-business-snapshot-tests.sh`,
  `run-insight-mute-tests.sh`, `run-setup-checklist-tests.sh`.

### 10-12 (Low) Signed vs unsigned build in 10.15
10.15's text asks for "a signed generic-iPhone Release build", but §4's command
uses `CODE_SIGNING_ALLOWED=NO`. Either list both commands or say that the signed
build is recorded only where signing identities are available, and that the
result is otherwise deferred.

### 10-13 (Low) Smaller accuracy fixes
- 10.02 step 2 says "all eight" but lists seven kinds, because open slot and
  unscheduled approved are merged. List all eight to match contract §3.
- The 10.01 handoff says "10.05–10.10 consume the snapshot". The actual consumers
  are 10.09, 10.10, and 10.13 (quick prompts).
- 10.07 depends on 10.06 only for shared-file serialization, not for any
  interface. Label it that way so no one waits on a semantic dependency that
  doesn't exist.
- 10.14 "Swift-to-RN equivalence" does not apply to device-local stores. State
  which checks are two-way (synced canonical data) and which are one-way (seed
  import of `insightMutes` / `setupChecklistState`).

## Phase 10 — contract decisions

### 10C-1 (Medium) Record that the hero suppresses the insights card
`screens/TodayScreen.tsx:888` renders `InsightsCard` only when `!loading &&
!hero`. §3.1 lists only the `isSetupComplete && insights.length > 0` gate, but
the 10.12 "done when" asserts "hero suppresses insights". Add the hero gate to
§3.1 so 10.12 has a cited oracle.

### 10C-2 (Low) Put the coach model ids in one place
§7 pins `claude-sonnet-4-6` and `llama-3.1-8b-instant` as parity constants. Keep
them for parity, but have 10.10 define each in a single constant. A later model
bump should be a one-line change reviewed on its own, not a parity break.

### 10C-3 (Low) Missing decision-table rows
Add rows for the store fail-closed-vs-degrade difference (10-6) and the
hero-suppresses-insights gate (10C-1).

---

## Phase 11 — implementation plan

### 11-1 (High) Keep widget and intent identity across the Expo→native upgrade
RN ships the extension as bundle id suffix `.widgets`
(`targets/widget/expo-target.config.js`) with kinds `NextJobWidget` and
`JobTimerWidget`. If the native extension's bundle id or `kind` strings differ,
widgets that users already placed disappear or go blank after the upgrade.
Renaming App Intent types or `AppShortcutsProvider` phrases also breaks Shortcuts
that users built.
**Change:** add an "upgrade identity" contract to 11.00: extension bundle id,
widget kinds, supported families, intent type names/identifiers, and shortcut
phrases, all copied from RN. Make "identical to RN" a 11.01/11.04 done-when
check, and add an SA2 row in Phase 12 ("placed widgets and user Shortcuts
survive the upgrade").

### 11-2 (High) Complete the intent inventory and fix target membership
`targets/widget/_shared/SiriIntents.swift` defines `NextJobIntent`,
`StartTripIntent`, `StopTripIntent`, `OnMyWayIntent`, `ClockInIntent`,
`ClockOutIntent`, `LogExpenseIntent`, and `OutstandingIntent`.
`JobTimer.swift` adds `StartTimerIntent` and `StopTimerIntent`. 11.04 lists only
timer start/stop, log expense, log trip, "owed", and on-my-way. It omits Next
Job and models trips as a single "log trip", even though RN uses the
`activeTrip` start/stop session.
The plan also puts all intents in the app target only (11.04) and gives the
timer-button intents a separate owner (11.03). An intent run from an
interactive widget `Button(intent:)` must be compiled into the widget extension
too. RN handles this with the `_shared` folder, which is compiled into both
targets.
**Change:**
(a) Enumerate all ten intents in 11.00 and 11.04.
(b) Mirror the `_shared` pattern: one source file compiled into both targets
    for the intents the widget invokes, with `AppShortcutsProvider` in the app
    target only.
(c) Resolve the 11.03/11.04 ownership overlap so each intent type is defined
    exactly once.

### 11-3 (Medium) Add a Phase 10 dependency
Several Phase 11 tasks need Phase 10 output:
- 11.10 audits every view, but `TodayView`/`CoachView` are rewritten in
  10.11–10.13.
- 11.08 must instrument the `insight_*` events that 10.12 introduces.
- 11.01's `outstandingTotal` should reuse 10.01's snapshot/`PaymentLedger`
  rollup rather than fork the math.

**Change:** add "Phase 10 closeout (10.15)" as an entry dependency for
11.08/11.10, and "10.01" for 11.01 step 3. Name the reuse explicitly.

### 11-4 (Medium) Make the diagram, waves, and ledger agree
- The ledger has 11.06 depending on 11.05, but the diagram hangs 11.06 directly
  off 11.00.
- The wave text puts 11.05 alongside 11.06/11.07.
- 11.10 "re-runs after 11.11/11.12" while 11.11 depends on 11.10.

**Change:** choose one graph. Recommended: 11.06 depends on 11.00 plus the 11.05
owner gate API. Split 11.10 into 11.10a (audit and fixes) and 11.10b (re-audit
after 11.11/11.12).

### 11-5 (Medium) Decide the SDK dependency explicitly
The execution contract says not to introduce "another package/build system".
Sentry crash capture realistically requires the Sentry Cocoa SDK, and PostHog
has an iOS SDK. SPM precedent already exists (RevenueCat, GoogleSignIn in
`project.pbxproj`).
**Change:** record in 11.00 that SPM SDKs are permitted for Sentry/PostHog. Keep
the event catalog and redaction policy in Foundation-only files behind a
protocol, because the `native/run-*.sh` host runners cannot import the SDKs.

### 11-6 (Medium) Assign the privacy manifest independently of analytics
11.07 step 4 ties `PrivacyInfo.xcprivacy` to the analytics SDK. Both the app and
the widget extension need their own manifest regardless, because both use
required-reason APIs such as `UserDefaults` (the App Group suite) and possibly
file timestamps. No manifest exists today.
**Change:** give 11.01 the extension manifest and a single task (11.07 or a new
11.0x) the app manifest, covering required-reason APIs and collected-data types.
Also add updating the App Store privacy nutrition labels to Phase 12.01.

### 11-7 (Low) Wrong or hedged references
- `modules/widget-bridge/WidgetBridgeModule.swift` → the actual path is
  `modules/widget-bridge/ios/WidgetBridgeModule.swift` (11.01 read list and
  "Existing code").
- `N/NativeLegacyDataImporter.swift` → the actual file is
  `N/LegacyDataImporter.swift` (11.12). Phase 12 §1 has the same error.
- 11.06 reads "`__tests__/deepLinks` (if present)". The file exists as
  `__tests__/deepLinks.test.js`. Drop the hedge and add it to §4.
- Add `__tests__/analytics.test.ts` to §4 for 11.07/11.08.

### 11-8 (Low) Fix the Sentry sampling description
11.09 says "enable auto-session tracking to match RN's `tracesSampleRate`".
`tracesSampleRate` (0.2 in `App.tsx:110`) is performance-trace sampling;
release-health session tracking is a separate setting. Specify both: traces at
0.2 to match RN, and auto-session tracking on, because the Phase 12 crash-free
sessions metric depends on it.

### 11-9 (Low) Pin the stale-snapshot window now
11.05 step 3 refers to "a documented window" without defining it. Decide the
value in 11.00 (and check `docs/widget-plan.md` for an existing value) so the
11.02 empty/stale UI and the 11.05 fixtures test the same boundary.

### 11-10 (Low) Add some host-level network coverage in 11.12
The roadmap deliverable says "memory, battery, and poor-network **tests**", but
11.12 produces only a protocol. Offline→online transitions and throttled
transports can be host-tested now with the injected transports from Phases 4–7.
Add a small host suite so Phase 12 isn't the first place those paths run.

---

## Phase 12 — implementation plan

### 12-1 (High) Correct the rollback mechanics
12.06 step 1 says "re-promote the prior Expo build". App Store Connect does not
allow re-releasing an older build over a newer live version. The
[Phase 0 rollback procedure](native-phase-0-baseline.md) already has this right:
pause the phased release, keep the Worker on the last mixed-client-compatible
deployment, and submit the preserved Expo branch as a new binary with a higher
build number.
**Change:**
- Cite and extend the Phase 0 procedure.
- Pre-build the Expo rollback candidate (version above the native release),
  upload it, and let it process in App Store Connect before Stage C, so "ready
  for immediate rollback" (SB3) is literally true. Plan for expedited review.
- Keep the EAS/Expo build pipeline green for the whole first stable series.

### 12-2 (High) Add a data strategy for native → Expo → native
After a user runs native, their local data lives in the native store. An Expo
rollback build reads legacy AsyncStorage, which is stale as of the upgrade. Any
change that was never synced is invisible or lost. On re-upgrade, the native
importer must not re-import that stale legacy data over newer native or cloud
state.
**Change:** add these to 12.06 and to the 12.00 charter as a decision:
- the rollback build treats the cloud as authoritative (forced pull, with an
  unsynced-change warning);
- the native build drains the mutation queue before any rollback advisory;
- the migration journal guarantees that a re-upgrade adopts newer state rather
  than re-importing the stale legacy data.

The rehearsal in 12.06 step 3 must include an unsynced local edit in each
direction.

### 12-3 (High) Describe the phased release as it actually works
12.07 step 3 says to "start at the charter's initial percentage, hold at each
step … expand only on the owner's go decision". Apple's phased release uses a
fixed 7-day schedule (1/2/5/10/20/50/100%). The only controls are pause (up to
30 days in total), resume, or release to everyone. It applies only to automatic
updates: new installs and manual updates get the native build immediately.
**Change:** rewrite the step as "pause if thresholds breach, resume on go". Have
the charter address the fact that new users bypass the rollout.

### 12-4 (Medium) Break the threshold-baseline circularity
12.00 depends on 11.12 baselines, but 11.12 says actual numbers are captured in
Phase 12.
**Change:** base the charter on the current Expo app's production metrics
(Sentry crash-free sessions, sync/migration error rates from existing
telemetry), which exist today. Mark thresholds provisional until Stage A adds
native baselines, then have the owner re-ratify them at the Stage B entry gate.

### 12-5 (Medium) Make the rollback rehearsal a Stage B entry gate
12.06 runs "parallel with 12.05", but SB3 requires rollback readiness
*throughout* Stage B.
**Change:** set 12.05 **Depends on:** 12.04 exit and 12.06 rehearsal recorded.
The Stage C re-verification stays in 12.07.

### 12-6 (Medium) The runsheet inventory is incomplete
Runsheets that exist: `native-device-test-runsheet.md`,
`native-phase-3-device-matrix.md`, and `native-phase-4`/`7`/`9-device-runsheet.md`
(plus the Phase 4 background, photo, and mixed-client docs). There is **no**
Phase 5, 6, or 8 runsheet, and the consolidated runsheet has no Phase 5/6/8
sections. 10.15 and 11.14 will create the Phase 10/11 runsheets.
**Change:** list the exact files in 12.03. Add a step to locate or create the
Phase 5/6/8 deferred rows; they are currently scattered through the roadmap
text. Otherwise "every deferred row appears exactly once" can't be met.

### 12-7 (Medium) Add missing release-readiness checks
Add to 12.01/12.04 (and to SA2 where marked):
- **Subscription continuity:** existing RevenueCat subscribers keep their
  entitlement after the upgrade; restore works; sandbox purchase works in Stage A.
- **Sign in with Apple continuity:** same team and bundle id, so user
  identifiers are stable. Verify an existing Apple-ID user lands in the same
  account.
- **Expo-scheduled notifications (SA2):** pending notifications left by the
  Expo app are reconciled by the native coordinator (same namespaces), not
  duplicated or orphaned.
- **Widget and Shortcut survival (SA2)** — see 11-1.
- **External TestFlight** requires Beta App Review. Build that lead time into
  Stage B, and prepare App Review notes plus a demo account.
- **Privacy nutrition labels** updated for any new SDK data collection (see 11-6).

### 12-8 (Medium) Cover mixed-client operation during rollout
During the phased release, one account can run native on one device and Expo on
another (for example an updated iPhone next to an iPad that hasn't updated).
**Change:** have 12.06/12.07 cite
[native-phase-4-mixed-client-convergence.md](native-phase-4-mixed-client-convergence.md)
and add a Stage B cohort row for a two-device, mixed-client user.

### 12-9 (Low) Scheduling and accuracy
- 12.03 (the evidence index) doesn't need 12.01. It can start in parallel with
  12.00; only *executing* the rows needs the release config.
- 12.01 step 2 lists "associated domains". Neither the native entitlements nor
  RN `app.json` declare any. Reword to "associated domains, if any are added"
  so no one hunts for a missing entitlement.
- §1 "What already exists" lists `N/NativeLegacyDataImporter.swift`. The actual
  file is `N/LegacyDataImporter.swift`.
- §1 lists the Phase 11 monitoring files as existing. They don't exist yet.
  Label them "delivered by 11.07–11.12".

---

## Cross-document items

- **X-1** Phase 10 → 11 dependency (see 11-3).
- **X-2** The B1 background hook (10-2) and the W1 widget mirror (11.01) should
  share one post-sync-pass seam, so there is exactly one place that republishes
  derived state after a commit.
- **X-3** Analytics seam ownership (10-8 ↔ 11.08).
- **X-4** Every plan's §4 should use `TZ=America/Phoenix` for RN oracles, and
  each should list the runners created by earlier tasks in that phase.

## Suggested order of application

1. Phase 12 rollback corrections (12-1, 12-2, 12-3). These are safety issues and
   need to be settled before a charter is written.
2. Phase 11 upgrade identity and intent inventory (11-1, 11-2), before 11.00
   freezes contracts.
3. Phase 10 policy placement and B1 definition (10-1, 10-2). 10.10 and 10.09 are
   still pending, so this is the cheapest time to change them.
4. The remaining Medium and Low items, batched into one documentation pass per
   plan.
