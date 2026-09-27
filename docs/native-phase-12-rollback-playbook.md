# Native Phase 12 — rollback playbook (12.06)

**Status: DRAFT. Not rehearsed and not staffed.** Written 2026-09-26 by task 12.06 on
branch native/phase-12. It depends on the
[cutover charter](native-phase-12-cutover-charter.md), which is itself a draft awaiting
owner approval. Nothing in this document is approved until the owner approves the
charter and records the rehearsal and staffing in the charter's decision log (§9).

This playbook extends the
[Phase 0 rollback procedure](native-phase-0-baseline.md) (§ Rollback procedure, steps
1–6) and does not replace it. §6 below maps each Phase 0 step to the step that carries it
out. The charter remains the single source for:

- the stop triggers (§4.8);
- the rollback data decision (§6);
- exposure control and Apple's documentation (§7);
- roles (§1), severity (§2) and thresholds (§3).

This playbook cites those sections and does not restate their values. `N/` means
`native/TradeReadyNative/`. The requirements covered are SB3 (rollback readiness) and E3
(playbooks staffed, rehearsal recorded) from plan §1.

## 0. Owner-gated steps

Every step that an agent may not run carries this banner:

> **OWNER-GATED.** Only the owner runs this step. An agent may prepare it but never runs
> it: no App Store Connect or TestFlight action, no upload or submission, no Worker
> deploy or rollback, no Supabase write, no production account or data, and no signing
> change (plan §1; charter §1, "Coding agents").

The commands in this document use placeholders in angle brackets for every credential,
team ID, key ID, version number, build number, account and URL (`<TEAM_ID>`,
`<ASC_KEY_ID>`, `<NATIVE_VERSION>`, …). Fill them in only in the owner's terminal and
the owner's private notes. Never write a filled-in value into this repository, and never
point a staging configuration at production: `https://staging.invalid` stays until real
staging exists (D4).

### What the 12.06 host build delivered, and what is still open

**Built with host tests:**

- the native half of the rollback data decision (§5.1 and §5.2): a rollback-readiness
  check that drains the device before any advisory, and the journal adoption rule
  (defect `P12-011`);
- a G6 test showing that nothing except a permanent deletion removes the legacy sources;
- the native run marker that the Expo build's E-1 reads at app start to tell one native
  run from the next. A restart after a missing or unreadable marker is random, not a
  fixed value that could repeat a recorded run (§5.3; review fix rounds 2 and 3, R45a
  and R48).

**Built with host tests since (2026-09-26, Task 12b, 12.00b.2-I):**

- launch and every activation finish or clear unfinished booking and portal link work
  (defect `P12-013`, charter §10; §5.1).

**Open:**

