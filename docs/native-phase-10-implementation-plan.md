# Phase 10 — Subagent Implementation Plan

**Date:** 2026-09-21

**Status:** In progress — 10.00, 10.01, and 10.03 code complete (see §6 ledger and
§7 log); all other tasks pending. Revised 2026-09-22 per
[native-phase-10-12-plan-review.md](native-phase-10-12-plan-review.md).

**Roadmap goal (Phase 10):** Restore the daily operating surface and proactive behavior.

**Scope source:** [native-ios-migration-roadmap.md](native-ios-migration-roadmap.md)
Phase 10 (Deliverables and Exit criteria) plus the parity rows in
[native-parity-matrix.md](native-parity-matrix.md): "Today and planning" (Today,
Setup checklist, Proactive insights), "Coach" (AI coach, Quick prompts, Insight
handoff), "Money, pricebook, imports, and exports" (the expense/snapshot inputs
the insights and tax block consume), and "Platform and operations"
(Notifications, Background refresh, Deep links). Design sources:
[2026-08-04-today-insights-design.md](superpowers/specs/2026-08-04-today-insights-design.md),
[2026-08-07-contextual-ai-design.md](superpowers/specs/2026-08-07-contextual-ai-design.md),
[2026-08-07-calendar-availability-booking-design.md](superpowers/specs/2026-08-07-calendar-availability-booking-design.md)
(§7 booking attention), and
[2026-07-17-appointment-reminders-design.md](superpowers/specs/2026-07-17-appointment-reminders-design.md).

## 1. Execution contract

Use one bounded task per subagent session. Read this plan, the roadmap Phase 10
section, the parity rows above, and the listed source/tests before editing.
Existing uncommitted migration/backend files are working inputs, not disposable
scaffolding. Do not commit, deploy, run live migrations, or contact production
accounts unless separately instructed.

`N/` means `native/TradeReadyNative/`. Proposed filenames below do not imply files
already exist. Match the existing host-test runners (`native/run-*.sh`) and Xcode
source inclusion rather than introducing another package/build system.

Every implementation task must:

1. State satisfied dependencies and the requirement IDs it implements.
2. Keep policy in pure Swift modules and services injectable; use canonical
   preservation, the existing owner/environment guards, repository, and mutation
   queue. No notification-selection, insight-ranking, snapshot, or coach-prompt
   policy in a view.
3. Resolve current IDs, merge only owned fields, check async owner/workspace
   identity across every suspension point, and publish success only after the
   relevant durable/server boundary.
4. Add meaningful fixture/failure tests, run focused checks, and compile when
   touching UI/platform wiring. Report exact commands and actual results.
5. Return files changed, test counts/results, limitations/blockers, and
   next-ready task IDs. A blocked task stays blocked; no placeholder action
   counts as done.

Device verification is deferred per the roadmap's
[2026-09-16 verification-deferral decision](native-ios-migration-roadmap.md)
(Phase 12 owns physical-device, permission, and delivery evidence). Phase 10
still must *produce* the device runsheet rows; it does not claim them as passed.

### Requirement IDs

- **D1** Today day/week schedule projection and the earnings/overdue/leads stats
  summary.
- **D2** Overdue-invoice and follow-up (lead) briefing sections with exact caps,
  see-more, and routing.
- **D3** Booking/portal attention rows with their contextual actions and
  self-dismissal semantics.
- **D4** Setup checklist: derivation, device-local persistence, dismissal, and
  contextual settings navigation.
- **D5** First-action hero and the sample-tour "used once" state.
- **D6** Contextual actions and one-shot cross-tab routing for every row/insight
  target.
- **S1** Business snapshot aggregation.
- **S2** Tax snapshot block the coach may cite.
- **S3** Proactive insight rules (all eight kinds) with stable ids, priorities,
  reasons, targets, and coach prompts.
- **S4** Insight mute/snooze lifecycle (device-local, owner-bound, prune, scrub).
- **S5** Insights card presentation: top-three slice, mute gating, setup gating.
- **C1** Coach provider routing and transports (Anthropic key, Groq key, backend
  proxy).
- **C2** Coach system prompt exposing only the intended business context.
- **C3** In-session chat transcript, `MAX_HISTORY` window, and data-aware quick
  prompts (quick-prompt branch policy is pure and owned by 10.10; 10.13 renders).
- **C4** Markdown-lite rendering, copy, typed error state, and usage-limit
  behavior (the `formatChatText` transform is pure and owned by 10.10).
- **C5** Insight→coach contextual prefill (editable, never auto-sent).
- **N1** Notification permission prompt, categories, and settings surface.
- **N2** Due-date (invoice-dunning) reminders including the auto-outreach body
  variant.
- **N3** Appointment reminders.
- **N4** Review-request reminders.
- **N5** Namespace coordination, shared 60-request cap, priority, and per-family
  cleanup.
- **N6** Tap routing from every payload to the exact native record, fail-closed.
- **B1** Extend the Phase 4 background task so that, after a real sync pass, one
  post-commit hook (a) reconciles notifications from the committed snapshot,
  (b) exposes the seam the Phase 11 widget mirror (11.01) plugs into, and
  (c) refreshes a cached `NativeBusinessSnapshot` for coach cold start. Today and
  insights themselves are derived at render time and have no background output.
- **B2** Fail-safe, idempotent background/scheduling behavior with duplicate
  prevention across app launches.

### Shared-file ownership

- **Integration lane:** only tasks 10.11–10.13 edit `N/AppStore.swift`,
  `N/TodayView.swift`, `N/CoachView.swift`, `N/RootView.swift`,
  `N/SettingsView.swift`, `N/Components.swift`, and tab/navigation state. Run
  those tasks serially even when their policy dependencies are ready.
- **Notification lane:** 10.05–10.09 share
  `N/NativeEstimateFollowUpNotifications.swift` (the coordinator and
  `NativeNotificationRoute`), the notification-plan methods and schedule key in
  `N/AppStore.swift`, and the delegate/registration in
  `N/TradeReadyNativeApp.swift`. Run serially; keep every existing identifier
  scheme and the foreign-family rule intact.
- **Pure/service lane:** 10.01, 10.02, 10.03, 10.04, 10.10 use separate files and
  can run in parallel where dependencies permit. They return integration
  contracts; they do not opportunistically edit shared UI/store files.
- The coordinating agent owns aggregate runner/project membership and document
  updates. A task may propose the exact additions; serialize their application.
  Separate worktrees are preferred for concurrent writers; never merge by
  overwriting another task's shared-file edits.

### Existing code this phase builds on (do not duplicate)

The daily surface is a prototype today, but several Phase 6–8 foundations must be
reused rather than rebuilt:

- **Pure notification families already exist and are wired:**
  `N/NativeEstimateFollowUpNotifications.swift` defines
  `NativeNotificationNamespace` (`est_`, `appt_`, `review_`, `inv_`, `rinv_`),
  `NativeNotificationRoute`, `NativeNotificationPlanItem`,
  `NativeNotificationNamespacePlan`, and an owner-bound coordinator with
  per-namespace cleanup under a shared 60-request cap. `N/AppStore.swift` already
  produces `estimateFollowUpNotifications`, `appointmentConfirmationNotifications`,
  `reviewRequestNotifications`, `invoiceReminderNotifications`, and
  `recurringInvoiceReminderNotifications`, and `TradeReadyNativeApp.swift`
  registers the `.appointment`/`.review`/`.invoiceReminder` plans plus
  `openOwnedRoute`. `N/NativeAppointmentNotifications.swift`,
  `N/Domain/NativeInvoiceNotifications.swift`, `N/NativeReviewRequests.swift`, and
  `N/NativeReviewRequestStore.swift` hold the pure selectors and the review store.
- **Migration seeds already parse the device-local state:**
  `N/NativeTypedAccountState.swift` and `N/LegacyMigrationCoordinator.swift`
  already decode `setupChecklistState`, `insightMutes`,
  `invoiceReminderPromptShown`, and `review_requests`. Only `review_requests` is
  currently adopted into a live store; the other three are read-but-unused.
- **Attention/routing foundations:** `N/Domain/NativeBookingAttention.swift`
  (Phase 8), `N/NativeGlobalSearch.swift` (one-shot exact-detail routing),
  `N/NativeInteractionState.swift` (loading/empty/no-match/error states),
  `N/Domain/UIModelAdapters.swift`, `N/Domain/CanonicalSnapshot.swift`,
  `N/NativeSyncCoordinator.swift`, and `N/NativeBackgroundRefresh.swift`.
- **Phase 9 inputs:** the expense anomaly and tax snapshot block consume the
  canonical `expenses`/`trips`/`settings.taxIncomeRate`/
  `settings.vehicleDeductionMethod` produced by the Phase 9 plan
  ([native-phase-9-implementation-plan.md](native-phase-9-implementation-plan.md)).
  Where 9.0x is still in flight, Phase 10 reads only canonical arrays that already
  exist in `CanonicalSnapshot` and degrades to silence per the rules below.

Known gaps the integration lane must close (found in source review):

- `N/TodayView.swift` is a minimal prototype: no week strip/day selection, no
  stats row, no first-action hero, no setup checklist, no insights card, no
  lead/overdue briefing sections, no route-planning action, and no
  booking-attention row model (it renders a single summary button instead).
- `N/CoachView.swift` is a prototype: backend-only transport, a one-line system
  prompt, static prompts, no snapshot/snapshot prompt, no provider-key routing,
  no markdown-lite pass, no typed error bubble, no `MAX_HISTORY`/token limits, and
  no contextual prefill.
- No Swift equivalents of `utils/todayInsights.ts`, `utils/businessSnapshot.ts`,
  `utils/insightMutes.ts`, `utils/setupChecklist.ts`, or `utils/chatMarkdown.ts`.
- No insight-mute or setup-checklist live store; no
  `promptForInvoiceReminders` contextual ask; no `UNNotificationCategory`
  registration (grep: none).
- The background task does not reconcile notifications or refresh derived state
  after a pass, and there is no single post-sync-commit seam for derived outputs.
  (`estimateFollowUpNotificationScheduleKey` should cover only notification-selector
  inputs; Today/insight refresh is reactive through store publishing.)
- Analytics: the RN `insight_*` and `sample_job_opened` events have no native
  transport yet. Phase 10 emits them through a no-op `NativeAnalytics` seam;
  Phase 11.08 owns transport and parity.

## 2. Dependency graph and waves

```text
10.00 contract/characterization baseline
 |- 10.01 business snapshot (S1,S2) -----------+
 |- 10.02 today insights engine (S3) ----------+
 |- 10.03 device-local state stores (S4,D4) ---+-- 10.11 Today UI (D1-D6)
 |- 10.04 today selectors + routing (D1-D6) ---+     |- 10.12 checklist/hero/insights cards (D4,D5,S5)
 |                                                   |- 10.13 coach UI + prefill (C3,C4,C5)
 |- 10.10 coach transport + prompt (C1,C2,C4) --+-----+
 |
 |- 10.05 permission/categories/settings (N1) --> also feeds 10.12 (checklist notifications task)
 |- 10.06 due-date + auto-outreach (N2)
 |- 10.07 appointment + review parity (N3,N4)   (after 10.06 for shared-file serialization only)
 |- 10.08 unified reconciliation + routing (N5,N6,B2)
 |- 10.09 background refresh extension (B1,B2)
10.05-10.09 -- 10.14 qualification -- 10.15 closeout
10.11-10.13 -- 10.14
```

The diagram expresses interface dependencies, not a requirement to wait for
every pure engine before useful integration. 10.11 can build the schedule/stats/
attention skeleton against 10.04 while 10.01–10.03 are still in flight; it is
closed only after 10.12 and 10.13 land. 10.05 (permission/settings) can start
immediately because the coordinator and families already exist; 10.08 is the
serialization point that proves the whole set.

Recommended waves:

1. **10.00.** Freeze interfaces and characterize gaps. Start parity/duplication
   probes here, not at closeout.
2. **Parallel 10.01 / 10.02 / 10.03 / 10.04 / 10.10** and the notification lane
   **10.05 → 10.06 → 10.07 → 10.08**, then **10.09**.
3. **Integration lane 10.11 → 10.12 → 10.13**.
4. **10.14 → 10.15.**

## 3. Task packets

### 10.00 — Freeze contracts and characterize gaps

**Depends on:** none. **Owner:** coordinating agent/design subagent.
**Requirements:** all (characterization only).

Read roadmap Phase 10, the parity rows, the RN sources and tests listed per task
below, and the existing Swift files above. Record current behavior in fixtures
without changing implementation. Create
`docs/native-phase-10-today-coach-notifications-contract-decisions.md` with:

- **Today selection semantics:** the exact day/week strip math
  (`getWeekDates`/`todayString`/`shiftDate`), per-day schedule sort with
  unscheduled-last, the `INVOICE_LIMIT`/`LEAD_LIMIT` caps and see-more counts, the
  "due today is not overdue" rule, and the earnings value definition for the day.
- **Attention model:** the full `selectBookingAttention` vs native
  `NativeBookingAttention` delta (native adds `missingJob`/`unconvertedActive`),
  the portal-change `handledAt` dismissal, and the exact row labels/rank order so
  the Today list and the alert copy match.
- **Insight contract:** each of the eight kinds with its constants
  (`OVERRUN_MIN_HOURS`, `MARGIN_TOLERANCE_PTS`, `DUE_SOON_DAYS`,
  `MIN_GAP_MINUTES`, `MAINTENANCE_DUE_MONTHS`, `EXPENSE_ANOMALY_MULT`/`_MIN_MTD`),
  its stable `id` shape, priority order, `reason`/`coachPrompt` text, and every
  exclusion. Confirm the top-three slice runs *after* mute filtering.
- **Mute lifecycle:** `makeMute`/`isMuteActive`/`filterMutedInsights`/`pruneMutes`
  semantics, local-frame dates, and that mutes are device-local and unsynced but
  must be wiped at every account boundary.
- **Setup contract:** `deriveSetupTasks` per task, the `done`/`dismissed`/
  `sampleTourDone` fields, the exact `SETTINGS_ROUTE_FOR_TASK` destinations, and
  the shared `isSetupComplete` gate the insights card reads.
- **Snapshot contract:** `aggregateSnapshot` fields and month-window bucketing,
  `buildTaxSnapshotBlock` mapping, and the `avgCompletedJobValue` definition
  (billable total incl. approved change orders, done jobs only, 0 when none).
- **Coach contract:** `buildSystemPrompt` exact wording and included/excluded
  data, provider precedence (`anthropicKey` → `groqKey` → backend), `MAX_HISTORY`
  (20) and `max_tokens` (600), the `api/ai-chat` request/response shape, and the
  privacy rule that secure keys never enter a prompt.
- **Markdown-lite contract:** `formatChatText` rules with the deliberately
  preserved cases (`2*4 and 2*6`, spaced math, `snake_case`), so Swift reproduces
  them byte-for-byte.
- **Notification contract:** the five identifier namespaces and their exact
  identifier formats, the fire-date construction for each family (local-frame
  9:00 a.m. patterns), the dunning exclusions (paid, missing/malformed due,
  imported `importBatchId`, pre-completion deposit), the auto-outreach body
  switch, the review one-shot rebuild rule, and the shared 60 cap with foreign
  families consuming budget first.
- **Duplicate-prevention contract:** what "across app launches" means for each
  path — coordinator cancel-owned-then-reschedule, review one-shot record guard,
  and review-notification rebuild from pending records.
- **Parity oracle index:** the exact `__tests__` files that nail each requirement
  and a per-row source map for the parity matrix rows this phase owns.

**Deliver:** contract decision table (chosen/blocked with reason), fixture index,
and a native interface/type handoff for independent work.

**Done when:** every task has an exact contract or a named blocker; existing
oracle behavior and any proposed intentional native difference are distinguished.
Tests expose mute-expiry ordering, top-three-after-mute, the portal-change
dismissal, unknown/blank settings in the snapshot, provider fallback, and the
shared-cap foreign-family case.

### 10.01 — Business snapshot engine

**Depends on:** 10.00 S1/S2 contract. **Requirements:** S1, S2 (pure).

**Read:** `utils/businessSnapshot.ts`, `utils/customerList.ts`,
`utils/invoiceStats.ts`, `utils/invoicePayments.ts` (`collectedByPeriod`,
`balanceDue`), `utils/taxEstimate.ts` (`summarizeTaxWindow`,
`formatPeriodRange`, `formatDeadline`), `utils/changeOrders.ts`
(`jobBillableTotal`); `__tests__/businessSnapshot.test.js`,
`__tests__/estimateSnapshot.test.js`; `N/Domain/CanonicalSnapshot.swift`,
`N/Domain/CanonicalModels.swift` (`Settings`, `Job`, `Invoice`, `Expense`, `Trip`),
`N/Domain/FinancialDomain.swift` (`PaymentLedger`, `TaxEstimateEngine`),
`N/NativeCustomerIdentity.swift` (customer rollup), `N/Domain/UIModelAdapters.swift`.

**Own:** new `N/Domain/NativeBusinessSnapshot.swift`;
`native/BusinessSnapshotTests/main.swift` and a focused runner. Do not edit
`FinancialDomain.swift` unless the coordinator extracts a shared predicate first.

