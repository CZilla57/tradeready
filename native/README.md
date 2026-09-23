# TradeReady Native

This directory contains the native iOS rewrite of TradeReady. It is a standalone
SwiftUI application (iOS 17+) and does not embed React Native or Expo.

## Open and run

1. Open `TradeReadyNative.xcodeproj` in Xcode.
2. Choose the `TradeReadyNative` scheme and an iPhone or iPad simulator.
3. Build and run.

Debug builds use `http://127.0.0.1:8787` and block production user-data
requests. Release builds intentionally use `https://staging.invalid` until a
real staging backend is provisioned. Production access must be enabled
explicitly in the Xcode build settings; see `docs/native-phase-0-baseline.md`.

The app stores a versioned canonical snapshot in Application Support. A newly
verified account chooses sample or fresh data only after onboarding and the
subscription gate. Use **Settings → Data → Import React Native data** after
installing over an existing Expo build with the same bundle
identifier; the importer reads all twelve plain-storage families directly into
their loss-preserving canonical models, including large manifest-backed values.
After preserving the complete Expo source, it also adopts safely contained JPEG
job photos and JPEG/PNG receipts and logos into deterministic native-owned
paths. Copies are byte-exact and non-destructive; missing, external, or
unsupported references remain in the snapshot for a later capable migrator.

## Migration scope

The native foundation includes the six main areas, native navigation/search/
forms, job scheduling and status changes, invoice settlement, customer contact
actions, expense capture, a complete settings hierarchy, JSON persistence,
legacy local-data import, deep links, and an AI coach client for the existing
backend. Settings → Import Data can prepare a shareable migration support report
whose closed schema contains only app/version, record-count, backup, and
migration-status metadata.

Photo capture/management UI, Stripe onboarding, PDF/accountant exports,
notifications, booking/portal administration, and the advanced profitability
cards remain explicit follow-on migration work. See `MIGRATION.md`.

## Domain verification

Run all Foundation-only Phase 1 parity suites without a simulator:

```sh
native/run-all-domain-tests.sh
```

The aggregate runner covers canonical record and versioned-snapshot round
trips, financial rules, non-financial recurrence/lifecycle/numbering/archive/ID
rules, loss-preserving SwiftUI adapters, canonical AppStore persistence, secure
field redaction, legacy-native upgrade, all-family AsyncStorage decoding,
versioned auxiliary-state capture, strict App Group input validation, and
interruption-safe local photo adoption with collision and source-preservation
coverage. Auxiliary activation tests also cover exact account-owner matching,
keyed identity namespaces, deterministic privacy-safe receipts, invalid device
preferences, excluded sync state, and concurrent idempotent staging. Focused
suites also cover access-token rejection, refresh rotation, authoritative
session replacement, expiry synthesis, server-subject agreement, authenticated
typed account-state decoding, and strict owner-gated pending-link routing that
leaves App Group source values untouched. Subscription tests cover exact
RevenueCat identity inputs, trial/paywall routing, fail-open refresh, bounded
errors, purchase cancellation, restore, and active-entitlement enforcement. A
focused subset also runs through
the `TradeReadyNativeTests` XCTest target in Xcode.

