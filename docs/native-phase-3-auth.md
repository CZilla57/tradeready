# Phase 3 Authentication Evidence

## Status

Phase 3 is in progress. The completed dependency-gated slices implement native
email authentication, the root identity boundary, and explicit sign-out with a
crash-resumable local account scrub, authenticated account deletion, and native
Sign in with Apple and Google, native PKCE password recovery and password
update, onboarding, the authenticated read-only initial cloud sync boundary,
and the RevenueCat subscription gate. They do not claim continuous Phase 4
push/pull sync, physical-device purchase proof, or the full account lifecycle.

## Implemented guarantees

- The SwiftUI root renders loading, signed-out, verified, account-mismatch, and
  retryable-unavailable states. Main app content is shown after live Auth
  verification, or during a temporary outage when the exact active Keychain
  session matches its last live-verified identity and the same account already
  has an owner-bound workspace from a completed online bootstrap.
- Password sign-in uses the Supabase Auth password grant. Signup supports both
  confirmation-required and immediate-session configurations.
- Password-reset requests now use PKCE and the exact native callback
  `tradeready://reset-password`. A 256-bit verifier is written to the Keychain
  before the email request; only its SHA-256 challenge is sent to Auth.
- Recovery accepts one `code` query item on that exact route. Duplicate or extra
  parameters, paths, credentials, ports, and token-bearing fragments fail
  closed. Provider error descriptions are never rendered as trusted copy.
- The one-time code is exchanged with the matching Keychain verifier. The
  resulting session still requires an independent `/auth/v1/user` subject
  match before publication, and the verifier is then removed.
- A verified recovery session is bound to its exact subject in the Keychain and
  trapped at a recovery-only root screen across foregrounds and restarts. It
  cannot consume pending job links, replay widget/Siri actions, or display main
  app content before password completion.
- Password updates require eight matching characters in the UI and send the new
  password only in the authenticated `PUT /auth/v1/user` body. The response
  subject must match the verified recovery subject. Success or cancellation
  removes the recovery session without deleting local business data, then
  returns to sign-in so the new password is proven normally.
- Signup-confirmation resend retains the approved hosted redirect used by the
  React Native application.
- Every independently verified subject now receives a stable, non-reversible
  native account binding even when no React Native auxiliary artifact exists.
  The binding is persisted with the native workspace before onboarding can
  mutate settings or sample data. A new login cannot claim retained unbound or
  differently bound account data; restored sessions provide the upgrade path
  for existing native installations.
- Root progression is now explicit and ordered: live authentication, initial
  cloud pull, onboarding, subscription, starting-point selection, then main app
  content. A returning account's remote settings are loaded before onboarding
  decides whether the account is new.
- Initial sync uses the verified session bearer plus the public Supabase key,
  explicitly filters every request by the verified subject, and rejects any
  response row whose `user_id` or record ID disagrees. It reads only the ten
  existing collection tables, settings, and dormant legacy customer notes; it
  does not upload or delete server data.
- Collection reads drain deterministic 500-row pages. Every endpoint and every
  canonical record must decode before one atomic snapshot save, so a later-page
  or later-table failure cannot publish a partial bootstrap. Remote tombstones
  remove only their matching IDs; same-account local-only records remain until
  Phase 4 supplies a crash-safe outgoing queue.
- The bootstrap retains the React Native merge exceptions: invoice payment
  ledgers union by payment ID with irreversible void precedence and rederived
  `paid`/`paidAt`, while booking history unions by `(at, actor, event)`. Other
  records remain remote-wins whole-record replacements, including additive
  fields unknown to this client.
- Remote settings are merged over the local/default canonical baseline for
  backward compatibility, but provider credentials are stripped before the
  candidate exists in memory or on disk. An unavailable, malformed, or
  unauthorized response leaves local data untouched behind a retryable cloud
  gate.
- Initial-sync responses carry their own local generation and exact subject
  check. A response suspended across sign-out, recovery, or another identity
  transition cannot overwrite the newer account state.
