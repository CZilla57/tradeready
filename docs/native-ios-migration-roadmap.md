# TradeReady Native iOS Migration Roadmap

## Objective

Replace the Expo/React Native iOS application with a native SwiftUI application
without losing customer data, weakening business rules, breaking backend
contracts, or interrupting the production app.

The React Native app remains the production reference until the native app passes
the release gates in Phase 12. Both apps continue to use the existing Cloudflare
Worker and Supabase backend.

## Verification deferral decision (2026-09-16)

The project owner (chadrector) has signed off on **deferring all
physical-device verification and isolated-staging sync evidence to Phase 12**.

Scope and meaning of this decision:

- This is a **deferral, not a waiver**. Every device and staging acceptance row
  that currently gates Phases 2–6 (and any phase before 12) is consolidated into
  the Phase 12 internal-TestFlight and limited-external-beta stages, where the
  evidence will actually be recorded against real devices and real accounts.
- Phases 2–5 are treated as **code complete** and are no longer individually
  release-blocked on device/staging evidence; downstream phases may proceed on
  host evidence (host/XCTest suites, React Native oracle parity, and signed
  Release builds). Their parity rows stay short of `Verified` until the Phase 12
  runs pass.
- The safety constraints below still hold in full: development builds must never
  write to production accounts (Phase 0 build-flag boundary), and the native app
  will **not** replace the Expo App Store build on host or simulator evidence
  alone — Phase 12 TestFlight remains the mandatory gate before cutover
  (constraints 5 and 7).
- No production service is substituted for the missing staging environment during
  ongoing development; the isolated-environment proof is gathered inside the
  Phase 12 beta process rather than as a per-phase precondition.

The consolidated evidence checklist lives in
[native-device-test-runsheet.md](native-device-test-runsheet.md); it is now
scheduled against Phase 12 rather than blocking Phases 2–3.

## Current progress

- Phase 0: **In progress** — inventories and code-level safety controls are in
  place; reference captures, a real staging environment, and operational
  threshold approval remain.
- Phase 1: **Complete** — the complete TypeScript model inventory has
  loss-preserving Swift wire models, a versioned canonical snapshot used as the
  app store's source of truth, and baseline-merge adapters for screen
  projections. Golden suites cover pricing, payments, tax, profitability,
  recurrence, numbering, lifecycle, archive, IDs, canonical persistence, and
  all-family AsyncStorage decoding, with representative XCTest coverage.
- Phase 2: **Code complete; device+staging evidence deferred to Phase 12** (see
  the 2026-09-16 deferral decision above) — all repository code
  deliverables are implemented: atomic snapshots, recovery, journaling, immutable
  source backups, provider-key and opaque Expo auth-session migration, and
  automatic no-overwrite launch import are implemented. A metadata-only,
  privacy-safe migration support report is available from Settings. Every
  auxiliary AsyncStorage value is now captured byte-for-byte in a separate,
  versioned artifact with identity-aware activation policy, and App Group
  queues/trips/deep-link handoffs have strict validation boundaries. Legacy
  auth sessions are reconstructed as raw bytes with strict chunk/service
  validation and published through verified generation chunks plus an atomic
  Keychain pointer. Safely contained JPEG job photos and JPEG/PNG receipts and
  logos are now copied byte-for-byte into deterministic native-owned paths only
  after immutable backup; retry reuses identical copies, destination conflicts
  fail closed, and missing/unsupported references remain recoverable. The
  validated device theme is restored during migration, and an identity-gated
  auxiliary staging boundary now requires exact legacy-owner matching, keyed
  account namespaces, deterministic transactions, serialized commits, and
  privacy-safe receipts. Legacy sync queues, cursors, owner markers, and RN
  completion flags remain inert. Migrated Supabase sessions are checked against
  the live Auth user endpoint; rejected access tokens use the refresh-token
  grant, validate the complete server response, atomically publish a successor
  Keychain generation, and reverify the same server identity before any exact-
  owner state activates. Local session user data and JWT claims are never
  trusted. A digest-authenticated typed consumer exposes only the eight approved
  account-state keys, and the AppStore retains explicit exact-owner proof. The
  first live App Group consumer now uses that proof to route fresh pending job
  and on-my-way links through the same strict parser as direct links without
  mutating cross-process state. On-my-way links open the job, render the migrated
  custom template through a tested channel-aware draft builder, and require
  review in both the native sheet and Apple's system composer before sending.
  The next widget/Siri migration boundary now has a strict, owner-binding-aware,
  loss-preserving batch planner with deterministic source/action digests,
  bounded input, duplicate rejection, ISO/local-date validation, and retention
  of additive and future action fields. Extension writers and the native claim
  transport now share a cross-process advisory lock. The tested transport can
  publish and verify an account-bound private write-ahead claim before removing
  only the claimed shared prefix, recover the narrow crash window without
  dropping concurrent appends, and require exact acknowledgement. Claimed known
  actions now replay through one atomic canonical transaction across jobs, time
  sessions, trips, and expenses; deterministic IDs and embedded action markers
  make post-commit retry idempotent, while future action types remain durably
  unacknowledged. Siri active-trip completion uses the same lock plus a stable
  action identity across append/clear interruption. Decodable PNG, HEIF, WebP,
  and GIF legacy images can be converted to the native JPEG contract while
  immutable originals remain recoverable. The physical-device upgrade matrix
  documented in [native-phase-2-persistence.md](native-phase-2-persistence.md)
  is, per the 2026-09-16 deferral decision, scheduled for Phase 12 rather than
  gating this phase. Continuous
  auth lifecycle belongs to Phase 3, authenticated photo upload/backfill to
  Phase 4, and photo capture/management UI to its later feature phase.
- Phase 3: **In progress** — the first authentication slice now provides the
  SwiftUI root auth gate, email/password sign-in and signup, confirmation
  resend, password-reset email, foreground session revalidation/refresh, and
  atomic Keychain session publication. Foreground outages preserve the exact
  in-memory live verification, while returning cold launches can reopen an
  already owner-bound workspace only when the active Keychain session exactly
  matches the identity from its last live verification. A
  successful token response must agree
  with an independent Auth user lookup before local account state activates;
  owner mismatch blocks the app rather than exposing prior data. Fresh native
  installs no longer seed sample data before the authenticated starting-point
  choice. Explicit sign-out now revokes the current Supabase device session and
  uses a crash-resumable scrub across canonical fallback copies, the locked App
  Group suite, and the active Keychain session; an offline device-only fallback
  requires a second confirmation. Account deletion now matches the React Native
  typed-confirmation rule, uses the authenticated backend boundary, and removes
  recovery-only local artifacts after closed server success. Its Release backend
  remains intentionally unconfigured pending staging validation. Social auth was
  split at its dependency boundary: native Sign in with Apple now has the
  existing capability, one-use nonce exchange, cancellation handling, and
  independent subject verification. Native Google sign-in now uses the existing
  iOS/web OAuth client IDs, a pinned Google SDK, hashed/raw one-use nonce pairing,
  silent cancellation, strict callback routing, and the same verified-session
  publication boundary. Native password recovery now uses a Keychain-backed
  PKCE verifier, an exact custom-scheme callback parser, independent subject
  verification, a recovery-only root gate across restarts, and an exact-subject
  password update that returns to sign-in without deleting local business data.
  The project owner reports the custom redirect is now allow-listed; signed
  device handoff proof remains. Native onboarding now adds a verified-account
  workspace binding, atomic draft/commit recovery, personalization, and an
  explicit replay-safe sample-or-fresh choice that never silently seeds or
  removes real records. The native RevenueCat boundary is now keyed by the
  independently verified Supabase subject and uses the existing public Apple
  SDK key and entitlement. It gates inactive accounts on current localized
  monthly/annual packages, eligibility-aware trial copy, purchase and restore;
  keeps third-party errors bounded; preserves the production fail-open refresh
  policy; and exposes live status and management in Settings. Initial-sync
  ordering is now explicit: after live identity verification, a read-only,
  owner-filtered Supabase bootstrap drains every canonical table before one
  atomic local commit; only then can onboarding, subscription, starting point,
  and main content advance. It preserves local-only records pending Phase 4,
  ports the invoice/payment and booking-history merge exceptions, strips
  credential fields, and rejects partial, malformed, cross-owner, and stale
  responses. The account-deletion backend now verifies the caller before one
  Auth admin delete and relies on an audited database cascade instead of
  non-atomic table REST deletes; mirrored host tests cover both deployed
  backend shapes, and R2 cleanup runs only after confirmed database deletion.
  On 2026-09-09, preflight found an available physical iPhone and passed all
  checked-in configuration contracts except the intentionally placeholder
  staging deletion backend. A clean signed Release build was installed and
  supplied partial Apple, Google, initial-sync, isolation, and subscription
  evidence recorded in the device matrix. Continuous push/pull sync and the
  remaining signed-device, isolated-staging, StoreKit, and TestFlight evidence
  remain.
