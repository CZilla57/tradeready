# Phase 12 — Cutover and Rollback Plan

**Date:** 2026-09-21

**Status:** Ready for charter/characterization; no stage executed, no evidence collected.
Revised 2026-09-22 per [native-phase-10-12-plan-review.md](native-phase-10-12-plan-review.md).

**Revised 2026-09-25 (Phase 11 reconciliation; owner decisions D1–D5 answered the
same day, §1.3).** Phase 11 finished after this plan was written (code-complete at `6d573a7`
on branch native/phase-11; this phase works on branch native/phase-12). This revision:

- moves the delivered Phase 11 monitoring, widget, App Intents, privacy-manifest and
  dSYM files into "What already exists" (each path verified at `6d573a7`);
- gives every Phase 11 carry an owning 12.xx task (§1.1);
- records the conflict between "evidence and operations" and the code-level cutover
  blockers, with two ways to resolve it for the owner to choose (§1.2), and adds the
  proposed pre-Stage-A build lane 12.00b (§3);
- routes each parked Phase 11 minor finding to exactly one place: the 12.00 defect
  list or the 12.03 evidence index (§7);
- adds two release blockers found while reconciling: the native version number is
  below the live Expo version (VER-1), and the signed build cannot be provisioned yet
  (SIGN-1).

It changes no requirement ID, and no stage gate is relaxed.

**Context:** the app has no current production users. The upgrade path from the
App Store Expo build is still exercised (SA2) because the roadmap requires it,
but no requirement exists only to preserve existing users' device state.

**Roadmap goal (Phase 12):** Replace the production binary without risking customer operations.

**Scope source:** [native-ios-migration-roadmap.md](native-ios-migration-roadmap.md)
Phase 12 (Stages A–C and Exit criteria), the
[2026-09-16 verification-deferral decision](native-ios-migration-roadmap.md), and
the device/staging evidence rows deferred by
[native-parity-matrix.md](native-parity-matrix.md). This plan also consumes the
device runsheets produced by Phases 2–11. As of 2026-09-22 these exist:
`native-device-test-runsheet.md`, `native-phase-3-device-matrix.md`,
`native-phase-4-device-runsheet.md`, `native-phase-4-background-refresh.md`,
`native-phase-4-job-photo-transfer.md`, `native-phase-4-mixed-client-convergence.md`,
`native-phase-7-device-runsheet.md`, `native-phase-9-device-runsheet.md`,
[native-phase-10-device-runsheet.md](native-phase-10-device-runsheet.md) (created
by 10.15), and
[native-phase-11-device-runsheet.md](native-phase-11-device-runsheet.md) (created
by 11.14; its per-row format — ID, requirement, steps, expected result,
environment/build, evidence — is the target shape for the 12.03 index). The Phase 11
gaps and known issues are in
[native-phase-11-platform-hardening-contract-decisions.md](native-phase-11-platform-hardening-contract-decisions.md)
§17.2 and the runsheet's "Owned items and open gates" table. **No Phase 5, 6, or 8 runsheet exists**, and the
consolidated runsheet has no sections for them; their deferred rows are scattered
through the roadmap text and are recovered by 12.03. The rollback procedure
extends [native-phase-0-baseline.md § Rollback procedure](native-phase-0-baseline.md).

## 1. Execution contract and authority

Phase 12 is **evidence and operations**, not feature implementation. Unlike
Phases 0–11, it cannot be executed by a subagent on its own authority: every stage
requires owner-held accounts, credentials, devices, and external state. A
subagent may prepare scripts, dashboards, playbooks, and documentation, but must
**not** submit to App Store Connect, deploy a backend, run a live migration,
touch production accounts/data, or change store metadata without an explicit,
in-scope instruction for that exact action.

Non-negotiable boundaries carried from the roadmap and prior phases:

- Production is never substituted for missing isolated staging. Do not change
  `https://staging.invalid` or any production-matched Supabase origin/key to make a
  preflight pass.
- Host checks, generic Release builds, and type-checks never substitute for
  physical-device, TestFlight, or store evidence.
- Legacy migration code and backend compatibility are **retained** for the first
  stable native release series; nothing in this phase deletes them.
- A real customer's data never enters Stage A; Stage A is team accounts and
  synthetic data only.

Every task must state its owner, entry/exit gates, evidence artifacts, and the
exact authority it needs. A gate that cannot be satisfied stays blocked and is
reported — never waived or approximated.

### Requirement IDs

- **SA1** Stage A uses only team accounts and synthetic data.
- **SA2** Upgrade migration from the current App Store Expo build is exercised.
- **SA3** Full regression suite and backend load checks run.
- **SB1** Limited external-beta cohort covers new, established, offline-heavy,
  Stripe, booking, recurring-work, and iPad users.
- **SB2** Monitored: migration failures, sync errors, crashes, payment
  reconciliation, support contacts.
- **SB3** The latest Expo binary is ready for immediate rollback throughout.
- **SC1** Non-critical Expo feature development is frozen.
- **SC2** Pre-cutover verification: database backups, backend compatibility,
  App Store metadata, entitlements, privacy manifests, legal disclosures.
- **SC3** Gradual release via phased App Store rollout.
- **SC4** Legacy migration code and backend compatibility retained.
- **E1** No unresolved severity-1 or severity-2 defects.
- **E2** Migration, sync, payment, and crash metrics meet agreed thresholds.
- **E3** Support and rollback playbooks are staffed and verified.

### Shared-file and artifact ownership

- **Charter/ops lane:** 12.00, 12.02, 12.06 own the charter, monitoring protocol,
  and rollback playbook documents. Only one writer per document; these are the
  gates every other task references.
- **Configuration lane:** 12.01 is the only task editing release build
  configuration, entitlements, privacy manifest, and store metadata sources. It
  runs before 12.04/12.05/12.07.
- **Evidence lane:** 12.03 aggregates the per-phase runsheets; 12.04/12.05/12.07
  append stage evidence. No task rewrites another phase's runsheet except to link
  it.
- The coordinating agent owns the roadmap/parity-matrix updates; stage owners
  provide evidence, not status edits.

### What already exists (do not rebuild)

- `N/BuildEnvironment.swift` + `BuildEnvironment` write/read guards and the
  privacy-safe preflight patterns from Phases 3–4
  (`native/run-phase-3-device-preflight.sh`,
  `native/run-phase-4-device-preflight.sh`).
- The migration stack: `N/NativeTypedAccountState.swift`,
  `N/LegacyMigrationCoordinator.swift`, `N/LegacyDataImporter.swift`,
  `N/NativeAuxiliaryStateActivation.swift` (and their runners).
- The Phase 0 rollback procedure and mixed-client compatibility rules
  (`native-phase-0-baseline.md`) and the Phase 4 mixed-client convergence doc.
- The sync/background stack: `N/NativeInitialSync.swift`,
  `N/NativeSyncCoordinator.swift`, `N/NativeSyncCursor.swift`,
  `N/NativeBackgroundRefresh.swift`.

Delivered by Phase 11 (moved here from "to be delivered" by the 2026-09-25 revision;
each path verified to exist at `6d573a7`):

- Analytics: `N/NativeAnalytics.swift` (the seam and 52-event catalog),
  `N/NativeAnalyticsPostHog.swift` (the PostHog transport, app target only) and
  `N/NativeAnalyticsConfiguration.swift` (keys supplied at build time; none in
  source). 11.07, 11.08.
- Crash reporting and redaction: `N/NativeCrashReporting.swift`,
  `N/NativeCrashReportingSentry.swift` (the Sentry adapter) and
  `N/NativeErrorRedaction.swift` (the contract §10.1 denylist, which 12.02 reuses).
  11.09.
- Performance: `N/NativePerformanceMetrics.swift` (eight signpost intervals; the
  measurement definitions are in
  [native-phase-11-performance.md](native-phase-11-performance.md)). 11.12.
- Widget extension: `native/TradeReadyWidgets/` (extension-only sources, its
  `Info.plist`, entitlements and privacy manifest) and `N/Widgets/Shared/` (compiled
  into both targets). 11.01–11.03.
- App Intents and Siri: `N/NativeAppIntents.swift` and `N/Intents/`. 11.04.
- Privacy manifests: `N/PrivacyInfo.xcprivacy` (app, 11.09) and
  `native/TradeReadyWidgets/PrivacyInfo.xcprivacy` (extension, 11.01).
- dSYM upload: `native/scripts/upload-sentry-dsyms.sh` (a no-op without
  `SENTRY_AUTH_TOKEN`; deliberately not a build phase, per the 11.09 ruling). 11.09.
- Support export: Settings › "Prepare support report"
  (`AppStore.createPersistenceSupportReport`, Phase 2) is a metadata-only
  persistence and migration report. `N/NativeSupportDiagnostics.swift` does **not**
  exist; 12.02 builds it by extending or wrapping that report, not as a second,
  parallel exporter.

### 1.1 Phase 11 carry-in (owned items)

