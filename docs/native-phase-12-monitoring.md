# Native Phase 12 — monitoring, metrics and support (12.02)

Status: DRAFT, 2026-09-26, on the Phase 12 branch. Plan item 12.02
(`docs/native-phase-12-implementation-plan.md`, requirement E2). The thresholds are the
charter's (`docs/native-phase-12-cutover-charter.md` §3); this document says where each
one is read, how, and who is alerted. `N/` means `native/TradeReadyNative/`.

**Nothing here is configured.** Every dashboard, query and alert below is a definition the
owner builds. No agent creates or configures a Sentry, PostHog or RevenueCat project, key,
DSN, dashboard or alert, and no agent reads production data. The owner holds every role
(D5), so every alert routes to the owner.

## 1. Owner prerequisites

| ID | What | Blocks | Notes |
|---|---|---|---|
| OI-2 | Sentry project `tradeready-ios` in org `tradeready-3r` | every Sentry signal below (TH-2 to TH-10), CR-1 to CR-9, P12-M-2 | The owner creates it. An agent never does (charter §4.1) |
| KEYS | The release Sentry DSN (`TRADEREADY_SENTRY_DSN`) and the PostHog key and host (`TRADEREADY_POSTHOG_API_KEY`, `TRADEREADY_POSTHOG_HOST`), supplied at build time | the same rows, AN-1 to AN-6 | No committed configuration sets them, so a committed build sends nothing (contract §10.4, §9.2). Placeholders only in this repository |
| D4 | Isolated staging | the Stage A dry run of the remote signals (P12-M-2) and the TH-9 query's first run | `https://staging.invalid` stays until real staging exists |
| RC | RevenueCat dashboard access (owner) | TH-10 | Read-only use: the customer view and entitlements |
| STRIPE | Stripe Dashboard access to the connected accounts' Checkout Sessions (owner) | TH-9 | Test mode in Stage A (charter TH-9) |
| SUPA | A read-only way to run SQL on Supabase (owner) | TH-9 | Staging first; production only by the owner, under the charter |
| LOG | A private intake log kept outside this repository | TH-11 | §7 |

Until OI-2 and KEYS are met, the on-device support report (§4) is the only source for the
device-side rows, and each Sentry row below is "runnable, not live".

## 2. Signals per charter metric

Windows for every row follow the charter §3 rule: Stage A per run on team devices;
Stage B rolling 7 days, read at each daily watch; Stage C rolling 24 hours on phased-release
days 1–7, then rolling 7 days; E2 at 12.08 the 14 days after the release reaches 100%. The
Window column adds only what a row itself defines. "Issue alert" means a Sentry issue
alert rule the owner creates, on "a new issue is created" and "the issue changes state from
resolved to unresolved", filtered by the event attribute `exception.value` (the
`[code] message` title, contract §10.4), with the owner as the only recipient (email and the
Sentry mobile app). A context is an extra, not a filterable attribute, so a rule "on a
context" filters on that context's fixed message (§3).

