# Phase 0 Baseline and Safety Controls

Updated: 2026-09-06

## Completed

- Created the phased migration roadmap.
- Created the screen/feature parity matrix.
- Inventoried navigation, storage, app-group keys, deep links, notification
  payloads, backend routes, analytics names, identity, entitlements, and the
  existing automated-test baseline.
- Added native build-environment configuration.
- Debug defaults to `development` with `http://127.0.0.1:8787`.
- Release defaults to a deliberately invalid staging URL.
- Production user-data requests are rejected unless both the environment is
  `production` and `TRADEREADY_ALLOW_PRODUCTION_WRITES` is explicitly `YES`.
- Removed the AI coach's hard-coded production URL.

## Reference captures still required

These require a working simulator or physical-device session and cannot be
truthfully completed from source inspection alone:

- Reference screenshots and recordings for every React Native screen.
- Light, dark, and accessibility-size captures.
- iPhone compact, iPhone large, iPad portrait, iPad landscape, and iPad
  multitasking captures.
- Loading, empty, populated, offline, validation-error, destructive-action, and
  backend-error states.

Capture artifacts should be stored outside source-control when they contain real
customer data. Synthetic fixture captures may be committed under a new folder,
`docs/native-reference/`, created with the first capture.

## Golden fixture plan

Use existing fixtures and tests first; do not invent new expected results when a
production oracle already exists.

Priority order:

1. Payment vectors and legacy-payment equivalence.
2. Pricing engine, direct costs, profitability, and change-order math.
3. Sync merge, account ownership, and sample-data migrations.
4. Invoice/estimate snapshots, PDF HTML, and file naming.
5. Recurring jobs/invoices and auto-send idempotency.
6. Booking availability, slot reservation, and scheduling conflicts.
7. Tax, revenue, aging, forecasts, and accounting-package output.
8. Deep links, notifications, widgets, and App Intent queue payloads.

Every fixture port records the JavaScript test filename, Swift test filename,
input hash, and expected-output hash.

## Backend compatibility rule

- The Cloudflare Worker remains the shared production backend.
- No native-driven backend change may remove or reinterpret a field used by the
  current App Store React Native client.
- New fields are additive and optional until the Expo client is retired.
- Destructive schema work requires backup, forward migration, rollback, and a
  mixed-client test.
- Public booking/portal routes retain their existing URLs throughout migration.

## Rollback procedure

1. Stop the phased rollout in App Store Connect.
2. Keep the Cloudflare Worker on the last mixed-client-compatible deployment.
3. If necessary, submit the preserved Expo release branch as the replacement
   binary with a higher build number.
4. Do not delete native migration journals or legacy AsyncStorage backups.
5. Reconcile native-written server rows using server audit timestamps and owner
   IDs before asking affected users to reopen the Expo build.
6. Publish a support notice only after the affected scope and safe user action
   are known.

## Phase 0 exit blockers

- Reference captures have not yet been produced because the available
  CoreSimulator service is unavailable and no device automation session was
  established.
- A non-production Cloudflare/Supabase environment and test accounts must be
  provisioned; the release configuration intentionally points to
  `https://staging.invalid` until that environment exists.
- Rollback ownership and acceptable migration/sync/crash thresholds need product
  owner approval.

Phase 1 domain-model work may begin in parallel with resolving these operational
blockers, but production integrations must not begin until a real staging
environment exists.