1. Port `aggregateSnapshot` as a pure function over canonical arrays with an
   injectable `now`: `revenueThisMonth`/`revenueLastMonth` from
   `collectedByPeriod` month windows, `outstandingTotal`, `overdueTotal`/
   `overdueCount`, `activeJobsByStatus`, `totalCustomers`, top-5 customers, and
   `avgCompletedJobValue` (mean billable total over done jobs with a positive
   total; 0 when none).
2. Port `buildTaxSnapshotBlock` as a thin projection over the existing
   `TaxEstimateEngine.summarize` inputs, preserving `incomeRateSet`,
   `needsVehicleChoice`, and `ratesKnown` (unknown year → latest known base,
   `ratesKnown: false`).
3. Reuse the Phase 5 `NativeCustomerIdentity` rollup for `topCustomers`/`total`;
   do not fork the lifetime-spend/owed math.
4. Emit a `NativeBusinessSnapshot` value with `asOf` and an optional tax block
   that is absent (not zeroed) when inputs fail to load, exactly as RN leaves
   `tax` undefined.

**Done when:** empty/zero collections, month-boundary month math (Jan rollover),
partial-payment dual counting (revenue and outstanding at once), voided-payment
exclusion, overpayment, imported/open-due invoices, done-job averaging with a
zero-total job, and unknown-tax-settings vectors match the RN fixtures exactly.
Snapshotting performs no mutation.

### 10.02 — Proactive insights engine

**Depends on:** 10.00 S3 contract. **Requirements:** S3 (pure).

**Read:** `utils/todayInsights.ts`, `utils/scheduleSmarts.ts`,
`utils/timeTracking.ts`, `utils/pricingEngine.ts` (`computeEstimateBreakdown`),
`utils/calendar.ts` (`selectUnscheduledApproved`), `utils/scheduleConfig.ts`
(`resolveSchedule`, `isWorkDay`, `isBlackoutDate`), `utils/invoicePayments.ts`,
`utils/invoiceHelpers.ts` (`daysPastDue`), `utils/moneyUtils.ts`
(`EXPENSE_CATEGORIES`), `utils/recurrence.ts` (`formatLocalDate`),
`utils/dateHelpers.ts` (`shiftDate`), `utils/changeOrders.ts` (`jobBillableTotal`);
`__tests__/todayInsights.test.ts`; existing `N/Domain/NativeCalendar.swift`,
`N/Domain/NativeSchedule.swift`, `N/Domain/NativeAvailability.swift`,
`N/Domain/FinancialDomain.swift` (`PricingEngine`), `N/NativeTimeTracking.swift`.

**Own:** new `N/Domain/NativeTodayInsights.swift`;
`native/TodayInsightsTests/main.swift` and runner. No view, store, or
notification edits here.

1. Define `NativeTodayInsight` with `kind`, `id`, `title`, optional `detail`, a
   typed `target` enum mirroring `InsightTarget`, `reason`, and optional
   `coachPrompt`. Keep the exact `id` shapes (`kind:recordId`, `kind:all`,
   `kind:date`/`kind:period`) and the low-margin id embedding `estimateTotal`.
2. Port all eight selectors in the documented order: (1) labor overrun, (2)
   low-margin estimate, (3) uninvoiced complete, (4) due soon, (5) open slot,
   (6) unscheduled approved (excluding the job `open_slot` already offered),
   (7) maintenance due, (8) expense anomaly — preserving each constant, exclusion
   (archived, status sets, zero-input guards), and the "one row + count" collapse.
3. Reuse existing pure engines: `computeTimeTracking` (native time tracking),
   `PricingEngine` breakdown for low margin, the calendar/availability selectors
   for the open slot, and local-frame string month math (never Date-parsing
   `YYYY-MM-DD`) for maintenance/anomaly.
4. Keep inputs optional exactly as RN: absent customers/recurring/expenses simply
   suppress those rules rather than guessing.

**Done when:** each kind's trigger boundary (over/under the constant), aggregate
vs single-row collapse and ordering, archive/status exclusions, the "due today is
not overdue" due-soon window, blacked-out/non-workday tomorrow, expenses with
fewer than three non-zero prior months, and the exact `reason`/`coachPrompt` text
fixtures match the RN oracle. The engine is pure and never mutates.

### 10.03 — Device-local owner-bound state stores

**Depends on:** 10.00 D4/S4 contract. **Requirements:** S4, D4 (state), D5
(state).

**Read:** `utils/insightMutes.ts`, `utils/setupChecklist.ts`,
`utils/storage/lifecycle.ts`, `utils/storage/keys.ts`,
`__tests__/insightMutes.test.ts`, `__tests__/setupChecklist.test.js`;
`N/NativeReviewRequestStore.swift` (the exact-owner store pattern to mirror),
`N/NativeTypedAccountState.swift` (`InsightMute`, `SetupChecklistState`,
`invoiceReminderPromptShown` seeds), `N/NativeAuxiliaryStateActivation.swift`,
`N/AppStore.swift` (account-boundary scrub).

**Own:** new `N/Domain/NativeInsightMutes.swift`,
`N/NativeInsightMuteStore.swift`, `N/Domain/NativeSetupChecklist.swift`,
`N/NativeSetupChecklistStore.swift`;
`native/InsightMuteTests/main.swift`, `native/SetupChecklistTests/main.swift` and
runners. Return adoption/seeding and scrub hooks as an integration contract; do
not edit `AppStore.swift` or `TodayView.swift` here.

1. Port the mute policy (`makeMute`, `isMuteActive`, `filterMutedInsights`,
   `pruneMutes`) with local-frame `until` dates and injectable `now`.
2. Port the checklist policy (`deriveSetupTasks`, `isSetupComplete`, the
   `done`/`dismissed`/`sampleTourDone` fields, and the provider-configured
   alternative for the `stripe` task).
3. Implement both as exact-owner-bound, versioned, atomic-write stores with a
   last-known-good backup and fail-closed unreadable/mismatch handling, mirroring
   `NativeReviewRequestStore`. Adopt the migrated `insightMutes`,
   `setupChecklistState`, and `invoiceReminderPromptShown` seeds once on
   activation with existing owner records winning; adopt `sampleTourDone` from
   the same seed.
4. Model the one-shot invoice-reminder prompt flag as its own owner-bound value so
   a stale flag cannot leak across accounts.

**Done when:** permanent dismiss vs snooze expiry, prune-expired, prune
against-live-ids, order-preserving filter, checklist derivation for every task,
dismissal, sample-tour idempotence, seed adoption with existing owner records
winning, unknown/absent fields preserved, atomic-write + backup recovery, and
exact-owner rejection of a mismatched binding all pass.

### 10.04 — Today selectors, stats, and routing contract

**Depends on:** 10.00 D1/D2/D3/D6 contract. **Requirements:** D1, D2, D3, D6
(pure).

**Read:** `screens/TodayScreen.tsx` (week strip, stats row, hero, sections,
greeting header, `handleInsightNavigate`, `handleBookingRowPress`),
`utils/dateHelpers.ts`, `utils/scheduleSmarts.ts`, `utils/invoiceHelpers.ts`,
`utils/jobStatus.ts`, `utils/estimateFollowUps.ts` (`selectAwaitingFollowUp`,
`awaitingResponseLabel`); `__tests__/TodayScreenSettingsGear.test.tsx`,
`__tests__/crossTabNavigation.test.tsx`; `N/Domain/NativeBookingAttention.swift`,
`N/NativeGlobalSearch.swift` (routing/one-shot request patterns),
`N/NativeInteractionState.swift`, `N/Domain/CanonicalSnapshot.swift`.

**Own:** new `N/Domain/NativeTodayBriefing.swift`;
`native/TodayBriefingTests/main.swift` and runner. This is the pure projection the
UI renders; no `TodayView.swift` edits here.

1. Port the week-strip derivation (`getWeekDates`, `todayString`, prev/next week),
   the per-day schedule filter/sort with unscheduled-last, and the earnings value
   for the selected day.
2. Port the stats row inputs (earnings, overdue total/count, lead count) and the
   overdue/follow-up section caps (`INVOICE_LIMIT`, `LEAD_LIMIT`) with exact
   see-more remainder counts and row ordering.
2a. Port the "estimates awaiting response" row (`selectAwaitingFollowUp` +
   `awaitingResponseLabel`, gated on the follow-up toggle, `FOLLOW_UP_DAYS`
   boundary) and the header projection (greeting cutoffs `< 12:00` morning,
   `< 17:00` afternoon, else evening; `formatDisplayDate(todayString)`), both
   with an injectable clock.
3. Define a typed `NativeTodayDestination` covering every insight target *and*
   every contextual action (job detail, create-invoice, invoice, invoices, jobs,
   schedule-with-focus, select-date, customer, customers, money, calendar,
   search, settings, route, on-my-way), plus the first-action hero destination.
   Reuse the existing one-shot exact-ID routing pattern (verify local ID, change
   tab, install a single-use request; fail closed on missing/archived).
4. Carry the booking-attention row model through unchanged (reuse
   `NativeBookingAttention.select`), including the native-only `missingJob`/
   `unconvertedActive` rows and their labels.

**Done when:** day/week edge cases (DST, week boundary, day with no jobs), cap
boundaries at exactly the limit and one over, ordering, the awaiting-estimate
boundary and toggle gate, greeting cutoffs at 11:59/12:00 and 16:59/17:00, hero derivation
(sample vs fresh, `sampleTourDone`), and every destination mapping fixture pass.
The projection is pure and performs no routing side effects itself.

### 10.05 — Notification permission, categories, and settings surface

**Depends on:** 10.00 N1 contract. **Requirements:** N1.

**Read:** `utils/notifications.ts`
(`setupNotifications`, `requestPermissions`, `promptForInvoiceReminders`),
`utils/storage/keys.ts` (`REMINDER_PROMPT_KEY`),
`screens/SettingsNotificationsScreen.tsx`, `screens/SettingsReviewsScreen.tsx`,
`__tests__/settingsNotificationsScreen.test.tsx`, `__tests__/notifications.test.js`;
`N/NativeEstimateFollowUpNotifications.swift` (coordinator/permission state),
`N/SettingsView.swift` (`NotificationSettings`, `ReviewSettings`),
`N/AppStore.swift`, `N/TradeReadyNativeApp.swift` (delegate install).

**Own:** shared notification-lane edits to `N/SettingsView.swift`,
`N/NativeEstimateFollowUpNotifications.swift` (category registration + prompt
state as needed), `N/AppStore.swift`, `N/TradeReadyNativeApp.swift`; new
`N/NativeNotificationCategories.swift`; `native/NotificationPermissionTests/main.swift`
and runner. Treat the existing schedule-key and coordinator contracts as frozen.

1. Register `UNNotificationCategory` per family at launch (a real
   `setNotificationCategories` call — none exists today), keyed to the same
   payload types the routes already decode. Categories must not add destructive
   actions that send to customers.
2. Implement the one-shot contextual invoice-reminder prompt exactly like RN:
   stamp the owner-bound flag before showing, ask at most once, silent when OS
   permission is already settled, and trigger `synchronize()` on grant.
3. Give the settings surface truthful per-family controls and permission state
   (overdue reminders + auto-outreach, appointment reminders, review requests)
   bound to the shared coordinator rather than the follow-up coordinator alone;
   preserve existing toggle semantics (`estimateFollowUpsEnabled` default-on,
   `appointmentRemindersEnabled` default-off, `reviewRequestEnabled` gate).
4. Keep secure provider keys out of any notification path.

**Done when:** categories register once and survive relaunch; the contextual
prompt fires at most once and only when undetermined; grant triggers a
synchronize; each toggle maps to its selector's enabled flag; sign-out clears the
owner-bound prompt flag. Platform permission proof stays deferred to Phase 12.

### 10.06 — Due-date reminders and the auto-outreach variant

**Depends on:** 10.05 N1. **Requirements:** N2.

**Read:** `utils/notifications.ts` (`inv_` branch), `utils/invoicePayments.ts`,
`utils/jobStatus.ts` (`isJobDunningEligible`), `utils/moneyUtils.ts`
(`parseLocalDate`), `backend-workers/lib/selectInvoicesToRemind.js`,
`backend-workers/lib/reminderEmail.js`, `__tests__/notifications.test.js`,
`__tests__/reminderLogic.test.js`, `__tests__/reminderEmailHardening.test.js`;
`N/Domain/NativeInvoiceNotifications.swift`,
`N/AppStore.swift#invoiceReminderNotifications`,
`N/NativeEstimateFollowUpNotifications.swift` (`scheduleInvoiceItem`).

**Own:** notification-lane edits to `N/AppStore.swift` /
`N/Domain/NativeInvoiceNotifications.swift`; `native/InvoiceNotificationTests`
extensions and runner. Keep the pure selector and identifier scheme; change only
what parity requires.

1. Audit the existing `inv_` selector/plan against the frozen contract and close
   any divergence: paid, blank/malformed due, imported `importBatchId`,
   pre-completion deposit suppression, rule-day ordering, and the shared 60 cap.
2. Confirm the auto-outreach body/title/`overdue_outreach` payload switch and the
   tap→outreach-review routing are complete for the native record, and that no
   path auto-sends a customer reminder.
3. Verify the local-frame 9:00 a.m. fire-date construction cannot drift from the
   `rinv_` branch.

**Done when:** identifiers, fire dates, counts, excluded sets, and both body
variants match the RN fixtures; imported invoices never schedule; the tap route
resolves only a still-relevant exact-owner invoice and fails closed otherwise.

### 10.07 — Appointment and review-request parity

**Depends on:** 10.05 (interface); 10.06 for shared-file serialization only — no
interface from 10.06 is consumed. **Requirements:** N3, N4.

**Read:** `utils/appointmentMessages.ts`, `utils/appointmentSend.ts`,
`utils/appointmentTemplates.ts`, `utils/reviewRequest.ts`,
`utils/notifications.ts` (`appt_`/`review_` branches),
`__tests__/notifications.test.js`, `__tests__/reviewRequest.test.js`,
`__tests__/ReviewRequestScreen.test.tsx`;
`N/NativeAppointmentNotifications.swift`, `N/NativeReviewRequests.swift`,
`N/NativeReviewRequestStore.swift`, `N/NativeReviewRequestView.swift`,
`N/AppStore.swift` (`appointmentConfirmationNotifications`,
`reviewRequestNotifications`, review completion hook).

**Own:** notification-lane edits to `N/AppStore.swift` and the two families'
selectors beyond 10.06's file; `native/AppointmentNotificationTests`,
`native/ReviewRequestTests` extensions and runners.

1. Appointment: confirm active-status set, contact requirement, day-before 5:00
   p.m. local fire date, stable soonest-first ordering, and that a notification
   tap opens an editable confirmation that never auto-sends.
2. Review: confirm the transition-into-`complete` one-shot with the toggle,
   reachable contact, no-existing-record guard, `max(1, delayHours || 3)`
   delay, live-customer-preferred draft with saved-record fallback, `sent`
   cancel-non-blocking, and — critically — the sweep's rebuild of pending
   `review_` one-shots from records so a sweep inside the delay window cannot eat
   the nudge permanently.
3. Add the parity test proving a sweep between arming and firing preserves the
   one-shot (B2 dependency preview).

**Done when:** every `appt_`/`review_` fixture matches RN, the one-shot guard holds
across a simulated relaunch and a mid-window sweep, and no path sends
automatically.

### 10.08 — Unified notification reconciliation and tap routing

**Depends on:** 10.05–10.07. **Requirements:** N5, N6, B2.

**Read:** `utils/notifications.ts` (whole sweep + ordering), all five native
families, `N/NativeEstimateFollowUpNotifications.swift`
(`synchronizeOnce`, `notificationItems`, `ownedPrefixes`, route decode),
`N/AppStore.swift#estimateFollowUpNotificationScheduleKey`,
`N/TradeReadyNativeApp.swift#openOwnedRoute`, `N/NativeDeepLinkParser.swift`;
`native/run-notification-coordinator-tests.sh`.

**Own:** notification-lane edits across the coordinator, the schedule key, and the
delegate; `native/NotificationCoordinatorTests` extensions and runner. Keep every
identifier scheme and the foreign-family rule.

1. Confirm the single coordinator reconciles all five owned families with the
   documented priority, per-namespace stale cleanup before the authorization
   guard, and foreign families consuming cap budget first (never removed).
2. Audit the schedule key so every input of the five notification selectors
   (plus their enable toggles and permission state) re-triggers `synchronize()`,
   and nothing else does. Insight mutes, setup-checklist state, and expenses do
   not alter any scheduled item and must **not** be folded in (they would only
   cause redundant reconciles); Today/insight refresh is reactive through store
   publishing, not the schedule key.
3. Prove idempotent duplicate prevention: two consecutive reconciles 1 s apart
   produce the same pending set with no double-scheduling, and a reconcile after
   a simulated relaunch does not duplicate or drop a family.
4. Audit every route's tap decode → exact-owner record resolution → fail-closed
   missing/archived/wrong-owner handling for `est_`, `appt_`, `review_`, `inv_`,
   `rinv_`.

**Done when:** the aggregate coordinator suite proves priority, the cap with
foreign families present, per-family cleanup on toggle/account changes, no
duplicate scheduling across launches, and correct/fail-closed routing for all
five payload types.

### 10.09 — Background refresh completion for Today and scheduling

**Depends on:** 10.01 (snapshot to cache), 10.08 (coordinator). 10.02–10.04 are
not inputs: Today/insights are render-time only. **Requirements:** B1, B2.

