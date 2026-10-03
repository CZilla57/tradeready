# Custom Job / Inspection Forms & Checklists (Roadmap Phase 20) — Design Spec

**Date:** 2026-10-02
**Status:** BUILDING on `feat/job-forms` (stacked; owner go-ahead 2026-10-02)
**Origin:** `docs/post-launch-feature-roadmap.md` Phase 20, build order #4
**Build target (owner, 2026-10-02):** native SwiftUI app, plus one Supabase migration **file** (not applied). **No React Native changes.** No Worker changes.

## 0. Preconditions verified against the repo

- No form, checklist or inspection model exists. `NativeSetupChecklist` is onboarding and unrelated. Trade templates (`NativeTradeTemplates`) are static pricebook scope prompts that are never persisted.
- Synced collections are blob tables `{id text pk, user_id, data jsonb, updated_at, deleted}` with owner RLS. **The `id` primary key is global across all users**, so every row id must be randomized. A fixed `builtin-…` row would collide across accounts.
- Device job pushes are whole-blob, unconditional upserts. The sync coordinator **pushes before it pulls**. The server writes into job blobs for estimate and change-order decisions, and the web app read-modify-writes jobs. RN moved photos out of the job blob for exactly this whole-job last-writer-wins hazard (`types/models.ts` JobPhoto note).
- `JobPhoto` has `{id, jobId, createdAt, uploadedAt?, customerVisible?, width?, height?}`. Optional keys can be added without a migration. A photo id is a stable cross-device reference (also the R2 key).
- PDFs: `UIGraphicsPDFRenderer` with hand-rolled pagination, copy-pasted helpers per document, and an immutable document-model struct. Tests cover only the model; no PDF embeds photos today.
- `Canonical.Settings.trade` is synced, but stored values are mixed case: onboarding writes `hvac`, while SettingsView writes "HVAC" or "Carpentry". Any trade filter must normalize.

## 1. Decision: a separate synced `forms` collection

Filled checklists are edited repeatedly **on-site**. That is the same place and time a customer may approve a change order, and the server writes that decision into the job blob. Nesting forms in the job blob would make every checkbox tap a whole-job overwrite racing that decision. A separate collection isolates form edits completely. One table holds both custom templates and job instances, using a `kind` discriminator, so the migration and sync plumbing are added once.

**Cost:** one migration file, plus the standard new-collection plumbing (about 10 touchpoints, listed in §6). **Release gate:** apply the migration before shipping the build. A missing table fails the full initial pull, so new-device sign-in would break.

## 2. Data model (`forms` collection, blob rows)

```ts
interface Form {
  id: string;                    // "fm<ms>_<base36 random>" — globally unique
  kind: 'template' | 'instance';
  jobId?: string;                // instance only
  templateId?: string;           // instance: "builtin:<key>" or a custom template id
  title: string;                 // 1..80
  items: FormItem[];             // 1..100
  completedAt?: string;          // instance: ISO; absent = in progress
  createdAt: string;             // ISO
  archivedAt?: string;           // template soft-hide
}
interface FormItem {
  id: string;                    // "fi_<n>" unique within the form
  kind: 'section' | 'check' | 'passFail' | 'text';
  label: string;                 // 1..200
  required?: boolean;            // ignored for 'section'
  photoRequired?: boolean;       // ignored for 'section'
  // Responses (instance only; absent = unanswered):
  checked?: boolean;             // 'check'
  result?: 'pass' | 'fail' | 'na';   // 'passFail'
  text?: string;                 // 'text' answer, 0..2000
  note?: string;                 // any answerable item, 0..1000 (e.g. why it failed)
  photoIds?: string[];           // job photo ids, max 10
}
```

`JobPhoto` gains optional `formId` and `formItemId` (additive). They are written when a photo is captured from a form item, so the photo appears in the job's Photos section and in the form.

**Completion rule** (pure, tested). An instance can be marked complete only when:
- every `required` item is answered (`check` → `checked == true`; `passFail` → any result; `text` → non-blank), and
- every `photoRequired` item has at least one photo id that still resolves to an existing job photo.

Reopening clears `completedAt`. A completed instance is read-only until it is reopened.

## 3. Built-in library (static, in code)

Built-in templates are never stored rows. Instantiating one creates an instance with `templateId: "builtin:<key>"`. There are six, each with `trades` tags:
- **General:** Pre-job walkthrough; Job completion & cleanup; Site safety checklist.
- **HVAC:** HVAC maintenance inspection.
- **Electrical:** Electrical safety inspection.
- **Plumbing:** Plumbing / water heater inspection.

Each has 6 to 15 items, a mix of kinds, and photo-required items where a real inspection would want evidence (e.g. "Data plate photo"). The content is generic good practice, with no code citations and no compliance claims. The picker shows the owner's trade first, using a normalized trade key (`hvac`, "HVAC" and "Hvac" all map to `hvac`), then "General", with an "All templates" toggle.