- The native onboarding wizard preserves the React Native two-step contract:
  welcome and subscription disclosure, then required business name, contact
  name, and trade. Partial input and the current step are atomically saved with
  a last-known-good backup under the verified account binding.
- Personalization publishes a commit marker before the canonical settings
  update. A termination between writes replays the validated draft instead of
  skipping setup or losing input. Existing canonical settings fields unknown to
  this client are retained.
- The starting-point screen makes sample versus fresh an explicit choice;
  nothing is preselected or silently seeded. Sample creation uses a persisted
  namespace and timestamp so an interrupted transaction replays the same IDs
  and dates. Preservation-aware upserts retain real records and unknown fields.
- Fresh start removes only native sample IDs. It cannot clear real customers,
  jobs, invoices, expenses, or unrelated canonical families. Completion is
  written only after the canonical commit succeeds.
- RevenueCat is configured only after a Supabase subject is independently
  verified. That stable subject is the App User ID, preserving the existing
  webhook/account ownership contract; anonymous RevenueCat identity is never
  used as the native business-data owner.
- The pinned 5.83.2 SDK and In-App Purchase capability sit between
  personalization and the starting-point choice. Active trials/subscriptions
  advance; inactive accounts remain on a hard paywall until purchase or restore
  returns the exact active `TradeReady Pro` entitlement.
- Current monthly and annual packages use StoreKit-localized prices. Annual is
  preferred when available, and trial copy is shown only from the product's
  real free-trial discount unless the best-effort eligibility check reports the
  account ineligible.
- Missing configuration or entitlement-refresh failure retains the established
  React Native fail-open behavior so a RevenueCat outage cannot hide paid users'
  local business data. An inactive account whose offerings fail to load remains
  on a retryable paywall; third-party diagnostic strings are not rendered.
- Purchase cancellation is silent. Purchase and restore keep the gate closed if
  the returned entitlement is inactive, serialize duplicate taps, and carry
  live trial status into Settings. The hard paywall retains a sign-out escape;
  Settings exposes restore and App Store subscription management.
- Subscription resolutions carry a local generation. A response suspended
  across retry, purchase completion, password recovery, or another stronger
  identity transition cannot overwrite the newer root state.
- Pending deep links and widget/Siri replay remain dormant throughout
  onboarding and run only after the starting-point transaction reaches `done`.
- Passwords exist only in the request body in memory. They are not stored,
  logged, placed in URLs, snapshots, migration journals, or diagnostics.
- A token endpoint response is independently checked through `/auth/v1/user`.
  The two server subjects must agree before the session is published.
- Session writers share the existing serialized identity actor. New and rotated
  sessions use generation chunks and an atomic active pointer in the Keychain.
- Foreground activation revalidates the session. A rejected access token uses
  the refresh-token grant; authoritative rotated credentials are persisted
  before the successor is independently verified. Transport failures, HTTP 408,
  HTTP 429, and server 5xx responses are classified separately from rejection.
  A foregrounded app first preserves its exact in-memory live verification; a
  cold launch may reuse only the matching Keychain identity cache. Changed,
  malformed, never-verified, and explicitly rejected sessions remain closed.
- Exact legacy-owner mismatch is a blocking root state. Choosing another account
  removes the active Keychain pointer and its current generation while retaining
  the prior local business data.
- Fresh native installs no longer seed sample data before authentication. Sample
  versus fresh data remains an explicit post-paywall choice.
- Explicit sign-out revokes only the current device's Supabase session before
  clearing local state. A terminal 401/403 is treated as already revoked.
- The destructive confirmation states that Phase 4 sync is not present and
  native-only records will be removed. If remote revocation is unavailable, a
  separate confirmation is required before device-only sign-out.
- A privacy-safe marker containing only the scrub scope is published before
  cleanup. The primary snapshot, last-known-good backup, and corrupt quarantines
  are removed; App Group widget, Siri, active-trip, and pending-link values are
  blanked under the shared lock; then the active Keychain session and marker are
  removed. Startup resumes an interrupted scrub before migration or snapshot
  loading.