| Open item | Who clears it | Where |
|---|---|---|
| The rehearsal (plan 12.06 step 5) | owner | §8 and evidence index rows P12-RB-2 to P12-RB-5 and P12-RB-7 |
| Staffing (step 6) | owner | §8.4 and row P12-RB-6 |
| The Expo-side rule (1) of the rollback data decision: E-1 detects at app start, clears (recommended) or holds, and pulls; E-2 to E-4 (R48). Until the pull, E-1 also holds the widget and Siri replay and invoice creation (R49) | the owner decides who builds it on the Expo release branch, and starts the build only after accepting §5.3 as final (after the final-review fix wave's re-review). The branch owner records E-1's keys, the clear-or-hold choice, the marker path under `expo-file-system`, the fingerprint, and the owner's acceptance of residuals 5 and 6 | §5.3; §5.6 items 5 and 6 |
| Defect `P12-012` (S1): the Expo build pushes its stale pre-upgrade queue before it pulls | owner: a ruling on Stage A entry (R43), then the §5.3 build | charter §10; §5.3 |
| Version numbers (VER-1) | owner; 12.01 sets the scheme | §3 |
| The Expo release branch itself | owner | §4 |

## 1. Decision owner and roles

Decision D5 (charter §1) makes the owner the single holder of every role:

- the **decision owner**, who decides whether to roll back and logs the decision;
- the release engineer;
- backend;
- support;
- on-call.

The charter's single-person operating rules apply to every step here, in particular:

- **Rule 1, watch days.** A rollback submission happens only on a watch day, and the
  watch covers 48 hours.
- **Rule 2, no unwatched phased-release days.**
- **Rule 5, the rollback candidate is pre-staged.**
- **Rule 6, write before acting.** The decision-log row comes before the action it
  authorizes.

An agent-prepared readiness summary is advice, not a decision.

## 2. Triggers and the rollback decision

### 2.1 What opens the decision

The stop triggers are charter §4.8, cited here and not restated. Any one of them does
three things:

- It pauses the stage.
- It opens this rollback decision the same day.
- It starts the S1 clock of charter §2 rule 5: a pause or rollback decision within 4
  hours of reading the report (`docs/native-phase-12-monitoring.md` §7).

A trigger does not by itself force a rollback. The owner chooses between fixing forward
with a new native build and rolling back to the Expo build.

### 2.2 Fix forward or roll back (provisional; approved with the charter)

**Always first:** contain. Pause the phased release, and Remove App From Sale if new
installs must stop (charter §7; §6 step 1 below).

**Roll back** (ship the Expo rollback candidate R) only when **all** of these hold:

1. **The defect is in the native binary.** A backend-caused breach is handled by step 2
   (the Worker) and not by an app rollback. A defect that the Expo build shares is not
   fixed by a rollback.
2. **The harm continues on devices that already installed the native version**, where
   pausing or removing it from sale does not reach. Examples: data loss or corruption as
   the app is used, a privacy or cross-account exposure, or a core-flow crash
   reproduced on two devices (charter §2 S1 and the §4.8 triggers).
3. **A native fix cannot reach those devices sooner than R.** Both need App Review. If a
   fixed native build is as fast, fix forward: a rollback costs every affected user two
   transitions.
4. **R is ready:** built, uploaded and processed (charter §4.5, §4.6), with the §5.3
   Expo-side rule built into it. The Worker must be compatible with both clients (§5.4).

   If the §5.3 rule is **not** in R, a rollback can overwrite newer cloud rows with the
   Expo build's stale queue on every device that ran the Expo build before the native
   one (defect `P12-012`, charter §10). Rolling back is then itself an S1 risk for those
   devices (§5.3), so the owner records that risk in the decision row.

   An E-1 that looks only when R syncs does not meet the rule. It misses an offline
   start and a first sign-in, and edits queued before its check are dropped or reverted
   (§5.3 E-1).

**Fix forward** in every other case. The stage stays paused, or the app stays off sale,
until the fixed native build is released on a watch day.

The decision-log row uses the charter §9 format:

```
| <N> | <DATE> | <STAGE> | Rollback decision: <roll back to R | fix forward>; <defect ID>; <one-line reason> | <evidence-index rows, defect row> | owner | <each §4.8 trigger checked and its state> |
```

## 3. Version numbering (VER-1)

### 3.1 Facts

- **VER-1 (charter §4.1).** Native `MARKETING_VERSION = 1.0` is below the Expo
  `app.json` version `1.2.1`. The owner confirms the live store version, and 12.01 sets
  the scheme under a recorded ruling.
- **One app record.** Both clients ship the same bundle ID and upload to the same App
  Store Connect app record. The native build is a version update of the Expo app, and
  the Expo rollback build is a version update of the native one.
- **No downgrade.** App Store Connect cannot re-release an older build over a newer live
  version (plan 12.06). A rollback is therefore always a **new, higher version**.
- **Native version numbers.** The native Info.plists read `$(MARKETING_VERSION)` and
  `$(CURRENT_PROJECT_VERSION)` (`native/Info.plist`, `native/TradeReadyWidgets/Info.plist`).
  A command-line override on the archive therefore sets the app and the widget extension
  together, without editing the project file.
- **Expo version numbers.** The Expo build takes its version from `app.json`
  (`expo.version`). Its build number comes from EAS's remote counter
  (`eas.json`: `appVersionSource: remote`, production `autoIncrement: true`). Its
  runtime version follows the app version (`runtimeVersion.policy: appVersion`), so an
  over-the-air update published for one version never reaches another.

### 3.2 The rule

```
L  <  N  <  R  <  N2
```

| Symbol | What it is | Where it comes from |
|---|---|---|
| **L** | The Expo version live on the App Store now | The owner reads it in App Store Connect (VER-1). `app.json` says `1.2.1`, which is not proof of what is live |
| **N** | The native release version: every Stage A and B TestFlight build and the Stage C release | 12.01's scheme (VER-1) |
| **R** | The Expo rollback candidate, built from the Expo release branch | The owner, before the rehearsal (§4). It must stay above every native version that might ship before a rollback |
| **N2** | The native re-upgrade after a rollback, and the rehearsal's second native build | The owner. It must be above R |

**Build numbers.** Give every upload a build number above every earlier upload of the
app, whichever pipeline made it. EAS's remote counter does not know about native uploads,
so before building R, set it above the last native build (§10.2).

**Headroom.** A native hotfix after release (N.1, N.2, …) must stay below R. If the
native release version reaches R, build a new candidate above it before Stage C
(charter §4.5 requires the candidate to be above the planned native release).

**Over-the-air updates.** An EAS Update published for L never reaches R. Any update
published during a rollback window must target R's runtime version.

**Rehearsal numbering.** The rehearsal (§8) uses the real numbers: the native TestFlight
build N, the actual candidate R (uploaded and processed, not submitted), and a native
build N2. It records each version and build in the evidence template (§8.3). This is the
"rollback candidate's version numbering is recorded" part of plan 12.06's "Done when".

## 4. Keep the rollback ready (plan 12.06 step 2)

> **OWNER-GATED.** Every item in this section.

**The Expo release branch.** Plan 12.06 step 1(c) and Phase 0 step 3 assume "the
preserved Expo release branch". On 2026-09-26 no branch or tag in this repository is
named for it. The owner creates `<EXPO_RELEASE_BRANCH>` from the commit that built L
(`<EXPO_LIVE_COMMIT>`). The branch carries only:

- the §5.3 Expo-side change;
- the version bump to R;
- any fix the owner rules is required.

Charter §1 rule 4 freezes non-critical Expo feature work from Stage C entry.

**Keep the pipeline green.** Build the branch with EAS at Stage B entry (charter §4.4:
"The Expo release branch builds green (SB3)"). Rebuild it after any change to the branch
through the first stable native release series (plan 12.06 step 2).

**Pre-stage R before Stage C.** Upload R and let it process, but do not submit it for
review (charter §4.5, §4.6; §1 rule 5). The rehearsal (§8) needs R on TestFlight before
Stage B entry, so upload it by then and use the same build in the rehearsal.

The commands are in §10.2.

## 5. The rollback data decision (charter §6): what each side does

Charter §6 has three rules:

1. The Expo build treats the cloud as authoritative: a forced pull, with a warning when
   unsynced changes exist.
2. The native build drains its queue before any rollback advisory.
3. On a re-upgrade, the journal adopts newer native or cloud state and never re-imports
   the stale legacy AsyncStorage.

12.06 built rules (2) and (3) with host tests. Rule (1) is Expo-side and is recorded
here as a requirement for the Expo release branch. It is not implemented here.

### 5.1 Rule (2), native: "Check everything is saved"

**Where.** Settings › Cloud Sync › **Check everything is saved** (`N/SettingsView.swift`,
the section after Sync now). The support script (§7.2) asks for it before any rollback
advice.

**What it does** (`AppStore.prepareRollbackReadiness`, `N/AppStore.swift:8343`):

1. It reads the device's local state (`AppStore.rollbackReadiness`, `N/AppStore.swift:8219`).
2. If none of the fail-closed conditions below holds, it applies any widget or Siri
   actions waiting in the App Group.
3. It runs one full manual sync (push, then pull).
4. It uploads waiting job photos, then syncs again if a photo uploaded.
5. It checks the device again.

The check never discards, settles or clears anything. The only thing it writes is what
an ordinary sync writes.

**What it shows.** Either "Ready: everything on this device is saved to the cloud." or
"Not ready yet: …" followed by each reason
(`NativeRollbackReadinessCopy`, `N/NativeSupportDiagnostics.swift:413`). A neutral note
line, starting "Also:", may follow either one. It reports booking and portal link work
(below) and never changes the result. The support report (schema version 4) carries the
last check under `rollbackReadiness`:

- `lastCheck` (`none`, `ready`, `not-ready`) and its age bucket;
- the sync outcome of the drain;
- the blocker codes;
- the note codes (`notes`), which never block;
- the waiting-change, refused-change, widget-action, photo and booking-work counts;
- the migration journal state.

It carries no record, record ID or name.

**Not ready, with something still to upload.** The drain ran and something is still
only on this device.

| Code | User sees |
|---|---|
| `pending-changes` | "N changes waiting to upload" |
| `rejected-changes` | "N changes the cloud refused need Retry or Discard above" |
| `widget-actions-pending` | "N widget or Siri actions not applied yet" |
| `photos-pending-upload` | "N photos waiting to upload" |
| `pending-changes-unreadable`, `rejected-changes-unreadable`, `widget-actions-unreadable` | "… can't be read" or "can't be checked" |

A refused change (I2, charter §5.3) cannot be drained. It is listed as not drainable
until the user taps Retry or Discard, and the check never discards it.

**Reported, never blocking: booking and portal link work** (review fix round 2, R46).

| Code (`notes`) | User sees, under the result |
|---|---|
| `booking-work-pending` | "Also: N booking or portal link updates haven't finished on this device. This work holds no changes that need uploading, so it doesn't change the result." |
| `booking-work-unreadable` | "Also: booking and portal link updates can't be checked on this device. …" (the same ending) |

This is 8.08 work that the push pass does not finish
(`NativeScheduleBookingPendingWorkStore`, `N/NativeScheduleBookingStore.swift`). It holds
no native-only business data, so "Ready" does not depend on it:

- A mirror item records a booking-link or portal-link change that the server already
  made. Only the display copy on this device did not update.
- A reschedule proof records the owner's accept of a customer's reschedule request
  ("I've rescheduled it" on Today; 2026-09-26, 12.00b.2-J, defect `P12-015`): the job's
  schedule the resolve confirms. The accept writes nothing to the job. The job change is
  the owner's earlier move, in the ordinary queue, which `pending-changes` counts.

The check counts this account's items only and never removes one. Launch and every
activation recover them (2026-09-26, 12.00b.2-I, defect `P12-013`):
`AppStore.recoverScheduleBookingPendingWork` (`N/AppStore.swift:10960`) runs for the
verified owner after the initial sync, from the signed-in gate and from
`performForegroundRefresh` after its sync (`N/AppStore.swift:8057`).

- A mirror waits for a pull (review fix round 1, 2026-09-26). It is read and merged only
  after a pull has committed the settings and customer rows since the identity was
  applied or the foreground refresh began: the merge queues the whole settings or
  customer record, and the push runs before the pull. On a cold launch the initial sync
  is that pull, so the gate-open pass finishes mirrors. On a warm activation the gate
  sites fire before the pull, so their pass leaves mirrors to the pass that follows
  `performForegroundRefresh`'s own pull. If that pull fails, mirrors wait for a later
  activation.
- The pull must also be current (final review M1, 2026-09-27; defect `P12-013`'s
  review residual R54 N1). A pull does not count in three cases:
  - it began before an account boundary, even if the same owner is back by the time it
    commits;
  - it began before the scene last entered the background: going to the background
    clears the mark, and a pull still in flight then cannot set it again;
  - it was taken before or while the gate waited for the owner (onboarding, the
    starting point, the paywall).

  So a waiting gate's exit leaves mirrors to the next activation's pull, as booking
  intake already did (defect `P12-016`). If a recovery merge's local save fails, the
  item stays for the next pass. The pass records the bounded code
  `recovery/local-commit` in the sync status and writes no message to the screen
  (final review M5).
- What the status read proves. A Create or Rotate mirror is applied only if the read of
  its staged token says `tokenValid`. An Enable or Disable mirror carries no token: its
  read carries the local link's token, because the merge writes that token back with the
  server's flag, and it is applied only on `tokenValid`. Either kind is removed without a
  write when the token is not current, or when there is nothing to merge into. Recovery
  never sends a change to the server.
- A proof stays only while its resolve can still succeed: the request still asks for a
  reschedule and the job still has the proven schedule. Recovery never resolves; the
  owner does, by tapping "I've rescheduled it" again (`AppStore.acceptBookingReschedule`,
  defect `P12-015`, fixed). An accept that could not finish shows why on the screen the
  owner used, and keeps its proof (`N/AppStore.swift:10391-10394` removes it only after
  the server confirms) until the owner taps again or the request moves on.
  Proofs are checked in every pass, before or after the pull: the check reads local
  state only, writes no record and queues nothing, so it cannot push a pre-pull copy.

An item also leaves when the flow that staged it succeeds on a later try, or at the
account's sign-out scrub. A count that stays is a mirror waiting for a committed pull
and a successful status read (for example offline), or a proof waiting for the owner.
Each pass that finds items logs one counts-only line,
`TradeReadyScheduleBookingRecovery stage=pass applied=… dropped=… kept=… stopped=…`
(`stopped` counts items left because the account changed during the pass). It goes to
the unified log, subsystem `com.tradeready.native`, category `diagnostics`, so a
TestFlight or App Store build keeps it (final review M6; monitoring doc §4).

**Not ready, fail-closed: nothing was sent.** The drain outcome is `skipped`.

| Code | User sees |
|---|---|
| `not-verified-owner` | "sign in to your account" |
| `initial-sync-incomplete` | "the first sync hasn't finished" |
| `writes-blocked` | "saving is paused on this device" |
| `account-scrub-pending`, `boundary-step-pending`, `account-operation-in-flight` | "an account change is still finishing" |
| `migration-incomplete`, `migration-unreadable` | "moving data from the previous app hasn't finished" |

**The account changes during the drain.** The result is `account-changed` ("the account
changed during the check, so run it again"). It is stored under the old account, so the
next account never sees it.

**Why every blocker must be clear.** The Expo build never sees any of them: the native
queue, the refused-change store, the widget replay queue and the native photo files. It
reads only its own AsyncStorage and the cloud. The booking-work file is not needed there
(above).

**Accepted limits:**

- A photo whose local file is gone does not block. There is nothing left to upload.
- A device that never had React Native data has no journal entry (`no-entry`), and that
  is ready.

**Host tests:** `native/run-rollback-readiness-tests.sh`.

### 5.2 Rule (3), native: the journal adopts native and cloud state (`P12-011`)

**Before 12.06.** A completed import already returned `.alreadyCompleted` without
reading the source again, and a native snapshot without migration provenance was never
replaced (charter §6). The 12.06 characterization found one gap (charter §10,
`P12-011`, S1).

The gap needed a device whose native workspace an account boundary had cleared, with no
snapshot and no completed journal. Two cases:

- a native-only install that was then signed out;
- an interrupted first migration, then a sign-out.

On a re-upgrade of such a device, the launch migration imported the Expo build's stale
AsyncStorage:

- its records;
- its session, published to the native Keychain;
- a new journal entry and new backups;
- the migrated notice.

With no React Native owner keys, account B's launch then queued those records for B's
push.

**Now.** `LegacyMigrationCoordinator.settledOutcome` (`N/LegacyMigrationCoordinator.swift:842`)
runs before any read of the legacy source:

- A completed journal settles as `already-completed`.
- A workspace an account scrub cleared, or whose snapshot survives only as its backup,
  settles as `native-state-adopted`.

Both keep the Task 9 re-protect of the published legacy directory. For the two P12-011
cases above, the launch shows nothing and the support report's `launchMigration`
outcome reads `native-state-adopted`. A device that migrated never attempts the migration again,
signed in or signed out (P12-003): its `launchMigration` outcome reads `not-attempted`,
and `persistence.migrationStatuses` shows `react-native-async-storage-to-v1` as
`completed`. Row P12-RB-7 checks the native-only sign-out case on a device (§8.2).

**Edits made in the Expo build during the rollback window reach native only through the
cloud,** by the native pull. The Expo build must therefore sync before the re-upgrade
(§6 step 10; §7.2 part C).

**Host tests:** `native/run-legacy-reimport-tests.sh`:

- section 8: re-upgrade cases R1–R6, characterized first against the unchanged code;
- section 9: G6.

### 5.3 Rule (1), Expo: a requirement for the Expo release branch (not implemented here)

Phase 12 agents do not edit React Native code (plan §1). Charter §6 asks 12.06 to record
two things: whether the release branch's existing pull meets rule (1), and who makes any
change.

**Finding: it does not meet it.** The existing Expo build has no warning about unsynced
native changes at all. On a device that ran the Expo build before the native one, with
changes still queued at the upgrade, it also pushes that stale queue before it pulls.
Citations are at `9e84478`; they are React Native files, read-only here.

1. The upgrade leaves the Expo AsyncStorage in place (G6, charter §5.4 item 1),
   including:
   - `__initDone_<user>`;
   - the pre-upgrade `__syncQueue`;
   - the old cursor `__lastSyncedAt` (`utils/sync.ts:11-13`).

   Native preserves these keys and never replays them
   (`N/LegacyMigrationCoordinator.swift:659`, `:682`).
2. On the Expo build's next launch, `initialSync` finds `__initDone_<user>` and calls
   `syncIfOnline` (`utils/sync.ts:365-369`). That pushes the pre-upgrade queue **before**
   it pulls (`utils/sync.ts:320-321`), stamping each item with the push time
   (`utils/sync.ts:163`).

   If that queue is empty, the pull alone brings every native-era row, because each
   has a database `updated_at` later than the old cursor. If it is not empty, the
   database stamps each pushed row's `updated_at` with its own clock
   (`supabase/migrations/20260831_updated_at_server_authority.sql`). Under whole-record
   last-writer-wins (`docs/native-phase-4-mixed-client-convergence.md`), every stale
   queued record overwrites the newer native-era row of that record, and the pull that
   follows brings the stale value back. **That is data loss (S1)**, filed as defect
   `P12-012` (charter §10): open, and it blocks Stage A entry until the owner records a
   ruling (R43).

   A native sign-out does not prevent it. The native sign-out never touches the Expo
   AsyncStorage, so `__initDone_<user>` and the stale `__syncQueue` survive it, and the
   same user signing in to the Expo build takes the same push-first path.

   The foreground sync (`context/AuthContext.tsx:118`) and the sync banner's "Sync now"
   (`components/SyncBanner.tsx:65-73`) push the same queue, and the banner counts it as
   "N changes pending" (`components/SyncBanner.tsx:47`).

   The stale queue is not the only source. Every save queues the whole collection it
   saves (`utils/sync.ts:121-123`, `utils/storage/collections.ts:29-31`), and the launch
   migrations and the push-token save run at every launch (`App.tsx:390-403`). So any
   save before the pull queues pre-native copies as well, including a save made
   offline, when no sync runs at all (`utils/sync.ts:318-319`). Review fix round 3
   (R48) moved E-1's check to app start for this reason.
3. **Where it is already safe:**
   - **A native-only install.** It has no `__initDone_` key, so `initialSync` takes the
     full-pull path: an empty cursor, then a pull (`utils/sync.ts:397-398`).
   - **Another account signing in.** A different owner marker wipes the local
     collections and the queue first (`utils/sync.ts:394-395`), then resets the cursor
     and pulls (`utils/sync.ts:397-398`).

**Requirements for the Expo release branch** (to build into R before it is uploaded):

- **E-1. Once per native run: detect it at app start, drop the queue that predates it,
  clear the stale copies, then pull.** Defined in review fix rounds 2 and 3 (R45, R45a,
  R48); round 4 (R49) holds the widget and Siri replay and invoice creation until the
  pull.
  - **When R looks: at app start, on every launch.** The check runs as soon as R's
    JavaScript starts, before anything reads or writes a collection:
    - before the first screen renders;
    - before `initialSync` (`context/AuthContext.tsx:42`);
    - before the launch migrations and the push-token save (`App.tsx:390-403`);
    - before the background refresh task syncs (`utils/backgroundRefresh.ts:100`);
    - before any widget and Siri replay (`context/AuthContext.tsx:108`,
      `utils/backgroundRefresh.ts:106`).

    It runs online or offline, signed in or signed out, because it reads only a file and
    AsyncStorage. It must not wait for a sync, for two reasons:
    - Offline, `syncIfOnline` returns before `pushQueue` (`utils/sync.ts:318-319`), but
      every save still enqueues (`utils/storage/collections.ts:29-31`).
    - The first sign-in path of `initialSync` pulls without calling `syncIfOnline`
      (`utils/sync.ts:390-398`).
  - **The signal: the native run marker.**
    `Application Support/TradeReadyNative/native-run-marker.json` holds
    `{"run":<n>,"schemaVersion":1}` (`N/NativeRunMarker.swift`).
    - Every native launch adds one to `run` after its launch work
      (`N/AppStore.swift:868`), including a signed-out or blocked launch.
    - A missing or unreadable marker restarts at a random run in 1…2,147,483,647, not
      at a fixed value (review fix round 3). The chance that a restart repeats the run
      R recorded is about one in two billion.
    - No account boundary removes it. The sign-out's `.live` scrub deletes `store.json`
      and its backup (`N/Domain/SnapshotRepository.swift:258-259`) but not this file. A
      deletion (`.all`) keeps it too.
    - Deleting the app removes it, together with R's AsyncStorage.
    - It holds no account data.

    R reads it with `expo-file-system`, which the Expo build already has. That module
    has no Application Support constant, so the branch owner must build the path and
    confirm on a device that the module can read it. Without that read, E-1 has no
    signal and the §5.3 build is not done. Host test:
    `native/run-rollback-readiness-tests.sh`, section M.
  - **R's record.** R keeps one small AsyncStorage key, for example `__nativeRun` (the
    branch owner names it), holding `{"run":<n>,"state":"pending"|"seen"}`, plus a
    fingerprint in the one case below. `run` is the **last usable run** R detected: the
    `run` of the last usable marker, or the sentinel `0` from the directory fallback. An
    unusable marker never changes it (final review I1, 2026-09-27). The record is device
    state, so the Expo sign-out (E-4) keeps it.
  - **Three states of the marker file.** R reads the file at app start and puts it in
    exactly one state. The native build's own `NativeRunMarker.load()` returns nil for
    both a missing and an unusable file (`N/NativeRunMarker.swift:40-46`). R must not copy
    that, because the two states lead to opposite actions.
    - **Missing:** there is no file at the marker path.
    - **Usable:** the file opens and parses, its `schemaVersion` is 1, and its `run` is
      a whole number of at least 1. These are the tests the native build applies to the
      same file (`N/NativeRunMarker.swift:40-46`).
    - **Unusable:** the file exists but is not usable. R cannot open it, cannot parse
      it, or its `schemaVersion` or `run` fails the tests.
  - **A new native run** is decided by these rules, in order. Anything else is "no new
    native run", and E-1 does nothing.
    1. **Usable marker:** a new native run exactly when its `run` differs from the
       record's last usable run, or when there is no record yet. R then records that
       `run` and clears any fingerprint. A usable marker whose `run` equals the last
       usable run changes nothing, not even the fingerprint. So a marker that becomes
       readable again after a launch that found it unusable is **not** a new native
       run: a transient read failure never fires a second detection, and a later
       transient failure that reads the same way ("unreadable") does not fire again.
    2. **Unusable marker** (review fix round 4): a new native run exactly when its
       fingerprint differs from the recorded one. A record with no fingerprint (no
       record at all, or one left by a new usable run or the directory fallback)
       differs from every fingerprint. R records the fingerprint and **keeps the last
       usable run unchanged**. The fingerprint is a short hash of the file's contents, or of
       "unreadable" when R cannot open the file. The branch owner picks it, for example a
       32-bit hash, so the record stays small. So an unusable marker fires once for each
       change to the file, not at every launch. This is the fail-safe choice: missing a
       native run lets R push a stale queue (the `P12-012` class), while a detection too
       many costs a pull and whatever R had not yet synced.
    3. **Missing marker, no record yet, and the native directory
       `Application Support/TradeReadyNative/` exists** (the directory fallback). The
       directory or any file in it counts, even with no marker. It is permanent (every
       native launch creates it, `N/AppStore.swift:624-626`), so it cannot tell one run
       from the next. It fires with no marker when a native build never reached
       `N/AppStore.swift:868`, or when all its marker writes failed. R records the sentinel
       run `0`. No marker can hold 0 (`run` is at least 1, `N/NativeRunMarker.swift:44`),
       so the fallback fires once, and any later usable marker still counts as new.
    4. **Missing marker and no native directory: no native run.** The device never ran
       the native build, for example the App Store Expo build L updated straight to R.
       E-1 detects nothing, clears nothing and drops nothing. R's queue, including edits
       L left unsynced, is pushed as usual. This is §8.2's L→R check (steps U1–U3). A
       missing marker with a record already present is also not a new run: E-1 needs a
       usable or unusable marker to fire again.
    - `store.json` alone is never a signal. A signed-out native device has none, yet its
      stale queue survives (item 2).
  - **On a new native run, one write.** Before anything else runs, R makes one
    `AsyncStorage.multiSet` that:
    - sets `__syncQueue` to empty, because every entry in it predates the detection;
    - sets `__lastSyncedAt` to the empty cursor, so the next pull is a full pull;
    - sets every pulled collection (`COLLECTION_TABLES`, `utils/sync.ts:77`) to an
      empty list and `customerNotes` to an empty map;
    - sets E-1's held settings paths (below) to empty, since a later native run drops
      R's earlier edits along with its queue;
    - records the run as pending.

    The collections and the notes are the keys the other-owner path clears
    (`utils/sync.ts:394`), with one exception: E-1 keeps `review_requests`. That key is
    local-only. No table holds it, so no pull could bring it back, and it is R's only
    record of which jobs already had a review request
    (`screens/JobDetailScreen.tsx:621`, `utils/reviewRequest.ts:103`, `:136-157`).
    Clearing it would invite a second request to the same customer. It is never queued
    or pushed, so keeping it cannot overwrite anything. The other-owner path and the
    Expo sign-out still clear it (`utils/storage/lifecycle.ts:120`).

    The write does not touch the App Group, where widget and Siri actions wait (below).
    The collections are written empty, not removed. A missing collection makes the
    loaders show sample data (`utils/storage/collections.ts:17-24`).

    Every value in the write is under 1,024 characters. AsyncStorage 2.2.0 keeps such
    values in its manifest and writes the manifest once, atomically (iOS
    `RNCAsyncStorage.mm`, `_writeEntry` and `_writeManifest`). A larger value would go
    to its own file first, so the write must stay small. If R stops before the write
    lands, the record still holds the old run. The next launch then detects again and
    repeats the write before anything renders.
  - **While the run is pending** (on every launch, until the pull lands):
    - **R lists no pre-native record**, so none can be shown, edited or queued.
    - **A record the user creates is queued and pushed as usual.** It is new, not a
      stale copy. Invoices are the exception (below).
    - **Settings are held.** Settings are one record, and they cannot be cleared: with
      no settings key, R falls back to the defaults (`utils/storage/settings.ts:63`).
      They are the one pre-native copy R keeps, shows and uses while the run is
      pending: the business name on screen, the labor rate a new job starts with
      (`screens/AddJobScreen.tsx:340`), and the numbering and payment settings an
      invoice would use (`utils/invoiceNumber.ts:30-51`, `utils/autoInvoice.ts:366-377`).
      That is one more reason invoices wait for the pull (below).

      The push-token save and the Square-token scrub can change settings at any launch
      (`utils/pushToken.ts:26`, `utils/storage/settings.ts:96-103`). While the run is
      pending, `saveSettings` does not queue `settings` (its `enqueue` call,
      `utils/storage/settings.ts:79`, is skipped). R records each changed leaf path in its
      own key instead, for example `__nativeRunHeldSettings`.
      - **Where the comparison runs (final review I2, 2026-09-27).** Inside
        `saveSettings`, **before** its AsyncStorage write
        (`utils/storage/settings.ts:75-78`). It compares the public settings being saved
        (`publicSettings`, with the secure fields removed, `:71-74`) with the stored
        public settings (`AsyncStorage.getItem(KEYS.settings)` read at that moment). It
        adds every value that was added, changed or removed, under its full path, to the
        paths already held.
      - **Why not in `enqueue` (`utils/sync.ts:99-106`).** `saveSettings` has already
        written the new value when it calls `enqueue`, so the stored settings there equal
        the new ones. The diff would always be empty, and the pull would silently drop
        R's pending settings edits (`utils/sync.ts:293-295`).
      - **Why not a baseline taken at the detection** (the alternative). It would be a
        copy of the whole settings object, which can exceed the 1,024-character limit
        that keeps the detection's one write atomic (below), and it would have to survive
        until the pull.
      - **How paths are held.** A nested object is held by its leaves, such as
        `providerKeys.square` (which the scrub removes) or `pushToken.token`, so applying
        the hold never carries stale sibling values over the pulled object. A list or a
        plain value is a leaf.
      - **The check.** §8.2 step 9's ` r0` check fails if the comparison ran after the
        write.
    - **Widget and Siri actions wait.** R does not run its widget and Siri replay
      (`replayWidgetActions`) while the run is pending: not at session start
      (`context/AuthContext.tsx:108`), not after a foreground sync (`:129`) and not in
      the background task (`utils/backgroundRefresh.ts:106`). It leaves the App Group
      `widgetActions` queue as it is; only the Expo sign-out's existing wipe removes it
      (E-4).

      The replay removes the queue before it applies it (`utils/widgetActions.ts:249-251`)
      and skips a timer action whose job is not listed (`:104-105`, `:112-115`). Against
      the cleared jobs it would lose every clock-in and clock-out waiting there: a tap on
      the native widget after the native build last ran, or a Siri "stop my timer" while
      R is pending offline. Skipping the call also skips the widget refresh it ends with
      (`utils/widgetActions.ts:284`) until the replay after the pull.
    - **Invoices wait.** R creates no invoice while the run is pending. The next invoice
      number comes from the invoices on the device only (`utils/invoiceNumber.ts:30-51`).
      With them cleared, a new invoice would start again at the settings floor
      (`INV-0001` by default) and repeat numbers already sent to customers. The block
      covers every path that numbers an invoice:
      - the Add Invoice screen (`screens/AddInvoiceScreen.tsx:88`);
      - an invoice from a job (`screens/CreateInvoiceFromJobScreen.tsx:234`);
      - auto-invoice when a job is marked complete (`utils/autoInvoice.ts:209`, called
        from `screens/JobDetailScreen.tsx:857`). The job is saved as complete without
        its invoice, as when any other auto-invoice condition is unmet, and the user
        creates the invoice from the job after the pull;
      - the recurring-invoice generator (`utils/recurringInvoices.ts:131`), which runs
        at session start and on each foreground (`context/AuthContext.tsx:104`, `:133`);
      - an import that creates invoices (`utils/importEngine.ts:334`).

      Every other record can be created while pending (residual 5).
    - **The pending notice** (the owner approves the wording) says that:
      - R is getting the latest data from the cloud, so empty lists are not lost data;
      - settings, such as the business name and rates, may be out of date until then;
      - invoices can be created once the cloud copy has loaded;
      - timer taps, trips and expenses from the widget or Siri are added then.
    - **A relaunch** finds the record pending and the marker unchanged. It detects
      nothing, clears nothing and drops nothing more. The settings hold, the widget and
      invoice holds and the pending notice all stay.
  - **The pull completes the run.** The detection and the clear never wait for a sync
    (above). Of E-1's own steps, only the pull waits for the first online, signed-in
    sync; the holds above wait for the pull. The run completes when a pull reads every
    table, the settings and the customer notes without an error, whichever path runs
    it:
    - `syncIfOnline` (`utils/sync.ts:316-321`);
    - `initialSync`'s first sign-in (`utils/sync.ts:397-398`);
    - the other-owner path (`utils/sync.ts:394-398`).

    Today `pullRemote` swallows a table's failure (`utils/sync.ts:283`) and any other
    error (`utils/sync.ts:310-312`), so the branch must make it report success. On
    success, in this order:
    1. apply the held leaf paths over the pulled settings, save the result and queue
       that settings record. This one save bypasses the hold: it runs while the run is
       still pending, and it queues the record instead of recording leaf paths. It goes
       through `saveSettings`, even when no path is held, so its notification sweep
       (`syncNotifications`, `utils/storage/settings.ts:81`) runs over the pulled
       records. That sweep re-arms the local reminders that every sweep while pending
       cancelled (§5.6 item 5; final review, R50 concern 4). The pull alone writes raw
       and runs no sweep (`utils/sync.ts:287`, `:294`, `:305`);
    2. then record the run as seen and remove the held paths. From here invoices can be
       created again: by hand, by auto-invoice, by the recurring generator or by an
       import;
    3. then run the widget and Siri replay once (`replayWidgetActions`). The actions
       queued before or during the pending state now find their jobs.

    The order makes a crash harmless. Until the run is seen, the held paths stay, so the
    next successful pull applies them again. Queuing settings again replaces the earlier
    entry (`utils/sync.ts:100-104`). Held paths found while the run is already seen are
    removed, never applied. A crash before step 3 leaves the App Group queue as it was,
    and R's next replay, at session start, foreground or in the background, applies it.

    **An action whose job is still missing after the pull**, because the job was
    deleted or never reached the cloud (§5.6 item 4), is skipped and removed, as the
    replay does today on any build (`utils/widgetActions.ts:104-105`, `:112-115`,
    `:249-251`). E-1 keeps that rule. The replay is R's existing one in every other way
    too: like today, it does not check which account queued an action (a queued action
    carries no owner, `utils/widgetActions.ts:37-52`). The Expo sign-out's App Group
    wipe (E-4) separates accounts only when the account change goes through the Expo
    sign-out. It does not cover an account change made in the native build before R
    runs. That case is §5.6 item 6, which needs the owner's acceptance.

    Held paths that belong to another account are discarded, never applied: the
    other-owner path and the Expo sign-out (E-4) remove them.
  - **Invariants.**
    - **R never drops an edit it made after a detection.** Only a later detection drops
      it: a later native run (below), or a change to a marker R cannot use (above). A
      missing marker on a device with no native directory, and a marker that becomes
      readable again with the run R last recorded as usable, are never detections (the
      rules above, final review I1). So an L→R update never drops R's unsynced queue.
      A transient read failure drops it at most once: at the launch that could not read
      the marker (the fail-safe of rule 2), never again when the marker reads back
      unchanged.
    - **R never drops a queued widget or Siri action because of E-1.** This covers the
      App Group `widgetActions` queue: timer start and stop, trips and expenses. While
      the run is pending R leaves that queue alone, and it replays the queue once the
      run is seen, after the pull has brought the jobs back. The replay's existing rules
      still drop an action it cannot apply, such as a timer action whose job is missing
      (above), and the Expo sign-out's App Group wipe (E-4) still removes the queue.

      Two kinds of handoff are **not** held (final review, R50 NB5). R still consumes
      them while pending:
      - the On My Way stash `pendingOpenUrl` (`App.tsx:541-545`);
      - a widget deep link to a job.

      Either can name a job R has cleared, and then it does nothing
      (`screens/JobDetailScreen.tsx:832`). The link is gone, but no data is lost: the
      user opens the job again after the pull.
    - **The replay can land after in-app timer changes** (final review, R50 NB3). An
      action waits until the pull, so it can apply after an in-app clock-in or clock-out
      the user made on the same job while pending. That job is one R lists then, so one
      R created in the window. Two outcomes:
      - A queued Start opens a session back-dated to the tap, after the in-app session
        closed. `applyClockIn` refuses only while a session is running
        (`utils/timeTracking.ts:107`).
      - A queued Stop closes the newer in-app session at zero length, because the end is
        clamped to its start (`utils/timeTracking.ts:128`).

      That job's billed hours can then be wrong until the user corrects the session
      (§5.6 item 5).
    - **R never numbers an invoice against the cleared list.** Invoice creation waits
      until the run is seen.
    - **The pull never silently reverts an edit R made.** Apart from settings, nothing R
      shows before the pull is a pre-native copy. Settings are the one pre-native copy R
      shows and uses while pending, and the pending notice says they may be out of date.
      A record R created survives the pull, because the pull replaces by id and keeps
      local-only records (`utils/sync.ts:262-272`). Held settings paths are applied
      after the pull.
    - **R never pushes a stale copy.** The queue is emptied at the detection. No
      pre-native copy is left to be queued, although every save queues the whole
      collection (`utils/sync.ts:121-123`). Settings are queued only after the pull, and
      only as the pulled record with R's held paths on top.
  - **Clear, not hold: recommended.** The branch owner records the choice. A hold would
    keep the pre-native copies on screen and hold every enqueue until the pull. The
    clear is preferred for three reasons:
    - **The invariants hold by construction, not by merge code.** Nothing stale stays on
      the device, so no stale copy can be shown, edited, queued or pushed, and no pull
      can revert an edit made to one.
    - **It reuses a path R already runs** when another account signs in
      (`utils/sync.ts:394-398`).
    - **A hold keeps stale copies on screen.** An invoice paid in the native window
      shows as unpaid and invites a second payment. Replaying held edits after the pull
      also needs a per-field merge for every table, including the invoice
      payment-ledger union (`utils/syncMerge.ts:47`) and deletes. That is new merge code
      whose failure pushes stale fields: the `P12-012` class.

    **Invoice numbering does not decide between them.** A hold keeps the pre-native
    invoices but not those numbered in the native window, so its next number could
    still repeat one already sent. Either way, invoice creation waits for the pull.

    **The cost** (residual 5, §5.6 item 5): until the pull, R lists no records, whether
    offline or before sign-in. Invoices cannot be created, because numbering needs the
    whole invoice list, and widget and Siri actions wait. A record created then can
    duplicate one in the cloud. Settings are the only data R keeps back from the queue,
    limited to the changed leaf paths.
  - **No new native run: E-1 does nothing.**
    - A detection never drops a queue entry that R creates after it.
    - A relaunch of R with its own pending queue and no native run since drops
      nothing, and the sync pushes that queue (§8.2 step 12).
  - **After N2, then R again** (a later native run), E-1 at app start drops the stranded
    pre-N2 R queue and clears the pre-N2 copies. It never pushes them, because those
    entries predate N2's rows and a push would overwrite them: the `P12-012` class. This
    is residual 1 (§5.6 item 1).
  - **The branch owner records** the record key, the clear or hold choice, the marker
    path, the fingerprint and the pending-state wording. The rehearsal checks:
    - R's first action offline, with a widget tap waiting from before R opened and the
      invoice block (§8.2 steps 4, 8 and 9). Step 9's ` r0` check also shows that the
      settings hold compares before `saveSettings` writes;
    - the relaunch case (§8.2 step 12);
    - the signed-out native case (§8.2 steps S1–S5);
    - R starting signed out (§8.2 step D3);
    - a device that never ran the native build, the App Store Expo build L updated
      straight to R (§8.2 steps U1–U3; final review I1). E-1 must detect nothing, and
      L's unsynced edit must reach the cloud. This is the check that catches a missing
      marker treated as unusable.
- **E-2.** Show an unsynced-changes warning when the Expo build cannot confirm that the
  native build's changes were drained. For example: "Changes made in the newer version
  that hadn't finished uploading may be missing. Open the newer version again to upload
  them, or contact support."

  An Expo build cannot read the native queue reliably. Warn on each E-1 detection, at
  app start and once per native run, unless the owner accepts a narrower signal. A
  relaunch with no native run since does not warn again. The warning is separate from
  E-1's pending notice, which stays until the pull lands. The warning is not about
  widget or Siri actions waiting in the App Group: they are not missing, and E-1
  applies them after the pull (the pending notice says so).
- **E-3.** Never modify or delete the native store, its journal, `LegacyBackups/`, the
  native run marker or the native Keychain items. They make the re-upgrade safe (§5.2)
  and let E-1 work, and a deletion would contradict Phase 0 step 4. While E-1's run is
  pending, R also leaves the App Group `widgetActions` queue alone, apart from the
  sign-out's existing wipe (E-4). After that, its replay consumes the queue as it does
  today (E-1).
- **E-4.** Keep the existing sign-out rule: the Expo sign-out clears the queue and the
  owner marker (`utils/storage/lifecycle.ts:106-159`). It also clears E-1's held
  settings paths, which are account data. It keeps E-1's run record, which is device
  state, and a pending run stays pending until a successful pull under the next
  account. The sign-out's existing App Group wipe (`utils/storage/lifecycle.ts:141`)
  also removes any widget and Siri actions still waiting, pending run or not: they
  belong to the account that signs out. E-1 does not change that.

**Who makes the change.** The owner, as the holder of every role (D5), or an agent the
owner assigns to the Expo release branch outside Phase 12's lanes. Until it is built:

- the rehearsal (§8) cannot pass for a device upgraded from the Expo build;
- §2.2 condition 4 is not met;
- defect `P12-012` stays open (charter §10).

**When the build may start** (final review Recommendation 6, 2026-09-27). The Expo
release branch build of E-1 to E-4 starts only after the owner accepts this §5.3 as
final. That acceptance comes after the Phase 12 final-review fix wave's re-review, and
the owner records it in the decision log (charter §9). The fix wave corrected two
Important defects in this text (I1: the unusable-marker rule; I2: where the settings
hold compares). An Expo build begun from an earlier draft could carry them, and both
lose R's unsynced edits.

### 5.4 Backend compatibility in both directions (plan 12.06 step 3)

During the rollback window both clients talk to the same Worker and Supabase project. The
wire contract is `docs/native-phase-4-mixed-client-convergence.md`:

- React Native upserts send `updated_at`, and Swift omits it;
- the database clock always wins;
- deletes are owner-filtered soft updates.

Phase 0's backend rule holds: new fields are additive and optional until the Expo client
is retired, and no native-driven backend change removes or reinterprets a field the Expo
client uses. §6 step 2 keeps the Worker on the last mixed-client-compatible deployment.
The rehearsal (P12-RB-2, P12-RB-3) checks both directions on a device.

### 5.5 G6 retention and account deletion

- **Live accounts.** The React Native source files and `LegacyBackups/` stay readable by
  the Expo build (charter §5.4; Phase 0 step 4; plan step 1(d)). Sign-out, launch,
  migration retry and re-upgrade never delete them. The host test is
  `native/run-legacy-reimport-tests.sh` section 9.
- **Permanent deletion.** A permanent account deletion (the `.all` scrub) is the one
  exemption. It removes `LegacyBackups/` and the journal, and it erases the React Native
  source files install-wide, whichever account the React Native build last held
  (charter §5.4 item 5, G6-Q1, `P12-001`). It keeps the native run marker, which holds
  no account data (§5.3 E-1).

  After a deletion, the Expo rollback build finds no local data and starts signed out.
  That is expected. The deleted account's cloud data is gone as well, so nothing is lost
  that the user did not delete. The support script never offers the rollback build as a
  way to recover a deleted account.

### 5.6 Known residuals (recorded, not fixed in 12.06)

1. **An Expo-window edit that never synced before the re-upgrade is lost.** Native never
   re-imports AsyncStorage (rule 3), so N2 never shows it. The edit stays in the React
   Native files (G6), but no build pushes it:
   - A user cannot install R once N2 is the App Store version.
   - If R runs again after N2 (TestFlight), E-1 sees N2's run at app start. It drops
     that stranded queue and clears the pre-N2 copies rather than push them over N2-era
     rows (§5.3).

   The procedure is to sync the Expo build before the re-upgrade (§6 step 10, §7.2
   part C). Relaunching R before then is safe: with no native run since, E-1 drops
   nothing (§8.2 step 12). The rehearsal leaves one edit unsynced on purpose (§8.2 step
   13, row P12-RB-3). This residual needs the owner's acceptance in the decision log;
   otherwise it is a defect (charter §2 rule 4).
2. **A native change still queued when the Expo build was installed is pushed at the
   re-upgrade.** This is the case where the user skipped the check, or it was not ready.
   The Expo build never removes the native queue, so the change is not lost. But if the
   same record was also edited in the Expo window, the native push is the later write and
   wins: the Expo-window edit to that one record is overwritten. The mitigation is the
   drain before any advisory (§5.1, §7.2 part A).

   Two more effects of the same queued change (final review, R50 NB4):
   - **A job still in the native queue.** R's pull does not bring it back, so R's
     post-pull replay skips and removes a widget or Siri timer action for that job
     (`utils/widgetActions.ts:104-105`, `:112-115`, `:249-251`). The tap is lost, and
     the job returns only when N2 pushes it at the re-upgrade.
   - **An invoice still in the native queue.** R numbers its invoices from the ones it
     pulled (`utils/invoiceNumber.ts:30-51`), so an invoice R creates after the pull can
     take the number of that native invoice. N2 pushes the native invoice later, and
     the two share a number.

   The rehearsal records the observed winner (§8.2 step 16, row P12-RB-3). A lost edit there
   matches this residual. It is a new defect only if the owner rules so in the decision
   log.
3. **The sign-in state after each transition is not predicted here.** The Expo and
   native builds keep separate sessions, and the Supabase refresh token rotates. The
   rehearsal records whether each transition asked for a sign-in. It never shows another
   account's data. R starting signed out does not weaken E-1: the check runs at app
   start, before the sign-in, and the first sign-in's pull completes the run (§5.3;
   §8.2 step D3).
