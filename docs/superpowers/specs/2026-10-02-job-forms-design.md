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

## 10. Build record (2026-10-03)

### Data layer verification

The committed data layer (`1352da0`, merged in `494bd87`) was re-run before any screen work, one runner at a time: `store-integration`, `initial-sync`, `delta-sync`, `mutation-push`, `sync-coordinator`, `two-device-convergence`, `sync-backfill`, `rejected-changes` (183 checks), `record-deletion`, `repository`, `snapshot`, `canonical` and `job-forms` (537 checks) all pass. The store-integration forms case covers add, answer, photo capture from an item, the completion refusal, complete, reopen, edit, save as template, archive, delete with the shared undo, the hidden-on-job-delete rule and a relaunch. No data-layer fix was needed.

### What was built

- `N/NativeJobFormsView.swift`
  - **Job detail › Forms & checklists**, just before Photos. Each row shows the title, "7/12 answered" and a text badge ("Completed" or "In progress", with a symbol), read as one VoiceOver element. Rows swipe to Delete, and "Add form" opens the picker.
  - **Add form picker**: your templates, then your trade's built-ins, then General. A "Show templates for every trade" toggle adds the rest. A picked form opens straight away.
  - **Fill screen** (a sheet). Progress and status sit on top, then the items grouped by section:
    - a toggle per check, a segmented Pass/Fail/N/A control with "Clear result", and a multi-line answer field;
    - "Add note" on every answerable item;
    - Library and Camera photo buttons with "n of 10 photos" and thumbnails (View photo, or Remove from this item, which keeps it in the job's Photos);
    - then Mark complete or Reopen, Share PDF, Edit items, Save as template and Delete form.
- `N/NativeJobFormEditorView.swift`
  - **Items editor**, pushed from the fill screen or from Settings: rename; add, edit, delete and reorder items. Reorder uses Edit and drag, plus VoiceOver Move up / Move down. The editor shows "12 of 100 items".
  - **Item sheet**: kind, label, and the required and photo-required flags.
  - **Settings › Your business › Forms & checklists**: your templates (edit or archive) and the built-in library for reference.
- `N/NativeFormPDF.swift`
  - **`NativeFormPDFDocument`** (pure): header, status, progress, sections and rows with badges, answers and notes, photo resolution, and the filename.
  - **`NativeFormPDFRenderer`** (`UIGraphicsPDFRenderer`, iOS only).
- `N/Domain/NativeJobFormsPresentation.swift` (pure, host-tested): row summaries, status and progress text, item groups, kind names and flags, draft commit rules and caps, photo slots, completion refusal text, a text message for every `FormError`, the item draft, and the editor caps.
- **Smaller edits:**
  - `N/JobsView.swift`: mounts the section.
  - `N/SettingsView.swift`: the `.forms` destination.
  - `N/NativeConfirmation.swift`: a `deleteForm` intent.
  - `N/NativeJobPhotosView.swift`: the full-screen viewer is now module-wide.
  - `N/Domain/NativeAccessibilityAudit.swift`: adds the FAIL and neutral PDF badge pairs to the audited contrast table.

### Decisions where the spec was silent

- **Presentation.** The form opens as a sheet with its own navigation stack, like the change-order and quote-option sheets. Edit items pushes inside it, and the same editor is pushed from Settings.
- **Picker order.** Custom templates come first ("Your templates"), then the trade's built-ins, then General.
- **Text commits.** A text answer or note is written:
  - when editing ends;
  - after a 1.5 s pause in typing;
  - before Mark complete, Share PDF, Save as template, Done and dismissal.

  A field stops at its cap (2,000 or 1,000 characters) instead of failing on save.
- **Refused completion.** An alert lists every missing item with its typed reason (capped at 6 lines, "… and N more"). Each missing row is then marked "Still needed: …" in text.
- **Completed form.** Every control is disabled and a read-only notice shows. Edit items is off. Share PDF, Save as template and Delete stay available.
- **Photos per item.** The domain caps the stored `photoIds`, ids of deleted photos included. The screen shows only the photos that still resolve. Before a capture, the screen detaches just enough dangling ids that the room it shows is real (`danglingIDsToDetach`). The library picker never offers more photos than the room left.
- **Item kind.** An item's kind is fixed once it is added: the edit sheet changes the label and flags only. New items are added at the end and can then be reordered. Deleting an item asks first, and the last item cannot be deleted.
- **Templates.** Templates are archived, never deleted, from a swipe or from the editor, after a confirmation. Archiving pops the editor.
- **Template location.** Template management lives in Settings as the spec says. The pricebook and trade templates live under Money.
- **PDF: what is left out.** Items of an unknown kind are omitted, and so are headings with no items under them.
- **PDF: badges.** Badges are text: PASS, FAIL, N/A, CHECKED, NOT CHECKED and NO RESULT. PASS and CHECKED use the PAID pair. FAIL uses a new danger pair (danger text on a light red wash, about 5.6:1). The other badges use a new neutral pair (secondary on light gray, about 5.2:1).
- **PDF: text, filename and footer.** A blank text answer reads "No answer". The filename is `Form-<title>-<customer>.pdf`. The footer reads "business • form • Page N".
- **PDF: rendering and cleanup.** The PDF renders off the main thread into a temporary folder that is removed when the share sheet closes.
- **Analytics.** The new screens send no analytics events. A new screen case needs the analytics-event suite, which runs only in the final gate. This is a follow-up.
- **Parity matrix.** `docs/native-parity-matrix.md` is unchanged. It tracks React Native parity rows, and the other post-launch native-only phases (25, 27) have no rows either.

### Spec points that turned out wrong

- **§5 photo size.** Four photos per row at 160 pt do not fit the 516 pt column of a Letter page with 48 pt margins. Cells are drawn at about 121 pt, four across. The bitmap is still capped at 160 pt (320 px at 2×) and recompressed as JPEG at quality 0.7 before drawing.
- **§0 images in PDFs.** "No PDF embeds photos today" is true, but the estimate and invoice renderers already draw the business logo image, so embedding images needed no new technique.

### Tests (2026-10-03, run one at a time)

- **Data-layer runners:** `run-job-forms-tests.sh` passes with 741 checks: the 537 domain checks plus screen state and the PDF document model. Every step-1 runner passes again: `store-integration`, `initial-sync`, `delta-sync`, `mutation-push`, `sync-coordinator`, `two-device-convergence`, `sync-backfill`, `rejected-changes` (183), `record-deletion`, `repository`, `snapshot` and `canonical`.
- **Other runners touched:** `run-confirmation-tests.sh` passes (`deleteForm` added). `run-schedule-booking-settings-tests.sh` passes; it compiles the changed audit palette.
- **Audit inventories:** `run-accessibility-audit-tests.sh` and `run-layout-metrics-tests.sh` have both been updated for the new views. The updated checks are the view inventory, Done-bar coverage, swipe count 12, in-row destructive count 18, the form PDF palette, the scroll roots and the photo chip row.
  - Accessibility: 2028 of 2029 pass.
  - Layout: 912 of 915 pass.
  - The remaining failures are the known pre-existing ones only: `RootView.swift:234` `.borderedProminent`, `RootView` six tabs, `CoachView.swift:68` Done, and the `.keyboardShortcut` count.
- **Release compile:** generic iOS, signing off: **BUILD SUCCEEDED**.
- **Not run here:** device evidence (VoiceOver, AX5, camera, the share sheet and the rendered PDF on an iPhone) is deferred to Phase 12.