- Immutable legacy migration backups remain recoverable and owner-gated. An
  explicit sign-out cannot turn one of those recovery artifacts into live data.
- Account deletion uses the existing trusted `POST /api/delete-account`
  endpoint with the access token only in the bearer header and no request body.
  A 401 response gets one verified refresh-and-retry; all other ambiguous or
  malformed responses fail closed without removing local data.
- After independently verifying the caller, both backend implementations issue
  one server-only Auth admin deletion. The current public schema's twenty
  user-owned tables were audited to use `ON DELETE CASCADE` foreign keys to
  `auth.users`, so PostgreSQL owns the relational deletion transaction instead
  of a partially-failing series of table REST requests. Private R2 photos are
  purged only after confirmed Auth deletion and are best-effort because R2 is
  outside that transaction.
- The deletion UI matches the React Native `DELETE` confirmation rule after
  trimming and case normalization. Server success triggers the stronger scrub:
  immutable migration recovery, auxiliary activation state, migration metadata,
  support reports, native media, App Group data, migrated provider credentials,
  and the active session are removed before returning to the auth gate.
- The checked-in Release configuration still points to `staging.invalid`, so
  archive builds fail with a configuration message rather than sending this
  irreversible request to production. Staging/device verification is still a
  release prerequisite.
- Sign in with Apple uses AuthenticationServices and the Apple capability that
  already exists in the Expo application. Each authorization creates a
  256-bit, base64url raw nonce; only its SHA-256 digest is sent to Apple, and
  the raw nonce exists in memory only for the matching Supabase exchange.
- Supabase receives exactly `provider`, `id_token`, and the raw `nonce` at the
  `id_token` grant. Its response still must agree with the independent Auth
  user lookup before the generation-based Keychain session becomes active.
- User cancellation is silent and cannot publish a session. Missing identity
  tokens and nonce-generation failures produce bounded user-facing errors.
  The read-only hosted Auth settings check returned `apple: true` on 2026-09-08;
  a real Apple credential exchange still requires signed physical-device proof.
- Google Sign-In is integrated through a version-pinned Swift package and the
  existing iOS and web OAuth client IDs used by the React Native app. The app
  registers the existing reversed iOS client-ID callback scheme and routes only
  matching Google callbacks to the SDK; TradeReady deep links retain their
  existing parser.
- Each Google sheet receives a fresh SHA-256 nonce digest. Only the matching raw
  nonce and returned Google ID token go to Supabase's `id_token` grant; Google
  profile fields and provider access tokens are neither trusted as identity nor
  persisted. The resulting Supabase subject must still pass the independent
  Auth user lookup before Keychain publication or owner activation.
- Google cancellation is silent. Missing tokens, unavailable presentation, and
  SDK failures are bounded errors. Successful TradeReady sign-out, account
  deletion, and resumed local scrub also clear the SDK's local Google credential.
  The read-only hosted Auth settings check returned `google: true` on 2026-09-08;
  an actual account-picker callback and exchange still require a signed device.

## Automated evidence

Run:

```sh
native/run-supabase-auth-tests.sh
native/run-authenticated-identity-tests.sh
native/run-initial-sync-tests.sh
native/run-subscription-tests.sh
native/run-account-deletion-tests.sh
(cd backend-workers && npm test)
native/run-repository-tests.sh
native/run-app-group-pending-open-url-tests.sh
native/run-all-domain-tests.sh
```

