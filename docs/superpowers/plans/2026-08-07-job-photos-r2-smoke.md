# Job Photos R2 Sync — Owner Smoke Script

Feature: job photos mirror to Cloudflare R2 (`tradeready-photos` bucket) for
cross-device sync + reinstall survival. JS-only OTA rider — no native change.

## Preconditions (all owner-completed as of 2026-08-07)
- [x] Supabase migration `supabase/migrations/20260806_job_photos.sql` applied
      (creates the `"jobPhotos"` table + RLS).
- [x] R2 bucket `tradeready-photos` created.
- [x] `backend-workers` deployed with the `PHOTOS` binding + `/api/photos/:photoId`
      route. **Note:** the Phase-5 `deleteAccount` `DATA_TABLES` tweak (`jobPhotos`)
      only takes effect on the *next* deploy — not correctness-critical (the FK
      `on delete cascade` already covers those rows), but fold it into the next deploy.
- [ ] OTA published (`eas update`) so devices run this JS.

## Two-device test (devices A and B, same account)

1. **Attach + upload (A → B).**
   On A, open a job → Photos → Add → take/pick a photo. It appears immediately.
   Wait for sync (or background A, foreground it), then foreground B and open the
   same job. Expected: a placeholder spinner briefly, then the photo appears.

2. **Offline attach uploads later (A).**
   Put A in airplane mode. Attach a photo — it shows instantly (local-first).
   Re-enable network, foreground A. Expected: upload fires; on B the photo appears
   after its next foreground/sync.

3. **Delete propagates (A → B).**
   On A, delete a photo (the ✕ on the thumb → confirm). On B after sync: the photo
   disappears.

4. **Job-delete + undo (A).**
   On A, delete a whole job that has photos, then tap **UNDO** in the snackbar.
   Expected: the job and all its photos return. If you let the snackbar expire
   instead, the job and its photo records are gone on B too after sync (the image
   bytes orphan in R2 until account deletion — expected).

5. **Reinstall self-heal (A).**
   Delete and reinstall the app on A, sign in. Open a job with photos.
   Expected: placeholders, then photos re-download from R2.

6. **Legacy adoption (only if you have pre-2026-08-06 job photos).**
   Sign in on a device that has old `Job.photos`. Expected: on first sign-in the
   photos silently convert to `jobPhotos` records and upload; nothing visibly
   changes except they now sync. Re-running (another sign-in) does nothing (the
   migration is idempotent).

7. **Account deletion purges R2.**
   Settings → Account → Delete account. Then in the Cloudflare R2 dashboard
   (or `wrangler r2 object list tradeready-photos`), confirm no objects remain
   under that user's `{userId}/` prefix.

## What "healthy" looks like
- Photos always render from disk instantly; the network is never on the render path.
- A photo from another device shows a spinner (downloading) or a cloud-upload icon
  (origin device hasn't uploaded yet) until its bytes arrive — both are correct, not bugs.
- Sentry: watch for `uploadPendingPhotos` / `ensurePhotoLocal` / `saveCompressedJobPhoto`
  error contexts; occasional transient network failures are fine (they retry).