4. **E-1's queue drop and clear rely on native having pushed the records it imported.**
   The pre-upgrade `__syncQueue` and collections hold edits that the native build
   imported at the upgrade. E-1 loses nothing when native has already pushed those
   records to the cloud.

   If native never finished its initial sync on that device, E-1 drops the queue and
   clears the copies while the edits exist only in native's store. R does not show
   them. They come back only at the re-upgrade, when N2 pushes them, with the
   same-record overwrite of item 2. A widget or Siri timer action for such a job finds
   no job after R's pull either, and the replay skips it (§5.3 E-1).

   The check guards this: it reads `initial-sync-incomplete`, and support does not
   advise the rollback (§5.1). Only a device that skipped the check reaches this case.
5. **Until R's first successful pull after a native run, R lists no records** (the cost
   of E-1's clear, §5.3). This holds offline or before sign-in. R shows its pending
   notice instead. In that window:
   - **A record created then is kept and pushed, but it can duplicate one already in
     the cloud**, for example a customer or a job. The owner accepts this with the §5.3
     build.
   - **No invoice can be created**, by hand, by auto-invoice, by the recurring generator
     or by an import. The next invoice number comes from the invoices on the device only
     (`utils/invoiceNumber.ts:30-51`); with them cleared, it would repeat numbers
     already sent to customers. So a duplicate from this window is never an invoice.
   - **Widget and Siri actions wait** in the App Group and are applied after the pull. A
     timer action whose job is not in the cloud is skipped then, as on any build.
     Because they wait, an action can land after an in-app timer change the user made
     in the window, on a job R created then: a back-dated session, or a zero-length
     stop. That job's billed hours can be wrong until the user corrects the session
     (§5.3 E-1 invariants; final review, R50 NB3).
   - **Settings are the pre-native copy**, and the pending notice says they may be out
     of date. A new job starts with the pre-native labor rate. A settings change made in
     the window is applied after the pull.
   - **Local reminders are off until the pull** (final review, R50 concern 4). Every
     notification sweep while pending cancels all scheduled local notifications
     (`utils/notifications.ts:109`), then rebuilds them from the cleared collections
     (`:92-105`), so none is scheduled. The sweeps run at session start and on
     foreground (`context/AuthContext.tsx:51`, `:131`) and on every collection or
     settings save (`utils/storage/collections.ts:32`, `:53`, `:74`,
     `utils/storage/settings.ts:81`). This covers invoice follow-ups, appointments,
     recurring-invoice, estimate and review nudges. Completion step 1 runs one sweep over
     the pulled records (§5.3 E-1), which re-arms the reminders still in the future. A
     reminder whose time fell inside the window is skipped, because a sweep schedules
     only future times (`utils/notifications.ts:139`, `:268`). The Worker's server-side
     sweeps are unaffected.

   This is not data loss. It needs the owner's acceptance with the §5.3 build. If the
   owner rules for the hold instead, this residual is replaced by the hold's replay rule
   (§5.3 E-1). The invoice block stays either way, because a hold's invoices lack those
   numbered in the native window.
