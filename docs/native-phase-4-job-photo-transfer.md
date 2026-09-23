# Native Phase 4 Job-Photo Transfer

Updated: 2026-09-13

Status: implementation and host verification complete; trusted-staging and
physical-device interruption/convergence evidence remains required.

## Implemented contract

- Preserves the React Native local-first shape: canonical `jobPhotos` metadata
  is the sync record, while bytes live only at
  `Application Support/TradeReadyNative/Media/job-photos/<photoId>.jpg` and the
  authenticated worker's owner-derived R2 key.
- Accepts only the existing `p<timestamp>_<lowercase-base36>` ID grammar and
  JPEG payloads no larger than the worker's 6 MiB limit. Invalid IDs, symlinks,
  non-JPEG data, and oversized files fail before a request is sent.
- Sends the current Supabase access token to `PUT/GET /api/photos/:photoId`.
  The app never supplies an owner ID or R2 key and contains no service-role or
  R2 credential; the worker verifies `/auth/v1/user` and derives the owner
  prefix from that server-verified subject.
- Runs after metadata sync on initial-sync completion, foreground activation,
  and delivered background refresh. A confirmed upload updates only that still-
  present, still-unconfirmed canonical record, preserving unknown fields, and
  queues the `jobPhotos` upsert before committing the snapshot. A second sync
  publishes the confirmation to other devices.
- Re-reads the active subject, owner binding, completed workspace, session, and
  current photo record across every network suspension. Switching accounts or
  signing out cannot install bytes or metadata into the next workspace.
- Downloads only records with `uploadedAt` and no deterministic local file.
  Response status, content type, size, and JPEG framing are checked before an
  atomic temporary-file move. An error body never touches the destination, and
  a local file that appears during the request is never overwritten.
- Uses no separate completion flag. Missing `uploadedAt` safely repeats the
  worker's idempotent same-key PUT after a crash; an installed deterministic
  file removes itself from later backfill work. Failed items remain recoverable
  and retry on a later initial, foreground, or background pass.
- Leaves local bytes intact after upload and on transfer failure. Existing
  crash-resumable account scrub removes the entire live `Media` directory at an
  account boundary.

## Automated evidence

Run:

```sh
native/run-job-photo-transfer-tests.sh
native/run-store-integration-tests.sh
native/run-all-domain-tests.sh
```

The focused suite verifies ID parity, authenticated GET/PUT request shape,
exact upload bytes, post-success timestamping, auth rejection classification,
JPEG/content-type validation, error-body rejection, deterministic atomic
installation, resumable no-overwrite behavior, and local-byte preservation.
The aggregate suite includes it, and the generic-iPhone build type-checks the
AppStore foreground/background wiring.

## Required external evidence

Do not call this slice verified until the trusted staging URL is configured and
all of the following are recorded on physical iPhones:

Run `native/run-phase-4-device-preflight.sh` first and record results in
`native-phase-4-device-runsheet.md`.

- A Swift-origin local JPEG uploads, receives `uploadedAt`, and downloads byte-
  identically on a second Swift device and on the React Native client.
- A React Native-origin photo metadata row and R2 object backfill to the Swift
  deterministic path without overwriting an existing file.
- Terminating the app during PUT, between PUT and local commit, during GET, and
  before the atomic move leaves the original local file/snapshot intact and a
  later pass converges without duplicates.
- Airplane mode during upload/backfill preserves bytes and metadata; restoring
  connectivity completes the same pending work.
- Sign-out or account switch during each network suspension cannot commit into
  or expose the next account's workspace.
- 401/403, 404, 429, 5xx, oversized responses, JSON error bodies, and malformed
  JPEG responses leave the destination absent and remain retryable.

Photo capture/picker, visibility controls, delete UI, thumbnails, and user-
facing per-photo failure states remain in the later Jobs feature phase.
