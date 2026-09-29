# Native iOS Physical-Device Test Run-Sheet

A single working checklist for the physical-device evidence that closes
**Phase 2** (persistence & upgrade) and **Phase 3** (authentication, onboarding,
subscription). This consolidates the matrices in
[native-phase-2-persistence.md](native-phase-2-persistence.md) and
[native-phase-3-device-matrix.md](native-phase-3-device-matrix.md); those
documents remain the authoritative source for acceptance wording, and this sheet
is where a run is actually recorded.

No simulator, generic-iPhoneOS, or host/command-line test can mark any row here
`Pass`. Every checkbox requires a signed build on a physical device.

> **Scheduling (2026-09-16 owner sign-off):** per the deferral decision in
> [native-ios-migration-roadmap.md](native-ios-migration-roadmap.md#verification-deferral-decision-2026-09-16),
> these rows no longer block Phases 2–3. They are consolidated into the Phase 12
> internal-TestFlight / limited-beta stages and are recorded there. This is a
> deferral, not a waiver: the evidence is still required before production
> cutover.

---

## Status at a glance

Passed on the 2026-09-09 run: **A1, A7, O1, S4, D1**. Everything else is open.

| Section | Rows | Passed | Remaining |
|---|---|---|---|
| Phase 2 — upgrade matrix | P1–P8 (8) | 0 | 8 |
| Phase 3 — authentication | A1–A8 (8) | 2 | 6 |
| Phase 3 — sync & onboarding | O1–O5 (5) | 1 | 4 |
| Phase 3 — subscription & TestFlight | S1–S7 (7) | 1 | 6 |
| Phase 3 — sign-out, deletion, isolation | D1–D5 (5) | 1 | 4 |
| **Total** | **33** | **5** | **28** |

D4 and D5 are additionally **blocked** until the staging backend in
[Section 5](#5--staging-backend-prerequisite-blocks-d4--d5) is provisioned.

---

## 1 — Shared preconditions (do once, before any row)

### Devices and builds

- [ ] Signed **physical iPhone** available (recorded baseline: iPhone 16 Pro Max /
      iOS 27.0).
- [ ] **Installable copy of the current Expo / App Store build** retained for the
      upgrade-from and rollback steps.
- [ ] Signed **Release native build** (not simulator, not generic-iPhoneOS-only).
- [ ] **TestFlight** distribution of that same build available for the
      purchase-critical repeat (S7).

### Accounts and services

- [ ] Disposable / staging accounts only.
- [ ] StoreKit **sandbox** testers provisioned for subscription rows.
- [ ] Custom redirect `tradeready://reset-password` confirmed allow-listed.

### Preflight

- [ ] From the repository root, run:

  ```sh
  native/run-phase-3-device-preflight.sh
  ```

  Exit `0` = machine and checked-in Release config ready. Exit `1` = a checked-in
  or resolved configuration contract failed (fix before continuing). Exit `2` =
  static contracts pass but a physical device or trusted staging backend is still
  missing.

### Evidence rules (apply to every row)

- Record only date, app version/build, iOS version, a privacy-safe tester alias,
  and `Pass` / `Fail` / `Blocked`.
- Never record an email, Apple/Google credential, access or refresh token,
  customer record, or full device identifier — not here and not in a support
  report.
- Keep screenshots / recordings **outside the repository**; redact system account
  pickers, emails, notification content, and purchase identifiers.
- A retry row passes only when the first failure left existing local data
  untouched and the retry reached the expected screen.
- A cross-account row passes only when account B cannot render, activate, or
  mutate account A's retained data.

### Run header (copy per run)

| Field | Value |
| --- | --- |
| Date | |
| App version / build | |
| iPhone model / iOS | |
| Signed configuration | |
| Tester aliases | |
| TestFlight build | |

---

## 2 — Phase 2: Persistence & upgrade matrix (P1–P8)

Source: [native-phase-2-persistence.md](native-phase-2-persistence.md). **All rows
open.** This matrix is the sole remaining Phase 2 exit gate.

### Per-row procedure (every P-row)

1. Install the **Expo build** first.
2. Create the fixture on-device (offline where the row specifies).
3. Install the **native build as an in-place upgrade** — do **not** delete the app.
4. **Launch the native app twice.**
5. Export the **Settings support report**.
6. Compare record counts and representative records against the Expo fixture.
7. Inspect migrated media.
8. Confirm the **Expo-format backup is still recoverable**.
9. Exercise **widget timer** and **Siri mileage** actions across foreground /
   background transitions.

### Rows

- [ ] **P1 — Clean install.** No legacy source is invented; onboarding receives an
      empty native store.
- [ ] **P2 — Sample account.** Counts, money, dates, settings, photos, session, and
      owner binding all match.
- [ ] **P3 — Large account.** External manifest values, **more than ten session
      chunks**, **512 queued actions**, and all photo directories migrate without
      truncation.
- [ ] **P4 — Offline account.** Local records and credentials survive; identity-gated
      state stays quarantined until live verification succeeds.
- [ ] **P5 — Partially synced account.** Local queue / cursors stay inert and
      recoverable; no server or local record is overwritten.
- [ ] **P6 — Interrupted migration.** Force-quit after **each** checkpoint — backup,
      snapshot publication, secure publication, widget claim, replay commit — and
      confirm every relaunch converges with no duplicates.
- [ ] **P7 — Account mismatch.** A different verified user receives none of the prior
      account's state, action replay, or customer data.
- [ ] **P8 — Corruption recovery.** Corrupt primary only, then primary **plus** backup;
      recovery-or-read-only-block behavior matches the support report.

### Phase 2 exit

- [ ] All of P1–P8 pass on a physical device.
- [ ] Retained Expo build reinstalls successfully as the **rollback rehearsal**.

---

## 3 — Phase 3: Signed-device matrix (A / O / S / D)

Source: [native-phase-3-device-matrix.md](native-phase-3-device-matrix.md).
Phase 3 exits only when **every** row — including S7 — is `Pass`.

### 3a — Authentication and recovery (A1–A8)

- [x] **A1 — New email account, confirmation required.** *(Pass 2026-09-09)*
      Confirmation-required UI appears; no main data visible before the confirmed
      session is independently verified.
- [ ] **A2 — Returning email account.** A **valid password** reaches initial sync and
      the correct owner namespace; invalid credentials expose no server detail.
      *(Only the synthetic `.invalid` failure path is proven so far.)*
- [ ] **A3 — Expired access token + valid refresh.** Foreground restoration rotates
      the session and lands on the same account without flashing an intermediate
      main screen.
- [ ] **A4 — Expired / rejected refresh token.** App returns to sign-in while
      retaining recoverable owner-bound local data.
- [ ] **A5 — Password reset, cold and warm callback.** Mail / browser handoff returns
      only through `tradeready://reset-password`; new password accepted after the
      recovery-only screen completes.
- [ ] **A6 — Reused / expired / malformed / cancelled reset.** Every invalid path
      fails closed; cancellation returns to sign-in without deleting business data.
- [x] **A7 — Sign in with Apple.** *(Pass 2026-09-09)* Sheet, nonce-bound exchange,
      independent subject check, relaunch, and device-only sign-out succeed;
      cancellation is silent.
- [ ] **A8 — Sign in with Google.** Cancellation, non-owner rejection, and SDK
      credential clearing are proven; **matching-owner Google sign-in and relaunch
      still required.**

### 3b — Initial sync and onboarding (O1–O5)

- [x] **O1 — Returning account, online initial pull.** *(Pass 2026-09-09)* Remote
      settings and all supported collections commit atomically before onboarding or
      the main UI decides its route.
- [ ] **O2 — Initial pull interrupted / offline.** A first-ever or incomplete
      bootstrap keeps the retryable cloud gate and never applies a partial
      candidate; a returning, previously live-verified bound account opens its
      local snapshot offline.
- [ ] **O3 — Onboarding interrupted on each step.** Relaunch restores the same
      account's draft and current step; another account cannot adopt it.
- [ ] **O4 — Sample start interrupted.** Relaunch replays the same sample transaction
      and IDs without duplication or replacement of real records.
- [ ] **O5 — Fresh start after interrupted sample.** Only native sample IDs are
      removed; real and unknown canonical records remain.

### 3c — Subscription and TestFlight (S1–S7)

- [ ] **S1 — New unsubscribed account.** Localized monthly / annual offerings load,
      annual is preferred when present, main data stays behind the paywall.
- [ ] **S2 — Purchase cancelled.** Cancellation is silent and the entitlement gate
      stays closed.
- [ ] **S3 — Sandbox purchase or trial.** An actual **sandbox purchase / trial**
      advances only the exact active `TradeReady Pro` entitlement to starting-point
      selection; Settings reflects trial / active status. *(Live "active" status is
      shown, but a real sandbox purchase is not yet proven.)*
- [x] **S4 — Restore for the same account.** *(Pass 2026-09-09)* Restore reopens the
      exact account after an active entitlement response.
- [ ] **S5 — Restore into a different account.** RevenueCat uses the newly verified
      Supabase subject; account A's local business data is never exposed to
      account B.
- [ ] **S6 — Expiry / lapse + foreground refresh.** The latest inactive entitlement
      returns the account to the paywall without crossing identity generations.
- [ ] **S7 — TestFlight purchase-critical repeat.** **S1–S6 and App Store
      subscription-management handoff behave the same in the distributed TestFlight
      build.** *(Handoff was only exercised from a directly-installed build.)*

### 3d — Sign-out, deletion, and owner isolation (D1–D5)

- [x] **D1 — Online sign-out.** *(Pass 2026-09-09)* Only this device's refresh-token
      family is revoked; the crash-resumable local scrub finishes before sign-in
      appears.
- [ ] **D2 — Offline sign-out.** Remote failure keeps data intact until the separate
      device-only confirmation; accepting it finishes the local scrub.
- [ ] **D3 — Account A → account B switch.** B cannot view A's snapshot, backup,
      onboarding draft, pending links, widget / Siri actions, media, or auxiliary
      activation state. *(Only the confirmation gate has been shown so far.)*
- [ ] **D4 — Approved disposable-account deletion.** 🔒 *Blocked on staging (Section 5).*
      Exact `DELETE` confirmation calls the approved backend; failure preserves
      local data; success removes the remote account plus every documented local
      recovery artifact.
- [ ] **D5 — Relaunch after successful deletion.** 🔒 *Blocked on staging (Section 5).*
      Interrupted cleanup resumes, the deleted session cannot restore, and the app
      lands at sign-in with no deleted-account data visible.

---

## 4 — TestFlight repeat scope (S7 detail)

S7 is not a single tap — it re-runs the purchase-critical path in the
**distributed** build:

- [ ] S1 repeated in TestFlight
- [ ] S2 repeated in TestFlight
- [ ] S3 (sandbox purchase / trial) repeated in TestFlight
- [ ] S4 (restore) repeated in TestFlight
- [ ] S5 (cross-account restore) repeated in TestFlight
- [ ] S6 (expiry + refresh) repeated in TestFlight
- [ ] App Store subscription-management handoff repeated in TestFlight

---

## 5 — Staging backend prerequisite (blocks D4 & D5)

Not a device test, but D4/D5 cannot start until this exists. Source:
[native-phase-3-staging.md](native-phase-3-staging.md).

- [ ] Owner selects a **separate Supabase project or branch** and accepts any cost.
- [ ] Apply repository migrations to the isolated environment.
- [ ] Run `supabase/verify/account_deletion_cascade.sql` — must report
      `Account-deletion cascade audit passed.`
- [ ] **Decide and verify the residual access-token control** (open design
      decision): either keep access-token lifetime short with a documented maximum
      residual window, **or** add a session-aware RLS policy requiring the JWT
      `session_id` to exist for the same user — proven with active, expired,
      signed-out, and deleted sessions in staging.
- [ ] Replace only `[env.staging.vars].SUPABASE_URL` in
      `backend-workers/wrangler.toml` with the isolated HTTPS project URL.
- [ ] Create the two isolated R2 buckets (`tradeready-invoice-pdfs-staging`,
      `tradeready-photos-staging`).
- [ ] Set only the staging Supabase secrets (`SUPABASE_ANON_KEY`,
      `SUPABASE_SERVICE_ROLE_KEY`) via interactive secret input.
- [ ] `npm test` and `npm run check:staging` pass locally.
- [ ] Deploy only after explicit owner authorization (`npm run deploy:staging`);
      the config classification names `tradeready-backend-staging`, has no cron
      triggers, and references only staging resources.
- [ ] Unauthenticated `POST /api/delete-account` returns a bounded `401`.
- [ ] Update the native Release `TRADEREADY_BACKEND_URL` and rerun
      `native/run-phase-3-device-preflight.sh`.

Only after every box above is checked may D4/D5 run with a disposable account on
the signed iPhone.

---

## 6 — Exit conditions

- [ ] **Phase 2 complete:** P1–P8 all `Pass` on device **and** Expo rollback
      rehearsal succeeds.
- [ ] **Phase 3 complete:** every A / O / S / D row `Pass`, **including S7**.

Any `Fail` or `Blocked` result keeps its phase in progress and must not be
converted into a marketing or release claim.
