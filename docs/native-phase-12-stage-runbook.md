# Native Phase 12 — stage runbook (12.04, 12.06 rehearsal, 12.05, 12.07, 12.08)

Prepared 2026-09-27 by task 14 (stage prep), on branch native/phase-12 at commit
`2bcfc07`. This runbook prepares the five owner-run stages; **it executes none of
them.** The owner's instruction (verbatim, task 14 brief): "run 12.04, 12.05, the
12.06 rehearsal, 12.07, or the 12.08 sign-off [is NOT allowed without explicit
instruction]. For those, prepare everything (checklists, scripts that no-op without
credentials, evidence templates, the exact commands) and stop with a readiness
report." This document is that preparation.

`N/` means `native/TradeReadyNative/`. `CH` is
[the cutover charter](native-phase-12-cutover-charter.md); `PL12` is
[the implementation plan](native-phase-12-implementation-plan.md); `EI` is
[the evidence index](native-phase-12-evidence-index.md); `MON` is
[the monitoring doc](native-phase-12-monitoring.md); `RB` is
[the rollback playbook](native-phase-12-rollback-playbook.md); `RR` is
[the release readiness doc](native-phase-12-release-readiness.md).

## 0. Stage order, single-person risk, and the evidence rule

```text
12.04 Stage A (internal TestFlight)
  -> 12.06 rehearsal (steps 5-6: native -> Expo -> native, staffing)
     -> 12.05 Stage B (limited external beta)
        -> 12.07 Stage C (production cutover)
           -> 12.08 exit verification and closeout
```

Stage B cannot enter before the 12.06 rehearsal is recorded (CH §4.4; it is a Stage B
entry gate, not merely a Stage A follow-on). Stage C cannot enter before Stage B
exits and the Expo rollback candidate is processed (CH §4.6). 12.08 depends on
12.04–12.07 (PL12 §3, 12.08).

**Single-person risk (CH §1).** Decision D5: the owner holds every role (owner,
release engineer, backend, support, on-call). Nobody else can pause a release,
remove the app from sale, answer a user or run the rollback, and there is no cover
when the owner is away. Every stage below inherits CH §1's operating rules
verbatim: watch days (a release, resume, invite wave or rollback submission only
when the owner can watch the dashboards twice that day and once the next); no
unwatched phased-release days; plan the calendar first; freeze non-critical work
during exposure; pre-stage the rollback; write the decision-log row before acting;
keep account access recoverable. This runbook does not restate the rules again in
each section — apply them throughout.