**Read:** `utils/backgroundRefresh.ts`, `N/NativeBackgroundRefresh.swift`,
`N/NativeSyncCoordinator.swift`, `N/NativeInitialSync.swift`,
`docs/native-phase-4-background-refresh.md`; `native/run-background-refresh-tests.sh`,
`native/run-sync-coordinator-tests.sh`.

**Own:** `N/NativeBackgroundRefresh.swift` and the AppStore background-work hook;
new `N/NativeDerivedStatePublisher.swift` (the single post-sync-commit seam);
`native/BackgroundRefreshTests` extensions and runner. Reuse the Phase 4
serialized push/pull pass; do not add a second sync path.

1. Add one post-commit seam, invoked after a real (non-`.alreadyRunning`) sync
   pass commits (foreground or background), that republishes every derived
   output from the committed canonical snapshot — never from stale in-memory
   collections. Its concrete outputs are:
   (a) notification reconciliation through the 10.08 coordinator;
   (b) a registration point for the Phase 11 widget mirror (11.01 plugs in; no
       widget code here);
   (c) a refreshed cached `NativeBusinessSnapshot` (10.01) for coach cold start.
   Today and insights are computed at render time and are not a background
   output. Each output is independently failure-isolated.
2. Preserve the existing guarantees: exact-owner cold-launch gating,
   signed-out/offline no-op, expiration cancellation with exactly-once
   completion, and 30-minute-earliest rescheduling.
3. Guarantee fail-safety: a failed/partial pass must leave the last good pending
   set intact (or, if it re-reconciles, reconcile to a correct set from the
   retained canonical snapshot) and never double-schedule.

**Done when:** simulated background passes (success, offline, signed-out,
failed table, expiration mid-pass) invoke the seam exactly once per committed
pass (never on `.alreadyRunning`, offline, or signed-out), reconcile
notifications with no duplicates, refresh the cached snapshot, call a registered
test observer with the committed snapshot, leave the prior outputs intact when
one output fails, complete an expiration exactly once, and write no business
data outside the existing sync commit. Physical-device delivery
evidence stays deferred to Phase 12 with runsheet rows created here.

### 10.10 — Coach transport, provider routing, and system prompt

**Depends on:** 10.00 C1/C2 contract and 10.01 (snapshot). **Requirements:** C1,
C2, C3 (quick-prompt policy), C4 (transport + markdown-lite policy).

**Read:** `utils/aiService.ts`, `utils/oneShotAI.ts`, `utils/anthropicMessage.ts`,
`utils/businessSnapshot.ts`, `utils/chatMarkdown.ts`,
`screens/ChatScreen.tsx#buildSystemPrompt` and `#getQuickPrompts`,
`backend-workers/src/routes/aiChat.js` (the live `/api/ai-chat` route, wired in
`backend-workers/src/index.js`; `backend/api/ai-chat.js` is the legacy Vercel
proxy and is not the contract), `__tests__/chatMarkdown.test.ts`,
`__tests__/estimateSnapshot.test.js`;
`N/Domain/CanonicalModels.swift` (`Settings.anthropicKey`, `.groqKey`),
`N/NativeEstimateDelivery.swift` (injected transport/auth-refresh pattern),
`N/BuildEnvironment.swift`, `N/NativeTypedAccountState.swift` (secure-key
handling), `N/Domain/NativeBusinessSnapshot.swift` (10.01).

**Own:** new `N/NativeCoachTransport.swift`,
`N/Domain/NativeCoachPrompt.swift`, `N/Domain/NativeChatMarkdown.swift`,
`N/Domain/NativeCoachQuickPrompts.swift`; `native/CoachTransportTests/main.swift`,
`native/CoachPromptTests/main.swift`, `native/ChatMarkdownTests/main.swift` and
runners. Provide a `CoachService` replacement contract for 10.13; do not edit
`CoachView.swift` here. Define each provider model id (`claude-sonnet-4-6`,
`llama-3.1-8b-instant`) as a single named constant so a later model change is a
one-line, separately reviewed edit.

1. Port provider precedence and the three transports: user Anthropic key
   (`/v1/messages`, `x-api-key`, `anthropic-version`), user Groq key
   (`api.groq.com`, `max_tokens` 600), and the authenticated backend proxy
   (`/api/ai-chat` with the bearer session, `{ messages:[{role,text}], systemPrompt }`,
   response `text`). Enforce the `MAX_HISTORY` 20-message window and per-provider
   failure typing.
2. Build `NativeCoachPrompt` from the canonical snapshot exactly like
   `buildSystemPrompt`, including the rates line, the business-data block, the
   active-jobs/top-customers/overdue lines, and the tax block with its
   "set-aside guidance only, refer filing questions to a professional" caveat.
   Secure keys are never interpolated into a prompt.
3. Never throw on a one-shot generator path where RN does not; return a typed
   result that the UI renders as an error bubble or fallback.
4. Port `formatChatText` as a pure transform in `NativeChatMarkdown`, in the
   contract §8 order, byte-for-byte (including the preserved `2*4 and 2*6`,
   spaced-math, and `snake_case` cases).
5. Port `getQuickPrompts(snapshot)` as a pure function in
   `NativeCoachQuickPrompts`, with the overdue and avg-job branches and the
   no-snapshot fallback.

**Done when:** provider-precedence, missing-key messages, history truncation,
backend auth-missing, unparseable/empty responses, the exact system-prompt
fixtures (including a keyless snapshot and a tax-unknown snapshot), every
`chatMarkdown.test.ts` vector, and each quick-prompt branch match RN.
The prompt contains only intended business context and no secrets.

### 10.11 — Today UI integration

**Depends on:** 10.04 plus integration-lane availability (normally after 10.01–
10.03). **Requirements:** D1, D2, D3, D6 (display).

**Own:** rewrite `N/TodayView.swift`; new `N/NativeTodayComponents.swift`
(week strip, stats row, section, rows) and the first-action hero; serialized
edits to `N/AppStore.swift` (selected-day/one-shot destination state) and
`N/RootView.swift` (tab routing) through the integration lane.

1. Render the week strip with day selection and prev/next week, the
   3-stat summary row (earnings/overdue/leads with their tap destinations),
   the first-action hero, the setup-checklist slot, the insights slot, the
   booking-attention rows (with their alert actions and portal-change dismissal),
   the overdue and follow-up briefing sections with caps/see-more, the
   awaiting-estimate row, and the selected-day schedule with its "Plan Route" and
   empty-schedule actions.
2. Route every row/insight/action through the typed `NativeTodayDestination`
   from 10.04 using the existing one-shot exact-ID pattern; verify the local ID
   and fail closed on missing/archived records.
3. Reuse `NativeInteractionState` for loading/empty/no-match/error presentation
   and await the real sync pass on pull-to-refresh (no early success when the
   coordinator reports `.alreadyRunning`).
4. Preserve the exact accessibility labels/hints from RN so later VoiceOver work
   has a stable baseline.

**Done when:** the screen matches RN section-for-section for populated, empty,
loading, and error inputs; every cap/see-more, contextual action, and hero state
works; no row is a placeholder. UI compiles; device layout proof stays deferred.

### 10.12 — Setup checklist, hero, and insights cards

**Depends on:** 10.02, 10.03, 10.05 (permission prompt + `synchronize()` for the
checklist's `notifications` task), 10.11. **Requirements:** D4, D5, S5.

**Own:** new `N/NativeSetupChecklistCard.swift`, `N/NativeInsightsCard.swift`;
serialized `N/TodayView.swift`/`N/SettingsView.swift`/`N/AppStore.swift` wiring
for checklist state, dismissal, and settings destinations.

1. Setup checklist: derive tasks from 10.03, show them with their subtitles,
   record `done`/`dismissed` through the owner-bound store, navigate to the exact
   `SETTINGS_ROUTE_FOR_TASK` destination, and hide via the shared
   `isSetupComplete` gate. The `notifications` task is handled in-card through
   the 10.05 permission API: request; on grant mark granted and `synchronize()`;
   on refusal offer "Open device settings".
2. Insights card: render the top three of the (mute-filtered) engine output,
   gate behind `isSetupComplete` and the "no hero" condition (contract §3.1,
   `TodayScreen.tsx` renders `InsightsCard` only when `!loading && !hero`), and provide
   dismiss/snooze affordances for muteable kinds only; unmuteable/self-resolving
   kinds show no dismiss control. Preserve the exact title/detail/reason copy.
3. Contextual actions: an insight's target routes through 10.04; its
   `coachPrompt` opens the coach with an editable prefill (10.13) and never
   auto-sends.
4. Persist mutes/dismissals optimistically through 10.03 and reconcile on next
   read; scrub at every account boundary.
5. Fail-closed store behavior (a recorded native difference: RN degrades to
   `[]`): when the mute store is unreadable, render only the five non-muteable
   (self-resolving) kinds — never an unfiltered list that would resurrect
   dismissed rows — and hide dismiss/snooze controls; when the checklist store is
   unreadable, keep the checklist hidden and treat setup as incomplete only for
   gating the insights card. Log one bounded, non-PII diagnostic per session.
6. Analytics: emit `insight_shown` (once per distinct visible id set),
   `insight_tapped`, `insight_coach_opened`, `insight_reason_viewed`,
   `insight_snoozed`, `insight_dismissed`, and `sample_job_opened` through a
   no-op `NativeAnalytics` seam. Phase 11.08 owns the transport and payload
   parity; do not build a transport here.

**Done when:** top-three-after-mute, gate ordering (hero suppresses insights,
checklist completion reveals them), dismiss vs snooze expiry, per-kind mute
availability, fail-closed mute/checklist rendering, analytics seam calls, and
every checklist destination fixture pass. UI compiles.

### 10.13 — Coach UI and contextual prefill

**Depends on:** 10.10, 10.12. **Requirements:** C3, C4 (UI), C5.

**Own:** rewrite `N/CoachView.swift`; new `N/NativeCoachComponents.swift`
(quick-prompt grid, message bubble, typing/error states); serialized
`N/AppStore.swift`/`N/RootView.swift` prefill wiring.

1. Port the transcript UI: newest-first list, user vs assistant bubbles,
   typing indicator, `MAX_HISTORY`-windowed sends, and "New chat" only when a
   transcript exists.
2. Render assistant replies through 10.10's `NativeChatMarkdown` (no transform
   logic in the view); user text stays verbatim. Long-press copies the rendered
   text.
3. Render 10.10's `NativeCoachQuickPrompts` output (no branch logic in the view),
   driven by 10.01's snapshot, with correct empty-state behavior.
4. Contextual prefill: accept an insight `coachPrompt`, fill the input once,
   clear the pending request so it cannot re-fire, pass
   `source: insight_prefill` to the no-op `NativeAnalytics` seam (Phase 11.08
   owns transport), and never auto-send.