6. **R's replay applies an action queued under another account** (final review, R50
   concern 2). An action in the App Group `widgetActions` queue carries no owner
   (`utils/widgetActions.ts:37-52`), and R's replay does not check one. Timer actions
   need their job id in R's data, so another account's timer actions are skipped. Trip
   and expense actions need no job, so they are applied to whichever account R is
   signed in as (`utils/widgetActions.ts:136-224`). The Expo sign-out's wipe (E-4)
   separates accounts only when the account change goes through it.

   The case it misses:
   - R's AsyncStorage still holds account X's older Expo session.
   - In the native window the user switched to account A in the native build. The
     native switch wipes the App Group, and A then queued trips or expenses from the
     widget or Siri.
   - R starts signed in as X, and after its pull replays A's trips and expenses into
     X's data.

   That is a cross-account write, S1 in kind, but narrow and pre-existing: any Expo
   build replays this way. It needs the owner's acceptance in the decision log (charter
   §2 rule 4), or a branch change that holds the replay until the owner of the queue is
   known.

## 6. The rollback, step by step

The Phase 0 steps map to this section as follows:

| Phase 0 step | Carried out by |
|---|---|
| 1 | Steps 1 and 7 |
| 2 | Step 2 |
| 3 | Steps 4 and 7 |
| 4 | Step 5 |
| 5 | Step 6 |
| 6 | Steps 3 and 8 |

