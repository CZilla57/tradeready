# Native Phase 12 — exit report (12.08)

**Status: TEMPLATE — not a record; 12.08 fills it.** Prepared 2026-09-27 by task 14
(stage prep) as a fill-in-the-blanks form for the owner (or an agent the owner
instructs) to complete when Stage C exits and 12.08 runs. Every value below is a
placeholder. No stage has run: this document contains no claim that any threshold,
gate or parity row has been met. `N/` means `native/TradeReadyNative/`. `CH` is
[the cutover charter](native-phase-12-cutover-charter.md); `EI` is
[the evidence index](native-phase-12-evidence-index.md); `MON` is
[the monitoring doc](native-phase-12-monitoring.md); `RB` is
[the rollback playbook](native-phase-12-rollback-playbook.md).

Host checks, simulator runs and generic builds never substitute for device, TestFlight
or store evidence (global constraints; CH §4). 12.08 does not run until Stage C exits
(CH §4.7) — either the phased release reached 100% (or Release to All Users was chosen)
with every threshold in range and zero open S1/S2, or the RB playbook was executed and
recorded (CH §4.7).

## 0. Front matter (fill in at 12.08)

| Field | Value |
|---|---|
| Date this report was completed | `<DATE>` |
| Completed by | `<owner, or agent instructed by the owner>` |
| Charter version / decision-log row approving exit | `<CH §9 row #>` |
| Stage C outcome | `<phased release reached 100% / Release to All Users / rollback executed (RB §6)>` |
| Native release version(s) covered | `<N, and N.1/N.2 hotfixes if any — CH §4.1/RB §3.2 numbering>` |
| Report supersedes | `<none / prior draft dated ...>` |

## 1. E1 — zero open S1/S2 (charter §2, §4.7)

E1 requires zero open severity-1 and zero open severity-2 defects, judged by the
severity rules in CH §2, at the moment of this report.

1. **Defect-list audit.** Re-derive this table from `CH §10` at the HEAD this report
   cites (not copied from an earlier draft):

   | Section | Open S1 count | Open S2 count | Notes |
   |---|---|---|---|
   | Original Phase 11 triage (12.00b.1, 12.00b.2, rider, doc batch, 12.01 check, 12.02, backlog, record) | `<N>` | `<N>` | `<any severity change the owner logged, with its CH §9 row>` |
   | New in Phase 12 (`P12-…`) | `<N>` | `<N>` | `<list each open ID>` |
   | Found during Stage A/B/C but not yet in the charter | `<N>` | `<N>` | `<append to CH §10 "New in Phase 12" before this report is final>` |
   | **Total open S1** | `<N>` | | must be **0** |
   | **Total open S2** | | `<N>` | must be **0** |

2. **Every closed row names its fixing commit(s)** (CH §8) — spot-check a sample and
   record any row that does not: `<none found | list>`.
3. **Any severity change** made during a stage (CH §2 rule 3) is a decision-log row;
   list each one here: `<CH §9 row # — ID — old severity → new severity — reason>`.
4. **Result:** `<E1 MET | E1 NOT MET — name the blocking ID(s)>`.

## 2. E2 — thresholds within target (charter §3; 12.02 sources)

E2 requires TH-1 to TH-11 within their charter §3 target over the 14 days after the
release reached 100% (TH-12 is advisory, not part of E2). For each row, cite the
12.02 source (`MON §2`/§3) actually read — never a substituted or host-only source
once a live one exists.

| ID | Metric | Charter target (CH §3) | 12.02 source (MON §2/§3) | Window (14 days after 100%) | Observed value | In target? | Evidence link |
|---|---|---|---|---|---|---|---|
| TH-1 | Migration data loss | 0 | Support reports, SA2 rows (`EI §19`, §23) | | `<N>` | `<yes/no>` | `<link>` |
| TH-2 | Migration failure without recovery | 0 | Sentry `legacyMigration`/`initialSync` (MON §3) | | `<N>` | `<yes/no>` | `<link>` |
| TH-3 | Unrecovered sync failure | 0 open | Sentry `pendingAge`/`pushQueue`/`pullRemote` (MON §2) | | `<N>` | `<yes/no>` | `<link>` |
| TH-4 | Sync error rate (PERF-7) | ≤5% DAU (7-day avg) | Sentry + PostHog DAU (MON §2) | | `<%>` | `<yes/no>` | `<link>` |
| TH-5 | Discarded local changes | 0 | Sentry `pushDiscarded` (MON §3) | | `<N>` | `<yes/no>` | `<link>` |
| TH-6 | 429 bursts (OI-3) | CH §5.5 signal/blocker levels | Sentry `syncThrottle` + dashboards (MON §5) | | `<N>` | `<yes/no>` | `<link>` |
| TH-7 | Rejected changes (I2) | 0 caused by a native defect | Sentry `pushRejected` (MON §3) | | `<N>` | `<yes/no>` | `<link>` |
| TH-8 | Crash-free sessions (PERF-9) | ≥99.5% at ≥300 sessions | Sentry Release Health (MON §2) | | `<%>` / `<session count>` | `<yes/no>` | `<link>` |
| TH-9 | Payment reconciliation | 0 unreconciled >24h | Stripe Dashboard vs Supabase (MON §6) | | `<N>` | `<yes/no>` | `<link>` |
| TH-10 | Subscription continuity | 0 mismatches | RevenueCat vs app state (MON §2) | | `<N>` | `<yes/no>` | `<link>` |
| TH-11 | Support contacts | 100% triaged in SLA | Intake log (MON §7) | | `<%>` | `<yes/no>` | `<link>` |
| TH-12 (advisory, not E2) | Launch/migration time | CH §3 targets | Instruments (12.04) | per Stage A run, not the 14-day window | `<value>` | `<n/a — advisory>` | `<link>` |

