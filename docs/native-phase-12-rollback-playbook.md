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

**Open:**

| Open item | Who clears it | Where |
|---|---|---|
| The rehearsal (plan 12.06 step 5) | owner | §8 and evidence index rows P12-RB-2 to P12-RB-5 and P12-RB-7 |
| Staffing (step 6) | owner | §8.4 and row P12-RB-6 |
| The Expo-side rule (1) of the rollback data decision: E-1 detects at app start, clears (recommended) or holds, and pulls; E-2 to E-4 (R48) | the owner decides who builds it on the Expo release branch. The branch owner records E-1's keys, the clear-or-hold choice, the marker path under `expo-file-system` and the owner's acceptance of residual 5 | §5.3; §5.6 item 5 |
| Defect `P12-012` (S1): the Expo build pushes its stale pre-upgrade queue before it pulls | owner: a ruling on Stage A entry (R43), then the §5.3 build | charter §10; §5.3 |
| Defect `P12-013`: unfinished booking and portal link work has no automatic recovery | filed by the controller; Task 12b wires the recovery and adds the charter row | §5.1 |
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

**What it does** (`AppStore.prepareRollbackReadiness`, `N/AppStore.swift:8133`):

1. It reads the device's local state (`AppStore.rollbackReadiness`, `N/AppStore.swift:8033`).
2. If none of the fail-closed conditions below holds, it applies any widget or Siri
   actions waiting in the App Group.
3. It runs one full manual sync (push, then pull).
4. It uploads waiting job photos, then syncs again if a photo uploaded.
5. It checks the device again.

The check never discards, settles or clears anything. The only thing it writes is what
an ordinary sync writes.

**What it shows.** Either "Ready: everything on this device is saved to the cloud." or
"Not ready yet: …" followed by each reason
(`NativeRollbackReadinessCopy`, `N/NativeSupportDiagnostics.swift:411`). A neutral note
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
- A reschedule proof guards a server resolve call. Its job change is in the ordinary
  queue, which `pending-changes` counts.

