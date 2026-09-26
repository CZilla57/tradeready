# Native Phase 12 — cutover charter (12.00)

**Status: DRAFT — not owner-approved.** Written 2026-09-25 on branch native/phase-12.
Every threshold in this document is **provisional**. No stage gate may cite this charter
until the owner approves it and records the approval in the
[decision log](#9-decision-log). Until then it is a proposal.

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
| G6-Q1 (account deletion and the RN source files): **resolved 2026-09-25** by 12.00b.2-F (`P12-001`). Rule: after a permanent account deletion nothing from that account is re-imported; the deletion erases the RN source files, and the G6 retention policy applies to live accounts only | §5.4 item 5 | approve with the G6 policy |

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
  `N/AppStore.swift:730`). Sentry and PostHog need owner-held setup (OI-2, build-time keys).
  Small cohorts make rates noisy, so several rows also carry a per-event rule.

| ID | Metric | Definition | Source | Provisional target | Refined / re-ratified |
|---|---|---|---|---|---|
| TH-1 | Migration data loss | Per Expo → native upgrade: a record, photo or setting present in the Expo build and missing from the native snapshot without a logged deferral. Compare the support report's per-collection `counts` with the Expo data set's known counts; photos adopted + deferred must equal photos found | Support report per upgraded device (12.04 SA2 rows): `launchMigration` counts and `persistence.recordCounts`. A lost record has no remote signal by design (the device cannot know the Expo counts); a failed or lost migration reports remotely as TH-2's `legacyMigration` (12.02, 2026-09-26; `docs/native-phase-12-monitoring.md` §2) | **0**. Any occurrence is S1 | fixed at 0; owner confirms at Stage B entry |
| TH-2 | Migration failure without recovery | Journal status `failed` for the RN import, or the "marked complete, but its native snapshot is unavailable" block (`N/AppStore.swift:7429`), still present after relaunch and Retry (`retryLegacyMigration`) | Sentry `reportError` context `legacyMigration` (`legacy-migration/failed/<domain>/<code>` and `legacy-migration/missing-migrated-snapshot`, at launch and on Retry; never for the P12-003 signed-out steady state) and `initialSync` (`preflight/local-recovery/missing-migrated-snapshot`), added by 12.02 (2026-09-26, `docs/native-phase-12-monitoring.md` §3); support report `launchMigration`; `LegacyMigration` signpost outcome (PERF-5, Instruments only) | **0** (S1). A failure that completes on retry is S2 until explained; more than one in a stage blocks that stage's exit until explained | zero fixed; retry rule refined by Stage A |
| TH-3 | Unrecovered sync failure | A signed-in, online device with changes pending for over 24 h, or with a non-transport sync code and no successful pass for 24 h | Sentry `reportError` events with context `pushQueue` / `pullRemote` and a bounded code (`N/AppStore.swift:11072`); Sentry `pendingAge` (`pending-age/over-24h`, once per episode; 12.02, 2026-09-26); the device's Cloud Sync screen and support report (`sync.oldestPendingAge`, `sync.lastSuccessfulSyncAge`) | **0 open**; each is S2 until classified. Two or more users with the same code unrecovered for 24 h is a stop trigger | owner at Stage B entry |
| TH-4 | Sync error rate (PERF-7) | Share of daily active users with at least one sync error event whose code is not `transport/…`, `non-http-response/…`, an auth status (401, first 403) or a 429 (TH-6) | Sentry, as TH-3; denominator: daily active users from Phase 11 analytics (PostHog, identified by Supabase user id), or the cohort size where PostHog has no data | **≤ 5% of daily active users** (7-day average); every new code is triaged whatever the rate | refined by Stage A (PERF-7 baseline); owner at Stage B entry |
| TH-5 | Discarded local changes | A queued change the push drops as unsendable, code `record-contract/<table>` (`N/NativeSupabasePush.swift:132`) | Sentry `reportError` context `pushDiscarded` (`record-contract/<table>`, with collection and count), sent even when the pass ends `.completed` (12.02, 2026-09-26, `docs/native-phase-12-monitoring.md` §3); support report `sync.discardedChangeCount`; the code on Cloud Sync | **0**; each is S1 until shown harmless | fixed at 0 |
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
| VER-1 | Native `MARKETING_VERSION = 1.0` is below the Expo `app.json` version `1.2.1` | Stage A upload; 12.06 version numbering | Owner confirms the live store version; 12.01 sets the scheme under a recorded ruling |
| OI-1 | The privacy labels omit first-party backend data (email, business records, job photos) | the decision: Stage A entry (12.01); the labels entered: Stage C entry | 12.01 decides; the owner enters the labels |
| OI-2 | Sentry project `tradeready-ios` in org `tradeready-3r` does not exist | Stage A entry (TH-8's source; rows CR-1 to CR-9) | Owner creates it; an agent never does |
| D4 | No trusted isolated staging. `https://staging.invalid` stays and production is never substituted | every STG row; SA3; Stage A exit | Owner provisions staging |
| AGG-1 | `native/run-all-domain-tests.sh` ends with a `backend-workers` `npm test` that has no `test` script in committed code | the aggregate's exit code; SA3's full regression, so Stage A exit; 12.08 | Owner or the backend agent. Phase 12 does not edit `backend-workers/` |

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
| Analytics | Both events stay on the Q4 exclusion list (`native/Phase11QualificationTests/main.swift:836`) |
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
   never overwrites (`N/Domain/SnapshotRepository.swift:233`); a published directory backup
   is returned unchanged (`:270`); files are written with complete file protection
   (`:57`, `:58`); copied directories are raised to `.complete` (`protectCopiedLegacyFiles`,
   `:348`, called at `:276`); the tree is excluded from device backup (`:340`). Known gaps:
   a nil enumerator returns silently and leaves a copy unprotected (L267.a, `:349`; fixed in
   12.00b.2), and legacy photo backup copies keep default protection (L267.c,
   `N/LegacyDataImporter.swift:1169`; backlog S3).
3. **Account boundaries.** Sign-out keeps `LegacyBackups/` and the migration journal
   (`removeLiveAccountData`, `N/Domain/SnapshotRepository.swift:116`). Permanent account
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
   `N/AppStore.swift:588`) and no completed journal
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