Every open gate from the Phase 11 runsheet's "Owned items and open gates" table and
contract §17.2, plus two blockers found on 2026-09-25, has one owning task here. G3
(device behaviour) is the device-row set that 12.03 indexes. OI-4 was closed by the
Phase 11 final review, except item 2, which is I2 below. G4 and G5 were fixed in
Phase 11.

| ID | Item | Owning task | Blocks | Source |
|---|---|---|---|---|
| G1 | **No native remote push.** `booking_request_opened` and `booking_update_opened` are never emitted, and booking push alerts do not exist natively. Booking alerts still arrive by email: `backend-workers/lib/booking/notifyOwner.js` sends email always and push only when the settings blob carries an Expo push token. RN reference: `utils/pushToken.ts` (Expo push token → `settings.pushToken`, saved only on change, never prompts) and the push-tap listener in `App.tsx` (`booking_request` → Jobs list; `booking_update` → the job, or the Jobs list) | 12.00 records the build-or-waive decision (D1). If built: 12.00b.4, with the push entitlement and provisioning via 12.01 | Cutover | contract §17.2 G1; roadmap "Cutover-blocking parity gaps" |
| G2 | **No native tax-settings screen.** `N/Domain/NativeTaxSettings.swift` and `AppStore.commitTaxSettings` exist, but no view calls them, so the income-tax rate and vehicle method cannot be set and `tax_settings_saved` is unreachable. RN reference: `components/money/TaxSettingsModal.tsx` | 12.00 records the decision (D2). If built: 12.00b.3 | Cutover | contract §17.2 G2; parity matrix "Tax set-aside" |
| I2 | **Sync-push wedge on a non-auth 4xx.** `NativeSupabasePush` treats 400/404/409/413/422, and a 403 that repeats after refresh, as transient and keeps the mutation forever. `NativeSyncCoordinator`'s `guard queue.load().isEmpty` then skips every pull, so one poison mutation stops all inbound sync. RN also retains failed items (`utils/sync.ts` `pushQueue`) but always pulls after pushing (`syncIfOnline`: `pushQueue` then `pullRemote`), so RN never wedges inbound sync | 12.00b.1 (the rejected-change UX is D3) | Cutover. The roadmap says "It must be fixed before cutover", with no waiver path | contract §17.2 known issue 2; runsheet I2 |
| G6 | **RN AsyncStorage source files on an upgraded device** may hold an RN-era plaintext Square token. Native's own `LegacyBackups/` copies are protected and backup-excluded; the RN originals are untouched | 12.00 (migration and recovery retention policy, in the charter). It interacts with 12.06: the Expo rollback build reads those same files, and 12.06 step 1(d) forbids deleting legacy backups | Stage A upgrade run (SA2) | contract §17.2 G6 |
| OI-1 | **§8.2 omits first-party backend data**: the sign-in email, synced business records (customer names, phones, addresses), job photos | 12.01 (decide the label declarations; update `N/PrivacyInfo.xcprivacy` if needed) | App Store privacy labels (PRIV-1) | contract §8.2, §8.3 |
| OI-2 | **Sentry project `tradeready-ios` in org `tradeready-3r`** must exist before the first dSYM upload | 12.02 documents it; the owner creates it (an agent must not) | CR-1 to CR-9 | 11.09 ruling |
| OI-3 | **429 push policy.** Under a 429, every queued item is still sent once per pass; passes are bounded by exponential backoff | 12.00 (policy, in the charter); 12.02 (monitored signal, PERF-7) | Monitoring and policy, not a known defect | 11.12; [performance](native-phase-11-performance.md) scenario B |
| SIGN-1 | **The signed Release build cannot be provisioned.** Re-run on branch native/phase-12 on 2026-09-25: exit 65, `No Accounts: Add a new account in Accounts settings.`, and the wildcard `iOS Team Provisioning Profile: *` lacks the App Groups capability and `group.com.gettradereadyapp.tradeready` for target `TradeReadyWidgets` | 12.01. Owner action: sign in at Xcode › Settings › Accounts (team `96J48TJWX3`); the agent re-runs the signed build. An agent never touches accounts, the keychain, profiles or signing settings | Every signed, device, TestFlight and archive row (EXT-1 onward) | Phase 11 ledger (11.14); this revision |
| VER-1 | **The native version is below the live Expo version.** `project.pbxproj` has `MARKETING_VERSION = 1.0` and `CURRENT_PROJECT_VERSION = 1`; RN `app.json` has `"version": "1.2.1"`. App Store Connect accepts only a version above the live one, and 12.06's rollback candidate must be above the native release | 12.01 (the owner confirms the live store version; 12.01 sets the version scheme, a `project.pbxproj` edit that needs a recorded ruling) | Stage A upload; 12.06 numbering | this revision |
| AGG-1 | **The aggregate's last step fails on committed code.** `native/run-all-domain-tests.sh` ends with `(cd backend-workers && npm test)`, which exits 1 with "Missing script: test": the committed `backend-workers/package.json` has no `test` script (only another agent's uncommitted edit adds it). Every native runner before it passes (`set -eu`) | Owner or the backend agent. Phase 12 does not edit `backend-workers/` | The aggregate's exit code only | Phase 11 ledger "Finish"; this revision |

### 1.2 Plan conflict: code-level cutover blockers

§1 says Phase 12 is evidence and operations, not feature implementation. But three
cutover blockers are code: I2 (a defect), and G1 and G2 (parity features). So is any
S1 or S2 item left in the §7 defect list, because E1 requires zero. The plan already
sanctions two small pieces of Phase 12 code:

- 12.02's `N/NativeSupportDiagnostics.swift`;
- 12.06's rollback data decision: drain the queue before any rollback advisory, and
  make the journal never re-import stale AsyncStorage.

The roadmap also makes I2 unwaivable as written ("It must be fixed before cutover").
So some build work happens in Phase 12 whichever option is chosen. The two options:

- **Option A: a pre-Stage-A build lane, 12.00b "Pre-cutover parity and defect fixes"**
  (packet in §3). It starts after the owner answers D1–D3 and must finish before 12.04.
  Each item is a normal SDD task, with its own tests and review:
  - RN is the behavioral spec;
  - write the failing test first;
  - register a host runner in `native/run-all-domain-tests.sh`;
  - pass a task review, then the whole-branch review at the end.

  It holds I2 (always), the §7 S1/S2 items that need code, and whichever of G1 and G2
  the owner chooses to build.
- **Option B: dated waivers in the charter.** G1 and/or G2 are not built. For each,
  the charter records:
  - the waiver's date and owner;
  - the user-visible impact (G1: booking alerts arrive by email only; G2: the Money
    tax card cannot open a settings screen, so the waiver states what the user sees);
  - the release that builds it;
  - why it is safe to ship.

  The analytics Q4 exclusion list stays as it is. I2 and any S1/S2 code fix still need
  the build lane, so under Option B 12.00b holds only 12.00b.1 and 12.00b.2.

The options can be mixed per gap (for example, build G2 and waive G1). The owner
decides (D1, D2); this plan does not choose.

### 1.3 Owner decisions (asked and answered 2026-09-25)

| ID | Decision | Answer (2026-09-25) | Affects |
|---|---|---|---|
| D1 | G1 native remote push: build before cutover (12.00b.4), or a dated waiver in the charter | **Dated waiver.** Booking alerts arrive by email only until native push ships; the charter records the waiver. 12.00b.4 is not built in Phase 12 | 12.00, 12.00b, 12.01 (no push entitlement needed) |
| D2 | G2 tax-settings screen: build before cutover (12.00b.3), or a dated waiver | **Build** (12.00b.3) | 12.00, 12.00b |
| D3 | I2 rejected-change UX: the shape of the "N changes couldn't sync" surface on Cloud Sync, and whether the user can retry or discard rejected changes | **Surface:** a Cloud Sync status line ("N changes couldn't be saved") that opens a detail list (record type, name, when); the count also goes into the support report. **Actions:** Retry re-queues the change; Discard removes it after a confirmation dialog, and the next pull restores the server's version | 12.00b.1 |
| D4 | Isolated staging: does a trusted staging backend and Supabase project exist? If not, it stays a hard blocker. `https://staging.invalid` stays, and production is never substituted | **Not yet.** It stays a hard blocker with an owner task; `https://staging.invalid` stays | 12.03 (every STG row), 12.04 (SA3) |
| D5 | Charter RACI: a name or role for owner, release engineer, backend, support and on-call | **The owner holds every role.** The charter records the single-person risk and the on-call coverage the phased release needs | 12.00 and every stage gate |

Also decided on 2026-09-25: native/phase-12 is rebased onto native/phase-11 at `1bb701c`,
which picks up `1e47f26` (the App Store rating prompt). The final whole-branch review
runs from `6d573a7`, so it also covers `1e47f26`, which Phase 11's final review did not
see.

Resolution of §1.2: **Option A for I2, the §7 S1/S2 items and G2; Option B for G1.**
Lane 12.00b therefore holds 12.00b.1, 12.00b.2 and 12.00b.3. 12.00b.4 is not built.

## 2. Stage graph and gates

