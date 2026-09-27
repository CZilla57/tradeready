# Phase 12 Release Configuration and Store Readiness (12.01, prep only)

Created 2026-09-27 by task 13 of the [Phase 12 implementation plan](native-phase-12-implementation-plan.md)
(plan §12.01). Source line numbers are at commit `666b1e0` (branch native/phase-12)
unless noted otherwise.

**Scope and authority (binding).** This task is read-only verification plus docs, plus
one host test (SC4). It does **not** edit `project.pbxproj`, `Info.plist`, entitlements
or privacy manifests (ledger ruling R8) — every value below that would need one of those
edits is recorded as a **proposed value** with the **owner approval** it needs, not
applied. No store metadata is changed and no App Store Connect, TestFlight or account
action is taken here.

**Stage A blockers (from the cutover charter §4.1 and the "New in Phase 12" defect
table, both current at `666b1e0`; not edited by this task).** Stage A entry needs SIGN-1,
VER-1 and OI-1 (all three below), plus OI-2, D4 and AGG-1 (owned outside this task — see
charter §4.1). The charter's "New in Phase 12" table (§10, 15 rows) also carries one open
**S1** defect that blocks Stage A entry under charter §2 rule 2: **P12-012** (the existing
Expo build's rollback rehearsal can push a stale pre-upgrade `__syncQueue` before its
pull and, under last-writer-wins, overwrite newer native rows after a rollback). P12-012
is **Open, awaiting the owner's ruling (R43)** — this task does not rule on it, only
names it. P12-013, P12-015, P12-016 and P12-017 (all S2) are **Fixed**; P12-018 (S3) is
**Open, backlog** (post-cutover) and does not block Stage A. This task does not edit the
charter's defect rows; see `docs/native-phase-12-cutover-charter.md` §10 for the table
itself. **Ruling R59:** the missing production build configuration (§3.1) is also an
owner-ruling blocker for Stage A/C upload — the owner must decide between adding a new
Production configuration or re-pointing Release once staging exists, and who supplies
the production values; no agent adds or edits a build configuration.

## 1. SIGN-1 — signed Release build (blocked)

Per the controller's Step 0 run (2026-09-25, `-allowProvisioningUpdates`, signed
Release), verbatim:

```
error: No Accounts: Add a new account in Accounts settings. (in target 'TradeReadyWidgets' from project 'TradeReadyNative')
error: Provisioning profile "iOS Team Provisioning Profile: *" doesn't include the App Groups capability.
… doesn't support the group.com.gettradereadyapp.tradeready App Group.
… doesn't include the com.apple.security.application-groups entitlement.
```

**Owner action:** sign in at Xcode › Settings › Accounts (team `96J48TJWX3`); re-run the
signed Release build; confirm `TradeReadyWidgets.appex` is embedded and that both
targets' provisioning profiles carry the `group.com.gettradereadyapp.tradeready` App
Group. This task does not attempt a signed build (no Apple ID is signed in on this
machine either) and does not touch accounts, profiles or signing.