Phase 4 cloud sync is underway. The read-only initial-sync pull already drains
every collection with owner filtering and server-authoritative merges. The write
path adds a durable, versioned mutation queue (last-writer-wins per record,
collection diffing, corruption-safe recovery, prune, and cross-owner scrub) and
an idempotent push transport (merge-duplicates collection/settings/note upserts,
owner-scoped soft deletes, secure-settings scrubbing, no client `updated_at`,
fail-closed id/blob checks, failure retention, and bounded diagnostics). Direct
Data API writes also pass a runtime environment guard: development and staging
must use an HTTPS origin and publishable key distinct from their configured
production references, while production requires exact origin/key matches and
the explicit production-write switch. The production key reference is checked
against the React Native production client without logging either value. A
blocked pass sends no request, retains its queue, skips the pull that could
overwrite pending edits, and reports only `push/environment`; authentication
and read-only recovery are unaffected. A
reachability-aware sync coordinator schedules the push: it serializes passes and
coalesces mid-pass triggers, skips when offline/signed-out/empty or inside an
exponential backoff window (reset on a full drain), persists only the
unacknowledged remainder, and on an auth rejection refreshes the session once and
retries. AppStore drives it on sign-in, foreground, and every local change, with
`NWPathMonitor`-backed reachability in production. A one-time, per-account
backfill enqueues the whole local snapshot (collections, secure-scrubbed
settings, and customer notes) on the first completed initial sync, so records
that arrived by legacy migration or sample-seeding — and thus never went through
the enqueue-on-edit hooks — still reach the cloud; it is flag-gated, idempotent,
offline-safe, and cleared at every account boundary. After each push the
coordinator runs a cursor-based delta pull (`native/run-delta-sync-tests.sh`)
that fetches only rows changed since each table's server `updated_at` watermark,
and a two-device convergence suite
(`native/run-two-device-convergence-tests.sh`) drives push and delta pull for two
Swift clients against one in-memory Supabase model to prove records propagate both
ways, concurrent edits converge to the last writer, deletes propagate, invoice
payment ledgers survive a concurrent overwrite, and an offline queue replays
idempotently. The same suite also drives a narrow React Native reference client
against the production Swift transports to verify bidirectional collection
upserts/deletes and database-clock authority with both far-future and stale
React Native device timestamps. Real installed-client evidence remains open in
`../docs/native-phase-4-mixed-client-convergence.md`. Run the new suites without a simulator via
`native/run-mutation-queue-tests.sh`, `native/run-mutation-push-tests.sh`,
`native/run-record-deletion-tests.sh`,
`native/run-build-environment-tests.sh`,
`native/run-sync-coordinator-tests.sh`, `native/run-background-refresh-tests.sh`,
`native/run-job-photo-transfer-tests.sh`,
`native/run-customer-identity-tests.sh`, `native/run-address-lookup-tests.sh`,
`native/run-global-search-tests.sh`,
`native/run-interaction-state-tests.sh`,
`native/run-customer-contact-action-tests.sh`,
`native/run-estimate-follow-up-tests.sh`,
`native/run-estimate-follow-up-notification-tests.sh`,
`native/run-change-order-tests.sh`,
`native/run-confirmation-tests.sh`,
`native/run-sync-backfill-tests.sh`,
`native/run-delta-sync-tests.sh`, and
`native/run-two-device-convergence-tests.sh`. The fixture-driven
`native/run-phase-4-device-preflight-tests.sh` verifies the fail-closed external
gate; all are included in
`native/run-all-domain-tests.sh`).

The native main tabs now show a compact sync banner only while work is syncing,
offline, pending, or failed. Settings → Cloud Sync exposes the durable pending
count, last successful session sync, scheduled retry, manual retry, and a bounded
privacy-safe diagnostic code. Push and pull failures schedule their own backoff
retry, and the sync-first sign-out action waits for that pass before removing
local account state. Native background refresh now registers before launch
completion, reschedules a 30-minute-earliest `BGAppRefreshTaskRequest`, cancels
cleanly on expiration, and permits a cold background launch to attach
credentials only after server verification and an exact completed-workspace
binding match. Job-photo upload/backfill now follows metadata sync in initial,
foreground, and background passes. It sends only the current bearer token to the existing
owner-deriving worker, preserves local JPEGs, commits `uploadedAt` only after a
confirmed PUT, validates and atomically installs missing downloads, and
re-checks exact ownership after every network suspension. Physical-device
background/photo/concurrency evidence remains open Phase 4 work; see
`../docs/native-phase-4-background-refresh.md` and
`../docs/native-phase-4-job-photo-transfer.md`. Run
`native/run-phase-4-device-preflight.sh` before recording those cases in
`../docs/native-phase-4-device-runsheet.md`.

