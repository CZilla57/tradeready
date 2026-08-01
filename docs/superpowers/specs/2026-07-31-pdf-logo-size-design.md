# PDF Logo Size Fix (40MB attachments) — Design

**Date:** 2026-07-31 · **Branch:** `feat/pdf-logo-size` · **Origin:** owner report —
invoice PDFs attach to email at ~40MB.
**Status:** owner-approved design (2026-07-31), including the Rule-3 dependency
approval for `expo-image-manipulator`. Ships SECOND of the three-branch effort
(CSV → PDF-logo-size → recurring-invoices).

## Root cause (verified in source 2026-07-31)

1. **Pick time** — `utils/logoPicker.ts:45,57`: logo picked with `quality: 0.8`
   but **no dimension cap**. `quality` tunes JPEG compression only; a modern
   phone photo keeps full 12–48MP dimensions. `persistPhotoSafe` stores it
   byte-for-byte.
2. **Embed time** — `utils/invoicePdfFile.ts:49–52`: the stored file is read
   whole into a base64 data URI (+33%) and inlined into the invoice HTML.
3. **Print time** — `Print.printToFileAsync` embeds the full-resolution image
   into the PDF (WebKit may re-encode losslessly, inflating further). The
   `.logo { max-height: 56px; max-width: 140px }` CSS (`utils/pdfTemplates.ts:53`)
   scales only the *rendering* — every original byte ships in the file.

Affected call sites (all three read the raw logo via `readPhotoAsDataUri`):

| Call site | Surface |
|---|---|
| `utils/invoicePdfFile.ts:49` | Invoice PDF email attachment (the reported 40MB) |
| `screens/InvoicesScreen.tsx:128` | Invoice PDF share/view |
| `screens/SendEstimateScreen.tsx:128` | Estimate PDF |

A logo rendered at 140×56pt needs ~280×112px at 2x. Target: PDFs in the
tens-of-KB range.

## Owner decisions (2026-07-31)

| Decision | Choice |
|---|---|
| Approach | `expo-image-manipulator`, **both layers** (pick-time + embed-time) |
| Dependency | **Approved** (Rule 3) — install with `npx expo install expo-image-manipulator` so the SDK-54-matched version is chosen; no other `package.json` changes |
| Branch | Own branch, NOT inside `feat/recurring-invoices` — keeps that feature JS-only/OTA-eligible |
| Rejected | JS-only stopgap (skip >300KB logos — silently drops the user's logo); embed-time-only (stored logos stay huge) |

Note: the receipt-OCR design (2026-07-19, decision D4) explicitly deferred this
dependency "until real-world failure rates warrant it." The 40MB attachment is
that warrant.

## Design

### Layer 1 — pick-time resize (permanent fix)

In `logoPicker.ts` `persistPicked`, after a successful pick and **before**
`persistPhotoSafe`: `ImageManipulator.manipulateAsync(uri, [{ resize: … }],
{ compress: 0.8, format: PNG })`, scaling so the **longest side ≤ 512px**
(aspect preserved; images already ≤512 pass through un-resized). PNG output
preserves logo transparency (JPEG would flatten transparent logos onto a
box — visible on dark themes and colored letterheads).

Failure mode: if `manipulateAsync` throws, persist the **original** — the
pick still succeeds (no UX regression) and Layer 2 still protects every PDF.
Report via `reportError`.

This also shrinks the stored file ~100×, which speeds the Settings preview
and the sync-free logo folder. The logo draft/sweep lifecycle
(`logoLifecycle.ts`) is untouched — resizing happens before the file is
persisted, so there is still exactly one new file per pick.

### Layer 2 — embed-time downscale (covers existing oversized logos)

New helper (in `utils/photoStorage.ts` alongside `readPhotoAsDataUri`):

```
readLogoForPdf(path: string): Promise<string | null>
```

`manipulateAsync(path, [resize to longest side ≤ 512], { compress: 0.8,
format: PNG, base64: true })` → return as a data URI. On any failure, fall
back to `readPhotoAsDataUri(path)` (status quo — never worse than today,
logo preserved), reporting via `reportError`.

Swap all three call sites from `readPhotoAsDataUri(settings.logoPhoto)` to
`readLogoForPdf(settings.logoPhoto)`. **Deliberately no file mutation** — the
stored logo is never rewritten in place, so the Settings draft-vs-filesystem
`deletePhoto` invariant and the orphan sweep are never in play.

### What is deliberately NOT done

- No resize-in-place migration of existing stored logos (touches the fragile
  logo lifecycle for little gain — Layer 1 fixes the store the next time the
  user picks a logo; Layer 2 makes the stored size irrelevant to PDFs).
- No `app.json` change: `expo-image-manipulator` needs no config plugin and no
  permissions. (Verify during implementation; if that turns out false, STOP —
  `app.json` changes need owner approval.)

## Ship constraints

- **Native module → NOT OTA-eligible.** Rides the next store build, which
  social sign-in already forces. Do not `eas update` a bundle containing this
  branch onto the current binary — the runtime won't have the native module.
- **Expo Go includes `expo-image-manipulator`** (SDK 54), so the owner's
  Expo Go device-smoke workflow is unaffected.
- `jest.setup.js` gains a mock for `expo-image-manipulator` (resolve with a
  fake uri/base64), following the existing expo-module mock pattern.

## Testing

- `readLogoForPdf`: happy path returns data URI from mocked manipulator;
  manipulator failure falls back to `readPhotoAsDataUri`; null/missing path.
- `logoPicker` pick path: mocked manipulator called with resize before
  `persistPhotoSafe`; manipulator failure still persists original.
- Golden-HTML tests (`__fixtures__/invoiceHtmlGolden.js`) unaffected — the
  `logoDataUri` parameter contract of `invoiceHtml`/`estimateHtml` is
  unchanged.
- Device smoke (owner, Expo Go): pick a full-res photo as logo → email an
  invoice PDF → attachment size sanity-check (expect well under 1MB); repeat
  with a pre-existing oversized logo (Layer 2 path); estimate PDF spot-check;
  transparent-PNG logo keeps transparency.

## Out of scope

- Job/receipt photo compression (different pipeline, no reported problem).
- PDF content/layout changes.