The plan 12.06 step 1 items (a)–(e) are marked on the steps. Record each step's time in
the run record (§8.3 layout, with "Run" in place of "Rehearsal").

**Step 0 — write the decision.**

> **OWNER-GATED.** Only the owner decides and writes the row.

Add the decision-log row (§2.2) before any action (charter §1 rule 6). Name the affected
versions and the defect row.

**Step 1 — contain (plan (a); Phase 0 step 1).**

> **OWNER-GATED.**

1. In App Store Connect, open the native version N and **pause** the phased release.
   Log the pause and the pause days left (charter §1 rule 2; 30-day budget, §7).
2. If new installs must stop, open Pricing and Availability and choose **Remove App From
   Sale**. This removes the whole app in every region within 24 hours and ends N's phased
   release (charter §7). There is no per-version removal of a live version, and "Make a
   version unavailable" applies only to previous versions.

**Step 2 — keep the Worker compatible (plan (b); Phase 0 step 2).**

> **OWNER-GATED.**

1. Confirm that the deployment serving production is the last one compatible with both
   clients (§5.4). If any deploy happened after the last mixed-client check, roll the
   Worker back to that version (§10.3).
2. Do not deploy anything else during the window (charter §1 rule 4).

**Step 3 — drain before any advisory (charter §6 rule 2; Phase 0 step 6).**

> **OWNER-GATED.** The owner acts as support.

1. Contact each known affected user with the support script, part A (§7.2), before any
   public note.
2. Tell a user to install or accept the rollback build only after their device shows
   "Ready: everything on this device is saved to the cloud."
3. A user who cannot reach "Ready" sends the support report and is escalated. Do not
   advise the update yet (§7.2).

This is how "drain before any rollback advisory" works in practice. The per-user advice
follows that user's drain, and the public note (step 8) goes out only after R is
approved and the known users have been asked to run the check.

R cannot arrive on a user's device before step 7. It is submitted with manual release
(step 4) and released only in step 7, after step 6's reconciliation. So "when it
arrives" in the support script (§7.2) always means after the reconciliation.

**Step 4 — submit R (plan (c); Phase 0 step 3).**

> **OWNER-GATED.**

1. Add the processed candidate R to a new App Store version R. It must be above N (§3).
2. Choose **"Manually release this version"**, and do not choose phased release: after a
   rollback decision, every device should get R as soon as it is released.
3. Submit it for review and request an expedited review through Apple's expedited review
   request form (`<EXPEDITED_REVIEW_FORM_URL>`). The reason must be factual: the defect's
   effect on users, not internal details.

**Step 5 — keep the journals and backups (plan (d); Phase 0 step 4).** This step is a
prohibition, not an action:

- Nobody deletes the native migration journal, `LegacyBackups/`, the React Native
  AsyncStorage or the native store.
- Support never tells a user to delete and reinstall the app. Deleting the app erases
  everything stored only on the device, including unsynced changes and the React Native
  source files.
- In native code, only the permanent-deletion (`.all`) scrub removes them (§5.5,
  host-tested).

**Step 6 — reconcile before users reopen the Expo build (plan (e); Phase 0 step 5).**

> **OWNER-GATED.** Read-only queries only (§10.4).

For each affected account (owner ID), run the queries in §10.4 on rows written in the
native window, between `<NATIVE_RELEASE_AT>` and `<ROLLBACK_AT>`, using the database
`updated_at` and `user_id`:

- Count the rows each account wrote in the native window, per table. That is the scope
  to reconcile.
- Count the account's live (not deleted) rows per table and compare them with the user's
  latest support report (`persistence.recordCounts`). A difference means something is
  only on the device or only in the cloud; resolve it with the user (§7.2) first.
- Confirm that no row carries a native-only `__native` key (L286.1).
- On a team account, confirm that the Expo build R renders native-written records of
  every table (the rehearsal does this; P12-RB-2).

Record counts and pass or fail only, never rows (evidence index §2 rule 2). Resolve any
mismatch before step 7.

**Step 7 — release R (Phase 0 step 3).**

> **OWNER-GATED.** A watch day (charter §1 rule 1).

1. Click **"Release This Version"**. It can take up to 24 hours to appear (charter §7).
2. If the app was removed from sale, reinstate it only once R is the live version.
   Reinstating serves the live version to everyone at once (charter §7 rule 4). Existing
   installs keep receiving updates while the app is off sale (charter §7), so R reaches
   them either way; confirm the behavior in App Store Connect at the time.
3. Watch the dashboards (`docs/native-phase-12-monitoring.md`) at least twice that day
   and once the next day.

**Step 8 — publish the status note (Phase 0 step 6).**

> **OWNER-GATED.**

Publish only when the affected scope and the safe user action are known. Use the status
note template (§7.3).

**Step 9 — close the window.**

> **OWNER-GATED.** Only the owner writes the decision-log row (item 1).

1. Write a decision-log row recording the result: the time of each step and the defects
   raised.
2. Append a stage run record (evidence index §24), using the §8.3 layout, as the plan
   12.07 "Done when" requires ("the rollback playbook has been executed and recorded").

**Step 10 — the re-upgrade (later).**

> **OWNER-GATED.**

1. Ship the fixed native build as N2, above R (§3), with phased release on a planned
   watch calendar (charter §1 rule 3).
2. Before N2 is released, ask known users to sync the Expo build: support script, part C.
   Expo-window edits reach native only through the cloud (§5.2, §5.6 residual 1).
3. On a re-upgraded device, native adopts its own or the cloud's state and never imports
   the Expo build's AsyncStorage again (§5.2). What the support report shows:
   - a device that migrated, signed in or signed out (the usual case): `launchMigration`
     outcome `not-attempted`, with `persistence.migrationStatuses` showing
     `react-native-async-storage-to-v1` as `completed`;
   - a native-only install, or an interrupted first migration, signed out before the
     Expo window (P12-011): `native-state-adopted`.

   Neither shows a migration notice.

## 7. Communication plan

### 7.1 Channels and privacy

**Channels.** The intake is the 12.02 channel: the in-app Contact support email and, in
Stages A and B, TestFlight feedback (`docs/native-phase-12-monitoring.md` §7). The owner
is support (D5). Each contact is a row in the owner's private intake log.

**Privacy rules for every message:**

- Never ask for a password, code, key or token.
- Never ask the user to send records or screenshots of customer data.
- The support report carries none of these (`docs/native-phase-12-monitoring.md` §4), so
  it is the only attachment to ask for.

### 7.2 Support script (template)

Fill in the `<…>` fields per contact. The script tells the user what to tap and what to
read back. It never tells them to delete the app.

**Part A — before the rollback update (native build N installed)**

> Thanks for letting us know. Before anything changes on your phone, let's make sure
> everything you've entered is saved to the cloud.
>
> 1. Please don't delete the app. Deleting it removes anything that hasn't uploaded yet.
> 2. Connect to Wi-Fi or mobile data.
> 3. Open TradeReady and go to **Settings › Cloud Sync**.
> 4. Tap **Check everything is saved** and wait for the line under it.
> 5. Tell us what that line says, and the line after it if there is one.

What support does with the answer. The first line is the result. A second line starting
"Also:" is a note (§5.1) and never changes the result:

| The line says | Support replies |
|---|---|
| "Ready: everything on this device is saved to the cloud." | The user may accept or install version `<ROLLBACK_VERSION>` when it arrives, which is only after its release (§6 step 7) and so after the reconciliation (§6 step 6). Go to part B |
| "N changes waiting to upload" or "N photos waiting to upload" | "Please stay connected, open the app for a minute, and tap Check everything is saved again." Repeat until Ready. If it stays, ask for the support report (below) |
| "N changes the cloud refused need Retry or Discard above" | Explain Retry and Discard (charter §5.3): Retry sends the change again; Discard replaces it with the cloud's version. Ask the user to choose for each, then check again. Never choose for them |
| "N widget or Siri actions not applied yet" | The check already tried to apply them. Ask the user to check again once; if the line stays, ask for the support report and escalate |
| The note "Also: … booking or portal link updates …" (under either result) | Act on the result line only. The work it names holds no changes that need uploading (§5.1). If the user says a booking link, portal link or reschedule looks unfinished, ask them to open the app while connected and check again: opening the app finishes link updates (defect `P12-013`, fixed). An accepted reschedule that did not finish waits for the user to tap "I've rescheduled it" again while connected; the app said why when they tapped it (defect `P12-015`, fixed). If the booking was declined, cancelled or confirmed elsewhere, the note clears the next time the app opens while connected |
| "sign in to your account", "the first sync hasn't finished", "saving is paused on this device", "an account change is still finishing", "moving data from the previous app hasn't finished", "… can't be read" or "… can't be checked" | Do not advise the update. Ask for the support report and escalate as S1 or S2 (charter §2) |
| "the account changed during the check, so run it again" | Ask the user to run it again while signed in to their own account |

**Support report:** Settings › Import Data › Migration support › **Prepare support report**, then
**Share support report**, attached to the reply. The report's `rollbackReadiness` section
shows the last check. Read its blocker codes and counts (§5.1).

**Part B — after the rollback update (the Expo build R installed)**

> Version `<ROLLBACK_VERSION>` is installed. Connect to Wi-Fi or mobile data, open it
> and sign in if it asks. Your data comes from the cloud, so it can take a minute to
> appear. Until it has, the app shows no records and can't create invoices. Timer taps,
> trips and expenses from the widget or Siri are added once it has. If something you
> entered recently is missing after that, don't re-enter it yet and don't delete the
> app. Reply to this message and tell us what's missing, and we'll check.

What support does in part B (§5.3 E-1, §5.6 item 5):

- **R shows no records, or will not create an invoice.** It has not finished its first
  pull after the native build. Ask the user to connect and sign in, then look again.
- **A record created before the pull duplicates one that appeared after it.** A
  customer or job they created in the meantime is kept. If it repeats one from the
  cloud, they can delete the extra copy once nothing they added is only on it. This
  never applies to invoices: R creates none before the pull, so two invoices are two
  different invoices, and support never tells the user to delete one.
- **Two invoices with the same number.** There are three possible causes (final review,
  R50 NB4):
  - the user typed that number by hand (`screens/AddInvoiceScreen.tsx:88`);
  - a native invoice was still queued when R was installed, so R's numbering after
    the pull could not see it (§5.6 item 2);
  - R was built without the invoice block.

  Ask which invoice the user created by hand, and never tell them to delete either
  one. Escalate as S2 (charter §2) when neither of the first two causes explains it.
- **A timer tap, trip or expense from the widget or Siri does not show.** R applies
  waiting widget and Siri actions only after its first pull. Ask the user to connect
  and sign in, and to look again once the records appear. A tap for a job that is not
  in the cloud is skipped: a job that was deleted (as in every version), or one still
  in the native build's queue (§5.6 item 2). That second case needs re-entering the
  time once the newer version is installed again.

If R carries the §5.3 warning and the user saw it, ask whether they had been offline
before the update. Their changes may still be in the newer version's storage, and they
upload when that version is installed again (§5.6 residual 2).

**Part C — before the re-upgrade (N2 due)**

> A new version is coming. Before it installs, please open TradeReady while connected,
> pull down on the Today screen to refresh, and check that no "changes pending" banner
> is showing. If one is, tap **Sync now** and wait for it to go away.

Send part C only when R carries the §5.3 change. On a build without it, "Sync now" in the
Expo build pushes the stale pre-upgrade queue (§5.3).

### 7.3 Status note (template)

> **TradeReady `<DATE>`: we're moving back to version `<ROLLBACK_VERSION>`**
>
> We found a problem in version `<AFFECTED_VERSION>`: `<ONE-SENTENCE USER-VISIBLE EFFECT>`.
> To keep your data safe we're replacing it with version `<ROLLBACK_VERSION>`, which
> arrives as a normal App Store update.
>
> **What to do:** before updating, open TradeReady, go to Settings › Cloud Sync and tap
> *Check everything is saved*. When it says Ready, update as usual. **Please don't delete
> the app.** If it doesn't say Ready, contact us from Settings › Contact support.
>
> **Your data:** `<WHAT IS AND IS NOT AFFECTED>`. We'll post an update by `<NEXT UPDATE TIME>`.
>
> `<SUPPORT_CONTACT>` · `<STATUS_PAGE_URL>`

Publish it only when the affected scope and the safe action are known (Phase 0 step 6).
Never name a user, an account or a customer. Update it at each step change: R approved,
R released, fix in review, N2 released.

## 8. Rehearsal (plan 12.06 step 5) and staffing (step 6)

> **OWNER-GATED.** The whole section. An agent prepared it and never runs it.

The rehearsal is the 12.06 gate for Stage B entry (charter §4.4). It must be recorded
before 12.05 starts: native → Expo (higher build) → native (higher again) on TestFlight,
with real version numbers, an unsynced local edit before each transition, and no data
loss. It uses team accounts and synthetic data only (SA1).

The rows are in evidence index §23:

| Row | What it covers |
|---|---|
| P12-RB-1 | The candidate and the numbering |
| P12-RB-2 | Native → Expo, its signed-out variant and the L→R check (E-1) |
| P12-RB-3 | Expo → native |
| P12-RB-4 | The check on a device |
| P12-RB-5 | SC4 after the round trip |
| P12-RB-6 | Staffing |
| P12-RB-7 | P12-011 on a device: a native-only install signed out before the Expo window |

### 8.1 Prerequisites

The evidence index §5 names:

- SIGN-1, VER-1, TF-INT;
- EXPO-BUILD: the App Store Expo build L on the device;
- G6 approved;
- EXPO-RB: the candidate R on TestFlight, built from the release branch with the §5.3
  change.

The rehearsal also needs:

- a native TestFlight build N2 above R, with N still installable from TestFlight's
  Previous Builds (the signed-out variant and P12-RB-7 install N after N2);
- one physical iPhone (IPH). The signed-out variant and P12-RB-7 each start from a
  device with no TradeReady on it. A second iPhone that has never had the app is
  preferred. Otherwise use the same iPhone after deleting the app, under two rules:
  - each deletion comes after a sequence that is recorded and synced;
  - before each deletion, sign out of the build that is installed, in its Settings.
    Keychain items survive deleting the app (charter §10, `P12-006`), so a session left
    signed in could meet the next sequence's data.
- one team account A with synthetic data, whose customers are labelled `RB-C1` …
  `RB-C9` and whose rehearsal job is `RB-J1`.

No staging is needed. No step deletes an account.

### 8.2 Checklist

Record the time of each numbered step. Each "offline" step means airplane mode on;
"online" means airplane mode off.

**Setup, T0: Expo L → native N**

1. Install L from the App Store on the iPhone and sign in as A. Create customers `RB-C1`
   to `RB-C6` and a job with a photo, and let it sync.