5. Render typed errors as a distinct error bubble (using the provider's message)
   and enforce the usage limits (input length, 600-token backend cap behavior).

**Done when:** provider routing, quick-prompt branch selection, markdown-lite
fixtures, prefill-fill-and-clear, error-bubble typing, copy, and new-chat states
all pass. UI compiles; live-provider proof stays deferred (an unavailable live AI
endpoint is a dependency, not a passing test).

### 10.14 — Cross-client and hosted-contract qualification

**Depends on:** 10.01–10.13. **Requirements:** all.

**Own:** focused integration fixtures/tests and evidence appended to
`docs/native-phase-10-today-coach-notifications-contract-decisions.md`; no
opportunistic UI rewrite.

Exercise RN-to-Swift equivalence (same canonical input → same output) for: the
business snapshot and tax block, every insight kind and its mute policy, the
setup checklist derivation, the coach system prompt, quick prompts and
markdown-lite output, and the full notification selection/tap-routing set.
Two-way (Swift-to-RN) checks apply only to synced canonical data the RN client
also reads; the device-local stores (`insightMutes`, `setupChecklistState`,
`invoiceReminderPromptShown`) are one-way seed imports and are verified only as
RN-seed → native adoption. Run the real RN oracles listed in section 4 after any
compatibility change. Add a deterministic daily-surface fixture (same canonical
input → same insights, snapshot, checklist, and scheduled set) and an
idempotent-scheduling proof (reconcile twice, identical pending set).

**Done when:** host/model tests pass, every source-discovered gap has implemented
coverage or a named blocker, and remaining device/permission/live-AI/hosted proof
is explicitly deferred to Phase 12.

### 10.15 — Aggregate verification and evidence closeout

**Depends on:** 10.14.

Register new focused runners in `native/run-all-domain-tests.sh`, verify Xcode
target membership, run the aggregate suite and the unsigned generic-iPhone
Release build (§4), and — where a signing identity is available — the signed
build (same command without `CODE_SIGNING_ALLOWED=NO`). Record results; if no
signing identity is available, record the signed build as deferred to Phase 12,
not as passed. Create `docs/native-phase-10-device-runsheet.md` from
the parity rows (Today, Setup checklist, Proactive insights, AI coach, Quick
prompts, Insight handoff, Notifications, Background refresh, Deep links); link it
into the consolidated Phase 12 checklist. Update the roadmap and parity matrix
with completed code versus deferred evidence, never a blanket "Verified". Record
signed and unsigned build results separately and preserve any unresolved
implementation gate.

**Done when:** each requirement has code/test/evidence references; every row,
button, prompt, and notification is real; no dependency is silently waived;
device/staging rows have steps, expected result, environment/build, and evidence
placeholders. No deployment or App Store cutover is part of this task.

## 4. Verification commands

Run from repository root. The following RN oracle commands exist today; new
focused Swift runners must be created by their task before being invoked. Use only
relevant oracles per task; run the full aggregate at integration closeout. Always
set `TZ=America/Phoenix` (a west-of-UTC zone) so the FA-039 local-date
regressions surface; a UTC machine hides them.

```sh
# Today surface, insights, snapshot, checklist, mutes, and cross-tab routing
TZ=America/Phoenix npm test -- --runInBand --runTestsByPath __tests__/todayInsights.test.ts __tests__/businessSnapshot.test.js __tests__/insightMutes.test.ts __tests__/setupChecklist.test.js __tests__/bookingAttention.test.ts __tests__/bookingNotify.test.js __tests__/TodayScreenSettingsGear.test.tsx __tests__/crossTabNavigation.test.tsx

# Coach
TZ=America/Phoenix npm test -- --runInBand --runTestsByPath __tests__/chatMarkdown.test.ts __tests__/estimateSnapshot.test.js __tests__/settingsNotificationsScreen.test.tsx

# Notifications, reminders, and review requests
TZ=America/Phoenix npm test -- --runInBand --runTestsByPath __tests__/notifications.test.js __tests__/reminderLogic.test.js __tests__/reminderEmailHardening.test.js __tests__/reviewRequest.test.js __tests__/ReviewRequestScreen.test.tsx

# Phase 10 runners created so far (10.01, 10.03)
TZ=America/Phoenix sh native/run-business-snapshot-tests.sh
TZ=America/Phoenix sh native/run-insight-mute-tests.sh
TZ=America/Phoenix sh native/run-setup-checklist-tests.sh

# Existing native foundations
sh native/run-notification-coordinator-tests.sh
sh native/run-estimate-follow-up-notification-tests.sh
sh native/run-appointment-notification-tests.sh
sh native/run-invoice-notification-tests.sh
sh native/run-review-request-tests.sh
sh native/run-background-refresh-tests.sh
sh native/run-booking-attention-tests.sh
sh native/run-global-search-tests.sh
sh native/run-interaction-state-tests.sh
sh native/run-store-integration-tests.sh

# Integration closeout
sh native/run-all-domain-tests.sh
xcodebuild -project native/TradeReadyNative.xcodeproj -scheme TradeReadyNative -configuration Release -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

For RN edits, run `npm run typecheck` plus the affected screen tests. Backend
tasks must run the existing `backend-workers` test/build commands appropriate to
the `ai-chat` route; do not invoke a deploy command to validate a build.

## 5. Reusable subagent prompt

> Implement **task 10.XX only** from `docs/native-phase-10-implementation-plan.md`.
> Read its dependency results,
> `docs/native-phase-10-today-coach-notifications-contract-decisions.md`, and the
> listed source/tests first. Report missing prerequisites before touching
> dependent code; independent work may continue. Respect the task file ownership
> and any existing uncommitted work. Reuse the existing pure engines and families
> — the notification coordinator/namespaces in
> `N/NativeEstimateFollowUpNotifications.swift`, `N/NativeAppointmentNotifications.swift`,
> `N/Domain/NativeInvoiceNotifications.swift`, `N/NativeReviewRequest*.swift`,
> `N/Domain/NativeBookingAttention.swift`, `N/NativeBackgroundRefresh.swift`, and
> the `N/Domain/FinancialDomain.swift` engines — rather than re-implementing
> policy. Use canonical data and field-scoped current-ID mutations; preserve
> unknown/concurrent fields. Reuse owner/environment, persistence, sync, and
> routing boundaries. No insight-ranking, snapshot, notification-selection, or
> coach-prompt policy in views. Coach and insight prompts expose only intended
> business context and never embed secure keys; nothing auto-sends to a customer.
> Add meaningful oracle/failure tests and run focused verification, compiling
> UI/platform changes. Record actual commands/results, not expected passes. Return
> requirement IDs covered, files changed, interface handoff, evidence, unresolved
> blockers, and next-ready tasks. Do not edit another task's shared files, invent
> backend guarantees, weaken determinism tests, commit, or deploy.

## 6. Initial execution ledger

Tasks **10.00, 10.01, 10.02, 10.03, and 10.04 are code complete**; all others are pending (see
the table). The source review used to write this plan is not test execution or
an implementation completion. Maintain
one row per task: status, owner/session, dependency evidence, files, commands,
actual results, blockers, and handoff. Separate **implementation blocked** from
**code complete / Phase 12 evidence deferred**.

| Task | Requirement IDs | Status | Depends on | Deliverable |
|---|---|---|---|---|
| 10.00 | all | **Code complete** | — | Contract decisions + fixture index |
| 10.01 | S1, S2 | **Code complete** | 10.00 | NativeBusinessSnapshot |
| 10.02 | S3 | **Code complete** | 10.00 | NativeTodayInsights |
| 10.03 | S4, D4, D5 | **Code complete** | 10.00 | Insight-mute + setup-checklist stores |
| 10.04 | D1, D2, D3, D6 | **Code complete** | 10.00 | NativeTodayBriefing |
| 10.05 | N1 | **Code complete** | 10.00 | Categories + permission prompt + settings |
| 10.06 | N2 | **Code complete** | 10.05 | Due-date/auto-outreach parity |
| 10.07 | N3, N4 | **Code complete** | 10.05 (+10.06 serialization only) | Appointment + review parity |
| 10.08 | N5, N6, B2 | **Code complete** | 10.05-10.07 | Unified reconciliation + routing |
| 10.09 | B1, B2 | **Code complete** | 10.01, 10.08 | Post-sync derived-state seam |
| 10.10 | C1, C2, C3, C4 | **Code complete** | 10.00, 10.01 | Coach transport + prompt + markdown + quick prompts |
| 10.11 | D1, D2, D3, D6 | **Code complete** | 10.04 | Today UI |
| 10.12 | D4, D5, S5 | Pending | 10.02, 10.03, 10.05, 10.11 | Checklist/hero/insights cards |
| 10.13 | C3, C4, C5 | Pending | 10.10, 10.12 | Coach UI + prefill |
| 10.14 | all | Pending | 10.01-10.13 | Cross-client qualification |
| 10.15 | all | Pending | 10.14 | Aggregate verification + closeout |

Exit criteria traceability (roadmap Phase 10):

- "Every current notification payload routes to the correct native record" —
  10.08 (routing/reconciliation) confirmed by 10.14; the per-family selectors in
  10.06/10.07.
- "Background tasks are tested on physical devices and fail safely" — 10.09
  (post-sync seam; fail-safe, failure-isolated outputs) with device evidence scheduled to Phase 12 via the
  10.15 runsheet, per the roadmap verification-deferral decision.
- "AI prompts expose only the intended business context" — 10.10 (prompt builder)
  and 10.13 (prefill), confirmed by 10.14.

---

## 7. Execution log

### 10.00 — Freeze contracts and characterize gaps

- Status: **Code complete / no implementation file changed.**
- Files: `docs/native-phase-10-today-coach-notifications-contract-decisions.md`
  (new; 15 sections — Today selection, attention model + native delta, the eight
  insight rules with every constant/id shape/reason/coach prompt, mute lifecycle,
  setup contract, snapshot contract, coach contract, markdown-lite, notification
  contract, duplicate prevention, parity oracle index, decision table, native
  interface handoff, source-discovered gaps, evidence + ledger).
- Commands / results: two RN oracle groups run with `TZ=America/Phoenix` —
  Today/insights/snapshot/checklist/attention (7 suites, 110 tests) and
  coach/markdown/notifications (6 suites, 123 tests). 13 suites / 233 tests, all
  passing. No oracle file was modified, added, or skipped.
- Blockers (named, non-blocking for the pure lane): live AI providers, device
  permission prompts, and background-refresh-on-device evidence are Phase 12 rows;
  `UNNotificationCategory` registration is 10.05 implementation work.
- Recorded intentional differences (native keeps these): the notification
  coordinator's priority order (`est_ → appt_ → review_ → inv_ → rinv_`, foreign
  families consuming cap budget first, never removed) versus RN's sweep order
  (`inv_ → appt_ → rinv_ → est_ → review_`); and the two extra booking-attention
  kinds (`missingJob`, `unconvertedActive`) that keep a booking from silently
  disappearing from the owner's view.
- Next-ready: **10.01**, **10.02**, **10.03**, **10.04**, and **10.10** (all pure,
  parallel), plus the notification lane **10.05**; 10.11–10.13 stay behind 10.04.

### 10.01 — Business snapshot engine

- Status: **Code complete / Phase 12 evidence deferred.**
- Files: `native/TradeReadyNative/Domain/NativeBusinessSnapshot.swift` (new:
  `NativeBusinessSnapshotAggregate`, `NativeBusinessSnapshot`,
  `NativeTaxSnapshotBlock`, `NativeTopCustomerEntry`, and
  `NativeBusinessSnapshotEngine.aggregate` / `buildTaxBlock` / `make` /
  `utcDateString` / `customerRollup`), `native/BusinessSnapshotTests/main.swift`,
  `native/run-business-snapshot-tests.sh`.
- Interface handoff: 10.02 consumes none of it; the consumers are 10.09 (caches
  it after a committed sync pass), 10.10 (`buildSystemPrompt` takes
  `NativeBusinessSnapshot` + `NativeTaxSnapshotBlock`; quick prompts read it), and
  10.13 (renders quick prompts from it); 10.12 may reuse `totalCustomers`.
  *(Corrected 2026-09-22; the original entry said "10.05–10.10".)* It reuses `PaymentLedger`,
  `NativeCashBasis.collectedByPeriod`, `NativeChangeOrders.billableTotal`,
  `TaxEstimateEngine` + `NativeTaxBreakdown` labels, and the
  `NativeCustomerIdentity` join rules (id → normalized name → derived key, sorted
  by lifetime spend) over canonical arrays.
- Commands / results: `TZ=America/Phoenix sh native/run-business-snapshot-tests.sh`
  — all checks passed (7 groups: revenue windows incl. the January rollover and
  the legacy `paidAt ?? due` fallback, outstanding/overdue with "due today is not
  overdue", partial payment dual counting, voided-payment exclusion, overpayment,
  active-status buckets with a zero-filled record never emitted, done-job average
  with approved/unapproved change orders and a zero-total job, customer rollup
  incl. invoice-only customers and the top-five cut, empty inputs, the tax block
  and its unset caveats, `asOf` UTC semantics, and tax-absent-on-failure).
  RN oracle re-run: `businessSnapshot.test.js` + `estimateSnapshot.test.js` pass.
- Cross-check: a scratch Jest probe (since deleted) printed the RN figures for the
  vectors this task adds beyond the oracle suite — overpayment
  (revenue 150 / outstanding 0), voided payment (revenue 0 / outstanding 1000),
  January rollover (400 / 250), top-five of seven (`C7…C3`, total 7), invoice-only
  `"  Casey  "` → `Casey`, unapproved change order → 2400, `asOf`
  `2026-07-06` at local midnight vs `2026-07-07` at 20:00 local, tax block
  `Jun 1 – Aug 31` / `Sep 15` with `incomeRateSet` — and the Swift expectations
  were pinned to that output.
- Note (recorded): the snapshot applies the customer-list rules to **canonical**
  arrays so money never round-trips through the UI projection's `Double`s; the
  money itself is `PaymentLedger` (the shared oracle), not a re-derived sum.
- Next-ready: 10.02, 10.03, 10.04, 10.05, 10.10 (all unblocked).

### 10.02 — Proactive insights engine

- Status: **Code complete / Phase 12 evidence deferred.**
- Files: `native/TradeReadyNative/Domain/NativeTodayInsights.swift` (new:
  `NativeInsightKind`, `NativeInsightTarget`, `NativeTodayInsight`, and
  `NativeTodayInsights.select` concatenating the eight selectors in the frozen
  priority order — `selectLaborOverruns`, `selectLowMarginEstimates`,
  `selectUninvoicedComplete`, `selectDueSoon`, `selectScheduleInsights`
  (open_slot + unscheduled_approved), `selectMaintenanceDue`,
  `selectExpenseAnomaly`, plus the pure `monthsBetween`/`shiftMonth`
  local-frame helpers and local `formatMoney`/`formatQuote`),
  `native/TodayInsightsTests/main.swift`, `native/run-today-insights-tests.sh`.
- Reused rather than rebuilt: `NativeTimeTracking.summary`/`.elapsedLabel` (labor
  overrun), `NativeSchedule.formatLaborHint`/`.largestFreeGap`/`.isWorkDay`/
  `.isBlackoutDate`/`.shiftDate`/`.parseDateComponents` and
  `NativeCalendar.selectUnscheduledApproved` (open slot + unscheduled approved,
  both generic over `ScheduleJobLike`, already satisfied by `Canonical.Job`),
  `NativeChangeOrders.billableTotal` (`jobBillableTotal`),
  `NativeCashBasis.ledgerInvoice`/`.ymd`/`.localComponents` +
  `PaymentLedger.isFullyPaid`/`.balanceDue` + `NativeMoneyReports.daysPastDue`
  (due-soon money/date math). `computeEstimateBreakdown`'s labor/material cost
  pair (the only two fields the low-margin rule reads) has no existing Swift
  port — `FinancialDomain.PricingEngine.calculate` takes a different forward
  `PricingInput`, not a stored `Canonical.Job` — so it is reimplemented locally
  from the job's own `laborHours`/`laborRate`/`materials`/`materialMarkup`
  exactly as `utils/pricingEngine.ts` does; `formatMoney`/`formatQuote` are
  likewise local (matching the RN formatter output) rather than importing
  `NativeJobProfitability.swift`'s heavier profitability dependency chain for
  two formatting calls.
- No canonical-input gaps: every RN input (`Job`, `Invoice`, `Customer`,
  `RecurringJob`, `Expense`, `ResolvedSchedule`) already has a `CanonicalModels`
  counterpart with the exact fields the rules read, so no rule was suppressed
  for a missing canonical field.
- Interface handoff: `NativeTodayInsights.select(jobs:invoices:now:schedule:
  targetMarginPercent:customers:recurringJobs:expenses:) -> [NativeTodayInsight]`.
  `NativeTodayInsight` exposes `kind: NativeInsightKind` and `id: String` in the
  shapes `NativeInsightMutes.filterMuted`/`.activeMutedIDs` already expect (a
  generic `id: (T) -> String` closure) — no change needed to 10.03's mute file.
  `NativeInsightTarget` is an exhaustive, Equatable/Hashable enum mirroring
  `InsightTarget` 1:1 for 10.04's compiler-checked mapping to
  `NativeTodayDestination`. 10.12 renders `.title`/`.detail`/`.reason`/
  `.coachPrompt` for the top three post-mute rows.
- Commands / results: `TZ=America/Phoenix sh native/run-today-insights-tests.sh`
  — all checks passed (all eight kinds' trigger boundaries incl. the 15-minute
  labor-overrun floor and 14-minute silence, the low-margin target−3-point
  boundary and severe/break-even split, the uninvoiced/due-soon single-vs-
  aggregate collapse and "due today is not overdue" window, open-slot
  120-minute boundary plus custom-schedule/blackout/non-workday suppression and
  stable tie-break ordering, unscheduled-approved double-count exclusion,
  maintenance-due's 6-calendar-month boundary/contact/pipeline/recurring
  exclusions and first-name-only coachPrompt, expense-anomaly's strict->1.5x
  threshold/$200 floor/three-non-zero-months guard/future-dated exclusion/
  biggest-driver category, full priority ordering, and id-shape pinning).
  RN oracle re-run: `TZ=America/Phoenix npm test -- --runInBand
  --runTestsByPath __tests__/todayInsights.test.ts` — 55/55 passed (unchanged
  baseline; this task ports it, does not modify it).
  `xcodebuild … Release … CODE_SIGNING_ALLOWED=NO build` — **BUILD SUCCEEDED**.
- Self-review: read the full diff before committing; found no unintended edits
  to `N/Domain/NativeInsightMutes.swift` or any shared/integration-lane file —
  only the three new files above are staged.
- Next-ready: 10.04, 10.11, 10.12 (10.02 was their remaining pure-lane
  dependency alongside 10.03).

### 10.03 — Device-local owner-bound state stores

- Status: **Code complete / Phase 12 evidence deferred.**
- Files: `native/TradeReadyNative/Domain/NativeInsightMutes.swift` (mute value +
  policy: `makeMute`, `isMuteActive`, `filterMuted`, `activeMutedIDs`, `prune`,
  `applying`, `sanitized`, local-frame `shift`),
  `native/TradeReadyNative/NativeInsightMuteStore.swift`,
  `native/TradeReadyNative/Domain/NativeSetupChecklist.swift` (task ids, titles,
  subtitles, `deriveSetupTasks` inputs, `isSetupComplete`, routes, state
  transitions, seed merge), `native/TradeReadyNative/NativeSetupChecklistStore.swift`
  (+ `NativeReminderPromptStore` for the one-shot permission flag),
  `native/InsightMuteTests/main.swift`, `native/SetupChecklistTests/main.swift`,
  `native/run-insight-mute-tests.sh`, `native/run-setup-checklist-tests.sh`.
- Interface handoff (the integration lane's adoption contract):
  `NativeInsightMuteStore.load/save/applyMute/mergeSeeded/removeAll`,
  `NativeSetupChecklistStore.load/save/markTaskDone/dismiss/markSampleTourDone/
  mergeSeeded/removeAll`, and
  `NativeReminderPromptStore.wasShown/markShown/mergeSeeded/removeAll` — all keyed
  by the 64-hex verified account binding, so 10.11/10.12 (and 10.05 for the
  prompt) call them after owner verification and add them to the account-boundary
  scrub list.
- Commands / results: `TZ=America/Phoenix sh native/run-insight-mute-tests.sh` —
  all checks passed (policy: dismiss vs snooze shape, `until` boundaries,
  order-preserving filter, expired/stale pruning, replace-instead-of-stack,
  month/year `shift`; store: round-trip, backup recovery for a missing primary,
  fail-closed corrupt read AND write, mismatch/invalid-binding rejection,
  `applyMute`, seed adoption with owner records winning, duplicate-id documents
  keeping the newest write). `TZ=America/Phoenix sh
  native/run-setup-checklist-tests.sh` — all checks passed (five tasks in order
  with RN titles/subtitles, phone+address / logo / recorded rate / recorded or
  alternative-processor stripe / granted-notifications derivations, the shared
  `isSetupComplete` gate, state transitions, `SETTINGS_ROUTE_FOR_TASK` routes,
  store round-trip + idempotent writes + backup recovery + fail-closed reads and
  writes, seed adoption, and the owner-bound one-shot reminder flag).
  RN oracle re-run: `insightMutes.test.ts` + `setupChecklist.test.js` pass.
  `xcodebuild … Release … CODE_SIGNING_ALLOWED=NO build` — **BUILD SUCCEEDED**.
- Recorded behaviour: a corrupt store fails closed on **read and write** (it
  never silently reads as "no mutes"/"empty checklist", which would resurrect
  dismissed rows or re-show the setup card), and `removeAll` is the only way out —
  matching the sibling `NativeReviewRequestStore` contract.
- Next-ready: 10.02, 10.04, 10.05, 10.10 (all unblocked); 10.12 now has both
  stores it needs.

### 10.04 — Today selectors, stats, and routing contract

- Status: **Code complete / Phase 12 evidence deferred.**
- Files: `native/TradeReadyNative/Domain/NativeTodayBriefing.swift` (week strip
  + per-day schedule filter/sort + earnings, stats inputs, overdue/lead
  sections with exact caps, awaiting-estimates row (reuses
  `NativeEstimateFollowUp`), header greeting/date, `NativeTodayDestination` +
  the exhaustive `destination(for: NativeInsightTarget)` mapping, first-action
  hero derivation, booking-attention row presentation (reuses
  `NativeBookingAttention.select`), `isSampleId`), `native/TodayBriefingTests/main.swift`,
  `native/run-today-briefing-tests.sh`.
- Interface handoff (10.11/10.12's adoption contract): `NativeTodayDestination`
  is the pure routing contract — 10.11 executes it through the existing
  one-shot exact-ID pattern (`NativeGlobalSearch`/
  `AppStore.routeToGlobalSearchResult`: verify the local id, change tab,
  install a single-use request, fail closed on missing/archived).
  `NativeTodayBriefing.destination(for:)` is an exhaustive, no-`default:`
  switch over `NativeTodayInsight`'s `NativeInsightTarget` (10.02), so a new
  insight target fails this file's compile instead of silently no-oping.
  `NativeTodayBriefing.hero(jobs:customers:sampleTourDone:)` takes
  `sampleTourDone` as a plain `Bool` — it does not call
  `NativeSetupChecklistStore` (10.03 owns persistence; 10.12 owns the
  hero-suppresses-insights gate per ledger ruling R3). This task performs no
  routing side effects and does not edit `AppStore.swift`/`TodayView.swift`.
- Commands / results: `TZ=America/Phoenix sh native/run-today-briefing-tests.sh`
  — all checks passed (destination mapping for all 10 insight targets;
  greeting cutoffs at 11:59/12:00 and 16:59/17:00 with an explicit
  America/New_York calendar; `formatDisplayDate`/`formatTimeRange` pinned to
  `dateHelpers.test.js`; week strip Mon–Sun boundaries incl. a DST
  spring-forward week; `shiftDate` month/year rollovers; unscheduled-last
  schedule-row ordering; earnings sum including a scheduled lead; overdue
  filter/sort with due-today excluded and a DST fall-back day-count case;
  lead sort by `createdAt`; section caps at exactly the limit (no see-more)
  and one over (see-more = 1); awaiting-estimates gate at the 3-day boundary
  and the follow-up toggle; first-action hero for sample/add-customer/
  create-job plus the "no real jobs" and "tour already done" no-hero cases;
  booking-row presentation incl. the missing-job-id → Jobs-tab fallback;
  `isSampleId` against the RN `SAMPLE_ID_RE` pattern). RN oracle re-run:
  `TZ=America/Phoenix npm test -- --runInBand --runTestsByPath
  __tests__/dateHelpers.test.js __tests__/TodayScreenSettingsGear.test.tsx
  __tests__/crossTabNavigation.test.tsx __tests__/bookingAttention.test.ts
  __tests__/estimateFollowUps.test.ts` — 5 suites / 52 tests, all passing, no
  oracle file touched. `xcodebuild … Release … CODE_SIGNING_ALLOWED=NO build`
  — **BUILD SUCCEEDED**.
- Recorded intentional native difference: RN's `weekMonthLabel` builds its
  cross-month label via `new Date(weekDates[0])` — a bare-date UTC parse that
  would mislabel a week starting on the 1st of a month on a west-of-UTC
  device (e.g. a week containing Jan 1 could read "Dec"). This port computes
  the label from local-frame date components instead (via
  `NativeSchedule.parseDateComponents`), per the binding global constraint
  ("date-only strings use local-frame string math, never Date-parsing to
  UTC") and CLAUDE.md's correctness-over-continuity rule. Not exercised by
  the existing RN oracle (`dateHelpers.test.js` only covers a July week), so
  it is a silent-in-RN defect this native port does not reproduce.
- Discrepancy found and resolved by reading `TodayScreen.tsx` directly (per
  the task brief's "Read first" instruction): the frozen contract's §1.5
  first-action-hero pseudocode is a flattened if/else-if chain, but the
  actual RN source is a NESTED conditional. They disagree in exactly one
  state: sample jobs exist AND (a real customer already exists OR the sample
  tour is done). The contract's flattened form falls through to "Create Your
  First Job"; the actual RN component shows **no hero at all** in that state
  (the inner `if` has no `else`, and the outer `else if`/`else` branches are
  gated on `sampleJobs.length === 0`, which is false here). This port matches
  the actual component (pinned oracle) and adds a fixture test
  (`heroSampleWithRealCustomer`) that would fail under the contract's
  paraphrase. Recommend a follow-up correction to
  `docs/native-phase-10-today-coach-notifications-contract-decisions.md` §1.5.
- Next-ready: 10.11 (Today UI integration) and 10.12 (checklist/hero/insights
  cards) — both were already gated on 10.04 alone for this requirement set and
  can now proceed; 10.05, 10.10 remain unblocked and unaffected.

### 10.05 — Notification permission, categories, and settings surface

- Status: **Code complete / Phase 12 evidence deferred (device permission
  dialogs, real OS delivery).**
- Files (new): `native/TradeReadyNative/NativeNotificationCategories.swift`
  (`NativeNotificationCategories.makeAll()` — one `UNNotificationCategory` per
  `NativeNotificationNamespace`, identifier = the namespace's `payloadType`, a
  single non-destructive `VIEW`/`.foreground` action each — no category can
  send anything to a customer), `native/NotificationPermissionTests/main.swift`,
  `native/run-notification-permission-tests.sh`.
- Files (edited): `native/TradeReadyNative/NativeEstimateFollowUpNotifications.swift`
  (protocol gains `registerCategories(_:)` with a no-op default extension so
  every pre-existing fake center keeps conforming unmodified; the system center
  implements it via `setNotificationCategories` and stamps
  `content.categoryIdentifier` on every scheduled notification; the coordinator
  gains `registerCategoriesIfNeeded()` — idempotent, guarded by a private flag
  — and `promptForInvoiceRemindersIfNeeded()` plus the
  `NativeInvoiceReminderPromptOutcome` result type; the designated init gains
  two defaulted closures, `wasReminderPromptShown`/`markReminderPromptShown`),
  `native/TradeReadyNative/AppStore.swift` (new `reminderPromptStore:
  NativeReminderPromptStore` property + init wiring; `removeAll()` added to all
  three account-scrub sites alongside `reviewRequestStore.removeAll()`; new
  `activateReminderPromptFlag` seed-adoption method — same `mergeSeeded`
  pattern as `activateReviewRequests` — called from both
  `applyAuthenticatedIdentityOutcome` and the foreground-activation path;
  `wasInvoiceReminderPromptShown()`/`markInvoiceReminderPromptShown()` reading
  the store fail-closed to "already shown"; new settable
  `onInvoiceCreatedContextualPrompt` hook fired from `commitInvoiceEdit`'s
  new-invoice branch and from `commitInvoiceFromJob`'s non-`.finalize` branch —
  the exact native equivalents of RN's two `promptForInvoiceReminders()` call
  sites in `AddInvoiceScreen.tsx`/`CreateInvoiceFromJobScreen.tsx`),
  `native/TradeReadyNative/TradeReadyNativeApp.swift` (builds the coordinator
  into a local `let` so it can wire `store.onInvoiceCreatedContextualPrompt`
  to `coordinator.promptForInvoiceRemindersIfNeeded()` and call
  `coordinator.registerCategoriesIfNeeded()` once, both before the
  `StateObject` wrap). Twelve `native/run-*-tests.sh` runners updated to add
  `NativeNotificationCategories.swift` (and, for six that compile `AppStore.swift`
  standalone, `Domain/NativeSetupChecklist.swift` +
  `NativeSetupChecklistStore.swift`) to their `swiftc` file lists so they keep
  compiling: `run-notification-coordinator-tests.sh`,
  `run-estimate-follow-up-notification-tests.sh`,
  `run-appointment-notification-tests.sh`, `run-review-request-tests.sh`,
  `run-calendar-editor-tests.sh`, `run-export-import-ui-tests.sh`,
  `run-phase9-qualification-tests.sh`, `run-pricebook-ui-tests.sh`,
  `run-schedule-booking-settings-tests.sh`, `run-store-integration-tests.sh`.
- Interface handoff for 10.12 (setup checklist's `notifications` task): call
  `NativeEstimateFollowUpNotificationCoordinator.requestAuthorization() async
  -> Bool` (pre-existing) to request permission — on `true`, call
  `synchronize()` (pre-existing, already used by `NotificationSettings`); on
  `false`, read `.permissionState` (`@Published`, pre-existing) — `.denied`
  means the card should offer "Open device settings"
  (`UIApplication.openSettingsURLString`, same pattern already used by
  `NotificationSettings` in `SettingsView.swift`). No new API was needed for
  this because 10.03/pre-existing work already exposed exactly this shape;
  10.05 only adds the *contextual, one-shot* ask
  (`promptForInvoiceRemindersIfNeeded()`), which 10.12 does not call — the
  checklist's in-card "notifications" task is a direct ask, not the contextual
  one-shot.
- Settings surface (item 3 of the brief): already bound to the shared,
  generalized coordinator (`NativeEstimateFollowUpNotificationCoordinator` with
  `namespacePlans` covering `.appointment`/`.review`/`.invoiceReminder`/
  `.recurringInvoice`, aliased `NativeNotificationCoordinator`) rather than an
  estimate-only coordinator — this was already true in the baseline snapshot
  from earlier phases, so no `SettingsView.swift` edit was needed. Verified the
  existing toggle defaults are exactly as specified and untouched:
  `estimateFollowUpsEnabled` defaults `true` (`CanonicalModels.swift`),
  `appointmentRemindersEnabled` defaults `false`, `reviewRequestEnabled`
  defaults `false` (the review-request gate).
- Commands / results:
  - `TZ=America/Phoenix sh native/run-notification-permission-tests.sh` —
    `PASS: native notification permission/category tests` (9 fixture groups:
    exactly 5 categories keyed to the 5 namespace payload types with one
    non-destructive action each; `registerCategoriesIfNeeded()` registers once
    and is a no-op on repeat calls; no workspace → no read/stamp/request;
    already-shown → silent; OS already `authorized`/`denied` → flag stamped
    once, no request; undetermined + grant → flag stamped BEFORE the request,
    exactly one request, exactly one `synchronize()` pass observed as one
    scheduled item; undetermined + refusal → one request, zero synchronize;
    three repeated calls in one session → only the first ever requests/stamps;
    simulated sign-out clears the flag for the next owner).
  - Re-ran every existing runner touched: `run-notification-coordinator-tests.sh`,
    `run-estimate-follow-up-notification-tests.sh`,
    `run-appointment-notification-tests.sh`, `run-invoice-notification-tests.sh`,
    `run-review-request-tests.sh`, `run-setup-checklist-tests.sh` — all still
    pass (no behavior change to existing fixtures).
  - RN oracles: `TZ=America/Phoenix npm test -- --runInBand --runTestsByPath
    __tests__/settingsNotificationsScreen.test.tsx __tests__/notifications.test.js`
    — 2 suites / 40 tests, all passing, no oracle file touched.
  - `sh native/run-all-domain-tests.sh` — full aggregate green (all Swift host
    runners plus the Cloudflare Worker/Vercel Node suites), confirming the
    twelve edited runner scripts and the `AppStore.swift`/coordinator changes
    do not regress any other domain.
  - `xcodebuild -project native/TradeReadyNative.xcodeproj -scheme
    TradeReadyNative -configuration Release -destination
    'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build` — **BUILD SUCCEEDED**.
- **Fix round 1 (2026-09-22):** review found the first pass skipped RN's
  custom pre-permission rationale `Alert.alert('Invoice reminders', …)` and
  fired the real OS permission dialog directly and unconditionally when
  undetermined — not "exactly like RN" as the brief requires. Corrected: the
  coordinator now stamps the flag then publishes a pending soft-ask
  (`@Published pendingInvoiceReminderPrompt`, plus
  `pendingInvoiceReminderPromptBinding` for owner-scoping) instead of calling
  `requestAuthorization()` directly; `NativeInvoiceReminderPromptOutcome`
  gained `.pendingUserChoice` in place of the old `.requested(granted:)`.
  `TradeReadyNativeApp.swift` presents it via a root-level SwiftUI `.alert`
  using RN's title/message/button copy verbatim from `utils/notifications.ts`;
  "Turn on" calls the new `confirmInvoiceReminderPrompt() async -> Bool`
  (requests authorization, and on grant runs `synchronize()` exactly once);
  "Not now" calls `dismissInvoiceReminderPrompt()` (clears the pending state
  only — the flag stays stamped, as in RN, so it never re-asks). A
  binding-mismatch check in `synchronizeOnce(now:)` dismisses any pending
  soft-ask that belongs to an account the user has since left. Also fixed
  Minor #1: `wasReminderPromptShown`'s default closure changed from `{ false
  }` to `{ true }` — the previous default was unsafe for any caller that
  never injects the real store closures (it could re-request indefinitely);
  the fail-safe default now means "treat as already shown" until a real
  store is wired in. `native/NotificationPermissionTests/main.swift` was
  rewritten to assert the new contract: flag stamped before the alert can
  show; zero OS requests until "Turn on"; "Not now" makes zero requests;
  repeated calls while pending never ask twice; a grant triggers exactly one
  `synchronize()`; an account-binding change during `synchronize()` dismisses
  a stale pending alert; and the fail-safe default never prompts when no
  store is injected. The previous "Recorded decision" entry below, which
  described the missing rationale UI as an intentional, correct scope choice,
  was incorrect and is superseded by this fix.
- Blockers: none for this task's own scope. Device permission-dialog and
  real-delivery evidence remain Phase 12 rows per the roadmap's
  verification-deferral decision.
- Next-ready: **10.06** (due-date reminders/auto-outreach parity), **10.07**
  (appointment/review parity — 10.06 serialization only), and **10.12** (setup
  checklist's notifications task now has its documented permission API).

### 10.06 — Due-date reminders and the auto-outreach variant

- Status: **Code complete / Phase 12 evidence deferred (device delivery).**
  Audit-and-close-gaps task; the audit found the `inv_`/`rinv_` selector
  already at parity with the RN fixtures. No implementation file changed —
  only test coverage was added.
- Audit result (against the frozen contract's §9.1-9.3): paid filtering (ledger
  `isPaid`, matching RN's `isFullyPaid`), blank/malformed `due` (shared local
  `dayDate` parser returns `nil`, item dropped), imported `importBatchId`
  (excluded), pre-completion deposit suppression (`isDunningEligible` mirrors
  `isJobDunningEligible`), rule-day ordering (outer invoice / inner rule-day,
  matching RN's loop nesting), and the auto-outreach title/body/
  `overdue_outreach` payload switch were all already correct in
  `N/Domain/NativeInvoiceNotifications.swift` and
  `N/AppStore.swift#invoiceReminderNotifications` — no divergence to close.
  The shared 60-request cap and native family priority
  (`est_ → appt_ → review_ → inv_ → rinv_`, foreign-first) live in the
  coordinator (10.05's file) and were out of this task's scope; confirmed
  unchanged and still passing.
- Fire-date drift (item 3): `fireDate(fromDue:plusDays:)` (`inv_`) and
  `nineAM(on:)` (`rinv_`) already share one `dayDate` local-frame day parser,
  so the two branches structurally cannot drift independently — no refactor
  needed. Added a DST-boundary pin (`America/New_York`, 2026-03-08 spring
  forward) to `native/InvoiceNotificationTests/main.swift` proving both
  branches land on the same 9 a.m. local instant across the boundary.
- Tap routing (N6): `AppStore.requestInvoiceReminderReview` was already
  gated on `hasExactSignedInWorkspace` and `invoices.contains(where:)`
  (fail-closed for a missing or wrong-owner invoice), and
  `consumeOutreachDeepLink` was already one-shot with no send path in
  `NativeInvoiceOutreachView` (manual compose/send only, never automatic).
  This had zero test coverage anywhere in the repo, so
  `native/StoreIntegrationTests/main.swift` gained five assertions using the
  existing `scheduleBookingTestSeedSignedInOwner`/`scheduleBookingTestClearOwner`
  test seam: routing is inert before an exact-owner workspace is bound; a
  plain reminder tap routes to the invoice without arming outreach; an
  auto-outreach tap arms the outreach sheet exactly once (`consumeOutreachDeepLink`
  returns `true` once, `false` after); a missing invoice ID fails closed; and
  clearing the owner revokes routing for a previously-valid invoice ID.
  "Archived" invoices are not a distinct N6 case — `Invoice` carries no
  `archivedAt`; only jobs/customers do. "Paid" is not a routing block either:
  the RN `OutreachScreen` still opens for a paid invoice (`isFullyPaid`
  hides send actions but the screen renders), so the native tap correctly
  still resolves it — parity holds, not a gap.
- Files: `native/InvoiceNotificationTests/main.swift` (DST-boundary fire-date
  test), `native/StoreIntegrationTests/main.swift` (tap-routing tests). No
  `N/AppStore.swift` or `N/Domain/NativeInvoiceNotifications.swift` edits —
  the audit found no divergence to fix.
- Commands / results: `sh native/run-invoice-notification-tests.sh` — PASS.
  `sh native/run-store-integration-tests.sh` — PASS. `sh
  native/run-notification-coordinator-tests.sh`, `run-estimate-follow-up-notification-tests.sh`,
  `run-appointment-notification-tests.sh`, `run-review-request-tests.sh`,
  `run-notification-permission-tests.sh` — all PASS (unchanged, confirming no
  regression). `TZ=America/Phoenix npm test -- --runInBand --runTestsByPath
  __tests__/notifications.test.js __tests__/reminderLogic.test.js
  __tests__/reminderEmailHardening.test.js` — 3 suites / 101 tests passing, no
  oracle file modified. `sh native/run-all-domain-tests.sh` — see task report
  for the full run.
- Blockers: none for this task's own scope. Device delivery evidence remains
  a Phase 12 row.
- Next-ready: **10.07** (appointment/review parity), **10.08** (unified
  reconciliation + routing, now has 10.06's confirmed-clean `inv_`/`rinv_`
  selectors to reconcile against).

### 10.07 — Appointment and review-request parity

- Status: **Code complete / Phase 12 evidence deferred (device delivery).**
  Audit-and-close-gaps task. The `appt_` selector
  (`N/NativeAppointmentNotifications.swift`) and the `review_` pure policy
  (`N/NativeReviewRequests.swift` + `N/NativeReviewRequestStore.swift`) were
  already at parity with the RN fixtures — no divergence there. The audit did
  find and fix one real bug in the `review_` **rebuild wiring**
  (`N/AppStore.swift#reviewRequestNotifications`): the sweep's rebuild
  selector read `record.scheduledAt` with a plain `ISO8601DateFormatter()`,
  which cannot parse the fractional-seconds format every writer
  (`armReviewRequestIfEligible`, `markReviewRequestSent`) actually produces —
  every pending record was silently dropped from the rebuilt plan on every
  sweep, i.e. the exact N4/B2 failure mode this task exists to guard against
  was live. Fixed by setting `formatter.formatOptions = [.withInternetDateTime,
  .withFractionalSeconds]` to match the writers.
- Audit result (brief item 1, appointment): active-status set
  (`approved`/`scheduled`/`in_progress`), contact requirement
  (phone-preferred/email-fallback/none, whitespace-only treated as absent),
  day-before 5pm local fire date (including an explicit DST spring-forward
  and fall-back case, `America/Los_Angeles` 2027-03-14/2027-11-07), and
  stable soonest-first ordering (equal fire dates preserve input order) were
  all already correct in `NativeAppointmentNotifications` — no divergence.
  Tap-never-auto-sends is `NativeAppointmentConfirmationReviewView`
  (pre-existing): an editable `TextEditor` gated behind an explicit "Continue
  to Messages/Mail" button that opens the system composer; nothing sends
  without that composer's own Send action.
- Audit result (brief item 2, review): transition-into-`complete` one-shot
  gating, reachable-contact requirement, no-existing-record guard,
  `max(1, delayHours || 3)` delay fallback, live-customer-preferred draft
  with saved-record fallback, and `sent`-cancel-non-blocking were all already
  correct in `NativeReviewRequests` + `AppStore.armReviewRequestIfEligible` /
  `markReviewRequestSent`. The sweep rebuild (brief's "most important item")
  had the formatter bug above; fixed.
- Parity test (brief item 3, B2 dependency preview): the combined
  sweep-survives-a-relaunch proof lives in one layer, in
  `native/StoreIntegrationTests/main.swift`. A full `AppStore` completes a
  job (arming the `review_` one-shot), sweeps
  `reviewRequestNotifications(now:)` at a mid-window `now` on that store,
  then simulates a relaunch with a second `AppStore` instance that calls the
  new `scheduleBookingTestReloadReviewRequests` seam — which invokes the
  real, private `activateReviewRequests(accountBinding:migrated:)` reload
  path (the same method a live launch's `applyAuthenticatedIdentityOutcome`
  calls), not a bypass — and sweeps the SAME mid-window `now` on the
  relaunched store; the identical `review_<jobId>` identifier and fire date
  survive both the mid-window sweep and the relaunch together. A further
  sweep after the fire instant drops it (no late re-nag), and marking the
  request sent removes it from every subsequent sweep for good.
  `native/ReviewRequestTests/main.swift` separately keeps a narrower,
  store-level proof: two `NativeReviewRequestStore` instances against the
  same file URL (a simulated relaunch) resolve the identical persisted
  record and therefore the identical `review_` fire instant computed by
  `NativeReviewRequests.planItem` — this is a pure relaunch-persistence
  check only, since `planItem` takes no `now` and cannot demonstrate
  sweep time-variance; that half of the guarantee is exercised solely by
  the `StoreIntegrationTests` test above.
- Tap routing (N6): `requestAppointmentConfirmationReview` and
  `requestReviewRequestReview` were already gated on
  `hasExactSignedInWorkspace`/`isSignedIn` and an existing job/draft
  (fail-closed for a missing or wrong-owner job) — zero test coverage
  anywhere in the repo. `native/StoreIntegrationTests/main.swift` gained
  assertions using the `scheduleBookingTestSeedSignedInOwner`/
  `scheduleBookingTestClearOwner` seam (matching 10.06's pattern): both taps
  are inert before an exact-owner workspace is bound; both route to the
  exact-owner job and open their editable sheet once bound; a missing job ID
  fails closed for both; clearing the owner revokes routing for a
  previously-valid job.
- Files: `native/AppointmentNotificationTests/main.swift` (expanded fixture
  coverage), `native/ReviewRequestTests/main.swift` (relaunch/sweep parity),
  `native/StoreIntegrationTests/main.swift` (tap routing + AppStore-level
  sweep), `N/AppStore.swift` (`reviewRequestNotifications` formatter fix).
- Commands / results: `sh native/run-appointment-notification-tests.sh` —
  PASS. `sh native/run-review-request-tests.sh` — PASS. `sh
  native/run-store-integration-tests.sh` — PASS (reproduced the sweep bug
  before the fix, confirmed fixed after). `sh
  native/run-appointment-messaging-tests.sh`, `run-notification-coordinator-tests.sh`,
  `run-estimate-follow-up-notification-tests.sh`,
  `run-invoice-notification-tests.sh`, `run-notification-permission-tests.sh`,
  `run-background-refresh-tests.sh` — all PASS (unchanged, no regression).
  `TZ=America/Phoenix npm test -- --runInBand --runTestsByPath
  __tests__/notifications.test.js __tests__/reviewRequest.test.js
  __tests__/ReviewRequestScreen.test.tsx` — 3 suites / 57 tests passing, no
  oracle file modified. `sh native/run-all-domain-tests.sh` and the
  Release/generic-iOS `xcodebuild` compile — see task report for the full
  run.
- Blockers: none for this task's own scope. Device delivery evidence remains
  a Phase 12 row.
- Next-ready: **10.08** (unified reconciliation + routing, now has 10.07's
  confirmed-clean `appt_`/`review_` selectors — including the fixed `review_`
  rebuild — to reconcile against).

### 10.08 — Unified notification reconciliation and tap routing

- Status: **Code complete.** Audit-and-close-gaps task, same shape as 10.06/
  10.07: the single coordinator already reconciled all five owned families
  with the documented native priority (`est_ → appt_ → review_ → inv_ →
  rinv_`), per-namespace cleanup before the authorization guard, and the
  foreign-family rule — confirmed correct by re-reading
  `N/NativeEstimateFollowUpNotifications.swift` and
  `N/TradeReadyNativeApp.swift`, unchanged by this task.
- Audit result (brief item 2, schedule key): `estimateFollowUpNotificationScheduleKey`
  was missing several fields the five selectors actually read — est_'s
  `customerName`/`title` (notification title/body), review_'s
  `customerName`/linked job `title` (body) and `settings.reviewRequestDelayHours`
  (fire-date offset — a real bug: changing the delay would not retrigger a
  resync, leaving pending review_ reminders at their stale fire time), inv_'s
  `customer`/`number` (title/body) and the linked job's `status` (drives
  `isJobDunningEligible`), and rinv_'s `customerName` (body). Fixed by adding
  all six. Confirmed insight mutes, setup-checklist state, and expenses are
  not folded in — the 10.03 mute/checklist stores are not wired into
  `AppStore` at all yet, and a table test proves an expense addition leaves
  the key unchanged. Permission state is deliberately NOT a key input; every
  call site that can change it already calls `synchronize()` explicitly
  afterward (`SettingsView`'s request button, the invoice-reminder soft-ask's
  "Turn on", and the `scenePhase == .active` foreground path).
- Audit result (brief item 4, routing): `appt_`'s
  `NativeAppointmentNotifications.canOpenNotification` and `review_`'s
  `requestReviewRequestReview` did not fail closed for an archived job —
  only `est_`'s did. Fixed both to match. `rinv_`'s
  `requestRecurringInvoiceReview` never resolved a record at all — it only
  switched to the Invoices tab. Fixed to resolve the latest GENERATED
  invoice for the rule (`recurringInvoiceId == ruleID`, highest
  `occurrenceNumber`), matching `App.tsx`'s `recurring_invoice` tap handler,
  falling back to the plain tab when nothing has generated yet; a missing
  rule or absent exact workspace still fails closed.
- Idempotence (brief item 3): added a named coordinator test proving the
  shared 60-cap with all five families competing and 57 foreign requests
  present (foreign consumes budget first, priority holds across the full
  set); an idempotent-reconcile test (two `synchronize()` calls 1s apart on
  the same coordinator produce an identical pending set, no identifier ever
  pending twice); and a simulated-relaunch test (a brand-new coordinator
  instance reusing the same underlying pending-request state produces the
  identical set).
- Tap-routing coverage (carried-forward 10.06 ledger finding): `appt_`/
  `review_`/`rinv_` lacked fail-closed test coverage; `rinv_` had none at
  all. `native/StoreIntegrationTests/main.swift` gained an archived-job
  block for `appt_`/`review_` and a full `rinv_` block (inert before
  binding, success with/without a generated invoice, missing-rule fail
  closed, signed-out fail closed).
- Files: `N/AppStore.swift` (schedule key, `requestReviewRequestReview`,
  `requestRecurringInvoiceReview`, two test-only `scheduleBookingTest*`
  seams), `N/NativeAppointmentNotifications.swift` (`canOpenNotification`
  archived guard), `native/NotificationCoordinatorTests/main.swift`,
  `native/StoreIntegrationTests/main.swift`.
- Commands / results: `sh native/run-notification-coordinator-tests.sh`,
  `run-store-integration-tests.sh`, `run-estimate-follow-up-notification-tests.sh`,
  `run-appointment-notification-tests.sh`, `run-invoice-notification-tests.sh`,
  `run-review-request-tests.sh`, `run-notification-permission-tests.sh` — all
  PASS. `TZ=America/Phoenix npm test -- --runInBand --runTestsByPath
  __tests__/notifications.test.js` — 37/37 passing.
  `__tests__/reminderLogic.test.js __tests__/reminderEmailHardening.test.js
  __tests__/reviewRequest.test.js` — 79/79 passing, no oracle file modified.
  `sh native/run-all-domain-tests.sh` and the Release/generic-iOS
  `xcodebuild` compile — see task report for the full run.
- Blockers: none. Device delivery evidence remains a Phase 12 row.
- Next-ready: **10.09** (post-sync derived-state seam — the reconcile entry
  point is `NativeEstimateFollowUpNotificationCoordinator.synchronize(now:)`,
  the same method `TradeReadyNativeApp.swift` already calls from
  `.task(id:)` and the foreground path).

### 10.09 — Background refresh completion for Today and scheduling

- Status: **Code complete (fix round 1 applied — see below).** New
  `N/NativeDerivedStatePublisher.swift`: a generic (`Input`/`Output`
  type-parameterized, dependency-free) post-sync-commit seam with
  `register`/`unregister` (output b), an owner-scoped `cachedSnapshot`
  accessor that fails closed (output c), and
  `publish(canonical:expectedOwnerBinding:)` guarded by a monotonic
  generation counter. **Contract (post-fix-round-1): "exactly once per
  committed canonical sync commit," not a single call site.**
  `AppStore.pullDeltaIfPossible` has several legitimate direct callers
  besides the coordinator's own pull closure (the booking response/
  reschedule/portal-admin recovery paths) — each one that reaches its commit
  publishes once, from that commit's snapshot; a caller that performs two
  separate commits (e.g. `prepareBookingReschedule`'s `syncNowAndWait` pull
  followed by its own direct `pullDeltaIfPossible`) correctly publishes
  twice. `AppStore.runBookingIntakeAfterVerifiedPull`'s local commit and the
  initial-full-sync commit in `beginInitialSyncGate` are each their own
  commit and publish separately too. The generation guard (not a single
  funnel) is what keeps these correctly ordered: a publish that resumes,
  after suspending in the notification-reconcile await, later than a newer
  publish has already completed must not overwrite the newer cache/observer
  state with its now-stale snapshot. Every excluded pass (offline,
  signed-out/no credentials, backoff, a thrown/failed push which skips the
  pull entirely, `.alreadyRunning` never reaching `runOnce` at all, or any
  pre-commit failure inside `pullDeltaIfPossible`) still returns before its
  would-be publish call — no new gating logic was needed for those.
- AppStore wiring: `derivedStatePublisher` (lazy,
  `NativeDerivedStatePublisher<Canonical.Snapshot, NativeBusinessSnapshot>`),
  `cachedBusinessSnapshot` (10.13 reads this for coach cold start),
  `registerDerivedStateObserver`/`unregisterDerivedStateObserver` (11.01's
  widget-mirror seam), and `notificationSynchronizeHook` — AppStore cannot
  hold the `NativeEstimateFollowUpNotificationCoordinator` directly (same
  constraint as the existing `onInvoiceCreatedContextualPrompt` hand-off), so
  `TradeReadyNativeApp.init` wires the hook to
  `coordinator.synchronize(now:)` — the exact 10.08 entry point, not a second
  reconcile path. Every account-boundary path calls
  `derivedStatePublisher.reset()`: `applyCompletedSignOutState` (alongside the
  existing `syncCoordinator?.reset()` call), `useAnotherAccount`, and
  `applyRecoverySignedOutState`. `reset()` clears ONLY the owner-scoped
  cached snapshot — observer registrations are app-lifetime (the 11.01
  widget mirror registers once) and must keep receiving the next owner's
  publishes after sign-in; `cachedSnapshot` additionally fails closed on its
  own (returns `nil` unless the cache's owner binding still matches the live
  one), so even a caller that forgot to reset cannot leak a prior owner's
  snapshot.
- Failure isolation: `publish` re-verifies `expectedOwnerBinding` before
  output (a), again before building the shared (b)/(c) snapshot, and again
  before touching the cache/observers — so a sign-out/account-switch race
  during either await cannot leak or cache another owner's data. (a) is
  wrapped in its own `do/catch`; a failing/throwing notify never blocks (b)/(c).
  (b)/(c) share one `makeSnapshot` build so the cache and every observer see
  the identical value; a build failure leaves the prior good cache completely
  untouched (never partially overwritten) and skips every observer for that
  pass. Each registered observer runs in its own `do/catch`, so one throwing
  observer cannot block or corrupt delivery to the others or the cache.
- Simulated-pass matrix -> test citation:
  - success (all three outputs fire, cache/observer see the exact committed
    input) -> `BackgroundRefreshTests` "success:" block.
  - offline / signed-out / failed-table (the seam's pull closure is never
    reached) -> proven at the coordinator level by
    `SyncCoordinatorTests`' existing `offlinePullCount == 0`,
    `signedOutPullCount == 0`, and `environmentPullCount == 0` assertions
    around `.offline`/`.notAuthenticated`/`.failed(remaining:)` — every one of
    those guards in `AppStore.pullDeltaIfPossible` runs strictly before this
    task's `publish` call, so the same proof carries over; `run-sync-coordinator-tests.sh`
    was not modified and stays green.
  - `.alreadyRunning` -> `SyncCoordinatorTests`' existing "already-running"
    assertions (`sync()` returns `.alreadyRunning` without a second `runOnce`,
    hence without a second pull) — unchanged, still green.
  - expiration mid-pass -> `BackgroundRefreshTests`' existing
    `NativeBackgroundRefreshOperation` cancellation tests (exactly-once
    completion) — unchanged; the seam does not check `Task.isCancelled`,
    matching `pullDeltaIfPossible`'s pre-existing style (a durable commit that
    already landed is real committed truth regardless of a later cancel).
  - one output failing -> `BackgroundRefreshTests`' "isolated" blocks: a
    throwing notify hook, a throwing snapshot build (with a prior good cache
    proven intact afterward), and a throwing observer alongside a healthy one.
  - owner-mismatch before publish and mid-publish (race after the (a) await)
    -> two more `BackgroundRefreshTests` blocks.
  - `reset()` clears cache + every observer -> another `BackgroundRefreshTests`
    block.
  - AppStore-level wiring (the network sync path itself is not exercisable in
    this swiftc host-test binary — `BuildEnvironment.supabaseURL`/
    `supabasePublishableKey` read `Bundle.main`'s Info.plist, empty here, so
    `syncCoordinatorIfConfigured()` always returns `nil`) -> a dedicated
    `StoreIntegrationTests` block calls `store.derivedStatePublisher.publish`
    directly to prove `makeCachedBusinessSnapshot` builds from real canonical
    data, the notification hook and a registered observer are reached through
    the real `AppStore` instance, owner-mismatch gating uses the store's real
    `verifiedAccountBinding`, and `reset()` clears the cache at the account
    boundary.