- Phase 4: **In progress** — the read-only initial-sync pull (Phase 3) already
  drains every collection with owner filtering and server-authoritative merges.
  The write path now has automated coverage. A durable, versioned mutation queue
  records local changes as idempotent `upsert`/soft-`delete` items, de-duplicates
  last-writer-wins per `(table, recordId)` so an upsert followed by a delete
  collapses to one payload-free delete, diffs a collection save into per-record
  changes matching the React Native contract, recovers a corrupt or unknown-schema
  file to an empty queue, retains a last-known-good backup on each write, and
  supports sample-id prune and cross-owner/account-deletion scrub. A push
  transport drains the queue to Supabase's Data API: collection rows upsert under
  `data` with `Prefer: resolution=merge-duplicates`, settings and customer notes
  use their bespoke row shapes, deletes are owner-scoped soft updates, secure
  settings keys are scrubbed, `updated_at` is never sent because the database
  stamps it authoritatively, an id/blob mismatch fails closed and is dropped
  rather than wedging the queue, transient failures are retained for retry, an
  unauthorized response flags the session for refresh, and every failure exposes
  only a bounded stage/table/status diagnostic. The direct Data API path now
  has its own fail-closed runtime environment boundary: development/staging may
  write only with a valid HTTPS origin and publishable key distinct from the
  configured production references; production requires exact origin/key
  matches and the explicit production-write switch. The production key reference
  is checked against the React Native production client without printing either
  value. A blocked pass sends no request, retains the durable
  queue, skips the pull that could overwrite pending local edits, and exposes
  only `push/environment`, while auth and read-only initial recovery remain
  available. AppStore is now wired to the
  queue: every local job/invoice/customer/expense upsert and delete and every
  settings change enqueues a mutation (deletes only when the record existed;
  settings scrubbed of secure keys before reaching the plain queue file), and
  every account boundary — explicit sign-out, account deletion, and the
  crash-recovered scrub on next launch — clears the queue so a new owner never
  inherits the previous account's pending writes. A reachability-aware sync
  coordinator now schedules the push. It serializes passes and coalesces a
  trigger that arrives mid-pass into a single follow-up run; skips cleanly when
  the queue is empty, the device is offline, the user is signed out, or a
  transient-failure backoff window is still open; grows an exponential backoff on
  each failure and resets it when the queue fully drains; persists only the
  unacknowledged remainder; and, on an unauthorized response, refreshes the
  session once through the server-verified activator and retries the remainder,
  persisting progress first so a crash mid-refresh cannot re-send accepted items.
  Every outcome is a bounded, identifier-free status. AppStore drives it on
  sign-in transitions (via the gate state), app foreground, and every local
  change; production reachability is backed by `NWPathMonitor`. A one-time,
  per-account backfill closes the gap the per-write hooks leave: records that
  entered the snapshot through legacy migration or sample-seeding never passed
  through the mutation methods, so on the first completed initial sync for an
  account the entire local snapshot is enqueued once — every collection row, the
  secure-scrubbed settings blob, and each customer note — under a durable
  per-subject flag that is cleared at every account boundary. The enqueue is
  idempotent (queue last-writer-wins dedup plus a `merge-duplicates` upsert) and
  offline-safe, so a lost flag or a partial run cannot create duplicate or stale
  cloud rows. The read-only bootstrap is now complemented by a cursor-based
  incremental pull. A versioned per-table cursor stores each collection's
  high-water mark as the raw **server** `updated_at` string (never a device
  clock), resumes each pass five minutes behind that watermark so a
  late-committing transaction is still seen, and reads a missing, corrupt, or
  wrong-version cursor file as empty — costing one safe, idempotent full pull
  rather than silently skipping changes. The delta fetch is owner-scoped and
  ordered `updated_at.asc,id.asc`, reuses the identical merge logic as the full
  pull (including the invoice payment-ledger union and booking-history merge
  exceptions), isolates a per-table transport/contract/decode failure by leaving
  that table's watermark unadvanced for the next pass instead of discarding the
  siblings that succeeded, and throws on an auth rejection so the caller can
  refresh. Settings and customer notes have no per-table cursor and are
  re-fetched each pass, exactly as the React Native client does. AppStore drives
  the pull after each push through the coordinator's pull hook: it commits the
  merged snapshot and advanced cursor atomically, leaves both untouched on any
  failure, re-checks the active owner across the network await so another
  account's rows are never applied, and refreshes-and-retries once from the
  original cursor on an auth rejection. The cursor file is scrubbed at every
  account boundary (crash-recovered launch scrub, explicit sign-out, and account
  deletion) alongside the queue and backfill flag, so a new owner never resumes
  from the previous account's watermarks. Two-device convergence is now covered
  by an automated suite that backs both client directions with one in-memory
  Supabase model (server-authoritative monotonic `updated_at`): new records
  propagate both ways, concurrent edits to one record converge to the last
  writer with no duplicate, deletes propagate as tombstones, a device that pulls
  a concurrent invoice overwrite keeps its own payment via the ledger union, and
  an offline queue survives a simulated relaunch and replays idempotently with no
  duplicate server row. Sync state is now observable in SwiftUI: a compact banner
  appears only while syncing or when work is offline, pending, or failed; Settings
  exposes the durable pending count, session completion time, next retry, manual
  retry, and a bounded diagnostic code. Transient push and pull failures now
  schedule their own exponential-backoff retry instead of waiting indefinitely
  for another foreground/edit trigger. Unsynced sign-out offers a race-free
  sync-first path and preserves the account when changes still cannot upload;
  account-boundary scrub also cancels the prior account's retry and status state.
  Background refresh is now registered before launch completion with the
  required plist contract, a 30-minute-earliest idempotent request, rescheduling
  at delivery, and expiration cancellation with exactly-once completion. A cold
  background launch can attach the stored session only after the existing live
  verification/refresh path yields an owner binding that exactly matches a
  completed local workspace; it cannot advance foreground account gates or
  adopt an unbound snapshot. Host tests cover scheduling, completion,
  expiration, and owner/workspace rejection. Authenticated job-photo byte
  transfer/backfill is now wired after metadata sync for initial, foreground,
  and background passes. It uses only the current Supabase bearer token against
  the existing worker, validates the shared ID/JPEG/6 MiB contract, preserves
  every local source, queues `uploadedAt` only after a confirmed PUT, installs
  validated downloads atomically without overwrite, and re-checks the exact
  owner across every await. Metadata plus deterministic file presence make both
  directions crash-resumable without a lossy completion flag. A modeled React
  Native reference client now exercises the shipped collection wire shape
  against the production Swift push/pull services and shared in-memory Data API:
  React Native-origin upserts and deletes reach Swift, Swift-origin changes reach
  the React Native model, and the database clock defeats both future and stale
  client timestamps. Remaining Phase 4 work is physical-device background,
  job-photo, React Native/Swift concurrency, and network-interruption evidence
  for the exit criteria, which the 2026-09-16 deferral decision schedules for
  Phase 12. A privacy-safe preflight now blocks placeholder or
  mismatched staging, a production-origin guard that disagrees with the Worker,
  a production-key guard that disagrees with the React Native client,
  missing SQL verification, and insufficient physical devices before the unified
  `native-phase-4-device-runsheet.md` begins. On 2026-09-13, the signed generic-
  iPhone Release build completed successfully and the aggregate native migration
  suite passed, including the background-refresh, job-photo, mixed-client,
  AppStore-integration, preflight-fixture, and backend-parity coverage. That host
  evidence closes the outstanding compile/link check but does not replace any
  physical-device row. On 2026-09-13, the owner declined provisioning a staging
  project and directed the migration to continue without it. On 2026-09-16 the
  owner signed off on deferring the outstanding device and staging evidence to
  Phase 12 (see the deferral decision above): Phase 4 is treated as code
  complete and no longer per-phase release-blocking, while TestFlight in
  Phase 12 remains the mandatory gate before any Expo replacement and no
  production service is substituted for the missing staging environment.
