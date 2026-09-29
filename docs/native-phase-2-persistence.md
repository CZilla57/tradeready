# Phase 2 Persistence and Upgrade Evidence

## Status

The repository implementation for Phase 2 is complete. The phase remains
blocked at its final exit gate until the physical-device upgrade matrix below
has been run against an App Store/TestFlight-style replacement install.

No simulator or command-line test can prove that an installed Expo container,
Keychain entries, App Group defaults, file protection, and native replacement
binary retain their production identities across an actual upgrade.

## Implemented guarantees

- Versioned canonical snapshots use atomic publication, a verified previous
  snapshot backup, corrupt-primary quarantine, and forward-schema write blocks.
- AsyncStorage import covers inline and external manifest values, every known
  business family, opaque auxiliary values, provider credentials, and raw
  Supabase session bytes across current and legacy SecureStore services.
- Migration is journaled, resumable, no-overwrite, pre-seed, and retains
  immutable Expo source directories and photo recovery copies.
- Secure sessions use verified generation-specific Keychain chunks and one
  atomic active pointer. Credentials never enter snapshots or support reports.
- Legacy local images are contained and signature-checked. JPEG/PNG bytes are
  retained exactly where their native contract permits; decodable PNG, HEIF,
  WebP, and GIF inputs can be converted to a single-frame JPEG while originals
  remain in the immutable backup. Failed conversions retain their references.
- Auxiliary account state activates only after live Supabase identity matches
  the exact legacy owner and is stored under a non-reversible account binding.
- Pending widget/Siri mutations use a shared cross-process lock, verified
  account-bound write-ahead claims, one atomic multi-family snapshot commit,
  idempotent action identities, and post-commit exact acknowledgement.
- Siri mileage start/stop state carries a stable action ID and completion
  payload, making append/clear interruption safe to retry.
- The Settings support export is metadata-only and excludes customer values,
  identifiers, paths, errors, credentials, sessions, and queued action bytes.

## Automated evidence

Run from the repository root:

```sh
native/run-all-domain-tests.sh
```

The aggregate currently runs seventeen suites covering financial rules,
canonical models, snapshots, repository recovery, legacy import, migration,
auxiliary activation, authenticated identity, typed state, App Group routing,
appointment messaging, widget replay, adapters, and AppStore integration.

Type-check the complete iOS source set without using host caches:

```sh
SDKROOT_TASK=$(xcrun --sdk iphoneos --show-sdk-path)
xcrun swiftc -typecheck \
  -module-cache-path /tmp/tradeready-native-typecheck-modules \
  -sdk "$SDKROOT_TASK" -target arm64-apple-ios17.0 \
  native/TradeReadyNative/Domain/*.swift native/TradeReadyNative/*.swift
xcrun swiftc -typecheck -parse-as-library \
  -module-cache-path /tmp/tradeready-widget-typecheck-modules \
  -sdk "$SDKROOT_TASK" -target arm64-apple-ios17.0 \
  targets/widget/Widgets.swift targets/widget/JobTimer.swift \
  targets/widget/_shared/SiriIntents.swift
```

## Required physical-device upgrade matrix

Use a development/staging account and retain an installable copy of the Expo
build for rollback. For each row, install the Expo build first, create the
fixture while offline where specified, then install the native build as an
upgrade without deleting the app.

| Fixture | Required verification |
|---|---|
| Clean install | No legacy source is invented; onboarding receives an empty native store |
| Sample account | Counts, money, dates, settings, photos, session, and owner binding match |
| Large account | External manifest values, more than ten session chunks, 512 queued actions, and all photo directories migrate without truncation |
| Offline account | Local records and credentials survive; identity-gated state remains quarantined until live verification succeeds |
| Partially synced account | Local queue/cursors remain inert and recoverable; no server or local record is overwritten |
| Interrupted migration | Force-quit after backup, snapshot publication, secure publication, widget claim, and replay commit; every relaunch converges without duplicates |
| Account mismatch | A different verified user receives no prior account state, action replay, or customer data |
| Corruption recovery | Corrupt primary only, then primary plus backup; recovery or read-only blocking matches the support report |

For every row, rerun the native app twice, export the support report, compare
record counts and representative records to the Expo fixture, inspect migrated
media, and confirm the Expo-format backup can still be recovered. Exercise
widget timer and Siri mileage actions during foreground/background transitions.

## Exit decision

Phase 2 can be marked complete only after every matrix row passes on a physical
device and the retained Expo build has been reinstalled successfully as the
rollback rehearsal. Authentication lifecycle belongs to Phase 3; authenticated
photo upload/backfill belongs to Phase 4; photo capture and management UI belong
to the job-detail feature phase.