| ID | Source (live or runnable) | Event or query | Threshold (charter §3) | Window | Alert route | Owner |
|---|---|---|---|---|---|---|
| TH-1 | Support report per upgraded device (runnable now; from Settings, or from the "Data migration paused" screen when the migration stops, §4); Sentry `legacyMigration` for the failure half | Report `launchMigration.importedCount`, `missingPhotoCount`, `adoptedPhotoCount`, `deferredPhotoCount` and `persistence.recordCounts`, compared with the Expo data set's known counts; photos adopted + deferred = photos found. A lost record has no remote signal by design: the device cannot know the Expo counts | 0; any is S1 and a §4.8 stop trigger | per upgrade (12.04 SA2 rows) | The SA2 row check itself; a `legacyMigration` issue alert (TH-2) | owner |
| TH-2 | Sentry `legacyMigration` and `initialSync` (new, §3); support report `launchMigration`, exportable from the "Data migration paused" screen itself (§4, Reach) | Issues whose title starts `[legacy-migration/failed/`, `[legacy-migration/missing-migrated-snapshot]` or `[preflight/local-recovery/missing-migrated-snapshot]`; the `operation` extra says where (launch or retry; preflight or pull for `initialSync`). Recovered = a later report shows `launchMigration.lastOutcome` `migrated` and `blocked` false | 0 (S1); a failure that completes on retry is S2 until explained; more than one in a stage blocks its exit | §3 | Issue alert on `exception.value` contains `legacy-migration/` or `missing-migrated-snapshot`: immediate | owner |
| TH-3 | Sentry `pendingAge` (new), `pushQueue`, `pullRemote`; support report `sync` | `[pending-age/over-24h]` issues (count extra = the device's pending changes); `pushQueue`/`pullRemote` issues with a non-transport code whose users stay affected for 24 h; report `sync.oldestPendingAge` `over-24h` and `lastSuccessfulSyncAge` | 0 open; each S2 until classified; 2 or more users with the same code unrecovered for 24 h is a stop trigger | 24 h age, inside §3 | Issue alert on `pending-age/`: immediate. Issue alert "affects more than 1 user in 24 hours" on contexts `pushQueue`/`pullRemote` | owner |
| TH-4 (PERF-7) | Sentry, as TH-3; PostHog for the denominator | Numerator: users per day with a `pushQueue`/`pullRemote` event whose code is not `transport/…`, `non-http-response/…`, `…/401`, a first `…/403` or `…/429` (Sentry issue search, users affected per day). Denominator: PostHog unique users per day with `Application Opened`, or the cohort size where PostHog has no data | ≤ 5% of daily active users (7-day average); every new code triaged whatever the rate | 7-day average | Every new sync issue already alerts (TH-3); the rate is read at the daily watch, since small cohorts make an automatic rate alert noise | owner |
| TH-5 | Sentry `pushDiscarded` (new); support report `sync.discardedChangeCount` | `[record-contract/<table>] Sync push dropped unsendable changes`, with `collection` and `count` | 0; each S1 until shown harmless; a §4.8 stop trigger | §3 | Issue alert on `record-contract/`: immediate | owner |
| TH-6 (OI-3) | Per-pass `pushQueue`/`pullRemote` events; Sentry `syncThrottle` (new); support report; Supabase and Cloudflare dashboards (owner) | Codes ending `/429`; `[throttle/consecutive-passes]` (count = the streak); report `sync.throttledPassCount`, `consecutiveThrottledPasses`, `maxConsecutiveThrottledPasses`, and `/429` entries in `sync.recentCodes` | Signal and blocker levels in §5 (charter §5.5) | 1 h for "2 or more devices"; 24 h for the blocker | Issue alert on `throttle/consecutive-passes`; issue alert "affects more than 1 user in 1 hour" on `/429`; in Stage A any `/429` | owner |
| TH-7 (I2) | Sentry `pushRejected` (12.00b.1); support report; Cloud Sync list on the device | `[rejected/<table>/<status>] Sync push refused changes` (`collection`, `status`, `count`); `[rejected-store/overflow]`; report `sync.rejectedChangeCount` (on file), `rejectedChangeOverflowCount`, `rejectedChangeScrubFailureCount`, `persistence.rejectedChangeCount` (shown) | 0 caused by a native payload or classification defect; each classified within the S2 SLA; an unclassified one blocks a stage exit | §3 | Issue alert on `rejected/` and `rejected-store/`: immediate | owner |
| TH-8 (PERF-9) | Sentry Release Health per release `<bundle id>@<version>+<build>` (`N/NativeCrashReporting.swift:71`, session tracking `:20`); Xcode Organizer and TestFlight (PERF-4, advisory) | Crash-free session rate for the release; crash issues (level fatal); Organizer hangs and terminations | ≥ 99.5% with ≥ 300 sessions in the window; below that every crash is triaged and a core-flow crash is S1; 24 h below the floor with the minimum met is a stop trigger | 24 h for the floor | Metric alert "crash-free session rate below 99.5% over 24 hours" on the release (the owner checks the session count before acting); issue alert on every new fatal issue | owner |
| TH-9 | Stripe Dashboard vs a read-only Supabase query (owner, §6); PostHog cross-check; Sentry `invoicePayment` (new) | §6. PostHog `payment_recorded`, `invoice_paid`, `bulk_invoices_marked_paid` daily counts (emission-tested, §9); `[invoice-payment/…] Payment could not be saved` | 0 unreconciled older than 24 h; a wrong amount, duplicate or lost entry is S1 and a stop trigger | 24 h age; the check runs daily | Issue alert on `invoice-payment/`: immediate. The reconciliation is a daily manual check | owner |
| TH-10 | RevenueCat customer view vs the app's paywall state (owner); Sentry `purchase`, `restorePurchases` (new); PostHog | RevenueCat entitlement per tester vs what the app shows; Sentry issues in contexts `purchase` (a user cancel is not reported) and `restorePurchases`; PostHog `subscription_purchased` (emission-tested) and `subscription_paywall_shown{context=onboarding_gate}` from a user RevenueCat shows entitled = a mismatch candidate | 0 mismatches; each S2, S1 if a paying user loses access with no restore path | §3 | Issue alert on contexts `purchase`/`restorePurchases` (fingerprint = context): immediate | owner |
| TH-11 | The intake channel and log (§7); TestFlight feedback | Every contact logged and classified S1/S2/S3/not a defect, with the support report when attached | 100% triaged within the charter §2 SLA; 0 unexplained missing- or wrong-data reports; over 1 contact per 5 active cohort users in a week triggers a review (advisory) | 7 days for the advisory ratio | The support inbox and TestFlight feedback email notifications, read at every watch | owner |
| TH-12 (PERF-1, 2, 5) | Instruments App Launch traces and the `LegacyMigration` signpost (12.04); Organizer launch metrics (PERF-4) | Cold and warm launch medians; first-launch migration with no watchdog termination | Advisory: cold median ≤ 2.0 s (SE17), warm ≤ 1.0 s; a hang or termination is S1 | per Stage A run | None automatic: recorded per 12.04 run; a termination also reaches TH-8 | owner |

## 3. New remote signals (12.02)

All go through `AppStore.reportError` (`N/AppStore.swift:12328`), so each is the Phase 11
`reportError` path: the §10.1 redactor, the allow-listed extras, a bounded `rawError`
`{code, message}` and the fingerprint `["{{ default }}", <context>]`, one Sentry issue per
context (contract §10.3, §10.4). Every code is built from table names, operation names
and an error's domain and number, never from a message, record, path or identifier.

| Context | Title: code, then message | When | Extras | Repeat rule | Metric |
|---|---|---|---|---|---|
| `legacyMigration` | `legacy-migration/failed/<domain>/<code>` or `legacy-migration/missing-migrated-snapshot`; "Previous-app data migration did not finish" | the launch migration or its Try again throws; a completed journal with no native snapshot. Never for the P12-003 signed-out steady state (completed journal, no snapshot, the scrub-cleared record) | `operation` launch/retry | once per launch or retry | TH-1, TH-2 |
| `initialSync` | the gate's own diagnostic code (`preflight/local-recovery/<reason>`, `preflight/configuration-or-session`, or the pull's code); "Initial sync did not complete" | the initial-sync gate refuses (RN `utils/sync.ts:410`) | `operation` preflight/pull | once per refusal | TH-2, TH-3 |
| `pushDiscarded` | `record-contract/<table>`; "Sync push dropped unsendable changes" | a pass dropped a queued change as unsendable, whatever the pass's last outcome: it can end completed, or deferred or offline when a trigger that arrived mid-pass reran it | `collection` = the pass's first dropped table only (a pass that drops from two tables names the first); `count` = every drop in the pass | once per pass with a drop | TH-5 |
| `syncThrottle` | `throttle/consecutive-passes`; "Sync passes throttled in a row" | the third network pass in a row with a `/429` code (push or pull) | `count` = streak | once per streak; a pass without a 429 or an account boundary re-arms it | TH-6 |
| `pendingAge` | `pending-age/over-24h`; "Changes pending for over 24 hours" | a network pass ends with a queued change older than 24 h | `count` = pending changes | once per episode; re-arms when the oldest change is under 24 h or at an account boundary | TH-3 |
| `invoicePayment` | `invoice-payment/commit/<domain>/<code>`, `invoice-payment/projection` or `invoice-payment/bulkMarkPaid/<domain>/<code>`; "Payment could not be saved" | a payment the owner entered, or a bulk mark-paid, could not be saved | `operation` commit/bulkMarkPaid; `count` (bulk) | once per failed save | TH-9 |
| `purchase` | the RevenueCat error as is (its redacted description) | a purchase throws, except a user cancel (RN `screens/PaywallScreen.tsx:94`) | — | once per failure | TH-10 |
| `restorePurchases` | the RevenueCat error as is (its redacted description) | Restore Purchases throws (RN `screens/PaywallScreen.tsx:115`) | — | once per failure | TH-10 |
| `accountScrub` | `account-scrub/blocked/<live/all/unknown>`, plus `/without-marker` for a deletion held only by the Keychain record; "Account cleanup could not finish" | a sign-out's or deletion's local cleanup is blocked (P12-001, P12-006) | `operation` launch/signOut/deleteAccount/retry; `count` = blocked attempts this launch (cap 99) | once per blocked episode within a launch; an unblocked cleanup re-arms it. The episode flag and the count are held in memory, so a cleanup still blocked at the next launch reports again, with the count back at 1: at most once per launch | charter §2 privacy row; support |