- Runner/build-graph changes (touches every runner that compiles `AppStore.swift`
  standalone, since it now references `NativeDerivedStatePublisher`/
  `NativeBusinessSnapshot`): added `NativeDerivedStatePublisher.swift` to
  `run-background-refresh-tests.sh`, `run-store-integration-tests.sh`,
  `run-calendar-editor-tests.sh`, `run-export-import-ui-tests.sh`,
  `run-phase9-qualification-tests.sh`, `run-pricebook-ui-tests.sh`,
  `run-schedule-booking-settings-tests.sh`; added `Domain/NativeBusinessSnapshot.swift`
  to `run-store-integration-tests.sh`, `run-export-import-ui-tests.sh`,
  `run-phase9-qualification-tests.sh`, `run-pricebook-ui-tests.sh`, plus its
  transitive `Domain/NativeCashBasis.swift`, `Domain/NativeMoneyReports.swift`,
  `Domain/NativeMileage.swift`, `Domain/NativeTaxSettings.swift`,
  `NativeTaxBreakdown.swift` to `run-calendar-editor-tests.sh` and
  `run-schedule-booking-settings-tests.sh` (the two runners with no prior
  Money-domain dependency at all).
- Device runsheet rows (10.15 folds these into `docs/native-phase-10-device-runsheet.md`;
  not created here):
  1. Step: background-refresh a signed-in device with a pending server-side
     change (another device edited a job) and Background App Refresh enabled.
     Expected: the delivered refresh reconciles notification requests to match
     the pulled snapshot (no stale/duplicate request for the edited record) and
     a subsequent coach cold-open reflects the new figures with no extra
     network round trip. Evidence: before/after `UNUserNotificationCenter`
     pending-request dump; coach system-prompt snapshot values.
  2. Step: put the device in airplane mode, wait past a scheduled refresh,
     then restore connectivity and background-refresh again. Expected: no
     notification reconcile or cache refresh happened while offline (prior
     good state intact); the next real pass reconciles/refreshes exactly
     once. Evidence: pending-request dump taken mid-airplane-mode vs. after
     reconnect.
  3. Step: sign out, then sign back in as a different account, then background-
     refresh. Expected: no notification or coach-snapshot data from the first
     account is ever visible after the second account's first real pass.
     Evidence: pending-request dump and coach cold-open content immediately
     after the second sign-in, before any manual refresh.
  4. Step: force-expire a background refresh mid-pass (Xcode's "Simulate
     Background App Refresh" then a debugger-forced expiration, or a long
     Instruments-throttled network). Expected: the system task completes
     unsuccessfully exactly once; the next delivered/foreground pass still
     reconciles to a correct set from the retained canonical snapshot, no
     duplicate notification requests. Evidence: console stage logs
     (`TradeReadyBackgroundRefresh stage=...`) bracketing the expiration, plus
     a pending-request dump after the following pass.