- Phase 5: **Code complete; verification pending** — the first pure customer-
  identity layer ports React Native's ID/name resolution, invoice-derived list
  entries, paid/owed rollups, blank-only invoice contact backfill, archive
  projection, and normalized duplicate detection. The SwiftUI customer list and
  detail screens now consume that shared identity layer, show invoice-derived
  customers without silently creating records, allow explicit promotion into a
  canonical customer, and use reversible soft archive/restore for stored
  customers. Archive changes preserve the canonical baseline and replace the
  pending customer upsert atomically through the existing durable queue. The
  active-customer list now presents React Native-equivalent possible-duplicate
  suggestions, selects the lower-history/newer record for review, and supports
  dismissal without mutating any business record. Dismissals are migrated from
  authenticated legacy account state into a versioned, exact-owner-bound local
  file, use atomic writes with a last-known-good backup, refuse to overwrite an
  unreadable source, and are included in crash-recoverable sign-out/account-
  deletion scrub. Customer detail now also performs the React Native winner/
  loser merge across customers, jobs, invoices, recurring jobs, and recurring
  invoices as one loss-preserving canonical commit. Blank winner contact fields,
  distinct notes, and the earliest creation date reconcile without discarding
  canonical-only or unknown fields; one atomic mutation-queue batch publishes
  the winner, loser tombstone, and every re-pointed record. A short-lived global
  Undo restores only those affected records and fails closed if any post-merge
  local or remote edit has changed their exact wire state.
  Customer create/edit now uses MapKit's address-only live completions, limits
  the list to five normalized unique values, ignores obsolete asynchronous
  results, and labels selected/no-result/unavailable states. Lookup is advisory:
  free-form address bytes remain editable and savable offline, so a search
  outage cannot discard or block customer data. This replaces the React Native
  screen's direct public-Nominatim autocomplete dependency, which the provider's
  current usage policy forbids.
  Today now also opens a native global search whose pure matcher preserves the
  React Native field sets, newest/alphabetical/latest-due ordering, archived
  job/customer exclusion, eight-result section caps, and true result totals.
  Search adds explicit new-job, new-customer, and new-invoice actions. Selecting
  an existing result verifies its local ID, changes to the owning tab, and
  installs a one-shot navigation request so the exact detail destination opens;
  missing or archived records fail closed. Customer and invoice requests are
  cleared with job requests during account scrub, and the projected job archive
  marker remains canonical-loss-preserving.
  A shared local-first interaction state now distinguishes usable content,
  initial loading, true-empty collections, search/filter misses, and initial
  failures without hiding cached records behind a transient sync error. Root
  authentication/subscription loading and retryable cloud/auth failures use the
  same accessible presentation, including the existing alternate-account
  recovery path. Jobs, invoices, customers, and global search now use consistent
  empty/no-match states with explicit reset actions and native pull-to-refresh.
  Refresh awaits the manual sync coordinator pass (which bypasses retry backoff)
  and observes the canonical snapshot published by its delta pull; offline and
  failed passes retain local content and continue through the existing bounded
  sync banner rather than fabricating a successful reload.
  Customer and job detail contact actions now normalize recipient values before
  crossing the system boundary, present reviewed in-app Messages/Mail drafts
  when available, fall back to recipient-only system URLs, and offer to copy
  the contact value when the device cannot handle the action. No path sends a
  message automatically.
  Customer detail history now orders jobs by latest scheduled date and invoices
  by latest due date. Invoice rows reuse the exact-ID cross-tab router, so a
  stale or missing invoice fails closed, and detail pull-to-refresh awaits the
  same real coordinator pass as the primary lists without hiding local history.
  The detail screen can also create an invoice draft with the exact saved
  customer ID and current contact fields, or without inventing a link for an
  invoice-derived identity. Notes edit inline; saving preserves every other
  customer field and explicitly promotes an invoice-derived identity into a
  canonical customer without rewriting historical invoices. Customer editor
  and inline-note saves dismiss only after the canonical snapshot is durably
  committed, while a failure keeps the draft visible and reports that existing
  data was preserved.
  A typed shared confirmation surface now guards job, invoice, and customer
  deletion plus customer merge. Requests carry stable record IDs rather than
  captured model values, and each confirmed mutation resolves current canonical
  state again before writing; invoice deletion explicitly warns that its
  embedded payment history is removed, while customer deletion states that job
  and invoice history remains. Merge retains its portal-link warning and uses
  the existing exact-wire conflict-safe undo.
  Confirmed job, invoice, and customer deletion now preserve the exact canonical
  record in an eight-second app-wide undo token, including unknown fields,
  original list position, and invoice payment history. Deleting a customer does
  not rewrite or remove its linked jobs or invoices. Undo restores only while
  the ID remains absent, atomically replaces the queued tombstone with the
  preserved upsert, and retains newer mutations that arrive while the tombstone
  is already in flight. Remote pull waits while any local mutation remains
  pending, preventing a server tombstone from hiding the restored record before
  its upsert lands. A recreated ID fails closed rather than being overwritten.
  Focused host tests, the aggregate migration suite, and a signed generic-iPhone
  Release build pass, including merge/undo, address lookup, global search, and
  shared interaction-state, customer-contact fallback, and typed-confirmation
  resolution, plus record-delete undo and in-flight queue reconciliation.
  Customer-editor saves now trim persisted text and match the React Native
  create-only duplicate rule: an existing trimmed/case-insensitive name blocks
  creation without dismissing or mutating the draft, while edits and advisory
  phone/email similarities remain allowed for merge review. All planned Phase 5
  code deliverables are now implemented and host-tested. The phase remains open
  only for physical-device interaction evidence and trusted-staging sync proof;
  customer portal administration remains a separate Phase 8 deliverable.
- Phase 7: **Code complete; verification pending** — every planned code
  deliverable is implemented and host-tested (see the Phase 7 evidence table
  in [native-phase-7-implementation-plan.md](native-phase-7-implementation-plan.md)
  and the deferred device rows in
  [native-phase-7-device-runsheet.md](native-phase-7-device-runsheet.md)).
  Invoice list/edit/detail, atomic idempotent payments with job
  reconciliation, Stripe Connect plus provider settings and link policy,
  full invoice PDF contract and paginated renderer, reviewed outreach and
  bulk actions, recurring-invoice generation and rule management, resumable
  auto-send preparation, and `inv_`/`rinv_` notifications are done.
  Simultaneous-offline recurring generation diverges (React Native-parity
  limitation pinned by test). The phase remains open only for
  physical-device interaction evidence and trusted-staging sync proof.
