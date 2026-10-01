# Phase 3 Signed-Device Matrix

This matrix is the remaining exit gate for native authentication, onboarding,
and subscription. Host tests, a generic iPhoneOS build, and a simulator are
useful inputs, but none can mark a row passed. Run every row on a signed physical
iPhone against an isolated test environment, then repeat the purchase-critical
rows in TestFlight. On 2026-09-09 the owner approved using production with
disposable accounts because the app has no real users; that exception applies
only to this recorded run and does not change the checked-in fail-closed build.

> **R59 update (2026-09-29):** no staging environment will exist, and the checked-in
> Release build is now the production configuration. The 2026-09-09 exception
> therefore becomes the standing rule: run every row on a signed device against
> production with disposable accounts only. `native/run-phase-3-device-preflight.sh`
> now requires the production configuration and prints a reminder. Rows that name an
> isolated or staging environment (for example D4 and D5) still read as written; the
> owner must amend or waive each in the charter decision log.

## Preflight

From the repository root, run:

```sh
native/run-phase-3-device-preflight.sh
```

The command prints classifications only. It does not print client keys, device
identifiers, account identifiers, or tokens. Exit `0` means the machine and
checked-in Release configuration are ready to begin the matrix. Exit `1` means
a checked-in or resolved configuration contract failed. Exit `2` means the
static contracts pass but a physical device or trusted staging backend is still
missing.

Do not point a staging archive at production to clear this gate. Account
deletion is irreversible, and Phase 4 cloud push is not available to rescue
native-only data.

### Latest automated checkpoint — 2026-09-09

- Preflight found an available physical iPhone and passed every checked-in
  signing, Supabase, Google, RevenueCat, callback, entitlement, and package
  contract.
- The checked-in preflight remains `Blocked` because the Release staging backend
  still uses the intentional placeholder. The owner approved a one-off
  production-backed build for disposable-account testing instead; production
  values were supplied as build overrides and were not written into the project.
- A clean signed Release build for generic iPhoneOS succeeded, including the
  live Google and RevenueCat packages, and passed strict signature verification.
- The one-off build was installed and repeatedly upgraded in place on the
  connected iPhone. The signed-out root and every recovery gate kept retained
  business data hidden.
- A disposable email signup completed the confirmation-required path and was
  independently verified before the exact-owner gate rejected it. A returning
  Sign in with Apple session restored across relaunches, completed the online
  initial pull, and reached Today.
- The first returning-owner attempt failed closed before cloud reads because an
  RN-valid blank scheduled-time string could not project into the SwiftUI job
  model. The read-side adapter now treats trimmed blank schedule strings as
  unset, accepts date-only or ISO scheduled dates, and preserves the original
  canonical strings on untouched edits. The canonical source was never replaced
  while diagnosis was in progress.
- A successful Google callback for a non-matching account reached the exact-owner
  gate without exposing retained data. That run revealed that `Use another
  account` cleared the verified Supabase session but not Google's local SDK
  credential. The account-switch path now clears both on every exit and has
  host regression coverage. Signed-device verification of the patched build
  returned to the signed-out root, presented Google account selection on the
  next attempt, and correctly restored the Different Account gate after the
  same non-owner account was selected.
- All host domain suites and the Phase 3 device preflight tests pass after the
  compatibility fix. The remaining physical-device and TestFlight rows stay
  open.
- Both backend implementations now use one verified Auth-user deletion backed
  by audited `ON DELETE CASCADE` relationships instead of non-atomic per-table
  REST deletes. Seventeen inert backend assertions, zero npm audit findings,
  production/staging Wrangler dry-runs, and an unauthenticated local Hono route
  smoke pass. The isolated Supabase environment, staging secrets, deployed
  endpoint, residual access-token policy, and D4/D5 device evidence remain
  open.

## Evidence rules

- Use disposable staging accounts and StoreKit sandbox testers. Never record an
  email address, Apple/Google credential, access token, refresh token, customer
  record, or full device identifier in this document or a support report.
