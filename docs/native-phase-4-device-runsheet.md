# Native Phase 4 Physical-Device Run-Sheet

Updated: 2026-09-13

This is the single recording surface for Phase 4 background refresh, job-photo
transfer, network interruption, and React Native/Swift convergence. The detailed
contracts remain in:

- `native-phase-4-background-refresh.md`
- `native-phase-4-job-photo-transfer.md`
- `native-phase-4-mixed-client-convergence.md`

No host test, simulator, generic-iPhone build, or modeled client may mark a row
below `Pass`.

> **R59 update (2026-09-29):** no staging environment will exist, and the checked-in
> Release build is the production configuration. Run these rows against production
> with disposable accounts only. `native/run-phase-4-device-preflight.sh` now
> requires the production configuration, requires the Release Supabase project and
> key to match the production guard, and expects the SQL verification output to be
> recorded against the production database. It no longer checks Worker staging
> isolation. Rows that name an isolated or staging environment still read as
> written; the owner must amend or waive each in the charter decision log.

## Latest preflight checkpoint

On 2026-09-13, the privacy-safe live preflight recognized one available physical
iPhone and passed every checked-in repository/configuration contract. The signed
generic-iPhone Release build and the aggregate migration suite also completed
successfully. The matrix remains blocked, and no row below has been marked
`Pass`, because all of these external prerequisites are still open:

- a second physical iPhone for concurrent React Native/Swift evidence;
- an owner-approved, non-placeholder HTTPS staging backend;
- a distinct non-production Supabase staging project configured consistently in
  the Worker and Release app;
- successful output from both required SQL verification scripts, run against the
  production database (R59). Save each output with a first line
  `TARGET_SUPABASE_URL=<the production Supabase URL>`; the preflight requires that line to
  match the Worker's production `SUPABASE_URL`. It is a recorded attestation of the target,
  not proof of it, because the scripts print no project identity themselves.

The same-day read-only cloud inventory found no TradeReady Supabase staging
project or branch, no staging R2 buckets, and no deployed
`tradeready-backend-staging` Worker. Production resources were left untouched.
The owner subsequently declined provisioning a staging project and directed
non-cloud migration work to continue. This defers rather than passes Phase 4:
every row below remains open, and replacement of the Expo app remains blocked.

Do not replace any of those staging values with production to clear the gate.

## 1 — Preconditions

- [ ] Use an owner-approved, isolated Supabase project or branch and separate
      staging R2 buckets. Never substitute production.
- [ ] Apply the repository migrations and capture privacy-safe successful output
      from both verification scripts:
      - `supabase/migrations/verify/20260831_updated_at_server_authority_verify.sql`
      - `supabase/migrations/verify/20260718_invoice_payment_merge_verify.sql`
- [ ] Deploy the staging Worker only after explicit owner authorization.
- [ ] Configure the signed Release app and staging Worker to use the same
      isolated Supabase project. A Release configuration that still matches the
      production Worker project is an explicit preflight failure/blocker even
      when its backend-write flag is disabled, because collection sync writes
      directly to Supabase.
- [ ] Keep `TRADEREADY_PRODUCTION_SUPABASE_URL` matched to the Worker production
      project and `TRADEREADY_PRODUCTION_SUPABASE_PUBLISHABLE_KEY` matched to the
      React Native production client. The app uses these public values as a
      fail-closed runtime guard; they do not grant row access and must never be
      replaced with staging merely to make a preflight pass.
- [ ] Set the active Release URL and publishable key from the same isolated
      staging project's Connect dialog. The preflight can prove they differ from
      production, but the signed-device auth/Data API checks prove they actually
      belong together.
- [ ] Prepare two physical iPhones, one current React Native build, one current
      Swift build, and disposable staging accounts.
- [ ] Enable Background App Refresh for the Swift app.
- [ ] Run the preflight with the saved SQL outputs:

  ```sh
  native/run-phase-4-device-preflight.sh \
    --updated-at-verification /absolute/path/updated-at-output.txt \
    --payment-merge-verification /absolute/path/payment-merge-output.txt
  ```

  Exit `0` means the matrix may begin. Exit `1` means a repository or resolved
  configuration contract failed. Exit `2` means static contracts pass but an
  external prerequisite is still missing.