The check counts this account's items only and never removes one. An item leaves when
the flow that staged it succeeds on a later try, or at the account's sign-out scrub. A
failed or unknown resolve keeps its proof (`N/AppStore.swift:9788-9793` removes it only
after success), and nothing retries staged items at launch, activation or sync
(`AppStore.recoverScheduleBookingPendingWork`, `N/AppStore.swift:10218`, has no caller).
A stuck item can therefore stay. That is defect `P12-013`, filed by the controller; Task
12b wires the recovery and adds its charter row.

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
  R48).
  - **When R looks: at app start, on every launch.** The check runs as soon as R's
    JavaScript starts, before anything reads or writes a collection:
    - before the first screen renders;
    - before `initialSync` (`context/AuthContext.tsx:42`);
    - before the launch migrations and the push-token save (`App.tsx:390-403`);
    - before the background refresh task syncs (`utils/backgroundRefresh.ts:100`).

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
      (`N/AppStore.swift:804`), including a signed-out or blocked launch.
    - A missing or unreadable marker restarts at a random run in 1…2,147,483,647, not
      at a fixed value (review fix round 3). The chance that a restart repeats the run
      R recorded is about one in two billion.
    - No account boundary removes it. The sign-out's `.live` scrub deletes `store.json`
      and its backup (`N/Domain/SnapshotRepository.swift:252-253`) but not this file. A
      deletion (`.all`) keeps it too.
    - Deleting the app removes it, together with R's AsyncStorage.
    - It holds no account data.

    R reads it with `expo-file-system`, which the Expo build already has. That module
    has no Application Support constant, so the branch owner must build the path and
    confirm on a device that the module can read it. Without that read, E-1 has no
    signal and the §5.3 build is not done. Host test:
    `native/run-rollback-readiness-tests.sh`, section M.
  - **R's record.** R keeps one small AsyncStorage key, for example `__nativeRun` (the
    branch owner names it), holding `{"run":<n>,"state":"pending"|"seen"}`. The record
    is device state, so the Expo sign-out (E-4) keeps it.
  - **A new native run** is a marker whose `run` differs from the record's.
    - **No record yet.** The native directory `Application Support/TradeReadyNative/`,
      or any file in it, also counts, even with no marker. The directory is permanent
      (every native launch creates it, `N/AppStore.swift:567-569`), so it cannot tell
      one run from the next. When it fires with no marker (a native build that never
      reached `N/AppStore.swift:804`, or whose marker writes all failed), R records the
      sentinel run `0`. No marker can hold 0 (`run` is at least 1,
      `N/NativeRunMarker.swift:44`), so the fallback fires once, and any later marker
      still counts as new.
    - `store.json` alone is never a signal. A signed-out native device has none, yet its
      stale queue survives (item 2).
  - **On a new native run, one write.** Before anything else runs, R makes one
    `AsyncStorage.multiSet` that:
    - sets `__syncQueue` to empty, because every entry in it predates the detection;
    - sets `__lastSyncedAt` to the empty cursor, so the next pull is a full pull;
    - sets every pulled collection (`COLLECTION_TABLES`, `utils/sync.ts:77`) to an
      empty list and `customerNotes` to an empty map, the keys the other-owner path
      clears (`utils/sync.ts:394`);
    - sets E-1's held settings keys (below) to empty, since a later native run drops R's
      earlier edits along with its queue;
    - records the run as pending.

    The collections are written empty, not removed. A missing collection makes the
    loaders show sample data (`utils/storage/collections.ts:17-24`).

    Every value in the write is under 1,024 characters. AsyncStorage 2.2.0 keeps such
    values in its manifest and writes the manifest once, atomically (iOS
    `RNCAsyncStorage.mm`, `_writeEntry` and `_writeManifest`). A larger value would go
    to its own file first, so the write must stay small. If R stops before the write
    lands, the record still holds the old run. The next launch then detects again and
    repeats the write before anything renders.
  - **While the run is pending** (on every launch, until the pull lands):
    - **R lists no pre-native record**, so none can be shown, edited or queued. It says
      it is getting the latest data (the owner approves the wording), so empty lists are
      not taken for lost data.
    - **A record the user creates is queued and pushed as usual.** It is new, not a
      stale copy.
    - **Settings are held.** Settings are one record, and they cannot be cleared: with no
      settings key, R falls back to the defaults (`utils/storage/settings.ts:63`). The
      push-token save can change them at any launch (`utils/pushToken.ts:26`). While the
      run is pending, `enqueue` (`utils/sync.ts:99-106`) does not queue `settings`
      (`utils/storage/settings.ts:79`). R keeps the changed keys in its own key instead,
      for example `__nativeRunHeldSettings`.
    - **A relaunch** finds the record pending and the marker unchanged. It detects
      nothing, clears nothing and drops nothing more. It keeps the settings hold and the
      pending notice.
  - **The pull completes the run.** Only the pull waits for the first online, signed-in
    sync. The run completes when a pull reads every table, the settings and the customer
    notes without an error, whichever path runs it:
    - `syncIfOnline` (`utils/sync.ts:316-321`);
    - `initialSync`'s first sign-in (`utils/sync.ts:397-398`);
    - the other-owner path (`utils/sync.ts:394-398`).

    Today `pullRemote` swallows a table's failure (`utils/sync.ts:283`) and any other
    error (`utils/sync.ts:310-312`), so the branch must make it report success. On
    success, in this order:
    1. apply the held settings keys over the pulled settings, save them and queue that
       settings record;
    2. then record the run as seen and remove the held keys.

    The order makes a crash harmless. Until the run is seen, the held keys stay, so the
    next full pull applies them again. Queuing settings again replaces the earlier entry
    (`utils/sync.ts:100-104`). Held keys found while the run is already seen are
    removed, never applied.

    Held keys that belong to another account are discarded, never applied: the
    other-owner path and the Expo sign-out (E-4) remove them.
  - **Invariants.**
    - **R never drops an edit it made after a detection.** Only a later native run
      drops it (below).
    - **The pull never silently reverts an edit R made.** Nothing R shows before the pull
      is a pre-native copy. A record R created survives the pull, because the pull
      replaces by id and keeps local-only records (`utils/sync.ts:262-272`). Held
      settings keys are applied after the pull.
    - **R never pushes a stale copy.** The queue is emptied at the detection. No
      pre-native copy is left to be queued, although every save queues the whole
      collection (`utils/sync.ts:121-123`). Settings are queued only after the pull.
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

    **The cost** (residual 5, §5.6 item 5): until the pull, R lists no records, whether
    offline or before sign-in, and a record created then can duplicate one in the
    cloud. Settings are the only hold, and it is limited to the changed keys.
  - **No new native run: E-1 does nothing.**
    - A detection never drops a queue entry that R creates after it.
    - A relaunch of R with its own pending queue and no native run since drops
      nothing, and the sync pushes that queue (§8.2 step 12).
  - **After N2, then R again** (a later native run), E-1 at app start drops the stranded
    pre-N2 R queue and clears the pre-N2 copies. It never pushes them, because those
    entries predate N2's rows and a push would overwrite them: the `P12-012` class. This
    is residual 1 (§5.6 item 1).
  - **The branch owner records** the record key, the clear or hold choice, the marker
    path and the pending-state wording. The rehearsal checks:
    - R's first action offline (§8.2 step 8);
    - the relaunch case (§8.2 step 12);
    - the signed-out native case (§8.2 steps S1–S5);
    - R starting signed out (§8.2 step D3).