**The evidence rule (binding on every stage below).** Host checks, simulator runs
and generic or unsigned builds never substitute for device, TestFlight or store
evidence (CH §4; global constraints). A stage preflight `READY` line means the
checks this repository can run offline passed — it is not a go decision, and it
does not close a device row. No parity-matrix row moves to `Verified` from any
output of this runbook (CH §4.7; `docs/native-parity-matrix.md` "Evidence required
for `Verified`").

## 1. Readiness snapshot at 2026-09-27 (`2bcfc07`)

These blockers recur across every stage's entry-gate checklist below; they are
recorded once here and cited by ID.

**Update 2026-09-29 (decision-log rows 8 to 12).** `CH-DRAFT` is cleared (charter approved). `OI-1` is decided and the manifest edit is applied; only entering the labels in App Store Connect remains, at Stage C entry. `OI-2` is reported cleared by the owner and unverified here. `VER-1` is half cleared: native N is 2.0.0, and the live version L is still unconfirmed. `P12-012` is being fixed on the Expo side (branch `expo/e1-native-run-guard`) and stays open until that fix is built into R. The rows and the "Blocking IDs" lists below predate these decisions; read them with this note.

| ID | What is open | Blocks | Who clears it | Source |
|---|---|---|---|---|
| CH-DRAFT | The charter's Status line reads "DRAFT — not owner-approved" | Every stage: "no stage gate cites an unapproved threshold" (CH, top) | Owner approves the charter and logs it in CH §9 | `CH` line 3 |
| SIGN-1 | No signed-in Xcode account; the wildcard profile lacks the `TradeReadyWidgets` App Group | Stage A entry (every signed, device, TestFlight and archive row) | Owner signs in at Xcode › Settings › Accounts with the owner's Apple team; re-run the signed Release build | `CH §4.1`; `RR §1` |
| VER-1 | Native `MARKETING_VERSION` (`1.0`) is below the live Expo version (`app.json` says `1.2.1`, unconfirmed live) | Stage A upload; 12.06 version numbering | Owner confirms the live App Store version; a `project.pbxproj` edit under a dated ruling sets the scheme | `CH §4.1`; `RR §2` |
| OI-1 | A privacy-label **proposal** exists (`RR §5`), but the owner has not approved it and the labels are not entered in App Store Connect | Stage A entry — the *decision* itself, per `CH §4.1` (not only "labels entered," which is Stage C entry) | Owner approves the `RR §5` proposal (or amends it) and the matching `PrivacyInfo.xcprivacy` edit before Stage A; enters the labels in App Store Connect before Stage C | `CH §4.1`; `RR §5` |
| RESEND | The G1 waiver's email-only alert path depends on the production Worker's `RESEND_API_KEY` secret being set; this repo can only confirm the code path fails silently closed without it, never whether the secret is actually set | G1 waiver condition (`CH §5.1`); Stage A entry (the waiver's conditions are checked at 12.01) | Owner runs `wrangler secret list` from `backend-workers/` (where `wrangler.toml` lives) against the production Worker and confirms `RESEND_API_KEY` is present (name only) | `CH §5.1`; `RR §10` |
| OI-2 | Sentry project `tradeready-ios` (org `tradeready-3r`) does not exist | Stage A entry (TH-8's source; rows CR-1 to CR-9; `P12-M-2`) | Owner creates it | `CH §4.1`; `MON §1` |
| D4 (STG) | No trusted isolated staging; `https://staging.invalid` stays | Every STG row; SA3; **Stage A exit** per `CH §4.1` (the charter's gate is unchanged by this task) — but the offline stage preflight FAILs its backend-placeholder check for every `--stage`, including `A`, as long as `TRADEREADY_BACKEND_URL` is the placeholder, so D4 is a *practical* Stage A entry blocker today even though the charter gates it at exit | Owner provisions staging | `CH §4.1`; `run-phase-12-stage-preflight.sh` backend-placeholder check |
| AGG-1 | The aggregate's final `backend-workers` `npm test` step has no committed test script | The aggregate's exit code; SA3's full regression, so Stage A exit; 12.08 | Owner or the backend agent (Phase 12 does not edit `backend-workers/`) | `CH §4.1` |
| R59 | No committed production build configuration exists (Debug=development, Release=staging) | Stage A/C upload (a production-configured build must exist to archive against, or the owner must rule that Stage A uploads the staging-configured Release build) | Owner rules between adding a Production configuration or re-pointing Release once staging exists, and who supplies the production values; no agent adds or edits a build configuration | `RR §3.1`, `RR` front matter |
| P12-012 (R43) | Open **S1**: the existing Expo build's rollback rehearsal pushes a stale pre-upgrade `__syncQueue` before its pull, which can overwrite newer native rows after a rollback under last-writer-wins | Stage A entry (CH §2 rule 2: an open S1 blocks unless the owner records a severity change or ruling); gates `EXPO-RB`, `P12-RB-1…3/7`, playbook §2.2 condition 4 | Owner rules on R43 and logs a `CH §9` row whose Decision cell is **exactly** `P12-012 ruled: R43` (nothing else in that cell — the reason goes in the Evidence cell) with Decider **exactly** `owner`, per `CH §9`'s strict grammar and worked example; then the playbook §5.3 build on the Expo release branch | `CH §10` row `P12-012`; `CH §9` marker grammar; `RB` §0 "Open" table |
| SUPA-URL | **Pre-existing (since `2bb8dd5`), verified S2, already recorded** — not a new finding. The committed Release build's `TRADEREADY_SUPABASE_URL` and `TRADEREADY_SUPABASE_PUBLISHABLE_KEY` match the production project (`RR §3.2`, `RR §3.3`) while `TRADEREADY_ENVIRONMENT=staging`; already flagged in `docs/native-phase-4-device-runsheet.md:47-52,58-60` and BLOCKed today by `native/run-phase-4-device-preflight.sh:285-292` (it will FAIL once a distinct staging Supabase project exists). Today a Release build's auth (sign-in, sign-up, password change) and Data API reads go to **production** (unguarded by design, `N/BuildEnvironment.swift:114-116`); Data API writes are blocked (`N/NativeSupabasePush.swift` `productionWriteBlocked`) and Worker calls resolve to the placeholder host. S2, not S1: no Data API or Worker write reaches production and there is no cross-account exposure | Stage A entry via **R59**, not a `CH §10` defect-list row (this task does not add one) — the offline preflight FAILs the Supabase-match checks (`run-phase-12-stage-preflight.sh`'s backend/Supabase production-match lines) regardless of any ruling; an R59 ruling to upload the staging-configured Release anyway must say so explicitly, or new installs get this configuration | Owner: fold this into the R59/D4 ruling (the Release Supabase URL and key move with staging, D4), or record a dated severity/ruling decision in `CH §9` if uploading the current configuration anyway | `docs/native-phase-4-device-runsheet.md:47-60`; `native/run-phase-4-device-preflight.sh:285-300`; `RR §3.2, §3.3`; `run-phase-12-stage-preflight.sh --stage A` FAIL lines |
| EXPO-RB | The Expo rollback candidate does not exist; the §5.3 Expo-side change (drain/clear the stale queue before any pull) is not built | 12.06 rehearsal; Stage B entry (CH §4.4) | Owner assigns who builds the §5.3 change on the Expo release branch, then builds/uploads R | `RB` §0, §4, §5.3 |
| REHEARSAL | The 12.06 rehearsal has not run; `EI` §24 "Stage A" and "Stage B" both read "No run recorded yet." | Stage B entry (CH §4.4); Stage C entry transitively | Owner runs the rehearsal (§3 below) after Stage A produces a TestFlight build | `RB` §8; `EI` §24 |

## 2. 12.04 — Stage A: internal TestFlight

### 2.1 Entry gate checklist (CH §4.2; `PL12` 12.04 "Depends on": 12.00b, 12.01, 12.02, 12.03)

| # | Criterion | Source | Current state (2026-09-27) | Evidence | Owner | Action needed |
|---|---|---|---|---|---|---|
| 1 | Charter is owner-approved (decision-log row), thresholds provisional | `CH §4.2` bullet 1 | **Not met** — Status line reads DRAFT | `CH` line 3 | owner | Approve the charter; log the approval in `CH §9` |
| 2 | 12.00b done: I2 (12.00b.1), the ten 12.00b.2 items and the G2 editor (12.00b.3) fixed with host evidence and a clean review; no open S1/S2 unless a logged severity change | `CH §4.2` bullet 2 | **Met** for the named items — every `12.00b.1`/`12.00b.2` defect-list row is `Fixed`, confirmed by `run-phase-12-stage-preflight.sh`'s defect-list checks; `P11-G2` records the tax-settings editor built (12.00b.3) | `CH §10` sections `12.00b.1`, `12.00b.2`; `EI` row `P11-G2` | — | None on this criterion. (Separately, `P12-012`, a "New in Phase 12" S1, is still open — see row 2a) |
| 2a | No open S1/S2 anywhere on the defect list unless the owner logged a severity change (`CH §2` rule 2) | `CH §2` rule 2; `CH §10` | **Not met** — `P12-012` (S1) is open; no `CH §9` row yet has a Decision cell that is exactly `P12-012 ruled: R43` (see `CH §9`'s strict grammar and worked example) | `CH §10` row `P12-012` | owner | Rule on R43 and log a `CH §9` row whose Decision cell is exactly `P12-012 ruled: R43` (reason in the Evidence cell) with Decider exactly `owner`, or fix the Expo-side §5.3 change before Stage A |
| 3 | 12.01 done: SIGN-1 and VER-1 cleared, OI-1 decision recorded, production configuration verified against the live Expo build, SC4 retention assertion recorded | `CH §4.2` bullet 3 | **Not met** — SC4 retention assertion recorded (`run-legacy-migration-retention-tests.sh`); SIGN-1 and VER-1 are open; OI-1 is only a proposal, not owner-approved (`RR §5`); no production build configuration exists (R59); SUPA-URL (pre-existing, S2) is unresolved | `RR §1, §2, §3.1, §5, §9, §14` | owner | Sign in to Xcode (SIGN-1); confirm the live version and set the scheme (VER-1); approve the OI-1 proposal; rule on R59; fold SUPA-URL into the R59/D4 ruling or record a severity decision |
| 4 | 12.02 done: every TH row has a live-or-runnable source and an alert route; OI-2 cleared and the stage build carries its Sentry DSN; the support export is privacy-safe; the dry run produced the expected signals | `CH §4.2` bullet 4 | **Partly met** — every TH row has a runnable source and the dry run produced the expected signals (`MON §10`); OI-2 (the Sentry project) does not exist, so no stage build can yet carry a live DSN | `MON §1, §2, §10`; `CH §4.1` row OI-2 | owner | Create the Sentry project `tradeready-ios` (org `tradeready-3r`); supply `TRADEREADY_SENTRY_DSN` at build time for the stage build (`REL+KEYS`) |
| 5 | 12.03 done: the evidence index exists, Stage A rows are tagged, D4 is recorded | `CH §4.2` bullet 5 | **Met** — `EI` exists with every row tagged A/A-B/B/C/X; D4 is recorded as a hard blocker | `EI §1–§7` | — | None |
| 6 | Host regression: every native runner passes under `TZ=America/Phoenix`; the unsigned and the signed Release builds succeed; the AGG-1 state is recorded | `CH §4.2` bullet 6 | **Partly met** — prior tasks' focused runners and unsigned compiles pass; the aggregate's committed state stops at the `backend-workers` step (AGG-1, expected); the signed build fails on SIGN-1 | Prior task reports; `CH §4.1` row AGG-1 | owner (AGG-1); owner (SIGN-1) | Resolve AGG-1 (backend `npm test` script) or accept it as recorded; clear SIGN-1 for the signed build |
| 7 | The G6 retention policy (`CH §5.4`) is approved before any SA2 upgrade run | `CH §4.2` bullet 7 | **Not met** — provisional, not yet in `CH §9`'s owner-approval row | `CH §5.4`; `CH §0` | owner | Approve G6 in the same decision-log row as the charter |
| 8 | Team accounts and synthetic data only (SA1); no real customer data prepared | `CH §4.2` bullet 8 | **N/A until the stage runs** — no accounts are prepared yet | — | owner | Prepare team accounts and synthetic data before running |

**Readiness line: Entry criteria met: no.** Blocking IDs: `CH-DRAFT`, `P12-012`
(R43), `SIGN-1`, `VER-1`, `OI-1`, `RESEND`, `R59`, `SUPA-URL`, `OI-2`,
`D4` (the charter gates D4 at Stage A *exit* per `CH §4.1`; it is listed here because
the offline preflight's backend-placeholder check fails closed for every stage,
`A` included, while `https://staging.invalid` stays), `AGG-1`, G6 approval (row 7).

Real-repo preflight tail (`sh native/run-phase-12-stage-preflight.sh --stage A`,
2026-09-27, re-run after task 14's fourth review round). This block is the record:
it shows every `FAIL` and `OWNER` line the run printed, with the `PASS` lines above
them left out. Re-run the command from the repository root for the full output.

```
FAIL: backend URL is not the placeholder (staging.invalid/local host)
FAIL: Supabase URL matches the production project outside a production build
FAIL: Supabase publishable key matches the production key outside a production build
FAIL: charter is owner-approved (Status line reads: **Status: DRAFT — not owner-approved.** Written 2026-09-25 on branch native/ph)
FAIL: defect list: no open S1/S2 blocks stage entry (open, no recorded ruling: P12-012)
FAIL: production build configuration decision is recorded (R59) — owner must rule on a Production configuration or re-pointing Release; see docs/native-phase-12-release-readiness.md
OWNER SIGN-1: Xcode account signed in and the signed Release build carries the App Group — not checkable offline
OWNER VER-1: the live App Store version is confirmed and the native scheme is set above it — not checkable offline
OWNER OI-2: the Sentry project tradeready-ios (org tradeready-3r) exists — not checkable offline
OWNER TF-INT: the internal TestFlight build is uploaded and processed — not checkable offline
OWNER OI-1: the App Store privacy-label edit is approved (decision recorded; labels entered at Stage C) — not checkable offline
OWNER RESEND: the production Worker's RESEND_API_KEY secret is confirmed present (wrangler secret list; G1 waiver condition) — not checkable offline

NOT READY for stage A: 6 local check failure(s).
```

### 2.2 Exact commands, in run order

1. **Environment/staging preflights** (`PL12` §4; must fail closed on
   placeholders/production match — run before the stage preflight, since the
   stage preflight's own staging checks build on the same facts):
   ```sh
   sh native/run-phase-3-device-preflight.sh
   sh native/run-phase-4-device-preflight.sh
   ```
   Today `run-phase-4-device-preflight.sh` BLOCKs on SUPA-URL (see §1); it FAILs
   instead once a distinct staging Supabase project exists (D4).
2. **Offline stage preflight** (repeat after any fix):
   ```sh
   sh native/run-phase-12-stage-preflight.sh --stage A
   ```
   Today's real-repo run is non-zero — its `FAIL` and `OWNER` lines are pasted in
   §2.1 above, under the readiness line.
   Do not proceed past a `FAIL` line by weakening the check; fix the underlying
   blocker.
3. **Host regression** (`PL12` §4):
   ```sh
   TZ=America/Phoenix sh native/run-all-domain-tests.sh
   ```
4. **Unsigned compile sanity** (`PL12` §4; does not substitute for the signed
   build in step 5):
   ```sh
   xcodebuild -project native/TradeReadyNative.xcodeproj -scheme TradeReadyNative \
     -configuration Release -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
   ```
5. **Owner action — SIGN-1.** Xcode › Settings › Accounts, sign in with the
   owner's Apple team. Then:
   ```sh
   xcodebuild -project native/TradeReadyNative.xcodeproj -scheme TradeReadyNative \
     -configuration Release -destination 'generic/platform=iOS' -allowProvisioningUpdates build
   ```
   Confirm `TradeReadyWidgets.appex` is embedded and both targets' profiles carry
   `group.com.gettradereadyapp.tradeready`.
6. **Owner action — VER-1.** App Store Connect › the app record › App Store tab:
   read the live version number. Then, under a dated ruling, edit
   `native/TradeReadyNative.xcodeproj/project.pbxproj` to set `MARKETING_VERSION`
   and `CURRENT_PROJECT_VERSION` above it on both targets (`RR §2`'s proposed
   scheme: N = `2.0.0`).
7. **Owner action — OI-1.** Review and approve (or amend) the `RR §5` privacy-label
   proposal, and approve the matching `PrivacyInfo.xcprivacy` edit. Entering the
   labels themselves in App Store Connect is a Stage C action.
8. **Owner action — RESEND.** Confirm the production Worker's secret (name only),
   run from `backend-workers/` (where `wrangler.toml` lives — from the repository
   root `wrangler` finds no config):
   ```sh
   cd backend-workers && wrangler secret list
   ```
   Never paste the value anywhere; the owner records only that it is present.
9. **Owner action — OI-2.** sentry.io › org `tradeready-3r` › Create Project ›
   platform iOS, name `tradeready-ios`. Record the DSN in the owner's own secret
   store, never in this repository.
10. **Owner action — D4.** Provision the trusted isolated staging backend
    (Supabase project/branch, staging R2 buckets, deployed staging Worker).
11. **Owner action — R59 ruling.** Decide: add a new Production build
    configuration, or re-point Release once staging exists. Record the ruling as
    one line in `RR` reading exactly `Production configuration decision: <what
    was decided> ruled: R59`, with a real decision filled in where `<what was
    decided>` is shown and nothing at all after `R59` on that line — the
    preflight requires the line to end there. The preflight reads this decision
    from `RR` only: R59 has no defect-list row, so there is no `CH §9` ruling row
    in the `<D> ruled: R<n>` form for it. Log it in `CH §9` as an ordinary
    decision row as well (`CH §1`: the decision-log row comes before acting);
    the preflight does not read that row. The preflight fails while the `RR` line
    still holds any `<...>` placeholder (a `<` or `>` with a space just inside
    it, as in a comparison like `p95 < 800 ms`, is not one). To withdraw the
    decision, add a later line to `RR` that contains "revoked" and names the
    decision or R59 — for example `Production configuration decision: revoked:
    R59` — which re-blocks Stage A/C until a new decision line follows it
    (`CH §9`).
12. **Owner action — SUPA-URL.** Fold this into the R59/D4 ruling above (the
    Release Supabase URL and key move with staging once D4 exists), or record a
    dated severity/ruling decision in `CH §9` if the current configuration ships
    anyway. Never edit the build setting directly to "fix" the match; the fix is
    provisioning D4 and repointing it there.
13. **Dry-run the upload helper** (repeat until every earlier step is done; this
    step never uploads on its own):
    ```sh
    sh native/phase-12-testflight-upload.sh --version 2.0.0 --build <NEXT_BUILD_NUMBER>
    ```
    Read the printed archive/export commands; they are not run by this call.
14. **Owner action — archive and upload (Stage A build).** Only once SIGN-1, VER-1
    and the production/staging configuration are settled, and only as the owner:
    ```sh
    sh native/phase-12-testflight-upload.sh --version 2.0.0 --build <NEXT_BUILD_NUMBER> \
      --execute --i-am-the-owner
    ```
    with `ASC_KEY_ID`, `ASC_ISSUER_ID` and `ASC_KEY_PATH` read from the owner's own
    secret store into the environment immediately before this one command — never
    written to a file in this repository or left set afterward.
15. **Owner action — App Store Connect › TestFlight › Internal Testing.** Wait
    until the build shows "Processed"; add the internal team group; record the
    exact build number and profile in the evidence template below.
16. **Owner action — SA2 upgrade run.** Physical device: install the current App
    Store Expo build, then install the Stage A build over it with no delete.
    Verify every canonical collection, owner binding, photo adoption, App Group
    state and the migration journal; verify pending Expo local notifications are
    reconciled, not duplicated; run the `P12-3B-1`/`P12-3B-2` subscription and
    Sign in with Apple continuity checks (`EI §23`).
17. **Owner action — run every Stage-A-eligible `EI` row** and record actual
    results in `EI §23`/§24 (below).
18. **Owner action — capture native baselines** (PERF-1, 2, 5, 6, 7, 8; crash-free
    sessions) from the runs above, for the Stage B re-ratification.

### 2.3 Evidence template (append to `EI §24`, "### Stage A (12.04)")

```
Run <N>, <DATE>
Build: <NATIVE_VERSION> (<NATIVE_BUILD>)   Profile: TestFlight internal
Devices/OS: <MODEL> / iOS <VERSION>[, ...]
Accounts (aliases only): <ALIAS1>, <ALIAS2>, ...
Environment: REL (staging-configured) | REL+KEYS
Rows run (ID: result): <P2-P1: pass>, <P2-P2: pass>, ... <one line per row, or a
  reference to the filled-in EI rows themselves>
Native baselines: launch <cold/warm ms>, crash-free sessions <%>, sync error rate <%>,
  migration timing <s>
Defects raised: <P12-... or none>
Rows moved to Stage B (charter §4.3, owner's log entry): <IDs, or none>
Timing: <upload to processed>, <SA2 upgrade duration>
```

The stage preflight reads this template, and the Stage B and Stage C templates in §4.3
and §5.3, to learn each one's `<...>` placeholder tokens: a run record in `EI §24` that
still holds any of them counts as unfilled, and fails the next stage's preflight. Keep
each template heading's quoted `"### Stage …"` section name as it is; if the preflight
cannot find a template, it fails that check closed.

### 2.4 Stop triggers (CH §4.8; who decides)

Any of these pauses Stage A (no new invites/no resume is not applicable pre-launch,
but the equivalent is: stop distributing new builds and open the rollback decision
the same day):

- any open S1, or a confirmed privacy or cross-account exposure;
- TH-1, TH-2, TH-5 or TH-9 above zero;
- TH-8 below its floor for 24 hours with the minimum sessions met, or a core-flow
  crash reproduced on two devices;
- TH-3: two or more users unrecovered for 24 hours with the same code;
- a 429 blocker as `CH §5.5` defines it.

**Who decides:** the owner (D5, single-person risk). The decision-log row uses the
format in `RB §2.2`. At Stage A there is no live app to roll back from (no cutover
yet); "rollback" here means: stop the TestFlight build, fix forward, and do not
proceed to Stage B until resolved.

### 2.5 Stage-owner prompt (`PL12` §5, filled in for 12.04)

> Execute **stage 12.04 only** from `docs/native-phase-12-implementation-plan.md`.
> Read the charter (`docs/native-phase-12-cutover-charter.md`), the evidence index
> and `docs/native-device-test-runsheet.md` plus the Phase 2/3 device matrices
> first. Confirm the entry gate in `docs/native-phase-12-stage-runbook.md` §2.1 is
> actually satisfied; if not, stop and report the blocker rather than
> approximating it. Do not substitute production for missing isolated staging, do
> not change `https://staging.invalid` or any production-matched Supabase value to
> pass a preflight, and do not mark any row `Verified` without the full evidence
> set (test name, RN oracle, device/OS, screenshot/output comparison). Record
> actual results, timings, build numbers and unresolved findings; separate a
> blocked gate from a passed one. Preserve canonical business data and legacy
> migration code. Return the tasks executed, evidence artifacts with exact paths,
> requirement IDs covered (SA1–SA3), unresolved S1/S2 findings, and Stage B's
> (and the 12.06 rehearsal's) readiness.

### 2.6 Readiness line

**Entry criteria met: no.** Blocking IDs: `CH-DRAFT`, `P12-012` (R43), `SIGN-1`,
`VER-1`, `OI-1`, `RESEND`, `R59`, `SUPA-URL` (via R59, not a `CH §10` row), `OI-2`,
`D4` (charter-gated at exit; the offline preflight fails on it at entry too — see §1),
`AGG-1`, G6 approval. See §2.1's readiness line for the full per-criterion detail.

## 3. 12.06 rehearsal (steps 5–6): native → Expo → native

### 3.1 Entry gate checklist (`PL12` 12.06 "Depends on": 12.00 rollback data decision, 12.02, 12.04 native TestFlight build; CH §4.4 lists it as a Stage B gate)

| # | Criterion | Source | Current state (2026-09-27) | Evidence | Owner | Action needed |
|---|---|---|---|---|---|---|
| 1 | Charter §6 rollback data decision approved | `PL12` 12.06 "Depends on"; `CH §0` | **Not met** — provisional, charter is DRAFT | `CH §6`; `CH §0` | owner | Approve with the charter |
| 2 | Native half of the rollback data decision built with host tests (queue drain before advisory; journal adoption rule) | `CH §4.4` bullet 3 | **Met** — built in 12.06, host-tested (`feat(native): phase 12.06 - rollback readiness drain and journal adoption rule`) | `RB §0` "Built with host tests"; `CH §10` row `P12-011` Fixed | — | None |
| 3 | A native TestFlight build exists to roll back from | `PL12` 12.06 "Depends on" | **Not met** — TF-INT not uploaded (needs SIGN-1, VER-1) | `EI §5` row TF-INT | owner | Complete 12.04 through upload |
| 4 | The Expo release branch exists with the §5.3 change (E-1 detect/clear/hold before any pull), and the rollback candidate R is uploaded and processed | `RB` §0, §4, §5.3; `CH §10` row `P12-012` | **Not met** — no Expo release branch exists by name; §5.3 not built | `EI §5` row EXPO-RB | owner | Assign the Expo-side builder; build and upload R (`RB §10.2`) after ruling R43 |
| 5 | 12.02 monitoring live enough to read the rehearsal's support reports | `PL12` 12.06 "Depends on" | **Partly met** — support report (v4) works on host/device without OI-2; Sentry signals need OI-2 | `MON §4`; `EI` row P12-M-1 | owner | OI-2 not required to rehearse (support report is enough), but improves TH-2/TH-3 visibility |
| 6 | Team account A with synthetic customers `RB-C1`…`RB-C9` and job `RB-J1`; a second iPhone (or a plan to reuse one, per `RB §8.1`) | `RB §8.1` | **N/A until scheduled** | — | owner | Prepare before the rehearsal date |

**Readiness line: Entry criteria met: no.** Blocking IDs: `CH-DRAFT`, `SIGN-1`,
`VER-1`, `EXPO-RB` (and its `P12-012`/R43 precondition).

### 3.2 Exact commands, in run order

1. **Environment/staging preflights and offline stage preflight** (`PL12` §4):
   ```sh
   sh native/run-phase-3-device-preflight.sh
   sh native/run-phase-4-device-preflight.sh
   sh native/run-phase-12-stage-preflight.sh --stage rehearsal
   ```
2. Complete 12.04 through step 15 (a processed native TestFlight build N).
3. **Owner action — build the Expo release branch's §5.3 change** (drain/clear the
   stale queue before any pull; `RB §5.3`). Start it only after accepting `RB §5.3` as
   final, which comes after the Phase 12 final-review fix wave's re-review (`RB §5.3`,
   "When the build may start"). Then:
   ```sh
   # In a separate clone or worktree, on the Expo release branch (RB §4).
   git switch <EXPO_RELEASE_BRANCH>
   # Set expo.version in app.json to <R_VERSION> (above N; RB §3.2) and commit it.
   ```
4. **Unsigned compile sanity, then dry-run the upload helper, for the
   rehearsal's second native build (N2)** (repeat before actually building N2):
   ```sh
   xcodebuild -project native/TradeReadyNative.xcodeproj -scheme TradeReadyNative \
     -configuration Release -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
   sh native/phase-12-testflight-upload.sh --version <N2_VERSION> --build <N2_BUILD>
   ```
5. **Owner action — build and upload the Expo rollback candidate R** (`RB §10.2`,
   owner-gated, placeholders only):
   ```sh
   export EXPO_TOKEN="$(<SECRET_STORE_READ_COMMAND> <EXPO_TOKEN_NAME>)"
   npx eas-cli@<EAS_CLI_VERSION> build:version:get --platform ios
   npx eas-cli@<EAS_CLI_VERSION> build:version:set --platform ios
   npx eas-cli@<EAS_CLI_VERSION> build --platform ios --profile production --non-interactive
   npx eas-cli@<EAS_CLI_VERSION> submit --platform ios --profile production --id <EAS_BUILD_ID> \
     --non-interactive
   ```
   Wait in App Store Connect › TestFlight until R shows Processed. Do not add it to
   a version for review.
6. **Owner action — rehearse** per `RB §8.2` steps 1–18 (T0: Expo L → native N; T1:
   native N → Expo R; T2: Expo R → native N2), then `RB §8.2`'s `P12-RB-5` (SC4
   clean-install check) and the signed-out variant, then `P12-RB-7` (`RB §8.2`
   D1–D6), then the L→R check (`RB §8.2` U1–U3). Use the exact archive/export commands
   from `RB §10.1` for N2 via:
   ```sh
   sh native/phase-12-testflight-upload.sh --version <N2_VERSION> --build <N2_BUILD> \
     --execute --i-am-the-owner
   ```
   (owner-run only, credentials from the owner's secret store, as in §2.2 step 9).
7. **Owner action — staffing decision-log row** (`RB §8.4`): watch days for every
   exposure step, planned pauses, confirmation the playbook and R are at hand.

### 3.3 Evidence template (`RB §8.3`, copied here; summary goes on `EI §23` rows `P12-RB-1` to `P12-RB-7`)

```
Rehearsal run <RUN_ID>   date <DATE>   device <MODEL> / iOS <OS_VERSION>   account alias <TEAM_ACCOUNT_ALIAS>

Versions (L < N < R < N2)
| Build | Version | Build number | Source | Processed at |
| L  | <L_VERSION>  | <L_BUILD>  | App Store  | —      |
| N  | <N_VERSION>  | <N_BUILD>  | TestFlight | <TIME> |
| R  | <R_VERSION>  | <R_BUILD>  | TestFlight | <TIME> |
| N2 | <N2_VERSION> | <N2_BUILD> | TestFlight | <TIME> |

Steps 1-18, S1-S5, D1-D6, U1-U3: time, expected (RB §8.2), observed, pass/fail, sign-in asked?,
  support-report codes (see RB §8.3 for the full per-step table — reproduced there, not
  duplicated here).
Readiness check results (steps 5, 6, 17; S2; D2, D6).
Transition timings T0/T1/T2; manual steps.
Defects raised: <P12-... or none>.
Staffing decision-log row: <CH §9 row #>.
```

### 3.4 Stop triggers

The rehearsal runs on synthetic/team data only, so `CH §4.8`'s production stop
triggers do not apply directly. The rehearsal's own stop condition (`RB` rules):

- **any failed step becomes a defect row** (`CH §2` rule 4); it is never waived
  silently — decide fix-forward on the rehearsal script itself, or accept a
  residual per `RB §5.6`;
- if `P12-012`'s pattern reproduces (the signed-out variant shows `RB-C8` at ` s0`,
  not ` s1`), the rehearsal has proven the Expo-side §5.3 change is not built
  correctly — **do not proceed to Stage B**; this is the exact condition CH §4.4
  gates on.

**Who decides:** the owner (D5).

### 3.5 Stage-owner prompt (`PL12` §5, filled in for the 12.06 rehearsal)

> Execute **the 12.06 rehearsal (plan step 5) and staffing (step 6) only** from
> `docs/native-phase-12-implementation-plan.md`. Read the charter, the rollback
> playbook (`docs/native-phase-12-rollback-playbook.md`, especially §5.3, §8) and
> the evidence index first. Confirm the entry gate in
> `docs/native-phase-12-stage-runbook.md` §3.1 is actually satisfied, in
> particular that the Expo release branch's §5.3 change is built and that a
> processed native TestFlight build exists; if not, stop and report the blocker.
> Use only team accounts and the synthetic customers `RB-C1`…`RB-C9`. Record
> actual version numbers, timings and the outcome of every checklist item in
> `docs/native-phase-12-rollback-playbook.md` §8.2, including the signed-out
> variant and `P12-RB-7`; a step that does not match its expected result is a
> defect (`P12-…`), not a note. Never delete legacy migration code or the RN
> source files as part of this exercise (that would defeat the rehearsal itself).
> Return the versions used, every evidence-index row updated, defects raised, and
> Stage B's readiness — in particular whether `P12-012`'s pattern reproduced.

### 3.6 Readiness line

**Entry criteria met: no.** Blocking IDs: `CH-DRAFT`, `SIGN-1`, `VER-1`, `EXPO-RB`
(and `P12-012`/R43).

## 4. 12.05 — Stage B: limited external beta

### 4.1 Entry gate checklist (CH §4.4; `PL12` 12.05 "Depends on": 12.04 exit gate, 12.06 rehearsal recorded, thresholds re-ratified, Beta App Review approval)

| # | Criterion | Source | Current state (2026-09-27) | Evidence | Owner | Action needed |
|---|---|---|---|---|---|---|
| 1 | Stage A exit met (decision-log row) | `CH §4.4` bullet 1 | **Not met** — Stage A has not run; `EI §24` "Stage A" reads "No run recorded yet." | `EI §24` | owner | Complete §2 above |
| 2 | Owner re-ratified TH-1 to TH-12 with Stage A baselines; OI-3 rate-limit facts recorded | `CH §4.4` bullet 2 | **Not met** — no Stage A baselines exist yet | `CH §3`; `CH §5.5` | owner | Re-ratify after Stage A |
| 3 | 12.06 gate: playbook written, native half built, rehearsal recorded with no data loss and real version numbers | `CH §4.4` bullet 3 | **Not met** — playbook and native half done; rehearsal not run | §3 above | owner | Complete §3 above |
| 4 | Beta App Review approved the external TestFlight build (allow lead time) | `CH §4.4` bullet 4 | **Not met** — no external build exists yet | `EI §5` row BAR | owner | Submit for Beta App Review once a Stage B build exists |
| 5 | The Expo release branch builds green (SB3) | `CH §4.4` bullet 5 | **Not met** — branch does not exist yet | `EI §5` row EXPO-RB | owner | Part of §3 above |
| 6 | Cohort covers SB1 (new, established, offline-heavy, Stripe, booking, recurring-work, iPad) plus one two-device mixed-client user; consent per legal disclosures | `CH §4.4` bullet 6 | **Not met** — not recruited | `EI §5` row COHORT | owner | Recruit per `CH §1` |
| 7 | Support intake and 12.02 dashboards live; owner's watch days for the window planned | `CH §4.4` bullet 7 | **Not met** — dashboards need OI-2; intake channel proposed, not confirmed live | `MON §7`; `CH §1` | owner | Create OI-2; confirm the intake channel; plan watch days |

**Readiness line: Entry criteria met: no.** Blocking IDs: everything under §2 and
§3 above, plus `BAR`, `COHORT`, `OI-2` (for dashboards).

### 4.2 Exact commands, in run order

1. **Offline stage preflight** (fails today because Stage A has no recorded run):
   ```sh
   sh native/run-phase-12-stage-preflight.sh --stage B
   ```
2. **If Stage B needs a new build** (not a reuse of the Stage A build): environment
   preflights, unsigned compile, then dry-run the upload helper (`PL12` §4):
   ```sh
   sh native/run-phase-3-device-preflight.sh
   sh native/run-phase-4-device-preflight.sh
   xcodebuild -project native/TradeReadyNative.xcodeproj -scheme TradeReadyNative \
     -configuration Release -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
   sh native/phase-12-testflight-upload.sh --version <VERSION> --build <BUILD>
   ```
3. **Owner action — App Store Connect › TestFlight › External Testing.** Create
   the external group; add build; answer Beta App Review's compliance questions
   with `RR §7`'s App Review notes; submit.
4. **Owner action — invite the cohort** (App Store Connect › TestFlight ›
   External Testing › add testers by email or public link, per `CH §4.4` bullet
   6's segments).
5. **Owner action — monitor daily** against `MON §2` dashboards and the
   `docs/native-phase-12-monitoring.md` §7 intake log; keep the decision log
   current (`CH §9`).
6. **Owner action — keep the rollback path ready throughout** (`RB §4`): the Expo
   release branch stays green; R stays processed.
7. At the end of the charter §4.4 window (14 consecutive days, provisional; `CH
   §4.5`), run:
   ```sh
   sh native/run-phase-12-stage-preflight.sh --stage C
   ```
   to check Stage C's offline entry conditions before requesting Stage C.

### 4.3 Evidence template (append to `EI §24`, "### Stage B (12.05)")

```
Run <N>, <DATE range: start - end (>=14 consecutive days)>
Build: <VERSION> (<BUILD>)   Profile: TestFlight external
Cohort segments covered (CH SB1): new <alias(es)>, established <alias(es)>,
  offline-heavy <...>, Stripe <...>, booking <...>, recurring-work <...>, iPad <...>,
  two-device mixed-client <...>
Environment: REL+KEYS (production-configured once R59 is resolved, or staging per
  the owner's ruling)
Rows run / metrics (TH-1 to TH-11, final 7 days): <value, in target Y/N> per row
  (link full data externally; do not paste customer data here)
Support contacts: <count>, triaged within SLA: <Y/N>
Rejected changes classified: <Y/N>
Defects raised: <P12-... or none>
Expo rollback candidate status at exit: processed, not submitted (P12-RB-1)
Rows moved between stages (charter §4.3, owner's log entry): <IDs, or none>
```

### 4.4 Stop triggers (CH §4.8; who decides)

Same list as §2.4, now with real exposure: any open S1 or confirmed privacy/
cross-account exposure; TH-1, TH-2, TH-5 or TH-9 above zero; TH-8 below floor for
24h with the session minimum met, or a core-flow crash on two devices; TH-3 with
two-plus users unrecovered for 24h on the same code; a 429 blocker per `CH §5.5`.
Any trigger: no new invites, pause resumes, open the 12.06 rollback decision the
same day (`RB §2`). **Who decides:** the owner (D5); the rollback-or-fix-forward
choice follows `RB §2.2`'s four conditions.

### 4.5 Stage-owner prompt (`PL12` §5, filled in for 12.05)

> Execute **stage 12.05 only** from `docs/native-phase-12-implementation-plan.md`.
> Read the charter, the evidence index, `native-phase-4-mixed-client-convergence.md`
> and the 12.02 monitoring doc first. Confirm the entry gate in
> `docs/native-phase-12-stage-runbook.md` §4.1 is actually satisfied — Stage A
> exit, the rehearsal record, re-ratified thresholds and Beta App Review approval
> all present — and stop and report the blocker if not. Do not substitute
> production for missing isolated staging and do not change
> `https://staging.invalid` or any production-matched value to pass a check. Keep
> the decision log current daily; triage every S1/S2 into a blocking decision, not
> a silent waiver; keep the rollback path ready throughout (Expo branch green, R
> processed). Do not mark any row `Verified`. Return the cohort actually recruited,
> the metrics against threshold over the final 7 days, unresolved findings, and
> Stage C's readiness.

### 4.6 Readiness line

**Entry criteria met: no.** Blocking IDs: all of §2's and §3's blockers, plus
`BAR`, `COHORT`.

## 5. 12.07 — Stage C: production cutover

### 5.1 Entry gate checklist (CH §4.6; `PL12` 12.07 "Depends on": 12.05 exit gate, 12.06 verified, the Expo rollback candidate uploaded and processed)

| # | Criterion | Source | Current state (2026-09-27) | Evidence | Owner | Action needed |
|---|---|---|---|---|---|---|
| 1 | Stage B exit met | `CH §4.6` bullet 1 | **Not met** — Stage B has not run | `EI §24` "Stage B" | owner | Complete §4 above |
| 2 | SC1: the Expo feature freeze is announced | `CH §4.6` bullet 2 | **Not met** | — | owner | Announce before Stage C entry |
| 3 | SC2 re-verified live: database backups taken and a restore tested; backend compatibility confirmed; App Store metadata, entitlements, privacy manifests, privacy labels (OI-1) and legal disclosures final | `CH §4.6` bullet 3 | **Partly prepared** — 12.01/task 13 prepared the checklist and read-only verification (`RR §3, §4, §6`); live execution (backup+restore test, labels entered) is Stage-C-time work | `RR §4.2, §5, §6, §9` | owner | Execute the live SC2 checks at Stage C entry; enter OI-1 labels |
| 4 | Release set up per `CH §7`: "Manually release this version" + phased release selected; release day and 7 watch days logged | `CH §4.6` bullet 4 | **Not met** — no version submitted yet | `CH §1` rule 3; `CH §7` | owner | Plan the calendar; log the row before release |
| 5 | Rollback candidate processed and the playbook at hand | `CH §4.6` bullet 5 | **Not met** — R does not exist | `EI §5` row EXPO-RB | owner | Complete §3 above |
| 6 | Production build configuration exists (R59), values verified | `RR` front matter; `RR §3.1` | **Not met** | `RR §3.1, §14` | owner | Rule and build the configuration; verify against the live Expo build (`CH §4.6` bullet 3 reads this together with 12.01 step 1) |

**Readiness line: Entry criteria met: no.** Blocking IDs: everything under §4
above, plus `R59` and the live-execution parts of criterion 3.

### 5.2 Exact commands, in run order

1. **Environment preflights and offline stage preflight** (`PL12` §4):
   ```sh
   sh native/run-phase-3-device-preflight.sh
   sh native/run-phase-4-device-preflight.sh
   sh native/run-phase-12-stage-preflight.sh --stage C
   ```
2. **Owner action — announce the Expo feature freeze** (SC1).
3. **Owner action — live SC2 checks**: take a database backup and test its
   restore; re-confirm backend compatibility; finalize App Store metadata,
   entitlements, privacy manifests and legal disclosures; enter the OI-1 privacy
   labels in App Store Connect (`RR §5`).
4. **Unsigned compile sanity, then dry-run the upload helper, for the production
   candidate:**
   ```sh
   xcodebuild -project native/TradeReadyNative.xcodeproj -scheme TradeReadyNative \
     -configuration Release -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
   sh native/phase-12-testflight-upload.sh --version <VERSION> --build <BUILD>
   ```
5. **Owner action — App Store Connect › App Store tab › + Version.** Attach the
   processed build; select "Manually release this version"; select "Release
   update over a 7-day period using phased release" (`CH §7`); submit for review.
6. **Owner action — plan the calendar** (`CH §1` rule 3): 7 watchable days with no
   planned absence; log the release day and the 7 days in `CH §9`.
7. **Owner action — release on a watch day** ("Release This Version"), then
   monitor `MON §2` continuously through the phased-release days, including the
   mixed-client window (`native-phase-4-mixed-client-convergence.md`).
8. **On any `CH §4.8` trigger:** pause the phased release; if new installs must
   stop too, Remove App From Sale (`CH §7`); open the 12.06 rollback decision
   (`RB §2.2`) the same day. If rolling back:
   ```sh
   sh native/phase-12-testflight-upload.sh --version <N_HOTFIX> --build <BUILD> \
     --execute --i-am-the-owner
   ```
   is for a **native** fix-forward build only. Submitting the already-processed
   Expo candidate R for review is a separate App Store Connect action (`RB §6`
   step 3), not this script (this script never builds or uploads the Expo side).

### 5.3 Evidence template (append to `EI §24`, "### Stage C (12.07)")

```
Run <N>, <DATE>
Build: <VERSION> (<BUILD>)   Release type: phased | Release to All Users
Release day: <DATE>   Watch days logged: <CH §9 row #>
Phased-release day-by-day %: 1% <DATE>, 2% <DATE>, 5% <DATE>, 10% <DATE>, 20% <DATE>,
  50% <DATE>, 100% <DATE> (or: paused on day <N> at <%>, reason <...>)
Metrics (TH-1 to TH-11, rolling 24h days 1-7 then rolling 7 days): <in target Y/N>
  per row
Legacy migration / backend compatibility retained: <Y/N, evidence>
Defects raised: <P12-... or none>
Outcome: reached 100% with metrics in threshold | Release to All Users chosen |
  RB playbook executed (link the decision-log row and RB record)
```

### 5.4 Stop triggers (CH §4.8; who decides)

Same as §4.4, now against the phased-release population. Additionally: the phased
release gates almost nothing (no installed base), so **new installs are the
exposed cohort** (`CH §7`); the real controls are manual release timing and, on a
breach, Remove App From Sale plus pausing the phased release. **Who decides:** the
owner (D5); `RB §2.2` governs roll back vs. fix forward.

### 5.5 Stage-owner prompt (`PL12` §5, filled in for 12.07)

> Execute **stage 12.07 only** from `docs/native-phase-12-implementation-plan.md`.
> Read the charter (especially §7's exposure-control rule and its corrections to
> this plan step), the evidence index and the 12.02 monitoring doc first. Confirm
> the entry gate in `docs/native-phase-12-stage-runbook.md` §5.1 is actually
> satisfied — Stage B exit, the freeze announced, live SC2 checks done, the
> release configured for manual release with phased rollout, and the rollback
> candidate processed — and stop and report the blocker if not. Never remove the
> whole app from sale, pause or resume a phased release, or submit the rollback
> candidate without the owner's explicit go for that exact action. Monitor
> continuously against the charter thresholds, including the mixed-client window;
> any S1/S2 or threshold breach opens the 12.06 rollback decision the same day and
> is reported, not silently absorbed. Do not mark any row `Verified` — that is
> 12.08's job, with the full evidence set. Return the phased-release day-by-day
> state, metrics against threshold, unresolved findings, and whether Stage C
> exited cleanly or the rollback was executed.

### 5.6 Readiness line

**Entry criteria met: no.** Blocking IDs: all of §4's blockers, plus `R59` and the
live SC2 execution items.

## 6. 12.08 — exit verification and closeout

### 6.1 Entry gate checklist (`PL12` 12.08 "Depends on": 12.04–12.07; CH §4.7 defines Stage C exit and Exit together)

| # | Criterion | Source | Current state (2026-09-27) | Evidence | Owner | Action needed |
|---|---|---|---|---|---|---|
| 1 | Stage C exit met: phased release reached 100% (or Release to All Users), every TH row in target, zero open S1/S2, legacy compatibility intact — or the RB playbook was executed and recorded | `CH §4.7` | **Not met** — no stage has run | `EI §24` | owner | Complete §5 above |
| 2 | E1: zero open S1/S2 on the defect list, judged by `CH §2` | `CH §4.7` | **Not met today** (`P12-012` open); re-check at exit time, since Stage A/B/C fixes may close it by then | `CH §10` | owner | Re-run the audit in `docs/native-phase-12-exit-report.md` §1 at exit time |
| 3 | E2: TH-1 to TH-11 within target over the 14 days after 100%, citing 12.02 sources | `CH §4.7` | **Not met** — no window has run | `MON §2` | owner | Fill `docs/native-phase-12-exit-report.md` §2 at exit time |
| 4 | E3: playbooks staffed, rehearsal recorded | `CH §4.7` | **Not met** — rehearsal not run, staffing row not logged | `RB §8.4` | owner | Complete §3 above |
| 5 | AGG-1 resolved | `CH §4.7` | **Not met** | `CH §4.1` | owner/backend | Resolve or accept with a dated ruling |
| 6 | No parity row `Verified` without the full evidence set | `CH §4.7` | **N/A until candidates exist** | `docs/native-parity-matrix.md` | — | Apply the rule when filling `docs/native-phase-12-exit-report.md` §4 |

**Readiness line: Entry criteria met: no.** Blocking IDs: all of §5's blockers,
plus `AGG-1` at exit time.

### 6.2 Exact commands, in run order

1. **Offline stage preflight:**
   ```sh
   sh native/run-phase-12-stage-preflight.sh --stage exit
   ```
2. Fill in `docs/native-phase-12-exit-report.md` §1–§9 completely, re-deriving
   every count from the charter and evidence index at the HEAD this report cites
   (never copied from an earlier draft).
3. **Owner action (or an agent the owner instructs) — update the roadmap and
   parity matrix** only for rows with the full evidence set (§4 of the exit
   report), citing the evidence-index rows that justify each move.
4. **Owner action — record the post-cutover stabilization window** and the
   legacy-code removal follow-up (exit report §5–§6); this phase does not
   schedule or execute the removal.
5. **Owner action — re-read the G1 waiver** (`CH §5.1` "Review" row) and record
   whether it still holds (exit report §7).

### 6.3 Evidence template

Use `docs/native-phase-12-exit-report.md` directly — it is the fill-in template
for this stage; do not duplicate its fields here.

### 6.4 Stop triggers

12.08 is verification, not an exposure window, so `CH §4.8`'s triggers do not
apply to it directly. If E1 finds a new open S1/S2 while completing the audit,
that finding itself reopens the Stage C rollback question (`CH §4.8`) before 12.08
can close — the exit report is not filed over an unresolved defect.

### 6.5 Stage-owner prompt (`PL12` §5, filled in for 12.08)

> Execute **stage 12.08 only** from `docs/native-phase-12-implementation-plan.md`.
> Read the charter, the evidence index, the 12.02 monitoring doc and the rollback
> playbook first. Confirm Stage C actually exited (§6.1's criterion 1) before
> starting; if not, stop and report the blocker. Fill
> `docs/native-phase-12-exit-report.md` completely: re-derive every defect and
> threshold count from the current charter and monitoring sources rather than
> copying an earlier draft, and move a parity-matrix row to `Verified` only with
> the full evidence set (test name, RN oracle, device/OS, screenshot/output
> comparison) — link each move to the evidence-index row that justifies it. Record
> the post-cutover stabilization window and the legacy-code removal follow-up as a
> future task, not work done now. Return the completed exit report's location, the
> E1/E2/E3 results, every roadmap/parity-matrix edit made, and remaining concerns.

### 6.6 Readiness line

**Entry criteria met: no.** Blocking IDs: all of §5's blockers.