2. Offline, edit `RB-C1` (name suffix ` t0`). Force-quit.
3. Online, install N from TestFlight over L, with no delete. Open it, let it migrate and
   sign in if asked. Check that `RB-C1` shows ` t0`.

**Native window, then T1: native N → Expo R**

4. Online, edit `RB-C1` again (suffix ` n1`) and `RB-C2` (suffix ` n1`). In Settings,
   change the business name (suffix ` n1`). Create job `RB-J1` for `RB-C5`, scheduled
   for today. Let them sync. Add TradeReady's Job Timer widget to the Home Screen and
   check that it shows `RB-J1` (if another job shows, schedule `RB-J1` earlier).
5. Offline, edit `RB-C3` (suffix ` n2`). Open Settings › Cloud Sync and tap Check
   everything is saved. Expect "Not ready yet: 1 change waiting to upload". Export the
   support report.
6. Online, tap the check again. Expect "Ready". Export the support report.
7. Offline, edit `RB-C4` (suffix ` n3`) and force-quit **without** running the check.
   This is the ignored-guard case of §5.6 residual 2.
8. Online, and without opening N:
   - On the Home Screen, tap Start on the Job Timer widget for `RB-J1`. The widget shows
     its pending state. This is a **widget tap made after the native build last ran**
     (§5.3 E-1): it waits in the App Group, and no app has applied it.
   - Straight away, install R from TestFlight. Do not open it yet: turn airplane mode
     on first. This is **R's first action offline** (§5.3 E-1 at app start).
   - Open R offline. Expect the E-2 warning and R's pending notice. No customers or jobs
     are listed, `RB-J1` included, and no sample data shows: E-1 cleared the pre-native
     copies before the first screen.
   - Try to create an invoice. R does not create it and says invoices can be created
     once the cloud copy has loaded.
   - Create customer `RB-C9`. In Settings, change your name (suffix ` r0`).
   - Force-quit R and open it again, still offline. `RB-C9` and ` r0` are still there,
     and nothing from before the upgrade is listed.
   - Go online. Sign in if asked. Pull to refresh.

   If R opens offline asking for a sign-in, it cannot sign in there. Record that this
   case, and the invoice check, were not exercised (§8.2 step D3 covers a signed-out
   start). Then go online, sign in as A, make the same two edits and pull to refresh.
   The step 9 checks still apply, the widget tap included. The first sign-in's pull
   completes the run before the edits, so record the settings hold as not exercised
   too: the ` r0` edit is then an ordinary settings save.

**Expo window, then T2: Expo R → native N2**

9. In R, after the pull, check the records:
   - `RB-C1` shows ` n1`, not ` t0` (§5.3 E-1: the stale queue did not overwrite it).
   - `RB-C2` shows ` n1` and `RB-C3` shows ` n2` (both drained).
   - `RB-C4` does **not** show ` n3` (never uploaded). R showed the §5.3 E-2 warning at
     step 8.
   - `RB-C9` is still listed, and your name shows ` r0`: the pull reverted neither.
     ` r0` is a settings edit made while the run was pending, so it survives only if
     the settings hold compared before `saveSettings` wrote (§5.3 E-1, final review I2).
     If ` r0` is gone, the hold compared after the write: record a failed step.
   - The business name shows ` n1`: R pushed no stale settings.
   - `RB-J1` is listed with a running timer that started at the step 8 widget tap. R
     left the tap in the App Group while pending and applied it after the pull (§5.3
     E-1).
   - Native-written records of every table used (customer, job with photo) render.
10. Online in R, edit `RB-C5` (suffix ` e1`) and `RB-C4` (suffix ` e1`), and let them
    sync. The `RB-C4` edit is the same-record conflict of §5.6 residual 2.
11. Offline in R, edit `RB-C6` (suffix ` e2`). Check that the "changes pending" banner
    shows. Go online, tap Sync now, and wait for the banner to clear (support script
    part C). This is the guarded case.
12. Offline in R, edit `RB-C2` (suffix ` e4`) and check that the banner shows 1 change
    pending. Force-quit R. Still offline, open R again: the banner still shows 1 change
    pending. Go online, pull to refresh, and wait for the banner to clear. `RB-C2` still
    shows ` e4`, and R did not show the E-2 warning again. This is the relaunch case of
    §5.3 E-1: no native build ran since R's last launch, so E-1 drops nothing and R's own
    queue reaches the cloud (step 16 checks it in N2).
13. Offline in R, edit `RB-C3` (suffix ` e3`) and check that the banner shows 1 change
    pending. Force-quit R **without** syncing, go online, do not open R again, and go
    straight to step 14. This is the ignored-guard case of §5.6 residual 1. If N2 later
    shows ` e3`, R synced the edit before the switch (for example through its background
    refresh, `utils/backgroundRefresh.ts`): record that the case was not exercised, for
    the owner's decision.
14. Install N2 from TestFlight over R, with no delete. Open it and sign in if asked
    (record it; §5.6 residual 3). Pull to refresh. Export the support report.

**After T2: check N2**

15. Check the migration state: no migration notice, no conflict or local-recovery
    screen. In the step 14 report, `launchMigration` shows the outcome `not-attempted`:
    this device migrated at T0 and kept its native workspace, so N2's launch finds the
    snapshot and the completed journal and does not attempt the migration.
    `persistence.migrationStatuses` shows `react-native-async-storage-to-v1` as
    `completed`, as in the step 6 report.
16. Check the records:
    - `RB-C1` shows ` n1`: not re-imported from AsyncStorage (§5.2).
    - `RB-C5` shows ` e1` and `RB-C6` shows ` e2`: they arrived through the cloud.
    - `RB-C2` shows ` e4`: the edit left pending across the R relaunch (step 12) was
      pushed, not dropped.
    - `RB-C9` is listed, and Settings shows the business name ` n1` and your name
      ` r0`. R's step 8 edits came through the cloud, and no stale settings did.
    - `RB-J1` shows the time session that started at the step 8 widget tap: it came
      through the cloud.
    - `RB-C3` shows ` n2`, not ` e3`: the unsynced R edit stays in R's AsyncStorage (G6)
      and does not reach N2 (§5.6 residual 1). Record it for the owner's ruling.
    - `RB-C4`: record which value wins, ` n3` or ` e1` (§5.6 residual 2). Nothing else
      changed.
17. Run Check everything is saved. Expect "Ready" (N2 cannot see the step 13 edit).
18. Write down the manual steps and each transition's duration: upload to processed,
    install, first launch to data shown.

**P12-RB-5 (SC4)** runs after this sequence on a clean install:

1. In N2, sign out (Settings › Account › Sign out), then delete the app (§8.1). This is
   the rehearsal's first deletion, of up to four. It is safe because the round trip is
   already recorded.
2. Install L from the App Store. If L opens signed in, sign out first: another build's
   session survives the deletion (§8.1). Then sign in to a second team account.
3. Create two customers.
4. Upgrade to N2 from TestFlight.

The legacy migration must run and show both customers, so the migration code path still
works after the rollback (plan 12.06 step 5, SC4).

**Signed-out variant of T1 (E-1; recorded on P12-RB-2)** runs after P12-RB-5. It checks
that R detects a native build that was signed out, whose `store.json` is gone (§5.3
E-1):

- S1. Start with no TradeReady on the device (§8.1): a second iPhone (preferred), or on
  the same iPhone sign out of N2, which P12-RB-5 left signed in to the second team
  account, and then delete the app. Install L from the App Store. If L opens signed in,
  sign out first: another build's session survives the deletion (§8.1). Sign in as A
  and pull to refresh. Online, create customer `RB-C8` and let it sync. Offline, edit `RB-C8`
  (suffix ` s0`) and force-quit. The Expo queue now holds the stale edit.
- S2. Online, install N from TestFlight over L (Previous Builds), with no delete. Open it,
  let it migrate and sign in as A if asked. Check that `RB-C8` shows ` s0`. Edit
  `RB-C8` again (suffix ` s1`) and let it sync. Run Check everything is saved: expect
  "Ready".
- S3. Sign out of N (Settings › Account › Sign out) and confirm.
- S4. Online, install R from TestFlight over N, with no delete. Open R, and sign in as A,
  the same user, if asked: the Expo build's own session survives the native sign-out.
  Pull to refresh.
- S5. Check that `RB-C8` shows ` s1`, not ` s0`. E-1 found the native run marker at app
  start (the sign-out removed `store.json`, not the marker). It dropped the stale queue
  and cleared the stale copy before any push. Record whether R showed the E-2 warning.
  If `RB-C8` shows ` s0`, the stale queue was pushed: that is `P12-012`, and the cloud
  row now holds the stale value (a §10.4 query can confirm it). Record it as a failed
  step.

**P12-RB-7 (P12-011 on a device)** runs after the signed-out variant. It checks the case
that `P12-011` fixed: a native-only install, signed out, then the Expo window, then N2:

- D1. Start with no TradeReady on the device (§8.1). A second iPhone is preferred. This
  step assumes the signed-out variant ran on the same iPhone: sign out of R (signed in
  as A since S4), and then delete the app. After any other history, follow §8.1
  instead.
  Online, install N from TestFlight (Previous Builds). With no L before it, this is a
  native-only install. Open it: no migration notice. Sign in as A, pull to refresh, and
  let it sync.
- D2. Run Check everything is saved: expect "Ready". Export the support report:
  `persistence.migrationStatuses` shows no status for
  `react-native-async-storage-to-v1` (nothing was imported). Sign out (Settings ›
  Account › Sign out) and confirm.
- D3. **R starts signed out** (§5.3 E-1 runs before the sign-in). Online, install R
  from TestFlight over N, with no delete.
  - Open R. It starts signed out, because it has no session on this device. Record it
    if it does not. Record whether R shows the E-2 warning before the sign-in.
  - Sign in as A. As soon as R shows its lists, and before pulling to refresh, create
    customer `RB-C7`. Record whether A's records were already listed then. Expect yes:
    the first sign-in's pull had finished. A fresh R has no `__initDone_` key, so its
    first sign-in pulls before `initialSync` returns (`utils/sync.ts:372-398`), and
    until then R shows its loading spinner instead of its lists
    (`context/AuthContext.tsx:41-42`, `App.tsx:379-385`). `RB-C7` is therefore created
    after that pull, and the step checks that the next pull keeps it. Record a "no" as
    a finding.
  - Pull to refresh. A's records appear, and `RB-C7` is still listed.
  - Edit `RB-C5` (suffix ` e7`), and let the changes sync until no "changes pending"
    banner shows.
  - Force-quit R.
- D4. Install N2 from TestFlight over R, with no delete. Open it. Before signing in,
  check that it shows the signed-out start: no records, no migration notice, and no
  conflict or local-recovery screen. N2 did not take over R's session or records.
- D5. Sign in as A and pull to refresh. `RB-C7` and the ` e7` edit to `RB-C5` appear:
  the Expo-window edits came through the cloud. Then, without force-quitting N2, export
  the support report (after a relaunch it reads `not-attempted`, since N2 then has a
  saved snapshot):
  - `launchMigration` shows the outcome `native-state-adopted`, notice `none` and
    `blocked` false;
  - `persistence.migrationStatuses` still shows no status for
    `react-native-async-storage-to-v1`: no journal entry was written.

  Before the fix, this launch imported R's records, published R's session to the native
  Keychain and showed the migrated notice (charter §10, `P12-011`).
- D6. Run Check everything is saved. Expect "Ready".