- Files: `N/NativeDerivedStatePublisher.swift` (new),
  `N/AppStore.swift` (`derivedStatePublisher`, `cachedBusinessSnapshot`,
  `registerDerivedStateObserver`/`unregisterDerivedStateObserver`,
  `notificationSynchronizeHook`, `makeCachedBusinessSnapshot`, the `publish`
  call in `pullDeltaIfPossible`, `derivedStatePublisher.reset()` in
  `applyCompletedSignOutState`), `N/TradeReadyNativeApp.swift`
  (`notificationSynchronizeHook` wiring), `native/BackgroundRefreshTests/main.swift`,
  `native/StoreIntegrationTests/main.swift`, and the seven runner scripts
  listed above.
- Commands / results: `TZ=America/Phoenix sh native/run-background-refresh-tests.sh`
  — "Background refresh tests passed" (0 FAIL lines; 12 new seam-matrix
  assertions plus the pre-existing policy/operation checks).
  `TZ=America/Phoenix sh native/run-sync-coordinator-tests.sh` — "PASS: native
  sync coordinator tests" (unchanged file, confirms the gating proof above
  still holds). `TZ=America/Phoenix sh native/run-notification-coordinator-tests.sh`
  — "PASS: native notification coordinator tests" (unchanged).
  `TZ=America/Phoenix sh native/run-business-snapshot-tests.sh` — "BusinessSnapshotTests:
  all checks passed" (unchanged). `TZ=America/Phoenix sh native/run-store-integration-tests.sh`
  — "PASS: canonical AppStore integration tests" (new 10.09 wiring block
  included). `TZ=America/Phoenix sh native/run-all-domain-tests.sh` and the
  Release/generic-iOS `xcodebuild` compile — see task report for the full run.
