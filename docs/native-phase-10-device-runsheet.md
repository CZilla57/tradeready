# Phase 10 Device Runsheet (scheduled for Phase 12)

Per the 2026-09-16 deferral decision, the physical-device, live-endpoint, and
permission-dialog rows below are **scheduled work for Phase 12 TestFlight/beta**,
not per-phase gates. Host evidence (focused Swift runners, the RN oracle suites,
the aggregate suite, the unsigned Release build, and — where a signing identity is
available — the signed Release build) gates code-complete; the rows here gate
`Verified`.

Scope: Phase 10 (Today surface, proactive insights, AI coach, notifications, and
the post-sync derived-state seam) — see
[native-phase-10-implementation-plan.md](native-phase-10-implementation-plan.md)
for per-task evidence and
[native-phase-10-today-coach-notifications-contract-decisions.md](native-phase-10-today-coach-notifications-contract-decisions.md)
for the frozen contracts and recorded native/RN deviations.

Conventions: `[ ]` open, `[x]` passed with evidence link/date. Record device
model, iOS version, account type, and build ID per row. Use synthetic data in a
staging/TestFlight account; never production customer data.

## Open implementation gates

These are **not** device-evidence rows — they are named, unresolved gaps in the
host-testable implementation itself, carried forward from the progress ledger's
Parked / Deferred-minors lines so they stay visible and are never silently
waived. Each is labeled **implementation gate (host-testable), not device
evidence** except where a row is inherently device-only (noted per item). They
also appear inline in the relevant section below and in the roadmap's Phase 10
entry.

1. **10.12 I4 — Stripe account-switch write race** *(implementation gate
   (host-testable), not device evidence)*: `markSetupTaskDoneIfStripeConnected`
   racing a Stripe status refresh against an account switch is proven today
   only through the pure `stripeTaskWriteAllowed` predicate (four cases), not
   end-to-end — `configuredStripeConnectService()` has no injectable transport
   seam a test can use to control timing. See the "Proactive insights" section
   below for the device-verification row.
2. **10.13 — Coach `sending` stuck-flag boundary** *(implementation gate
   (host-testable), not device evidence)*: `sending` can remain stuck `true`
   if `CoachView` ever survives an account boundary without RootView's
   existing teardown running first. Unreached today because RootView always
   tears the view down on sign-out/account-switch — no test forces the
   boundary the other way. See the "AI coach" section below.
3. **10.09 (a) — stale cache on a failed later publish** *(implementation gate
   (host-testable), not device evidence)*: if a newer post-sync publish fails
   inside `makeSnapshot`, the cached `NativeBusinessSnapshot` is left on an
   older snapshot than the one that was actually committed (fail-safe — the
   next successful commit corrects it, but the window itself is untested).
   Lower impact since final-review I2: the coach no longer reads the cache,
   so only derived-state observers could see the older snapshot.
4. **10.09 (b) — three pre-commit failure codes have no forcing test**
   *(implementation gate (host-testable), not device evidence)*: the
   diagnostic codes `pull/local-commit`, `pull/cursor-commit`, and
   `pull/authentication` (`pull/session`) each sit behind an unconditional
   `return` positioned, in source, before the derived-state `publish` call —
   the same structural guarantee already relied on for the tested
   offline/signed-out/owner-changed cases — but no automated test
   independently forces any of the three codes to prove the guard holds at
   that exact boundary.
5. **10.09 (c) — CLOSED (final-review I6, 2026-09-23).** The post-sync
   publish used to run when `advancePastInitialSync` ended in
   `.accountMismatch`/`.unavailable`. Every publish site and the publisher's
   owner re-check now use the exact-workspace predicate
   `AppStore.derivedStatePublishBinding`, and `registerDerivedStateObserver`
   documents the owner contract (observers fire only for an exact workspace —
   an explicit 11.01 entry precondition). Forcing test: the "I6" block in
   `native/StoreIntegrationTests/main.swift`. Kept in this list for history.

## Today

- [ ] Day/week schedule strip and day selection match the RN week/day projection, including the current-day default and empty-selected-day row
- [ ] Stats row (earnings, overdue, leads) matches RN's figures for the same account/date (screenshot pair)
- [ ] Overdue-invoice and follow-up/lead briefing sections show the exact caps, see-more, and route to the correct record
- [ ] Booking/portal attention rows render their contextual actions and self-dismiss once resolved, including the native-only `missingJob`/`unconvertedActive` rows
- [ ] First-action hero appears/disappears per the sample-tour "used once" rule and its tap routes correctly
- [ ] Pull-to-refresh against staging keeps cached figures visible on a failed refresh
- [ ] Large Dynamic Type and dark mode render every Today row without truncation

## Setup checklist

