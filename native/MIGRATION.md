# React Native → SwiftUI migration map

The phased implementation and release plan lives in
[`../docs/native-ios-migration-roadmap.md`](../docs/native-ios-migration-roadmap.md).

## Implemented in the native target

- Native SwiftUI lifecycle, `TabView`, `NavigationStack`, sheets, searchable
  lists, swipe actions, grouped forms, menus, alerts, and Dynamic Type.
- Today dashboard and schedule, job list/detail/create/edit, invoice
  list/detail/create/edit/payment, customer list/detail/create/edit, money
  overview/expenses, coach conversation, and settings.
- Complete settings information architecture with subtitled hub rows and native
  detail pages for business profile, schedule, pricing, invoice numbering,
  import, payments, booking, appearance, AI, notifications, reviews,
  subscription, account, support, privacy, and terms.
- Versioned canonical snapshot persistence with atomic writes and loss-preserving
  screen projection merges.
- Direct canonical import of all twelve plain-storage families from the previous
  AsyncStorage manifest, including large manifest-backed values.
- Non-destructive, deterministic adoption of safely contained local images
  after immutable source backup. JPEG/PNG bytes remain exact where compatible;
  decodable PNG/HEIF/WebP/GIF sources can be converted to the native JPEG
  contract. Missing or failed-conversion references remain recoverable.
- Exact-owner App Group handoffs with a cross-process locked write-ahead claim,
  atomic idempotent job/trip/expense replay, and crash-safe Siri mileage state.
- `tradeready://job/<id>` deep links.
- Existing backend AI endpoint integration.

## Next parity slices

Follow the phased roadmap's dependency gates:

1. Finish the remaining baseline operational evidence (Phase 0); the canonical
   domain models, round-trip fixtures, and business-rule layer are complete
   (Phase 1).
2. Run the physical-device upgrade and rollback matrix to close Phase 2. Its
   repository code is complete, including the refresh-capable server-verified
   migrated-session bridge, typed account-state boundary, reviewed pending-link
   consumer, transactional widget/Siri replay, and image conversion. Exact auxiliary
   capture, validated device-theme restoration, strict owner-gated auxiliary
   staging with privacy-safe receipts, live Supabase `/auth/v1/user` plus
   refresh-grant verification, Keychain-secret HMAC account namespaces, strict
   App Group validators and pending-link routing, generation-
   based secure-session publication, lossless local JPEG/PNG photo adoption,
   and the metadata-only support export are implemented. Legacy sync queues and
   cursors stay preserve-only for Phase 4. See
   `../docs/native-phase-2-persistence.md` for the remaining device evidence;
   photo capture/management UI belongs to later phases.
3. Authentication, onboarding, subscription gates, then collection-based cloud
   sync with ownership and server-authoritative merge rules (Phases 3–4). The
   read-only initial-sync pull is in place; the write path now has a durable
   last-writer-wins mutation queue and an idempotent, owner-scoped push
   transport, and AppStore enqueues on every local upsert/delete and settings
   change while clearing the queue on every account boundary. A reachability-aware
   sync coordinator serializes push passes with exponential backoff, refreshes an
   expired session once and retries, coalesces edits made mid-pass, and is driven
   on sign-in, foreground, and every local change. A one-time, per-account
   backfill enqueues the whole local snapshot on the first completed initial
   sync so migration- and seed-created records that bypassed the enqueue-on-edit
   hooks still reach the cloud; it is flag-gated, idempotent, offline-safe, and
   cleared at every account boundary. Cursor-based delta pull and two-device
   convergence tests are implemented. Direct Supabase mutation writes now have
   a separate fail-closed runtime boundary: non-production builds cannot reuse
   the configured production project origin or publishable key, and production
   requires exact origin/key matches plus the explicit write switch. A blocked pass retains the
   queue and exposes only `push/environment`; auth and read-only initial recovery
   remain available. A modeled React Native client now shares
   the in-memory Data API with the production Swift push/pull services and
   verifies both wire directions, owner-scoped soft deletion, and database-clock
   authority when the React Native device clock is far wrong. The native banner and Settings status page
   expose pending/offline/failure state, manual retry, scheduled retry, last
   successful session sync, and bounded diagnostics; sync-first sign-out waits
   for the upload before cleanup. Background refresh now registers before launch
   completion, submits/resubmits a 30-minute-earliest app-refresh request, uses
   the existing exact-owner/session gates on cold launch, and cancels with
   exactly-once completion on expiration. Authenticated job-photo upload and
   atomic missing-file backfill now run after metadata sync, preserve local
   sources, resume from metadata/file state, and re-check exact ownership after
   network suspension. Still to do in Phase 4: physical-device background and
   photo interruption, plus physical-device React Native/Swift convergence
   evidence. Run `run-phase-4-device-preflight.sh` before recording the unified
   matrix in `../docs/native-phase-4-device-runsheet.md`. The Phase 4 preflight
   also verifies that the app's production-origin guard matches the Worker
   production project and its production-key guard matches the React Native
   production client, without printing key values.
4. Complete customers, jobs, estimates, invoices, and payments (Phases 5–7).
   Manual create-invoice-from-job (create/request-deposit/finalize, ported from
   `utils/autoInvoice.ts` into `Domain/JobInvoiceDomain.swift`, with an atomic
   `AppStore.commitInvoiceFromJob` snapshot mutation and a new
   `NativeCreateInvoiceFromJobView` sheet) is done. Opt-in local automatic
   invoice creation now shares that derivation and atomically advances an
   eligible completed job to its saved invoice. The job detail now renders the
   change-order section and offers add, edit, on-site approval/decline, one-way
   cancellation, and pending-only delete through one local-first canonical
     transaction that re-resolves the job and order by ID. Change-order
     approval-link delivery, basic clock in/out, job profitability, photos,
     recurring jobs, appointment confirmations, and review-request flows are
     now implemented and host-tested. Unattended email/payment-link/PDF
     delivery, profitability aggregate reporting, and the Outreach send screen
     remain open; analytics and physical-device proof are deferred to their
     later gates. See the Phase 6 section of
     `../docs/native-ios-migration-roadmap.md`. Phase 6 exits at
     lead-through-durable-invoice plus field ops; payment collection stays
     Phase 7.
5. Scheduling, booking, portals, reporting, and daily operations (Phases 8–10).
6. Platform integrations, device hardening, beta, and cutover (Phases 11–12).

The original Expo source remains untouched so behavior can be compared screen by
screen while these slices are migrated.