Facts at `1bb701c`: a 429 is transient (`N/NativeSupabasePush.swift:181`), so each queued
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
erases the RN source files (G6-Q1, resolved: §5.4 item 5); rule (3) is about live accounts.

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

The next row is the owner's approval (or amendment) of this draft. A go/no-go row names
the checklist (§4.x) and links the evidence-index rows; "Rollback trigger considered"
names each §4.8 trigger checked and its state.

## 10. Defect list

Source: plan §7 (the Phase 11 parked-minor triage, verified against `6d573a7`). An ID is
the Phase 11 controller-ledger line (`L130`; `L205.c` is the third item on line 205); `T1`
was found by the triage. The evidence column stays in plan §7. **State @`6d573a7`** is
frozen; **Status** is the live column later tasks update (§8).

Counts: 90 defect rows (S1 2, S2 17, S3 71; 16 closed) plus 3 pointers to 12.03.
Handling: 12.00b.1 1, 12.00b.2 10, rider 6, doc batch 11, 12.01 check 2, 12.02 1,
backlog 36, record 23 (16 closed, 7 accepted). The 12.02 review added the backlog rows
L193.b-rest and 12.02-F4 (2026-09-26). Open S1/S2 needing code (Stage A blockers):
L238, L74, L96, L130, L131, L237.d, L267.a, L286.1, L286.4, L286.5a, L286.5b.

What each handling means: **12.00b.1 / 12.00b.2** — fixed in that build item; blocks Stage
A. **rider** — S3 fixed inside 12.00b.2 because that change edits the same code; does not
block Stage A. **doc batch** — fixed in 12.00's separate docs-only commit. **12.01 check /
12.02** — done inside that task. **backlog** — S3 post-cutover work; does not block Stage
A. **record** — no action: closed (kept for audit) or accepted behavior.

### 12.00b.1 — I2 rejected-change handling (blocks Stage A entry) (1)