- Record only the date, app version/build, iOS version, a privacy-safe tester
  alias, and `Pass`, `Fail`, or `Blocked` for each row.
- A retry row passes only when the first failure leaves existing local data
  untouched and the retry reaches the expected screen.
- A cross-account row passes only when account B cannot render, activate, or
  mutate account A's retained data.
- Preserve screenshots or recordings outside the repository and redact system
  account pickers, emails, notification content, and purchase identifiers.

Suggested run header:

| Field | Value |
| --- | --- |
| Date | 2026-09-09 |
| App version/build | 1.0 (1) |
| iPhone model / iOS | iPhone 16 Pro Max / iOS 27.0 |
| Signed configuration | One-off Release production override; checked-in defaults unchanged |
| Tester aliases | returning-owner-A; disposable-email-B |
| TestFlight build | Pending |

Run observations:

- A1 pass: disposable-email-B required email confirmation, returned to the
  sign-in screen, exposed no main content before confirmation, and was
  independently verified before the exact-owner gate evaluated it.
- A2 partial: a synthetic `.invalid` email/password submission returned only
  `Authentication failed. Please try again.` on the signed device. No Supabase
  response detail was exposed. A valid returning-password login remains
  pending.
- D3 partial: after successful email confirmation, the newly verified account
  was blocked by the retained exact-owner binding from the previous install.
  The app displayed the Different Account gate and exposed no prior business
  data. Full D3 cleanup and cross-state assertions remain pending.
- D1 pass: returning-owner-A completed online sign-out without a remote
  revocation or local-cleanup failure alert. The signed device reached the
  signed-out root only after the app's local scrub boundary completed; no main
  content or retained account state was visible.
- A7 pass: Sign in with Apple published an independently verified Supabase
  identity for returning-owner-A, restored across multiple in-place relaunches,
  completed initial sync, and routed to Today. Subsequent signed-device sign-out
  returned to the signed-out root, and cancelling a fresh Apple sheet was
  silent and left that root unchanged.
- A8 partial: opening Google sign-in reached the system `google.com`
  authorization prompt. Cancelling there was silent, published no session, and
  left the signed-out root unchanged. A subsequent account selection completed
  the callback and independently verified a Supabase subject before the
  non-matching owner was stopped at the Different Account gate. On the patched
  signed build, `Use another account` returned to the signed-out root and the
  next Google attempt presented account selection instead of silently reusing
  the rejected credential; selecting that same non-owner correctly restored
  the Different Account gate. Matching-owner Google sign-in and relaunch remain
  pending.
- O1 pass: returning-owner-A reached Today only after all supported tables were
  fetched and the candidate snapshot passed the single atomic initial-sync
  commit boundary. The earlier cloud gate was traced to local UI projection,
  not Supabase authorization; retained data remained hidden until the
  loss-preserving schedule compatibility fix was installed.
- S3 partial: after returning-owner-A restored through the verified identity and
  entitlement gates, the signed-device Subscription screen displayed
  `TradeReady Pro` with `Subscription active`. This proves the live Settings
  status for the current entitlement, but not a sandbox purchase or trial.
- S4 pass: restoring purchases for returning-owner-A completed successfully,
  retained the exact signed-in account, and returned to the Subscription screen
  with `TradeReady Pro` still active.
- S7 partial: `Manage subscription` handed off successfully to Apple's
  subscription-management UI and returned to TradeReady without changing the
  active status. This was the directly installed signed build, not TestFlight,
  so the distributed-build repeat remains pending.

## Authentication and recovery