- **E-2.** Show an unsynced-changes warning when the Expo build cannot confirm that the
  native build's changes were drained. For example: "Changes made in the newer version
  that hadn't finished uploading may be missing. Open the newer version again to upload
  them, or contact support."

  An Expo build cannot read the native queue reliably. Warn on each E-1 detection, at
  app start and once per native run, unless the owner accepts a narrower signal. A
  relaunch with no native run since does not warn again. The warning is separate from
  E-1's pending notice, which stays until the pull lands.
- **E-3.** Never modify or delete the native store, its journal, `LegacyBackups/`, the
  native run marker or the native Keychain items. They make the re-upgrade safe (§5.2)
  and let E-1 work, and a deletion would contradict Phase 0 step 4.
- **E-4.** Keep the existing sign-out rule: the Expo sign-out clears the queue and the
  owner marker (`utils/storage/lifecycle.ts:106-159`). It also clears E-1's held
  settings keys, which are account data. It keeps E-1's run record, which is device
  state, and a pending run stays pending until the next account's full pull.

**Who makes the change.** The owner, as the holder of every role (D5), or an agent the
owner assigns to the Expo release branch outside Phase 12's lanes. Until it is built:

- the rehearsal (§8) cannot pass for a device upgraded from the Expo build;
- §2.2 condition 4 is not met;
- defect `P12-012` stays open (charter §10).

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
   same-record overwrite of item 2.

   The check guards this: it reads `initial-sync-incomplete`, and support does not
   advise the rollback (§5.1). Only a device that skipped the check reaches this case.
5. **Until R's first full pull after a native run, R lists no records** (the cost of
   E-1's clear, §5.3). This holds offline or before sign-in. R shows its pending notice
   instead.

   A record created in that window is kept and pushed, but it can duplicate a record
   that is already in the cloud. A settings change made in that window is applied after
   the pull.

   This is not data loss. It needs the owner's acceptance with the §5.3 build. If the
   owner rules for the hold instead, this residual is replaced by the hold's replay rule
   (§5.3 E-1).

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
| The note "Also: … booking or portal link updates …" (under either result) | Act on the result line only. The work it names holds no changes that need uploading (§5.1). If the user says a booking link, portal link or reschedule looks unfinished, ask them to make that change again; nothing retries it by itself yet (defect `P12-013`) |
| "sign in to your account", "the first sync hasn't finished", "saving is paused on this device", "an account change is still finishing", "moving data from the previous app hasn't finished", "… can't be read" or "… can't be checked" | Do not advise the update. Ask for the support report and escalate as S1 or S2 (charter §2) |
| "the account changed during the check, so run it again" | Ask the user to run it again while signed in to their own account |

**Support report:** Settings › Import Data › Migration support › **Prepare support report**, then
**Share support report**, attached to the reply. The report's `rollbackReadiness` section
shows the last check. Read its blocker codes and counts (§5.1).

**Part B — after the rollback update (the Expo build R installed)**

> Version `<ROLLBACK_VERSION>` is installed. Connect to Wi-Fi or mobile data, open it
> and sign in if it asks. Your data comes from the cloud, so it can take a minute to
> appear. Until it has, the app shows no records. If something you entered recently is
> missing after that, don't re-enter it yet and don't delete the app. Reply to this
> message and tell us what's missing, and we'll check.

If the user says R shows no records, it has not finished its first pull after the
native build (§5.3 E-1, §5.6 item 5). Ask them to connect and sign in. A record they
created in the meantime is kept. If it duplicates one that appears after the pull, they
can remove the extra one.

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
| P12-RB-2 | Native → Expo, and its signed-out variant (E-1) |
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
- one team account A with synthetic data, whose records are labelled `RB-C1` … `RB-C9`.

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
   change the business name (suffix ` n1`). Let them sync.