Already live before 12.02: `pushQueue` "Sync push left changes queued" and `pullRemote`
"Sync pull did not complete" (Phase 11, `utils/sync.ts:211`, `:312`), `deleteAccount`
(Phase 11, `N/SettingsView.swift:973`), `pushRejected` "Sync push refused changes"
(12.00b.1) and `widgetLock` "App Group lock busy" (12.00b.2-B).

**Why Sentry, not PostHog.** (1) The analytics catalog is closed to the RN events: Q4
(contract §17.1) requires RN's `track(` sites to equal the 52-event catalog, so a
native-only failure event would break the catalog check and cross-client parity.
(2) These are failures, and the charter already reads failures from Sentry (TH-3, TH-4).
(3) The Sentry path is the one with the §10.1 denylist, allow-listed extras and a
per-context fingerprint; PostHog carries product properties under a different policy.
(4) Sentry has per-issue alerting and "users affected" counts, which the stop triggers
need. The cost: every signal here needs OI-2 and KEYS. Until then the support report
carries the same facts as counts.

## 4. The support export

"Prepare support report" (`N/NativeSupportReportAction.swift`), in Settings › Migration
support and on both blocked screens (`N/RootView.swift`; Reach below), calls
`AppStore.createPersistenceSupportReport` (`N/AppStore.swift:977`), which now
writes the version 4 report built by `AppStore.supportReport` (`N/AppStore.swift:989`)
from the types in `N/NativeSupportDiagnostics.swift`. The user shares
`tradeready-support-report.json` from the share sheet, usually into the Contact support
email. The v2 persistence report (Phase 2) is kept whole under `persistence`, so nothing
it carried is lost.