Any breach during the window is a stop trigger (CH §4.8) and a decision-log row
(CH §9); link it here: `<CH §9 row # | none>`.

**Result:** `<E2 MET | E2 NOT MET — name the breaching TH-ID(s)>`.

## 3. E3 — playbooks staffed, rehearsal recorded (charter §1, §4.4; RB §8)

1. **Rollback rehearsal.** Link the completed rehearsal record (RB §8.3 evidence
   template) and its evidence-index rows: `<EI §23 rows P12-RB-2 to P12-RB-5, P12-RB-7 — link>`.
   Rehearsal date: `<DATE>`. Outcome: `<no data loss, real version numbers L<N<R<N2 | defects raised: list>`.
2. **Staffing.** Link the decision-log row confirming watch days, planned pauses and
   that the playbook and processed candidate R were at hand (RB §8.4; `EI` row
   `P12-RB-6`): `<CH §9 row #>`.
3. **Support intake.** Confirm the intake channel and SLA (MON §7) ran throughout
   Stage B and C and every contact was triaged: `<yes/no — evidence>`.
4. **Result:** `<E3 MET | E3 NOT MET — name what is missing>`.

## 4. Parity-matrix `Verified` candidates

List only rows for which **every** item of the parity matrix's "Evidence required for
`Verified`" contract (`docs/native-parity-matrix.md` §"Evidence required for
`Verified`") exists. A row with a partial evidence set stays at its current status —
never move it to `Verified` on partial evidence (CH §4.7; global constraints).

| Parity matrix row (PM line) | XCTest / UI-test name | RN oracle (file:line) | Device / OS | Screenshot or output comparison | Backend contract version / migration note | Verified? |
|---|---|---|---|---|---|---|
| `<e.g. L28 Auth>` | `<test name>` | `<RN file:line>` | `<device, OS>` | `<link, or "n/a — no visual output">` | `<contract doc §, or "n/a">` | `<yes — move to Verified in this commit / no — evidence incomplete: name the gap>` |

Add one row per candidate. For every row **not** listed here, the parity matrix keeps
its current status; do not infer `Verified` from an evidence-index checkbox alone.

## 5. Post-cutover stabilization window

- **Window.** `<start date>` to `<end date>` (recommended: the same 14 days as E2,
  extended if any TH row is still being watched).
- **What is watched.** The same 12.02 dashboards (MON §2) at reduced frequency once
  E1–E3 are met; any new S1/S2 during the window reopens the rollback decision (CH §4.8).
- **Exit of the stabilization window.** `<date, and who confirmed no new S1/S2 arose>`.

## 6. Legacy-code removal follow-up (explicitly not part of this phase)

The G6 retention policy (CH §5.4) keeps the legacy migration code (RN AsyncStorage
reader, `LegacyMigrationCoordinator`, `LegacyBackups/`) indefinitely, "until a future
release series removes the legacy migration code" (CH §5.4). This report records the
follow-up, it does not schedule or execute it:

- **Earliest removal condition.** Not before every installed device has completed its
  one-time migration and the owner judges the rollback window (CH §6) closed — i.e.
  not this phase, and not the stabilization window above.
- **What removal would touch (for the future task, not now):** `N/LegacyMigrationCoordinator.swift`,
  `N/LegacyDataImporter.swift`, `N/Domain/SnapshotRepository.swift`'s `LegacyBackups/`
  handling, the retry/"Try again" UI paths, and every host test runner named in CH §5.4
  and this doc.
- **Tracking.** `<link a future roadmap entry or backlog ID once one exists; none yet>`.

## 7. G1 waiver re-read (charter §5.1, "Review" row)

The G1 waiver (native remote push, dated 2026-09-25) is re-read at 12.08 (CH §5.1).
Record whether the waiver still holds or the building release (12.00b.4) has since
shipped: `<waiver still in effect | 12.00b.4 shipped in release <N> — waiver closed>`.

## 8. Roadmap and parity-matrix updates made by this report

List every edit this report's completion makes to
`docs/native-ios-migration-roadmap.md` and `docs/native-parity-matrix.md`, each with
the evidence-index row(s) that justify it (CH §4.7; global constraints — never mark a
row `Verified` without the full evidence set):

- `<file:line — old text → new text — justified by EI row(s) …>`

## 9. Concerns and open items at exit

`<list anything unresolved even though E1–E3 are met, e.g. accepted residuals from
the defect list's "record" rows, backlog items deferred post-cutover, or a G1/OI-3
policy the owner should revisit>`