The focused suites cover endpoint/method/header/body contracts, email trimming,
absolute-expiry synthesis, invalid-credential and rate-limit mapping,
confirmation-required signup, PKCE challenge and exchange request shapes,
strict recovery-link parsing, secure recovery-state transitions, exact-subject
password update, confirmation resend redirects, independent subject
agreement, atomic session publication, refresh rotation, stale-writer
protection, local-scope session revocation, Apple and Google nonce-bound native
ID-token request shapes, Google cancellation classification, subscription
configuration/identity inputs, fail-open entitlement refresh, active-trial and
inactive-paywall routing, annual preference, trial copy, bounded offering
errors, purchase cancellation, active-entitlement enforcement, restored trial
state, the authenticated deletion request,
closed success parsing, typed-confirmation parity, active-session/provider-key
removal, deletion of every live snapshot fallback, scope-aware marker recovery,
permanent recovery-artifact cleanup, and locked App Group blanking.
The backend suite runs the same dependency-free account-deletion contract
against both the Vercel and Cloudflare cores. It verifies strict bearer parsing,
bounded failures, rate limiting, one Auth-user delete, absence of table-by-table
deletes, and post-delete-only R2 cleanup. The read-only
`supabase/verify/account_deletion_cascade.sql` gate checks the database invariant
required by that transaction boundary. The pinned dependency graph has zero npm
audit findings, both production and staging Worker bundles pass Wrangler
dry-runs, and an inert local smoke of the actual Hono route verifies the bounded
`OPTIONS`, wrong-method, and unauthenticated responses without contacting
Supabase.
Onboarding coverage also exercises new-account creation, denied adoption of
unbound data, atomic draft backup recovery, exact-binding mismatch, and stable
native account namespaces. Initial-sync coverage verifies all production table
reads, owner-filtered bearer requests, multi-page draining, tombstones,
remote-wins replacement, invoice and booking merge exceptions, unknown-field
retention, credential scrubbing, and closed handling of owner mismatch and 401.

The complete app also builds, links, and passes strict signature verification
as a signed Release build for the generic iPhoneOS target with the pinned
Google and RevenueCat packages. The latest clean build was installed on the
signed iPhone on 2026-09-09; the privacy-safe interactive results are recorded
in `docs/native-phase-3-device-matrix.md` and remain partial device evidence.

## Deployment and device gate

Run `native/run-phase-3-device-preflight.sh` before starting signed-device
work, then record the privacy-safe result of every scenario in
`docs/native-phase-3-device-matrix.md`. The preflight fails separately for
checked-in configuration defects and for external prerequisites such as a
missing physical iPhone or the placeholder staging backend; it never prints
client values or device identifiers.

The project owner reports that `tradeready://reset-password` has been added to
the Supabase Auth redirect allow list. Still verify request, Mail/browser
handoff, cold launch, warm launch, expired/reused
link, password update, cancellation, relaunch, and sign-in with the new password
on a signed physical device. The host tests and generic iPhoneOS build do not
prove that external configuration or handoff.

RevenueCat still requires StoreKit sandbox and TestFlight verification of the
live offering, localized prices, trial eligibility, purchase cancellation,
successful purchase, restore under the same and a different TradeReady account,
expiry/lapse, foreground refresh, and App Store subscription-management handoff.

Supabase access JWTs are stateless and can remain valid until their expiration
even after the Auth user and refresh sessions are deleted. The current RLS
policies use owner equality but do not independently require a live
`auth.sessions` row. Before staging can support a permanent-deletion release
claim, test and approve either a short bounded JWT-expiry policy or a
session-aware restrictive RLS policy in the isolated environment. Do not apply
that cross-table authorization change directly to production.

## Remaining Phase 3 work

1. Signed-device recovery, Google and Apple exchanges, initial-sync online and
   offline behavior, onboarding interruption,
   sample/fresh selection, StoreKit sandbox,
   TestFlight, expiry, account-deletion staging, and cross-account
   evidence.
2. Device-matrix rows still Pending: A2-A6, A8, O2-O5, S1-S3, S5-S7, D2-D5
   (A2, A8, D3, S3 and S7 have partial observations recorded but are not
   promoted). Every remaining row needs a signed iPhone, StoreKit sandbox or
   TestFlight, or staging; none is in-repo code work.
3. Account-deletion staging proof: an isolated Supabase project or branch, the
   `supabase/verify/account_deletion_cascade.sql` run, and the choice of a
   residual access-token control (short JWT lifetime or session-aware RLS).
   Owner-gated (D4).
4. The `tradeready://reset-password` redirect allow-list is owner-reported and
   unproven until the A5/A6 device rows pass.
