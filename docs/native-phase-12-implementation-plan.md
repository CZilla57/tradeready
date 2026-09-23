# Phase 12 — Cutover and Rollback Plan

**Date:** 2026-09-21

**Status:** Ready for charter/characterization; no stage executed, no evidence collected.
Revised 2026-09-22 per [native-phase-10-12-plan-review.md](native-phase-10-12-plan-review.md).

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
`native-phase-7-device-runsheet.md`, and `native-phase-9-device-runsheet.md`.
`native-phase-10-device-runsheet.md` and `native-phase-11-device-runsheet.md` are
created by 10.15 and 11.14. **No Phase 5, 6, or 8 runsheet exists**, and the
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
To be delivered before Phase 12 starts (not yet in the repo):

- Phase 11 monitoring hooks: `N/NativeAnalytics.swift`,
  `N/NativeCrashReporting.swift`, `N/NativePerformanceMetrics.swift` (delivered by
  11.07–11.12), and the app/extension privacy manifests (11.01, 11.09).

## 2. Stage graph and gates

```text
12.00 cutover charter (provisional thresholds, severity, RACI, go/no-go, rollback data decision)
12.03 deferred evidence index (can start in parallel with 12.00; executing rows needs 12.01)
 |- 12.01 release config + store-readiness freeze (SC2, SC4)
 |- 12.02 monitoring/metrics/support instrumentation (E2)
 |        | (12.01, 12.02, 12.03 are Stage A entry prerequisites)
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
   release timing and pausing or removing the version from sale.

**Done when:** provisional thresholds, severities, owners, stage gates, the
rollback data decision, and the exposure-control rule are written and
owner-approved; every later task can cite a single charter source. This task does
not choose metrics the owner has not ratified.

### 12.01 — Release configuration and store-readiness freeze

**Depends on:** 12.00; 11.01–11.14 landed. **Requirements:** SC2, SC4.

**Read:** `N/BuildEnvironment.swift`, `native/Info.plist`,
`N/TradeReadyNative.entitlements`, the release build configurations in
`native/TradeReadyNative.xcodeproj/project.pbxproj`,
`native/run-phase-3-device-preflight.sh`,
`native/run-phase-4-device-preflight.sh`, `app.json` (for the RN values the native
build must match), and the Phase 7–11 release notes.

**Own:** release-configuration edits in the Xcode project/`Info.plist`/
entitlements and new `docs/native-phase-12-release-readiness.md`; the privacy
manifest file (shared with 11.07/11.09) once created.

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

**Done when:** every deferred row from Phases 2–11 appears exactly once with a
stage assignment and an evidence placeholder; unresolved prerequisites are named.

### 12.04 — Stage A: internal TestFlight

**Depends on:** 12.01, 12.02, 12.03. **Requirements:** SA1, SA2, SA3.

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
# Full host regression before any stage
sh native/run-all-domain-tests.sh

# Environment/staging preflight (must fail closed on placeholders/production match)
sh native/run-phase-3-device-preflight.sh
sh native/run-phase-4-device-preflight.sh

# Unsigned compile sanity (does not substitute for a signed/device build)
xcodebuild -project native/TradeReadyNative.xcodeproj -scheme TradeReadyNative -configuration Release -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

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
| 12.00 | all (gates) | Pending | 11.12 (definitions) | Cutover charter + provisional thresholds + RACI + rollback data decision |
| 12.01 | SC2, SC4 | Pending | 12.00, 11.x | Release config + store-readiness + review notes |
| 12.02 | E2 | Pending | 12.00, 11.07-11.12 | Monitoring/metrics/support |
| 12.03 | enables SA2/SA3, E1-E3 | Pending | phase runsheets (parallel with 12.00) | Deferred-evidence index incl. Phase 5/6/8 rows |
| 12.04 | SA1, SA2, SA3 | Pending | 12.01-12.03 | Stage A run + evidence + native baselines |
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