## 2 — Evidence rules

- Record only date, app version/build, iOS version, privacy-safe device aliases,
  environment classification, and `Pass` / `Fail` / `Blocked`.
- Never record an email, access/refresh token, customer data, full device ID,
  raw backend URL, R2 key, or photo contents in the repository.
- Use synthetic records and non-sensitive JPEG fixtures.
- A retry row passes only if the interrupted attempt preserved the canonical
  snapshot, local source bytes, queue, and cursor needed to converge later.
- An account-boundary row passes only if the next account cannot view, install,
  apply, replay, or acknowledge the previous owner's work.

### Run header

| Field | Value |
|---|---|
| Date | |
| Swift app version / build | |
| React Native app version / build | |
| Swift device alias / iOS | |
| React Native device alias / iOS | |
| Staging environment classification | |

## 3 — Background refresh

- [ ] **B1 — Delivered refresh.** Queue a Swift edit, create a remote edit from
      the other client, deliver a background refresh, and confirm push then pull
      converge without duplicates.
- [ ] **B2 — Offline delivery.** Deliver while in airplane mode; the queue and
      snapshot remain intact. Restore connectivity and confirm a foreground or
      later background pass converges.
- [ ] **B3 — Signed-out cold launch.** Deliver a task while signed out; it
      completes without rendering or mutating the previous workspace.
- [ ] **B4 — Expiration.** Expire a task during a delayed request; completion is
      unsuccessful exactly once and unacknowledged queue/cursor work remains.
- [ ] **B5 — Account boundary.** Sign out or switch accounts while a pass is
      suspended; no prior-owner mutation, pull, photo, or widget action commits.

## 4 — Job-photo transfer

- [ ] **P1 — Swift upload.** A valid local JPEG uploads byte-exactly and only
      then gains `uploadedAt`.
- [ ] **P2 — Swift-to-Swift backfill.** A second Swift device installs the bytes
      at the deterministic path without overwriting an existing local file.
- [ ] **P3 — Swift-to-React Native.** The React Native client receives the Swift
      metadata/object and renders the same synthetic photo.
- [ ] **P4 — React Native-to-Swift.** React Native-origin metadata/object backfill
      to Swift without replacing an existing file.
- [ ] **P5 — Upload interruption.** Terminate during PUT and between PUT and
      local metadata commit; relaunch safely repeats and converges.
- [ ] **P6 — Download interruption.** Terminate during GET and before atomic
      move; destination stays absent or valid, never partial.
- [ ] **P7 — Offline and retryable failures.** Airplane mode, 401/403, 404, 429,
      5xx, oversized, JSON, and malformed-JPEG responses preserve local state
      and retry safely.
- [ ] **P8 — Photo account boundary.** Switch accounts during upload and download;
      no bytes or metadata cross owners.

## 5 — Mixed React Native/Swift convergence

- [ ] **C1 — Independent creates.** Each client creates a different job; both
      clients converge to exactly one copy of each.
- [ ] **C2 — Ordered concurrent edit.** Both edit the same job offline; reconnect
      in a recorded order and confirm the database-last writer wins on both.
- [ ] **C3 — Deletes.** Each client deletes a record created by the other; both
      apply the owner-scoped tombstone.
- [ ] **C4 — Payments.** Each client adds a distinct payment to one invoice;
      both entries and any void state survive on both clients.
- [ ] **C5 — Booking history.** Server/customer history and device conversion
      fields survive a concurrent write and converge without duplicate history.
- [ ] **C6 — Relaunch replay.** Interrupt each client after server acceptance but
      before local queue commit; relaunch does not create duplicate rows.
- [ ] **C7 — Mixed-client account boundary.** Switch the Swift device to another
      account while React Native writes; none of the old account's state appears.

## 6 — Phase 4 exit

- [ ] B1–B5 all pass.
- [ ] P1–P8 all pass.
- [ ] C1–C7 all pass.
- [ ] Every interrupted path reconverges automatically.
- [ ] No duplicate, lost, partial, or cross-account data was observed.

Any failed or blocked row keeps Phase 4 in progress.