5. Offline, edit `RB-C3` (suffix ` n2`). Open Settings › Cloud Sync and tap Check
   everything is saved. Expect "Not ready yet: 1 change waiting to upload". Export the
   support report.
6. Online, tap the check again. Expect "Ready". Export the support report.
7. Offline, edit `RB-C4` (suffix ` n3`) and force-quit **without** running the check.
   This is the ignored-guard case of §5.6 residual 2.
8. Online, and without opening N, install R from TestFlight. Do not open it yet: turn
   airplane mode on first. This is **R's first action offline** (§5.3 E-1 at app start).
   - Open R offline. Expect the E-2 warning and R's pending notice. No customers or jobs
     are listed, and no sample data shows: E-1 cleared the pre-native copies before the
     first screen.
   - Create customer `RB-C9`. In Settings, change your name (suffix ` r0`).
   - Force-quit R and open it again, still offline. `RB-C9` and ` r0` are still there,
     and nothing from before the upgrade is listed.
   - Go online. Sign in if asked. Pull to refresh.

   If R opens offline asking for a sign-in, it cannot sign in there. Record that this
   case was not exercised (§8.2 step D3 covers a signed-out start). Then go online, sign
   in as A, make the same two edits and pull to refresh.

**Expo window, then T2: Expo R → native N2**

9. In R, after the pull, check the records:
   - `RB-C1` shows ` n1`, not ` t0` (§5.3 E-1: the stale queue did not overwrite it).
   - `RB-C2` shows ` n1` and `RB-C3` shows ` n2` (both drained).
   - `RB-C4` does **not** show ` n3` (never uploaded). R showed the §5.3 E-2 warning at
     step 8.
   - `RB-C9` is still listed, and your name shows ` r0`: the pull reverted neither.
   - The business name shows ` n1`: R pushed no stale settings.
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
    - `RB-C3` shows ` n2`, not ` e3`: the unsynced R edit stays in R's AsyncStorage (G6)
      and does not reach N2 (§5.6 residual 1). Record it for the owner's ruling.
    - `RB-C4`: record which value wins, ` n3` or ` e1` (§5.6 residual 2). Nothing else
      changed.
17. Run Check everything is saved. Expect "Ready" (N2 cannot see the step 13 edit).
18. Write down the manual steps and each transition's duration: upload to processed,
    install, first launch to data shown.

**P12-RB-5 (SC4)** runs after this sequence on a clean install:

1. In N2, sign out (Settings › Account › Sign out), then delete the app (§8.1). This is
   the rehearsal's first deletion, of up to three. It is safe because the round trip is
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

**P12-RB-7 (P12-011 on a device)** runs last. It checks the case that `P12-011` fixed: a
native-only install, signed out, then the Expo window, then N2:

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
    customer `RB-C7`. Record whether A's records were already listed then, which means
    the first sign-in's pull had finished.
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
| S1 … S5, D1 … D6 | | | | | | |

Readiness check (steps 5, 6, 17; S2; D2, D6): lastCheck / drainOutcome / blockers / notes / counts
Transition timings: T0 <MIN>, T1 <MIN>, T2 <MIN>; manual steps: <LIST>
N2 launchMigration (step 15): <outcome>; migrationStatuses react-native-async-storage-to-v1: <status>
R offline first action (step 8): pending notice <yes/no>; pre-upgrade records listed before the pull <none | some>; sample data <none | shown>; sign-in asked offline <yes/no>;
  after the pull RB-C9 <listed | missing>, your name <r0 | other>, business name <n1 | other>; in N2 (step 16) <same | other>
R relaunch (step 12): banner after relaunch <1 pending | cleared>; E-2 warning again <yes/no>; RB-C2 in N2 <e4 | other>
RB-C3 in N2 (residual 1): <n2 | e3>
RB-C4 winner (residual 2): <n3 | e1>
Signed-out variant: RB-C8 in R <s1 | s0>; E-2 warning <yes/no>
P12-RB-7: R at D3 started signed out <yes/no>; E-2 before sign-in <yes/no>; A's records listed when RB-C7 was created <yes/no>;
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
| P12-RB-2 | A | Rehearsal T0 and T1: Expo L → native N → Expo R, with unsynced edits, the readiness check and R's first action offline; and the signed-out variant (E-1) |
| P12-RB-3 | A | Rehearsal T2: Expo R → native N2, with a synced Expo edit, one left pending across an R relaunch, an unsynced one, no re-import and the residuals recorded |
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
