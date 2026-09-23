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
- [ ] "Why am I seeing this?" reason sheet opens for every muteable/readable insight and is unreachable for the rest (matches the VoiceOver actions-rotor behavior recorded in 10.12)
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
- [ ] **Notification permission soft-ask flow (10.05, deferred)**: RN's custom "Not now / Turn on" rationale `Alert` has no native equivalent — native calls `requestAuthorization()` directly (the one system dialog) with no pre-permission rationale screen. Confirm this is an accepted product decision on device, or file a follow-up to add the rationale screen
- [ ] Categories survive relaunch (registered once per launch in host tests; unverified end-to-end across app kill/relaunch on device)
- [ ] **Tap routing (10.07/10.08)**: tapping a delivered notification of each family routes to the exact still-open, owner-verified record; a stale/foreign/unrecognized payload fails closed (no navigation, no crash)
- [ ] Sign-out/account-switch clears only the pending requests owned by the signing-out account; a foreign family's pending requests are preserved untouched
- [ ] Invoice-dunning auto-outreach body variant renders and never auto-sends

## Background refresh

- [ ] `BGAppRefreshTask` actually fires on device within the OS's scheduling window (30-minute-earliest reschedule) — host tests only prove the registration/scheduling logic, not real OS delivery
- [ ] **Post-sync derived-state seam (10.09, B1)**: after a real background sync pass, verify on device that (a) notifications reconcile from the committed snapshot, (b) the cached `NativeBusinessSnapshot` used for coach cold start refreshes, and (c) Today/insights reflect the new data on next foreground — the "exactly once per committed pass" guarantee is proven today only by code inspection plus `SyncCoordinatorTests`, because the swiftc host-test harness cannot construct a real `BuildEnvironment`/`Bundle.main`
- [ ] Authenticated job-photo upload/backfill still completes during a background pass that also reconciles notifications (no ordering regression)
- [ ] Expiration mid-pass still completes exactly once (no duplicate notification reconcile, no double-cached snapshot publish) — see also `native-phase-4-background-refresh.md`, which owns the underlying task lifecycle
- [ ] Signed-out/offline background pass remains a no-op for both the pre-existing sync work and the new Phase 10 reconcile/refresh hook

## Deep links

- [ ] Every N6 notification-tap route (job, invoice, estimate, appointment, recurring-invoice, review) opens the exact native record it names
- [ ] A stale/deleted-record payload and a foreign-owner payload both fail closed (no crash, no wrong-record navigation)
- [ ] Cross-tab one-shot routing (from Today search/insights/booking rows, and from the Coach insight-handoff prefill) lands on the right tab and record exactly once, without leaving stale route state for the next unrelated navigation

## Exit checklist for Phase 12

- [ ] Every row above has device/staging evidence or an explicit, recorded waiver
- [ ] Any row that fails is recorded as a defect with the build ID, not silently waived
- [ ] The two parked implementation gates above (Stripe account-switch race, Coach `sending` stuck-flag boundary) are either closed with a real fix or explicitly re-accepted with a dated rationale before Phase 12 exit
- [ ] The parity matrix is updated from `In progress` to `Verified` only after the rows above pass
