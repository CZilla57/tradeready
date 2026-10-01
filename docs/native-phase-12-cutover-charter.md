# Native Phase 12 — cutover charter (12.00)

**Status: Owner-approved 2026-09-29** ([decision log](#9-decision-log) row 8). Written 2026-09-25 on branch native/phase-12.
Every threshold in this document stays **provisional** until the Stage B re-ratification (§0, §3).
Stage gates may cite this charter.

This charter is the single source for defect severity, thresholds, roles, stage gates,
the rollback data decision, the exposure-control rule and the defect list. Later tasks
(12.00b, 12.01–12.08) cite it and do not restate its values. Scope and requirement IDs
(SA1–SA3, SB1–SB3, SC1–SC4, E1–E3) are in
[the Phase 12 plan](native-phase-12-implementation-plan.md) §1; the owner decisions
D1–D5 are plan §1.3; the Phase 11 carries are plan §1.1. Metric definitions come from
[the Phase 11 performance protocol](native-phase-11-performance.md), which sets no
threshold and names this charter as their owner. The app has **no current production
users**, so there is no Expo baseline and almost no installed base to protect. Code facts
cited here were read at `1bb701c`, the native/phase-12 base (`N/` differs from `6d573a7`
only by the rating prompt).

## 0. What the owner approves

| Item | Section | Owner action |
|---|---|---|
| Roles and the single-person operating rules | §1 | approve |
| Severity definitions, examples and rules | §2 | approve |
| Thresholds TH-1 to TH-12 | §3 | approve as provisional for Stage A; re-ratify at Stage B entry with the Stage A baselines |
| Stage go/no-go checklists and stop triggers | §4 | approve |
| G1 waiver, G6 retention policy, OI-3 429 policy | §5 | approve each |
| Rollback data decision | §6 | approve (12.06 implements it) |
| Exposure control, including two corrections to plan 12.07 | §7 | approve |
| G6-Q1 (account deletion and the RN source files): **resolved 2026-09-25** by 12.00b.2-F (`P12-001`). Rule: after a permanent account deletion nothing from that account is re-imported; the deletion erases the RN source files install-wide (not scoped to the deleted account: §5.4 item 5), so the G6 keep-never-delete retention ends there | §5.4 item 5 | approve with the G6 policy |

## 1. Roles (RACI) and the single-person risk

Decision D5 (2026-09-25): the owner holds every role.

| Role | Holder | Responsible for |
|---|---|---|
| Owner (accountable for every gate) | the owner | this charter, thresholds, severity changes, waivers, every go/no-go, the decision log |
| Release engineer | the owner | signing (SIGN-1), version numbers (VER-1), TestFlight and App Store Connect uploads, release, pause, Release to All Users, removal from sale, the Expo rollback candidate |
| Backend | the owner | the Worker deployment freeze, Supabase backups and a restore test, read-only reconciliation queries, the rate-limit facts OI-3 needs, isolated staging (D4) |
| Support | the owner | the intake channel 12.02 defines, triage within the §2 SLA, user messages from the 12.06 script |
| On-call | the owner | watching the 12.02 dashboards, acting on the §4.8 stop triggers |
| Coding agents (consulted only) | — | prepare documents, scripts and host-tested code. They never submit to App Store Connect, deploy, touch production data or accounts, or change signing (plan §1) |

**Single-person risk.** Nobody else can pause a release, remove the app from sale, answer
a user or run the rollback. There is no second reviewer at a go/no-go and no cover when
the owner is away. The owner accepts this residual risk because the exposed population is
small (no installed base). These operating rules (provisional) reduce it:

1. **Watch days.** A manual release ("Release This Version"), a resume of a paused phased
   release, a Stage B invite wave or a rollback submission happens only when the owner can
   check the dashboards at least twice that day and once the next day. A released version
   can take up to 24 hours to reach the App Store (§7), so the watch covers 48 hours.
2. **No unwatched phased-release days.** The 7-day phased release advances daily on its
   own. Pause it before any day the owner cannot watch. Pauses draw on a 30-day total
   budget; log each pause and the days left. A pause does **not** stop new installs or
   manual updates (§7): after a breach, during an unwatched stretch, the only full stop is
   Remove App From Sale.
3. **Plan the calendar first.** Stage C starts only when the owner has 7 watchable days
   (plus any planned pauses) with no planned absence; the release's decision-log row names
   them.
4. **Freeze during exposure.** No backend deploy during the Stage B window or the phased
   release, except a fix a §4.8 stop trigger requires. No non-critical Expo feature work
   from Stage C entry (SC1).
5. **Pre-stage the rollback.** The Expo rollback candidate is uploaded and processed before
   Stage C (12.06 step 2), so one person can submit it without building under pressure.
6. **Write before acting.** Each go decision is written in the decision log, with its
   evidence, before the action it authorizes. An agent-prepared readiness summary may be
   read first; it is advice, not a decision.
7. **Keep access recoverable.** The owner keeps a private list of the accounts the release
   depends on. No credential or account identifier is written in this repository.

## 2. Defect severity

The definitions are plan §7's, applied literally:

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

Examples by class. An ID refers to a real row in the [defect list](#10-defect-list).

| Class | S1 | S2 | S3 |
|---|---|---|---|
| Migration | a record present in the Expo build is missing after upgrade with no logged deferral; the journal says complete but no snapshot loads and Retry cannot recover | a migration that fails once and completes on retry; L267.a (a legacy backup can stay unprotected: a fail-open gate) | L267.c (photo backup copies keep default protection); L267.b (a locked relaunch retries; accepted) |
| Sync | a queued local change discarded (`record-contract/<table>`, TH-5); a pull that overwrites a pending local edit | L238 / I2 (one rejected change stops all inbound sync); L237.d (launch skips the recurring-invoice refresh RN runs) | L237.e (a regressed cursor the next pull refetches) |
| Payments | a payment recorded twice, lost, or on the wrong invoice; a wrong total, balance or tax amount | a payment link cannot be sent while manual recording still works | copy on a payment screen |
| Crash / hang | any reproducible crash or watchdog termination in a core flow | L74 / L96 (a blocking file lock on the main actor with no timeout); a crash outside core flows with a workaround | a hitch with no functional effect |
| Data loss | L130 (one bad widget/Siri entry quarantines the whole batch, so valid clock-ins and expenses are never applied) | a loss the next sync restores without user action | — |
| Privacy / cross-account | L286.5b (a double failure lets the next account bind over the previous account's AI key or widget data); any credential, token or customer text in analytics, Sentry or a support report | L286.5a (Settings can show account B "Saved" for account A's key); L167.c (diagnostic names logged public; closed) | L193.c (over-redaction; accepted) |

Rules:

1. **E1 at every stage exit.** Zero open S1 and zero open S2 at the exit of Stage A,
   Stage B, Stage C and at 12.08. An S1 found during a stage is a stop trigger (§4.8).
2. **Stage A entry.** An open S1 or S2 on the defect list blocks Stage A entry unless
   12.00b fixes it, or the owner records a severity change with its rationale in the
   decision log (plan 12.00 step 8).
3. **Severity changes** are the owner's, in the decision log, with the reason. A closed
   item keeps the severity it had while open. S1 and S2 route the same way, so a
   borderline call does not change what is built (plan ruling R2).
4. **New defects** found in Phase 12 get IDs `P12-001` onward and are appended to the
   defect list's "New in Phase 12" table with severity, source and handling.
5. **Triage SLA** (provisional, sized for one person): S1 — a pause/rollback decision the
   same day, within 4 hours of the owner reading the report; S2 — classified and assigned
   within 1 business day; S3 — within 5 business days.

## 3. Thresholds (provisional)

Rules for every row:

- The values are **absolute targets** (plan 12.00 step 2). There is no Expo production
  baseline, and PERF-10 (the Expo launch reference) is never a threshold.
- **Stage A** (12.04 step 5) captures native baselines for the rows marked "refined". The
  owner **re-ratifies every row at Stage B entry** and logs each changed value. A zero
  target stays zero unless the owner records why.
- **Windows.** Stage A: per run, on team devices. Stage B: rolling 7 days, evaluated at
  each daily watch. Stage C: rolling 24 hours during phased-release days 1–7, then rolling
  7 days. E2 at 12.08: the 14 days after the release reaches 100%.
- **Sources** marked "12.02 adds" do not exist at `1bb701c`; 12.02 gives every row a live
  or runnable source and an alert route before Stage A entry. An on-device source is read
  from the privacy-safe support report (`AppStore.createPersistenceSupportReport`,
  `N/AppStore.swift:977`). Sentry and PostHog need owner-held setup (OI-2, build-time keys).
  Small cohorts make rates noisy, so several rows also carry a per-event rule.

| ID | Metric | Definition | Source | Provisional target | Refined / re-ratified |
|---|---|---|---|---|---|
| TH-1 | Migration data loss | Per Expo → native upgrade: a record, photo or setting present in the Expo build and missing from the native snapshot without a logged deferral. Compare the support report's per-collection `counts` with the Expo data set's known counts; photos adopted + deferred must equal photos found | Support report per upgraded device (12.04 SA2 rows): `launchMigration` counts and `persistence.recordCounts`. A lost record has no remote signal by design (the device cannot know the Expo counts); a failed or lost migration reports remotely as TH-2's `legacyMigration` (12.02, 2026-09-26; `docs/native-phase-12-monitoring.md` §2) | **0**. Any occurrence is S1 | fixed at 0; owner confirms at Stage B entry |
| TH-2 | Migration failure without recovery | Journal status `failed` for the RN import, or the "marked complete, but its native snapshot is unavailable" block (`N/AppStore.swift:9138`), still present after relaunch and Retry (`retryLegacyMigration`) | Sentry `reportError` context `legacyMigration` (`legacy-migration/failed/<domain>/<code>` and `legacy-migration/missing-migrated-snapshot`, at launch and on Retry; never for the P12-003 signed-out steady state) and `initialSync` (`preflight/local-recovery/missing-migrated-snapshot`), added by 12.02 (2026-09-26, `docs/native-phase-12-monitoring.md` §3); support report `launchMigration`; `LegacyMigration` signpost outcome (PERF-5, Instruments only) | **0** (S1). A failure that completes on retry is S2 until explained; more than one in a stage blocks that stage's exit until explained | zero fixed; retry rule refined by Stage A |
| TH-3 | Unrecovered sync failure | A signed-in, online device with changes pending for over 24 h, or with a non-transport sync code and no successful pass for 24 h | Sentry `reportError` events with context `pushQueue` / `pullRemote` and a bounded code (`N/AppStore.swift:12355`); Sentry `pendingAge` (`pending-age/over-24h`, once per episode; 12.02, 2026-09-26); the device's Cloud Sync screen and support report (`sync.oldestPendingAge`, `sync.lastSuccessfulSyncAge`) | **0 open**; each is S2 until classified. Two or more users with the same code unrecovered for 24 h is a stop trigger | owner at Stage B entry |
| TH-4 | Sync error rate (PERF-7) | Share of daily active users with at least one sync error event whose code is not `transport/…`, `non-http-response/…`, an auth status (401, first 403) or a 429 (TH-6) | Sentry, as TH-3; denominator: daily active users from Phase 11 analytics (PostHog, identified by Supabase user id), or the cohort size where PostHog has no data | **≤ 5% of daily active users** (7-day average); every new code is triaged whatever the rate | refined by Stage A (PERF-7 baseline); owner at Stage B entry |
| TH-5 | Discarded local changes | A queued change the push drops as unsendable, code `record-contract/<table>` (`N/NativeSupabasePush.swift:140`) | Sentry `reportError` context `pushDiscarded` (`record-contract/<table>`, with collection and count), sent even when the pass ends `.completed` (12.02, 2026-09-26, `docs/native-phase-12-monitoring.md` §3); support report `sync.discardedChangeCount`; the code on Cloud Sync | **0**; each is S1 until shown harmless | fixed at 0 |
| TH-6 | 429 bursts (OI-3) | Sync passes whose code ends `/429`. A Sentry event counts passes, not requests: one pass sends every queued item once | Sentry, as TH-3 (codes ending `/429`), and `syncThrottle` (`throttle/consecutive-passes`: 3 throttled passes in a row on one device; 12.02, 2026-09-26); support report throttled-pass counts; Supabase and Cloudflare dashboards for the server view (owner) | signal and blocker levels in §5.5 | owner at Stage B entry, once the real rate limit is known |
| TH-7 | Rejected changes (I2) | Changes 12.00b.1 moves to the rejected store (count, table, status code; D3) | Sentry `reportError` context `pushRejected` (`rejected/<table>/<status>`, `rejected-store/overflow`; 12.00b.1), alerted on each new issue (12.02, 2026-09-26, `docs/native-phase-12-monitoring.md` §2); support report `sync.rejectedChangeCount` (on file) and `persistence.rejectedChangeCount` (shown on Cloud Sync) | **0** caused by a native payload or classification defect; every rejected change classified within the S2 SLA; an unclassified one blocks a stage exit | owner at Stage B entry |
| TH-8 | Crash-free sessions (PERF-9) | Sentry release health per release (`<bundle id>@<version>+<build>`, `N/NativeCrashReporting.swift:71`; session tracking on, `:20`) | Sentry (needs OI-2 and a release DSN) | **≥ 99.5%** when the release has ≥ 300 sessions in the window. Below that the rate is not used: every crash is triaged, and any crash in a core flow is S1. Organizer hangs and terminations (PERF-4) are read alongside, advisory | refined by Stage A; owner at Stage B entry |
| TH-9 | Payment reconciliation (Stripe) | Every Stripe Checkout Session completed on a connected account has exactly one `payments[]` entry with id `stripe_<session id>` and method `stripe` on its invoice (the webhook contract in `backend-workers/src/routes/stripe/webhook.js`), still present after the next native sync of that invoice; every native manual payment appears once in Supabase; totals and balances follow the RN rules | Stripe Dashboard reports for connected accounts vs a read-only Supabase query of invoices (owner); PostHog `payment_recorded` / `invoice_paid` counts as a cross-check. The webhook's header records a read-modify-write race that can clobber a concurrent write; this check is what catches it | **0 unreconciled older than 24 h**. A wrong amount, duplicate or lost entry is S1. Stage A uses Stripe test mode on synthetic accounts | fixed at 0 |
| TH-10 | Subscription continuity (RevenueCat) | An entitlement bought on the Expo build is honored after upgrade; Restore Purchases works; a sandbox purchase works (plan 12.01 step 3b) | RevenueCat customer view vs the app's paywall state; 12.04 rows | **0 mismatches**. Each is S2; S1 if a paying user loses access with no restore path | fixed at 0 |
| TH-11 | Support contacts | Every contact through the 12.02 intake channel and TestFlight feedback, classified S1 / S2 / S3 / not a defect | 12.02 intake log, with the support report when attached | **100% triaged within the §2 SLA**; 0 unexplained reports of missing or wrong data (each becomes a defect). Over 1 contact per 5 active cohort users in a week triggers a review (advisory) | owner at Stage B entry |
| TH-12 | Launch and migration time (PERF-1, 2, 5); advisory, not E2 | App Launch time to first frame; `LegacyMigration` duration on the first native launch after upgrade | Instruments traces from 12.04 | Cold launch median **≤ 2.0 s** on SE17, typical tier; warm median **≤ 1.0 s**; first-launch migration on the large tier finishes with no watchdog termination. A breach is S3 unless it is a hang or termination (S1) | refined by Stage A; owner at Stage B entry |

## 4. Stage gates

A gate that cannot be satisfied stays blocked and is reported; it is never approximated
(plan §1). Each gate decision is a decision-log row. Host checks, simulator runs and
generic builds never substitute for device, TestFlight or store evidence.

### 4.1 Open prerequisites (2026-09-25)

| ID | What is open | Blocks | Who clears it |
|---|---|---|---|
| SIGN-1 | The signed Release build cannot be provisioned: no signed-in Xcode account, and the wildcard profile lacks the App Group for `TradeReadyWidgets` | Stage A entry (every signed, device, TestFlight and archive row) | Owner signs in at Xcode › Settings › Accounts; 12.01 re-runs the signed build. An agent never touches accounts, profiles or signing |
| VER-1 | **Cleared 2026-09-29 (rows 10 and 13):** native N is 2.0.0 and the live Expo version L is 1.2.1, so L < N holds. R must be above 2.0.0. Was: native `MARKETING_VERSION = 1.0` below the Expo `app.json` version `1.2.1` | Stage A upload; 12.06 version numbering | Owner confirms the live store version; 12.01 sets the scheme under a recorded ruling |
| OI-1 | **Decided 2026-09-29 (row 9); manifest edit applied.** Open only: the owner enters the labels in App Store Connect (Stage C entry). Was: the privacy labels omit first-party backend data (email, business records, job photos) | the decision: Stage A entry (12.01); the labels entered: Stage C entry | 12.01 decides; the owner enters the labels |
| OI-2 | **Reported cleared 2026-09-29 (row 11), unverified by agents.** Was: Sentry project `tradeready-ios` in org `tradeready-3r` does not exist | Stage A entry (TH-8's source; rows CR-1 to CR-9) | Owner creates it; an agent never does |
| D4 | **Superseded 2026-09-29 (row 14): the owner decided no staging will exist.** The gates that cited D4 are not yet amended. Was: No trusted isolated staging. `https://staging.invalid` stays and production is never substituted | every STG row; SA3; Stage A exit | Owner provisions staging |
| AGG-1 | **Cleared 2026-09-29 (row 15):** `backend-workers/package.json` now has `"test": "node --test tests/*.test.cjs"`, and `npm test` there passes 26 tests. Was: `native/run-all-domain-tests.sh` ends with a `backend-workers` `npm test` that has no `test` script in committed code | the aggregate's exit code; SA3's full regression, so Stage A exit; 12.08 | Owner or the backend agent. Phase 12 does not edit `backend-workers/` |

### 4.2 Stage A entry (12.04) — go/no-go

- [ ] This charter is owner-approved (decision-log row), including thresholds as provisional.
- [ ] 12.00b is done: L238 (I2, 12.00b.1), the ten 12.00b.2 items and the G2 editor
      (12.00b.3) are fixed with host evidence and a clean review. No S1 or S2 row is open
      unless the owner logged a severity change.
- [ ] 12.01 is done: SIGN-1 and VER-1 cleared, the OI-1 decision recorded, production
      configuration verified against the live Expo build, the SC4 retention assertion
      recorded.
- [ ] 12.02 is done: every TH row has a live or runnable source and an alert route; OI-2
      cleared and the stage build carries its Sentry DSN; the support export is
      privacy-safe; the dry run on synthetic data produced the expected signals.
- [ ] 12.03 is done: the evidence index exists, Stage A rows are tagged, D4 is recorded.
- [ ] Host regression: every native runner passes under `TZ=America/Phoenix`; the
      unsigned and the signed Release builds succeed; the AGG-1 state is recorded.
- [ ] The G6 retention policy (§5.4) is approved before any SA2 upgrade run.
- [ ] Team accounts and synthetic data only (SA1); no real customer data is prepared.

**Blocking:** any unchecked item.

### 4.3 Stage A exit

- [ ] Every Stage-A-eligible 12.03 row has device or TestFlight evidence, or the owner
      logged its move to Stage B (only for a Stage-B-eligible row).
- [ ] SA2: the upgrade from the App Store Expo build ran on a physical device. TH-1 = 0,
      TH-2 = 0, TH-10 = 0; pending Expo local notifications were reconciled, not
      duplicated.
- [ ] SA3: the full regression suite (AGG-1 cleared) and the backend load checks ran
      against isolated staging (D4 cleared).
- [ ] Zero open S1 or S2 (E1).
- [ ] Native baselines captured (PERF-1, 2, 5, 6, 7, 8 and crash-free sessions) and handed
      to the owner.

**Blocking:** any open S1 or S2; any migration data loss; any migration failure without
recovery; any unreconciled test-mode payment; D4 or AGG-1 unresolved.

### 4.4 Stage B entry (12.05) — go/no-go

- [ ] Stage A exit met (decision-log row).
- [ ] The owner re-ratified TH-1 to TH-12 with the Stage A baselines (one row per changed
      value) and recorded the rate-limit facts OI-3 needs (§5.5).
- [ ] 12.06 gate: the playbook is written; the native half of the rollback data decision
      (§6) is built with host tests; the rehearsal native → Expo → native on TestFlight,
      with an unsynced local edit before each transition, is recorded with no data loss
      and real version numbers.
- [ ] Beta App Review approved the external TestFlight build (allow lead time).
- [ ] The Expo release branch builds green (SB3).
- [ ] The cohort covers SB1 (new, established, offline-heavy, Stripe, booking,
      recurring-work, iPad) plus one two-device mixed-client user; "established" means
      accounts seeded with realistic history; consent and data handling follow the legal
      disclosures.
- [ ] The support intake and the 12.02 dashboards are live; the owner's watch days for the
      window are planned (§1).

**Blocking:** any unchecked item.

### 4.5 Stage B exit

- [ ] The cohort ran for at least 14 consecutive days (provisional), with every SB1 segment
      active.
- [ ] Every TH row is within target over the final 7 days; every breach has a resolved
      finding.
- [ ] Zero open S1 or S2; every support contact triaged; every rejected change classified.
- [ ] The Expo rollback candidate (version above the planned native release) is uploaded
      and processed, not submitted (12.06 step 2).

### 4.6 Stage C entry (12.07) — go/no-go

- [ ] Stage B exit met.
- [ ] SC1: the Expo feature freeze is announced.
- [ ] SC2 re-verified live: database backups taken and a restore tested; backend
      compatibility confirmed; App Store metadata, entitlements, privacy manifests,
      privacy labels (OI-1) and legal disclosures final.
- [ ] The release is set up as §7 describes: "Manually release this version" and phased
      release selected; the release day and the 7 watch days are logged (§1 rule 3).
- [ ] The rollback candidate is processed and the 12.06 playbook is at hand.

### 4.7 Stage C exit and Exit (12.08)

Stage C exit: the phased release reached 100% (or Release to All Users was chosen) with
every TH row within target, zero open S1 or S2, and legacy migration code and backend
compatibility intact (SC4); or the 12.06 playbook was executed and recorded.

Exit (12.08) confirms E1 (zero open S1 or S2 on the defect list, judged by §2), E2 (TH-1
to TH-11 within target over the 14 days after 100%, citing the 12.02 sources) and E3
(playbooks staffed, rehearsal recorded). AGG-1 is resolved. No parity row is `Verified`
without the full evidence set. The G1 waiver (§5.1) and the legacy-code removal follow-up
are carried into the exit report.

### 4.8 Stop triggers during any stage

Any of these pauses the stage: no new invites, no resume, the phased release paused. It
also opens the 12.06 rollback decision the same day. Whether to ship the Expo rollback
build is 12.06's decision, which the owner makes and logs.

- any open S1, or a confirmed privacy or cross-account exposure;
- TH-1, TH-2, TH-5 or TH-9 above zero;
- TH-8 below its floor for 24 hours with the minimum sessions met, or a crash in a core
  flow reproduced on two devices;
- TH-3: two or more users unrecovered for 24 hours with the same code;
- a 429 blocker as §5.5 defines it.

If the owner cannot watch while a trigger is open, pause first; if new installs must stop
too, Remove App From Sale (§7).

## 5. Phase 11 carry decisions

### 5.1 G1 — native remote push: dated waiver (D1)

| Field | Value |
|---|---|
| Date | 2026-09-25 |
| Owner | the owner (D1, plan §1.3) |
| What is waived | Native remote push for booking alerts, and the tap routing RN has (`booking_request` → Jobs list; `booking_update` → the job, or the Jobs list). The events `booking_request_opened` and `booking_update_opened` are not emitted |
| User-visible impact | Booking alerts arrive **by email only**: new quote requests and booked appointments (`notifyOwner`, `backend-workers/lib/booking/notifyOwner.js:71`), and customer reschedule requests and cancellations (`notifyOwnerUpdate`, `:120`). No push banner, no tap-to-open. The request appears in Jobs after the next sync |
| Release that builds it | The first post-cutover native release. Plan §3 12.00b.4 is its specification (push capability, `aps-environment` through the configuration owner, APNs credentials for the Expo project, an OI-1 check, device rows) |
| Why it is safe | The email is attempted on every alert, independently of push, whenever an owner email and the Worker's email binding exist (`notifyOwner.js:73-74`, `:125-126`). Push is additive and fire-and-forget (`:86-106`, `:149-166`). No data path depends on push: booking records reach the app through normal sync. There are no production users, so nobody loses a push alert they had |
| Conditions | 12.01 confirms, read-only, that the production Worker has its email binding set, because without it an owner gets no alert at all. A 12.03 row covers an upgraded device: native keeps an Expo-era `settings.pushToken` in the synced settings (`N/Domain/CanonicalModels.swift:1231`) and the backend keeps sending to it, while the native build has no `aps-environment` entitlement. Expected: the email arrives and no push is delivered; any push that does arrive opens the app without a crash |
| Analytics | Both events stay on the Q4 exclusion list (`native/Phase11QualificationTests/main.swift:864-866`) |
| Review | Re-read at 12.08; the waiver ends when the building release ships |

### 5.2 G2 — tax-settings editor: build (D2)

Built in 12.00b.3 before Stage A: port RN `components/money/TaxSettingsModal.tsx` onto
`N/Domain/NativeTaxSettings.swift` and `AppStore.commitTaxSettings`, open it from the
Money tax card, and remove `tax_settings_saved` from the Q4 exclusion list. It is a Stage A
entry item (§4.2). No waiver.

**Status (2026-09-25):** built in 12.00b.3 on native/phase-12, host evidence only. The
Money tax card opens `N/NativeTaxSettingsView.swift`; `tax_settings_saved` is off the Q4
exclusion list. Device rows P12-B3-1 and P12-B3-2 are in the evidence index §23 (the
second needs staging, D4). The parity row "Tax set-aside" stays "In progress".

### 5.3 I2 — rejected-change handling (D3)

Unwaivable (roadmap: "It must be fixed before cutover"); defect row L238, built in
12.00b.1. D3's surface: a Cloud Sync status line ("N changes couldn't be saved") that opens
a detail list (record type, name, when); the count also goes into the support report.
Retry re-queues a change through the normal push. Discard, after a confirmation dialog
("Discard this change?", button "Discard change"), fetches the server's version of that one
record at once and shows it on this device; it does not wait for the next delta pull, which
may never return the row. A refused insert that the server has no record of is removed from
this device, and the dialog says so: "If the record was never saved to the cloud, it will
be removed from this device." (Implemented 2026-09-25 in 12.00b.1.) The monitored signal is TH-7. Rejected changes cannot be
drained before a rollback advisory; 12.06 reports them as not drainable (§6).

### 5.4 G6 — retention of the RN source files and legacy backups

**Policy (provisional): keep, never delete, until a future release series removes the
legacy migration code** (plan §1, SC4). A permanent account deletion ends it for the whole
install: the deletion erases the RN source files on the device, whichever account the RN
build last held (item 5, G6-Q1 resolved 2026-09-25). It agrees with
12.06 step 1(d) and Phase 0 rollback step 4 ("do not delete native migration journals or
legacy AsyncStorage backups"), and the Expo rollback build can still read the files it
reads today.

1. **RN AsyncStorage source files and the RN Documents files** stay where the Expo build
   wrote them, untouched. Native reads them (`asyncStorageCandidates`,
   `N/LegacyDataImporter.swift:441`; `liveSource`, `N/LegacyMigrationCoordinator.swift:780`)
   and no `N/` code modifies or re-protects them; only a permanent account deletion
   deletes them (item 5). Documents stays "the immutable Expo source throughout recovery"
   (`N/LegacyMigrationCoordinator.swift:705`). They keep
   whatever protection class the Expo build gave them; raising it could break the rollback
   build's reads while the device is locked.
2. **`LegacyBackups/` copies** are kept, immutable and protected: `preserveLegacyBytes`
   never overwrites (`N/Domain/SnapshotRepository.swift:239`); a published directory backup
   is returned unchanged (`:270`); files are written with complete file protection
   (`:57`, `:58`); copied directories are raised to `.complete` (`protectCopiedLegacyFiles`,
   `:527`, called at `:425`, `:453`); the tree is excluded from device backup (`:340`). Known
   gaps: a nil enumerator returns silently and leaves a copy unprotected (L267.a, `:528`;
   fixed in 12.00b.2), and legacy photo backup copies keep default protection (L267.c,
   `N/LegacyDataImporter.swift:1179`; backlog S3).
3. **Account boundaries.** Sign-out keeps `LegacyBackups/` and the migration journal
   (`removeLiveAccountData`, `N/Domain/SnapshotRepository.swift:122`). Permanent account
   deletion removes `LegacyBackups/`, the journal and the support report
   (`removeAllAccountData`, `:142`). 12.06 step 1(d) is about rollback, not a user's own
   deletion, so this stays. Sign-out does not touch the RN source files; permanent
   deletion erases them (item 5).
4. **Accepted residual.** An RN-era plaintext Square token can remain in the RN source files
   on an upgraded device until a permanent deletion erases them (item 5). It stays in the
   app's own sandbox, where the Expo build left it, with the protection that build gave it.
   Native adds no copy outside the protected, backup-excluded `LegacyBackups/`, and heals
   imported copies in its own store (contract §17.2 G4). With no production users, only
   team devices that ran a pre-2026-08 Expo build can hold one.
5. **G6-Q1, resolved 2026-09-25 by 12.00b.2-F (Task 9b, plan ruling R10): defect
   `P12-001` (S1, §10).** The host test (`native/run-legacy-reimport-tests.sh`)
   reproduced it at `1bb701c`. Permanent deletion removed the snapshot, the journal, the
   auxiliary state, `LegacyBackups/`, the native Keychain and the App Group values, but not
   the RN source files. The next launch found no snapshot (`shouldAttempt`,
   `N/AppStore.swift:786`) and no completed journal
   (`N/LegacyMigrationCoordinator.swift:628`) and imported the deleted account again: its
   records, its auxiliary state with the owner marker, new backups, and its legacy Supabase
   session and provider key, published to the native Keychain. A deletion left pending
   and finished at launch did the same in that launch. Account B's sign-in then stopped at
   the account-mismatch gate, and B's launch activation adopted A's re-imported workspace
   when the RN data had no owner keys, so B's initial sync would queue A's records under B.
   **Rule:** after a permanent account deletion nothing from that account is re-imported.
   The retention above ends at a permanent deletion, and the erase is install-wide, not
   per account: the RN source files hold whichever account the RN build last had. If A
   signed out and B then deletes B's account on the same device, A's RN-era files go too;
   A's synced data stays in A's cloud account, but that device no longer has A's RN-era
   rollback source. **Fix (option a):** the deletion (`.all`) scrub ends by erasing what the
   importer reads from the RN app: every AsyncStorage candidate directory, the Documents
   photo directories and the legacy Expo SecureStore services (`NativeLegacySourceEraser`,
   `N/LegacyMigrationCoordinator.swift`); every scrub already wipes the App Group values.
   It runs under the account-scrub marker, after the rest of the wipe, so a failure (a
   locked Keychain, say) leaves the deletion pending, the launch migration does not run,
   and the next launch or Retry erases again. Each removal is verified, and an absent item
   counts as done. A tombstone (option b) was not chosen: it would keep the deleted
   account's data on the device, and a Keychain tombstone survives a reinstall. Sign-out,
   the recovery exits and the account switch keep the RN source files and the completed
   journal, so nothing is imported again (tested). 12.06's host test that no code path
   deletes the RN source files or `LegacyBackups/` after a verified import must exempt
   this one path. Device row: P12-B2F-1 (evidence index §23).

### 5.5 OI-3 — 429 push policy

Facts at `1bb701c`: a 429 is transient (`N/NativeSupabasePush.swift:189`), so each queued
item gets one request per pass, the throttled items stay queued, and no pull runs after a
failed or partial push. After a failure the next automatic pass waits an exponential
backoff: base 5 s doubling to a 300 s cap in the app (`N/NativeSyncCoordinator.swift:140`,
`:141`, `:388`). The "30 s, then 60 s" in the Phase 11 documents is the poor-network
harness's 30 s base, not the app's. User-initiated syncs (the Sync buttons,
pull-to-refresh, calendar refresh) bypass the backoff (`N/NativeSyncCoordinator.swift:7`, `:211`).
One device with N queued items therefore sends up to N requests per pass, at most one
automatic pass per backoff interval, plus manual syncs.

*2026-09-26 (12.02, ruling R19):* since 12.00b.1 a push pass that reaches per-item results
pulls afterward even with changes still queued, including under a 429 (contract §17.2, I2);
only a thrown push skips the pull. A throttled pass therefore sends N push requests plus at
least 12 pull reads (10 collections, settings and customer notes; more with extra 500-row
pages). `docs/native-phase-12-monitoring.md` §5 has the signal math.

Policy (provisional):

1. Accept the current behavior for Stage A and Stage B. No code change now.
2. **Signal (monitored, not blocking):** every 429 pass is counted (TH-6). Review it as an
   S3 finding when one device has 429 codes on 3 consecutive passes, when 2 or more devices
   get a 429 within the same hour, or on any 429 in Stage A, where synthetic load should
   not reach a rate limit.
3. **Blocker:** a 429 that leaves a device's queue undrained for 24 hours while online
   (TH-3, S2), or server evidence that one device's pass itself trips the limit. Then the
   push must stop the pass at the first 429 (a 12.00b-class change with its own test)
   before Stage C.
4. **Facts to collect before Stage B entry:** the real rate limits of the Supabase project
   and the Worker (owner, from the dashboards); the SA3 load check against isolated staging
   measures behavior under them.

## 6. Rollback data decision

Recorded as plan 12.00 step 5 states it; 12.06 implements and rehearses it.

1. The rollback (Expo) build treats the cloud as authoritative: a forced pull, with a
   warning when unsynced changes exist.
2. The native build drains its mutation queue before any rollback advisory is published.
3. The native migration journal guarantees that a re-upgrade adopts newer native or cloud
   state and never re-imports stale legacy AsyncStorage.

12.06 builds the native half, (2) and (3), with host tests before the rehearsal (plan
12.06 step 3). Rejected changes (I2) cannot be drained; the advisory reports them as not
drainable. Rule (1) is Expo-side and Phase 12 agents do not edit RN code, so 12.06 records
whether the release branch's existing pull meets it and who makes any change. Today a
completed import returns `.alreadyCompleted` without reading the source again
(`N/LegacyMigrationCoordinator.swift:628`), and a native snapshot without migration
provenance is never replaced (`:668`). Permanent deletion loses the journal, so it also
erases the RN source files, install-wide and not scoped to the deleted account (G6-Q1,
resolved: §5.4 item 5); rule (3) applies while an account's data is still live on the
device, i.e. before that install-wide erase.

## 7. Exposure control at cutover

Apple documentation read 2026-09-25:

- "Release a version update in phases":
  https://developer.apple.com/help/app-store-connect/update-your-app/release-a-version-update-in-phases
- "Select an App Store version release option":
  https://developer.apple.com/help/app-store-connect/manage-your-apps-availability/select-an-app-store-version-release-option/
- "Manage availability for your app on the App Store":
  https://developer.apple.com/help/app-store-connect/manage-your-apps-availability/manage-availability-for-your-app-on-the-app-store/
- "Make a version unavailable for download":
  https://developer.apple.com/help/app-store-connect/manage-your-apps-availability/make-a-version-unavailable-for-download/

What the controls do, per those pages:

| Control | Behavior |
|---|---|
| Phased release | For a **version update** only (the native binary is an update to the existing app record). Over 7 days a random sample of users **with automatic updates on** gets the update: 1%, 2%, 5%, 10%, 20%, 50%, 100%. Anyone can still download the version manually from the App Store at any time, which covers new installs and manual updates. Selected on the version before release ("Release update over a 7-day period using phased release") |
| Pause / resume | Pause as often as needed, up to **30 days in total**; a resume picks up on the day it stopped. A pause does not stop manual downloads |
| Release to All Users | Available at any time once the version is Ready for Distribution; every device with automatic updates on gets it |
| Manual release | "Manually release this version" holds an approved version in Pending Developer Release until "Release This Version". It can take **up to 24 hours** to appear on the App Store. Apple emails a reminder after 30 days pending |
| Remove App From Sale | Pricing and Availability › Remove App From Sale. The **whole app** leaves the App Store in all regions **within 24 hours**. Users who downloaded it keep it, keep receiving updates and can redownload from purchase history. The phased release stops and is not available for that version again; when the app is reinstated, the version goes to all users at once |
| Make a version unavailable | Applies to **previous** versions only. For a version that is Ready for Distribution with an issue, Apple says to submit an update, or remove the entire app from sale |

The rule for this cutover (provisional):

1. With no installed base, the phased release gates almost nothing. **New installs are
   the exposed cohort**, and they get the native version as soon as it is live.
2. The controls that matter: **manual release timing** (release only on a planned watch
   day, §1) and, on a breach, **Remove App From Sale** to stop new installs. Pause the
   phased release as well, so that nothing advances.
3. Keep the phased release on anyway: it costs nothing and gates any auto-updating
   installs.
4. After a removal, reinstate only when the version that should be served is the one live.
   Reinstating serves the current version to everyone at once, and a later controlled
   rollout needs a new version submitted with phased release (12.06 plans the order).

**Corrections to plan 12.07 step 3** (this section wins): (a) the current version cannot be
"removed from sale" on its own; the only removal is the whole app, which also ends the
phased release for that version; (b) Apple's page does not say "new installs"; it says
anyone can download a version in phased release manually at any time, so the plan's
conclusion still holds.

## 8. Maintaining this charter

One writer: the 12.00 lane (the owner, or an agent the owner instructs). Later tasks change
only the defect list's Status column (the fixing commit, or "Fixed, device evidence
pending" with the 12.03 row; a host-only fix never closes a device row or makes a parity
row `Verified`) and add rows to "New in Phase 12". A threshold, severity or gate change is a decision-log row plus an edit
here, in one commit. After any edit, run `sh native/run-doc-reference-check.sh`.

## 9. Decision log

Format (append-only; newest last):

| # | Date | Stage | Decision | Evidence | Decider | Rollback trigger considered |
|---|---|---|---|---|---|---|
| 1 | 2026-09-25 | pre-A | D1: G1 native push waived with a dated waiver (§5.1); 12.00b.4 not built | plan §1.3 | owner | n/a (no release) |
| 2 | 2026-09-25 | pre-A | D2: G2 tax-settings editor built in 12.00b.3 | plan §1.3 | owner | n/a |
| 3 | 2026-09-25 | pre-A | D3: I2 surface and actions as §5.3 | plan §1.3 | owner | n/a |
| 4 | 2026-09-25 | pre-A | D4: no isolated staging yet; hard blocker; `https://staging.invalid` stays | plan §1.3 | owner | n/a |
| 5 | 2026-09-25 | pre-A | D5: the owner holds every role (§1) | plan §1.3 | owner | n/a |
| 6 | 2026-09-27 | pre-A | Bookkeeping (not an owner decision): defect-list state refreshed at `2bcfc07` — Status reconciled against `git log 6d573a7..2bcfc07`; `12.02-F4` renumbered `P12-009`; `P12-010` and `P12-014` added; §10 intro's "Open S1/S2 needing code" list corrected to name `P12-012` as the sole open blocker | §10 (`6f6159b`) | task 14 (agent) | n/a (bookkeeping) |
| 7 | 2026-09-27 | pre-A | Bookkeeping (not an owner decision): records the ruling grammar the offline stage preflight enforces (controller rulings R65 and R67). A defect-list ruling counts only as a row here whose Decider is exactly owner and whose Decision cell is exactly the defect ID, one space, ruled:, one space and the ruling token, with nothing else in the cell. A later row here that names the same ID and contains the revoking word re-blocks that defect, whoever decides; a later row in the exact ruling form clears it again. The production-configuration line (R59) in the release-readiness doc follows the same two rules. The wording is set out under this table | §9 below this table; `native/run-phase-12-stage-preflight.sh` (`ruling_is_recorded`, section 5); `native/run-phase-12-stage-preflight-tests.sh` | controller (agent) | n/a (bookkeeping) |
| 8 | 2026-09-29 | pre-A | Charter approved as written; thresholds stay provisional for Stage A and are re-ratified at Stage B entry (§0) | Owner instruction in the Claude Code session of 2026-09-29 (approved the charter in chat) | owner | n/a (no release) |
| 9 | 2026-09-29 | pre-A | OI-1 decided: the release-readiness §5 privacy-label proposal is approved as written, and the matching `NSPrivacyCollectedDataTypes` edit to `N/PrivacyInfo.xcprivacy` is authorized and applied (EmailAddress, Name, PhoneNumber, PhysicalAddress, PhotosorVideos, OtherUserContent, all App Functionality, linked, not tracking). The owner still enters the labels in App Store Connect before Stage C entry | Owner instruction in the Claude Code session of 2026-09-29; `N/PrivacyInfo.xcprivacy`; `native/ErrorRedactionTests/main.swift` manifest pin | owner | n/a |
| 10 | 2026-09-29 | pre-A | VER-1 partly decided: the native release version N is 2.0 (`MARKETING_VERSION = 2.0.0` on both targets). The live Expo version L is not yet confirmed in App Store Connect. R must exceed N, and N2 must exceed R (playbook §3.2) | Owner instruction in the Claude Code session of 2026-09-29 ("App Store version should be 2.0"); `project.pbxproj` | owner | n/a |
| 11 | 2026-09-29 | pre-A | OI-2 reported cleared: the owner says the Sentry project `tradeready-ios` (org `tradeready-3r`) now exists. Not verifiable from the repository | Owner instruction in the Claude Code session of 2026-09-29 | owner | n/a |
| 12 | 2026-09-29 | pre-A | P12-012: the owner chose to fix the defect on the Expo side (playbook §5.3 E-1 to E-4) instead of accepting the risk. Branch `expo/e1-native-run-guard`. The defect stays Open until that change is reviewed, merged into the Expo release branch and built into the rollback candidate R | Owner instruction in the Claude Code session of 2026-09-29 ("make the fix on the expo side") | owner | n/a |
| 13 | 2026-09-29 | pre-A | VER-1 cleared: the live App Store version L is 1.2.1, as `app.json` says. With N = 2.0.0 (row 10) the rule L < N holds. R must be above 2.0.0, and N2 above R (playbook §3.2) | Owner instruction in the Claude Code session of 2026-09-29 ("Current App Store version 1.2.1") | owner | n/a |
| 14 | 2026-09-29 | pre-A | R59 decided: there will be no staging build. Release is the production configuration: `TRADEREADY_ENVIRONMENT = production`, the production Worker origin, and production writes enabled. Debug stays development against localhost. D4 is superseded as a provisioning task. **Not decided here:** every gate and evidence row that requires isolated staging (STG rows, SA3, Stage A exit, the D4 rows the docs say are never waived) still reads as written; the owner must amend or waive each in a later row. Until then, Release and TestFlight builds write to the production backend, so use disposable accounts for every test | Owner instruction in the Claude Code session of 2026-09-29 ("no staging build at all, everything for release"); `project.pbxproj`; release-readiness §3.1 | owner | n/a |
| 15 | 2026-09-29 | pre-A | AGG-1 bookkeeping (not an owner decision): the `backend-workers` test script exists and passes, so the blocker is cleared | `backend-workers/package.json`; `npm test` there: 26 tests, 0 failures | agent | n/a (bookkeeping) |
| 16 | 2026-09-28 | pre-A | Bookkeeping (not an owner decision): defect list reconciled at `3d26fad` against the 2026-09-20 fix list (`docs/native-migration-fix-tasklist.md`: F1 to F12 and the Phase 7 recurring-invoice gap), which no Phase 10–12 document had tracked. `P12-023` (S1), `P12-024` to `P12-029` (S2) and `P12-030` to `P12-034` (S3) added; §10 intro corrected: the open Stage A blockers are now `P12-012`, `P12-023` and `P12-024` to `P12-029`. The severities are the finder's; any change is the owner's (§2 rule 3) | §10 "New in Phase 12"; each fix-list item re-checked by reading code at `3d26fad` | fix-list reconciliation (agent) | n/a (bookkeeping) |
| 17 | 2026-09-30 | pre-A | Bookkeeping (not an owner decision): defect-list Status updated for P12-023 to P12-028 after their fixes landed in the working tree (`supabase/migrations/20260920-20260922`, `supabase/verify/`, `N/AppStore.swift`, `N/NativeScheduleBookingStore.swift`, both link screens, `N/Domain/NativeBookingAttention.swift`). P12-024, -026, -027, -028 read Fixed; P12-023 and P12-025 stay Open for the staging proof. P12-029 and P12-012 are unchanged: each waits for an owner ruling | §10; `sh supabase/verify/local/run.sh`; `sh native/run-schedule-booking-recovery-tests.sh`; `sh native/run-booking-attention-tests.sh` | agent | n/a (bookkeeping) |
| 18 | 2026-09-30 | pre-A | P12-029: severity S2 to S3; accepted as a permanent limitation | Owner decision in chat, on the agent's recommendation. Two devices offline for the same recurring occurrence can each generate an invoice, exactly as the Expo engine does (`inv<ms>` IDs; pinned in `native/RecurringInvoiceTests/main.swift`). Sequential generation after a pull converges and is the normal path. A deterministic-ID fix would change the `inv<ms>` IDs that issue-date extraction and the Expo rollback build rely on, for a rare case that already exists today. Evidence row P7-25 is reconciled to record the outcome rather than require no double bill. See §10 P12-029 and evidence index P7-25 | owner | n/a |
| 19 | 2026-09-30 | pre-A | P12-012 ruled: R43 | The owner accepts the stale-queue risk for Stage A (chat, 2026-09-30), against the agent's recommendation to build E-1 to E-4 first. This supersedes row 12 (2026-09-29), where the owner chose to fix P12-012 on the Expo side; the Expo branch `expo/e1-native-run-guard` is no longer required for Stage A. Reason: there are no current app users (project rule: correctness over existing-user continuity), so a rollback to the Expo build has no newer native rows for its stale pre-upgrade queue to overwrite. The exposure returns if real users exist before the §5.3 build ships; the owner then revokes this ruling. Playbook §2.2 condition 4 and rows P12-RB-1 to P12-RB-3 and P12-RB-7 stay as written. See §10 P12-012 and playbook §5.3 | owner | n/a |
| 20 | 2026-09-30 | pre-A | P12-023: local proof accepted in place of the staging proof; closed on that basis | Owner decision in chat, 2026-09-30: the local-PostgreSQL proof (`sh supabase/verify/local/run.sh`, 50 checks, real concurrent sessions, negative control) is accepted in place of the isolated-staging proof, and no staging environment will be built unless the project gets real users. The local database only imitates Supabase's default privileges and PostgREST JWT claims, so that gap is accepted. Condition: when the Phase 8 migrations are first applied to a live Supabase project, run the read-only queries in `supabase/verify/booking_lifecycle_rpcs.sql`, `booking_admin_state.sql` and `portal_token_admin.sql` on it straight after (the grant queries must return zero rows); a non-empty result reopens the defect. Row 14 (no staging build; D4 superseded as a provisioning task) is consistent with this | owner | n/a |
| 21 | 2026-09-30 | pre-A | P12-025: local proof accepted in place of the staging proof; closed on that basis | Owner decision in chat, 2026-09-30: the local-PostgreSQL proof (`sh supabase/verify/local/run.sh`, 50 checks, real concurrent sessions, negative control) is accepted in place of the isolated-staging proof, and no staging environment will be built unless the project gets real users. The local database only imitates Supabase's default privileges and PostgREST JWT claims, so that gap is accepted. Condition: when the Phase 8 migrations are first applied to a live Supabase project, run the read-only queries in `supabase/verify/booking_lifecycle_rpcs.sql`, `booking_admin_state.sql` and `portal_token_admin.sql` on it straight after (the grant queries must return zero rows); a non-empty result reopens the defect. Decision D4 (no isolated staging) stands | owner | n/a |
| 22 | 2026-10-01 | pre-A | RESEND: the production Worker's `RESEND_API_KEY` secret is confirmed present (G1 waiver condition: email is the only booking alert) | Owner ran `npx wrangler secret list` from `backend-workers/` (2026-10-01); the name appears in the list. The value was never read or recorded | owner | n/a |
| 23 | 2026-10-01 | pre-A | Export compliance: `ITSAppUsesNonExemptEncryption = false` added to `native/Info.plist`, and the App Store Connect question answered "None of the algorithms mentioned above" for the first Stage A build | Owner approval in chat, 2026-10-01; release-readiness §4.3 (standard HTTPS/TLS and Apple CryptoKit only); `plutil -lint native/Info.plist` OK; unsigned Release build carries `false` | owner | n/a |
| 24 | 2026-10-01 | pre-A | TF-INT: the Stage A build 2.0.0 (1) is uploaded to App Store Connect and processed. It has not been submitted for review or beta review, and the internal testing group is not yet recorded as added | Owner report in chat, 2026-10-01 (the build shows Ready to Submit in App Store Connect); uploaded with `native/phase-12-testflight-upload.sh --execute`; archive carries the Sentry DSN and the embedded `TradeReadyWidgets.appex` | owner | n/a |
| 25 | 2026-10-01 | pre-A | Stage A build 2.0.0 (2) uploaded to App Store Connect, replacing build 1 for the SA2 upgrade run. Build 1 stalled on "Data migration paused" (`NativeSecureSettingsStoreError/3`, `conflictingNativeSession`: a session left in the keychain by an earlier native debug build blocked the import; nothing was imported). Build 2 carries the fix (commit `4fe8a10`: the migrated session replaces a stale native one), the `ITSAppUsesNonExemptEncryption` key and the Sentry DSN. Not submitted for review; processing, the internal group and the on-device result are not yet recorded | Owner report in chat, 2026-10-01 (upload succeeded); on-device support report showing the failure code; `sh native/run-migration-coordinator-tests.sh` and `TZ=America/Phoenix sh native/run-all-domain-tests.sh` pass; unsigned Release compile succeeds | owner | n/a |
| 26 | 2026-10-01 | pre-A | SA2 upgrade run on build 2.0.0 (2): the migration completed on a physical iPhone that held a stale native keychain session from an earlier debug build (the case that stalled build 1). The app showed that the data was migrated and opened. The owner reports the test run successful. Individual evidence rows (P2-P2, P12-3B-1, P12-3B-2 and the variant rows) are not itemized here and stay open until each is recorded in `EI §23`/`§24` | Owner report in chat, 2026-10-01: the phone showed the data-migrated message on first launch of build 2; the owner reports the test run successful. No support report, record counts or per-row results were attached to this row | owner | n/a |
| 27 | 2026-10-01 | pre-A | Stage A run 1 results recorded in `EI §24`. OWN-1 and OWN-2 stay blocked: they are STG rows, ran against production, and are not waived (EI §2 rule 5). The rollback rows P12-RB-2, -3, -5 and -7 ran against the plain App Store 1.2.1 build, not the Expo rollback candidate R, so they do not close; their evidence cells stay `[ ]`. No device model, iOS version, account alias or external evidence link was supplied, so no row closed | Owner decision and report in chat, 2026-10-01; `EI §24` Stage A run record | owner | n/a |
| 28 | 2026-10-01 | pre-A | Expo rollback candidate R: the owner chose to build it from the 1.2.1 code with only the §5.3 change, not from `master`, because `master` carries unreleased Expo features. The prepared branch `expo/rollback-candidate-r` (from `b57f304`) adds the pull-cursor fix `703064c` as a prerequisite of E-1, which is a deviation from the playbook's "only the §5.3 change": E-1 clears local copies and relies on a full pull, and the 1.2.1 pull does not page. Playbook §4 records it. Not built, not uploaded; the L commit is unconfirmed, the E-1 wording is placeholder and the marker read is unverified on a device | Owner instruction in chat, 2026-10-01; branch commits `0ce360b` and `277f680`; `tsc --noEmit`, the full Expo suite (207 suites, 2,845 tests) and lint pass on the branch | owner | n/a |

Row 8 is the owner's approval of this charter. A go/no-go row names
the checklist (§4.x) and links the evidence-index rows; "Rollback trigger considered"
names each §4.8 trigger checked and its state.

**Recording a defect-list ruling (a strict grammar, ruling R65).** When an open S1/S2
defect-list row (§10) cites a ruling in parentheses (the pattern is "until the owner
records a ruling (R<n>)"), `native/run-phase-12-stage-preflight.sh` treats that ruling as
recorded only when a row here satisfies **all** of the following. There is no word list
of accepted or rejected phrasings — anything that is not this exact shape is not a
ruling, and the gate fails closed:

1. It is a real table row.
2. Its **Decider** cell, trimmed and read case-insensitively, is exactly `owner`.
3. Its **Decision** cell, trimmed, is **exactly** `<D> ruled: R<n>` — the defect ID, one
   space, `ruled:`, one space, the ruling token, and nothing else. No rationale, dash,
   parenthetical or trailing punctuation belongs in this cell; put the reason in the
   Evidence cell instead.

Any other wording — a qualifier before or after the marker, "unruled:"/"overruled:"
instead of "ruled:", a different Decider, or a ruling bound to a different defect ID in
the same row — is not a ruling, whatever it says.

**Revoking a ruling is lenient (ruling R67, 2026-09-27).** Rulings are strict so that a
near-miss never unblocks a defect; revocations are lenient so that a near-miss never
leaves one unblocked. Any later row in this section that names the defect ID and
contains the word "revoked" in any letter case re-blocks the defect, whoever the
Decider is and whatever else the row says (`<D> revoked: R<n>` is the recommended form;
`<D> revoked: R<n> (draft)`, `<D> Revoked: R<n>` or a revoke with its reason inline all
count). The one exception is a row in the exact ruling form above (owner Decider,
Decision cell exactly `<D> ruled: R<n>`): that row is always a ruling, even when its
Evidence cell mentions a revoked row. The log is append-only, newest last, so the last
ruling-or-revoking row for the defect decides: after a revoke, only a later row in the
exact ruling form above clears the defect again. Only the word "revoked" revokes; write
it rather than "withdrawn" or "unruled".

Worked example (fictional IDs; this is not a real ruling on anything in §10):

| # | Date | Stage | Decision | Evidence | Decider | Rollback trigger considered |
|---|---|---|---|---|---|---|
| 7 | 2026-10-01 | pre-A | P12-0NN ruled: R00 | The owner accepts \<the specific risk\> for Stage A because \<reason\>; see \<evidence link\>. | owner | n/a |

A real row ruling on `P12-012`'s stale-queue risk would have a Decision cell reading
exactly `P12-012 ruled: R43`, with the reason in the Evidence cell and `owner` in the
Decider cell, exactly like the worked example above.

The production-configuration decision (R59) is not a row here: it is one line in
`docs/native-phase-12-release-readiness.md` reading exactly `Production configuration
decision: <the decision> ruled: R<n>`, ending at `R<n>`, with no `<...>` placeholder left
in it. It is revoked the same lenient way: any later line in that doc that contains
"revoked" (any case) and names the decision ("Production configuration decision"), R59,
or the ruling the decision line cites re-blocks it, until a later exact decision line. A
line in the exact decision form is always a decision, even if it also contains
"revoked".

## 10. Defect list

Source: plan §7 (the Phase 11 parked-minor triage, verified against `6d573a7`). An ID is
the Phase 11 controller-ledger line (`L130`; `L205.c` is the third item on line 205); `T1`
was found by the triage. The evidence column stays in plan §7. **State @`6d573a7`** is
frozen; **Status** is the live column later tasks update (§8).

Counts: 89 defect rows (S1 2, S2 17, S3 70; 16 closed) plus 3 pointers to 12.03. This
count is the original Phase 11 triage list (plan §7) only; "New in Phase 12" (below) is
counted separately in its own heading.
Handling: 12.00b.1 1, 12.00b.2 10, rider 6, doc batch 11, 12.01 check 2, 12.02 1,
backlog 35, record 23 (16 closed, 7 accepted). The 12.02 review added the backlog row
L193.b-rest (2026-09-26); its other addition, `12.02-F4`, is renumbered `P12-009` below
(task 14, R40). **Refreshed 2026-09-27 at `2bcfc07`** (task 14, defect-list refresh):
every row's Status was reconciled against `git log 6d573a7..2bcfc07`; no open item was
found with an un-recorded fixing commit. **Open S1/S2 needing code (Stage A blockers):
none of the original Phase 11 triage rows** (L238, L74, L96, L130, L131, L237.d, L267.a,
L286.1, L286.4, L286.5a, L286.5b are all Fixed — see their rows below). At the
2026-09-27 refresh the one open Stage A blocker was **P12-012** (S1, "New in Phase 12"),
gated on the owner's ruling (R43); P12-013, P12-015, P12-016 and P12-017 (all S2) are
Fixed. **Reconciled 2026-09-28 at `3d26fad`** against the 2026-09-20 fix list
(`docs/native-migration-fix-tasklist.md`), which no Phase 10–12 document had tracked:
it adds **P12-023** (S1) and **P12-024 to P12-029** (S2) as open Stage A blockers, and
P12-030 to P12-034 (S3 backlog). The open Stage A blockers are now P12-012, P12-023 and
P12-024 to P12-029. **2026-09-30 (later):** P12-029 is Closed as an accepted S3 limitation (§9 row 18); P12-012 is ruled R43 (§9 row 19) and no longer blocks Stage A entry. **2026-09-30:** P12-024, P12-026, P12-027 and P12-028 are fixed on the
branch (host evidence). P12-023 and P12-025 have landed fixes that are host-proved on a
local PostgreSQL; the owner accepted that proof in place of staging (§9 rows 20 and 21), so both are Fixed. No Stage A blocker remains open on the defect list.

What each handling means: **12.00b.1 / 12.00b.2** — fixed in that build item; blocks Stage
A. **rider** — S3 fixed inside 12.00b.2 because that change edits the same code; does not
block Stage A. **doc batch** — fixed in 12.00's separate docs-only commit. **12.01 check /
12.02** — done inside that task. **backlog** — S3 post-cutover work; does not block Stage
A. **record** — no action: closed (kept for audit) or accepted behavior.

### 12.00b.1 — I2 rejected-change handling (blocks Stage A entry) (1)

| ID | Item | Sev | State @`6d573a7` | Handling | Status |
|---|---|---|---|---|---|
| L238 | I2: a non-auth 4xx is retried forever, and every pull is skipped while it is queued | S2 | Open | **12.00b.1** (unwaivable). **Residuals, rated S3 (2026-09-25):** past the 100-entry cap the oldest refused change is dropped and counted; the password-recovery exits scrub the store but keep the records, with the same effect; so does "Use another account", which scrubs the store and keeps the workspace (since the final review, M4, the switch and the recovery exits also reset the sync coordinator, as a sign-out does, so a push still on the wire files nothing under the next owner's tag). A refused record does not hold its table's watermark (the pull keeps its local version while it is refused and advances the cursor past the server row), so once its entry is gone, by a cap drop or one of those scrubs, the device keeps the unsent local version until the server row next changes, and only that later write reaches it through a pull: until then the device and the cloud silently differ (final review M15, 2026-09-27; S3, accepted as the rest of this residual); and a newer change to a refused record that the push drops as unsendable (`record-contract`) counts as cleared, so its entry leaves the list. The server would never accept those edits anyway | Fixed — 12.00b.1 (host) (`fix(native): phase 12.00b.1 - I2 rejected changes leave the queue and sync keeps pulling`; `feat(native): phase 12.00b.1 - Cloud Sync lists changes that couldn't be saved (D3)`; `fix(native): phase 12.00b.1 - review fixes (no-binding fail-closed, per-item 403, tests, copy)`; `fix(native): phase 12.00b.1 - rejected store uses after-first-unlock protection; docs reconcile Discard (review prep)`; final-review fix (M4) in `fix(native): phase 12 final review - pull marks, cold-launch stamp guard, switch reset, recovery save code (M1-M5)`) |

### 12.00b.2 — S1/S2 code fixes (block Stage A entry) (10)

| ID | Item | Sev | State @`6d573a7` | Handling | Status |
|---|---|---|---|---|---|
| L74 | `NativeWidgetMirror.write` takes a blocking `flock` on the MainActor with no timeout | S2 | Open | **12.00b.2**: bounded try-lock in `WidgetAppGroupLock` (one fix with L96) | Fixed — 12.00b.2-B (`fix(native): phase 12.00b.2 - bounded App Group lock on the main actor (L74, L96)`; review fixes in `fix(native): phase 12.00b.2 - lock review fixes (fast-fail window, busy diagnostics, test hardening)` (`a257dd1`)) |
| L96 | `OnMyWayIntent.perform()` takes the same blocking `flock` on the MainActor | S2 | Open | **12.00b.2** (with L74) | Fixed — 12.00b.2-B (`fix(native): phase 12.00b.2 - bounded App Group lock on the main actor (L74, L96)`; review fixes in `fix(native): phase 12.00b.2 - lock review fixes (fast-fail window, busy diagnostics, test hardening)` (`a257dd1`)) |
| L130 | One malformed, duplicate or over-512 widget/Siri queue entry quarantines the whole batch, so valid actions (clock-ins, expenses, trips) are never applied | **S1** | Open | **12.00b.2**: quarantine only the bad entries when the queue parses. A whole-batch quarantine stays only for unparseable bytes, and the raw bytes are still retained. Amend contract §4.6 | Fixed — 12.00b.2-C (`fix(native): phase 12.00b.2 - replay quarantines only bad widget/Siri entries (L130, L131)`; `fix(native): phase 12.00b.2 - replay review fixes (claim-record retention, unreadable claims, message precedence)`) |
| L131 | `invalidClaim`/`conflictingClaims` retry forever and the claim is never quarantined, which wedges that owner's replay | S2 | Open | **12.00b.2**: quarantine the bad claim with a bounded diagnostic. Today's workaround is sign-out/in, which clears claims | Fixed — 12.00b.2-C (`fix(native): phase 12.00b.2 - replay quarantines only bad widget/Siri entries (L130, L131)`; `fix(native): phase 12.00b.2 - replay review fixes (claim-record retention, unreadable claims, message precedence)`); a regular claim file that stays unreadable still fails closed, counted (`unreadableClaimCount`) |
| L237.d | Returning-user launch runs `refreshRecurringJobs()` but not `refreshRecurringInvoices()`, while RN runs both | S2 | Open | **12.00b.2**: add the invoice refresh, with a test cross-checked against RN | Fixed — 12.00b.2-E (`fix(native): phase 12.00b.2 - returning-user launch also generates recurring invoices (L237.d)`) |
| L267.a | `protectCopiedLegacyFiles` returns silently on a nil enumerator, so the legacy AsyncStorage backup that can hold the G6 residual is never protected | S2 | Open | **12.00b.2**: treat a nil enumerator as a per-file failure (diagnostic plus journal retry); consistent with the G6 policy | Fixed — 12.00b.2-E (`fix(native): phase 12.00b.2 - nil enumerator logs a diagnostic instead of skipping legacy file protection (L267.a)`; `fix(native): phase 12.00b.2 - legacy backup copies are re-protected until protection succeeds (L267.a)`; `fix(native): phase 12.00b.2 - launch re-protects a completed migration's legacy backup copy (L267.a)`) |
| L286.1 | Widget/Siri replay markers (`__nativeWidgetStartActionID`/`StopActionID`) sit in session `unknownFields`, are pushed to Supabase inside the job, and RN keeps them forever | S2 | Open | **12.00b.2**: first confirm replay idempotency survives a pull that replaces the job, then strip `__native*` keys from pushed payloads. The test asserts no queued payload carries one | Fixed — 12.00b.2-D (`fix(native): phase 12.00b.2 - replay markers stay local (L286.1)`; review fixes in `fix(native): phase 12.00b.2 - replay markers stay local, review fixes (L286.1)` (`85bf192`)) |
| L286.4 | "Try cleanup again" cannot reach a pending boundary step, and `signUp`'s immediate-session branch skips the pre-bind retry | S2 | Open | **12.00b.2**: surface pending boundary steps in the retry affordance, and route `signUp` through the pre-bind retry | Fixed — 12.00b.2-A (`fix(native): phase 12.00b.2 - account-boundary steps survive double failure (L286.5b, L286.4, L286.5a)`) |
| L286.5a | `aiProviderKeyIsSaved` ignores the pending AI-key-wipe marker, so Settings can show account B "Saved" for account A's key | S2 | Open | **12.00b.2**: gate it like the advisory reads | Fixed — 12.00b.2-A (`fix(native): phase 12.00b.2 - account-boundary steps survive double failure (L286.5b, L286.4, L286.5a)`) |
| L286.5b | If a boundary step's marker write and its wipe both fail, the pending state lives only in memory. After a relaunch the gates reopen over A's AI key or widget data | **S1** | Open | **12.00b.2**: fail closed durably. A step whose marker cannot be written must not let the next owner bind. Add a double-failure-then-relaunch test. **Note (2026-09-25, 12.00b.2-A review I1):** as built, the next owner binds but stays gated: sign-in retries the pending steps first, and while one is still pending B gets no widget mirror, no replay and no AI key. AI keys are also owner-tagged, so even when the marker, the Keychain record and the wipe all fail and the app relaunches, A's key reads as absent for B. Residual, rated **S3**: the widget step's share of that triple failure. Replay stamped for A is dropped, B's first mirror write overwrites A's snapshot, and the widget extension showing leftover App Group data until then is pre-existing | Fixed — 12.00b.2-A (`fix(native): phase 12.00b.2 - account-boundary steps survive double failure (L286.5b, L286.4, L286.5a)`; review fix `fix(native): phase 12.00b.2 - owner-tagged AI keys close the boundary residual (L286.5b review)`) |

### Rider — S3 fixed inside 12.00b.2 (does not block Stage A) (6)

| ID | Item | Sev | State @`6d573a7` | Handling | Status |
|---|---|---|---|---|---|
| L205.a | `canChangeAIProviderKeys` comment omits the switch and pending-wipe guards | S3 | Open | rider (with L286.5a) | Fixed — 12.00b.2-A (`fix(native): phase 12.00b.2 - account-boundary steps survive double failure (L286.5b, L286.4, L286.5a)`) |
| L205.e | Switch and recovery exit wipe only the AI key kinds. The migrated `providerKey` Keychain entry survives until sign-out or delete (`clearAccountValues()`); nothing reads it after migration. (triage text corrected by plan ruling R4) | S3 | Open | rider (with L286.5b) | Fixed — 12.00b.2-A (`fix(native): phase 12.00b.2 - account-boundary steps survive double failure (L286.5b, L286.4, L286.5a)`) |
| L205.g | `aiProviderKeyState` reads the Keychain synchronously in a SwiftUI `body` | S3 | Open | rider (with L286.5a) | Fixed — 12.00b.2-A (`fix(native): phase 12.00b.2 - account-boundary steps survive double failure (L286.5b, L286.4, L286.5a)`) |
| L286.2 | `requestDestructive()` re-reads the stored `actionRule` instead of the dialog's `rule` (the I1 failure class) | S3 | Open | rider (take the rule from the call site) | Fixed — 12.00b.2-E (`fix(native): phase 12.00b.2 - destructive plan confirmation targets the dialog's captured rule (L286.2)`) |
| L286.3 | A stale comment says `useAnotherAccount` does not hold `authenticationOperationInFlight` | S3 | Open | rider | Fixed — 12.00b.2-A (`fix(native): phase 12.00b.2 - account-boundary steps survive double failure (L286.5b, L286.4, L286.5a)`) |
| L286.7 | Session-rejected reactivation keeps `verifiedAccountBinding` and deep-link route state (fail-closed today) | S3 | Open | rider (with L286.4) | Fixed — 12.00b.2-A (`fix(native): phase 12.00b.2 - account-boundary steps survive double failure (L286.5b, L286.4, L286.5a)`) |

### Doc batch — fixed in 12.00's docs-only commit (11)

| ID | Item | Sev | State @`6d573a7` | Handling | Status |
|---|---|---|---|---|---|
| L65 | Contract decision table lists C22 before C21 | S3 | Open | doc batch | Closed — 12.00 doc batch (`1c6859a`) |
| L141.a | Phase 11 plan §7 11.05 entry contradicts itself on parked-route handling | S3 | Open | doc batch | Closed — 12.00 doc batch (`1c6859a`) |
| L141.b | Contract C8 row still says "blocked until 11.05 decides", though §4.6 resolved it | S3 | Open | doc batch | Closed — 12.00 doc batch (`1c6859a`) |
| L205.c | Parity "AI Assistant" row omits the "Unavailable" key state | S3 | Open | doc batch (with T1) | Closed — 12.00 doc batch (`1c6859a`) |
| L205.d | Phase 11 plan §7 repeats "Next ready: 11.10a" | S3 | Open | doc batch | Closed — 12.00 doc batch (`1c6859a`) |
| L223.b | IPAD-KB-1 omits "cancel a swipe-back, then ⌘N" | S3 | Open | doc batch; 12.03 copies the fixed row | Closed — 12.00 doc batch (`1c6859a`) |
| L237.a | Phase 11 plan §6 and the parity "Supabase sync" row omit round 3 and scenarios G–H | S3 | Open | doc batch | Closed — 12.00 doc batch (`1c6859a`) |
| L249.d | Phase 11 plan still says the Today status row is 44pt | S3 | Open | doc batch | Closed — 12.00 doc batch (`1c6859a`) |
| L274.a | Phase 11 runsheet does not explain its switch to row tables | S3 | Open | doc batch | Closed — 12.00 doc batch (`1c6859a`) |
| L286.8 | Contract §17.2, the runsheet I2 row and the roadmap's I2 text omit the poison-item test and the `utils/sync.ts` line range | S3 | Open | doc batch (plan §3 12.00b.1 already specifies both) | Closed — 12.00 doc batch (`1c6859a`) |
| T1 | Parity "AI Assistant" row still lists the OI-4 known issues that `5f2f397` fixed | S3 | Open | doc batch (with L205.c) | Closed — 12.00 doc batch (`1c6859a`) |

### 12.01 check (2)

| ID | Item | Sev | State @`6d573a7` | Handling | Status |
|---|---|---|---|---|---|
| L169.a | Release build's `appintentsnltrainingprocessor` "Could not archive SSU artifacts" line was never diffed against Phase 10 | S3 | Open (unverified) | 12.01 check: diff a Release log against the native/phase-10 tip | Open (unverified) |
| L169.b | Store-integration runner's `ConformanceIsolation` warning was never diffed against Phase 10 | S3 | Open (unverified) | 12.01 check (same diff) | Open (unverified) |

### 12.02 (1)

| ID | Item | Sev | State @`6d573a7` | Handling | Status |
|---|---|---|---|---|---|
| L193.b | Only 3 of about 74 RN `reportError` sites are wired natively, with no ErrorBoundary equivalent (contract §10.4) | S3 | Open | 12.02 wires the sites that the charter's crash/error metrics read; the rest go to backlog | Done — 12.02 (`feat(native): phase 12.02 - privacy-safe support diagnostics`; review fix `fix(native): phase 12.02 - a discard in a coalesced sync pass is still reported (TH-5)` (`d00a804`)), 2026-09-26: RN `initialSync`, `purchase` and `restorePurchases` wired, plus native-only `legacyMigration`, `pushDiscarded`, `syncThrottle`, `pendingAge`, `invoicePayment` and `accountScrub`; the other 68 RN sites and the ErrorBoundary analog are backlog (`docs/native-phase-12-monitoring.md` §8) |

### Backlog — post-cutover S3 work (does not block Stage A) (35)

| ID | Item | Sev | State @`6d573a7` | Handling | Status |
|---|---|---|---|---|---|
| L75 | `widgetMirrorOwnerBinding` is internal, not private | S3 | Open | backlog | Open |
| L76 | Widget scrub-race test fakes the scrub with a manual domain wipe | S3 | Open | backlog | Open |
| L95 | `WidgetActionQueue.swift` mixes value types, models and the engine (823 lines) | S3 | Open | backlog | Open |
| L97 | Intent scrub-race test fakes the scrub (sleep plus manual wipe) | S3 | Open | backlog | Open |
| L109 | Widget `localDateString` duplicates the app's projection helper | S3 | Open | backlog (with L117) | Open |
| L110 | `.missing` and `.noUpcomingJob` share an icon; `.missing` copy is not the contract's | S3 | Open | backlog | Open |
| L117 | Four copies of the "job not before today" local-date compare | S3 | Open | backlog; consolidate under `TZ=America/Phoenix` tests (FA-039 class) | Open |
| L118 | Widget navy colour constant is duplicated | S3 | Open | backlog | Open |
| L132 | Race tests assert "not finished after 0.3s", not "blocked on the flock" | S3 | Open | backlog | Fixed — 12.00b.2-B rider (`fix(native): phase 12.00b.2 - bounded App Group lock on the main actor (L74, L96)`; the anchored writer-first scrub race; its review fixes, which hardened the race tests and wrote this list, are in `fix(native): phase 12.00b.2 - lock review fixes (fast-fail window, busy diagnostics, test hardening)` (`a257dd1`)); other `timedOut` race sites remain (backlog: `AppGroupPendingOpenURLTests:177`, `AppIntentQueueTests:867`, `WidgetOwnerGatingTests:636`, `:1512`, `:1526`, `WidgetSnapshotTests:615`, `:641`, lines as of `c620929`) |
| L133 | `testOneLock` counts exact source-string occurrences in `AppStore.swift` | S3 | Open | backlog | Open |
| L140.b | `StoreIntegrationTests` comment says there is no App-Group access, but the switch now scrubs it | S3 | Open | backlog | Open |
| L168 | Analytics-config comment names three gating conditions; the code has a fourth (invalid host) | S3 | Open | backlog | Open |
| L170.a | pbxproj host tests match literal tab/newline sequences | S3 | Open | backlog | Open |
| L170.b | `expect(!widget.isEmpty)` on the `Range` of a successful match is vacuous | S3 | Open | backlog | Open |
| L178 | About 15 store-level analytics emitters have no emission test | S3 | Open | backlog; 12.02 tests any emitter a charter metric reads | Open |
| L179.a | `deleteAccount` reset-position test compares source byte offsets | S3 | Open | backlog | Open |
| L179.b | Test-only `legacyStringValue` ships in the app target | S3 | Open | backlog | Open |
| L193.a | `NativeErrorRedaction.swift` mixes four concerns in 729 lines | S3 | Open | backlog | Open |
| L205.b | Three `if let functionBody(…)` source checks skip silently on a rename | S3 | Open | backlog | Open |
| L205.f | `bindingProvider` defaults to the real Keychain provider | S3 | Open | backlog | Open |
| L215.a | Reduce-Motion scan checks the whole file, not the enclosing type | S3 | Open | backlog | Open |
| L215.b | Unreachable `openValue ?? ""` fallback | S3 | Open | backlog | Open |
| L223.a | `mentions()` gate check ignores negation | S3 | Open | backlog | Open |
| L223.d | `NativeChangeOrdersView` has Swift-concurrency warnings | S3 | Open | backlog | Open |
| L237.b | Server-only records merge at the array end; no test pins the order | S3 | Open | backlog | Open |
| L249.a | `.bordered` tint scan accepts any text token | S3 | Open | backlog | Open |
| L249.b | Destructive-text scan matches only a literal `role: .destructive` | S3 | Open | backlog | Open |
| L249.c | "On my way" hit outset is 16pt vs RN's `hitSlop` of 8 | S3 | Open | backlog | Open |
| L264.a | Square "link saved" message persists while the user types a new draft | S3 | Open | backlog | Open |
| L264.b | Leaving Settings drops an unsaved Square draft without a prompt | S3 | Open | backlog | Open |
| L264.c | Initial-sync backfill runs before the derived-state publish binding | S3 | Open | backlog | Open |
| L264.d | Square-link check keeps a leading U+FEFF that RN's `.trim()` strips | S3 | Open | backlog (a real native difference; RN is the spec) | Open |
| L267.c | Legacy photo backup copies keep default file protection | S3 | Open | backlog | Open |
| L286.6 | `signOut`/`deleteAccount` refused mid-switch show their normal failure copy | S3 | Open | backlog | Open |
| L193.b-rest | The 68 RN `reportError` sites 12.02 did not wire (none read by a charter metric) and the ErrorBoundary analog | S3 | — (added by the 12.02 review, 2026-09-26) | backlog; the grouped list is `docs/native-phase-12-monitoring.md` §8. Wire a file-I/O site only after P12-007 | Open |

### Record — no action (closed, or accepted behaviour) (23)

| ID | Item | Sev | State @`6d573a7` | Handling | Status |
|---|---|---|---|---|---|
| L77 | Replay kept a second lock file beside `WidgetAppGroupLock` | S3 | Closed `86925a1` | record | Closed `86925a1` |
| L98 | OnMyWay warm-route `pendingOpenUrl` stash was never cleared | S3 | Closed `33a24c3` | record | Closed `33a24c3` |
| L139 | Account-switch App-Group scrub failure was fail-open with no retry (final review 1a) | S2 | Closed `5f2f397` | record (residual: L286.5b) | Closed `5f2f397` |
| L140.a | `scrubWidgetAccountState` doc comment was stale for the switch caller | S3 | Closed `5f2f397` | record | Closed `5f2f397` |
| L142 | `useAnotherAccount` did not hold `authenticationOperationInFlight`, so `signOut` could interleave (1c) | S2 | Closed `5f2f397` | record | Closed `5f2f397` |
| L156 | `deepLinkOwnerWasActive` could skip discarding a parked route (final review 2) | S2 | Closed `2e70415` | record | Closed `2e70415` |
| L167.a | Mutually recursive `track` protocol defaults | S3 | Closed `58ae2a2` | record | Closed `58ae2a2` |
| L167.b | Variant ranking could strip its own discriminator | S3 | Closed `58ae2a2` | record | Closed `58ae2a2` |
| L167.c | Diagnostic names were logged `.public` without the secret screen | S2 | Closed `58ae2a2` | record | Closed `58ae2a2` |
| L180 | Parity matrix called the tax row "ported" although no editor exists | S3 | Closed `d18b29c` | record (the gap itself is G2, plan §1.1) | Closed `d18b29c` |
| L202 | Switch/recovery AI-key wipe ignored delete errors | S2 | Closed `5f2f397` | record (residual: L286.5b) | Closed `5f2f397` |
| L204.a | A failed boundary AI-key wipe was silent, with no counter and no retry (1b) | S2 | Closed `5f2f397` | record | Closed `5f2f397` |
| L204.b | `signIn` during a switch did not check `accountSwitchInFlight` (1c) | S2 | Closed `5f2f397` | record | Closed `5f2f397` |
| L215.d | A24: keyboard dismissal outside the auth forms | S3 | Closed `afacd91` | record | Closed `afacd91` |
| L224 | "Cancel plan"/"Delete plan" silently did nothing (final review I1) | S2 | Closed `8146cd6` | record | Closed `8146cd6` |
| L274.b | The Phase 12 plan's scope-source sentence (edited by 11.14 in `d18b29c`) read abruptly | S3 | Closed (plan revision `09236e6`) | record | Closed (plan revision `09236e6`) |
| L81 | Single-slot `widgetSeamCapture` could be cleared by an unrelated early return; unreachable today | S3 | Open | record (accepted) | Open |
| L157 | A parked warm URL with no owner tag can open the next owner's same-id record (their own data only) | S3 | Open (by design) | record (accepted, contract §6.2) | Open (by design) |
| L193.c | Redaction over-redacts long plain alphanumerics (accepted, the safe direction) | S3 | Open (accepted) | record | Open (accepted) |
| L223.c | A failed bulk-outreach sheet leaves ⌘N gated off until Done | S3 | Open | record (fail-closed) | Open |
| L237.c | An A→B→A value inside one un-coordinated pull can escape touched-key protection; it self-heals | S3 | Open | record (accepted) | Open |
| L237.e | Overlapping direct pulls can commit a regressed cursor; the next pull refetches | S3 | Open | record (idempotent) | Open |
| L267.b | A `.completeFileProtection` write can throw on a locked relaunch; the journal retries | S3 | Open | record (accepted, 11.13) | Open |

### Pointers — routed to the 12.03 evidence index (3)

| ID | Item | Sev | State @`6d573a7` | 12.03 row |
|---|---|---|---|---|
| L215.c | A22: stacked route-move chevrons grow a stop row to about 116pt (accepted as RN parity) | S3 | Closed (accepted) | device row A11-TT-1: first tap hits |
| L223.e | IPAD-MT-3: Stage Manager's first frame may shift column geometry | S3 | Open | device row IPAD-MT-3 |
| L249.e | iOS 17/18 destructive text and the "On my way" hit-test are unverified | S3 | Open | device rows A11B-FR1-1/2 |

### New in Phase 12 (34)

| ID | Item | Sev | Found (date, source) | Handling | Status |
|---|---|---|---|---|---|
| P12-001 | Permanent account deletion left the React Native source files (AsyncStorage, Documents photos, legacy SecureStore items), so the next launch re-imported the deleted account: its records, owner marker, legacy session and provider key. Account B's sign-in then met the account-mismatch gate, or B's launch adopted A's data when the RN data had no owner keys (§5.4 item 5, G6-Q1) | **S1** | Open @`1bb701c` (reproduced 2026-09-25, 12.00b.2-F host test `native/run-legacy-reimport-tests.sh`) | 12.00b.2-F | Fixed — 12.00b.2-F (host) (`fix(native): phase 12.00b.2 - deleted account's legacy data is never re-imported (P12-001)`); device row P12-B2F-1 |
| P12-002 | Phase 11 docs (runsheet OI-3 row; `native-phase-11-performance.md` §1.2 scenario B) stated the 429 push backoff as the poor-network test harness's 30 s/60 s values, not the app's real exponential backoff (5 s base, doubling, 300 s cap; `N/NativeSyncCoordinator.swift:140-141,388`) | S3 | 2026-09-25, Task 2 12.00 doc batch | doc batch | Closed — 12.00 doc batch (`1c6859a`) |
| P12-003 | On a migrated device, sign-out (the `.live` scrub) removed the native snapshot and kept the completed migration journal (rightly: the journal stops the next account re-importing the RN data), but nothing recorded why the snapshot was gone. The next launch read that as a lost migrated snapshot (`missingMigratedSnapshot`): a failed-migration notice, local writes blocked, "Try again" the same, and the next sign-in stopped at `preflight/local-recovery/missing-migrated-snapshot` (§2 Migration S1 example; TH-2): A's, and B's when the RN data had no owner keys (with owner keys B met the account-mismatch gate instead: P12-005). The scrub now records that it cleared the workspace, so the relaunch is an ordinary signed-out start and the next sign-in heads for that account's initial sync; a snapshot lost with no scrub still blocks | **S1** | 2026-09-25, Task 9b characterization | 12.00b.2-G | Fixed — 12.00b.2-G (host) (`fix(native): phase 12.00b.2 - sign-out on a migrated device relaunches cleanly (P12-003)`); device row P12-B2G-1 |
| P12-004 | A sign-out or deletion whose scrub failed and was finished by "Try cleanup again" (`retryAccountScrub`) left the previous account's pending schedule/booking work (booking and portal link mirrors, with their link tokens) on the device; the launch recovery and the first attempt cleared it. No leak: each item carries its owner's exact binding and every send, apply and recovery path acts only on the signed-in account's binding, so the next account could neither send nor apply it. The three paths now clear one shared list of stores | S3 | 2026-09-25, Task 9b characterization | 12.00b.2-G | Fixed — 12.00b.2-G (host) (`fix(native): phase 12.00b.2 - every account-scrub path clears the same stores (P12-004)`) |
| P12-005 | On an upgraded device whose RN data carried owner keys (RN writes `__dataOwner` at every initial sync, `utils/sync.ts:406`), sign-out kept the RN-era auxiliary artifact (account state and owner marker) for an exact-owner rollback, so every other account's sign-in was held at the account-mismatch gate, whose only action is "Use another account": no second account could use the device. RN's sign-out clears `__dataOwner` and every account key (`utils/storage/lifecycle.ts:106-159`). The sign-out scrub now drops the auxiliary artifact and its staged copy (a deletion already did): the next account gets a clean workspace and none of the previous account's state, the same account's sign-in takes the ordinary path, and a workspace no scrub cleared still holds another account at the gate | S2 | 2026-09-25, Task 9c review | 12.00b.2-G | Fixed — 12.00b.2-G (host) (`fix(native): phase 12.00b.2 - a signed-out upgraded device accepts another account (P12-005)`); device row P12-B2G-1 |
| P12-006 | A permanent deletion whose local scrub could not write its account-scrub marker (`beginAccountScrub` throws, as on a full or failing volume) ran none of its steps and left nothing on disk saying the deletion was pending: only the in-memory blocked screen. "Try cleanup again" and the scene-activation retry then took the not-pending branch and unblocked without scrubbing, and the next launch loaded the deleted account's records. The snapshot, journal, legacy backups, session, provider key and RN source files all stayed; account B's sign-in met the account-mismatch gate, B's next launch adopted the workspace when the RN data had no owner keys, and B's initial-sync backfill queued A's records for B's push (nothing was re-imported: the snapshot and completed journal were still there). The P12-001 pattern. The deletion is now also recorded in the Keychain (`account-deletion-scrub-pending.v1`, schema version only) and held in memory; Retry, scene activation and the launch write the marker from it first and run the whole `.all` scrub, eraser included, and until then it stays blocked with nothing loaded. Residuals (accepted): if the Keychain write fails too, only the in-memory copy remains (Retry and activation still finish it; a relaunch first does not), counted and logged by stage code. A record that cannot be read at launch does not block the launch (the snapshot it guards is unreadable in the same before-first-unlock window); scene activation re-reads it. The record (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`) survives an uninstall, so uninstalling the native app, installing the RN build, using another account there and then reinstalling the native app would run the `.all` scrub, including the install-wide RN source eraser, on that other account's RN data; reachable only before cutover, by testers, after a marker-write failure (Task 9c re-review Minor 2) | **S1** | 2026-09-25, Task 9c review (Minor 4); reproduced by host test `native/run-legacy-reimport-tests.sh` section 7 | 12.00b.2-G | Fixed — 12.00b.2-G (host) (`fix(native): phase 12.00b.2 - a deletion whose scrub marker cannot be written stays pending (P12-006)`; review fixes (R31) in `fix(native): phase 12.00b.2 - a resumed identity check never overwrites a sign-out (R31)` (`3153e93`) and `fix(native): phase 12.00b.2 - the password-recovery sign-out also ends an in-flight identity check (R31)` (`89ddfac`)); no device row: the marker-write failure is injected on the host (a read-only app directory) and cannot be produced on a device on demand |
| P12-007 | Crash and error messages keep file paths: the Phase 11 redactor (contract §10.1) has no path rule, so a crash message or an `NSError` description that names a file reaches Sentry with its path (on iOS the app container, with no user name) | S3 | 2026-09-26, Task 11 (12.02) dry run (`native/SupportDiagnosticsTests/main.swift` section 16; `docs/native-phase-12-monitoring.md` §11 finding 1) | A §10.1 contract path rule lands before any file-I/O backlog site (`photoStorage`, `invoicePdfFile`) is wired; today only `deleteAccount`, `purchase` and `restorePurchases` pass raw errors, and native file names are record ids or invoice numbers | Open (backlog) |
| P12-008 | A snapshot save that threw left its change in memory. The payment, bulk Mark paid and invoice editor commits (and eight other sites: onboarding personalization, starting point, demo reset, Settings, the automatic-send clear, and the older invoice and expense saves and expense delete) changed the live snapshot before `repository.save` and did not restore it on failure, so the widget mirror showed the unsaved change at once and the next unrelated save persisted it without queueing it for sync. Characterized on the host (`native/run-save-rollback-tests.sh`): after an unrelated save, a failed payment or bulk settlement showed paid and survived a relaunch, never queued; a pull then left it diverged from the server (row unchanged) or dropped a payment the owner had seen (row changed); a failed create retried left two invoices with the same number, one never synced. RN saves and queues together (`utils/storage/collections.ts:26-35`). Every change made to the live snapshot before its save now commits through `AppStore.commitSnapshot` or `commitSettings`, which keep the previous snapshot and screens when the save throws, and copy sites save first, then apply; nothing unsaved is queued, tracked or mirrored, and the `invoicePayment` capture still fires once. A failed Settings save now says so on the Settings screens, and a failed reset to demo data keeps a blocked source blocked | **S1** | 2026-09-26, Task 11 (12.02) review | 12.00b.2-H | Fixed — 12.00b.2-H (`fix(native): phase 12.00b.2 - a failed save leaves nothing unsaved in memory (P12-008)`, review fixes in `fix(native): phase 12.00b.2 - P12-008 review fixes (pin, settings and bulk failure, demo reset)`); host only: a device cannot force a snapshot save failure on demand |
| P12-009 (= `12.02-F4`) | Parity gap: a purchase that RevenueCat cancels by throwing (`purchaseCancelledError`) shows native's failed state; RN shows nothing. Not reported to Sentry (host-tested with `RevenueCat.ErrorCode` 1) | S3 | 2026-09-26, Task 11 (12.02) review (`docs/native-phase-12-monitoring.md` §11 finding 4) | Renumbered from `12.02-F4` to `P12-009` (task 14, R40, 2026-09-27); backlog | Open (backlog) |
| P12-010 | A sync trigger that arrives mid-pass is rerun inside the same pass (`NativeSyncCoordinator.sync`), and the pass's status then carries only the rerun's outcome. After a partial or failed first run the rerun is usually deferred by the backoff, so the pass ends `.backoffDeferred`: `pushDiscarded` (TH-5) still reports, but the first run's `pushQueue`/`pullRemote` report, its `/429` count toward `syncThrottle` and the `pendingAge` check are skipped for that pass. The next network pass reports the same state, so a persistent failure is signaled one pass late, never lost | S3 | 2026-09-26, Task 11 (12.02) review (`docs/native-phase-12-monitoring.md` §11 finding 8) | backlog (found during the 12.02 monitoring build-out; added by task 14, R40): a fix changes the contract §10.4 per-pass semantics, left for the owner to classify | Open (backlog) |
| P12-011 | A re-upgrade (native → the Expo rollback build → native) re-imported the Expo build's stale AsyncStorage over native state, against §6 rule 3, on a device whose native workspace an account boundary had cleared and that had no completed migration journal: a native-only install that was then signed out, or an interrupted first migration followed by a sign-out. The launch migration found no snapshot and imported the Expo build's records, published its legacy session to the native Keychain, wrote a new journal entry and backups, and showed the migrated notice; when the RN data had no owner keys, account B's next launch adopted that workspace and queued the stale records for B's push. With the snapshot surviving only as its backup, the importer ran again and stopped at a secure-store conflict. The migration now settles first (`LegacyMigrationCoordinator.settledOutcome`): a completed journal returns `already-completed`, and a workspace an account scrub cleared, or whose snapshot survives only as its backup, is adopted as `native-state-adopted`, both keeping the Task 9 re-protect; neither reads the legacy source. Edits made in the Expo build reach native only through the cloud (`docs/native-phase-12-rollback-playbook.md` §5.2) | **S1** | 2026-09-26, Task 12 (12.06) characterization (`native/run-legacy-reimport-tests.sh` section 8: 37 of 888 checks failed at `9e84478`) | 12.06 | Fixed — 12.06 (host) (`feat(native): phase 12.06 - rollback readiness drain and journal adoption rule`); device row P12-RB-7 |
| P12-012 | The existing Expo build pushes a stale pre-upgrade `__syncQueue` before it pulls: on a device that ran the Expo build before the native one, the rollback build's first sync finds `__initDone_<user>` (`utils/sync.ts:365-369`) and pushes the queue left at the upgrade before its pull (`utils/sync.ts:320-321`), each item stamped at push time (`utils/sync.ts:163`). The database stamps `updated_at` with its own clock, so under last-writer-wins those stale records can overwrite newer native rows after a rollback. A native sign-out does not prevent it: the Expo keys survive it (`docs/native-phase-12-rollback-playbook.md` §5.3) | **S1** | 2026-09-26, Task 12 (12.06) | Expo release branch (EXPO-RB), requirements E-1…E-4 (playbook §5.3); owner assigns the builder | Open. Gates P12-RB-1…3/P12-RB-7 and playbook §2.2 condition 4; blocks Stage A entry under §2 rule 2 until the owner records a ruling (R43) |
| P12-013 | Unfinished booking and portal link work (plan 8.08) was never recovered after a relaunch. A booking-link or portal-link change (Create, Rotate, Enable, Disable) that succeeded on the server but whose local save failed, or whose owner changed during the call, was staged as owner-bound pending work, as is a reschedule proof before its resolve; the only recovery function (`recoverScheduleBookingPendingWork`) had no caller. Characterized on the host (`native/run-schedule-booking-recovery-tests.sh`): the display copy and the cloud settings or customer row (what other devices and the Expo rollback build read) kept the dead token or the old flag; after a lost first Create the device stayed on "No link yet" (Create then answered `already_exists`, and the portal screen offers no Rotate without a local token); the screens' "It will finish automatically" never happened; and a proof outlived a declined, confirmed or deleted request. Nothing reached customers: the server always held the owner's last change, and native shares a link only on a fresh `tokenValid` read (`docs/native-phase-8-contract-decisions.md` §6). RN has the same save-failure path and no recovery (`screens/CustomerDetailScreen.tsx:272-293`, `screens/SettingsBookingScreen.tsx:36-46`). Recovery now runs for the verified owner at launch and on every activation, after the initial sync, and re-checks the account generation and the owner after every await. A mirror is read and merged only after a pull has committed in that launch or activation (a cold launch's initial sync; on a warm activation, the foreground refresh's own pull), because the merge queues the whole settings or customer record and the push runs before the pull; until then, or when that pull fails, it waits. Since the final review (M1, 2026-09-27) that pull must also have started under the current account generation and after the scene last entered the background, and a pull taken before or while a gate waits for the owner does not count; a failed recovery save records the code `recovery/local-commit` instead of a screen message (M5). It is applied only when a fresh `status` read says the token it writes back is current (the staged token after a Create or Rotate; the local link's token after an Enable or Disable), with the server's flag, and is dropped otherwise; recovery never mutates the server. A proof is kept only while its resolve can still succeed (the request still `reschedule_requested`, the job still on the proven schedule) | S2 | 2026-09-26, Task 12 (12.06) re-review | 12.00b.2-I | Fixed — 12.00b.2-I (`fix(native): phase 12.00b.2 - unfinished booking and portal work is recovered after a relaunch (P12-013)`, review fixes in `fix(native): phase 12.00b.2 - P12-013 review fixes (mirrors wait for a committed pull, flag-only token check, pass diagnostic)`; final-review fixes in `fix(native): phase 12 final review - pull marks, cold-launch stamp guard, switch reset, recovery save code (M1-M5)`); host only: staging needs a local save failure, which a device cannot force on demand |
| P12-014 | Pre-existing bulk-settle copy gaps (Task 11b re-review, R42). `commitBulkSettleInvoices` (`N/AppStore.swift:2161-2184`) counts a missing invoice, an already-paid invoice and one whose edit throws all as `skipped`, the same bucket as "already paid": `InvoicesView.runBulkSettle` (`native/TradeReadyNative/InvoicesView.swift:275-288`) then tells the owner "Nothing to settle — the selected invoices are already paid." or "N skipped (already paid)." even when an invoice was actually missing or failed to settle, not already paid. `runBulkSettle` also calls `exitSelectMode()` unconditionally, so the selection is cleared after a failed or partial bulk settle, not just a successful one, and the owner cannot see which invoices were skipped to retry them individually. No data is lost or double-counted (P12-008 already guarantees a thrown edit commits nothing); this is a copy/UX gap only | S3 | 2026-09-27, Task 11b re-review (P12-008 fixed by cd160b0 + 9e84478) | backlog | Open (backlog) |
| P12-015 | The owner could not accept a customer's reschedule request from the native UI. Today's "I've rescheduled it" and the Requests row's "Resolve" built a schedule draft with the request's original slot (`request.slot`) as the target, no schedule baselines and the request's status (`reschedule_requested`) as the job's baseline, so the schedule-only commit always refused it as a baseline conflict: nothing was sent, neither screen showed anything, and the conflict text went to `migrationMessage`, from where it could show later on another screen. The request stayed `reschedule_requested` on the server and every device, and the original slot's reservation stayed held (only a resolve releases it, `docs/native-phase-8-contract-decisions.md` §7). Declining was the only other action. Both rows now call `AppStore.acceptBookingReschedule`, in RN's order: the owner moves the job first, and the tap only confirms it (`screens/TodayScreen.tsx:607-616`). It writes nothing to the job, syncs and pulls, refuses, and says why, while a change to the job or the request is still queued, and resolves with a proof of the job's current `(date, start)`. A job still at the request's slot is resolved too, as RN resolves it, and the notice says the time did not change. Every outcome is shown on the screen the owner acted on, never through `migrationMessage`. A fix that kept `request.slot` as the target would have moved the rescheduled job back to the original slot (S1); an S1 guard test pins the job to the owner's moved time (`native/run-schedule-booking-recovery-tests.sh` section F) | S2 | 2026-09-26, Task 12b (12.00b.2-I) review | 12.00b.2-J | Fixed — 12.00b.2-J (`fix(native): phase 12.00b.2 - the owner can accept a customer's reschedule request (P12-015)`, review fixes in `fix(native): phase 12.00b.2 - reschedule accept review fixes (P12-015 M1-M9)` (`d1c001e`)) |
| P12-016 | Customer bookings never became jobs on a native-only account. Plan 8.08's atomic intake (`AppStore.runBookingIntakeAfterVerifiedPull`) had no production caller, so a booking or quote request that arrived by pull stayed a request: Today showed only "… is waiting to be scheduled", with no job, customer, calendar or route entry, and when the customer asked to reschedule, the accept answered `notLinkedToJob`, so Decline was the only action that worked. Nothing was lost on the server: the booking and its slot stayed held. RN converts every booking into the lead job `jbk_<id>` and a customer once the launch's initial sync ends and after every foreground sync (`App.tsx:396`, `context/AuthContext.tsx:118-120`, `utils/storage/bookingConversion.ts:124-145`). Characterized on the host (`native/run-schedule-booking-recovery-tests.sh` section K). Intake now runs when the subscription gate opens the signed-in gate straight after the initial sync, and in the foreground refresh after its sync: for the verified owner after the initial sync, and only after a pull that committed every table in that launch or activation (not one taken before or while a gate waits for the owner), which it converts from instead of pulling again. A failed or partial pull, a pull that spans an account change, read-only data and the time before the initial sync convert nothing. It converts as RN does: deterministic `jbk_` IDs never replace a job, a request whose `jbk_` job is already on the device (another device made it) is linked to that job, a repeat customer's blank email, phone or address is filled from the booking and never replaced, and customer creation stays time-based (limitation L3). A failed intake save no longer leaves text in `migrationMessage` | S2 | 2026-09-27, Task 12c (12.00b.2-J) review | 12.00b.2-K | Fixed — 12.00b.2-K (`fix(native): phase 12.00b.2 - bookings become jobs after launch and each foreground sync (P12-016)`, review fixes in `fix(native): phase 12.00b.2 - P12-016 review fixes (repeat customer fill, existing lead job, waiting gate, real initial sync)`) |
| P12-017 | The owner's Decline (Today's "Decline booking", `declineBookingRequest`), and the test-only legacy `resolveBookingReschedule`, queued a whole copy of the booking request after the server had written the new status and appended the owner's history entry (`backend-workers/lib/booking/respond.js:64-75`). The next push replaced the server row's history with the device's copy, dropping that entry and any server entry the device had not pulled. The status could not regress (`declined` is terminal) and the customer never sees history. RN updates the request in memory only and pushes nothing (`screens/TodayScreen.tsx:559-563`). Characterized on the host (`native/run-schedule-booking-recovery-tests.sh` section D). Both now save the server's status on the device without queueing the request, and the next pull brings the server's row with its history. Before the POST the decline pushes what is queued; while a change to the request is still queued, or refused and waiting in Settings › Cloud Sync, it sends nothing and says why, and Today and Requests show the decline's outcome (RN's failure alert). In the same class (Task 12d review M6), booking intake's request stamp and repeat-customer fill are now guarded upserts: a PATCH of the row's data filtered on the table's delta-pull watermark (`updated_at=lte.`), so a customer's cancel or reschedule request, or another device's customer edit, that reaches the server between the pull and the push is kept and the device takes the server's row. A request whose stamp was dropped that way keeps its lead job, and Today shows the request's current state (for example the customer's cancel) on that job (review fix round 1, I1). Residuals, all S3 (`docs/native-phase-8-contract-decisions.md` §8 note): a fill dropped that way is not redone; a table with no row pulled yet still pushes whole rows, as RN does (since the final review, M3, a cold launch's stamp is guarded with the initial sync's own watermark, so it is no longer dropped and redone); a server write whose transaction was open across the pull's read (milliseconds) can still match the guard; a direct pull that overlaps a sync pass can save its cursor over the lowered watermark (the 5-minute overlap covers recent changes); the Worker's own read-then-write of the request can still overwrite a stamp; and the offset-paged delta pull can skip a row reordered by a concurrent write in a delta of more than 500 rows | S2 | 2026-09-27, Task 12c (12.00b.2-J) review | 12.00b.2-L | Fixed — 12.00b.2-L (`fix(native): phase 12.00b.2 - decline no longer pushes a booking copy over the server's history (P12-017)`, review fixes in `fix(native): phase 12.00b.2 - P12-017 review fixes (cancel after a dropped stamp, error-path account check, save failure, Cloud Sync)` (`b3723c9`); final-review fix (M3) in `fix(native): phase 12 final review - pull marks, cold-launch stamp guard, switch reset, recovery save code (M1-M5)`) |
| P12-018 | `NativeBookingRequestsView` is presented by no screen (RN has no booking-requests screen either; Today carries the actions) and the legacy `prepareBookingReschedule`/`resolveBookingReschedule` are test-only — remove or move the tests onto `acceptBookingReschedule` | S3 | 2026-09-27, Task 12c (12.00b.2-J) review | Backlog (post-cutover) | Open (S3 backlog) |
| P12-019 | Host test suites reach the real App Group container. An `AppStore` built without a `widgetActionReplayTransport` falls back to the live one (`N/AppStore.swift:676`, `try? .live()`): the real App Group action queue and claim directory. That is true of the Phase 12 suites RejectedChanges, LegacyReimport and SupportDiagnostics, and of AIProviderKey, SaveRollback, StoreIntegration and older suites; their account scrubs run `removeAllAccountClaims()` on the host's real group container. State is shared across runs and suites (a likely cause of flaky runs, such as the SaveRollback stall on the live lock file recorded in Task 12b), and a scrub deletes the host's real claim directory. Fix: a host-test helper that injects a temporary-directory `NativeWidgetActionClaimTransport` into every test `AppStore` (as `native/ScheduleBookingRecoveryTests` already does), with a check that no suite builds one without it. Test infrastructure only; the app is unaffected | S3 | 2026-09-27, Phase 12 final review (M9; widened from Task 12b's note on SaveRollback and StoreIntegration) | backlog (test infrastructure) | Open (S3 backlog) |
| P12-020 | A busy warm-link dedupe can present the On My Way review twice. When the App Group lock is busy, `takeMatching` returns nothing and the stash survives, while the warm route still opens the review. The next activation within 300 s (returning to the app after sending the message is one) runs `consumePendingOpenURLStash`, and `take` presents the same editable review again. Nothing is sent automatically and the review stays owner-gated, so the worst case is a second message only if the owner taps Send again. Reaching it needs the widget extension to hold the lock for more than 100 ms between the app's own stash write and the dedupe; the older `lockFailed` path had the same effect | S3 | 2026-09-25, Task 6 (12.00b.2-B) review M4; unrecorded until the Phase 12 final review | backlog | Open (S3 backlog) |
| P12-021 | A fresh native-only install that has never migrated and is signed out attempts the legacy migration, and reads the legacy source and the Keychain, at every launch. So a background launch while the device is locked can stop at `.legacyMigration`. Pre-existing; found while fixing P12-005 and P12-006 | S3 | 2026-09-25, Task 9c (12.00b.2-G) report concern 5; unrecorded until the Phase 12 final review | backlog | Open (S3 backlog) |
| P12-022 | The Phase 11 plan's ledger ends two entries with the same "Next ready" line: 11.03 at `docs/native-phase-11-implementation-plan.md:1240` and `:1389` (and 11.11 at `:2797` and `:2884`). Each follows a different finished task, but the plan reads as if a step repeated. Task 2's review named the 11.11 pair; the final review found the 11.03 pair; both are listed here | S3 | 2026-09-25, Task 2 (12.00 docs) review; Phase 12 final review triage | backlog (doc) | Open (S3 backlog) |
| P12-023 | Fix-list F3. The four Phase 8 RPCs (`claim_booking_slot`, `transition_booking`, `admin_booking_link`, `admin_portal_token`) are `security definer`, take the owner id as a parameter and never check `auth.uid()`, but each migration revokes EXECUTE only from `public`. Supabase normally grants EXECUTE on new `public` functions directly to `anon` and `authenticated` (default privileges), which a revoke from `public` does not remove, so a client holding the publishable key may be able to call them for any owner: step another account's booking, or mint and rotate its booking and portal links. Also open: owner `for all` RLS policies on the server-authority tables `booking_link_state`, `booking_operations` and `portal_operations` (devices must never write them); no table grant to `service_role` for the Worker's REST reads (they fail on projects without automatic grants); `booking_take_lock` executable by `public`. Not live: the migrations are unapplied and cannot apply yet (P12-024) | **S1** | 2026-09-28, fix-list reconciliation at `3d26fad` (`docs/native-migration-fix-tasklist.md` F3, review 2026-09-20) | Backend (migrations), before any apply (fix plan F3): revoke EXECUTE and table access from `anon` and `authenticated`, grant `service_role` only what the Worker needs, revoke `booking_take_lock` from `public`; confirm with `has_function_privilege` and `has_table_privilege` on isolated staging (D4), never production. S1 until that check: the owner may record a severity change in §9 if the target project grants clients nothing | Fixed — fix landed (uncommitted working tree; no commit yet), host-proved; the staging proof is waived by the owner (§9 row 20), with the post-apply verify-SQL condition recorded there. Migrations now revoke EXECUTE from `public`, `anon` and `authenticated` on all four RPCs and the helpers, drop the owner `FOR ALL` policies on the three server-authority tables, revoke their client table privileges and grant `service_role` what the Worker reads, and refuse a client JWT role inside each RPC (defense in depth). `run.sh` asserts all of it against a Supabase-shaped scratch database, including refused anon/authenticated sessions; `supabase/verify/*.sql` now assert roles, not ACL text |
| P12-024 | `supabase/migrations/20260920_booking_lifecycle_rpcs.sql:119` declares `v adopted_exists boolean := false;` (a space for the underscore; the body uses `v_adopted_exists`), so creating `claim_booking_slot` fails and the migration cannot apply; a migration runner stops there, so the two later Phase 8 migrations do not run either. The Worker reads the missing RPCs as not deployed and keeps the legacy booking path, but `/api/booking/admin` has no legacy path and returns 500 to native's booking-link screen. Merged in `d5eff92` without being compiled against Postgres (host tests mock the RPCs) | S2 | 2026-09-28, fix-list reconciliation re-check of F2 | Backend (migrations): fix the declaration and compile all three Phase 8 migrations against a scratch Postgres before any apply | Fixed (uncommitted working tree; no commit yet) — `v_adopted_exists` declaration fixed; all three Phase 8 migrations apply and re-apply on a scratch PostgreSQL 16 (`sh supabase/verify/local/run.sh`). The compile also exposed two more defects that no host test could see, both fixed: `digest` lives in the `extensions` schema on Supabase (calls are now `extensions.digest`), and `select count(*) … for update` in `admin_portal_token` is illegal (lock, then count); plus `transition_booking` wrote `history: null` for a request with no history |
| P12-025 | Fix-list F2. `claim_booking_slot` takes the owner advisory lock (`booking_take_lock`) and then reads jobs and settings, but native and RN sync write those tables with plain PostgREST upserts that never take the lock, so a job or availability change can commit around a claim and a customer booking can overbook: the G1 no-overbooking guarantee is not established (no worse than the pre-Phase 8 path). `transition_booking` takes the request row lock before the owner lock, the reverse of the documented order. The contract decisions (`docs/native-phase-8-contract-decisions.md`) and the migration comment still say the writer serializes behind the claim | S2 | 2026-09-28, fix-list reconciliation at `3d26fad` (F2) | Backend (fix plan F2): one lock-aware or versioned write protocol for jobs and settings, owner lock first; prove a claim against competing job and settings writes on real Postgres (isolated staging, D4; `supabase/verify/booking_lifecycle_concurrency.sh` still exits DEFERRED); correct the contract doc | Fixed — fix landed (uncommitted working tree; no commit yet), proved on real concurrent sessions on a local PostgreSQL; the staging proof is waived by the owner (§9 row 21), with the post-apply verify-SQL condition recorded there. `jobs` and `settings` now carry write-fence triggers that take the claim's owner lock (statement trigger first, so overlapping writers cannot deadlock; row trigger for `service_role`), and `transition_booking` takes the owner lock before its row lock. `run.sh` shows a claim waiting for an in-flight job write and then answering `slot_taken`, a settings write waiting for an in-flight claim, no deadlock under overlapping writers, claims and transitions, and (negative control) the same test overbooking with the triggers dropped. Contract §2.5 corrected |
| P12-026 | Booking attention rows whose linked job was deleted are a dead end. `N/Domain/NativeBookingAttention.swift` turns a reschedule request, an unhandled portal change, and a booked, confirmed, cancelled or declined booking whose job is gone into `.missingJob`, and Today offers only View job (the Jobs tab) and OK (`N/TodayView.swift:330-335`). The customer's reschedule request can never be answered or declined, the portal change never marked Done, and the row never clears. RN shows the first two as ordinary rows with their actions and drops the rest (`utils/bookingAttention.ts:47-78`). Native `deleteJob` does not touch linked bookings, so the owner can cause this on one device. Covers fix-list F6's deleted-linked-job case | S2 | 2026-09-28, fix-list reconciliation at `3d26fad` (F4 and F6 re-check) | Keep RN's reschedule and portal actions (I've rescheduled it, Decline booking, Done) on these rows and give the other kinds a dismiss; host tests on the attention logic and the dialog wiring | Fixed (uncommitted working tree; no commit yet) — every missing-job row now has an answer: Decline booking (reschedule request), Done (portal change) or Dismiss (`handledAt` stamp; the row stops surfacing); host tests `BookingAttentionTests` §11 and `ScheduleBookingRecoveryTests` O1/O2 |
| P12-027 | Fix-list F8. The booking-link and portal-link admin actions mint a fresh operation ID on every tap (`N/NativeBookingSettingsView.swift:263-264`, `N/NativeCustomerPortalView.swift:256-261`) and an unknown outcome records nothing, so no retry ever reuses an ID and the replay tables go unused. A first Create whose response is lost leaves the device with no token; the screens then offer only Create (Rotate needs a local token), and the second Create answers `already_exists`, so the owner cannot get a shareable link from any native device. A lost Rotate makes the next tap issue a second new link. The booking-link screen's comment claims a replay that does not exist. P12-013 fixed the server-succeeded, local-save-failed path, not this one | S2 | 2026-09-28, fix-list reconciliation at `3d26fad` (F8) | Fix plan F8: persist an owner, action and target-bound pending operation ID before the request, reuse it after an unknown outcome or a relaunch, and offer Rotate when there is no local token; host-provable with the `ScheduleBookingRecoveryTests` lost-response fakes | Fixed (uncommitted working tree; no commit yet) — the operation ID is staged in the pending-work store before the request (`adminOperation` item), reused after an unknown outcome or a relaunch, cleared only on a definite outcome, expires at the server's replay window (29 of 30 days), and a different action waits. Both screens offer Retry and, for a server link this device has no copy of, Replace link. Host tests `ScheduleBookingRecoveryTests` N1-N9 (lost Create and Rotate replay once, portal too); device rows still owed |
| P12-028 | Fix-list F10. `commitScheduleBookingLocal` passes an empty `stageRecovery` closure (`N/AppStore.swift:9591`): when the snapshot save succeeds and the queue append fails it still returns success and only records a diagnostic. Its one production caller is booking intake, live since P12-016, so a converted job and customer can stay local-only: the next intake pass sees the request already stamped and queues nothing, and a pull never pushes local records. The helper's doc still says recovery was staged, and `StoreIntegrationTests` passes a non-empty closure that production never does | S2 | 2026-09-28, fix-list reconciliation at `3d26fad` (F10) | Fix plan F10: durably stage the owner-bound batch before reporting success and replay it at launch and sync; test an interruption between the snapshot commit and the queue append | Fixed (uncommitted working tree; no commit yet) — intake stages the exact batch before saving (`stagedBatch` item), a failed stage commits nothing, a failed queue write leaves the batch for the launch or activation pass, replay skips superseded, missing and already-queued drafts, and rollback readiness counts staged drafts as waiting changes. Host tests `ScheduleBookingRecoveryTests` M1-M6 |
| P12-029 | Simultaneous-offline recurring invoice generation: two devices offline for the same occurrence each mint an invoice (`inv<ms>` IDs, exactly as RN does), so the customer can be billed twice (pinned in `native/RecurringInvoiceTests/main.swift:91-113`). The 2026-09-20 fix list asked for a decision (resolve, or accept as a permanent limitation); none is recorded, the Phase 7 spec still calls the concurrency qualification BLOCKING, and evidence row P7-25's pass criterion (no double bill) contradicts the pinned behavior | S3 | 2026-09-28, fix-list reconciliation (Phase 7 known gap) | Owner decision: fix it (deterministic occurrence IDs), or accept it as a permanent limitation (a severity change in §9, then a Record row); either way reconcile P7-25 | Closed — accepted permanent limitation (owner severity change, §9 row 18) |
| P12-030 | Fix-list F1 residual. Decline and reschedule accept no longer republish a stale booking-request copy (P12-015, P12-017) and the intake stamp is a guarded PATCH, but `stampBookingRequestHandled` (`N/AppStore.swift:10010`; Today's portal-change Done) still queues the whole row through `enqueueUpsert` with no `ifUnchangedSince` guard, despite its comment that it merges only the timestamp. The server never edits `portal_change_requested` rows, so only a concurrent write from another of the owner's devices can be lost; RN saves the whole row too | S3 | 2026-09-28, fix-list reconciliation at `3d26fad` (F1) | backlog: send the stamp through the existing guard, add a section D-style test in `ScheduleBookingRecoveryTests`, correct the comment | Open (S3 backlog) |
| P12-031 | Fix-list F9. `reconcileBookingLinkForSharing` and `reconcilePortalLinkForSharing` (`N/AppStore.swift:10620`, `:10838`) build a share URL from the token read before their status await and never recheck the owner; `NativeCustomerPortalView.refresh` calls the status service directly; `NativeBookingSettingsView.scheduleStillCurrent()` is hard-coded true beside a comment saying the store rechecks. No leak is reachable: both views live under RootView's signed-in tabs, which every account change tears down first, and neither function writes the store. Defense in depth plus a false comment | S3 | 2026-09-28, fix-list reconciliation at `3d26fad` (F9) | backlog (fix plan F9): capture owner, customer and token before the await and recheck all three after it; move the portal view onto the store entry point; host test with a suspended status call. The owner may classify it S2 (an in-app owner check that fails open) | Open (S3 backlog) |
| P12-032 | Fix-list F7 residuals. The route view is reachable from Today since `f8037ce`, but `previewCoordinate` (`N/NativeRouteView.swift:315`) still returns nil, so a Complete preview draws an empty map; there is no full-route action and no Google fallback when Apple Maps cannot open, both of which RN has (`screens/RouteScreen.tsx`); and each refresh builds a new `NativeRoutePreviewRunner`, so whichever lookup finishes last wins over a newer reorder | S3 | 2026-09-28, fix-list reconciliation at `3d26fad` (F7) | backlog (fix plan F7); the map drawing and the open-failure fallback need device evidence | Open (S3 backlog) |
| P12-033 | Booking attention residuals from fix-list F5, F6 and F11. The portal-change Done ignores failed and missing outcomes and its save failure surfaces as `migrationMessage` (`N/AppStore.swift:10029`); Today shows no progress while an accept's sync, pull and request run; unconverted rows have no action (temporary: P12-016 converts them at the next launch or foreground sync); and the unused `NativeBookingRequestsView` (P12-018) still holds the app's only dead control, a disabled Reconcile button marked TODO | S3 | 2026-09-28, fix-list reconciliation at `3d26fad` | backlog; the dead control goes with P12-018 | Open (S3 backlog) |
| P12-034 | Fix-list F12 process gates are still missing. `native/run-all-domain-tests.sh` never compiles the app; no test catches a screen that nothing presents (P12-018 was found by review); the `supabase/verify` SQL files are manual queries that check function EXECUTE and RLS policies but no table grants and not `booking_take_lock`, and their three privilege queries select `p.proname` from `information_schema.routine_privileges` with no `p` alias, so they fail before showing any grant; the concurrency proof `supabase/verify/booking_lifecycle_concurrency.sh` exits DEFERRED (evidence row P8-15) | S3 | 2026-09-28, fix-list reconciliation at `3d26fad` (F12) | backlog (test infrastructure); the grant assertions land with P12-023's fix | Open (S3 backlog) |