- Phase 10: **Code complete; device+staging evidence deferred to Phase 12** (see
  the 2026-09-16 deferral decision above) — every planned Today, proactive-
  insights, AI-coach, notification, and post-sync derived-state deliverable is
  implemented and host-tested (see the Phase 10 execution ledger in
  [native-phase-10-implementation-plan.md](native-phase-10-implementation-plan.md)
  and the frozen contracts/deviations in
  [native-phase-10-today-coach-notifications-contract-decisions.md](native-phase-10-today-coach-notifications-contract-decisions.md)).
  The Today surface (schedule, stats, overdue/lead briefings, booking/portal
  attention rows, first-action hero, setup checklist, insights card), the
  business-snapshot and eight-rule proactive-insights engines with mute/snooze
  lifecycle, the AI coach (provider routing, system prompt, transcript,
  markdown-lite, quick prompts, insight-handoff prefill), all five notification
  namespaces with unified reconciliation and exact-owner tap routing, and the
  post-sync derived-state seam (notification reconcile + cached business
  snapshot refresh, exactly once per committed sync pass) are done. Cross-
  engine qualification against a shared fixture (task 10.14) proves
  determinism and idempotent-reconcile-twice behavior. The final whole-branch
  review's fix wave (2026-09-23) made archived jobs route from Today and
  notification taps (RN parity, contract §9.6), made the coach build its
  business snapshot from live data, removed an inert AI-privacy toggle,
  registered every unregistered host runner behind a guard in
  `native/run-all-domain-tests.sh`, and closed the 10.09 (c) gate: every
  derived-state publish now requires an exact owner workspace, and
  `registerDerivedStateObserver` documents that observers fire only for an
  exact workspace — an explicit **11.01 entry precondition**. Four
  implementation gates stay open and unwaived (all implementation gates,
  host-testable, not device evidence, except where noted): the Stripe account-switch write race
  is proven only through a pure predicate, not end-to-end (no injectable
  Stripe service seam yet); the coach `sending` flag could stay stuck if the
  Coach view ever survives an account boundary without RootView's existing
  teardown running first; a newer post-sync publish that fails inside
  `makeSnapshot` leaves the cached business snapshot on an older,
  already-superseded commit; the three pre-commit failure diagnostic codes
  `pull/local-commit`, `pull/cursor-commit`, and `pull/authentication` each
  rely only on source-level inspection of an unconditional pre-`publish`
  `return`, with no automated test independently forcing any of the three.
  (The fifth gate, the post-sync publish running when
  `advancePastInitialSync` ends in `.accountMismatch`/`.unavailable`, is
  closed by the final-review fix wave, I6, with a forcing test.) Device,
  permission, live-AI-provider, and background-delivery evidence remain
  deferred to Phase 12 per
  [native-phase-10-device-runsheet.md](native-phase-10-device-runsheet.md),
  which also tracks the four open gates above.