**Schema (closed).** Every field the v3 and v4 reports add is a version, a boolean, a count
capped at 9,999, an age bucket (`none`, `under-1h`, `1h-to-24h`, `over-24h`) or a bounded
code. The nested v2 part keeps its own counts uncapped, as Phase 2 and 12.00b.1 wrote them
(`persistence.recordCounts` and `persistence.rejectedChangeCount`): they are the owner's
own record counts, which TH-1 compares exactly, and carry no content:

- `reportSchemaVersion` (4; 12.06 raised it from 3 by adding `rollbackReadiness`),
  `app {version, build}`;
- `persistence`: the v2 report (record and file counts, backups, journal, rejected
  count), or `null` with `persistenceUnavailableCode` when the snapshot cannot be read;
- `launchMigration`: notice, blocked, block reason and detail, the last outcome
  (`not-attempted`, `migrated`, `conflict`, `already-completed`,
  `native-state-adopted` (12.06, `P12-011`), `missing-migrated-snapshot`, `no-data`,
  `failed`), operation, failure code, and the
  imported, missing, adopted and deferred counts;
- `accountBoundary`: scrub pending and its scope (`none`, `live`, `all`, `unreadable`,
  `undecodable`; never the marker's bytes), scrub blocked with scope and attempt count,
  deletion pending without a marker, the Keychain deletion record's presence
  (`absent`, `present`, `unreadable`), the P12-003 workspace-cleared record's presence,
  cleanup pending, each boundary step's pending and unverified flags, and the
  marker-write, record and AI-key-wipe failure counts;
- `sync`: queue length, oldest pending age, syncing, consecutive failures, last outcome,
  diagnostic code, last pull state and code, backoff active, last successful sync age, the
  I2 rejected count on file (including an entry Cloud Sync hides while a newer change for
  its record is queued) with its overflow and scrub-failure counts, the discarded count,
  the throttled-pass counts, and `recentCodes` (the last 16 `reportError` contexts and
  codes, consecutive repeats merged into a count) with `recentCodesOmitted`;
- `widgets`: mirror dirty, lock-busy count, and the replay quarantine and set-aside counts;
- `legacyBackupProtection` (L267.a, counts only): checks run, enumerator unavailable,
  files protected and failed at the last check, failures in total;
- `rollbackReadiness` (12.06, v4): the last Settings › Cloud Sync › Check everything is
  saved on this account (`none`, `ready`, `not-ready`), its age bucket, the drain's sync
  outcome code (`skipped` when a fail-closed condition held), the blocker codes, the
  note codes (`notes`, which never block), the waiting-change, refused-change,
  widget-action, photo-upload and booking-work counts, and the migration journal state;
  `none` before any check and after an account change
  (`docs/native-phase-12-rollback-playbook.md` §5.1). `bookingWorkCount` is this
  account's unfinished booking or portal link work. It is reported as the note
  `booking-work-pending`, or `booking-work-unreadable` when its file does not decode, and
  never as a blocker: the items hold no native-only business data. A mirror item records
  a change the server already made, and a reschedule proof guards a server resolve whose
  job change is in the ordinary queue. Launch and every activation finish or clear
  them (2026-09-26, 12.00b.2-I, defect `P12-013`), so a count that stays is a mirror
  waiting for a committed pull and a successful status read (for example offline), or
  a reschedule proof waiting for the owner's resolve. Each recovery pass that finds
  items logs one counts-only line, `TradeReadyScheduleBookingRecovery stage=pass`
  (playbook §5.1), to the unified log ("On-device log lines" below).

**Code rule.** A code keeps only `A–Z a–z 0–9 . _ / -`, at most 96 bytes, with no run of
6 or more digits, no run of 12 or more hex characters containing a digit, and nothing
`NativeErrorRedaction.standard.redactString` would change. Anything else becomes
`unrecognized`. So an email, a URL (`:` is refused), a token, an id or a phone number never
survives as a code.

**Cap.** 16,384 bytes (`NativeSupportDiagnostics.maximumReportBytes`). Over it the oldest
recent codes are dropped first and counted; a report that still does not fit is not
written (`reportTooLarge`) and the action says the report could not be created. The dry-run
report was 2,450 bytes (2,705 with the v4 `rollbackReadiness` section, its notes and
booking-work count included, in the 12.06 host run).

**Never included:** records, names, contact details, notes, record ids, the owner
binding or Supabase subject, file paths, error messages, keys, tokens, sessions, marker
bytes, and document or photo bytes. The host tests seed each of these (a `sk_live_` key,
`sk-ant-` and `gsk_` keys, a `phc_` token, a JWT session, an email, a phone number, a
customer name and notes, a refused change's payload, base64 document bytes in the legacy
backup, a hostile version and build, a malicious sync code) and prove none reaches the
file (§12; `native/SupportDiagnosticsTests/main.swift` section 13).

**Deletion pending.** A deletion that cannot finish shows as `accountBoundary`
`scrubBlocked` with scope `all` (and `deletionRecord` `present`,
`deletionPendingWithoutMarker` when the marker could not be written), and remotely as
`accountScrub` `account-scrub/blocked/all[/without-marker]`.

**Reach.** A device held on "Data migration paused" or on the cleanup-paused screen
("Sign-out cleanup paused", "Account deletion cleanup paused"; `N/RootView.swift`) never
reaches Settings, so both screens show the same action under Try again and Contact
support (review fix round 1, 2026-09-26). It only reads diagnostics and writes the
report file beside the store, never an owner record, so it works while owner writes are
blocked. Host tests create the v4 report in each blocked state (a failed migration, a
missing migrated snapshot, a blocked sign-out cleanup and a blocked deletion cleanup),
with owner writes still blocked, and prove no other file changes (§12). For TH-1/TH-2 and
P12-001/P12-006 the blocked device's report is therefore a source alongside the remote
signals in §3. No device row reaches these screens on demand: each needs an injected
failure.

**On-device log lines** (final review M6, 2026-09-27). The `stage=` diagnostic lines that
Phase 12 added go to the unified log, subsystem `com.tradeready.native`, category
`diagnostics`, through `Logger` (`N/AppStore.swift` `stageLogger`; one file-private logger
each in `N/Domain/SnapshotRepository.swift`, `N/NativeAppGroupInbox.swift`,
`N/NativeSupabasePush.swift`, `N/NativeWidgetActionReplay.swift` and
`N/Widgets/Shared/WidgetActionQueue.swift`). A TestFlight or App Store build keeps them.
Before, they used `print`, which reaches only an attached debugger's console.
- **Where to read them.** Console.app with the iPhone attached, filtered on the
  subsystem, or a sysdiagnose from the device. They are not in the support report: its
  counts (above) carry the same facts.
- **Levels.** A pass, check or contention line logs at `notice`: `TradeReadyBookingIntake
  stage=pass`, `TradeReadyScheduleBookingRecovery stage=pass`, `TradeReadyRollbackReadiness
  stage=checked`, `TradeReadyRejectedChanges stage=filed`, `TradeReadyMutationPush
  stage=superseded` and `TradeReadyWidgetLock stage=busy`. A failure logs at `error`: the
  run marker, account-boundary steps, an unreadable claim, the rejected-change overflow
  and boundary scrub, a failed Retry enqueue, the scrub-cleared record and the
  legacy-backup enumerator.
- **Privacy.** Every value in a line is an integer, a Bool or a fixed code (a stage,
  step, table or reason name), marked public so a Release build shows it instead of
  `<private>`. No record, name, token, key, binding or path.
- **Unchanged.** `stage=` lines from before Phase 12 still use `print`.

## 5. OI-3: 429 bursts (TH-6)

**R19 (2026-09-25).** 12.00b.1 relaxed the pull guard toward RN: a push pass that reaches
per-item results now pulls afterward even when changes stay queued, including under a
429 (contract §17.2, I2; `N/NativeSyncCoordinator.swift:340`). A thrown push still skips
the pull. So one throttled pass from one device sends:

- N push requests, one per queued change (N = the queue length), and
- the pull's reads: at least 12 (the 10 collections, `settings` and `customer_notes`,
  `N/NativeInitialSync.swift:106`), plus one per extra 500-row page.