| ID | Item | Sev | State @`6d573a7` | Handling | Status |
|---|---|---|---|---|---|
| L238 | I2: a non-auth 4xx is retried forever, and every pull is skipped while it is queued | S2 | Open | **12.00b.1** (unwaivable). **Residuals, rated S3 (2026-09-25):** past the 100-entry cap the oldest refused change is dropped and counted, and a later pull can then overwrite its record; the password-recovery exits scrub the store but keep the records, with the same effect; so does "Use another account", which scrubs the store and keeps the workspace; and a newer change to a refused record that the push drops as unsendable (`record-contract`) counts as cleared, so its entry leaves the list. The server would never accept those edits anyway | Fixed — 12.00b.1 (host) |

### 12.00b.2 — S1/S2 code fixes (block Stage A entry) (10)

| ID | Item | Sev | State @`6d573a7` | Handling | Status |
|---|---|---|---|---|---|
| L74 | `NativeWidgetMirror.write` takes a blocking `flock` on the MainActor with no timeout | S2 | Open | **12.00b.2**: bounded try-lock in `WidgetAppGroupLock` (one fix with L96) | Fixed — 12.00b.2-B (`fix(native): phase 12.00b.2 - bounded App Group lock on the main actor (L74, L96)`) |
| L96 | `OnMyWayIntent.perform()` takes the same blocking `flock` on the MainActor | S2 | Open | **12.00b.2** (with L74) | Fixed — 12.00b.2-B (`fix(native): phase 12.00b.2 - bounded App Group lock on the main actor (L74, L96)`) |
| L130 | One malformed, duplicate or over-512 widget/Siri queue entry quarantines the whole batch, so valid actions (clock-ins, expenses, trips) are never applied | **S1** | Open | **12.00b.2**: quarantine only the bad entries when the queue parses. A whole-batch quarantine stays only for unparseable bytes, and the raw bytes are still retained. Amend contract §4.6 | Fixed — 12.00b.2-C (`fix(native): phase 12.00b.2 - replay quarantines only bad widget/Siri entries (L130, L131)`; `fix(native): phase 12.00b.2 - replay review fixes (claim-record retention, unreadable claims, message precedence)`) |
| L131 | `invalidClaim`/`conflictingClaims` retry forever and the claim is never quarantined, which wedges that owner's replay | S2 | Open | **12.00b.2**: quarantine the bad claim with a bounded diagnostic. Today's workaround is sign-out/in, which clears claims | Fixed — 12.00b.2-C (`fix(native): phase 12.00b.2 - replay quarantines only bad widget/Siri entries (L130, L131)`; `fix(native): phase 12.00b.2 - replay review fixes (claim-record retention, unreadable claims, message precedence)`); a regular claim file that stays unreadable still fails closed, counted (`unreadableClaimCount`) |
| L237.d | Returning-user launch runs `refreshRecurringJobs()` but not `refreshRecurringInvoices()`, while RN runs both | S2 | Open | **12.00b.2**: add the invoice refresh, with a test cross-checked against RN | Fixed — 12.00b.2-E (`fix(native): phase 12.00b.2 - returning-user launch also generates recurring invoices (L237.d)`) |
| L267.a | `protectCopiedLegacyFiles` returns silently on a nil enumerator, so the legacy AsyncStorage backup that can hold the G6 residual is never protected | S2 | Open | **12.00b.2**: treat a nil enumerator as a per-file failure (diagnostic plus journal retry); consistent with the G6 policy | Fixed — 12.00b.2-E (`fix(native): phase 12.00b.2 - nil enumerator logs a diagnostic instead of skipping legacy file protection (L267.a)`; `fix(native): phase 12.00b.2 - legacy backup copies are re-protected until protection succeeds (L267.a)`; `fix(native): phase 12.00b.2 - launch re-protects a completed migration's legacy backup copy (L267.a)`) |
| L286.1 | Widget/Siri replay markers (`__nativeWidgetStartActionID`/`StopActionID`) sit in session `unknownFields`, are pushed to Supabase inside the job, and RN keeps them forever | S2 | Open | **12.00b.2**: first confirm replay idempotency survives a pull that replaces the job, then strip `__native*` keys from pushed payloads. The test asserts no queued payload carries one | Fixed — 12.00b.2-D (`fix(native): phase 12.00b.2 - replay markers stay local (L286.1)`) |
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
| L65 | Contract decision table lists C22 before C21 | S3 | Open | doc batch | Closed — 12.00 doc batch (this commit) |
| L141.a | Phase 11 plan §7 11.05 entry contradicts itself on parked-route handling | S3 | Open | doc batch | Closed — 12.00 doc batch (this commit) |
| L141.b | Contract C8 row still says "blocked until 11.05 decides", though §4.6 resolved it | S3 | Open | doc batch | Closed — 12.00 doc batch (this commit) |
| L205.c | Parity "AI Assistant" row omits the "Unavailable" key state | S3 | Open | doc batch (with T1) | Closed — 12.00 doc batch (this commit) |
| L205.d | Phase 11 plan §7 repeats "Next ready: 11.10a" | S3 | Open | doc batch | Closed — 12.00 doc batch (this commit) |
| L223.b | IPAD-KB-1 omits "cancel a swipe-back, then ⌘N" | S3 | Open | doc batch; 12.03 copies the fixed row | Closed — 12.00 doc batch (this commit) |
| L237.a | Phase 11 plan §6 and the parity "Supabase sync" row omit round 3 and scenarios G–H | S3 | Open | doc batch | Closed — 12.00 doc batch (this commit) |
| L249.d | Phase 11 plan still says the Today status row is 44pt | S3 | Open | doc batch | Closed — 12.00 doc batch (this commit) |
| L274.a | Phase 11 runsheet does not explain its switch to row tables | S3 | Open | doc batch | Closed — 12.00 doc batch (this commit) |
| L286.8 | Contract §17.2, the runsheet I2 row and the roadmap's I2 text omit the poison-item test and the `utils/sync.ts` line range | S3 | Open | doc batch (plan §3 12.00b.1 already specifies both) | Closed — 12.00 doc batch (this commit) |
| T1 | Parity "AI Assistant" row still lists the OI-4 known issues that `5f2f397` fixed | S3 | Open | doc batch (with L205.c) | Closed — 12.00 doc batch (this commit) |