**D1 waiver note:** the charter's G1 waiver (§5.1, D1) covers native remote push for this
release, so no `aps-environment` entitlement addition and no push-capability
confirmation are needed here (see §7 below for the waiver's read-only condition).

## 2. VER-1 — version numbering (blocked on an owner confirmation)

- Native `MARKETING_VERSION` = `1.0`, `CURRENT_PROJECT_VERSION` = `1` — every build
  configuration of the `TradeReadyNative` target
  (`native/TradeReadyNative.xcodeproj/project.pbxproj:389` Debug, `:426` Release) and the
  `TradeReadyWidgets` target (`:501` Debug, `:532` Release). All four agree with each
  other.
- RN `app.json` `expo.version` = `1.2.1` (`app.json:6`), `expo.ios.buildNumber` = `1`
  (`app.json:19`).
- Native's marketing version (1.0) is **below** the RN version (1.2.1). The owner has not
  yet confirmed the live App Store version in App Store Connect (VER-1's first
  requirement); this task cannot substitute a guess.

**Proposed scheme** (leaves room for the 12.06 rollback candidate and the re-upgrade
above it, per plan §12.01 and charter §4.4/§4.5): once the owner confirms the live
version L (expected `1.2.1` unless a newer Expo build has since shipped),

| Release | MARKETING_VERSION | Purpose |
|---|---|---|
| L | (owner-confirmed, expected 1.2.1) | Current live Expo build |
| N (native cutover) | **2.0.0**, build above every prior upload | The native Stage A/B/C release |
| R (Expo rollback candidate) | **2.0.1** or higher | 12.06's processed-not-submitted rollback candidate (must stay above N) |
| N2 (re-upgrade) | **2.0.2** or higher | The native re-upgrade above R |

**Owner action:** confirm the live App Store version in App Store Connect; if it
disagrees with `1.2.1`, adjust the scheme above accordingly. Then a `project.pbxproj`
edit under a dated ruling sets `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` on both
targets (kept equal, per the current pattern) — not done by this task (R8).

## 3. Step 1 — production configuration parity

### 3.1 What the build configurations actually are

The project has **two** build configurations for the `TradeReadyNative` app target, not
three: Debug (`project.pbxproj:376-413`) is wired to `TRADEREADY_ENVIRONMENT =
development` with a local backend (`http://127.0.0.1:8787`); Release
(`project.pbxproj:414-450`) is wired to `TRADEREADY_ENVIRONMENT = staging` with
`TRADEREADY_BACKEND_URL = "https://staging.invalid"` (the intentional non-resolving
placeholder per global-constraints and D4 — it must stay until real staging exists, and
this task does not touch it). **There is no committed production configuration today.**
This is expected at this stage (D4 is open; charter §4.1), but it means Stage A cannot
upload a production-configured build until the owner adds one.

**Fail-closed check, current committed state:** `BuildEnvironment.allowsSupabaseDataWrites`
(`N/BuildEnvironment.swift:117-152`) requires `environment == .production` AND
`TRADEREADY_ALLOW_PRODUCTION_WRITES == "YES"` AND the configured Supabase origin/key to
equal the production guard. The committed Release configuration has
`TRADEREADY_ENVIRONMENT = staging` and `TRADEREADY_ALLOW_PRODUCTION_WRITES = NO`
(`project.pbxproj:435,438`), so `allowsSupabaseDataWrites` returns `false` regardless of
which Supabase project the URL/key happen to point at — **verified fail-closed** in the
committed state. (Separately, `BuildEnvironment.endpoint(_:sendsUserData:)` blocks a
non-production build from writing to the production *Worker* host by name,
`N/BuildEnvironment.swift:176-183`.)

**Proposed production values, not applied (R8):** when the owner is ready to build a
production configuration, it needs `TRADEREADY_ENVIRONMENT = production`,
`TRADEREADY_BACKEND_URL` = the production Worker origin, and
`TRADEREADY_ALLOW_PRODUCTION_WRITES = YES`, added as a third configuration (or by
repointing Release once staging has its own place) under a dated ruling — not done here.

### 3.2 Backend origin

- Native's `TRADEREADY_PRODUCTION_SUPABASE_URL` guard (both Debug and Release,
  `project.pbxproj:406,443`) is `https://ncbqswfdvckmdocbawaa.supabase.co`.
- The production Cloudflare Worker's committed, non-secret `SUPABASE_URL`
  (`backend-workers/wrangler.toml:26`, `[vars]`, explicitly documented as "public
  (shipped in the app bundle)") is **the same host**: `ncbqswfdvckmdocbawaa.supabase.co`.
  **Matches.**
- RN's production backend origin (`app.json` `expo.extra.backendUrl`, `app.json:89`) is
  `https://tradeready-backend.tradeready.workers.dev`, the exact host
  `BuildEnvironment.endpoint` checks by name for the production-write guard
  (`N/BuildEnvironment.swift:178`). **Matches** (the native guard targets the same Worker
  RN ships against).
- Neither Debug nor Release is configured against that production Worker origin today
  (Debug uses localhost; Release uses `staging.invalid`) — expected, since no production
  configuration exists yet (§3.1).

### 3.3 Supabase publishable key

- Native's `TRADEREADY_SUPABASE_PUBLISHABLE_KEY` equals
  `TRADEREADY_PRODUCTION_SUPABASE_PUBLISHABLE_KEY` in **both** Debug and Release
  (`project.pbxproj:405,409` and `:442,446` — same value in each pair, not reproduced
  here). Isolation between environments here comes from the `TRADEREADY_ENVIRONMENT`
  gate (§3.1), not from a different Supabase key per environment.
- Compared against RN's production Supabase anon key (`utils/supabase.ts`, the constant
  `run-phase-4-device-preflight.sh` reads as `SUPABASE_ANON_KEY`): **present in both**;
  byte-for-byte comparison deferred to the existing preflight script rather than
  reproduced in this doc (`native/run-phase-4-device-preflight.sh` already does this
  exact check at its `rn_production_key` step). Value not printed here (never copied into
  a doc, ruling on secrets).

### 3.4 RevenueCat keys