- [ ] Every task's derivation and progress bar match RN for a fresh account and a fully-set-up account
- [ ] Dismissal persists device-locally and survives relaunch
- [ ] Each task's contextual settings navigation lands on the correct screen
- [ ] **In-card notification permission request** (10.12/10.05 interface handoff): tapping the `notifications` task's request affordance shows the real system permission dialog; on grant, the card updates without navigating away; on denial, the card offers "Open device settings" and the link opens Settings correctly
- [ ] Confirm the recorded `rate` task deviation (native marks done on `onDisappear` from Pricing Defaults, not on RN's discrete save) reads correctly on device — not just host-tested

## Proactive insights

- [ ] All eight insight kinds (`labor_overrun`, `low_margin_estimate`, `uninvoiced_complete`, `due_soon`, `open_slot`, `unscheduled_approved`, `maintenance_due`, `expense_anomaly`) render with correct copy, priority order, and top-three slice on a real account
- [ ] Insights card is gated behind setup completion exactly as host-tested
- [ ] Mute ("Dismiss") and snooze ("N days") persist device-locally, are owner-bound, prune on expiry, and are scrubbed at sign-out/account switch — verify on device, not just the host mute-store suite
- [ ] "Why am I seeing this?" reason sheet is reachable for **every** insight row (10.12 fix round 1, I3): through the row's long-press context menu and the VoiceOver "Why am I seeing this?" action on every row, and additionally through the ellipsis options dialog on muteable rows; each path fires `insight_reason_viewed` once and shows the insight's reason text
- [ ] **Stripe account-switch race (10.12 I4, parked)**: switching Stripe-connected accounts while a Stripe status refresh is in flight must not mark the checklist `stripe` task done for the wrong owner — this is proven today only through the pure `stripeTaskWriteAllowed` predicate (four cases), not end-to-end (no injectable Stripe service seam exists yet); exercise this manually on device against two real Stripe-connected accounts

## AI coach

- [ ] Provider routing (client Anthropic key, client Groq key, backend proxy for a signed-in user with no client key) all produce a real reply against a **live** provider — **deferred to Phase 12; only a fake transport has been exercised in host tests**
- [ ] System prompt cites the same business-snapshot figures Today shows, and never contains a secret provider key (grep the request body on device)
- [ ] Chat transcript persists in-session, respects `MAX_HISTORY`, and clears at sign-out/account switch (host-tested via the RootView teardown path; confirm no residual transcript survives an account switch on device)
- [ ] Markdown-lite rendering (bold/lists/line breaks), copy button, and the typed error bubble (network failure, malformed reply, usage-limit) render correctly on device
- [ ] **Known parked gap**: `sending` can remain `true` if the Coach view somehow survives an account boundary without RootView tearing it down (today RootView always tears it down on sign-out/account switch, so this is unreached in the current app, but verify no code path skips that teardown on device before/after backgrounding)

## Quick prompts

- [ ] Quick-prompt labels/copy are data-aware (reference real job/invoice/customer counts) and match RN for the same account
- [ ] Correct empty-state prompts show for an account with no jobs/invoices
- [ ] The Ionicons→SF-Symbol icon map (4 mapped icons + `sparkles` fallback) renders every current quick-prompt icon correctly; flag if a fifth quick-prompt icon is ever added (it would silently render `sparkles`)

## Insight handoff

- [ ] Tapping "Ask coach" from an insight opens the Coach tab with the prompt **prefilled, editable, and never auto-sent**
- [ ] The prefill is consumed exactly once (a second tab switch back to Coach does not re-fill)
- [ ] Insight-shown / insight-handoff analytics fire through the `NativeAnalytics` no-op seam today; confirm real transport (Phase 11.07/11.08) once wired

## Notifications

- [ ] All five namespaces (`est_`, `appt_`, `review_`, `inv_`, `rinv_`) actually deliver as OS notifications on device, in the documented priority order, under the shared 60-request cap
- [ ] **Invoice-reminders soft-ask alert (10.05 fix round 1, `TradeReadyNativeApp.swift` `.alert("Invoice reminders", …)` driven by the coordinator's `pendingInvoiceReminderPrompt`)** — shows once: on a fresh account with OS permission undetermined, creating the first invoice shows the "Invoice reminders" alert exactly once; a second invoice (same session or after relaunch) never shows it again
- [ ] **Soft-ask "Turn on"**: tapping "Turn on" dismisses the alert and then shows the real iOS permission dialog; on Allow, pending reminders are scheduled (one reconcile); on Don't Allow, nothing is scheduled and the alert never returns
- [ ] **Soft-ask "Not now"**: tapping "Not now" dismisses the alert, shows no iOS permission dialog, and the alert never returns for that account
- [ ] **Soft-ask silent when settled**: with OS permission already granted or denied, creating the first invoice shows no alert (the flag is still stamped)
- [ ] **Soft-ask cancelled by sign-out**: with the alert pending (trigger it, then sign out or switch account before answering), the alert is cleared on the next reconcile and never appears for the other account; the new account gets its own one-time ask
- [ ] Categories survive relaunch (registered once per launch in host tests; unverified end-to-end across app kill/relaunch on device)
- [ ] **Tap routing (10.07/10.08)**: tapping a delivered notification of each family routes to the exact still-open, owner-verified record; a stale/foreign/unrecognized payload fails closed (no navigation, no crash)
- [ ] **Archived job routing (final-review I1, contract §9.6)**: archive a job that still has a scheduled appointment and a pending review request; its Today schedule row and its delivered `appt_`/`review_` notifications still appear (RN `utils/archive.ts` parity), and tapping each one opens the job / confirmation / review draft — never a dead tap. A deleted job's notification still fails closed
- [ ] **Cold-launch notification tap (final-review m7)**: with the app killed, tap a delivered notification of each family. Record what happens: the tap is dropped (no navigation) until the auth gate resolves, because every `request…Review` route guards on the signed-in exact workspace — the same as RN, which ignores the tap until `navigationRef.isReady()` and a session exist. Confirm it does not crash, does not route to a wrong record after sign-in, and note whether the owner expects a deferred route (would be a product follow-up, not a Phase 10 defect)
- [ ] Sign-out/account-switch clears only the pending requests owned by the signing-out account; a foreign family's pending requests are preserved untouched
- [ ] Invoice-dunning auto-outreach body variant renders and never auto-sends

## Background refresh

- [ ] `BGAppRefreshTask` actually fires on device within the OS's scheduling window (30-minute-earliest reschedule) — host tests only prove the registration/scheduling logic, not real OS delivery
- [ ] **Post-sync derived-state seam (10.09, B1)**: after a real background sync pass, verify on device that (a) notifications reconcile from the committed snapshot, (b) the cached `NativeBusinessSnapshot` (now read only by derived-state observers; the coach builds from live data since final-review I2) refreshes, and (c) Today/insights reflect the new data on next foreground — the "exactly once per committed pass" guarantee is proven today only by code inspection plus `SyncCoordinatorTests`, because the swiftc host-test harness cannot construct a real `BuildEnvironment`/`Bundle.main`
- [ ] Authenticated job-photo upload/backfill still completes during a background pass that also reconciles notifications (no ordering regression)
- [ ] Expiration mid-pass still completes exactly once (no duplicate notification reconcile, no double-cached snapshot publish) — see also `native-phase-4-background-refresh.md`, which owns the underlying task lifecycle
- [ ] Signed-out/offline background pass remains a no-op for both the pre-existing sync work and the new Phase 10 reconcile/refresh hook
- [ ] **10.09 (a), implementation gate (host-testable), not device evidence**: force a `makeSnapshot` failure on a second, later publish after an earlier one already committed, and confirm whether the cache is left on the stale (older) snapshot as expected, or whether it needs a fix before Phase 12 sign-off
- [ ] **10.09 (b), implementation gate (host-testable), not device evidence**: add or run a forcing test for each of `pull/local-commit`, `pull/cursor-commit`, and `pull/authentication` to independently prove the pre-`publish` `return` guard holds at that exact boundary, not just by source inspection
- [x] **10.09 (c), implementation gate — CLOSED by the Phase 10 final-review fix wave (I6), 2026-09-23**: every publish site and the publisher's owner re-check now use `AppStore.derivedStatePublishBinding`, which is nil for `.accountMismatch`/`.unavailable` (and signed-out/recovery gates) and without a workspace bound to the verified binding. Forcing test: `native/StoreIntegrationTests/main.swift` "I6" block drives a real suspended pull, flips the gate to each state, and asserts no notification synchronize, no observer call and no cache write

## Deep links

- [ ] Every N6 notification-tap route (job, invoice, estimate, appointment, recurring-invoice, review) opens the exact native record it names
- [ ] A stale/deleted-record payload and a foreign-owner payload both fail closed (no crash, no wrong-record navigation)
- [ ] Cross-tab one-shot routing (from Today search/insights/booking rows, and from the Coach insight-handoff prefill) lands on the right tab and record exactly once, without leaving stale route state for the next unrelated navigation

## Exit checklist for Phase 12

- [ ] Every row above has device/staging evidence or an explicit, recorded waiver
- [ ] Any row that fails is recorded as a defect with the build ID, not silently waived
- [ ] The four still-open implementation gates above (10.12 Stripe account-switch race, 10.13 Coach `sending` stuck-flag boundary, 10.09 (a) stale-cache-on-failed-publish, 10.09 (b) three untested pre-commit failure codes) are either closed with a real fix or explicitly re-accepted with a dated rationale before Phase 12 exit. 10.09 (c) was closed by the final-review fix wave (I6)
- [ ] The parity matrix is updated from `In progress` to `Verified` only after the rows above pass