A pass that ends partial or failed backs off: 5 s doubling to a 300 s cap
(`N/NativeSyncCoordinator.swift:185`, `:516`). A sustained burst therefore allows about 17
automatic passes in its first hour and 12 an hour after that, each of N + 12 or more
requests, plus every manual sync (which bypasses the backoff). The poor-network harness
and the 12.02 dry run use a stub link; the dry run counts push requests only, because its
coordinator has no pull wired.

**Levels (charter §5.5).**

- Counted: every 429 pass (`pushQueue`/`pullRemote` events with a `/429` code; the report's
  `throttledPassCount`).
- Signal, reviewed as S3: one device with 429 codes on 3 consecutive passes (`syncThrottle`,
  exactly this rule); 2 or more devices with a 429 within the same hour (the "affects more
  than 1 user in 1 hour" alert); any 429 in Stage A.
- Blocker: a 429 that leaves a device's queue undrained for 24 hours while online
  (`pendingAge` with `/429` in that device's report `recentCodes`, TH-3), or server
  evidence that one device's pass trips the limit (Supabase and Cloudflare dashboards,
  owner). Then the push must stop at the first 429 before Stage C (charter §5.5 item 3).

## 6. TH-9 payment reconciliation

Owner only, read-only, run first on staging (D4) and in Stripe test mode. Daily at the
watch:

1. Stripe Dashboard, each connected account: Checkout Sessions completed in the window,
   exported with session id and amount.
2. Supabase, read-only: the Stripe entries on invoices. A sketch to validate on staging
   (the webhook writes `payments[]` into the invoice's `data`,
   `backend-workers/src/routes/stripe/webhook.js`):

   ```sql
   select i.id as invoice_id, p->>'id' as payment_id, (p->>'amount')::numeric as amount
   from public.invoices i
   cross join lateral jsonb_array_elements(coalesce(i.data->'payments', '[]'::jsonb)) p
   where p->>'method' = 'stripe'
     and coalesce(i.deleted, false) = false
     and i.updated_at >= now() - interval '8 days';
   ```

   Every session must appear exactly once as `stripe_<session id>` with the same amount;
   a `group by payment_id having count(*) > 1` finds duplicates.
3. Repeat after the next native sync of those invoices (the webhook's read-modify-write
   race, charter TH-9).
4. Cross-check: PostHog `payment_recorded` (manual payments) and `invoice_paid` /
   `bulk_invoices_marked_paid` daily counts against the new non-Stripe `payments[]`
   entries, and no `invoicePayment` issue in Sentry.

Record only counts and mismatching ids in the stage record, never customer data.

## 7. Intake channel and triage SLA

Proposed for the owner to confirm at Stage A entry:

- **Channel.** The in-app Contact support email (Settings › Contact support,
  `N/SettingsView.swift:124`; the blocked cleanup and migration screens link the same
  address with their own subject, `N/RootView.swift:24`, `N/RootView.swift:41`) and, in
  Stages A and B, TestFlight feedback. Users attach the support report (§4) from Settings,
  or from the blocked screen itself.
- **Log.** A private log outside this repository, one row per contact: date received,
  channel, app version and build, severity (S1/S2/S3/not a defect), charter metric, defect
  ID (`P12-…`), status, and whether the SLA was met. Contact details stay in the mail
  client, not the log.
- **SLA (charter §2 rule 5):** S1 — a pause or rollback decision the same day, within 4
  hours of reading the report; S2 — classified and assigned within 1 business day; S3 —
  within 5 business days. Each missing- or wrong-data report becomes a defect (TH-11).

## 8. L193.b: `reportError` sites

RN calls `reportError` at 74 sites. 12.02 wires the ones a charter metric reads:

| RN site | Native site | Since |
|---|---|---|
| `utils/sync.ts:211` `pushQueue` | `AppStore.applySyncStatus` | Phase 11 |
| `utils/sync.ts:312` `pullRemote` | `AppStore.applySyncStatus` | Phase 11 |
| `screens/SettingsAccountScreen.tsx:61` `deleteAccount` | `SettingsView.performDeleteAccount` | Phase 11 |
| `utils/sync.ts:410` `initialSync` | `AppStore.beginInitialSyncGate` (both preflight refusals and the pull) | 12.02 |
| `screens/PaywallScreen.tsx:94` `purchase` | `AppStore.purchaseSubscription` (not for a user cancel, as RN) | 12.02 |
| `screens/PaywallScreen.tsx:115` `restorePurchases` | `AppStore.restoreSubscription` | 12.02 |

Native-only contexts with no RN site: `pushRejected` (12.00b.1), `widgetLock`
(12.00b.2-B), and `legacyMigration`, `pushDiscarded`, `syncThrottle`, `pendingAge`,
`invoicePayment` and `accountScrub` (12.02). There is still no ErrorBoundary analog.

**Backlog (68 RN sites, none read by a charter metric; S3; charter §10 Backlog row
L193.b-rest).** Native surfaces these failures in the UI or folds them into the
coordinator's codes:

| Area | Sites |
|---|---|
| Sync | `trySyncNow`, `backfillLocalOnlyCollections`, `pushAllLocalToCloud` (3) |
| Photos | `utils/photoSync.ts` (6) and `utils/photoStorage.ts` (3) |
| CSV import | `screens/SettingsImportScreen.tsx` (8) |
| Customers and portal links | `screens/AddCustomerScreen.tsx` (2), `screens/CustomerDetailScreen.tsx` (10), `screens/CustomersScreen.tsx` (2) |
| Jobs | `screens/JobsScreen.tsx` (1), `screens/JobDetailScreen.tsx` (4), `components/JobProfitabilitySection.tsx` (2) |
| Invoices and payment settings | `screens/OutreachScreen.tsx` (2), `screens/CreateInvoiceFromJobScreen.tsx` (2), `utils/invoicePdfFile.ts` (1), `utils/autoInvoice.ts` (2), `screens/SettingsPaymentsScreen.tsx` (2) |
| Booking settings | `screens/SettingsBookingScreen.tsx` (4) |
| Subscription setup | `configurePurchases` in `utils/subscription.ts` (1) |
| Today and Money | `screens/TodayScreen.tsx` (2), `utils/storage/dailyOps.ts` (2), `hooks/useMoneyData.ts` (3) |
| Other | `fontGateLoad` (`App.tsx`), `onboardingFinish`, `startChoice`, `aiChat`, `settingsSave`, `shrinkLogoOnPick` (6) |

## 9. L178: emitters a charter metric reads

TH-9 and TH-10 read four PostHog events. Each now has a store-level emission test in
`native/AnalyticsEventTests/main.swift`, checked by removing the emitter:

- `paymentEmittersReadByCharter`: `payment_recorded` and `invoice_paid` from a recorded
  payment, `invoice_paid` per invoice and one `bulk_invoices_marked_paid{count}` from a bulk
  mark-paid. Removing the `invoice_paid` emissions fails 2 of 542 checks.
- `subscriptionEmitterReadByCharter`: `subscription_purchased` once for a completed
  purchase, none for a cancel or a thrown purchase. Removing the emitter fails 1 of 545.

L178 stays Open in the charter: the other store-level emitters (none read by a metric)
still have no emission test.

## 10. Dry run on synthetic data (2026-09-26)

Host fixtures only, a stub link on `dry-run.invalid`, no network
(`native/SupportDiagnosticsTests/main.swift` section 16; command in §12). Output:

| Fixture | Signal produced |
|---|---|
| A failed migration (the migration provider throws) | Sentry `legacyMigration`: `[legacy-migration/failed/com.example.Fixture/7] Previous-app data migration did not finish`. Report `launchMigration`: `lastOutcome` failed, `lastOperation` launch, `lastFailureCode` `com.example.Fixture/7`, `notice` failed, `blocked` true, `persistenceBlockReason` legacy-migration |
| A poison item (one change refused with 422, one unsendable) | Outcome completed (1 pushed), 2 requests, code `rejected/jobs/422`, 1 discarded, 0 queued. Sentry `pushRejected` `[rejected/jobs/422] Sync push refused changes` (collection jobs, count 1, status 422), then `pushDiscarded` `[record-contract/jobs] Sync push dropped unsendable changes` (collection jobs, count 1). Report `rejectedChangeCount` 1, `discardedChangeCount` 1 |
| A 429 burst (2 queued changes, every request 429) | 3 passes, each partial (0 pushed, 2 remaining) with 2 push requests and code `http-response/jobs/429`. Sentry `pushQueue` three times, then `syncThrottle` `[throttle/consecutive-passes] Sync passes throttled in a row`. Report `throttledPassCount` 3, `consecutiveThrottledPasses` 3, `pendingCount` 2 |
| A crash-style error and a crash event | Sentry `deleteAccount`, domain `com.example.Fixture`, extras `{"context":"deleteAccount"}`. The redacted crash event keeps no email (`[email]`), token (`[Filtered]`), IP or name (user `{id}` only), but **keeps the file path** in its message (finding, §11) |
| The report | 2,450 bytes of 16,384; sections `accountBoundary`, `app`, `launchMigration`, `legacyBackupProtection`, `persistence`, `persistenceUnavailableCode`, `reportSchemaVersion`, `sync`, `widgets` |

## 11. Findings and follow-ups

1. **Crash messages keep file paths.** The Phase 11 redactor (contract §10.1) has no
   file-path rule, so a crash or error message that names a file keeps its path. On iOS
   that is the app container, with no user name, but an `NSError` description can carry a
   file name. Logged as **P12-007** (charter §10, S3, Open, backlog): a §10.1 path rule in
   `N/NativeErrorRedaction.swift` lands before any file-I/O backlog site (`photoStorage`,
   `invoicePdfFile`, §8) is wired. Today only `deleteAccount`, `purchase` and
   `restorePurchases` pass raw errors, and native file names are record ids or invoice
   numbers. CR-6 inspects stored events for it.
2. **A failed payment save leaves the in-memory snapshot changed.** `commitInvoicePayment`
   and `commitBulkSettleInvoices` write the payment into the in-memory snapshot before
   `repository.save`, and do not roll it back when the save (or the payment's projection)
   fails. `apply` is never reached, so the screens do not show the payment and nothing is
   queued. The hazard is later: the next unrelated save writes the whole in-memory
   snapshot, so it persists the payment without ever queueing it for sync, and the
   snapshot's `didSet` already refreshes the widget mirror from it. `invoicePayment`
   (§3) makes the failed save visible remotely. Logged as **P12-008** (charter §10, S1
   once characterized: after the next unrelated save the payment showed paid, unqueued,
   and a pull left it diverged or dropped it). **Fixed in 12.00b.2-H (2026-09-26):**
   every change made to the live snapshot before its save, these two and nine other
   sites included, commits through `AppStore.commitSnapshot` or `commitSettings`, which
   keep the previous snapshot and screens when the save throws, and copy sites save
   first, then apply, so nothing unsaved is mirrored, queued or persisted by a later
   save; the `invoicePayment` capture still fires once. Tests:
   `native/run-save-rollback-tests.sh` (each site, plus a source pin).
3. **Pending age follows the last write.** A queued change's timestamp is its last edit
   (last-writer-wins), so a change edited again inside 24 hours never looks old to
   `pendingAge`.
4. **A thrown cancel shows as failed.** RevenueCat can report a cancel by throwing
   (`purchaseCancelledError`); native does not report it to Sentry (host-tested with
   `RevenueCat.ErrorCode` 1) but still shows the failed state, where RN shows nothing. An
   S3 parity gap, charter §10 "New in Phase 12" row P12-009 (renumbered from `12.02-F4`
   by task 14, R40); no code change in 12.02.
5. **Two rejected counts.** `sync.rejectedChangeCount` counts refused changes on file;
   `persistence.rejectedChangeCount` counts the ones Cloud Sync shows. They differ while a
   newer change for a refused record is queued.
6. **The report was not reachable from the blocked screens.** Resolved in review fix
   round 1: both blocked screens show the Settings action (§4, Reach).
7. **PERF-3 (proposed decision, owner to ratify):** no UI-test target in Phase 12. Adding
   one changes the Xcode project and needs a signed device run; TH-12 is advisory and
   reads Instruments App Launch traces (12.04) and Organizer (PERF-4). PERF-3 stays open
   until the owner logs the decision.
8. **A deferred rerun hides its pass's network outcome.** A sync trigger that arrives
   mid-pass is rerun inside the same pass (`NativeSyncCoordinator.sync`), and the pass's
   status then carries the rerun's outcome. After a partial or failed first run the rerun
   is usually deferred by the backoff, so the pass ends `.backoffDeferred`: its discards
   still report (TH-5, fixed in review fix round 1), but the first run's `pushQueue` or
   `pullRemote` report, its `/429` count toward `syncThrottle` and the `pendingAge` check
   are skipped for that pass. The next network pass reports the same state, so a
   persistent failure is late by one pass, not lost. Pre-existing for `pushQueue` and
   `pullRemote` (Phase 11); left for the owner to classify, since a fix changes the
   contract §10.4 per-pass semantics.

## 12. Tests and commands

All `TZ=America/Phoenix`, host only:

- `sh native/run-support-diagnostics-tests.sh` (new; 239 checks since 12.06): the signals in §3 at
  their sites, including the P12-003 steady state staying silent, one report per
  blocked episode in a launch, a discard in a pass whose coalesced rerun was deferred (reported once)
  and a thrown RevenueCat cancel (not reported); the pure code, age and count rules; the
  export's closed schema, cap and seeded-secret exclusions; the boundary and migration
  state; the report from both blocked screens (the v4 report while owner writes are
  blocked, no other file changed, and one shared action in Settings and in both
  `RootView` blocked branches); the dry run.
- `sh native/run-accessibility-audit-tests.sh`: the shared action
  (`N/NativeSupportReportAction.swift`) is in the reviewed view inventory.
- `sh native/run-sync-coordinator-tests.sh` and `sh native/run-mutation-push-tests.sh`:
  the discarded count and table (TH-5), reset at each pass.
- `sh native/run-analytics-event-tests.sh` (545 checks): §9.
- `sh native/run-store-integration-tests.sh` and `sh native/run-rejected-changes-tests.sh`:
  the v4 report around the v2 part, and the I2 count in it.
- `sh native/run-rollback-readiness-tests.sh` (12.06): the `rollbackReadiness` section
  and the check behind it.
- `sh native/run-error-redaction-tests.sh`, unchanged.
- `sh native/run-all-domain-tests.sh`; it ends at the AGG-1 `npm test` step (charter §4.1).

Device and staging checks are rows P12-M-1 to P12-M-3 in
`docs/native-phase-12-evidence-index.md` §23.