- `TRADEREADY_REVENUECAT_API_KEY` (Apple, `project.pbxproj:407,444`) and RN's
  `expo.extra.rcAppleApiKey` (`app.json:95`): **present in both, matches** (direct string
  comparison run locally; value not reproduced here — RevenueCat Apple SDK keys are
  public client identifiers per `N/BuildEnvironment.swift:62-65`, but this task still
  does not copy key values into docs).
- `TRADEREADY_REVENUECAT_ENTITLEMENT_ID` = `TradeReady Pro` in both Debug and Release,
  matching the charter's TH-10 wording and `docs/native-phase-3-device-matrix.md`'s
  `TradeReady Pro` references.

### 3.5 Google Sign-In client identifiers (non-secret, named by key only)

- `TRADEREADY_GOOGLE_IOS_CLIENT_ID` / `TRADEREADY_GOOGLE_SERVER_CLIENT_ID`
  (`project.pbxproj:402-403,439-440`) match `app.json`'s `googleIosClientId`
  (`app.json:98`) and `googleWebClientId` (`app.json:97`) exactly — direct string
  comparison run locally; values not reproduced here. `native/Info.plist`'s
  `GIDClientID` / `GIDServerClientID` keys (`native/Info.plist:28-29`) resolve from the
  same build settings. The Google Sign-In URL scheme registered in `native/Info.plist`'s
  `CFBundleURLTypes` (`native/Info.plist:37`) matches the resolved iOS client id's
  prefix — the same check `run-phase-3-device-preflight.sh` already runs. (Fix round 1:
  this section previously reproduced the client-id/URL-scheme value directly; it is
  named by key only now, consistent with how §3.4 treats the RevenueCat key — the value
  is inherently public, shipped in the binary's `CFBundleURLTypes` for the OAuth
  redirect, but this doc does not copy identifier values regardless.)

### 3.6 Entitlement-adjacent URLs

- `TRADEREADY_EMAIL_CONFIRMATION_URL` matches `app.json`'s `emailConfirmedUrl` exactly
  (`https://gettradereadyapp.com/confirmed.html`).
- `TRADEREADY_PASSWORD_RESET_URL` is the native deep link
  `tradeready://reset-password` (both configurations), while RN's
  `app.json` `passwordResetUrl` is the web fallback
  `https://gettradereadyapp.com/reset.html`. **This is not a mismatch**: native handles
  the password-reset callback itself via its own URL scheme (confirmed intentional by
  `run-phase-3-device-preflight.sh`'s own assertion that Release's reset URL must equal
  `tradeready://reset-password`), while RN, having no universal/custom deep link back
  into a bare Expo Go/dev client in every context, redirects through the web page. Noted
  for completeness, not a blocker.

### 3.7 Analytics and crash-reporting keys

`TRADEREADY_POSTHOG_API_KEY`, `TRADEREADY_POSTHOG_HOST` and `TRADEREADY_SENTRY_DSN` are
**absent from every committed build configuration** (Debug and Release, both targets) —
confirmed by grep across `project.pbxproj` and by the absence of any `*.xcconfig` file in
`native/`. This matches `N/BuildEnvironment.swift:71-95`'s documented behavior: analytics
and crash reporting stay off until a Release build supplies these at build time (OI-2,
KEYS in the evidence index). The RN keys (`app.json` `extra.posthogApiKey`,
`extra.sentryDsn`) are never copied into native config, matching the doc comments in
`BuildEnvironment.swift`.

## 4. Step 2 — entitlements, privacy manifests, encryption and permission strings

### 4.1 Entitlements

- App (`native/TradeReadyNative/TradeReadyNative.entitlements`): Sign in with Apple
  (`com.apple.developer.applesignin` = `Default`) and App Group
  (`group.com.gettradereadyapp.tradeready`). No associated domains.
- Widget extension (`native/TradeReadyWidgets/TradeReadyWidgets.entitlements`): the same
  App Group only. No associated domains.
- RN `app.json`'s `ios.entitlements` (`app.json:21-25`) declares only the same App Group;
  `usesAppleSignIn: true` (`app.json:20`) is the Expo-plugin equivalent of the native
  entitlement. **Matches** — today's build needs exactly App Group + Sign in with Apple,
  and neither the native entitlements nor RN's `app.json` declare associated domains, so
  there is nothing to add for that.
- No `aps-environment` entry (push) in either entitlements file — correct under the D1
  waiver (§1 above; charter §5.1). If D1 is ever answered "build" instead of "waived",
  12.00b.4 (not this task) adds `aps-environment` under its own ruling and confirms the
  push capability, per the plan text.

### 4.2 Privacy manifests vs actual behavior

Both manifests already exist (11.01, 11.09) and were re-verified against the current
source:

- **App** (`N/PrivacyInfo.xcprivacy`): declares `NSPrivacyAccessedAPICategoryUserDefaults`
  (`CA92.1` standard, `1C8F.1` App Group) and
  `NSPrivacyAccessedAPICategoryFileTimestamp` (`C617.1`). Re-grepped: the only
  `.contentModificationDateKey` reads are in `N/NativeWidgetActionReplay.swift:1247,1382`
  (widget-action claim files in the App Group container); no new boot-time or
  disk-space API appears in `N/`. **Matches current source.**
- **Widget** (`native/TradeReadyWidgets/PrivacyInfo.xcprivacy`): declares UserDefaults
  `1C8F.1` only, no collected data. Re-grepped: no file-timestamp, boot-time or
  disk-space API in `native/TradeReadyWidgets/`. **Matches.**
- **Collected data types** (app manifest): UserID, Product Interaction, Other Usage Data
  (PostHog, 11.07/11.08), Crash Data, Performance Data, Other Diagnostic Data (Sentry,
  11.09), Other Financial Info and Purchase History (11.09 decisions, contract
  decisions §8.3). These are the SDK/analytics-contributed types and are unchanged by
  this task.
- **Open concern carried from 11.09** (contract decisions §8.3, "Concern for Phase 12 App
  Store Connect labels, not declared here"): the app also sends the sign-in email to
  Supabase auth, syncs business records (customers, jobs, invoices) and uploads job
  photos to the TradeReady backend — App Functionality data types (Email Address, Name,
  Phone Number, Physical Address, Photos, Customer Support/Other User Content) that
  §8.2 does not list. This is exactly OI-1 (below): this task decides the proposal: the
  owner and a `PrivacyInfo.xcprivacy` edit apply it.

### 4.3 `ITSAppUsesNonExemptEncryption`

**Gap found.** RN's `app.json` sets `ios.infoPlist.ITSAppUsesNonExemptEncryption = false`
(`app.json:27`). `native/Info.plist` has **no `ITSAppUsesNonExemptEncryption` key at
all**. The app uses only standard HTTPS/TLS (URLSession, Supabase, RevenueCat, Sentry,
PostHog SDKs) and no proprietary/non-exempt cryptography, so `false` is the accurate
value — same as RN. Without the key, every App Store Connect upload will prompt for the
export-compliance answer manually instead of it being declared in the binary.

**Proposed value, not applied (R8):** add `<key>ITSAppUsesNonExemptEncryption</key><false/>`
to `native/Info.plist`, matching RN. **Owner approval needed** for the `Info.plist` edit.

### 4.4 Permission strings

- `NSCameraUsageDescription` = "TradeReady uses the camera to add job photos."
  (`native/Info.plist:30`). The only in-app photo-capture path is
  `UIImagePickerController` with `sourceType = .camera`
  (`N/NativeJobPhotosView.swift:226`), which requires this string. **Present and
  accurate.** Wording differs slightly from RN's camera permission copy
  (`app.json`'s `expo-image-picker.cameraPermission`, "TradeReady needs camera access to
  let you take photos of job sites and completed work.") — both describe the same
  capability; not a functional gap, but the owner may want to align wording for
  consistency across the two builds (non-blocking style note, not a defect).
- **No `NSPhotoLibraryUsageDescription`, and none is needed.** Photo library access uses
  SwiftUI's `PhotosPicker` (`N/NativeJobPhotosView.swift:63`), which — like
  `PHPickerViewController` — runs out-of-process and requires no usage string and no
  library permission prompt. RN declares a photo-library permission string
  (`app.json`'s `expo-image-picker.photosPermission`) because Expo's picker uses the
  legacy in-process API; native's modern picker makes that string unnecessary. **Not a
  gap** — recorded so a future reviewer does not "fix" this by adding an unused key.
- `NSCameraUsageDescription` is the only permission string native declares. No
  microphone, location, contacts, motion or other sensitive-API usage description
  exists or is needed (no matching API usage found in `N/`).

## 5. OI-1 — App Store privacy-label declarations (decision, not entered)

**Proposal** (first-party backend data the app sends/syncs, per contract decisions §8.3's
carried-forward concern, §4.2 above):

| Data type | Linked | Tracking | Purpose(s) | Why |
|---|---|---|---|---|
| Email Address | Yes | No | App Functionality | Sign-in email to Supabase Auth |
| Name | Yes | No | App Functionality | Business/customer name fields synced to the backend |
| Phone Number | Yes | No | App Functionality | Customer contact fields synced to the backend |
| Physical Address | Yes | No | App Functionality | Customer/job address fields synced to the backend |
| Photos | Yes | No | App Functionality | Job photos uploaded to the TradeReady backend |
| Customer Support / Other User Content | Yes | No | App Functionality | Job notes, messages and other free-text records synced to the backend |

None of these are for tracking (no cross-app/cross-site use; `NSPrivacyTracking` stays
`false`). This is in addition to, not a replacement for, the already-decided
analytics/crash types in §4.2 (UserID, Product Interaction, Other Usage Data, Crash
Data, Performance Data, Other Diagnostic Data, Other Financial Info, Purchase History).

**Owner action:** enter these App Functionality labels in App Store Connect (Stage C
entry per the evidence index prerequisites table) and approve a `N/PrivacyInfo.xcprivacy`
edit adding the corresponding `NSPrivacyCollectedDataTypes` entries (not applied here,
R8). PRIV-1 (a later check) then verifies the entered labels against the manifest.

## 6. Step 3 — App Store metadata and legal disclosures (owner-verified currency)

The app's legal-disclosure URLs are wired consistently: `TRADEREADY_PASSWORD_RESET_URL`/
`TRADEREADY_EMAIL_CONFIRMATION_URL` build settings and RN's `app.json` `privacyPolicyUrl`
(`https://gettradereadyapp.com/privacy.html`) and `termsUrl`
(`https://gettradereadyapp.com/terms.html`) all point at the same `gettradereadyapp.com`
site (source: `app.json:91-92`). This task cannot verify the *content* of those hosted
pages (privacy policy accuracy, subscription auto-renewal/price/duration disclosure
wording) from the repository — that is a live-site content review.

**Owner action:** confirm the hosted privacy policy, terms and subscription-disclosure
copy at `gettradereadyapp.com` are current for the native build (in particular, that
subscription auto-renewal terms match the RevenueCat/StoreKit paywall's actual price and
duration) before Stage C entry, and update the App Store privacy nutrition labels per §5.

## 7. Step 3a — App Review notes and demo account template

**App Review notes (draft, for both external TestFlight Beta App Review and production
review):**

> TradeReady is a field-service business app (scheduling, invoicing, estimates,
> customers) for solo trade contractors. Sign in with the demo account below. On first
> sign-in, choose "Start with sample data" during onboarding to seed a full synthetic
> business (customers, jobs, invoices, estimates) with no real customer data. The
> subscription paywall can be bypassed with the reviewer's sandbox/demo entitlement (see
> below); Restore Purchases is available if the paywall reappears. Booking-link and
> portal flows can be exercised from Settings › Booking link using the seeded sample
> customer. No push notifications are sent in this release (booking alerts arrive by
> email only, per a dated waiver) — this is expected, not a defect.

**Demo account TEMPLATE (fields only — no real credentials; the owner fills this in a
credential manager, never in this repo or this doc):**

| Field | Value (owner-supplied) |
|---|---|
| Sign-in method | Email + password, or Sign in with Apple (state which) |
| Demo email | *(owner fills in; a disposable/synthetic mailbox the owner controls)* |
| Demo password | *(owner fills in; not this app's production password policy minimum only — meets it)* |
| Environment | Whichever environment the submitted build is configured against (production, once §3.1's gap is closed) |
| Subscription state | Owner grants a sandbox/demo `TradeReady Pro` entitlement, or notes that the paywall is reachable and Restore Purchases works |
| Seed data | "Start with sample data" during onboarding, or a pre-seeded account the owner maintains |
| Notes for the reviewer | Any App Review-specific navigation notes (e.g., where to find booking links, how to trigger an invoice-paid flow) |

This task does not create the account or enter these fields in App Store Connect — that
is an owner action requiring real credentials, which this task never handles.

## 8. Step 3b — subscription and identity continuity checks (evidence rows appended)

Two new evidence-index rows record these checks (not already present — `P3-S3`,
`P3-S5` and the SIWA rows in `docs/native-phase-12-evidence-index.md` are non-upgrade
Phase 3 rows, not scoped to the Expo-to-native SA2 upgrade run this step asks for):

- **`P12-3B-1`** (`docs/native-phase-12-evidence-index.md` §23): a RevenueCat entitlement
  bought on the Expo build is honored after the native upgrade, Restore Purchases works,
  and a fresh sandbox purchase works on the native build (charter TH-10).
- **`P12-3B-2`** (same §23): a Sign in with Apple user (same team and bundle id) lands in
  the same account after the native upgrade.

Both are Stage A, run in the same SA2 upgrade session as `P2-P2` per
`docs/native-phase-12-evidence-index.md` §10's note that "12.04 step 2 adds its own SA2
checks (pending Expo notifications reconciled; the 12.01 step 3b continuity checks) to
the same run." Evidence placeholders are empty (`[ ]`) — this task does not run them (no
device, no sandbox tester, no signed build available here).

## 9. Step 4 — database-backup and backend-compatibility checklist (gate reference)

Execution is owned by 12.03 (database-backup checklist) and 12.07 (backend-compatibility
verification at Stage C), not this task. This task adds the explicit **SC4 retention
assertion**:

**Assertion:** the legacy migration path (Expo AsyncStorage → native) is never removed or
unwired. Enforced by a new host test, `native/run-legacy-migration-retention-tests.sh`
(+ `native/LegacyMigrationRetentionTests/main.swift`), registered in
`native/run-all-domain-tests.sh` immediately after `run-migration-coordinator-tests.sh`.

It is a pure source/structure check, not a behavioral one (so it never touches the
Keychain or writes a legacy backup, and passes with the console locked — ruling R53).
*(Revised by that task's own review fix round 1, Important 2: checks 1-5 below alone
stayed green even if the app's real launch path stopped requesting automatic migration
at all, because they only checked the gated block's contents, never that the gate is
actually reached from the app's real entry point. Checks 6-8 below close that gap.)*
The runner (`native/LegacyMigrationRetentionTests/main.swift`) makes 8 assertions,
numbered here in the same order as its 8 `PASS`/`FAIL` lines:

1. **`LegacyMigrationCoordinator` compiles into the host target**
   (`N/LegacyMigrationCoordinator.swift:793`, `struct`), referenced by type only, never
   called. If it is removed or renamed, `swiftc` fails before the test binary ever runs,
   and the runner treats that the same as a failing test.
2. **`LegacyDataImporter.readAsyncStorageValues(from:)` compiles into the host target**
   (the AsyncStorage reader, `N/LegacyDataImporter.swift:488`), referenced by signature
   only, never called; same compile-failure-as-test-failure rule as check 1.
3. **`AppStore`'s init still gates an automatic legacy migration attempt on launch**,
   read as source text: its initializer (`N/AppStore.swift:615` `init`) still guards an
   automatic migration attempt with
   `if automaticallyMigrateLegacyData && accountScrubRecoveryError == nil {` (`:748`).
4. **The gated block constructs a `LegacyMigrationCoordinator(`** (`:768`), scoped to
   the launch-path block only (`:748` through `let completedWithoutSnapshot =` at
   `:803`) — not a manual "Try again" retry path elsewhere in the file.
5. **The gated block routes it through `try self.migrateLegacySource(with: coordinator)`**
   (`:776`).
6. **The real entry point uses the convenience init.**
   `native/TradeReadyNative/TradeReadyNativeApp.swift`'s `@main` entry point constructs
   `AppStore` through `AppStore(analytics:` (the convenience init with
   `analytics:`/`crashReporting:` parameters), not the designated
   `init(fileURL:...)`, whose `automaticallyMigrateLegacyData` parameter defaults to
   `false`.
7. **`AppStore` still declares that convenience init** (`convenience init(` in
   `N/AppStore.swift`, read as source text alongside check 6).
8. **The convenience init passes `automaticallyMigrateLegacyData: true`** to the
   designated initializer — the assertion that actually closes the fix-round-1 gap:
   flipping this to `false`, or deleting the argument (falling back to the designated
   init's own `= false` default), would silently disable legacy migration at every
   real launch while checks 1-5 kept passing.

**RED (original mutation, before the fix round).** Renamed the launch-path call site's
constructor to `LegacyMigrationCoordinatorSC4REDTEST(` at `N/AppStore.swift:768` only
(leaving the two other, non-launch-path call sites at `:4496` and `:4550` untouched),
reran the runner: `FAIL: the launch path constructs a LegacyMigrationCoordinator`,
exit 1. Evidence: `evidence-task13/sc4-red-mutation.txt`. Restored `N/AppStore.swift`
exactly via `git checkout -- native/TradeReadyNative/AppStore.swift`; confirmed with
`git diff --stat` (no output — clean).

**RED (fix round 1, the gap checks 6-8 were added to close).** Two mutations, each
restored before the next: (a) flipped the convenience init's
`automaticallyMigrateLegacyData: true` to `false` — evidence
`evidence-task13/fix1-sc4-red-mutation-flip-false.txt`; (b) deleted that argument line
entirely, falling back to the designated init's `false` default — evidence
`evidence-task13/fix1-sc4-red-mutation-delete-line.txt`. Both mutations produce the
identical tail `FAIL: the convenience init passes automaticallyMigrateLegacyData: true
to the designated init` (check 8), exit 1, with checks 1-7 still passing (proving the
gap: before this fix round, no check would have caught either mutation, since it added
checks 6 and 7 as well as the failing check 8).

**GREEN (before and after each mutation, current 8-check design).** Evidence:
`evidence-task13/fix1-sc4-green-baseline.txt` and
`evidence-task13/fix1-sc4-green-after-restore.txt`, both all-PASS, exit 0. The original
5-check GREEN evidence (`evidence-task13/sc4-green-baseline.txt`,
`sc4-green-after-restore.txt`) predates the fix round and is superseded by these.

## 10. G1 waiver dependency — production Resend email binding (read-only)

The charter's G1 waiver (§5.1, D1) makes booking alerts email-only for this release. Its
"Conditions" row requires 12.01 to confirm, read-only, that the production Worker has its
email binding set:

- `backend-workers/lib/booking/notifyOwner.js:74` and `:126` both gate the email send on
  `env.RESEND_API_KEY` being present (`if (to && env.RESEND_API_KEY) { … }`).
- `backend-workers/wrangler.toml:2-5` documents that `RESEND_API_KEY` (and
  `GROQ_API_KEY`) are **secrets**, set only via `wrangler secret put RESEND_API_KEY`
  (Phase 4) — never in the committed `[vars]` block. No secret value is or should be in
  this repository.
- **This task can only confirm the binding NAME the code expects (`RESEND_API_KEY`) and
  that the code path fails silently closed (no email attempt) without it — it cannot
  confirm from the repository whether the secret is actually set in the production
  Worker.**

**Owner action:** run `wrangler secret list` against the production Worker and confirm
`RESEND_API_KEY` is present (name only — never paste its value anywhere). Without it, an
owner gets no booking alert at all under the G1 waiver (push is also waived).

**Native push-token retention (unrelated to Resend, same waiver's condition row):**
native keeps the Expo-era `settings.pushToken` field, untouched, through the migration
and through Codable round-tripping — `Canonical.Settings.pushToken`
(`N/Domain/CanonicalModels.swift:1272` declaration, `:1302` decode, `:1334` encode). The
charter cites this at an older line number (`~1231`, commit `1c6859a`); the field itself
is unchanged, only its line has moved with later edits.

## 11. §7 L169.a/L169.b — diffed against the native/phase-10 tip

Per the controller resolution, diffed both against the native/phase-10 branch's tip
(`afacdb24e6f66343e51febd25d9cf983a17243c2`) in a separate scratch worktree under the
scratchpad (`.../scratchpad/phase-10-l169-check`, removed after use; never in the shared
checkout).

- **L169.a** ("Release build's `appintentsnltrainingprocessor` 'Could not archive SSU
  artifacts' line was never diffed against Phase 10"): ran the identical unsigned
  Release build (`xcodebuild … -configuration Release -destination
  'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build`) at both `666b1e0` (this
  worktree) and the native/phase-10 tip. **Neither build's log contains "Could not
  archive SSU artifacts"** — `appintentsnltrainingprocessor` ran at both commits and
  logged only "No AppShortcuts found - Skipping." (evidence:
  `.../evidence-task13/unsigned-release-build.log` line ~4573 area at `666b1e0`, and
  `.../evidence-task13/phase10-tip-release-build.log` lines 4573-4576 at the phase-10
  tip). This does not reproduce on this machine/toolchain at either commit, so it is not
  something Phase 11 or Phase 12 introduced; it appears to be an intermittent/
  environment-specific artifact from whatever machine logged it during 11.07. Recorded
  as **verified not a Phase 12 regression**; the charter's L169.a row is not edited by
  this task (§10 defect rows are owned elsewhere), so this finding is for the charter
  owner to close.
- **L169.b** ("Store-integration runner's `ConformanceIsolation` warning was never
  diffed against Phase 10"): **stays open.** `native/run-store-integration-tests.sh` is
  one of the runners ruling R53 names as failing with EPERM while the console is locked
  (it writes a legacy backup via the same `SnapshotRepository` Class A file-protection
  path). Confirmed locked throughout this task: `ioreg -n Root -d1 | grep
  IOConsoleLocked` → `Yes` (checked at task start and again before the aggregate run).
  Running it — at either commit — is left to the controller on an unlocked console.

## 12. Verification run

All commands run from
`/private/tmp/claude-502/-Users-chadrector-dev-tradeready/d06509aa-4db0-4f7b-9b04-823eea14ef87/scratchpad/phase-12`
unless noted; evidence under
`/private/tmp/claude-502/-Users-chadrector-dev-tradeready/d06509aa-4db0-4f7b-9b04-823eea14ef87/scratchpad/evidence-task13/`.

1. **Focused runner** (new): `TZ=America/Phoenix sh native/run-legacy-migration-retention-tests.sh`
   → exit 0, 5/5 PASS. See §9's RED/GREEN evidence files.
2. **Aggregate**: `TZ=America/Phoenix sh native/run-all-domain-tests.sh` →
   **stopped early at `run-repository-tests.sh`** with
   `NSCocoaErrorDomain Code=513 … "Operation not permitted" … LegacyBackups/legacy-native-snapshot-to-v1.json`
   (ruling R53: Class A file protection under a locked console). Confirmed
   `ioreg -n Root -d1 | grep IOConsoleLocked` → `Yes` immediately before this run. Per
   global-constraints, this is not this task's regression: the focused runner this task
   touched (`run-legacy-migration-retention-tests.sh`) already passed directly (step 1),
   and the full aggregate is left to the controller to re-run on an unlocked console.
   Evidence: `.../evidence-task13/aggregate-run.log`.
3. **Unsigned Release compile**:
   `xcodebuild -project native/TradeReadyNative.xcodeproj -scheme TradeReadyNative -configuration Release -destination 'generic/platform=iOS' -derivedDataPath <scratchpad>/dd-unsigned CODE_SIGNING_ALLOWED=NO build`
   → `** BUILD SUCCEEDED **` (exit 0). `TradeReadyWidgets.appex` present at
   `Build/Products/Release-iphoneos/TradeReadyNative.app/PlugIns/TradeReadyWidgets.appex`.
   **No new compiler warning**: the only 4 warnings are pre-existing main-actor/
   `Identifiable` conformance warnings in `NativeChangeOrdersView.swift` (unrelated to
   this task's change — this task's only Xcode-target-file edit,
   `N/AppStore.swift`'s temporary RED mutation, was fully reverted before this build; the
   new SC4 test file is not part of the app target). Evidence:
   `.../evidence-task13/unsigned-release-build.log`.
4. **Doc reference check**, run both before and after the docs edits in this task:
   `sh native/run-doc-reference-check.sh` → before: **2186 references checked: 2 missing
   (the R1 pre-existing baseline), 6 planned**; after this task's docs (this file plus the
   evidence-index appends): **2237 references checked: 2 missing, 4 planned** — same 2
   MISSING rows both times (the pre-existing phase-8 references), no new MISSING row
   introduced. Evidence: `.../evidence-task13/doc-reference-check-before.log` and
   `.../evidence-task13/doc-reference-check-after.log`.
5. **§11 L169.a/L169.b diff builds**: see §11 above (two extra unsigned Release builds,
   one per commit, in a scratch worktree removed after use).

## 13. Docs changed

- **New**: this file, `docs/native-phase-12-release-readiness.md`.
- **New**: `native/LegacyMigrationRetentionTests/main.swift`,
  `native/run-legacy-migration-retention-tests.sh` (registered in
  `native/run-all-domain-tests.sh`).
- **Edited**: `docs/native-phase-12-evidence-index.md` — appended `P12-3B-1` and
  `P12-3B-2` to §23, updated the §6 stage-count table and its narrative totals (§8
  above).
- **Not edited** (R8, and not owned by this task): `project.pbxproj`, `Info.plist`,
  either entitlements file, either `PrivacyInfo.xcprivacy`, and the cutover charter's
  defect rows (§10, §4.1) — every proposed change to these is recorded above with the
  owner action it needs.

## 14. Concerns

- **No production build configuration exists yet** (§3.1) — Stage A/C upload needs one
  added under a dated ruling; this is in addition to VER-1's version-number edit.
- **SIGN-1, VER-1 and OI-1 all block Stage A entry** and all need owner action before
  12.01's own edits (version numbers, privacy labels) can be applied.
- **P12-012 (S1, Open)** blocks Stage A entry per charter §2 rule 2 until the owner rules
  on it (R43) — this task only surfaces it, per the charter's own table.
- **`ITSAppUsesNonExemptEncryption` is missing** from `native/Info.plist` (§4.3) — low
  risk (manual App Store Connect prompt instead of a declared answer) but should be
  fixed alongside the other `Info.plist`/entitlements edits this phase already needs.
- **RESEND_API_KEY's production presence is unverifiable from the repository** (§10) —
  owner must confirm with `wrangler secret list`; if unset, the G1 waiver's only
  user-visible alert path (email) silently does nothing.
- **L169.b stays open**, blocked by the same R53 console lock as the rest of the
  migration/repository-touching runners; leave to the controller on an unlocked console.
- **L169.a did not reproduce at either commit** in this environment — worth the charter
  owner's decision on whether to close it as environment-specific rather than leaving it
  "Open (unverified)" indefinitely.