### 12.01 check (2)

| ID | Item | Sev | State @`6d573a7` | Handling | Status |
|---|---|---|---|---|---|
| L169.a | Release build's `appintentsnltrainingprocessor` "Could not archive SSU artifacts" line was never diffed against Phase 10 | S3 | Open (unverified) | 12.01 check: diff a Release log against the native/phase-10 tip | Open (unverified) |
| L169.b | Store-integration runner's `ConformanceIsolation` warning was never diffed against Phase 10 | S3 | Open (unverified) | 12.01 check (same diff) | Open (unverified) |

### 12.02 (1)

| ID | Item | Sev | State @`6d573a7` | Handling | Status |
|---|---|---|---|---|---|
| L193.b | Only 3 of about 74 RN `reportError` sites are wired natively, with no ErrorBoundary equivalent (contract §10.4) | S3 | Open | 12.02 wires the sites that the charter's crash/error metrics read; the rest go to backlog | Done — 12.02 (`feat(native): phase 12.02 - privacy-safe support diagnostics`), 2026-09-26: RN `initialSync`, `purchase` and `restorePurchases` wired, plus native-only `legacyMigration`, `pushDiscarded`, `syncThrottle`, `pendingAge`, `invoicePayment` and `accountScrub`; the other 68 RN sites and the ErrorBoundary analog are backlog (`docs/native-phase-12-monitoring.md` §8) |

### Backlog — post-cutover S3 work (does not block Stage A) (36)

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
| L132 | Race tests assert "not finished after 0.3s", not "blocked on the flock" | S3 | Open | backlog | Fixed — 12.00b.2-B rider (`fix(native): phase 12.00b.2 - bounded App Group lock on the main actor (L74, L96)`; the anchored writer-first scrub race); other `timedOut` race sites remain (backlog: `AppGroupPendingOpenURLTests:177`, `AppIntentQueueTests:867`, `WidgetOwnerGatingTests:636`, `:1512`, `:1526`, `WidgetSnapshotTests:615`, `:641`, lines as of `c620929`) |
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
| 12.02-F4 | Parity gap: a purchase that RevenueCat cancels by throwing (`purchaseCancelledError`) shows native's failed state; RN shows nothing. Not reported to Sentry (host-tested) | S3 | — (added by the 12.02 review, 2026-09-26) | backlog; `docs/native-phase-12-monitoring.md` §11 finding 4 | Open |

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