| ID | Scenario | Acceptance | Result |
| --- | --- | --- | --- |
| A1 | New email account with confirmation required | Confirmation-required UI appears; no main data is visible before the confirmed session is independently verified. | Pass |
| A2 | Returning email account | A valid password reaches initial sync and the correct owner namespace; invalid credentials expose no server detail. | Pending |
| A3 | Expired access token with valid refresh token | Foreground restoration rotates the session and lands on the same account without exposing an intermediate main screen. | Pending |
| A4 | Expired or rejected refresh token | The app returns to sign-in while retaining recoverable owner-bound local data. | Pending |
| A5 | Password reset, cold and warm callback | Mail/browser handoff returns only through `tradeready://reset-password`; the new password is accepted after the recovery-only screen completes. | Pending |
| A6 | Reused, expired, malformed, and cancelled reset | Every invalid path fails closed; cancellation returns to sign-in without deleting business data. | Pending |
| A7 | Sign in with Apple | Apple sheet, nonce-bound Supabase exchange, independent subject check, relaunch, and device-only sign-out all succeed; cancellation is silent. | Pass |
| A8 | Sign in with Google | Account picker, callback, nonce-bound Supabase exchange, independent subject check, relaunch, and SDK credential clearing all succeed; cancellation is silent. | Pending |

## Initial sync and onboarding

| ID | Scenario | Acceptance | Result |
| --- | --- | --- | --- |
| O1 | Returning account, online initial pull | Remote settings and all supported collections commit atomically before onboarding or the main UI decides its route. | Pass |
| O2 | Initial pull interrupted or offline | A first-ever or incomplete bootstrap keeps the retryable cloud gate and never applies a partial candidate. A returning account whose exact Keychain session was previously live-verified and whose workspace is bound to that account opens its local snapshot offline. | Pending |
| O3 | Onboarding interrupted on each step | Relaunch restores the same verified account's draft and current step; another account cannot adopt it. | Pending |
| O4 | Sample start interrupted | Relaunch replays the same sample transaction and IDs without duplication or replacement of real records. | Pending |
| O5 | Fresh start after interrupted sample creation | Only native sample IDs are removed; real and unknown canonical records remain. | Pending |

## Subscription and TestFlight

| ID | Scenario | Acceptance | Result |
| --- | --- | --- | --- |
| S1 | New unsubscribed account | Localized monthly/annual offerings load, annual is preferred when present, and main data remains behind the paywall. | Pending |
| S2 | Purchase cancelled | Cancellation is silent and the entitlement gate remains closed. | Pending |
| S3 | Sandbox purchase or trial | Only the exact active `TradeReady Pro` entitlement advances to starting-point selection; Settings reflects trial/active status. | Pending |
| S4 | Restore for the same TradeReady account | Restore reopens the exact account after an active entitlement response. | Pass |
| S5 | Restore while signed into a different TradeReady account | RevenueCat uses the newly verified Supabase subject and account A's local business data is never exposed to account B. | Pending |
| S6 | Expiry or lapse plus foreground refresh | The latest inactive entitlement returns the account to the paywall without crossing identity generations. | Pending |
| S7 | TestFlight purchase-critical repeat | S1 through S6 and App Store subscription-management handoff behave the same in the distributed build. | Pending |

## Sign-out, deletion, and owner isolation

| ID | Scenario | Acceptance | Result |
| --- | --- | --- | --- |
| D1 | Online sign-out | Only this device's refresh-token family is revoked; the crash-resumable local scrub finishes before sign-in appears. | Pass |
| D2 | Offline sign-out | Remote failure keeps data intact until the separate device-only confirmation; accepting it finishes the local scrub. | Pending |
| D3 | Account A to account B switch | B cannot view A's snapshot, backup, onboarding draft, pending links, widget/Siri actions, media, or auxiliary activation state. | Pending |
| D4 | Approved disposable-account deletion | Exact `DELETE` confirmation calls the approved backend; failure preserves local data and success removes the remote account plus every documented local recovery artifact. | Pending |
| D5 | Relaunch after successful deletion | Interrupted cleanup resumes, the deleted session cannot restore, and the app lands at sign-in with no deleted-account data visible. | Pending |

Phase 3 exits only when every row is `Pass`, including S7. Any `Fail` or
`Blocked` result keeps Phase 3 in progress and must not be converted into a
marketing or release claim.