```text
12.00 cutover charter (provisional thresholds, severity, RACI, go/no-go, rollback data decision)
 |- 12.00b pre-cutover parity and defect fixes (proposed 2026-09-25, §1.2; I2 always,
 |        §7 S1/S2 code fixes, G1/G2 only if the owner chooses to build; gated on D1-D3)
12.03 deferred evidence index (can start in parallel with 12.00; executing rows needs 12.01)
 |- 12.01 release config + store-readiness freeze (SC2, SC4)
 |- 12.02 monitoring/metrics/support instrumentation (E2)
 |        | (12.00b, 12.01, 12.02, 12.03 are Stage A entry prerequisites)
 |- 12.04 Stage A internal TestFlight (SA1-SA3) -> native baselines; owner re-ratifies thresholds
 |- 12.06 rollback playbook + rehearsal (SB3, E3)
 |        | (Stage A exit + rehearsal recorded + thresholds ratified -> Stage B entry)
 |- 12.05 Stage B limited external beta (SB1-SB3)
 |        | (Stage B exit + rollback candidate uploaded -> Stage C entry)
 |- 12.07 Stage C production cutover (SC1, SC3, SC4)
12.04-12.07 -- 12.08 exit verification + closeout (E1-E3)
```

## 3. Task packets

### 12.00 — Cutover charter: thresholds, severity, and go/no-go

**Depends on:** 11.12 (the measurement definitions, not device numbers).
**Requirements:** all (defines the gates).

**Own:** `docs/native-phase-12-cutover-charter.md`; no code.

1. Define defect severity (S1/S2/S3) with examples drawn from migration, sync,
   payments, crash, and data-loss classes, and the rule that S1/S2 must be zero.
2. Set **provisional** numeric thresholds for migration failures, sync errors,
   crashes (crash-free sessions), and payment reconciliation, plus the rolling
   window and the data source (Phase 11 analytics + Sentry + Supabase/Stripe
   reports). There are no production users, so no Expo production baseline
   exists: state the thresholds as absolute targets (for example a crash-free
   sessions floor, zero unreconciled payments, zero migration data loss). Record
   that Stage A's native baselines refine them, and that the owner re-ratifies
   them at the Stage B entry gate. Do not wait on device numbers that only
   Phase 12 can produce.
3. Define the stage RACI (owner, release engineer, backend, support, on-call),
   the go/no-go checklist per stage, and the decision-log format.
4. Define the exit definition for each stage and the explicit blocking conditions
   (e.g., any S1, any data-loss, migration failure above threshold).
5. Record the **rollback data decision** (see 12.06): the rollback build treats
   the cloud as authoritative (forced pull, with a warning when unsynced changes
   exist); the native build drains its mutation queue before any rollback
   advisory; and the native migration journal guarantees that a re-upgrade adopts
   newer native/cloud state rather than re-importing stale legacy AsyncStorage.
6. Record how exposure is controlled at cutover given no installed base (see
   12.07): the phased release only gates automatic updates to existing installs,
   so new installs receive the build immediately. The real controls are manual
   release timing and pausing or removing the version from sale. Cite Apple's
   current documentation, with the date it was read.
7. *(Revision 2026-09-25.)* Record the Phase 11 carry decisions it owns (§1.1): D1
   and D2 (build in 12.00b, or a dated waiver with the fields §1.2 lists); the G6
   migration and recovery retention policy for the RN AsyncStorage source files
   (keep them, protected, or delete after a verified import; it must agree with the
   12.06 rule never to delete legacy backups and with the Expo rollback build, which
   reads those files); and the OI-3 429 push policy.
8. *(Revision 2026-09-25.)* Own the **defect list**: every §7 item routed to "12.00
   defect list", with its severity, state at `6d573a7`, handling and source ledger
   line. An open S1 or S2 blocks Stage A entry unless 12.00b fixes it, or the owner
   records a severity change with its rationale in the decision log. The §7 items
   marked "doc batch" are fixed here, in one docs-only commit.

The charter is a **draft** until the owner approves it. The draft marks itself that
way, and no stage gate cites an unapproved threshold.

**Done when:** provisional thresholds, severities, owners, stage gates, the
rollback data decision, and the exposure-control rule are written and
owner-approved; every later task can cite a single charter source. This task does
not choose metrics the owner has not ratified.

### 12.00b — Pre-cutover parity and defect fixes (proposed 2026-09-25; see §1.2)

**Depends on:** the owner's D1–D3 answers; the 12.00 defect list (a draft is enough
to start 12.00b.1). **Must finish before:** 12.04, because Stage A builds include it.
**Requirements:** E1 (no unresolved S1/S2), SB2 (sync errors observable), and parity
for G1/G2 when built.

**Own:** the native files each item names; new host runners, registered in
`native/run-all-domain-tests.sh`; the matching contract, parity-matrix and runsheet
rows. It never edits `backend*/`, `supabase/`, `targets/`, `utils/`, `types/` or
`__tests__/`. A `project.pbxproj` edit needs a recorded ruling.

Phase 11 conventions apply to every item:

- RN is the behavioral spec;
- a failing test first, with RED and GREEN recorded;
- every runner registered, run with `TZ=America/Phoenix`;
- the focused runners, the aggregate (AGG-1 aside) and the unsigned Release compile
  run per task;
- a task review per item and a whole-branch review at the end;
- device behaviour becomes 12.03 rows and is never claimed from host evidence.

**12.00b.1 — I2 rejected-change handling (always in scope).**

1. In `N/NativeSupabasePush.swift`, classify a non-auth 4xx (400, 404, 409, 413,
   422, and a 403 that repeats after one refresh) as `.rejected`. A 401 and the
   first 403 keep the auth-refresh path. 408, 425, 429, 5xx and network errors stay
   transient.
2. Move a rejected mutation out of the live queue into an app-private, owner-scoped
   rejected store. Scrub that store at every account boundary (sign-out, account
   switch, deletion, the recovery exits), using the existing boundary-marker pattern.
3. Add a bounded diagnostic: the count, table and status code only, through the
   Phase 11 redaction path. It never carries a payload.
4. Build the Cloud Sync surface D3 chooses.
5. Decide whether to relax `NativeSyncCoordinator`'s `guard queue.load().isEmpty`
   toward RN (pull after push). The 11.12 commit path already keeps pending records
   ("pending wins") and holds per-table cursors. Record the decision, and make sure a
   record kept locally cannot pin its table's cursor forever.
6. Tests:
   - a poor-network poison-item scenario in `native/PoorNetworkTests/main.swift`:
     the good items push, inbound pulls continue, and the poison item reaches the
     rejected store exactly once;
   - the classification table;
   - the boundary scrubs;
   - a citation of RN's pull-after-push in `utils/sync.ts` `syncIfOnline`.

**12.00b.2 — §7 S1/S2 code fixes.** Every §7 item routed to the defect list as S1 or
S2, still open at `6d573a7`, and fixable in code. The §7 table names them (handling
"12.00b.2": 2 S1 and 8 S2). The S3 items marked "rider" edit the same code and ship
in the same task, but they do not block Stage A on their own.

**12.00b.3 — G2 tax-settings editor (only if D2 is "build").**

1. Port RN `components/money/TaxSettingsModal.tsx` onto the existing
   `N/Domain/NativeTaxSettings.swift` and `AppStore.commitTaxSettings`.
2. Open it from the Money tax card, which 11.10a found cannot be tapped natively.
3. `tax_settings_saved` becomes live and leaves the Q4 exclusion list in
   `native/Phase11QualificationTests/main.swift`.
4. Pass the Phase 11 accessibility scanners, update the parity row "Tax set-aside",
   and add a device row to 12.03.

**12.00b.4 — G1 native remote push (only if D1 is "build"). Not built: D1 was answered "dated waiver" on 2026-09-25 (§1.3). Kept as the spec for the release that builds it.**

1. Register for remote notifications only when notification permission is already
   granted. RN never prompts for push; the invoice-reminder flow owns the ask.
2. Exchange the APNs device token for an Expo push token for the EAS project in
   `app.json` (`extra.eas.projectId`), so the backend's existing Expo sender works
   unchanged. This uses the same token-exchange endpoint that `expo-notifications`
   calls. If the owner would rather not depend on it, the alternative is an APNs
   sender in the backend, which is a backend task outside this lane.
3. Write `settings.pushToken` (`token`, `platform: "ios"`, `updatedAt`) only when the
   token changed, through the normal settings save (one upsert).
4. Route taps through the 11.06 gates (signed in, owner, record): `booking_request`
   → the Jobs list; `booking_update` → the job when `jobId` is present, otherwise the
   Jobs list. Emit `booking_request_opened` and `booking_update_opened`; both leave
   the Q4 exclusion list.
5. Owner-held prerequisites:
   - the Push Notifications capability on App ID `com.gettradereadyapp.tradeready`,
     with regenerated profiles;
   - the `aps-environment` entitlement, added by 12.01 (the entitlements owner) under
     a ruling;
   - the Expo project's APNs credentials covering that bundle id;
   - an OI-1 privacy-label check for the new network destination.
6. Add device rows to 12.03: delivery; tap routing from a cold and a warm app;
   signed out.