**L→R check (E-1 on a device that never ran native; recorded on P12-RB-2; final review
I1, 2026-09-27)** runs after P12-RB-7. It checks that E-1 does nothing when the native
build never ran on the device: no marker and no native directory mean no native run
(§5.3 E-1 rule 4). So R keeps and pushes the queue L left, instead of clearing it.

- U1. Start with no TradeReady on the device (§8.1): a second iPhone that has never had
  the app (preferred), or on the same iPhone sign out of N2, which P12-RB-7 left signed
  in as A, and then delete the app. Install L from the App Store. If L opens signed in,
  sign out first. Sign in as A and pull to refresh. Offline, edit `RB-C7` (suffix
  ` u0`) and force-quit L. The Expo queue now holds that edit, and no native build has
  run on this install.
- U2. Online, install R from TestFlight over L, with no delete (N is never installed).
  Before opening R, turn airplane mode on. Open R offline. Expect no E-2 warning and no
  pending notice. A's records are listed as L left them, and `RB-C7` shows ` u0`.
  Force-quit and open R again offline: still no warning or notice.
- U3. Go online and pull to refresh. The "changes pending" banner clears, and `RB-C7`
  still shows ` u0`: the queue L left was pushed, not dropped. If R showed the warning
  or the notice, or `RB-C7` lost ` u0`, E-1 treated a missing marker as a native run.
  Record a failed step: R dropped the user's unsynced edit.

### 8.3 Evidence template

Copy this into the owner's private rehearsal record. In the repository, only its summary
goes on rows P12-RB-1 to P12-RB-7 (evidence index §23).

```
Rehearsal run  <RUN_ID>   date <DATE>   device <MODEL> / iOS <OS_VERSION>   account alias <TEAM_ACCOUNT_ALIAS>

Versions (L < N < R < N2)
| Build | Version | Build number | Source (App Store / TestFlight) | Processed at |
| L  | <L_VERSION>  | <L_BUILD>  | App Store  | —      |
| N  | <N_VERSION>  | <N_BUILD>  | TestFlight | <TIME> |
| R  | <R_VERSION>  | <R_BUILD>  | TestFlight | <TIME> |
| N2 | <N2_VERSION> | <N2_BUILD> | TestFlight | <TIME> |

Steps
| Step | Time | Expected (§8.2) | Observed | Pass/Fail | Sign-in asked? | Support report (codes only) |
| 1  | | | | | | |
| …  | | | | | | |
| 18 | | | | | | |
| S1 … S5, D1 … D6, U1 … U3 | | | | | | |

Readiness check (steps 5, 6, 17; S2; D2, D6): lastCheck / drainOutcome / blockers / notes / counts
Transition timings: T0 <MIN>, T1 <MIN>, T2 <MIN>; manual steps: <LIST>
N2 launchMigration (step 15): <outcome>; migrationStatuses react-native-async-storage-to-v1: <status>
R offline first action (step 8): pending notice <yes/no>; pre-upgrade records listed before the pull <none | some>; sample data <none | shown>; sign-in asked offline <yes/no>;
  invoice refused before the pull <yes/no | not exercised>;
  after the pull RB-C9 <listed | missing>, your name <r0 | other>, business name <n1 | other>; in N2 (step 16) <same | other>
Widget tap before R's first open (steps 8, 9, 16): RB-J1 before the pull <not listed | listed>; after the pull <timer from the tap | no timer | other>; in N2 <same session | other>
R relaunch (step 12): banner after relaunch <1 pending | cleared>; E-2 warning again <yes/no>; RB-C2 in N2 <e4 | other>
RB-C3 in N2 (residual 1): <n2 | e3>
RB-C4 winner (residual 2): <n3 | e1>
Signed-out variant: RB-C8 in R <s1 | s0>; E-2 warning <yes/no>
L→R check (U1–U3): E-2 warning <no | yes>; pending notice <no | yes>; RB-C7 offline in R <u0 | other>; after the pull <u0 | other>
P12-RB-7: R at D3 started signed out <yes/no>; E-2 before sign-in <yes/no>; A's records listed when RB-C7 was created <yes (expected) | no>;
  N2 before sign-in <signed-out start | other: describe>; launchMigration <outcome>;
  RB-C7 and RB-C5 e7 after sign-in <present | missing>
Defects raised: <P12-… or none>
SC4 (P12-RB-5): migration ran <yes/no>, records shown <COUNT>
```

**Rules:**

- A failed step becomes a defect row (charter §2 rule 4). It is never waived silently.
- Record synthetic labels and suffixes only. Never record an email, token, key or device
  identifier (evidence index §2 rule 2).

### 8.4 Staffing (plan 12.06 step 6, E3)

> **OWNER-GATED.**

Under D5 the owner is support and on-call for the cutover window, with no second person
(charter §1). Staffing is confirmed by a decision-log row that names:

- the watch days for each exposure step: the Stage B invite waves, the Stage C release
  and the 7 phased-release days (charter §1 rules 1–3);
- the planned pauses;
- that this playbook and the processed R are at hand (charter §4.6).

Record the row on P12-RB-6.

## 9. Evidence index rows

These rows are appended to `docs/native-phase-12-evidence-index.md` §23:

| Row | Stage | What it covers |
|---|---|---|
| P12-RB-1 | X | The rollback candidate R uploaded and processed, not submitted, with its numbering recorded |
| P12-RB-2 | A | Rehearsal T0 and T1: Expo L → native N → Expo R, with unsynced edits, the readiness check, a widget tap waiting for R's pull, and R's first action offline with the invoice block; and the signed-out variant (E-1) |
| P12-RB-3 | A | Rehearsal T2: Expo R → native N2, with a synced Expo edit, one left pending across an R relaunch, an unsynced one, the widget tap's session, no re-import and the residuals recorded |
| P12-RB-4 | A | The readiness check's states, its accessibility and the v4 support report on a device |
| P12-RB-5 | A | SC4: the legacy migration still runs in N2 after the round trip |
| P12-RB-6 | X | Staffing for the cutover window |
| P12-RB-7 | A | P12-011 on a device: a native-only install signed out, the Expo window starting signed out, then N2 adopts native and cloud state |

## 10. Commands (all owner-gated, placeholders only)

> **OWNER-GATED.** The whole section. The commands are exact, but every credential, ID,
> version and URL is a placeholder. Run them from the owner's machine with the owner's
> accounts. Never paste a secret onto a command line that shell history keeps: read it
> from the owner's secret store into an environment variable.

### 10.1 Native build N or N2: archive and upload to TestFlight

```sh
# From the repository root, on the native release commit. SIGN-1 must be cleared.
xcodebuild -project native/TradeReadyNative.xcodeproj -scheme TradeReadyNative \
  -configuration Release -destination 'generic/platform=iOS' \
  -archivePath "<ARCHIVE_DIR>/TradeReadyNative-<NATIVE_VERSION>-<NATIVE_BUILD>.xcarchive" \
  MARKETING_VERSION=<NATIVE_VERSION> CURRENT_PROJECT_VERSION=<NATIVE_BUILD> \
  DEVELOPMENT_TEAM=<TEAM_ID> -allowProvisioningUpdates archive

# Check the numbers the archive carries (app and widget extension).
/usr/libexec/PlistBuddy -c 'Print :ApplicationProperties:CFBundleShortVersionString' \
  "<ARCHIVE_DIR>/TradeReadyNative-<NATIVE_VERSION>-<NATIVE_BUILD>.xcarchive/Info.plist"
/usr/libexec/PlistBuddy -c 'Print :ApplicationProperties:CFBundleVersion' \
  "<ARCHIVE_DIR>/TradeReadyNative-<NATIVE_VERSION>-<NATIVE_BUILD>.xcarchive/Info.plist"

# Upload. <EXPORT_OPTIONS_PLIST> lives outside the repository and sets
# method=app-store-connect, destination=upload, teamID=<TEAM_ID>.
xcodebuild -exportArchive \
  -archivePath "<ARCHIVE_DIR>/TradeReadyNative-<NATIVE_VERSION>-<NATIVE_BUILD>.xcarchive" \
  -exportPath "<EXPORT_DIR>" -exportOptionsPlist "<EXPORT_OPTIONS_PLIST>" \
  -allowProvisioningUpdates \
  -authenticationKeyPath "<ASC_KEY_P8_PATH>" -authenticationKeyID <ASC_KEY_ID> \
  -authenticationKeyIssuerID <ASC_ISSUER_ID>
```

The upload goes to TestFlight only. Submitting a version for review is a separate App
Store Connect action (§6 step 4).

### 10.2 Expo rollback candidate R: build and upload, do not submit

```sh
# In a separate clone or worktree, on the Expo release branch (§4).
git switch <EXPO_RELEASE_BRANCH>
# Set expo.version in app.json to <R_VERSION> and commit it on the release branch.

export EXPO_TOKEN="$(<SECRET_STORE_READ_COMMAND> <EXPO_TOKEN_NAME>)"
npx eas-cli@<EAS_CLI_VERSION> build:version:get --platform ios
# Set the remote build number above the last native build (§3.2); the command prompts.
npx eas-cli@<EAS_CLI_VERSION> build:version:set --platform ios
npx eas-cli@<EAS_CLI_VERSION> build --platform ios --profile production --non-interactive

# Upload the finished build to App Store Connect (TestFlight). This does NOT submit
# it for review. The ASC API key is the owner's; its path and IDs are placeholders.
npx eas-cli@<EAS_CLI_VERSION> submit --platform ios --profile production --id <EAS_BUILD_ID> \
  --non-interactive
```

Then, in App Store Connect › TestFlight, wait until R is processed, and record its version
and build (P12-RB-1). Do not add it to a version for review until §6 step 4.

### 10.3 Worker: confirm or roll back to the last mixed-client-compatible deployment

```sh
cd backend-workers
export CLOUDFLARE_API_TOKEN="$(<SECRET_STORE_READ_COMMAND> <CF_TOKEN_NAME>)"
export CLOUDFLARE_ACCOUNT_ID=<CF_ACCOUNT_ID>
npx wrangler deployments status          # what serves traffic now
npx wrangler deployments list            # recent deployments, newest last
npx wrangler versions list               # version IDs
# Only if a deploy happened after the last mixed-client check:
npx wrangler rollback <WORKER_VERSION_ID> --message "<ROLLBACK_REASON>"
npx wrangler deployments status          # confirm
```

### 10.4 Supabase: read-only reconciliation queries (§6 step 6)

Run these in the owner's SQL editor on the project that served the release, with a
read-only role where one exists. Record counts only.

```sql
-- Rows the account wrote in the native window, per table. <TABLE> is each of the ten
-- collection tables in utils/sync.ts:77, then settings and customer_notes.
select count(*) from public."<TABLE>"
 where user_id = '<OWNER_USER_ID>'
   and updated_at >= '<NATIVE_RELEASE_AT>' and updated_at < '<ROLLBACK_AT>';

-- The account's live rows per table, to compare with persistence.recordCounts in the
-- user's latest support report.
select count(*) from public."<TABLE>"
 where user_id = '<OWNER_USER_ID>' and deleted = false;

-- Native-only local markers must never reach the server (L286.1). Expected: 0.
select count(*) from public."<TABLE>"
 where user_id = '<OWNER_USER_ID>' and data ? '__native';
```

The `deleted` filter and the `?` query apply to the ten collection tables, whose `data`
column is `jsonb` and which have a `deleted` column
(`supabase/migrations/20260803_local_collections_sync.sql` shows the shape). The
`settings` and `customer_notes` definitions are not in this repository: count their rows
by `user_id` only, and record "n/a" for the other two queries.