### New in Phase 12 (8)

| ID | Item | Sev | Found (date, source) | Handling | Status |
|---|---|---|---|---|---|
| P12-001 | Permanent account deletion left the React Native source files (AsyncStorage, Documents photos, legacy SecureStore items), so the next launch re-imported the deleted account: its records, owner marker, legacy session and provider key. Account B's sign-in then met the account-mismatch gate, or B's launch adopted A's data when the RN data had no owner keys (§5.4 item 5, G6-Q1) | **S1** | Open @`1bb701c` (reproduced 2026-09-25, 12.00b.2-F host test `native/run-legacy-reimport-tests.sh`) | 12.00b.2-F | Fixed — 12.00b.2-F (host) (`fix(native): phase 12.00b.2 - deleted account's legacy data is never re-imported (P12-001)`); device row P12-B2F-1 |
| P12-002 | Phase 11 docs (runsheet OI-3 row; `native-phase-11-performance.md` §1.2 scenario B) stated the 429 push backoff as the poor-network test harness's 30 s/60 s values, not the app's real exponential backoff (5 s base, doubling, 300 s cap; `N/NativeSyncCoordinator.swift:140-141,388`) | S3 | 2026-09-25, Task 2 12.00 doc batch | doc batch | Closed — 12.00 doc batch (this commit) |
| P12-003 | On a migrated device, sign-out (the `.live` scrub) removed the native snapshot and kept the completed migration journal (rightly: the journal stops the next account re-importing the RN data), but nothing recorded why the snapshot was gone. The next launch read that as a lost migrated snapshot (`missingMigratedSnapshot`): a failed-migration notice, local writes blocked, "Try again" the same, and the next sign-in stopped at `preflight/local-recovery/missing-migrated-snapshot` (§2 Migration S1 example; TH-2): A's, and B's when the RN data had no owner keys (with owner keys B met the account-mismatch gate instead: P12-005). The scrub now records that it cleared the workspace, so the relaunch is an ordinary signed-out start and the next sign-in heads for that account's initial sync; a snapshot lost with no scrub still blocks | **S1** | 2026-09-25, Task 9b characterization | 12.00b.2-G | Fixed — 12.00b.2-G (host) (`fix(native): phase 12.00b.2 - sign-out on a migrated device relaunches cleanly (P12-003)`); device row P12-B2G-1 |
| P12-004 | A sign-out or deletion whose scrub failed and was finished by "Try cleanup again" (`retryAccountScrub`) left the previous account's pending schedule/booking work (booking and portal link mirrors, with their link tokens) on the device; the launch recovery and the first attempt cleared it. No leak: each item carries its owner's exact binding and every send, apply and recovery path acts only on the signed-in account's binding, so the next account could neither send nor apply it. The three paths now clear one shared list of stores | S3 | 2026-09-25, Task 9b characterization | 12.00b.2-G | Fixed — 12.00b.2-G (host) (`fix(native): phase 12.00b.2 - every account-scrub path clears the same stores (P12-004)`) |
| P12-005 | On an upgraded device whose RN data carried owner keys (RN writes `__dataOwner` at every initial sync, `utils/sync.ts:406`), sign-out kept the RN-era auxiliary artifact (account state and owner marker) for an exact-owner rollback, so every other account's sign-in was held at the account-mismatch gate, whose only action is "Use another account": no second account could use the device. RN's sign-out clears `__dataOwner` and every account key (`utils/storage/lifecycle.ts:106-159`). The sign-out scrub now drops the auxiliary artifact and its staged copy (a deletion already did): the next account gets a clean workspace and none of the previous account's state, the same account's sign-in takes the ordinary path, and a workspace no scrub cleared still holds another account at the gate | S2 | 2026-09-25, Task 9c review | 12.00b.2-G | Fixed — 12.00b.2-G (host) (`fix(native): phase 12.00b.2 - a signed-out upgraded device accepts another account (P12-005)`); device row P12-B2G-1 |
| P12-006 | A permanent deletion whose local scrub could not write its account-scrub marker (`beginAccountScrub` throws, as on a full or failing volume) ran none of its steps and left nothing on disk saying the deletion was pending: only the in-memory blocked screen. "Try cleanup again" and the scene-activation retry then took the not-pending branch and unblocked without scrubbing, and the next launch loaded the deleted account's records. The snapshot, journal, legacy backups, session, provider key and RN source files all stayed; account B's sign-in met the account-mismatch gate, B's next launch adopted the workspace when the RN data had no owner keys, and B's initial-sync backfill queued A's records for B's push (nothing was re-imported: the snapshot and completed journal were still there). The P12-001 pattern. The deletion is now also recorded in the Keychain (`account-deletion-scrub-pending.v1`, schema version only) and held in memory; Retry, scene activation and the launch write the marker from it first and run the whole `.all` scrub, eraser included, and until then it stays blocked with nothing loaded. Residuals (accepted): if the Keychain write fails too, only the in-memory copy remains (Retry and activation still finish it; a relaunch first does not), counted and logged by stage code. A record that cannot be read at launch does not block the launch (the snapshot it guards is unreadable in the same before-first-unlock window); scene activation re-reads it. The record (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`) survives an uninstall, so uninstalling the native app, installing the RN build, using another account there and then reinstalling the native app would run the `.all` scrub, including the install-wide RN source eraser, on that other account's RN data; reachable only before cutover, by testers, after a marker-write failure (Task 9c re-review Minor 2) | **S1** | 2026-09-25, Task 9c review (Minor 4); reproduced by host test `native/run-legacy-reimport-tests.sh` section 7 | 12.00b.2-G | Fixed — 12.00b.2-G (host) (`fix(native): phase 12.00b.2 - a deletion whose scrub marker cannot be written stays pending (P12-006)`); no device row: the marker-write failure is injected on the host (a read-only app directory) and cannot be produced on a device on demand |
| P12-007 | Crash and error messages keep file paths: the Phase 11 redactor (contract §10.1) has no path rule, so a crash message or an `NSError` description that names a file reaches Sentry with its path (on iOS the app container, with no user name) | S3 | 2026-09-26, Task 11 (12.02) dry run (`native/SupportDiagnosticsTests/main.swift` section 16; `docs/native-phase-12-monitoring.md` §11 finding 1) | A §10.1 contract path rule lands before any file-I/O backlog site (`photoStorage`, `invoicePdfFile`) is wired; today only `deleteAccount`, `purchase` and `restorePurchases` pass raw errors, and native file names are record ids or invoice numbers | Open (backlog) |
| P12-008 | A snapshot save that threw left its change in memory. The payment, bulk Mark paid and invoice editor commits (and eight other sites: onboarding personalization, starting point, demo reset, Settings, the automatic-send clear, and the older invoice and expense saves and expense delete) changed the live snapshot before `repository.save` and did not restore it on failure, so the widget mirror showed the unsaved change at once and the next unrelated save persisted it without queueing it for sync. Characterized on the host (`native/run-save-rollback-tests.sh`): after an unrelated save, a failed payment or bulk settlement showed paid and survived a relaunch, never queued; a pull then left it diverged from the server (row unchanged) or dropped a payment the owner had seen (row changed); a failed create retried left two invoices with the same number, one never synced. RN saves and queues together (`utils/storage/collections.ts:26-35`). Every change made to the live snapshot before its save now commits through `AppStore.commitSnapshot` or `commitSettings`, which keep the previous snapshot and screens when the save throws, and copy sites save first, then apply; nothing unsaved is queued, tracked or mirrored, and the `invoicePayment` capture still fires once. A failed Settings save now says so on the Settings screens, and a failed reset to demo data keeps a blocked source blocked | **S1** | 2026-09-26, Task 11 (12.02) review | 12.00b.2-H | Fixed — 12.00b.2-H (`fix(native): phase 12.00b.2 - a failed save leaves nothing unsaved in memory (P12-008)`, review fixes in `fix(native): phase 12.00b.2 - P12-008 review fixes (pin, settings and bulk failure, demo reset)`); host only: a device cannot force a snapshot save failure on demand |