**Done when:** every item 12.00b holds is fixed with host evidence and a clean
review, and no §7 S1/S2 item is open. The aggregate (AGG-1 aside) and the unsigned
Release build pass. The device rows are in 12.03. No parity row is marked
`Verified` here.

### 12.01 — Release configuration and store-readiness freeze

**Depends on:** 12.00; 11.01–11.14 landed. **Requirements:** SC2, SC4.

**Read:** `N/BuildEnvironment.swift`, `native/Info.plist`,
`N/TradeReadyNative.entitlements`, the release build configurations in
`native/TradeReadyNative.xcodeproj/project.pbxproj`,
`native/run-phase-3-device-preflight.sh`,
`native/run-phase-4-device-preflight.sh`, `app.json` (for the RN values the native
build must match), and the Phase 7–11 release notes. Also *(revision 2026-09-25)*
the extension's `native/TradeReadyWidgets/Info.plist` and
`native/TradeReadyWidgets/TradeReadyWidgets.entitlements`, and both privacy
manifests (`N/PrivacyInfo.xcprivacy`, `native/TradeReadyWidgets/PrivacyInfo.xcprivacy`).

**Own:** release-configuration edits in the Xcode project/`Info.plist`/
entitlements and new `docs/native-phase-12-release-readiness.md`; both privacy
manifests (they exist since Phase 11).

*Revision 2026-09-25: additional steps from the Phase 11 carry-in (§1.1).*

- **SIGN-1.** After the owner signs in at Xcode › Settings › Accounts, re-run the
  signed Release build and record the result verbatim. Confirm that
  `TradeReadyWidgets.appex` is embedded and that both targets' profiles carry
  `group.com.gettradereadyapp.tradeready`. If D1 is "build", add `aps-environment`
  under a ruling and confirm the push capability.
- **VER-1.** Record the live App Store Expo version (the owner confirms it), and set
  a native `MARKETING_VERSION` and build-number scheme above it (a `project.pbxproj`
  edit with a ruling). Leave room for the 12.06 rollback candidate to sit above the
  native release, and the re-upgrade above that.
- **OI-1.** Decide the App Store privacy-label declarations for first-party backend
  data (email, business records and their contact fields, photos; App
  Functionality, linked), and align `N/PrivacyInfo.xcprivacy` with them. PRIV-1 then
  checks the entered labels against it.
- Read-only verification comes first. `docs/native-phase-12-release-readiness.md`
  lists every item with a verified value or a named blocker. Store metadata is
  never changed and no account is created without an explicit instruction.

1. Verify production configuration matches the live Expo build's backend origin,
   Supabase origin/key, RevenueCat keys, and entitlements; confirm the
   environment/write guards still fail closed and that no staging/placeholder
   value can ship.
2. Confirm entitlements (App Group and Sign in with Apple today; associated
   domains only if a later phase adds them — neither the native entitlements nor
   RN `app.json` declare any) and the app and widget-extension privacy manifests
   (11.01, 11.09) match what the build actually does, and that
   `ITSAppUsesNonExemptEncryption` and permission strings are accurate.
3. Verify App Store metadata and legal disclosures (privacy policy, terms,
   subscription disclosures) are current for the native build, and update the
   App Store privacy nutrition labels for the data the Sentry/PostHog SDKs
   collect.
3a. Prepare App Review notes and a demo account for both external TestFlight
   (Beta App Review, needed before Stage B) and production review.
3b. Record subscription and identity continuity checks for Stage A: a RevenueCat
   entitlement bought on the Expo build is honored after upgrade, Restore
   Purchases works, and a sandbox purchase works; a Sign in with Apple user
   (same team and bundle id) lands in the same account after upgrade.
4. Record the database-backup and backend-compatibility checklist as a gate
   reference (execution is 12.03/12.07), and add the explicit assertion that
   legacy migration code and backend compatibility are retained (SC4).

**Done when:** preflight passes for the intended environment with the owner's real
configuration (not a substituted one), every store-readiness item has a verified
value or a named blocker, and the retention rule is recorded. No store submission
here.

### 12.02 — Monitoring, metrics, and support instrumentation

**Depends on:** 12.00, 11.07–11.12. **Requirements:** E2.

**Read:** the Phase 11 analytics/crash/performance modules, the charter
thresholds, `N/NativeAccountDeletion.swift` and any support-export path, and the
backend/Stripe reporting surfaces.

**Own:** new `N/NativeSupportDiagnostics.swift` (privacy-safe, bounded) if not
already provided by Phase 11; `docs/native-phase-12-monitoring.md`; dashboards and
alert definitions (owner-configured, documented here).

1. Define each monitored signal's source, query/threshold, alert route, and owner:
   migration failures, sync errors/pending-queue growth, crash-free sessions,
   payment reconciliation, and support contacts.
2. Ensure a privacy-safe support export exists (bounded, no secure keys, no
   customer PII, no document bytes) so a beta user can share diagnostics without
   leaking data.
3. Define the beta feedback/support intake channel and the triage SLA from the
   charter.
4. Verify no monitored payload carries secure keys or sensitive documents
   (reusing the Phase 11 redaction denylist).
5. *(Revision 2026-09-25.)* Phase 11 carries:
   - **OI-2:** document the Sentry project `tradeready-ios` (org `tradeready-3r`)
     as an owner prerequisite for CR-1 to CR-9. The agent never creates it.
   - **OI-3:** make 429 bursts a monitored signal (Cloud Sync diagnostic codes,
     PERF-7) against the charter's policy.
   - **I2:** once 12.00b.1 lands, make the rejected-change count a monitored sync
     signal.
   - **Support export:** `N/NativeSupportDiagnostics.swift` builds on the existing
     `AppStore.createPersistenceSupportReport`, with host tests proving it is
     bounded and redacted.
   - **Dry run:** run the synthetic-data dry run on host fixtures only.

**Done when:** every metric in the charter has a live-or-runnable source, an
owner, and an alert route; the support export is privacy-safe; and a dry-run on
synthetic data produces the expected signal. No production data is read for this
task without explicit authorization.

### 12.03 — Deferred device and staging evidence collection

**Depends on:** the Phase 2–11 runsheets. Building the index can start in
parallel with 12.00; only *executing* rows (12.04+) needs 12.01. **Requirements:**
enables SA2, SA3, E1–E3.

**Read:** the runsheet files listed under "Scope source" above,
`native-phase-4-mixed-client-convergence.md`, the roadmap Phase 5, 6, and 8
sections, and the phase preflight scripts.

**Own:** `docs/native-phase-12-evidence-index.md` aggregating every deferred row
with its phase, requirement, environment/build, expected result, and evidence
placeholder; no feature edits.

1. Consolidate every deferred physical-device, isolated-staging, TestFlight, and
   background/sync row into one executable index, de-duplicating rows that share a
   scenario.
1a. Phases 5, 6, and 8 have no runsheet. Extract their deferred device/staging
   rows from the roadmap text and their plan/spec docs
   (`native-phase-8-implementation-plan.md`,
   `native-phase-8-calendar-booking-routes-portals-spec.md`) into the
   index, and name each source line so nothing is invented.
2. Mark which rows are Stage A-eligible (synthetic/team) versus Stage B-eligible
   (established/Stripe/booking/recurring/iPad), so the stage owners know what runs
   where.
3. Confirm the trusted isolated-staging URL requirement is either satisfied by the
   owner or recorded as a hard blocker (never substituted).