Legacy Supabase sessions remain opaque bytes during upgrade. The migration
rejects corrupt or mixed SecureStore chunk sets and publishes verified native
Keychain generations before atomically selecting the active session. At native
startup, a still-valid access token is sent only to Supabase's Auth user
endpoint; only the returned server identity may activate an exact-owner
auxiliary envelope, under a namespace derived with a private Keychain HMAC key.
Rejected access tokens now use the refresh-token grant; the validated server
response is published as a new verified Keychain generation before its identity
is independently checked again. The resulting exact-owner proof drives a typed,
digest-authenticated reader for approved account-state keys and a read-only App
Group pending-link consumer. Job links route locally, while on-my-way links open
an editable, channel-aware draft and then Apple's system composer; neither path
mutates the shared source and messages are never auto-sent. Widget/Siri actions
and active-trip completion now use the locked, write-ahead, idempotent replay
transport described in the Phase 2 evidence document.
Phase 3 authentication is now underway. Native startup and every foreground
activation revalidate the saved session, refresh a rejected access token, and
publish rotated credentials atomically. The root gate exposes no app content
until that live identity check succeeds. Email/password sign-in and signup,
confirmation resend, and password-reset email use Supabase Auth directly; a
new token response must agree with an independent user lookup before it is
stored or allowed to activate exact-owner state. Password recovery now stores a
one-use PKCE verifier in the Keychain before requesting the email, accepts only
the exact `tradeready://reset-password?code=...` callback, and traps the verified
session on a recovery-only root screen until an exact-subject password update or
cancellation returns to sign-in. Google Sign-In now uses the
version-pinned native SDK, the existing iOS/web OAuth client configuration, a
one-use hashed/raw nonce pair, silent cancellation, and the same independently
verified session-publication boundary.

Native onboarding is bound to a stable HMAC account namespace. Its welcome and
business-personalization draft survives interruption, settings commit through a
recoverable marker, and the final screen requires an explicit sample-or-fresh
choice. Sample transactions replay stable IDs without replacing real records;
fresh start removes only native sample IDs. Main tabs and pending actions remain
blocked until the choice commits. The pinned RevenueCat SDK now sits between
personalization and the starting-point choice, keyed by the independently
verified Supabase subject. Active trials/subscriptions advance, inactive users
see current monthly/annual packages with eligibility-aware trial copy, and
purchase/restore results must contain the exact active entitlement before the
root gate opens. Subscription refresh failure preserves the established React
Native fail-open behavior, while offering failures remain on a retryable
paywall. Settings exposes live trial/active status, restore, and App Store
subscription management.

The project owner reports `tradeready://reset-password` is now in the Supabase
Auth redirect allow list. Host tests and a generic iPhoneOS build still do not
prove the external email/browser/app handoff.
Before device verification, run `native/run-phase-3-device-preflight.sh`. It
checks the resolved Release configuration, Apple/Google/purchase contracts,
and physical-iPhone availability without printing identifiers or client
configuration. Complete `../docs/native-phase-3-device-matrix.md` only against
trusted staging; the checked-in `staging.invalid` backend intentionally blocks
the destructive deletion row.
Explicit sign-out now revokes the current Supabase device session, warns before
discarding any still-pending changes, and performs a crash-resumable scrub of
canonical live/backup copies, the locked App Group suite, and the active
Keychain session. Remote failure leaves data intact unless the user separately
confirms device-only sign-out.

Account deletion requires the React Native-compatible `DELETE` phrase, sends
only the current bearer token to the existing trusted backend, retries one
expired session through verified refresh, and accepts only a closed success
response. It then removes recovery artifacts and migrated provider credentials
in addition to the normal local scrub. The checked-in Release backend remains
`staging.invalid`; configure and verify staging before enabling this destructive
flow in an archive.

Native Sign in with Apple reuses the app's established Apple capability and
AuthenticationServices. A 256-bit raw nonce is held only for one authorization,
its SHA-256 digest is sent to Apple, and the token plus raw nonce are exchanged
through Supabase's native ID-token grant. Cancellation is silent, and the
resulting session still passes the independent subject check before publication.

Queued widget/Siri actions preserve exact source bytes and future fields while
rejecting malformed, duplicate, oversized, or invalidly dated input. The
cross-process claim transport publishes a private write-ahead claim before
removing only the claimed prefix, commits known actions through one atomic
canonical transaction, and acknowledges the exact claim afterward. Unsupported
future actions remain durably queued.

Job detail now renders the canonical change-order section: derived-status badges
with React Native's copy and tone, recorded decision notes, and the add, edit,
on-site approval or decline, one-way cancellation, and pending-only delete
actions. Every action commits through one local-first transaction that
re-resolves the job and order by ID, so a decision or cancellation that arrives
while a sheet is open fails closed; the editor refuses to open for an ineligible
job or an order that is no longer pending, and never rewrites the estimate
baseline, approval link, nested preservation metadata, or unknown fields. The
customer approval link, signature, and analytics remain with the change-order
delivery slice.