## 4. Owner flows (native)

- **Job detail → "Forms & checklists" section** (just before Photos). It lists the job's instances (title, progress "7/12", a complete badge) and has an "Add form" button that opens the picker (built-ins plus the owner's custom templates).
- **Form view:**
  - Items are grouped by section.
  - `check` is a toggle, `passFail` is a segmented Pass/Fail/N/A control, and `text` is a multi-line field. Any item can take a note.
  - A per-item photo button captures through the existing camera/PhotosPicker pipeline (`store.createJobPhoto`), stamped with `formId`/`formItemId`.
  - The view shows progress, then "Mark complete" (blocked with a list of missing items) or "Reopen", then "Share PDF".
  - Edit mode adds an item (kind + label + required/photo flags), deletes or reorders items, and renames the form.
  - Each change commits through `AppStore` as one `forms` upsert. Text fields commit on end-edit or debounce, not on every keystroke.
- **Save as template** (from any form): copies the title and items without responses into a new `kind: template` row.
- **Settings → "Forms & checklists":** lists custom templates (rename, edit items, archive). Archived templates are hidden from the picker; existing instances are unaffected.
- **Deleting a form:** soft-delete via the normal `enqueueDelete`, with an 8 s undo like other records.
- **Deleting a job:** its form instances are left in place and hidden, exactly as job photos are today (no cascade; see §8).

## 5. PDF report

A new `NativeFormPDF` follows the estimate PDF's structure: an immutable document model plus a `UIGraphicsPDFRenderer` renderer.
- Header: business name, logo and contact.
- Job title, customer, address, form title, and completed date (or "In progress").
- Items by section, with a result badge, the answer text and note.
- A photo grid under each item: up to 4 per row, each downscaled to fit 160 pt and JPEG-recompressed before drawing. Photos whose bytes aren't on this device render a "Photo not available on this device" placeholder.
- Footer: page numbers.

It is shared through the existing `NativeActivitySheet` from a temporary file that is deleted on dismiss. The document model is fully host-tested: rows, sections, the answered/unanswered rendering text, photo resolution, and the filename.

## 6. Sync plumbing (new collection `forms`)

1. Migration `supabase/migrations/20261002_forms.sql`, a copy of `20260806_job_photos.sql`. It also attaches the existing `public.set_updated_at()` trigger to the new table **in this migration**; the already-applied `20260831` migration is not edited. Add the new table to `supabase/verify/local/bootstrap.sql` too.
2. `Canonical.Form` and `Canonical.FormItem`, using the preservation pattern; add `formId` and `formItemId` to `Canonical.JobPhoto`.
3. `SnapshotPayload.forms`: property, init, take/put, defaulting to empty for old snapshots.
4. Push `collectionTables` and the pull `Collection` enum, apply and replace.
5. `rebasePulledDelta`: one `rebase` line.
6. `NativeSyncBackfill` subjects.
7. Labels and diagnostics: rejected-change `typeLabel`/`name`, performance record count, safe diagnostic keys, support-report counts.
8. Account deletion: the server cascades through the foreign key, so no change there; the local scrub already removes the snapshot.
9. `docs/release-checklist.md` gains the release-gate line.

## 7. Testing

- **New Swift `JobFormsTests`** (runner `run-job-forms-tests.sh`, registered). It covers:
  - canonical round-trip (unknown keys preserved)
  - built-in library integrity: unique keys, item ids and labels within caps, every template instantiable, trade normalization
  - instantiate, answer, completion rule (each failure reason), reopen, and edit operations (add, delete, reorder, caps)
  - save-as-template stripping responses
  - dangling photo ids
  - the PDF document model
  - id format and uniqueness
- **Existing suites updated:** canonical snapshot fixtures (a `forms` member), sync and initial-sync table lists, mutation push classification, two-device convergence (one form edited on each device converges through last-writer-wins), and sync backfill.
- **Gates:** `sh native/run-all-domain-tests.sh`, the Release compile, `sh native/run-doc-reference-check.sh`. Run the local Postgres verify only if `supabase/verify/local/run.sh` works on this machine; otherwise record that as owner evidence.

## 8. Accepted residuals

- Deleting a job leaves its form instances, like its photos. They are hidden and do no harm. Cascading would need multi-record undo tokens, which is a separate change.
- Last-writer-wins happens per form across two devices editing the same form at once. That is acceptable for one operator; the job blob is unaffected.
- No customer-facing form view in the portal (not requested).
- Built-in content is generic guidance, not code compliance.

## 9. Owner decisions recorded

| # | Decision | Choice |
|---|---|---|
| D1 | Storage | New `forms` collection (templates and instances), migration file written, **owner applies before shipping** |
| D2 | Template builder | No drag-and-drop builder; built-ins plus "save as template", with item add/delete/reorder |
| D3 | Photos | Reuse job photos with `formId`/`formItemId` back-references |
| D4 | Job delete | No cascade (matches photos) |