4. *(Revision 2026-09-25.)* Use the Phase 11 runsheet's row format (ID,
   requirement, steps, expected result, environment/build, evidence placeholder) for
   every row. Include each §7 item routed to "12.03 evidence index", and the device
   rows 12.00b adds. List every unresolved prerequisite by name (for example STG /
   D4, SIGN-1, OI-2, the owner's provider keys).

**Done when:** every deferred row from Phases 2–11 appears exactly once with a
stage assignment and an evidence placeholder; unresolved prerequisites are named.

### 12.04 — Stage A: internal TestFlight

**Depends on:** 12.00b (revision 2026-09-25), 12.01, 12.02, 12.03. **Requirements:** SA1, SA2, SA3.

**Own:** stage run record appended to `docs/native-phase-12-evidence-index.md`;
owner/team approval to submit to App Store Connect.

1. Build and distribute to internal TestFlight using team accounts and synthetic
   data only (SA1). Record the exact build number and profile.
2. Exercise the upgrade migration from the current App Store Expo build on a
   physical device: install Expo build → upgrade to native without deleting →
   verify every canonical collection, owner binding, photo adoption, App Group
   state, and the migration journal (SA2, drawing on the Phase 2/3 matrices).
   Also verify that local notifications the Expo build left pending are
   reconciled by the native coordinator (same namespaces) — replaced, not
   duplicated or orphaned — and run the 12.01 step 3b subscription and Sign in
   with Apple continuity checks.
3. Run the full regression suite and backend load checks against the staging
   backend (SA3).
4. Execute every Stage-A-eligible row from 12.03 and record actual results.
5. Capture the native baselines defined by 11.12 (launch time, crash-free
   sessions, sync error rate, migration timing) and hand them to the owner to
   re-ratify the 12.00 thresholds before Stage B.

**Done when:** Stage A rows have real device/TestFlight evidence, no S1/S2 defect
is open, and the Stage-A exit gate in the charter is met or a named blocker is
reported. A host-only or simulator-only run does not close this task.

### 12.05 — Stage B: limited external beta

**Depends on:** 12.04 exit gate, 12.06 rehearsal recorded, thresholds re-ratified,
and Beta App Review approval for the external TestFlight build (allow lead time).
**Requirements:** SB1, SB2, SB3.

**Own:** beta cohort record + monitoring log appended to the evidence index;
owner approval to invite the cohort.

1. Recruit the charter cohort representing new, established, offline-heavy,
   Stripe, booking, recurring-work, and iPad users (SB1), plus at least one
   two-device mixed-client user (native on one device, Expo on another; see
   `native-phase-4-mixed-client-convergence.md`). With no production users,
   "established" means accounts seeded with realistic history. Document consent
   and data-handling per the legal disclosures.
2. Monitor migration failures, sync errors, crashes, payment reconciliation, and
   support contacts against the charter thresholds, with the 12.02 dashboards and
   the privacy-safe support export (SB2). Keep the decision log current.
3. Keep the rollback path ready throughout the beta (SB3), per 12.06: the Expo
   release branch builds green, and the rollback candidate can be uploaded on
   demand.
4. Triage every report; convert unresolved S1/S2 into a blocking decision, not a
   silent waiver.

**Done when:** the cohort has run the beta for the charter window, every metric is
within threshold (or has a blocking finding), and the Stage-B exit gate is met.

### 12.06 — Rollback playbook and rehearsal

**Depends on:** 12.00 (rollback data decision), 12.02, and 12.04 (a native
TestFlight build to roll back from). It is a **Stage B entry gate**: SB3 requires
rollback readiness throughout Stage B, so the rehearsal must be recorded before
12.05 starts. **Requirements:** SB3, E3.

**Own:** `docs/native-phase-12-rollback-playbook.md`; rehearsal record.

App Store Connect cannot re-release an older build over a newer live version.
The playbook extends the
[Phase 0 rollback procedure](native-phase-0-baseline.md) rather than
replacing it.

1. Write the step-by-step rollback:
   (a) pause the phased release and/or hold or remove the native version from
       sale (see 12.07 on what each control actually gates);
   (b) keep the Cloudflare Worker on the last mixed-client-compatible deployment;
   (c) submit the preserved Expo release branch as a **new binary** whose
       version/build number is higher than the live native release, requesting
       expedited review;
   (d) never delete native migration journals or legacy AsyncStorage backups;
   (e) reconcile native-written server rows by server audit timestamps and
       owner ids before asking users to reopen the Expo build.
2. Keep the rollback ready in advance: keep the EAS/Expo build pipeline green
   through the first stable native release series, and before Stage C, upload
   and process (but don't submit) an Expo rollback candidate whose version is
   above the planned native release version.
3. Implement and document the 12.00 rollback data decision. An Expo build reads
   legacy AsyncStorage, which is stale as of the upgrade, so:
   - the rollback build treats the cloud as authoritative (forced pull) and warns
     when it cannot confirm that unsynced native changes were drained;
   - the native build drains its mutation queue before any rollback advisory is
     published;
   - on re-upgrade, the native migration journal adopts newer native/cloud state
     and never re-imports the stale legacy AsyncStorage over it.
   Confirm backend compatibility in both directions during the mixed-client
   window (`native-phase-4-mixed-client-convergence.md`).
   *(Revision 2026-09-25.)* An agent may build the native code for this step, with
   host tests, before the rehearsal: the queue drain before any rollback advisory,
   and the journal rule that adopts newer native or cloud state. The rehearsal
   (step 5) and staffing (step 6) need the owner. The G6 retention policy (12.00)
   must leave the RN AsyncStorage source files readable by the Expo rollback build.
4. Define the trigger conditions (which S1/S2 or metric breach forces rollback),
   the decision owner, and the communication plan (support script, status note).
5. Rehearse on synthetic/team accounts via TestFlight with real version
   numbering: native → Expo (higher build) → native (higher again). Include an
   unsynced local edit made before each transition. Record actual timing and
   manual steps, and verify the legacy migration code path still exists and
   works after rollback (SC4).
6. Confirm support and on-call staffing for the cutover window (E3).

**Done when:** the playbook is written, rehearsed with recorded evidence, and
staffed; the rehearsal proves native → Expo → native without data loss on
synthetic accounts, including the unsynced-edit cases; and the rollback
candidate's version numbering is recorded.

### 12.07 — Stage C: production cutover

**Depends on:** 12.05 exit gate + 12.06 verified + the Expo rollback candidate
uploaded and processed (12.06 step 2). **Requirements:** SC1, SC3, SC4.

**Own:** cutover run record appended to the evidence index; owner approval to
release to production.

1. Freeze non-critical Expo feature development for the cutover window (SC1) and
   announce the freeze.
2. Re-verify the pre-cutover checklist live: database backups taken and
   restorable, backend compatibility confirmed, App Store metadata/entitlements/
   privacy manifest/legal disclosures final (SC2 items, executed here).
3. Release using App Store phased release (SC3) and control exposure as it
   actually works:
   - The phased release follows Apple's fixed 7-day schedule
     (1/2/5/10/20/50/100%). The only controls are pause (up to 30 days in total),
     resume, and release to all. It gates only **automatic updates** to existing
     installs; new installs and manual updates get the build immediately.
   - Because there are no current users, the phased release gates almost
     nothing. Treat new installs as the exposed cohort: use manual release timing
     (release when the owner and on-call are ready), watch the 12.02 dashboards
     against thresholds, and pause the phased release or remove the version from
     sale on a breach.
   - Confirm these App Store Connect behaviors against Apple's current
     documentation when writing the charter.
4. Retain legacy migration code and backend compatibility; verify no release step
   removes them (SC4).
5. Monitor continuously against 12.02 during rollout, including the mixed-client
   window (one account on native and Expo devices at once); any S1/S2 or
   threshold breach triggers the 12.06 rollback decision.

**Done when:** the phased rollout reaches 100% with metrics in threshold, no S1/S2
open, and legacy compatibility intact — or the rollback playbook has been
executed and recorded.

### 12.08 — Exit verification and closeout

**Depends on:** 12.04–12.07. **Requirements:** E1, E2, E3.

**Own:** `docs/native-phase-12-exit-report.md` + roadmap/parity-matrix updates.

1. Audit and confirm zero unresolved severity-1/severity-2 defects with the
   charter severity definitions (E1).
2. Confirm migration, sync, payment, and crash metrics meet the agreed thresholds
   over the agreed window, citing the 12.02 sources (E2).
3. Confirm support and rollback playbooks are staffed and their rehearsal is
   recorded (E3).
4. Update the roadmap and parity matrix to `Verified` **only** where the
   evidence-index rows are actually satisfied, linking each row to its XCTest /
   UI test, RN oracle, device/OS, and screenshot or output comparison per the
   parity matrix's "Evidence required for Verified" contract.
5. Record the post-cutover stabilization window and the follow-up for removing
   legacy migration code in a future release series (explicitly not part of this
   phase).

**Done when:** the exit report links every requirement and exit criterion to real
evidence, no row is marked `Verified` without the full evidence set, and the
roadmap reflects reality rather than intent.

## 4. Verification commands

Phase 12 primarily runs evidence rather than code suites. The commands below
support the gates; run them per task, not all at once.

```sh
# Full host regression before any stage (a west-of-UTC zone exposes local-date bugs)
TZ=America/Phoenix sh native/run-all-domain-tests.sh

# Environment/staging preflight (must fail closed on placeholders/production match)
sh native/run-phase-3-device-preflight.sh
sh native/run-phase-4-device-preflight.sh

# Unsigned compile sanity (does not substitute for a signed/device build)
xcodebuild -project native/TradeReadyNative.xcodeproj -scheme TradeReadyNative -configuration Release -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build

# Signed local Release build (pre-approved; archive/export/upload are not)
xcodebuild -project native/TradeReadyNative.xcodeproj -scheme TradeReadyNative -configuration Release -destination 'generic/platform=iOS' -allowProvisioningUpdates build

# RN oracles for any 12.00b item
TZ=America/Phoenix npm test -- --runInBand --runTestsByPath <files>

# Doc references after editing a docs/native-*.md file (must report 0 missing)
sh native/run-doc-reference-check.sh
```

*Revision 2026-09-25:*

- When another agent has uncommitted edits in `native/`, verify committed code in a
  clean worktree, not in the shared checkout.
- The aggregate's final `backend-workers` step fails on committed code (AGG-1,
  §1.1). Every native runner before it must still pass.
- The signed build fails until SIGN-1 is cleared.

Device, TestFlight, App Store Connect, backend-load, and rollback steps are manual
per the stage packets and produce evidence artifacts, not shell exit codes. Do not
invoke a deploy, store-submission, or live-migration command without explicit
authorization for that exact action.

## 5. Reusable stage-owner prompt

> Execute **stage 12.XX only** from
> `docs/native-phase-12-implementation-plan.md`. Read the charter
> (`docs/native-phase-12-cutover-charter.md`), the evidence index, and the listed
> runsheets first. Confirm the entry gate is actually satisfied; if not, stop and
> report the blocker rather than approximating it. Do not substitute production
> for missing isolated staging, do not change `https://staging.invalid` or any
> production-matched Supabase value to pass a preflight, and do not mark any row
> `Verified` without the full evidence set (test name, RN oracle, device/OS,
> screenshot/output comparison). Record actual results, timings, build numbers,
> and unresolved findings; separate a blocked gate from a passed one. Preserve
> canonical business data and legacy migration code. Return the tasks executed,
> evidence artifacts with exact paths, requirement IDs covered, unresolved
> S1/S2 findings, and the next gate's readiness.

## 6. Initial execution ledger

All tasks **12.00–12.08 are pending**. No stage has been executed and no evidence
has been collected. This plan is not a claim that the app is release-ready; the
deferred device/staging/TestFlight evidence from Phases 2–11 is collected here.

| Task | Requirement IDs | Status | Depends on | Deliverable |
|---|---|---|---|---|
| 12.00 | all (gates) | Pending | 11.12 (definitions); D1, D2, D5 | Cutover charter + provisional thresholds + RACI + rollback data decision + defect list (§7) + G6/OI-3 policy |
| 12.00b | E1, SB2; G2 parity | Approved 2026-09-25 (§1.3) | D1–D3 answered; 12.00 defect list | I2 fix + §7 S1/S2 code fixes + G2 editor (G1 waived) |
| 12.01 | SC2, SC4 | Pending | 12.00, 11.x; SIGN-1, VER-1, OI-1 | Release config + store-readiness + review notes |
| 12.02 | E2 | Pending | 12.00, 11.07-11.12 | Monitoring/metrics/support |
| 12.03 | enables SA2/SA3, E1-E3 | Pending | phase runsheets (parallel with 12.00); D4 | Deferred-evidence index incl. Phase 5/6/8 rows + §7 device items |
| 12.04 | SA1, SA2, SA3 | Pending | 12.00b, 12.01-12.03 | Stage A run + evidence + native baselines |
| 12.06 | SB3, E3 | Pending | 12.00, 12.02, 12.04 | Rollback playbook + rehearsal (Stage B entry gate) |
| 12.05 | SB1, SB2, SB3 | Pending | 12.04, 12.06, Beta App Review | Stage B run + monitoring log |
| 12.07 | SC1, SC3, SC4 | Pending | 12.05, 12.06, rollback candidate uploaded | Stage C cutover run |
| 12.08 | E1, E2, E3 | Pending | 12.04-12.07 | Exit report + roadmap update |

Exit criteria traceability (roadmap Phase 12):

- "No unresolved severity-1 or severity-2 defects" — 12.04/12.05/12.07 track and
  block on them; 12.08 audits (E1).
- "Migration, sync, payment, and crash metrics meet agreed thresholds" — 12.00
  sets them, 12.02 instruments them, 12.05/12.07 monitor them, 12.08 confirms them
  (E2).
- "Support and rollback playbooks are staffed and verified" — 12.06 (playbook +
  rehearsal) and 12.08 (staffing + verification) (E3).

## 7. Phase 11 parked-minor triage (2026-09-25)

**Source.** The Phase 11 controller ledger
(.superpowers/sdd/native-phase-11-implementation-plan/progress.md, git-ignored, kept in
the main checkout) parked about 45 lines of "minor (deferred)" findings and final-review
residuals. Each line was split into atomic items and verified against the code at
`6d573a7`, by symbol rather than by the ledger's stale line numbers. An item's ID is its
ledger line: `L130` is line 130, and `L205.c` is the third item on line 205. `T1` was
found during this triage and has no ledger line. One ledger duplicate was merged: the
"Also" clause on L204 is L204.b.

**Severity** (draft; 12.00 ratifies it in the charter). The definitions are applied
literally:

- **S1:** can lose, corrupt or expose business or customer data (including across
  accounts); leaks a credential, secret or PII; crashes or hangs a core flow; computes
  money wrong; or is a migration failure without recovery.
- **S2:** a core workflow is broken, stalls, or silently diverges from RN, with a
  workaround or a bounded blast radius. Core workflows are sign-in, sync, jobs,
  estimates, invoices, payments, booking, migration and widget/Siri writes. S2 also
  covers a fail-open privacy or owner gate with no demonstrated leak, and an
  accessibility blocker on a core flow.
- **S3:** cosmetic or copy; test quality; duplication or hygiene; stale docs; or a
  fail-closed edge case with no data impact.

A closed item keeps the severity it had while open. S1 and S2 route the same way, since
E1 allows neither at exit, so a borderline S1/S2 call does not change what gets built.

**Destination** (each item goes to exactly one):

- **Defect:** the 12.00 defect list. Use it for a code, test or doc defect that can be
  confirmed or fixed on the host. Closed items also go here, for audit.
- **12.03:** the evidence index. Use it when confirming the item needs a device, a live
  SDK, the store, TestFlight or staging, and no code change is known to be needed.

**Handling:**

- **12.00b.1 / 12.00b.2:** fixed in that build item. It blocks Stage A.
- **rider:** an S3 item fixed inside 12.00b.2 because that change already edits the same
  code. It does not block Stage A.
- **doc batch:** fixed in 12.00's docs-only commit.
- **12.01 check / 12.02:** done inside that task.
- **backlog:** an S3 item that stays on the defect list as post-cutover work unless the
  charter pulls it in. It does not block Stage A.
- **record:** no action. The item is closed (kept for audit) or is accepted behavior.

| ID | Item | State @`6d573a7` | Evidence | Sev | Dest | Handling |
|---|---|---|---|---|---|---|
| L65 | Contract decision table lists C22 before C21 | Open | `docs/native-phase-11-platform-hardening-contract-decisions.md:69` | S3 | Defect | doc batch |
| L74 | `NativeWidgetMirror.write` takes a blocking `flock` on the MainActor with no timeout | Open | `N/Widgets/Shared/WidgetAppGroup.swift:75`; caller `N/AppStore.swift:6466` | S2 | Defect | **12.00b.2**: bounded try-lock in `WidgetAppGroupLock` (one fix with L96) |
| L75 | `widgetMirrorOwnerBinding` is internal, not private | Open | `N/AppStore.swift:6431` | S3 | Defect | backlog |
| L76 | Widget scrub-race test fakes the scrub with a manual domain wipe | Open | `native/WidgetSnapshotTests/main.swift:589` | S3 | Defect | backlog |
| L77 | Replay kept a second lock file beside `WidgetAppGroupLock` | Closed `86925a1` | `N/NativeWidgetActionReplay.swift:560` | S3 | Defect | record |
| L81 | Single-slot `widgetSeamCapture` could be cleared by an unrelated early return; unreachable today | Open | `N/AppStore.swift:6420` | S3 | Defect | record (accepted) |
| L95 | `WidgetActionQueue.swift` mixes value types, models and the engine (823 lines) | Open | `N/Widgets/Shared/WidgetActionQueue.swift` | S3 | Defect | backlog |
| L96 | `OnMyWayIntent.perform()` takes the same blocking `flock` on the MainActor | Open | `N/Intents/OnMyWayIntent.swift:25`; `N/Widgets/Shared/WidgetActionQueue.swift:594` | S2 | Defect | **12.00b.2** (with L74) |
| L97 | Intent scrub-race test fakes the scrub (sleep plus manual wipe) | Open | `native/AppIntentQueueTests/main.swift:874` | S3 | Defect | backlog |
| L98 | OnMyWay warm-route `pendingOpenUrl` stash was never cleared | Closed `33a24c3` | `native/AppIntentQueueTests/main.swift:1014` | S3 | Defect | record |
| L109 | Widget `localDateString` duplicates the app's projection helper | Open | `N/Widgets/Shared/NextJobWidgetPolicy.swift:131`; `N/Domain/NativeWidgetSnapshot.swift:126` | S3 | Defect | backlog (with L117) |
| L110 | `.missing` and `.noUpcomingJob` share an icon; `.missing` copy is not the contract's | Open | `N/Widgets/Shared/NextJobWidgetView.swift:43`; `N/Widgets/Shared/JobTimerWidgetView.swift:53` | S3 | Defect | backlog |
| L117 | Four copies of the "job not before today" local-date compare | Open | `N/Widgets/Shared/JobTimerWidgetPolicy.swift:143`; `N/Widgets/Shared/WidgetActionQueue.swift:784` (plus L109's two) | S3 | Defect | backlog; consolidate under `TZ=America/Phoenix` tests (FA-039 class) |
| L118 | Widget navy colour constant is duplicated | Open | `N/Widgets/Shared/JobTimerWidgetView.swift:17` | S3 | Defect | backlog |
| L130 | One malformed, duplicate or over-512 widget/Siri queue entry quarantines the whole batch, so valid actions (clock-ins, expenses, trips) are never applied | Open | `N/NativeWidgetActionReplay.swift:632`; contract §4.3/§4.6 | **S1** | Defect | **12.00b.2**: quarantine only the bad entries when the queue parses. A whole-batch quarantine stays only for unparseable bytes, and the raw bytes are still retained. Amend contract §4.6 |
| L131 | `invalidClaim`/`conflictingClaims` retry forever and the claim is never quarantined, which wedges that owner's replay | Open | `N/AppStore.swift:5818`; `N/NativeWidgetActionReplay.swift:775` | S2 | Defect | **12.00b.2**: quarantine the bad claim with a bounded diagnostic. Today's workaround is sign-out/in, which clears claims |
| L132 | Race tests assert "not finished after 0.3s", not "blocked on the flock" | Open | `native/WidgetOwnerGatingTests/main.swift:619` | S3 | Defect | backlog |
| L133 | `testOneLock` counts exact source-string occurrences in `AppStore.swift` | Open | `native/WidgetOwnerGatingTests/main.swift:1279` | S3 | Defect | backlog |
| L139 | Account-switch App-Group scrub failure was fail-open with no retry (final review 1a) | Closed `5f2f397` | `N/AppStore.swift:4817`; `N/Domain/SnapshotRepository.swift:26` | S2 | Defect | record (residual: L286.5b) |
| L140.a | `scrubWidgetAccountState` doc comment was stale for the switch caller | Closed `5f2f397` | `N/AppStore.swift:4804` | S3 | Defect | record |
| L140.b | `StoreIntegrationTests` comment says there is no App-Group access, but the switch now scrubs it | Open | `native/StoreIntegrationTests/main.swift:3322` | S3 | Defect | backlog |
| L141.a | Phase 11 plan §7 11.05 entry contradicts itself on parked-route handling | Open | `docs/native-phase-11-implementation-plan.md:1532` vs `:1631` | S3 | Defect | doc batch |
| L141.b | Contract C8 row still says "blocked until 11.05 decides", though §4.6 resolved it | Open | `docs/native-phase-11-platform-hardening-contract-decisions.md:56` | S3 | Defect | doc batch |
| L142 | `useAnotherAccount` did not hold `authenticationOperationInFlight`, so `signOut` could interleave (1c) | Closed `5f2f397` | `N/AppStore.swift:4240` | S2 | Defect | record |
| L156 | `deepLinkOwnerWasActive` could skip discarding a parked route (final review 2) | Closed `2e70415` | `N/AppStore.swift:4010` | S2 | Defect | record |
| L157 | A parked warm URL with no owner tag can open the next owner's same-id record (their own data only) | Open (by design) | `N/NativeDeepLinkRouting.swift:84` | S3 | Defect | record (accepted, contract §6.2) |
| L167.a | Mutually recursive `track` protocol defaults | Closed `58ae2a2` | `N/NativeAnalytics.swift:53` | S3 | Defect | record |
| L167.b | Variant ranking could strip its own discriminator | Closed `58ae2a2` | `N/NativeAnalytics.swift:449` | S3 | Defect | record |
| L167.c | Diagnostic names were logged `.public` without the secret screen | Closed `58ae2a2` | `N/NativeAnalytics.swift:338` | S2 | Defect | record |
| L168 | Analytics-config comment names three gating conditions; the code has a fourth (invalid host) | Open | `N/NativeAnalyticsConfiguration.swift:13` vs `:51` | S3 | Defect | backlog |
| L169.a | Release build's `appintentsnltrainingprocessor` "Could not archive SSU artifacts" line was never diffed against Phase 10 | Open (unverified) | `docs/native-phase-11-implementation-plan.md:2043` | S3 | Defect | 12.01 check: diff a Release log against the native/phase-10 tip |
| L169.b | Store-integration runner's `ConformanceIsolation` warning was never diffed against Phase 10 | Open (unverified) | `docs/native-phase-11-implementation-plan.md:2019` | S3 | Defect | 12.01 check (same diff) |
| L170.a | pbxproj host tests match literal tab/newline sequences | Open | `native/AnalyticsTransportTests/main.swift:270` | S3 | Defect | backlog |
| L170.b | `expect(!widget.isEmpty)` on the `Range` of a successful match is vacuous | Open | `native/AnalyticsTransportTests/main.swift:280` | S3 | Defect | backlog |
| L178 | About 15 store-level analytics emitters have no emission test | Open | `native/AnalyticsEventTests/main.swift` | S3 | Defect | backlog; 12.02 tests any emitter a charter metric reads |
| L179.a | `deleteAccount` reset-position test compares source byte offsets | Open | `native/AnalyticsEventTests/main.swift:543` | S3 | Defect | backlog |
| L179.b | Test-only `legacyStringValue` ships in the app target | Open | `N/NativeAnalytics.swift:26` | S3 | Defect | backlog |
| L180 | Parity matrix called the tax row "ported" although no editor exists | Closed `d18b29c` | `docs/native-parity-matrix.md:99` | S3 | Defect | record (the gap itself is G2, §1.1) |
| L193.a | `NativeErrorRedaction.swift` mixes four concerns in 729 lines | Open | `N/NativeErrorRedaction.swift:15` | S3 | Defect | backlog |
| L193.b | Only 3 of about 74 RN `reportError` sites are wired natively, with no ErrorBoundary equivalent (contract §10.4) | Open | `N/AppStore.swift:9859`; `N/SettingsView.swift:953` | S3 | Defect | 12.02 wires the sites that the charter's crash/error metrics read; the rest go to backlog |
| L193.c | Redaction over-redacts long plain alphanumerics (accepted, the safe direction) | Open (accepted) | `N/NativeErrorRedaction.swift` | S3 | Defect | record |
| L202 | Switch/recovery AI-key wipe ignored delete errors | Closed `5f2f397` | `N/AppStore.swift:9011` | S2 | Defect | record (residual: L286.5b) |
| L204.a | A failed boundary AI-key wipe was silent, with no counter and no retry (1b) | Closed `5f2f397` | `N/AppStore.swift:9011` | S2 | Defect | record |
| L204.b | `signIn` during a switch did not check `accountSwitchInFlight` (1c) | Closed `5f2f397` | `N/AppStore.swift:4330` | S2 | Defect | record |
| L205.a | `canChangeAIProviderKeys` comment omits the switch and pending-wipe guards | Open | `N/AppStore.swift:8992` | S3 | Defect | rider (with L286.5a) |
| L205.b | Three `if let functionBody(…)` source checks skip silently on a rename | Open | `native/AIProviderKeyTests/main.swift:927` | S3 | Defect | backlog |
| L205.c | Parity "AI Assistant" row omits the "Unavailable" key state | Open | `docs/native-parity-matrix.md:126` | S3 | Defect | doc batch (with T1) |
| L205.d | Phase 11 plan §7 repeats "Next ready: 11.10a" | Open | `docs/native-phase-11-implementation-plan.md:2580` | S3 | Defect | doc batch |
| L205.e | Switch and recovery exit wipe only the AI key kinds. The migrated `providerKey` Keychain entry survives until sign-out or delete (`clearAccountValues()`); nothing reads it after migration. The triage text was corrected here | Open | `N/AppStore.swift:9015`; `N/LegacyMigrationCoordinator.swift:367` | S3 | Defect | rider (with L286.5b) |
| L205.f | `bindingProvider` defaults to the real Keychain provider | Open | `N/NativeAuthenticatedIdentity.swift:431` | S3 | Defect | backlog |
| L205.g | `aiProviderKeyState` reads the Keychain synchronously in a SwiftUI `body` | Open | `N/SettingsView.swift:616` | S3 | Defect | rider (with L286.5a) |
| L215.a | Reduce-Motion scan checks the whole file, not the enclosing type | Open | `native/AccessibilityAuditTests/main.swift:534` | S3 | Defect | backlog |
| L215.b | Unreachable `openValue ?? ""` fallback | Open | `N/NativeMoneyCards.swift:64` | S3 | Defect | backlog |
| L215.c | A22: stacked route-move chevrons grow a stop row to about 116pt (accepted as RN parity) | Closed (accepted) | `docs/native-phase-11-platform-hardening-contract-decisions.md:1766` | S3 | 12.03 | device row A11-TT-1: first tap hits |
| L215.d | A24: keyboard dismissal outside the auth forms | Closed `afacd91` | `N/CoachView.swift:63` | S3 | Defect | record |
| L223.a | `mentions()` gate check ignores negation | Open | `native/LayoutMetricsTests/main.swift:867` | S3 | Defect | backlog |
| L223.b | IPAD-KB-1 omits "cancel a swipe-back, then ⌘N" | Open | `docs/native-phase-11-device-runsheet.md:199` | S3 | Defect | doc batch; 12.03 copies the fixed row |
| L223.c | A failed bulk-outreach sheet leaves ⌘N gated off until Done | Open | `N/InvoicesView.swift:47` | S3 | Defect | record (fail-closed) |
| L223.d | `NativeChangeOrdersView` has Swift-concurrency warnings | Open | `N/NativeChangeOrdersView.swift:581` | S3 | Defect | backlog |
| L223.e | IPAD-MT-3: Stage Manager's first frame may shift column geometry | Open | `docs/native-phase-11-implementation-plan.md:3068` | S3 | 12.03 | device row IPAD-MT-3 |
| L224 | "Cancel plan"/"Delete plan" silently did nothing (final review I1) | Closed `8146cd6` | `N/NativeRecurringInvoicesView.swift:104` | S2 | Defect | record |
| L237.a | Phase 11 plan §6 and the parity "Supabase sync" row omit round 3 and scenarios G–H | Open | `docs/native-parity-matrix.md:138` | S3 | Defect | doc batch |
| L237.b | Server-only records merge at the array end; no test pins the order | Open | `N/AppStore.swift:7218`; `N/NativeInitialSync.swift:514` | S3 | Defect | backlog |
| L237.c | An A→B→A value inside one un-coordinated pull can escape touched-key protection; it self-heals | Open | `N/AppStore.swift:6695` | S3 | Defect | record (accepted) |
| L237.d | Returning-user launch runs `refreshRecurringJobs()` but not `refreshRecurringInvoices()`, while RN runs both | Open | `N/AppStore.swift:5189`; `context/AuthContext.tsx:103` | S2 | Defect | **12.00b.2**: add the invoice refresh, with a test cross-checked against RN |
| L237.e | Overlapping direct pulls can commit a regressed cursor; the next pull refetches | Open | `N/AppStore.swift:6633` | S3 | Defect | record (idempotent) |
| L238 | I2: a non-auth 4xx is retried forever, and every pull is skipped while it is queued | Open | `N/NativeSupabasePush.swift:178`; `N/NativeSyncCoordinator.swift:290` | S2 | Defect | **12.00b.1** (unwaivable) |
| L249.a | `.bordered` tint scan accepts any text token | Open | `native/AccessibilityAuditTests/main.swift:1477` | S3 | Defect | backlog |
| L249.b | Destructive-text scan matches only a literal `role: .destructive` | Open | `N/NativeConfirmation.swift:114` | S3 | Defect | backlog |
| L249.c | "On my way" hit outset is 16pt vs RN's `hitSlop` of 8 | Open | `N/NativeTodayComponents.swift:434` | S3 | Defect | backlog |
| L249.d | Phase 11 plan still says the Today status row is 44pt | Open | `docs/native-phase-11-implementation-plan.md:3783` | S3 | Defect | doc batch |
| L249.e | iOS 17/18 destructive text and the "On my way" hit-test are unverified | Open | `docs/native-phase-11-device-runsheet.md:184` | S3 | 12.03 | device rows A11B-FR1-1/2 |
| L264.a | Square "link saved" message persists while the user types a new draft | Open | `N/SettingsView.swift:498` | S3 | Defect | backlog |
| L264.b | Leaving Settings drops an unsaved Square draft without a prompt | Open | `N/SettingsView.swift:401` | S3 | Defect | backlog |
| L264.c | Initial-sync backfill runs before the derived-state publish binding | Open | `N/AppStore.swift:5275` | S3 | Defect | backlog |
| L264.d | Square-link check keeps a leading U+FEFF that RN's `.trim()` strips | Open | `N/Domain/NativeInvoicePaymentLinks.swift:97`; `utils/invoiceHelpers.ts:97` | S3 | Defect | backlog (a real native difference; RN is the spec) |
| L267.a | `protectCopiedLegacyFiles` returns silently on a nil enumerator, so the legacy AsyncStorage backup that can hold the G6 residual is never protected | Open | `N/Domain/SnapshotRepository.swift:348` (called at `:276`) | S2 | Defect | **12.00b.2**: treat a nil enumerator as a per-file failure (diagnostic plus journal retry); consistent with the G6 policy |
| L267.b | A `.completeFileProtection` write can throw on a locked relaunch; the journal retries | Open | `N/Domain/SnapshotRepository.swift:237` | S3 | Defect | record (accepted, 11.13) |
| L267.c | Legacy photo backup copies keep default file protection | Open | `N/LegacyDataImporter.swift:1192` | S3 | Defect | backlog |
| L274.a | Phase 11 runsheet does not explain its switch to row tables | Open | `docs/native-phase-11-device-runsheet.md:1` | S3 | Defect | doc batch |
| L274.b | This plan's scope-source sentence (edited by 11.14 in `d18b29c`) read abruptly | Closed (this revision) | "Scope source" paragraph above | S3 | Defect | record |
| L286.1 | Widget/Siri replay markers (`__nativeWidgetStartActionID`/`StopActionID`) sit in session `unknownFields`, are pushed to Supabase inside the job, and RN keeps them forever | Open | `N/NativeWidgetActionReplay.swift:339`; `N/AppStore.swift:5831`; `utils/syncMerge.ts:44` | S2 | Defect | **12.00b.2**: first confirm replay idempotency survives a pull that replaces the job, then strip `__native*` keys from pushed payloads. The test asserts no queued payload carries one |
| L286.2 | `requestDestructive()` re-reads the stored `actionRule` instead of the dialog's `rule` (the I1 failure class) | Open | `N/NativeRecurringInvoicesView.swift:121`; `N/Domain/NativeRecurringInvoices.swift:303` | S3 | Defect | rider (take the rule from the call site) |
| L286.3 | A stale comment says `useAnotherAccount` does not hold `authenticationOperationInFlight` | Open | `N/AppStore.swift:359` vs `:4238` | S3 | Defect | rider |
| L286.4 | "Try cleanup again" cannot reach a pending boundary step, and `signUp`'s immediate-session branch skips the pre-bind retry | Open | `N/RootView.swift:8`; `N/AppStore.swift:4718`, `:4346` | S2 | Defect | **12.00b.2**: surface pending boundary steps in the retry affordance, and route `signUp` through the pre-bind retry |
| L286.5a | `aiProviderKeyIsSaved` ignores the pending AI-key-wipe marker, so Settings can show account B "Saved" for account A's key | Open | `N/AppStore.swift:8968` vs `:8954` | S2 | Defect | **12.00b.2**: gate it like the advisory reads |
| L286.5b | If a boundary step's marker write and its wipe both fail, the pending state lives only in memory. After a relaunch the gates reopen over A's AI key or widget data | Open | `N/AppStore.swift:4830`; `N/Domain/SnapshotRepository.swift:169` | **S1** | Defect | **12.00b.2**: fail closed durably. A step whose marker cannot be written must not let the next owner bind. Add a double-failure-then-relaunch test |
| L286.6 | `signOut`/`deleteAccount` refused mid-switch show their normal failure copy | Open | `N/AppStore.swift:4615`, `:4651` | S3 | Defect | backlog |
| L286.7 | Session-rejected reactivation keeps `verifiedAccountBinding` and deep-link route state (fail-closed today) | Open | `N/AppStore.swift:4185` | S3 | Defect | rider (with L286.4) |
| L286.8 | Contract §17.2, the runsheet I2 row and the roadmap's I2 text omit the poison-item test and the `utils/sync.ts` line range | Open | `docs/native-phase-11-platform-hardening-contract-decisions.md`; `docs/native-phase-11-device-runsheet.md`; `docs/native-ios-migration-roadmap.md` | S3 | Defect | doc batch (12.00b.1 above already specifies both) |
| T1 | Parity "AI Assistant" row still lists the OI-4 known issues that `5f2f397` fixed | Open | `docs/native-parity-matrix.md:126` | S3 | Defect | doc batch (with L205.c) |

**Totals (91 items):**

- **By severity:** S1 2, S2 17, S3 72.
- **By state:** 17 closed, 74 open or accepted.
- **By destination:** 88 go to the defect list and 3 to 12.03.
- **By handling:**

  | Handling | Items |
  |---|---|
  | 12.00b.1 | 1 |
  | 12.00b.2 | 10 |
  | rider | 6 |
  | doc batch | 11 |
  | 12.01 check | 2 |
  | 12.02 | 1 |
  | backlog | 34 |
  | record (accepted) | 7 |
  | record (closed) | 16 |
  | 12.03 row | 3 |

**Stage-A-blocking code items (12.00b):**

- L238, which is I2 (12.00b.1).
- L130 and L286.5b, both S1.
- L74 and L96, one fix.
- L131, L237.d, L267.a, L286.1, L286.4 and L286.5a.

The riders fixed alongside them are L205.a, L205.e, L205.g, L286.2, L286.3 and L286.7.

**Ledger lines that mention minors but get no row**, checked so nothing is dropped:

- **Minors fixed in their own round, not parked:** L60, L73, L94, L129, L177 and L192.
  These are rulings that folded minors into a Phase 11 fix round.
- **Dispatch or review summaries:** L173, L200, L207, L211, L220, L232, L245, L254,
  L261, L262, L277 and L278. Their open items were parked on the lines tabled above.
- **L191:** its four "Phase 12" notes are already device rows CR-6 to CR-9 in
  `docs/native-phase-11-device-runsheet.md`, so they reach 12.03 with that runsheet.
- **L270:** its carries are §1.1.
- **L285 and L289:** rulings. L285 parked the L286 residuals, and L289 keeps the
  Phase 11 workspace.