- **Fix round 1** (controller-reviewed, all findings verified and fixed in
  one pass): the review found the "exactly once" claim above was not
  structural (`pullDeltaIfPossible` has 7 direct callers besides the
  coordinator's pull closure — a reschedule published twice for one
  logical operation with no ordering guard), the cache was not cleared at
  every account boundary (`useAnotherAccount`/`applyRecoverySignedOutState`
  left it readable for the next owner), a stale-resuming publish could
  overwrite a newer one's cache/observers, `reset()` wrongly dropped
  observer registrations (breaking the 11.01 widget mirror across
  sign-out/sign-in), the real call sites were untested, booking-intake
  never republished its own post-intake commit, and a redundant
  post-`makeSnapshot` owner check had no suspension before it. Ruling: the
  contract becomes "exactly once per committed canonical sync commit" (see
  above); a monotonic generation counter in `NativeDerivedStatePublisher`
  guards ordering; `cachedSnapshot` is now owner-scoped and fails closed;
  `reset()` clears only the cache; the redundant post-`makeSnapshot` check
  was removed (no suspension occurs between it and the prior check, so it
  was provably dead weight). Fixed: `NativeDerivedStatePublisher.swift`
  (generation guard, owner-scoped fail-closed `cachedSnapshot`, `reset()`
  semantics); `AppStore.swift` (`useAnotherAccount` and
  `applyRecoverySignedOutState` now call `derivedStatePublisher.reset()`;
  `runBookingIntakeAfterVerifiedPull` publishes a second time from its own
  post-intake commit; `beginInitialSyncGate`'s initial-full-sync commit —
  previously not wired to the seam at all — now publishes too; every
  misleading "single funnel"/"ONE call site" doc comment corrected).
  New tests drive the REAL call sites through `ScheduleBookingTestDelta`:
  a committed delta pull publishes exactly once; a partial pull (failed
  tables, other tables committed) still publishes; the owner-changed-
  during-the-network-await pre-commit failure publishes nothing (the
  other three pre-commit diagnostic codes — `pull/local-commit`,
  `pull/cursor-commit`, `pull/authentication`/`pull/session` — are not
  independently forceable in this harness without a new filesystem/network-
  failure test seam, out of scope for this round; each sits behind an
  unconditional `return` positioned, in source, before the `publish` call,
  the same structural guarantee already relied on for the offline/signed-
  out cases); the booking-intake commit republishes post-intake data (a
  second, distinct snapshot with the new customer, superseding the pull's
  pre-intake one). Account boundary: a real `cancelPasswordRecovery()`
  (the production entry point to `applyRecoverySignedOutState`) and a real
  `useAnotherAccount()` — via a NEW test-only seam,
  `scheduleBookingTestSeedIdentityActivator`, that injects a minimal
  `NativeAuthenticatedIdentityActivator` so `useAnotherAccount()` reaches
  its success path (its `clearSession()` call is Keychain-only, no
  network/App-Group access, so the injected verifier is never actually
  invoked) — each clear `cachedBusinessSnapshot` while a previously-
  registered observer still fires on the next publish after sign-in. The
  real `signOut()` is deliberately NOT exercised: first attempted, it hung
  indefinitely in this host-test binary (`sample`d mid-hang; the stack
  showed `AppStore.signOut` -> `performLocalAccountScrub` ->
  `NativeAppGroupAccountScrubber.scrub()` blocked in `mkdirat`, trying to
  create the App Group container directory with no App Group entitlement in
  a plain `swiftc` binary) — a genuine, newly-discovered harness hazard, not
  a scope decision. `applyCompletedSignOutState`'s boundary is instead
  proven by calling its one relevant line
  (`derivedStatePublisher.reset()`) directly on the same store instance, the
  established pattern this file already used before this fix round. The
  generation guard itself (an older publish resuming after a newer one
  completes must not overwrite it) is unit-tested in
  `BackgroundRefreshTests` with a controlled continuation-based race. The
  initial-full-sync publish added to `beginInitialSyncGate` is not
  exercisable end-to-end in this harness: that function's own first guard
  requires `BuildEnvironment.supabaseURL`/`supabasePublishableKey` non-nil,
  which — same pre-existing constraint noted throughout this task — are
  always `nil` in a plain `swiftc`-compiled binary, so the function returns
  before ever reaching the `Task` closure the publish call lives in; the
  fix was verified by code inspection (identical shape/position to the
  already-tested `pullDeltaIfPossible` publish call) rather than a live
  test. (The original 10.09 report's §9/§10 called the
  `useAnotherAccount`/`applyRecoverySignedOutState` gap "out of scope" —
  that was superseded by this fix round: both are now covered, one for
  real, one via a purpose-built test seam; only `signOut()`'s own App
  Group scrub and the network-sync/initial-sync paths remain genuinely
  undrivable here, for the reasons given above.)
  Commands: `TZ=America/Phoenix sh native/run-background-refresh-tests.sh`
  — "Background refresh tests passed" (generation-guard + fail-closed-cache
  + observer-survives-reset assertions added). `TZ=America/Phoenix sh
  native/run-store-integration-tests.sh` — "PASS: canonical AppStore
  integration tests" (real-call-site fix-round-1 block added).
  `TZ=America/Phoenix sh native/run-sync-coordinator-tests.sh` — "PASS:
  native sync coordinator tests" (unchanged). `TZ=America/Phoenix sh
  native/run-notification-coordinator-tests.sh` — "PASS: native
  notification coordinator tests" (unchanged). `TZ=America/Phoenix sh
  native/run-all-domain-tests.sh` — 0 FAIL lines across every Swift host-test
  runner plus `backend-workers`' 26/26 `npm test`. Release/generic-iOS
  `xcodebuild -project native/TradeReadyNative.xcodeproj -scheme
  TradeReadyNative -configuration Release -destination
  'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build` — `** BUILD
  SUCCEEDED **`, 0 `error:` lines. `sh native/run-doc-reference-check.sh`
  re-run after this fix round's doc edit: 0 missing. See the fix-round-1
  report addendum for the full run detail.
- **Fix round 2** (controller-reviewed): the re-review marked all 7 round-1
  findings ADDRESSED but found round 1's own fix introduced a new race in
  `beginInitialSyncGate`'s `Task`: the new publish call sat BEFORE
  `markInitialSyncCompleted(subject:)`/`advancePastInitialSync(...)`, and
  `publish` genuinely suspends in production (it awaits
  `notifySynchronize`). A concurrent identity change landing during that
  await — sign-out, `useAnotherAccount`, recovery cancel, or another
  foreground `activateMigratedAuthenticatedIdentity` bumping
  `initialSyncGateGeneration` — would let `publish` correctly bail on its
  own owner/generation guard, but the stale task would then resume past
  the await and still stamp `initialSyncCompletedSubject`, kick a backfill
  and `syncNowAndWait`, and let `advancePastInitialSync` overwrite
  `authenticationGateState`, all for a subject/generation no longer
  current. Also flagged: the `derivedStatePublisher` doc comment at
  AppStore.swift (~5262) still claimed "the single post-sync-commit seam...
  its only caller is `pullDeltaIfPossible`", false since round 1 added two
  more publish sites. Fix (the reviewer's preferred option): moved the
  publish call to run AFTER `markInitialSyncCompleted`/
  `advancePastInitialSync` (still publishing the committed initial-sync
  snapshot) instead of before, so there is no suspension point left between
  the closure's subject/generation guard and gate completion — nothing for
  a concurrent identity change to race against there any more; the publish
  call itself still re-checks the owner binding via
  `derivedStatePublisher.publish`'s own guard, so it safely no-ops if the
  account changed between gate completion and that line running. Corrected
  the stale doc comment to describe the real multi-site "exactly once per
  committed canonical sync commit" contract (3 publish sites:
  `pullDeltaIfPossible`, `beginInitialSyncGate`,
  `prepareBookingReschedule`'s follow-up pull) and why the generation guard,
  not a single call site, is what orders them.
  Test coverage: this exact `Task` closure remains **not drivable
  end-to-end** in the swiftc host-test harness — confirmed this round by
  tracing every real call site of `applyAuthenticatedIdentityOutcome`
  (`activateMigratedAuthenticatedIdentity`, `signIn`, `signUp`,
  `verifyEmail`, `completePasswordRecovery`, ...), each gated by a
  `BuildEnvironment.supabaseURL`/`supabasePublishableKey` guard that runs
  before any of them reach `applyAuthenticatedIdentityOutcome`, always
  `nil` in this binary; neither test seam that reaches a signed-in state
  (`scheduleBookingTestSeedSignedInOwner`,
  `scheduleBookingTestSeedIdentityActivator`) routes through
  `applyAuthenticatedIdentityOutcome` either — both bypass it by design.
  Pinned instead, per the reviewer's fallback instruction: a new
  `StoreIntegrationTests` test calls the real
  `activateMigratedAuthenticatedIdentity()` — the exact entry point the
  finding named as a race trigger — and asserts it stops at its
  `BuildEnvironment` guard (`authenticationGateState == .unavailable`, zero
  `notifySynchronize` calls, `cachedBusinessSnapshot` still nil), proving
  that guard still holds as the boundary the reordering fix depends on.
  What remains unproven by any automated test here: the reordering's actual
  runtime effect inside the `Task` body (that a real concurrent identity
  change during the real `notifySynchronize` await no longer corrupts gate
  state) — verified instead by static reading of the diff (no `await`
  between the subject/generation guard and
  `markInitialSyncCompleted`/`advancePastInitialSync`) and by the
  pre-existing generation-guard test covering `publish`'s own internal
  ordering guard. Device-level verification remains deferred to Phase 12,
  same as the rest of network sync.
  Commands (foreground, no background monitors, per the coordinator's
  explicit instruction — `run-all-domain-tests.sh` skipped this round since
  no runner's file list changed): `TZ=America/Phoenix sh
  native/run-background-refresh-tests.sh` — "Background refresh tests
  passed". `TZ=America/Phoenix sh native/run-store-integration-tests.sh` —
  "PASS: canonical AppStore integration tests" (new fix-round-2 guard-pin
  test added; same two pre-existing unrelated warnings as before). `TZ=
  America/Phoenix sh native/run-sync-coordinator-tests.sh` — "PASS: native
  sync coordinator tests". Release/generic-iOS `xcodebuild -project
  native/TradeReadyNative.xcodeproj -scheme TradeReadyNative -configuration
  Release -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO
  build` — `** BUILD SUCCEEDED **`, 0 `error:` lines.
- Blockers: none. Device delivery evidence remains a Phase 12 row (rows
  drafted above for 10.15 to fold in).
- Next-ready: **10.11** (Today UI — can now assume the background/foreground
  seam keeps derived state current without any UI-triggered refresh of its
  own) and **11.01** (Phase 11 widget mirror — plugs into
  `AppStore.registerDerivedStateObserver`, receiving the same committed
  `NativeBusinessSnapshot` the coach cache uses).

### 10.10 — Coach transport, provider routing, and system prompt

- Status: **Code complete / Phase 12 evidence deferred (live AI providers).**
- Files: `native/TradeReadyNative/NativeCoachTransport.swift` (provider
  precedence — Anthropic key -> Groq key -> backend proxy — the three
  transports against `/v1/messages`, `api.groq.com`, and the live
  `backend-workers/src/routes/aiChat.js` `/api/ai-chat` route, `MAX_HISTORY`
  = 20 truncation, and a typed `NativeCoachTransportError` mirroring RN's
  throw contract), `native/TradeReadyNative/Domain/NativeCoachPrompt.swift`
  (`buildSystemPrompt` port), `native/TradeReadyNative/Domain/NativeChatMarkdown.swift`
  (`formatChatText` port), `native/TradeReadyNative/Domain/NativeCoachQuickPrompts.swift`
  (`getQuickPrompts` port); `native/CoachTransportTests/main.swift`,
  `native/CoachPromptTests/main.swift`, `native/ChatMarkdownTests/main.swift`
  and their `native/run-coach-transport-tests.sh`,
  `native/run-coach-prompt-tests.sh`, `native/run-chat-markdown-tests.sh`
  runners (not yet registered in `run-all-domain-tests.sh` per the global
  constraint — 10.15 owns that).
- Interface handoff (10.13's adoption contract): `NativeCoachTransport` takes
  an injected `NativeCoachHTTPDataLoading` loader (the same
  `async throws -> (Data, URLResponse)` seam as `NativeInvoiceDelivery.swift`,
  not the synchronous-bridge pattern in `NativeAITransport.swift`) plus a
  per-call `backendBaseURL`/`sessionBytes` — it has no `.live()` factory and
  no `BuildEnvironment`/Keychain dependency, so 10.13 constructs it with
  `NativeCoachTransport(backendBaseURL: BuildEnvironment.backendBaseURL)` and
  passes the Keychain-read Supabase session bytes at call time, mirroring how
  `AppStore.swift` already wires `NativeInvoiceDeliveryService`.
  `sendMessage(messages:systemPrompt:anthropicKey:groqKey:sessionBytes:)`
  is the one entry point 10.13 calls; it throws `NativeCoachTransportError`
  exactly where RN throws (missing key, provider error, empty response,
  backend not configured/signed out, transport failure), and 10.13's `catch`
  should render `"Something went wrong: \(error.message)"` as the `isError`
  bubble — this is a drop-in replacement for the prototype `CoachService.reply`
  in `CoachView.swift` (not edited by this task). `NativeCoachPrompt.buildSystemPrompt(settings:snapshot:)`
  takes `Canonical.Settings` and the optional `NativeBusinessSnapshot` (10.01)
  directly — 10.13 builds the prompt once per send and passes it as
  `systemPrompt` to `sendMessage`. `NativeCoachQuickPrompts.quickPrompts(snapshot:)`
  returns the four `NativeCoachQuickPrompt` cards in order; 10.13 renders them
  with no branch logic of its own. `NativeChatMarkdown.formatChatText(_:)` is
  a pure `String -> String` transform 10.13 applies to every assistant bubble
  before display.
- Commands / results:
  `TZ=America/Phoenix sh native/run-coach-transport-tests.sh` — all checks
  passed (provider precedence; Anthropic/Groq/backend success + exact request
  shape/headers/model-constant assertions; missing-key typed errors with RN's
  exact copy; provider `error` surfacing for all three transports;
  unparseable/empty-response typing; `MAX_HISTORY` truncation to the last 20
  for both Anthropic and Groq; backend not-configured, sign-in-required for
  every malformed/absent session shape, non-2xx surfacing, and a network-level
  loader failure; end-to-end `sendMessage` routing; a fixture proving no
  secure key ever appears in a thrown error's message or the Anthropic request
  body). `TZ=America/Phoenix sh native/run-coach-prompt-tests.sh` — all checks
  passed (no-snapshot minimal settings; unmatched-trade-id "Trades" fallback
  with an empty `contactName` dropped from "who"; a full snapshot with
  overdue/top-customers/active-jobs/tax-known; a snapshot with the tax block
  entirely absent; a snapshot with tax present but both rate-unknown caveats
  firing; an all-zero/empty snapshot; the overdue singular/plural boundary; a
  fixture proving no secure key ever enters the built prompt; every
  `getQuickPrompts` branch — no-snapshot fallback, live overdue+avgJob, and
  the overdue-singular case). `TZ=America/Phoenix sh native/run-chat-markdown-tests.sh`
  — all checks passed, every vector copied verbatim from
  `__tests__/chatMarkdown.test.ts`. RN oracle re-run:
  `TZ=America/Phoenix npm test -- --runInBand --runTestsByPath
  __tests__/chatMarkdown.test.ts __tests__/estimateSnapshot.test.js` — 2
  suites / 19 tests, all passing, no oracle file touched.
  `TZ=America/Phoenix sh native/run-business-snapshot-tests.sh` (10.01
  regression check, since `NativeCoachPrompt`/`NativeCoachQuickPrompts` sit on
  top of `NativeBusinessSnapshot`) — all checks passed.
  `xcodebuild … Release … CODE_SIGNING_ALLOWED=NO build` — **BUILD SUCCEEDED**,
  no warnings in the four new files.
- No RN oracle test file exists for `buildSystemPrompt`/`getQuickPrompts`
  (both are private functions inside `screens/ChatScreen.tsx`, not exported,
  and neither is unit-tested in `__tests__/`). Every fixture pinned in
  `CoachPromptTests` was captured by copying the exact function bodies —
  including the `TRADE_TYPES` table from `utils/pricingEngine.ts` — into a
  scratch Node probe, running it, and recording the actual printed output; the
  probe was deleted afterward and no `screens/`/`utils/` file was modified.
- Recorded RN behavior reproduced deliberately (reads like a bug, is not one):
  the `BUSINESS DATA (...)` block is built as its own template literal
  starting with `"\n\n"` and then `.trim()`-ed BEFORE being concatenated onto
  the rate/prompt prefix — the leading blank line is trimmed away, so
  `"USD only."` is followed immediately by `"BUSINESS DATA"` with **no**
  space or line break between them. The tax block, appended afterward with
  its own un-trimmed leading `"\n"`, does keep a line break before
  `"Tax set-aside estimate:"`. Confirmed by running the actual RN function
  (not inferred from reading the source) and pinned as a fixture
  (`testFullSnapshot`) so a future "fix" of this concatenation does not slip
  through unnoticed as a silent behavior change.
- Recorded intentional native difference: RN's `activeJobsByStatus` is a
  plain object whose `Object.entries()` order is "the order statuses were
  first encountered while iterating the jobs array" — information
  `NativeBusinessSnapshotEngine` (10.01) does not preserve, because its
  `activeJobsByStatus` is a Swift `[String: Int]` (unordered), built to the
  same "only non-zero statuses present" partial-record contract RN uses. No
  RN oracle test pins the status-line order inside the prompt text itself
  (`businessSnapshot.test.js` only asserts the status/count map with
  `toEqual`, which does not care about key order), so `NativeCoachPrompt`
  renders statuses in a fixed, documented pipeline order
  (`lead, estimate_sent, approved, scheduled, in_progress`) rather than an
  order that cannot be recovered from the already-collapsed dictionary.
- Recorded native addition (not a divergence from any pinned behavior): the
  Anthropic/Groq/backend transport failures are surfaced as a typed
  `NativeCoachTransportError` rather than an untyped `Error`/exception, and a
  network-level loader failure (a thrown error from the injected loader) is
  normalized to `.unavailable` rather than propagated as an opaque underlying
  error — RN does not wrap `fetch` in `try/catch` at all for the two direct
  providers, so a raw network exception's `.message` would otherwise leak
  through verbatim. This is a stricter, still RN-compatible typed-result
  contract per the task brief's "return a typed result the UI renders as an
  error bubble or fallback" instruction, and it never changes the text shown
  for a provider- or backend-authored error (those pass through untouched via
  `.providerError(String)`).
- Next-ready: 10.13 (Coach UI and contextual prefill) — this task's
  `NativeCoachTransport`, `NativeCoachPrompt`, `NativeChatMarkdown`, and
  `NativeCoachQuickPrompts` are the full pure/service contract 10.13 needs;
  10.11/10.12 remain unaffected and unblocked by this task.

### 10.11 — Today UI integration

- Status: **Code complete.** Setup-checklist and insights slots are
  intentional `EmptyView()` hooks; 10.12 fills them per the plan's phasing.
- Files: `native/TradeReadyNative/TodayView.swift` (rewritten — week strip,
  stats row, first-action hero, booking-attention rows, overdue/follow-up
  briefing sections, awaiting-estimate row, selected-day schedule, header
  actions, pull-to-refresh), `native/TradeReadyNative/NativeTodayComponents.swift`
  (new — the row/card/section view library `TodayView` composes:
  `NativeTodayWeekStripView`, `NativeTodayStatsRowView`,
  `NativeTodayHeroCardView`, `NativeTodaySetupChecklistSlot`,
  `NativeTodayInsightsSlot` (both `EmptyView()` today),
  `NativeTodayBookingAttentionRow`, `NativeTodayBriefingSection`,
  `NativeTodayOverdueInvoiceRow`, `NativeTodayLeadRow`, `NativeTodaySeeMoreRow`,
  `NativeTodayListCard`, `NativeTodayJobCard`, `NativeTodayScheduleStop`,
  `NativeTodayEmptySchedule`), `native/TradeReadyNative/AppStore.swift`
  (added `todaySelectedDate` published state — `selectedTab` already existed
  and is only reused here, a
  `today*` computed-property section reusing 10.01's canonical projections
  and 10.04's `NativeTodayBriefing`/10.02's `NativeTodayInsights`,
  `selectTodayDate`/`shiftTodaySelectedWeek`, the `NativeTodayRouteResult`
  enum, and `routeToToday(_:)` — the destination router; also resets
  `todaySelectedDate` on the sign-out/account-boundary path),
  `native/StoreIntegrationTests/main.swift` (router, one-shot, and
  selected-day/week-nav host tests, appended before the final `PASS`/`FAILED`
  summary). Six existing standalone runners
  (`run-calendar-editor-tests.sh`, `run-export-import-ui-tests.sh`,
  `run-phase9-qualification-tests.sh`, `run-pricebook-ui-tests.sh`,
  `run-schedule-booking-settings-tests.sh`, `run-store-integration-tests.sh`)
  had `Domain/NativeTodayInsights.swift` and `Domain/NativeTodayBriefing.swift`
  added to their `swiftc` file lists, since `AppStore.swift` now references
  both.
- Interface handoff (10.12's adoption contract): `NativeTodaySetupChecklistSlot`
  and `NativeTodayInsightsSlot` are empty `View` structs placed in `TodayView.body`
  at RN's exact positions (checklist slot right after the hero card, insights
  slot right after the checklist slot, both before the booking-attention
  rows) — 10.12 fills their bodies directly (same file, same struct names) or
  swaps them for real content without touching `TodayView.swift`'s layout.
  `AppStore.routeToToday(_:)` is the one router both 10.11's rows and 10.12's
  checklist/hero/insight cards call — it takes any `NativeTodayDestination`
  (10.04) and returns a `NativeTodayRouteResult`: `.handled` for cases that
  already mutated store state (tab switch + one-shot deep link, or
  `todaySelectedDate`), or a `.present*` case the caller turns into a local
  `@State` sheet toggle exactly as `TodayView.handle(_:)` already does. 10.12
  passes `sampleTourDone: false` into `NativeTodayBriefing.hero` today (via
  `AppStore.todayHero`) because `AppStore` does not yet expose
  `NativeSetupChecklistStore`'s persisted `sampleTourDone` — 10.12 owns wiring
  that store in and flipping this to the real value.
- Commands / results: `TZ=America/Phoenix sh native/run-store-integration-tests.sh`
  — `PASS: canonical AppStore integration tests` (includes the new 10.11
  router/nav block: every `NativeTodayDestination` case, fail-closed on
  missing/archived job/customer/invoice ids and malformed dates, one-shot
  deep-link clearing when routing to a new target, `selectTodayDate`/
  `shiftTodaySelectedWeek` valid/invalid/±7 behavior, and a
  `performPullToRefresh()` call confirming it reports no outcome rather than
  a fabricated success when no sync coordinator is configured).
  `TZ=America/Phoenix sh native/run-today-briefing-tests.sh` — all checks
  passed (10.04 regression, unaffected). `TZ=America/Phoenix sh
  native/run-global-search-tests.sh` — `PASS: native global search tests`
  (regression check for the shared one-shot deep-link pattern `routeToToday`
  reuses). `TZ=America/Phoenix sh native/run-export-import-ui-tests.sh`,
  `run-phase9-qualification-tests.sh`, `run-pricebook-ui-tests.sh` — all
  passed after the `NativeTodayInsights`/`NativeTodayBriefing` file-list fix.
  `TZ=America/Phoenix npm test -- --runInBand --runTestsByPath
  __tests__/TodayScreenSettingsGear.test.tsx __tests__/crossTabNavigation.test.tsx`
  — 2 suites / 3 tests passing. `TZ=America/Phoenix sh
  native/run-all-domain-tests.sh` — passing (26 backend-workers tests plus
  the Swift device-preflight and store-integration runners it chains).
  `xcodebuild … Release … CODE_SIGNING_ALLOWED=NO build` — **BUILD SUCCEEDED**,
  0 `error:` lines for the whole app target.
- Blocker found and deliberately NOT fixed in this task: `run-calendar-editor-tests.sh`
  and `run-schedule-booking-settings-tests.sh` were already missing
  `NativeImportHistory.swift` from their `swiftc` file lists before this task
  started (confirmed via `git diff --stat` — this task's edit to each file
  only adds the two `NativeTodayInsights`/`NativeTodayBriefing` lines, no
  removals), so both fail with `error: cannot find 'NativeImportHistory' in
  scope` unrelated to anything Today-specific. Flagged as a follow-up task
  (`task_a8b8157d`) rather than fixed inline, to keep this task's diff scoped
  to Today UI.
- Recorded native difference: `.onMyWay(jobId:)` routes through the existing
  on-my-way review sheet (`requestOnMyWayReview`, the same path the
  notification-tap flow already uses) instead of duplicating RN's
  channel-aware composer-launch logic (`utils/appointmentSend.ts` builds the
  templated body, then `utils/messaging.ts`'s `composeSMS`/`composeEmail`
  opens the OS SMS or Mail composer pre-filled — RN still requires the owner
  to review and hit send there, it is not a silent background send). Native's
  review sheet serves the same "owner reviews before it goes out" purpose
  through existing Phase 8/9 infrastructure rather than a second parallel
  composer-launch path, and surfaces a "no customer phone" failure through
  that sheet's own UI rather than a bare native alert.
  Booking-alert multi-action prompts (`reschedule_requested` needs 4 actions:
  View job / I've rescheduled it / Decline booking / Cancel) use SwiftUI's
  `.confirmationDialog` rather than `Alert`, since `Alert` supports at most
  two buttons; row/alert copy is otherwise byte-identical to
  `screens/TodayScreen.tsx`'s `handleBookingRowPress`/`bookingRowLabel`.
  `.route` presents the already-shipped, previously-orphaned Phase 8
  `NativeRouteView()` — no new maps/routing code was written.
- Next-ready: **10.12** (setup checklist, hero, and insights cards — the two
  slot views and `sampleTourDone` wiring described above are ready for it)
  and, once 10.12 lands, **10.13** (Coach UI, already unblocked on the
  10.10 side).

**Fix round 1** (post-review):

- Fixed inconsistent fail-closed archived checks: `.createInvoice`,
  `.schedule`, and `.onMyWay` only checked `jobs.contains(id)` with no
  archived guard, while `.job`/`.customer` verified `archivedAt` was empty —
  a since-archived job's `createInvoice`/`schedule`/`onMyWay` destination
  could open against it. Added `AppStore.isLiveTodayJob(_:)`, a single
  private helper every job-based `routeToToday` case now calls, so the
  archived guard exists once rather than being duplicated per-case (and
  therefore cannot silently drift out of sync again). Added archived and
  missing tests for `.createInvoice`, `.schedule`, and `.onMyWay` to
  `StoreIntegrationTests/main.swift` alongside the existing `.job`/`.customer`
  coverage.
- `routeToToday`'s `.selectDate` case now calls `selectTodayDate(_:)` instead
  of duplicating its guard-and-assign body inline.
- Moved `nativeTodayBookingRowLabel` out of `NativeTodayComponents.swift`
  (a view-support file) into `NativeTodayBriefing.swift` as
  `NativeTodayBriefing.bookingRowLabel(_:)`, a pure static function next to
  `bookingRowPresentation(_:)`. Added `TodayBriefingTests/main.swift`
  coverage: reschedule/cancelled short-date-only labels, the portal-change
  copy (which ignores the slot date entirely), and the native-only
  `missingJob` fallback to `bookingRowPresentation(_:).summary`.
- Corrected the `.onMyWay` rationale (here and in the report): RN does not
  send silently — `utils/appointmentSend.ts` builds the templated message
  and `utils/messaging.ts`'s `composeSMS`/`composeEmail` open the OS SMS or
  Mail composer pre-filled, still requiring the owner to review and hit send.
  Native's on-my-way review sheet serves the same review-before-send purpose
  through existing infrastructure, not a same-vs-silent shortcut.
- Corrected the `selectedTab` claim: it already existed on `AppStore` before
  this task; only `todaySelectedDate` is new published state.
- Fix round 1 wired `NativeContentState`/`NativeContentStateView` into
  `TodayView` for what was believed to be a residual gap in the first-action
  hero. **Fix round 2 removed this wiring**: the review correctly found it
  was dead code. `NativeTodayBriefing.hero(jobs:customers:sampleTourDone:)`
  (`Domain/NativeTodayBriefing.swift`) opens with
  `let realJobs = jobs.filter { !isSampleId($0.id) }; guard realJobs.isEmpty
  else { return nil }` — so `hero` is `nil` if and only if at least one real
  job already exists, which makes `jobs.count + customers.count +
  invoices.count == 0` impossible whenever `hero == nil` (a real job is one
  of those jobs). There is no residual case; the overlay's `.empty` branch
  could never render, and the doc comment describing a "sample-tour-done"
  edge case was simply wrong about which side of the `guard` returns `nil`.
  Removed `TodayView.contentState`, the `.overlay { NativeContentStateView(...) }`
  modifier, and the explanatory comment.
  **Controller ruling, recorded here per instruction:** Today has exactly two
  empty states, both already covered without `NativeContentState`:
  - **No jobs anywhere (fresh account):** the first-action hero
    (`NativeTodayHeroCardView`, driven by `store.todayHero`) — "Add Your
    First Customer" / "Create Your First Job" / the sample-tour card — at
    RN's exact screen position. This is Today's only account-wide empty
    state, and it already has a purpose-built, RN-matching presentation.
  - **Selected day has no jobs:** `NativeTodayEmptySchedule`, rendered by
    `scheduleSection` when `store.todaySelectedDaySchedule.isEmpty` — RN's
    own `EmptySchedule` component, ported directly.
  No `NativeContentState` case maps onto either: `.empty`/`.noMatches` are
  built for a single filtered list (JobsView/CustomersView/InvoicesView's
  pattern), and Today is a composite dashboard whose sections each already
  own their empty presentation; `.loading` cannot occur post-`RootView`
  initial-sync gate; `.error` has no RN behavior to port (RN's
  `fetchTodayData` catch only logs) and would duplicate the app-wide
  `NativeSyncBanner`, which `NativeInteractionState.swift`'s own doc comment
  says already owns background-failure surfacing. `NativeContentState` has
  no reachable Today state; its reuse item from the brief is satisfied by
  confirming this rather than by wiring in dead code.
- Commands / results (fix round 1):
  `TZ=America/Phoenix sh native/run-store-integration-tests.sh` —
  `PASS: canonical AppStore integration tests` (includes the new archived/
  missing `.createInvoice`/`.schedule`/`.onMyWay` cases).
  `TZ=America/Phoenix sh native/run-today-briefing-tests.sh` —
  `All NativeTodayBriefing tests passed` (includes the new `bookingRowLabel`
  cases). `xcodebuild … Release … CODE_SIGNING_ALLOWED=NO build` —
  **BUILD SUCCEEDED**. `sh native/run-doc-reference-check.sh` — `937 path
  references checked: 0 missing, 59 planned (not yet created)`. No runner
  `swiftc` file list changed in this round, so `run-all-domain-tests.sh` was
  not re-run.

**Fix round 2** (re-review — the one open finding): `TZ=America/Phoenix sh
native/run-store-integration-tests.sh` — `PASS: canonical AppStore
integration tests`. `TZ=America/Phoenix sh native/run-today-briefing-tests.sh`
— `All NativeTodayBriefing tests passed` (both unaffected by a
`TodayView.swift`-only removal; re-run to confirm no regression).
`xcodebuild … Release … CODE_SIGNING_ALLOWED=NO build` — **BUILD SUCCEEDED**.
`sh native/run-doc-reference-check.sh` — `939 path references checked: 0
missing, 59 planned (not yet created)`. No test file or runner file list
changed in this round (the fix was a deletion in `TodayView.swift` only), so
no new test coverage was added and `run-all-domain-tests.sh` was not re-run.