- Phase 11: **Code complete (tasks 11.00–11.15, closed out by 11.14 on
  2026-09-24); device, extension, Siri, live-SDK and store evidence deferred to
  Phase 12. Not `Verified`.** The Phase 11 final whole-branch review's fix wave
  is done (plan §7, "Final review fix wave"). Delivered and host-tested: a WidgetKit extension
  (`TradeReadyWidgets.appex`, embedded in the app) with Next Job (small, medium) and
  Job Timer widgets over an owner-tagged App Group snapshot that RN's own
  `BridgeSnapshot` decoder reads; all ten App Intents (eight Siri shortcuts plus the
  widget's Start/Stop Timer) appending owner-tagged actions to the locked App Group
  queue and replaying through the normal save paths; owner, stale-data and
  sign-in gating for widgets, Siri and cold/warm deep links; PostHog analytics (52-event
  catalog, 49 live natively) with an allow-list, identity lifecycle and screen map;
  Sentry crash reporting with a redactor and a dSYM upload script; app and extension
  privacy manifests; AI-provider key entry; an accessibility audit and re-audit with
  zero release-blocking findings; the iPad content column and hardware-keyboard
  shortcuts; privacy-safe signposts, a poor-network suite and a soak protocol; and a
  cross-client qualification suite against RN's decoders, vectors and call sites.
  Evidence: `TZ=America/Phoenix sh native/run-all-domain-tests.sh` (every one of the
  120 runners registered) and the unsigned generic Release build pass. The signed
  local Release build did **not** complete: the widget extension has no provisioning
  profile with the App Group, and Xcode has no signed-in developer account to create
  one (plan §7, 11.14). Every device row is in
  [native-phase-11-device-runsheet.md](native-phase-11-device-runsheet.md). Two
  cutover-blocking parity gaps are owned by Phase 12.00 (see Phase 12 below): no
  native remote push notifications (G1) and no native tax-settings screen (G2).
  Carried to Phase 12 as owned items: the RN AsyncStorage source-file retention policy
  (G6, 12.00), the first-party data in the privacy labels (12.01), the Sentry
  `tradeready-ios` project (12.01/12.02) and the 429 push policy (12.00/12.02). Of the
  five known code issues sent to the final review (runsheet OI-4), four are fixed; the
  sync-push 4xx wedge (I2) is a cutover-blocking defect owned by Phase 12.00 (see
  Phase 12 below).
- Phases 8–9 and 12: **Not started** (tracking note: Phase 8's contract
  decisions and Phase 9's implementation plan/device runsheet already exist as
  in-flight artifacts from earlier work on this branch; their roadmap status
  lines were not reconciled by this Phase 10 closeout task and remain as
  written pending that phase's own closeout).

Tracking details: [native-parity-matrix.md](native-parity-matrix.md),
[native-phase-2-persistence.md](native-phase-2-persistence.md), and
[native-phase-0-baseline.md](native-phase-0-baseline.md). Phase 1 evidence is
recorded in [native-phase-1-domain.md](native-phase-1-domain.md). The remaining
physical-device evidence for Phases 2 and 3 is tracked as a single working
checklist in [native-device-test-runsheet.md](native-device-test-runsheet.md).

## Guiding constraints

1. Preserve the existing bundle identifier, signing team, URL scheme, and App
   Store record.
2. Never change the production data format without backward compatibility.
3. Port business rules into testable Swift modules before wiring them into UI.
4. Treat every placeholder button as incomplete even when its screen exists.
5. Ship through internal TestFlight first; do not replace the Expo build based on
   simulator testing alone.
6. Each phase must meet its exit criteria before dependent phases begin.
7. Backend changes must remain compatible with the current React Native release
   until the migration is complete.

## Definition of parity

A feature is migrated only when all five conditions are true:

- Its complete persisted data shape is supported.
- Its business rules match the React Native implementation.
- Its loading, empty, error, offline, and destructive states are implemented.
- Its backend/platform integration works on a physical device.
- Automated tests cover its critical paths and migration behavior.

---

## Phase 0 — Baseline and migration controls

**Goal:** Make parity measurable and prevent accidental production replacement.

### Deliverables

- Inventory every React Native screen, workflow, storage key, backend endpoint,
  deep link, notification type, analytics event, and entitlement.
- Create a feature-parity matrix with `Not started`, `In progress`, `Blocked`,
  `Tested`, and `Parity verified` states.
- Capture golden fixtures for customers, jobs, estimates, invoices, payments,
  expenses, settings, recurring rules, bookings, and portal data.
- Capture reference screenshots and screen recordings on supported iPhone and
  iPad sizes in light mode, dark mode, and large Dynamic Type.
- Add an explicit native build flag/environment so development builds cannot
  write to production accidentally.
- Document backend compatibility and rollback ownership.

### Exit criteria

- Every current feature has an owner, test reference, and acceptance statement.
- Native builds use development accounts and backend configuration by default.
- A rollback to the latest Expo release is documented and rehearsed.

---

## Phase 1 — Canonical Swift domain layer

**Goal:** Establish lossless data compatibility before adding more UI.

### Deliverables

- Port every type from `types/models.ts` into versioned `Codable` Swift models.
- Include materials, direct costs, labor breakdowns, payments, estimate
  approvals, change orders, recurring work, photos, mileage, pricebook,
  bookings, portals, archives, and complete settings.
- Add tolerant decoding for older and additive-optional records.
- Port IDs, date handling, currency precision, status derivation, archive rules,
  invoice numbering, recurrence, payment math, and pricing math.
- Replace floating-point financial calculations where necessary with a defined
  decimal/cents representation.
- Add fixture-based XCTest coverage comparing Swift results with golden outputs
  from the React Native test suite.

### Exit criteria

- Swift decodes and re-encodes all golden fixtures without losing meaningful
  fields.
- Pricing, payment, tax, recurrence, status, and profitability fixtures match
  the React Native results.
- No production workflow depends on the simplified prototype models.

---

## Phase 2 — Persistence and upgrade migration

**Goal:** Prove that an App Store upgrade preserves local data.

### Deliverables

- Create a versioned native repository layer with atomic writes and corruption
  recovery.
- Finish AsyncStorage import, including large manifest values, every storage key,
  secure fields, photos, and app-group/widget data.
- Make migration idempotent and resumable after interruption.
- Write a migration journal recording started/completed versions without storing
  secrets.
- Back up legacy files before conversion and retain them until cloud verification
  succeeds.
- Adopt supported local photo bytes non-destructively with stable IDs, strict
  source containment, atomic no-overwrite publication, and retained deferred
  references; defer image conversion and cloud activation until their identity-
  aware clients exist.
- Add import/export diagnostics suitable for support without exposing private
  customer data.

### Exit criteria

- Real-device upgrade tests succeed for clean installs, sample accounts, large
  accounts, offline accounts, and partially synced accounts.
- Re-running migration creates no duplicates or data loss.
- A failed migration leaves the Expo-format data recoverable.

---

## Phase 3 — Authentication, onboarding, and subscription gate

**Goal:** Reproduce the production entry flow and identity boundaries.

### Deliverables

- Supabase email/password authentication and session restoration.
- Sign in with Apple and Google sign-in.
- Password reset, email confirmation, sign out, and account deletion.
- Keychain-backed token and secret storage.
- Onboarding draft, onboarding completion, and starting-point/sample-data flow.
- RevenueCat integration, entitlement checks, paywall, purchase, and restore.
- Root loading gates that wait for authentication, initial sync, onboarding, and
  subscription state in the correct order.

### Exit criteria

- New, returning, expired-session, trial, subscribed, and unsubscribed accounts
  land on the correct screen.
- Switching accounts cannot expose the previous account's local data.
- Purchase and restore work in StoreKit sandbox and TestFlight.

---

## Phase 4 — Cloud synchronization and offline behavior

**Goal:** Make the native app safe for real customer data.

### Deliverables

- Port Supabase collection pull/push contracts.
- Enforce a runtime origin/key environment boundary on direct Supabase mutation
  writes.
- Port the mutation queue, cursors, backfill flags, merge rules, and ownership
  guards.
- Apply server-authoritative payment, estimate, change-order, booking, and portal
  decisions without overwriting newer local edits.
- Add reachability-aware retries, exponential backoff, foreground sync, and
  background refresh.
- Mirror authenticated job-photo bytes after metadata sync with exact-owner,
  atomic-download, source-preserving, and interruption-resume guarantees.
- Implement sync status UI and actionable error diagnostics.
- Add concurrency tests for edits from two devices and edits made offline.

### Exit criteria

- Two-device test suites converge without duplicates or lost updates.
- Network interruption during any write recovers automatically.
- React Native and Swift clients can use the same account concurrently during
  the transition.

---

## Phase 5 — Customers, search, and shared interaction infrastructure

**Goal:** Finish the shared primitives required by jobs and invoices.

### Deliverables

- Complete customer create/edit/detail/history and contact actions.
- Customer identity reconciliation, invoice contact backfill, duplicate
  detection, merge, archive, and restore.
- Address lookup and validation.
- Global search across customers, jobs, invoices, and actions.
- Shared undo, confirmation, error presentation, loading, empty, refresh, and
  offline components.
- Native mail and SMS composers with graceful device-capability fallbacks.

### Exit criteria

- Customer rollups match production fixtures.
- Merge and archive operations are reversible and sync correctly.
- Global search routes to the exact requested native destination.

---

## Phase 6 — Jobs, estimates, and field operations

**Goal:** Port the complete lead-to-completion workflow.

**Status: In progress.** The first dependency-gated job-list slice now ports
React Native's Active, Quotes, Complete, Paid, Declined, All, and Archived
groups, including exact archive boundaries, counts, rare-chip fallback, search,
newest-first ordering, and the three top-line stats. Billable display values add
only approved, non-cancelled change orders with link-decision precedence and
cent rounding. Recurring and archive markers are read directly from a list-only
canonical projection so editing the simplified SwiftUI job cannot flatten
recurrence, costs, change orders, or unknown fields. Job create/edit now reports
success only after the local canonical snapshot is durably committed, and
archive/restore replaces the pending job upsert through that same local-first
path. The full quick-action destinations intentionally remain hidden until the
dependent pricing, invoice, and status-transition screens can fulfill their
labels instead of routing to placeholders. On 2026-09-15, the focused pure list
and canonical AppStore integration tests passed, 45 React Native filter/archive/
change-order oracle tests passed, the aggregate native migration and backend
suite passed, and the signed generic-iPhone Release build completed. This is
host evidence only; Phase 6 device and end-to-end workflow verification remain.
The next job-workflow slice adds reviewed, loss-preserving duplication. A new
job carries only the React Native descriptive and pricing whitelist, including
exact material records, while clearing schedule, status, invoice, approval,
recurrence, photos, time sessions, labor breakdown, direct costs, change
orders, archive/import metadata, and source-level unknown fields. The source is
never mutated; Cancel writes nothing, saving retains the hidden pricing through
a canonical draft template, and a newly occupied ID fails closed instead of
overwriting. Arbitrary status editing has also been removed. Detail now offers
only the direct one-step estimate-sent to approved, scheduled to in-progress,
and in-progress to complete transitions, each guarded by the exact status shown
when tapped; approved jobs route through the schedule editor. Pricing/estimate,
completion invoice automation, declined revision, and review-request actions
remain gated on their dedicated Phase 6 workflows.
The pricing-calculator UI is now wired to the existing golden-tested Decimal
engine. It exposes labor and emergency rates, editable materials, material
markup, typed direct costs with pass-through/tax/customer-visibility policy,
overhead, true margin, minimum fee, travel, tax, low/recommended/high range,
break-even, and an arithmetic breakdown. Existing nested material/direct-cost
preservation metadata stays attached while editing. At save time AppStore
re-resolves the latest canonical job, changes only calculator-owned fields and
the computed estimate total, commits locally before dismissing, and queues the
canonical upsert; concurrent description/lifecycle/approval/recurrence/photo/
time/change-order/archive/unknown changes are not replaced. Travel, emergency,
and tax remain calculation inputs rather than new job wire fields, matching the
current React Native save contract.
The calculator now also supports the canonical four-bucket labor breakdown
(on-site, drive, supply-run, and setup/cleanup time), keeps their sum as the
single billable labor-hours value, retains the non-billable note, and presents
the React Native sanity and travel double-charge checks as advisory warnings
that never block saving.
Lead jobs with saved pricing can now open a native estimate review. The review
is frozen from the current canonical job, uses the stored estimate total as
truth, includes only customer-visible direct costs, and folds hidden/internal
pricing into the residual operating-cost line. The owner can edit the prepared
email or text before continuing to Apple's Mail or Messages composer; the app
does not auto-send. A separate explicit mark-as-sent action commits the exact
lead-to-estimate-sent transition and local follow-up date before queuing the
canonical upsert, with an expected-status guard preventing a stale review from
overwriting newer sync state. Native approval-link creation now pushes that
stamp, requires a completed authoritative pull, and rechecks the complete
customer-facing snapshot before calling the existing authenticated Worker. The
server alone mints the capability token and durably attaches the frozen
snapshot; the native app then commits the same token, server time, and snapshot
locally before queuing an idempotent mirror. Exact-owner checks surround every
await, one verified bearer is used with a single refresh retry, malformed links
fail closed, approved snapshots remain immutable, and link creation never sends
Mail or Messages automatically. The reviewed estimate can now be exported as a
native PDF without rereading or mutating canonical job state. The renderer
consumes the same frozen customer-facing approval snapshot, includes customer
and business contact details, an available local logo, issue date, every
reviewed line item, the authoritative total, and the full scope across
additional pages. Export uses a sanitized temporary filename and the system
share sheet, removes its temporary directory after dismissal, and neither marks
the estimate sent nor contacts the customer. Missing or unreadable logo bytes
omit only the logo. Mail and Messages completion is now typed: only Apple's
explicit `.sent` result records delivery, while cancel retains the edited
review, a saved Mail draft stays unrecorded with a clear notice, and failure
keeps the draft available for retry. Before a confirmed delivery advances a
lead or re-arms an estimate-sent follow-up date, AppStore rebuilds the latest
customer-facing snapshot and requires exact equality with the reviewed copy;
newer pricing or lifecycle state is preserved rather than mislabeled as sent.
The review now also exposes deterministic copy and regenerate actions without
adding a network or AI dependency. Copy uses the exact visible text and
includes the subject for email. Email and text edits are retained separately
while switching channels; regeneration affects only the visible channel,
retains an existing approval link, and asks before replacing user edits. None
of these actions writes canonical state or changes delivery timestamps.
Declined-estimate revision is now history-preserving and server-authoritative.
The authenticated `revise-declined` operation owner-filters the job, requires
the exact active capability token and a declined decision, appends that approval
unchanged to additive `approvalHistory`, clears the active approval and sent
date so the old link stops resolving, and returns the job to Lead in one
`updated_at`-conditional write. A concurrent change yields a conflict rather
than an overwrite, and retries after a completed write are idempotent. Native
syncs and rechecks the exact owner before requesting revision, validates that
all prior history and consent metadata survived the response, refuses to
replace any local job that changed during the await, installs the authoritative
job durably, and opens pricing. The job detail keeps prior snapshots, totals,
signer, and decline reasons visible without exposing tokens or network
metadata. An unchanged declined snapshot cannot be sent again; the owner must
materially revise its customer-facing estimate first. Approved estimates stay
immutable. Native estimate follow-up now ports the React Native eligibility and
copy contract as dependency-free Swift: the latest local send stamp wins over
the approval timestamp fallback, malformed dates fail closed, the one-shot
reminder is derived for 9:00 a.m. local three calendar days after send, the
persistent awaiting-response selector starts after three elapsed days, and
deterministic editable copy uses the canonical job title and quote amount. A
thin UserNotifications coordinator owns only the `est_` namespace, preserves
other pending notification families and their priority under the shared
60-request ceiling, and schedules only while permission and the exact verified
workspace binding both remain valid across suspension points. Sign-out,
account change, toggle-off, and denied permission remove pending `est_`
requests without deriving customer-visible content. Notification taps validate
the typed payload and recheck the exact signed-in workspace plus current job
state before opening an editable Mail/Messages review. The Today row uses the
same setting and remains visible after the one-shot reminder expires. No path
auto-sends or mutates the job. Analytics, physical-device notification/tap and
composer proof, and withdrawal of an undecided live approval link remain gated.
Focused canonical adapter, approval-link transport, and AppStore tests cover
reviewed duplication, pricing-only merges, labor warnings, frozen estimate
construction, exact post-sync snapshot comparison, server response validation,
and the local-first sent stamp; the React Native duplication/lifecycle oracle
contributed 73 passing assertions, the pricing/input/direct-cost oracle
contributed 69, and the estimate-snapshot/time-and-trip focused oracle passes.
The focused PDF document contract, the unchanged 32-test React Native PDF
oracle, the aggregate native/backend suite, and a signed generic-iPhone Release
build also pass on 2026-09-16. Physical-device sharing and visual comparison
against golden PDFs remain open.
The focused delivery policy and canonical AppStore tests, the 33-test React
Native messaging/follow-up oracle, the aggregate native/backend suite, and the
signed generic-iPhone Release build also pass. Physical-device Mail/Messages
result handling remains open.
The focused deterministic message-drafting contract, the 33-test React Native
estimate-message oracle, the aggregate native/backend suite, and a signed
generic-iPhone Release build pass for the copy/regenerate slice. Physical-device
clipboard, keyboard, and channel-switch interaction proof remains open.
The focused native follow-up policy and notification-coordinator suites and the
unchanged 17-test React Native follow-up oracle pass. Coverage includes payload
validation, permission denial, namespace-scoped cleanup, the shared cap,
isolated scheduling failure, signed-out behavior, and an owner transition
during an OS scheduling suspension. The aggregate native/backend suite and a
generic-iPhone Debug compile with code signing disabled also pass on 2026-09-19.
Analytics and physical-device notification, Today-row, tap-routing, and system
composer proof remain open.
The first native change-order slice now ports the React Native canonical
mutation contract without introducing a second UI model. Derived status keeps
cancellation above every decision and a server-stamped link decision above an
on-site decision; only approved, non-cancelled orders affect the billable
total. Create is limited to approved, scheduled, in-progress, and complete
jobs; title, signed amount, below-zero credit, cent-rounding, pending-only edit
and delete, separate verbal approval/decline, and one-way cancellation rules
are golden-tested against the existing JavaScript oracle. Every AppStore
action re-resolves the current canonical job and order by ID, changes only the
fields owned by that action, durably saves before publishing, and replaces the
job's queued upsert. A decision or cancellation that arrives while an editor
is open therefore makes its later save fail closed, while link approval data,
the estimate baseline, and unknown forward-compatible fields survive. The
same slice fixed a half-cent reconciliation drift: native job-list and invoice
derivations now round the approved change-order subtotal before adding it to
the estimate, matching React Native's two-stage rounding. Two-stage rounding
now matches the JavaScript oracle exactly, including negative half-cents
(`-1.005` → `-1`) and the binary `1.005` boundary: the invoice path routes
through the shared `FinancialDecimal.javascriptCents` helper, while the
standalone-compilable job-list and change-order files keep the same
`floor(x * 100 + 0.5) / 100` rule locally because their focused `swiftc`
harnesses compile them without the financial-domain file.
The job-detail change-order section is now implemented.
`NativeChangeOrders.sectionState`/`row(for:)` project record-ordered rows with
the React Native badge copy and tone, keep a recorded decision note under the
title only when it is non-empty, and expose actionability so only pending and
awaiting rows present actions while edit and delete stay pending-only.
`NativeChangeOrderEditorView` ports `AddChangeOrderScreen` — the amount stays
raw text so validation can explain a bad entry — and `AppStore.changeOrderDraft`
refuses to open an editor for an ineligible job or an order that is no longer
pending. Every save runs through the same local-first transaction by ID:
`commitChangeOrder` reports the exact canonical refusal without a second
validation model, writes nothing when the job or order moved on, and closes the
editor only for the two stale-state cases the oracle navigates back on. The
section also records the separate on-site approval or decline with its optional
note — cleared on every close path so one order's note never pre-fills the next
— and the one-way cancellation, with the React Native confirmation copy ported
verbatim. The customer approval link and signature remain with the change-order
delivery slice: "Send for approval" is intentionally absent rather than routed
to a placeholder, and analytics stay gated. Focused pure-model vectors (status
labels and tones, actionability, section visibility, subtotal rounding, refusal
classification) and canonical AppStore integration coverage (blank draft,
commit create/edit, stale refusal, on-site decision, section projection) pass,
as do the unchanged React Native change-order oracle (`changeOrders`,
`changeOrderMath`, `changeOrderParity`, `changeOrdersSection`, and
`autoInvoice`: 88 passing assertions), the complete native/backend aggregate
suite, and generic-iPhone Debug and Release builds with signing disabled on
2026-09-19. Physical-device
add/edit/decision/cancel proof remains open.
The focused revision transport, exact-artifact adapter, canonical AppStore,
Worker/Vercel planner parity, dispatcher, and TypeScript checks pass. The
targeted React Native oracle contributes 103 passing assertions, the complete
native/backend aggregate suite passes, and the Worker production dry-run
bundles successfully. Backend deployment, live old-link invalidation, a racing
customer-decision exercise, and physical-device revision/history proof remain
open.
A job reaching `.complete`, `.approved`, `.scheduled`, or `.inProgress` can now
create or finalize its invoice natively, replacing the placeholder that
previously dead-ended the completed-job status row. `Domain/JobInvoiceDomain.swift`
is a new, standalone-compilable port of `utils/autoInvoice.ts`: billable labor
hours prefer a completed time session's tracked total over the quoted estimate
only once the job is done and the estimate actually priced labor hourly, the
approved-non-cancelled change-order decision rule is shared between the
running total and the per-item invoice lines, and line items (labor, materials,
customer-visible direct costs, the residual overhead line, and one line per
approved change order) are always rebuilt fresh from the job's current record
rather than carried in the draft, matching the React Native screen's save path
exactly. `AppStore.invoiceFromJobDraft`/`commitInvoiceFromJob` resolve
`JobLifecycleRules.invoiceScreenMode` (create, requestDeposit, or finalize),
prefill from the billable breakdown or, in finalize mode, re-derive the amount
only when approved change orders shifted it since the linked deposit invoice
was created, and commit invoice and job together in one atomic snapshot
mutation guarded by an expected-status recheck, following the same low-level
pattern `stampEstimateSent` established. `NativeCreateInvoiceFromJobView` is a
new `Form`-based sheet carrying the RN screen's pre-fill, tracked-time, and
finalize change-order-delta banners; job detail now offers "Create invoice" or
"Finalize invoice" once complete, and "Request deposit"/"View deposit" while
approved, scheduled, or in progress, the latter routing through the existing
global-search destination the `.invoiced` case already uses in place of the
Outreach screen. A new focused `InvoiceFromJobTests` suite, fixtured directly
from `__tests__/autoInvoice.test.ts`, caught two genuine defects before they
reached the simulator: a missing guard that let tracked time round down to a
non-billable zero without falling back to the estimate, and a `Decimal(Double)`
precision bug in the 2-decimal tracked-hour rounding. Both are fixed and
covered. The full native/backend aggregate suite and a clean `xcodebuild
build` pass with these changes on 2026-09-19. The directly dependent local
auto-invoice-on-completion path is now wired to the existing opt-in setting.
Completing an eligible in-progress job closes its last running timer, rebuilds
the same invoice lines and tracked-time total as the manual flow, resolves or
creates the customer, and advances the job to its linked invoice in one atomic
canonical save. Exact expected-status and existing-invoice gates prevent stale
taps or deposit jobs from creating duplicate final invoices; unmet gates leave
the job complete for manual review. The UI routes to the created invoice only
after the durable commit. Phase 7 wires the unattended-email stamp and the
payment-link/PDF preparation through the owner-bound delivery path (the
backend sweep remains the sender of record), including for migrated settings
that had enabled automatic email. The change-order section and basic time-tracking clock in/out
UI are now implemented and host-tested in their own slices (change-order
approval-link delivery/signature, time-tracking cross-device/widget/Siri
replay, and profitability aggregation remain open); this invoice slice only
reads the change orders and time sessions already synced from the backend.
Focused pure-domain and canonical AppStore integration coverage pass for the
auto-create gates, clock-out clamp, tracked-time amount, numbering, customer
creation, durable job/invoice linkage, queue publication, no-email stamp, and
stale-retry rejection. Physical-device evidence for the invoice-from-job modes
and automatic completion routing remains open.
After these slices, the complete native migration/backend aggregate suite and
the generic-iPhone Release build with code signing disabled passed on
2026-09-19. Host evidence: focused pure-domain/AppStore suites, the aggregate
suite, and the signed host build. Deferred to Phase 12 (still open, not
Verified): physical-device and end-to-end workflow proof for every Phase 6
slice above.

### Deliverables

- Job creation, editing, duplication, archive, and status transitions.
- Pricing calculator with labor, materials, markup, overhead, margin, minimums,
  travel, emergency pricing, and direct costs.
- Estimate documents, immutable snapshots, approval links, decisions, and
  follow-ups.
- Change orders, customer sign-off, verbal approval, cancellation, approval-link
  delivery, and billable total reconciliation (customer signature/decision is
  completed on the public change page; analytics and device proof remain).
- Time tracking, labor sessions, profitability, and direct-cost reporting
  (basic timer and job profitability card are implemented; aggregate reporting
  and cross-device/widget/Siri proof remain).
- Job photos, local storage, cloud upload/signing, visibility, and migration
  (native import/view/delete/visibility UI is implemented; device convergence
  proof remains).
- Recurring jobs, appointment confirmations, on-my-way messaging, and review
  requests (native rule manager, notification flows, and typed composers are
  implemented; analytics and device proof remain).
- Create-invoice-from-job (manual create/request-deposit/finalize and opt-in
  local automatic creation, done); native payment-link/PDF delivery foundation
  and RN-equivalent auto-email gating are implemented, while full invoice
  outreach, payment collection, and production delivery remain Phase 7.

### Exit criteria

- A job can progress from lead through durable invoice plus field-ops actions
  without using the Expo app (payment collection stays Phase 7).
- Estimate and change-order totals match golden documents exactly.
- Offline field actions sync safely when connectivity returns.

---

## Phase 7 — Invoices, payments, and customer communication

**Goal:** Complete receivables and payment collection.

### Deliverables

- Full invoice creation/edit/detail and line-item behavior.
- Deposit, partial payment, settlement, overpayment, void, and legacy payment
  equivalence.
- Stripe Connect status/onboarding and payment-link generation.
- PayPal.Me, Venmo, and supported custom payment links.
- Native PDF generation matching the current invoice and estimate templates.
- Email/SMS sending, PDF attachments, reminders, outreach, cooldowns, and bulk
  actions.
- Recurring invoices and automatic generation/email safeguards.
- Invoice-to-job status reconciliation and notification scheduling.

### Exit criteria

- Payment math and webhook reconciliation pass match backend fixtures.
- Generated PDFs pass visual comparison and arithmetic validation.
- Automated outreach cannot double-send or contact imported historical invoices.

---

## Phase 8 — Calendar, booking, routes, and portals

**Goal:** Port scheduling and customer self-service.

### Deliverables

- Day/week calendar, unscheduled queue, rescheduling, conflict warnings, working
  hours, buffers, gap suggestions, and time off.
- MapKit route planning and navigation handoff.
- Booking-link create/share/disable/rotate and availability configuration.
- Slot computation, reservation, race handling, confirmation, reschedule, and
  cancellation workflows.
- Customer portal create/share/disable/rotate.
- Portal estimates, invoices, appointments, change orders, visible photos, and
  customer requests.

### Exit criteria

- Availability parity fixtures match the existing implementation.
- Concurrent attempts cannot reserve the same slot.
- Disabling or rotating a link invalidates the previous link immediately.

---

## Phase 9 — Money, expenses, mileage, and exports

**Goal:** Restore the business reporting and accounting surface.

**Status (2026-09-22): code complete; device + live-endpoint evidence deferred to
Phase 12.** Every deliverable below has a native implementation with host tests
and a focused runner; the RN oracle groups were re-run after the port and
reproduce the frozen counts (38 suites / 758 tests). See
[native-phase-9-implementation-plan.md](native-phase-9-implementation-plan.md)
for per-task evidence,
[native-phase-9-money-exports-contract-decisions.md](native-phase-9-money-exports-contract-decisions.md)
for the frozen contracts plus the 9.14 qualification results, and
[native-phase-9-device-runsheet.md](native-phase-9-device-runsheet.md) for the
scheduled device rows. Nothing in this phase is `Verified` yet: the parity
matrix rows read `In progress` until those device/staging runs pass.

### Deliverables

- Complete date filters and cash-basis calculation rules.
- Revenue, receivables, aging, expenses, tax set-aside, seasonality,
  profitability, customer mix, top customers, forecast, conversion, and average
  job-value cards.
- Expense create/edit/delete and receipt photo/OCR review flow.
- Mileage log, trip editing, deduction method, and yearly rates.
- Pricebook CRUD, templates, job-prefill, and AI suggestions.
- CSV export and deterministic accountant ZIP package.
- Import mapping, validation, preview, commit report, history, and undo.

### Exit criteria

- Every report matches the React Native fixtures for identical input data.
- Accounting packages are structurally and semantically equivalent.
- OCR never saves extracted values without user review.

---

## Phase 10 — Today, coach, notifications, and automation

**Goal:** Restore the daily operating surface and proactive behavior.

### Deliverables

- Today schedule, overdue work, booking/portal attention, setup checklist, and
  contextual actions.
- Business snapshot and proactive insights with mute behavior.
- AI coach history, quick prompts, markdown rendering, backend errors, usage
  limits, and contextual prefill from insights.
- UserNotifications categories, permissions, due-date reminders, appointment
  reminders, review requests, and deep-link routing.
- Extend the Phase 4 sync task with background generation/refresh behavior for
  Today, insights, and notification scheduling.
- Prevent duplicate scheduling and sending across app launches.

### Exit criteria

- Every current notification payload routes to the correct native record.
- Background tasks are tested on physical devices and fail safely.
- AI prompts expose only the intended business context.

---

## Phase 11 — Widgets, App Intents, analytics, and production hardening

**Goal:** Complete platform integration and operational visibility.

### Deliverables

- WidgetKit target using the existing app group and snapshot contract.
- App Intents/Siri on-my-way and job actions.
- Complete cold/warm deep-link routing with authentication gates.
- PostHog event parity, privacy controls, and user identification lifecycle.
- Sentry crash/error reporting with secret and customer-data redaction.
- Accessibility audit: VoiceOver, Dynamic Type, contrast, Reduce Motion, touch
  targets, keyboard navigation, and switch control.
- iPad layouts, multitasking, rotation, memory, battery, and poor-network tests.
- Performance profiling and launch-time measurement.

### Exit criteria

- Widget and Siri actions remain correct across sign-in changes and stale data.
- Analytics and diagnostics contain no secure keys or sensitive document data.
- Accessibility and device-matrix audits have no release-blocking findings.

---

## Phase 12 — Parallel beta, cutover, and rollback

**Goal:** Replace the production binary without risking customer operations.

### Stage A — Internal TestFlight

- Team accounts and synthetic data only.
- Exercise upgrade migration from the current App Store Expo build.
- Run the full regression suite and backend load checks.

### Stage B — Limited external beta

- Invite a small cohort representing new, established, offline-heavy, Stripe,
  booking, recurring-work, and iPad users.
- Monitor migration failures, sync errors, crashes, payment reconciliation, and
  support contacts.
- Keep the latest Expo binary ready for immediate rollback.

### Stage C — Production cutover

- Freeze non-critical Expo feature development.
- Verify database backups, backend compatibility, App Store metadata,
  entitlements, privacy manifests, and legal disclosures.
- Release gradually using phased App Store rollout.
- Do not remove legacy migration code or backend compatibility during the first
  stable native release series.

### Cutover-blocking parity gaps (owned by Phase 12.00)

Found by Phase 11 qualification (contract §17.2). Each is built before cutover or
given a dated waiver by Phase 12.00; neither may be silently dropped.

- **Push notifications (G1).** The native app has no remote push notifications. RN
  opens booking requests and booking updates from push taps and tracks
  `booking_request_opened` and `booking_update_opened`; natively neither alert nor
  event exists. Build native remote push (a device token the backend's sender accepts —
  RN registers an Expo push token in `utils/pushToken.ts` — plus tap routing) or
  record a dated waiver.
- **Tax settings screen (G2).** Native has the tax-settings domain and
  `AppStore.commitTaxSettings`, but no screen calls it, so the income-tax rate and
  vehicle method cannot be set and `tax_settings_saved` is never emitted. Build the
  editor (RN `TaxSettingsModal`) or record a dated waiver.

### Cutover-blocking defect (owned by Phase 12.00)

Recorded by the Phase 11 final review (contract §17.2 "Known issues" 2; runsheet row
I2); not fixed in Phase 11. It must be fixed before cutover.

- **Sync push wedges on a non-auth 4xx (I2).** `NativeSupabasePush` treats
  400/404/409/413/422, and a 403 that repeats after refresh, as transient and keeps the
  mutation queued forever; `NativeSyncCoordinator` pulls only when the queue is empty,
  so one poison mutation stops inbound sync and an RLS 403 loops. Fix sketch: classify
  those responses as `.rejected`; move rejected mutations to an app-private,
  owner-scoped rejected store scrubbed at every account boundary; add a bounded
  diagnostic and an "N changes couldn't sync" line on Cloud Sync; then decide whether
  to relax the pull guard toward RN parity (RN always pulls after push,
  `utils/sync.ts` `pushQueue` lines 149–214 / `syncIfOnline` lines 316–326), keeping
  the 11.12 per-table rebase. Test: a poor-network poison-item scenario in
  `native/PoorNetworkTests/main.swift` (good items push, inbound pulls continue, and
  the poison item reaches the rejected store exactly once). Implemented by Phase 12
  12.00b.1 (`docs/native-phase-12-implementation-plan.md`).

### Exit criteria

- No unresolved severity-1 or severity-2 defects.
- Migration, sync, payment, and crash metrics meet agreed thresholds.
- Support and rollback playbooks are staffed and verified.

---

## Cross-phase quality gates

Every pull request or milestone should include:

- Unit tests for new business rules.
- Fixture comparison when replacing React Native logic.
- Loading, error, empty, offline, and accessibility behavior.
- Physical-device verification for platform integrations.
- Confirmation that the React Native client remains backend-compatible.
- Updated parity matrix and migration notes.

## Recommended milestone order

| Milestone | Phases | Outcome |
|---|---:|---|
| Safe foundation | 0–2 | Lossless models and recoverable local migration |
| Account-ready alpha | 3–4 | Authentication, subscriptions, and reliable sync |
| Operational core | 5–7 | Customers, jobs, estimates, invoices, and payments |
| Full business parity | 8–10 | Scheduling, portals, reporting, and automation |
| Release candidate | 11 | Platform services, accessibility, and hardening |
| Production migration | 12 | TestFlight validation, phased cutover, rollback |

## Immediate next actions

1. Build the Phase 0 parity matrix from the existing screens, tests, utilities,
   endpoints, and storage keys.
2. Freeze the simplified native model interfaces and replace them with the full
   versioned domain models.
3. Convert the highest-risk React Native test fixtures—pricing, payments, sync,
   recurrence, and migration—to cross-implementation golden tests.
4. Test an upgrade from the current App Store build on a physical device before
   implementing additional production integrations.
