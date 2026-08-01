# PDF Logo Size Fix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop invoice and estimate PDFs from carrying a full-resolution phone photo as the business logo, which produced ~40MB email attachments.

**Architecture:** Two independent layers, both built on `expo-image-manipulator`. **Layer 1 (pick time)** downscales the chosen logo to ≤512px on its longest side and re-encodes it as PNG *before* `persistPhotoSafe` copies it into app storage, so newly picked logos are small on disk forever. **Layer 2 (embed time)** adds `readLogoForPdf` to `utils/photoStorage.ts`, which downscales to ≤512px and returns a PNG data URI without ever touching the stored file; the three PDF call sites swap to it, so logos already stored at full resolution stop bloating PDFs too. Both layers degrade to today's behaviour on failure — the pick still succeeds, the PDF still gets a logo.

**Tech Stack:** Expo 54 / React Native 0.81 / React 19 / TypeScript (strict) / Jest via jest-expo. One new dependency: `expo-image-manipulator` (owner-approved). Already installed and used here: `expo-image-picker`, `expo-print`, `expo-file-system` (legacy API).

**Spec:** `docs/superpowers/specs/2026-07-31-pdf-logo-size-design.md`

**Ship note (does not change any task):** `expo-image-manipulator` is a native module, so **this branch is NOT OTA-eligible**. It must ride the next store build (which social sign-in already forces). Do not `eas update` a bundle containing this branch onto the current binary — the installed runtime has no such native module. Expo Go for SDK 54 *does* bundle `expo-image-manipulator`, so the owner's Expo Go device-smoke workflow still works.

## Global Constraints

- **Branch:** `feat/pdf-logo-size`, cut from `master`. At plan time `master` is `9c3e1dc` with a clean working tree. Branch creation and committing this plan doc are Task 1's first steps.
- **The ONLY dependency change allowed, owner-approved (change-control Rule 3):** `npx expo install expo-image-manipulator` (so the SDK-54-matched version is chosen — expected `~14.0.8`, from `node_modules/expo/bundledNativeModules.json`). **No other `package.json` changes.**
- **If the install touches `app.json` (plugins etc.), STOP and escalate to the owner.** `app.json` changes need separate owner approval. (Verified at plan time: `expo-image-manipulator@14.0.8` ships no `app.plugin.js` and needs no permissions, so no `app.json` entry is expected.)
- **Gate before EVERY commit**, run from the repo root `C:\Users\Chadr\OneDrive\Documents\TraderPro App\tradeready` (quote the path — it contains a space): `npm run typecheck` → 0 errors; `npm test` → all pass (baseline at plan time: **1433 tests / 90 suites**, verified 2026-08-01); `npm run lint` → 0 warnings (`--max-warnings=0`, so a warning is RED). **Never commit red.** (Change-control Rule 2.)
- **Commit style:** imperative subject with a `feat:` / `fix:` / `chore:` / `docs:` / `build:` prefix, one coherent change per commit.
- **No `eslint-disable`, `@ts-ignore`, or `@ts-expect-error`.**
- **Layer 1:** pick-time resize in `utils/logoPicker.ts` — longest side ≤ 512px, PNG format (preserves transparency), compress 0.8, applied **BEFORE** `persistPhotoSafe`. On `manipulateAsync` failure, persist the **ORIGINAL** (the pick still succeeds) and report via `reportError`.
- **Layer 2:** new `readLogoForPdf(path: string): Promise<string | null>` in `utils/photoStorage.ts` — manipulate to ≤512px longest side, PNG, compress 0.8, `base64: true` → data URI. On **ANY** failure fall back to `readPhotoAsDataUri(path)` and `reportError`. Swap the three call sites to it. **NO file mutation of the stored logo, ever** — the Settings draft-vs-filesystem `deletePhoto` invariant and the logo orphan sweep must never come into play.
- **No persisted data-shape changes.** No new fields on `Settings`, no new AsyncStorage keys. `Settings.logoPhoto?: string` (`types/models.ts:415`) stays exactly as it is.
- **No PDF content or layout changes.** `invoiceHtml(invoice, biz, logoDataUri?)` (`utils/pdfTemplates.ts:193`) and `estimateHtml(job, customer, biz, logoDataUri?)` (`utils/pdfTemplates.ts:313`) keep their signatures, and the `.logo` CSS at `utils/pdfTemplates.ts:53` is not touched. The golden-HTML fixtures must not change.
- **Out of scope:** job-photo and receipt-photo compression (different pipeline, no reported problem); resize-in-place migration of already-stored logos.

## File Structure

| File | Status | Responsibility |
|---|---|---|
| `package.json` / `package-lock.json` | Modify | Adds `expo-image-manipulator` only. |
| `jest.setup.js` | Modify | Global `expo-image-manipulator` mock, following the existing expo-module mock pattern. |
| `utils/photoStorage.ts` | Modify | Gains the shared logo constants, the pure `logoResizeActions` helper, `readLogoForPdf` (Layer 2), and an optional file-extension argument on `persistPhoto`/`persistPhotoSafe`. |
| `utils/logoPicker.ts` | Modify | Layer 1: shrink the picked asset before it is persisted. |
| `utils/invoicePdfFile.ts` | Modify | Call site 1 — email attachment. |
| `screens/InvoicesScreen.tsx` | Modify | Call site 2 — invoice PDF share/view. |
| `screens/SendEstimateScreen.tsx` | Modify | Call site 3 — estimate PDF. |
| `utils/logoLifecycle.ts` | Modify | Doc-comment only: file names are no longer always `.jpg`. |
| `__tests__/photoStorage.test.js` | Modify | Tests for `logoResizeActions`, `readLogoForPdf`, and the extension argument. |
| `__tests__/invoicePdfFile.test.js` | Modify | Its `../utils/photoStorage` mock moves from `readPhotoAsDataUri` to `readLogoForPdf`. |
| `__tests__/logoPicker.test.js` | Create | First test file for the pick path. |
| `ARCHITECTURE.md`, `README.md` | Modify | Dependency + module descriptions. |

---

### Task 1: Branch, plan doc, dependency, Jest mock

Puts the branch, the approved dependency, and the test-infrastructure mock in place. No behaviour changes yet — the gate must stay exactly as green as it is on `master`.

**Files:**
- Create (already written, needs committing): `docs/superpowers/plans/2026-08-01-pdf-logo-size.md`
- Modify: `package.json` (dependencies), `package-lock.json`
- Modify: `jest.setup.js:75-79` (insert the new mock immediately after the `expo-image-picker` mock block)

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: a global Jest mock of `expo-image-manipulator` exposing `manipulateAsync: jest.Mock`, `SaveFormat`, and `FlipType`. Later tasks override it per-test with `mockResolvedValueOnce` / `mockRejectedValueOnce`, following the `__tests__/messaging.test.js` convention for global mocks.

- [ ] **Step 1: Cut the branch**

```bash
cd "C:/Users/Chadr/OneDrive/Documents/TraderPro App/tradeready"
git status --short
git checkout -b feat/pdf-logo-size master
git branch --show-current
```

Expected: `git status --short` prints only `?? docs/superpowers/plans/2026-08-01-pdf-logo-size.md` (this plan). `git branch --show-current` prints `feat/pdf-logo-size`. If the working tree has any *other* modification, STOP — it is not this branch's work.

- [ ] **Step 2: Commit the plan doc**

```bash
git add docs/superpowers/plans/2026-08-01-pdf-logo-size.md
git commit -m "docs: add the PDF logo-size implementation plan"
```

- [ ] **Step 3: Install the approved dependency**

```bash
npx expo install expo-image-manipulator
```

Expected: `expo-image-manipulator` appears in `package.json` `dependencies` at `~14.0.8` (the SDK-54 bundled version).

- [ ] **Step 4: Verify the install touched nothing it shouldn't**

```bash
git status --short
node -e "console.log(require('./package.json').dependencies['expo-image-manipulator'])"
```

Expected `git status --short`: exactly two lines, `M package.json` and `M package-lock.json`. Expected `node -e` output: `~14.0.8`.

**STOP conditions — escalate to the owner, do not work around:**
- `app.json` appears in `git status`. `app.json` changes need separate owner approval.
- Any dependency other than `expo-image-manipulator` was added, removed, or version-bumped in `package.json`. Confirm with `git diff package.json` — it must show a single added line.

- [ ] **Step 5: Add the global Jest mock**

`jest.setup.js` currently has the `expo-image-picker` mock at lines 75-79. Insert this new block immediately after it (before the `expo-image` mock at line 81):

```js
// The manipulator is native. Resolve with a small, already-within-cap image by
// default so suites that merely touch the logo path need no per-test setup;
// tests that care about resizing override the dimensions with
// mockResolvedValueOnce. Enum values match the real SaveFormat/FlipType strings.
jest.mock("expo-image-manipulator", () => ({
  manipulateAsync: jest.fn(() =>
    Promise.resolve({
      uri: "file:///mock/manipulated.png",
      width: 512,
      height: 512,
      base64: "PNGDATA",
    })
  ),
  SaveFormat: { JPEG: "jpeg", PNG: "png", WEBP: "webp" },
  FlipType: { Vertical: "vertical", Horizontal: "horizontal" },
}));
```

- [ ] **Step 6: Run the gate**

```bash
npm run typecheck
npm test
npm run lint
```

Expected: typecheck 0 errors; `Tests: 1433 passed, 1433 total` / `Test Suites: 90 passed, 90 total` (unchanged — nothing consumes the mock yet); lint 0 warnings.

- [ ] **Step 7: Commit**

```bash
git add package.json package-lock.json jest.setup.js
git commit -m "build: add expo-image-manipulator and its jest mock"
```

---

### Task 2: `logoResizeActions` + `readLogoForPdf` (Layer 2)

The embed-time downscale. A pure helper decides the resize action from the image's dimensions; `readLogoForPdf` probes the file for those dimensions, re-encodes to a bounded PNG, and returns a data URI — falling back to today's exact behaviour on any failure.

**Files:**
- Modify: `utils/photoStorage.ts` (add an import at the top, and append the new exports after `readPhotoAsDataUri`, which ends at line 96)
- Modify: `__tests__/photoStorage.test.js:8-29` (extend the local file-system mock and the `beforeEach`) and append two new `describe` blocks

**Interfaces:**
- Consumes: `readPhotoAsDataUri(uri: string): Promise<string | null>` and `photoExists(uri: string): Promise<boolean>`, both already in `utils/photoStorage.ts` (lines 83 and 74); `reportError(error: unknown, context?: Record<string, unknown>): void` from `utils/analytics.ts:41`; the `expo-image-manipulator` Jest mock from Task 1.
- Produces:
  - `LOGO_MAX_DIMENSION: number` — `512`.
  - `LOGO_COMPRESS: number` — `0.8`.
  - `logoResizeActions(width: number, height: number): ImageManipulator.Action[]` — `[]`, `[{ resize: { width: 512 } }]`, or `[{ resize: { height: 512 } }]`.
  - `readLogoForPdf(path: string): Promise<string | null>` — a `data:image/png;base64,…` string, or `null` when the file is gone and the fallback also fails.

- [ ] **Step 1: Extend the test file's mocks**

`__tests__/photoStorage.test.js` lines 8-13 currently mock only what `persistPhotoSafe` needs. `readPhotoAsDataUri` (the fallback) additionally reads the file and touches `FileSystem.EncodingType`. Replace lines 8-19 with:

```js
jest.mock("expo-file-system/legacy", () => ({
  documentDirectory: "file:///mock/",
  getInfoAsync: jest.fn(),
  makeDirectoryAsync: jest.fn(),
  copyAsync: jest.fn(),
  readAsStringAsync: jest.fn(),
  EncodingType: { Base64: "base64" },
}));

jest.mock("../utils/analytics", () => ({ reportError: jest.fn() }));

const FileSystem = require("expo-file-system/legacy");
const ImageManipulator = require("expo-image-manipulator");
const { reportError } = require("../utils/analytics");
const {
  persistPhotoSafe,
  logoResizeActions,
  readLogoForPdf,
} = require("../utils/photoStorage");
```

Then replace the `beforeEach` at lines 24-29 with:

```js
const LOGO = "file:///mock/logos/1700000000000_abc.png";

beforeEach(() => {
  jest.clearAllMocks();
  FileSystem.getInfoAsync.mockResolvedValue({ exists: true });
  FileSystem.makeDirectoryAsync.mockResolvedValue(undefined);
  FileSystem.copyAsync.mockResolvedValue(undefined);
  FileSystem.readAsStringAsync.mockResolvedValue("RAWBYTES");
  // mockReset (not mockClear) so a leftover mockResolvedValueOnce from a
  // previous test can never bleed into the next one.
  ImageManipulator.manipulateAsync.mockReset();
  ImageManipulator.manipulateAsync.mockResolvedValue({
    uri: "file:///mock/manipulated.png",
    width: 512,
    height: 512,
    base64: "PNGDATA",
  });
});
```

Leave the existing `describe("persistPhotoSafe", …)` block and its seven tests exactly as they are.

- [ ] **Step 2: Write the failing tests**

Append to `__tests__/photoStorage.test.js`:

```js
describe("logoResizeActions", () => {
  test("caps a landscape image on its width", () => {
    expect(logoResizeActions(4032, 3024)).toEqual([{ resize: { width: 512 } }]);
  });

  test("caps a portrait image on its height", () => {
    expect(logoResizeActions(3024, 4032)).toEqual([{ resize: { height: 512 } }]);
  });

  test("caps a square image on its width", () => {
    expect(logoResizeActions(2000, 2000)).toEqual([{ resize: { width: 512 } }]);
  });

  test("leaves an image that is already within the cap alone", () => {
    expect(logoResizeActions(300, 120)).toEqual([]);
  });

  test("treats exactly 512 as within the cap", () => {
    expect(logoResizeActions(512, 200)).toEqual([]);
  });

  test("returns no actions for unreported dimensions, so nothing is upscaled", () => {
    // ImagePickerAsset documents width/height as "can be 0"; a naive
    // resize-to-512 would blow a 0x0 or unknown image up instead of down.
    expect(logoResizeActions(0, 0)).toEqual([]);
    expect(logoResizeActions(NaN, NaN)).toEqual([]);
  });
});

describe("readLogoForPdf", () => {
  test("returns a png data uri built from the manipulator's base64", async () => {
    await expect(readLogoForPdf(LOGO)).resolves.toBe("data:image/png;base64,PNGDATA");
    expect(reportError).not.toHaveBeenCalled();
  });

  test("caps an oversized landscape logo at 512 on its longest side", async () => {
    ImageManipulator.manipulateAsync.mockResolvedValueOnce({
      uri: "file:///mock/probe.jpg",
      width: 4032,
      height: 3024,
    });
    await readLogoForPdf(LOGO);
    expect(ImageManipulator.manipulateAsync).toHaveBeenNthCalledWith(1, LOGO);
    expect(ImageManipulator.manipulateAsync).toHaveBeenNthCalledWith(
      2,
      LOGO,
      [{ resize: { width: 512 } }],
      { compress: 0.8, format: "png", base64: true }
    );
  });

  test("caps an oversized portrait logo on its height", async () => {
    ImageManipulator.manipulateAsync.mockResolvedValueOnce({
      uri: "file:///mock/probe.jpg",
      width: 3024,
      height: 4032,
    });
    await readLogoForPdf(LOGO);
    expect(ImageManipulator.manipulateAsync).toHaveBeenNthCalledWith(
      2,
      LOGO,
      [{ resize: { height: 512 } }],
      { compress: 0.8, format: "png", base64: true }
    );
  });

  test("re-encodes a logo that is already small with no resize action", async () => {
    ImageManipulator.manipulateAsync.mockResolvedValueOnce({
      uri: "file:///mock/probe.jpg",
      width: 280,
      height: 112,
    });
    await readLogoForPdf(LOGO);
    expect(ImageManipulator.manipulateAsync).toHaveBeenNthCalledWith(2, LOGO, [], {
      compress: 0.8,
      format: "png",
      base64: true,
    });
  });

  test("never rewrites the stored logo file", async () => {
    // The Settings draft keeps a logo file alive until Save, and the orphan
    // sweep matches on exact paths — an in-place rewrite would break both.
    await readLogoForPdf(LOGO);
    expect(FileSystem.copyAsync).not.toHaveBeenCalled();
  });

  test("falls back to the raw file and reports when the manipulator throws", async () => {
    const boom = new Error("decode failed");
    ImageManipulator.manipulateAsync.mockRejectedValueOnce(boom);
    await expect(readLogoForPdf(LOGO)).resolves.toBe("data:image/png;base64,RAWBYTES");
    expect(reportError).toHaveBeenCalledWith(boom, { context: "readLogoForPdf" });
  });

  test("falls back and reports when the manipulator returns no base64", async () => {
    ImageManipulator.manipulateAsync
      .mockResolvedValueOnce({ uri: "file:///mock/probe.jpg", width: 4032, height: 3024 })
      .mockResolvedValueOnce({ uri: "file:///mock/out.png", width: 512, height: 384 });
    await expect(readLogoForPdf(LOGO)).resolves.toBe("data:image/png;base64,RAWBYTES");
    expect(reportError).toHaveBeenCalledTimes(1);
  });

  test("returns null without calling the manipulator when the logo file is gone", async () => {
    // A logo path does not survive a reinstall (see photoExists). That is not
    // an error and must not page anyone.
    FileSystem.getInfoAsync.mockResolvedValue({ exists: false });
    await expect(readLogoForPdf(LOGO)).resolves.toBeNull();
    expect(ImageManipulator.manipulateAsync).not.toHaveBeenCalled();
    expect(reportError).not.toHaveBeenCalled();
  });
});
```

- [ ] **Step 3: Run the tests to verify they fail**

```bash
npx jest __tests__/photoStorage.test.js
```

Expected: FAIL — `TypeError: logoResizeActions is not a function` (and the same for `readLogoForPdf`). The seven existing `persistPhotoSafe` tests still pass.

- [ ] **Step 4: Implement**

In `utils/photoStorage.ts`, add the manipulator import below the existing two imports at lines 1-2, so the top of the file reads:

```ts
import * as FileSystem from "expo-file-system/legacy";
import * as ImageManipulator from "expo-image-manipulator";
import { reportError } from "./analytics";
```

Then append to the end of the file (after `readPhotoAsDataUri`, which currently ends at line 96):

```ts
/** Longest side, in pixels, that a logo is allowed to keep. */
export const LOGO_MAX_DIMENSION = 512;

/**
 * Save compression for logo re-encodes. PNG is lossless, so this only tunes the
 * encoder's effort — it is kept at the picker's own 0.8 for parity.
 */
export const LOGO_COMPRESS = 0.8;

/**
 * The manipulator actions that cap a `width`x`height` image at
 * LOGO_MAX_DIMENSION on its longest side, preserving aspect ratio.
 *
 * expo-image-manipulator derives the missing dimension when only one is given,
 * so the action names whichever side is longer and lets the other follow.
 *
 * Returns no actions for an image that already fits, and for dimensions the
 * platform did not report (ImagePicker documents width/height as "can be 0"):
 * resizing on a 0 would upscale a small logo instead of shrinking a big one.
 */
export function logoResizeActions(
  width: number,
  height: number,
): ImageManipulator.Action[] {
  if (!Number.isFinite(width) || !Number.isFinite(height)) return [];
  if (width <= 0 || height <= 0) return [];
  if (Math.max(width, height) <= LOGO_MAX_DIMENSION) return [];
  return [
    width >= height
      ? { resize: { width: LOGO_MAX_DIMENSION } }
      : { resize: { height: LOGO_MAX_DIMENSION } },
  ];
}

/**
 * A logo read as a PDF-ready data URI, downscaled to at most
 * LOGO_MAX_DIMENSION on its longest side.
 *
 * Why this exists: `Print.printToFileAsync` embeds every byte of the image it is
 * handed, and the `.logo { max-height: 56px; max-width: 140px }` CSS scales the
 * *rendering* only. A phone photo used as a logo produced ~40MB invoice PDF
 * attachments (owner report, 2026-07-31). Logo files stored before the
 * pick-time cap existed are still full resolution, so the cap has to be applied
 * here too.
 *
 * PNG, not JPEG: a transparent logo re-encoded as JPEG gains a solid box, which
 * shows on the PDF's white letterhead.
 *
 * The stored file is never rewritten — the downscaled copy exists only in the
 * manipulator's cache and in the returned string. That keeps the Settings
 * draft-vs-filesystem `deletePhoto` invariant and the logo orphan sweep out of
 * play entirely.
 *
 * Two manipulator calls, not one: the resize action has to name the longer
 * side, which means the dimensions must be known first. The probe call performs
 * no transformation and its output file is discarded.
 *
 * Any manipulator failure falls back to `readPhotoAsDataUri` — exactly today's
 * behaviour. A large PDF beats a logo-less one.
 */
export async function readLogoForPdf(path: string): Promise<string | null> {
  // A logo path does not survive a reinstall; a missing file is ordinary, not a
  // failure, and must not reach reportError.
  if (!(await photoExists(path))) return null;
  try {
    const probe = await ImageManipulator.manipulateAsync(path);
    const result = await ImageManipulator.manipulateAsync(
      path,
      logoResizeActions(probe.width, probe.height),
      { compress: LOGO_COMPRESS, format: ImageManipulator.SaveFormat.PNG, base64: true },
    );
    if (!result.base64) throw new Error("manipulateAsync returned no base64 data");
    return `data:image/png;base64,${result.base64}`;
  } catch (err) {
    reportError(err, { context: "readLogoForPdf" });
    return readPhotoAsDataUri(path);
  }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

```bash
npx jest __tests__/photoStorage.test.js
```

Expected: PASS — 21 tests in the suite (7 existing + 6 `logoResizeActions` + 8 `readLogoForPdf`).

- [ ] **Step 6: Run the gate**

```bash
npm run typecheck
npm test
npm run lint
```

Expected: typecheck 0 errors; `Tests: 1447 passed, 1447 total` / `Test Suites: 90 passed, 90 total`; lint 0 warnings.

- [ ] **Step 7: Commit**

```bash
git add utils/photoStorage.ts __tests__/photoStorage.test.js
git commit -m "feat: add readLogoForPdf, a 512px-capped PNG logo reader for PDFs"
```

---

### Task 3: Swap the three PDF call sites to `readLogoForPdf`

Every surface that embeds the logo in a PDF now goes through the capped reader. This is the change that fixes the reported 40MB attachment for logos that are already stored at full resolution.

**Files:**
- Modify: `utils/invoicePdfFile.ts:11` (import) and `:49-50` (call)
- Modify: `screens/InvoicesScreen.tsx:29` (import) and `:127-129` (call)
- Modify: `screens/SendEstimateScreen.tsx:23` (import) and `:127-129` (call)
- Modify: `__tests__/invoicePdfFile.test.js:3`, `:8-13`, `:100-126`

**Interfaces:**
- Consumes: `readLogoForPdf(path: string): Promise<string | null>` from Task 2.
- Produces: no new exports. `buildInvoicePdfFile(invoice, settings?)`, `handleExportPdf` in both screens, and both template signatures are unchanged.

Note: the repo has no screen-level tests for `InvoicesScreen` or `SendEstimateScreen` (deliberate — see the tradeready-validation-and-diagnostics skill, "screens are untested by design"). Their swaps are verified by typecheck, lint, and the grep in Step 6, and by the owner's device smoke in Task 5.

- [ ] **Step 1: Update the failing test first**

In `__tests__/invoicePdfFile.test.js`, change line 3 from

```js
import { readPhotoAsDataUri } from "../utils/photoStorage";
```

to

```js
import { readLogoForPdf } from "../utils/photoStorage";
```

Replace lines 8-13 (the comment and the photoStorage mock) with:

```js
// photoStorage's real readLogoForPdf drives expo-image-manipulator and the
// filesystem; mock it so the logo path is actually observable.
jest.mock("../utils/photoStorage", () => ({
  readLogoForPdf: jest.fn(() => Promise.resolve(null)),
}));
```

Replace the three logo tests at lines 100-126 with:

```js
  test("passes the capped logo data uri into the template when a logo is set", async () => {
    readLogoForPdf.mockResolvedValueOnce("data:image/png;base64,AAA");
    await buildInvoicePdfFile(invoice, { logoPhoto: "file:///mock/logo.png" });
    expect(readLogoForPdf).toHaveBeenCalledWith("file:///mock/logo.png");
    expect(invoiceHtml).toHaveBeenCalledWith(
      invoice,
      { logoPhoto: "file:///mock/logo.png" },
      "data:image/png;base64,AAA"
    );
  });

  test("renders without a logo when none is set", async () => {
    await buildInvoicePdfFile(invoice, {});
    expect(readLogoForPdf).not.toHaveBeenCalled();
    expect(invoiceHtml).toHaveBeenCalledWith(invoice, {}, undefined);
  });

  test("renders without a logo when the logo file can't be read", async () => {
    readLogoForPdf.mockResolvedValueOnce(null);
    const uri = await buildInvoicePdfFile(invoice, { logoPhoto: "file:///mock/gone.png" });
    expect(invoiceHtml).toHaveBeenCalledWith(
      invoice,
      { logoPhoto: "file:///mock/gone.png" },
      undefined
    );
    expect(uri).toBe("file:///mock/cache/Invoice-INV-0001-Jane-Smith.pdf");
  });
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
npx jest __tests__/invoicePdfFile.test.js
```

Expected: FAIL — two tests in `describe("buildInvoicePdfFile")`. The source still calls `readPhotoAsDataUri`, which the mock no longer provides, so the call throws `TypeError: (0 , _photoStorage.readPhotoAsDataUri) is not a function` inside `buildInvoicePdfFile`'s own `try` and is swallowed into a `null` return. Concretely: "passes the capped logo data uri into the template when a logo is set" fails with `expect(readLogoForPdf).toHaveBeenCalledWith(...)` / "Number of calls: 0", and "renders without a logo when the logo file can't be read" fails because `uri` is `null` instead of the cache path. The 8 `invoicePdfFilename` tests and the no-logo tests still pass.

- [ ] **Step 3: Swap call site 1 — the email attachment**

In `utils/invoicePdfFile.ts`, change line 11 from

```ts
import { readPhotoAsDataUri } from "./photoStorage";
```

to

```ts
import { readLogoForPdf } from "./photoStorage";
```

and change lines 49-51 from

```ts
    const logoDataUri = settings.logoPhoto
      ? await readPhotoAsDataUri(settings.logoPhoto)
      : null;
```

to

```ts
    const logoDataUri = settings.logoPhoto
      ? await readLogoForPdf(settings.logoPhoto)
      : null;
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
npx jest __tests__/invoicePdfFile.test.js
```

Expected: PASS — 16 tests (8 `invoicePdfFilename` + 8 `buildInvoicePdfFile`).

- [ ] **Step 5: Swap call sites 2 and 3 — the two screens**

In `screens/InvoicesScreen.tsx`, change line 29 from

```ts
import { readPhotoAsDataUri } from "../utils/photoStorage";
```

to

```ts
import { readLogoForPdf } from "../utils/photoStorage";
```

and change lines 127-129 (inside `handleExportPdf`) from

```ts
    const logoDataUri = settings.logoPhoto
      ? await readPhotoAsDataUri(settings.logoPhoto)
      : null;
```

to

```ts
    const logoDataUri = settings.logoPhoto
      ? await readLogoForPdf(settings.logoPhoto)
      : null;
```

In `screens/SendEstimateScreen.tsx`, change line 23 from

```ts
import { readPhotoAsDataUri } from "../utils/photoStorage";
```

to

```ts
import { readLogoForPdf } from "../utils/photoStorage";
```

and change lines 127-129 (inside `handleExportPdf`) from

```ts
    const logoDataUri = settings.logoPhoto
      ? await readPhotoAsDataUri(settings.logoPhoto)
      : null;
```

to

```ts
    const logoDataUri = settings.logoPhoto
      ? await readLogoForPdf(settings.logoPhoto)
      : null;
```

- [ ] **Step 6: Verify no PDF path still reads the raw logo**

```bash
npx eslint utils/invoicePdfFile.ts screens/InvoicesScreen.tsx screens/SendEstimateScreen.tsx --max-warnings=0
grep -rn "readPhotoAsDataUri" utils screens components
```

(PowerShell equivalent for the second command: `Select-String -Path utils\*.ts,screens\*.tsx,components\**\*.tsx -Pattern readPhotoAsDataUri`.)

Expected from `eslint`: no output, exit 0.

Expected from `grep`: **seven** lines and no others —

- `utils/photoStorage.ts` ×3 — the definition (line 83), the mention in `readLogoForPdf`'s doc comment, and the fallback call inside `readLogoForPdf`
- `utils/receiptOCR.ts:149` and `:162` — doc-comment mentions only
- `components/money/AddExpenseModal.tsx:19` and `:129` — the unrelated receipt path

**No hit anywhere in `screens/`, and no hit in `utils/invoicePdfFile.ts`.** If either appears, the swap is incomplete.

- [ ] **Step 7: Run the gate**

```bash
npm run typecheck
npm test
npm run lint
```

Expected: typecheck 0 errors; `Tests: 1447 passed, 1447 total` / `Test Suites: 90 passed, 90 total` (test count unchanged — these were edits, not additions); lint 0 warnings. The golden-HTML suites (`__tests__/pdfTemplates.test.js`, `__tests__/pdfBizHeader.test.js`) must still pass untouched: the `logoDataUri` parameter contract did not change.

- [ ] **Step 8: Commit**

```bash
git add utils/invoicePdfFile.ts screens/InvoicesScreen.tsx screens/SendEstimateScreen.tsx __tests__/invoicePdfFile.test.js
git commit -m "fix: cap the embedded logo size on every PDF surface"
```

---

### Task 4: Pick-time resize (Layer 1)

The permanent fix: a logo picked from now on is stored at ≤512px as a PNG, so it is small on disk, fast in the Settings preview, and small in every PDF even if Layer 2 ever fails. Because the stored file becomes a PNG, `persistPhoto` gains an optional extension argument so the filename stops lying about its contents — `readPhotoAsDataUri` derives the data-URI MIME type from that extension (`utils/photoStorage.ts:90-91`), and it is the Layer 2 fallback path.

**Files:**
- Modify: `utils/photoStorage.ts:4-14` (`persistPhoto`) and `:32-39` (`persistPhotoSafe`)
- Modify: `utils/logoPicker.ts` (imports at lines 1-3, and `persistPicked` at lines 10-21)
- Modify: `__tests__/photoStorage.test.js` (two tests appended to the existing `persistPhotoSafe` describe)
- Create: `__tests__/logoPicker.test.js`

**Interfaces:**
- Consumes: `logoResizeActions(width, height): ImageManipulator.Action[]` and `LOGO_COMPRESS: number` from Task 2; `persistPhotoSafe` from `utils/photoStorage.ts`; `reportError(error, context?)` from `utils/analytics.ts:41`.
- Produces:
  - `persistPhoto(tempUri: string, folder?: string, ext?: string): Promise<string>` — `folder` still defaults to `"photos"`, `ext` defaults to `"jpg"`, so all existing callers are unchanged.
  - `persistPhotoSafe(tempUri: string, folder: string, ext?: string): Promise<string | null>` — `ext` defaults to `"jpg"`.
  - `promptForLogo(onPicked: (uri: string) => void): void` — signature unchanged; its two callers (`screens/OnboardingScreen.tsx:109`, `screens/SettingsScreen.tsx:418`) need no edits.

- [ ] **Step 1: Write the failing extension tests**

Append these two tests inside the existing `describe("persistPhotoSafe", …)` block in `__tests__/photoStorage.test.js` (after the last test, "nothing is written when the copy fails"):

```js
  test("stores under the requested extension so the file name matches its bytes", async () => {
    // A resized logo is PNG. readPhotoAsDataUri derives the data-URI mime type
    // from the extension, so a .jpg name on PNG bytes would mislabel it.
    const uri = await persistPhotoSafe(TEMP, "logos", "png");
    expect(uri).toMatch(/^file:\/\/\/mock\/logos\/.+\.png$/);
  });

  test("defaults to .jpg, so existing callers are unchanged", async () => {
    const uri = await persistPhotoSafe(TEMP, "job-photos");
    expect(uri).toMatch(/^file:\/\/\/mock\/job-photos\/.+\.jpg$/);
  });
```

- [ ] **Step 2: Write the failing pick-path tests**

Create `__tests__/logoPicker.test.js`:

```js
// promptForLogo — the pick path, exercised through the Alert buttons it puts up.
//
// Both pick branches (camera, library) share persistPicked, so driving the
// library button covers the resize for both. The resize is the point: the
// picker's `quality: 0.8` tunes JPEG compression only and caps no dimension, so
// a phone photo used as a logo arrived at full resolution and was stored
// byte-for-byte — the origin of the ~40MB invoice PDFs.

import { Alert } from "react-native";

jest.mock("expo-file-system/legacy", () => ({
  documentDirectory: "file:///mock/",
  getInfoAsync: jest.fn(),
  makeDirectoryAsync: jest.fn(),
  copyAsync: jest.fn(),
}));

jest.mock("../utils/analytics", () => ({ reportError: jest.fn() }));

const FileSystem = require("expo-file-system/legacy");
const ImagePicker = require("expo-image-picker");
const ImageManipulator = require("expo-image-manipulator");
const { reportError } = require("../utils/analytics");
const { promptForLogo } = require("../utils/logoPicker");

const PICKED = "file:///tmp/DCIM/IMG_0001.jpg";
const SHRUNK = "file:///mock/manipulated.png";

let onPicked;
let alertSpy;

// Buttons: [0] Take Photo, [1] Choose from Library, [2] Cancel.
async function chooseFromLibrary() {
  promptForLogo(onPicked);
  const buttons = alertSpy.mock.calls[0][2];
  await buttons[1].onPress();
}

beforeEach(() => {
  jest.clearAllMocks();
  onPicked = jest.fn();
  alertSpy = jest.spyOn(Alert, "alert").mockImplementation(() => {});
  FileSystem.getInfoAsync.mockResolvedValue({ exists: true });
  FileSystem.makeDirectoryAsync.mockResolvedValue(undefined);
  FileSystem.copyAsync.mockResolvedValue(undefined);
  ImagePicker.requestMediaLibraryPermissionsAsync.mockResolvedValue({ status: "granted" });
  ImageManipulator.manipulateAsync.mockReset();
  ImageManipulator.manipulateAsync.mockResolvedValue({
    uri: SHRUNK,
    width: 512,
    height: 384,
  });
});

afterEach(() => alertSpy.mockRestore());

describe("promptForLogo", () => {
  test("resizes an oversized pick before storing it", async () => {
    ImagePicker.launchImageLibraryAsync.mockResolvedValueOnce({
      canceled: false,
      assets: [{ uri: PICKED, width: 4032, height: 3024 }],
    });
    await chooseFromLibrary();
    expect(ImageManipulator.manipulateAsync).toHaveBeenCalledWith(
      PICKED,
      [{ resize: { width: 512 } }],
      { compress: 0.8, format: "png" }
    );
  });

  test("caps a portrait pick on its height", async () => {
    ImagePicker.launchImageLibraryAsync.mockResolvedValueOnce({
      canceled: false,
      assets: [{ uri: PICKED, width: 3024, height: 4032 }],
    });
    await chooseFromLibrary();
    expect(ImageManipulator.manipulateAsync).toHaveBeenCalledWith(
      PICKED,
      [{ resize: { height: 512 } }],
      { compress: 0.8, format: "png" }
    );
  });

  test("re-encodes an already-small pick with no resize action", async () => {
    ImagePicker.launchImageLibraryAsync.mockResolvedValueOnce({
      canceled: false,
      assets: [{ uri: PICKED, width: 300, height: 120 }],
    });
    await chooseFromLibrary();
    expect(ImageManipulator.manipulateAsync).toHaveBeenCalledWith(PICKED, [], {
      compress: 0.8,
      format: "png",
    });
  });

  test("persists the manipulated file under a .png name, never the original", async () => {
    ImagePicker.launchImageLibraryAsync.mockResolvedValueOnce({
      canceled: false,
      assets: [{ uri: PICKED, width: 4032, height: 3024 }],
    });
    await chooseFromLibrary();
    const stored = onPicked.mock.calls[0][0];
    expect(stored).toMatch(/^file:\/\/\/mock\/logos\/.+\.png$/);
    expect(FileSystem.copyAsync).toHaveBeenCalledWith({ from: SHRUNK, to: stored });
  });

  test("probes the file when the picker reports no dimensions", async () => {
    // ImagePickerAsset documents width/height as "can be 0".
    ImagePicker.launchImageLibraryAsync.mockResolvedValueOnce({
      canceled: false,
      assets: [{ uri: PICKED, width: 0, height: 0 }],
    });
    ImageManipulator.manipulateAsync.mockResolvedValueOnce({
      uri: "file:///mock/probe.jpg",
      width: 4032,
      height: 3024,
    });
    await chooseFromLibrary();
    expect(ImageManipulator.manipulateAsync).toHaveBeenNthCalledWith(1, PICKED);
    expect(ImageManipulator.manipulateAsync).toHaveBeenNthCalledWith(
      2,
      PICKED,
      [{ resize: { width: 512 } }],
      { compress: 0.8, format: "png" }
    );
  });

  test("a manipulator failure stores the original and still reports the pick", async () => {
    const boom = new Error("out of memory");
    ImagePicker.launchImageLibraryAsync.mockResolvedValueOnce({
      canceled: false,
      assets: [{ uri: PICKED, width: 4032, height: 3024 }],
    });
    ImageManipulator.manipulateAsync.mockRejectedValueOnce(boom);
    await chooseFromLibrary();
    const stored = onPicked.mock.calls[0][0];
    expect(stored).toMatch(/^file:\/\/\/mock\/logos\/.+\.jpg$/);
    expect(FileSystem.copyAsync).toHaveBeenCalledWith({ from: PICKED, to: stored });
    expect(reportError).toHaveBeenCalledWith(boom, { context: "shrinkLogoOnPick" });
  });

  test("a cancelled pick manipulates and stores nothing", async () => {
    ImagePicker.launchImageLibraryAsync.mockResolvedValueOnce({ canceled: true });
    await chooseFromLibrary();
    expect(ImageManipulator.manipulateAsync).not.toHaveBeenCalled();
    expect(FileSystem.copyAsync).not.toHaveBeenCalled();
    expect(onPicked).not.toHaveBeenCalled();
  });

  test("a failed save alerts and never calls onPicked", async () => {
    ImagePicker.launchImageLibraryAsync.mockResolvedValueOnce({
      canceled: false,
      assets: [{ uri: PICKED, width: 4032, height: 3024 }],
    });
    FileSystem.copyAsync.mockRejectedValueOnce(new Error("disk full"));
    await chooseFromLibrary();
    expect(onPicked).not.toHaveBeenCalled();
    expect(alertSpy).toHaveBeenNthCalledWith(
      2,
      "Couldn't save that image",
      "Your logo wasn't changed. Please try again."
    );
  });
});
```

- [ ] **Step 3: Run both test files to verify they fail**

```bash
npx jest __tests__/photoStorage.test.js __tests__/logoPicker.test.js
```

Expected: FAIL. `photoStorage.test.js` — the `.png` test fails with `Received: "file:///mock/logos/….jpg"` (the extension argument is ignored). `logoPicker.test.js` — `expect(ImageManipulator.manipulateAsync).toHaveBeenCalledWith(...)` fails with "Number of calls: 0" (nothing resizes yet).

- [ ] **Step 4: Add the extension argument to `persistPhoto` / `persistPhotoSafe`**

In `utils/photoStorage.ts`, replace lines 4-14 with:

```ts
// `ext` is the stored file's extension, not a conversion request — the caller
// passes what the bytes actually are. readPhotoAsDataUri derives the data-URI
// mime type from it, so a resized (PNG) logo saved under `.jpg` would be
// handed to the PDF renderer mislabelled.
export async function persistPhoto(
  tempUri: string,
  folder = "photos",
  ext = "jpg",
): Promise<string> {
  const dir = `${FileSystem.documentDirectory}${folder}/`;
  const info = await FileSystem.getInfoAsync(dir);
  if (!info.exists) {
    await FileSystem.makeDirectoryAsync(dir, { intermediates: true });
  }
  const filename = `${Date.now()}_${Math.random().toString(36).slice(2)}.${ext}`;
  const dest = `${dir}${filename}`;
  await FileSystem.copyAsync({ from: tempUri, to: dest });
  return dest;
}
```

and replace the body of `persistPhotoSafe` (lines 32-39) with:

```ts
export async function persistPhotoSafe(
  tempUri: string,
  folder: string,
  ext = "jpg",
): Promise<string | null> {
  try {
    return await persistPhoto(tempUri, folder, ext);
  } catch (err) {
    reportError(err, { context: "persistPhoto", folder });
    return null;
  }
}
```

Leave the doc comment above `persistPhotoSafe` (lines 16-31) exactly as it is.

- [ ] **Step 5: Implement the pick-time resize**

Replace the whole of `utils/logoPicker.ts` lines 1-21 (the imports and `persistPicked`) with:

```ts
import { Alert } from "react-native";
import * as ImagePicker from "expo-image-picker";
import * as ImageManipulator from "expo-image-manipulator";
import { persistPhotoSafe, logoResizeActions, LOGO_COMPRESS } from "./photoStorage";
import { reportError } from "./analytics";

// Only the fields the resize needs. ImagePicker always supplies width/height,
// but documents both as "can be 0" when the platform did not report them.
type PickedAsset = { uri: string; width?: number; height?: number };

// The picker's own dimensions when it gave usable ones, otherwise ask the
// manipulator. Never guess: resizing against a 0 would upscale a small logo.
async function dimensionsOf(asset: PickedAsset): Promise<{ width: number; height: number }> {
  const width = asset.width ?? 0;
  const height = asset.height ?? 0;
  if (width > 0 && height > 0) return { width, height };
  const probe = await ImageManipulator.manipulateAsync(asset.uri);
  return { width: probe.width, height: probe.height };
}

/**
 * The picked image capped at 512px on its longest side and re-encoded as PNG,
 * plus the extension its bytes now have.
 *
 * `quality: 0.8` on the picker tunes JPEG compression only and caps no
 * dimension, so a modern phone photo arrived at full 12-48MP and was stored
 * byte-for-byte — which is what produced ~40MB invoice PDF attachments.
 *
 * PNG, not JPEG: logos are commonly transparent, and JPEG would flatten that
 * onto a solid box that shows against the PDF letterhead and in dark mode.
 *
 * A manipulator failure must not cost the user their pick, so the original is
 * returned instead. The pick still succeeds (just large) and `readLogoForPdf`
 * still bounds every PDF built from it.
 */
async function shrinkForLogo(asset: PickedAsset): Promise<{ uri: string; ext: string }> {
  try {
    const { width, height } = await dimensionsOf(asset);
    const result = await ImageManipulator.manipulateAsync(
      asset.uri,
      logoResizeActions(width, height),
      { compress: LOGO_COMPRESS, format: ImageManipulator.SaveFormat.PNG },
    );
    return { uri: result.uri, ext: "png" };
  } catch (err) {
    reportError(err, { context: "shrinkLogoOnPick" });
    return { uri: asset.uri, ext: "jpg" };
  }
}

// Shrink the chosen image, copy it into app storage and hand back the persisted
// path. Shared tail of both pick branches; a cancelled or empty result is a
// no-op. A failed copy tells the user their logo is unchanged rather than
// leaving the tap looking ignored, and never calls onPicked — so no caller
// records a path to a file that was not written.
async function persistPicked(
  result: { canceled: boolean; assets?: PickedAsset[] | null },
  onPicked: (uri: string) => void,
): Promise<void> {
  if (result.canceled || !result.assets?.[0]) return;
  const shrunk = await shrinkForLogo(result.assets[0]);
  const uri = await persistPhotoSafe(shrunk.uri, "logos", shrunk.ext);
  if (!uri) {
    Alert.alert("Couldn't save that image", "Your logo wasn't changed. Please try again.");
    return;
  }
  onPicked(uri);
}
```

Leave `promptForLogo` (lines 23-63 of the original file) untouched.

- [ ] **Step 6: Run both test files to verify they pass**

```bash
npx jest __tests__/photoStorage.test.js __tests__/logoPicker.test.js
```

Expected: PASS — 23 tests in `photoStorage.test.js`, 8 in `logoPicker.test.js`.

- [ ] **Step 7: Run the gate**

```bash
npm run typecheck
npm test
npm run lint
```

Expected: typecheck 0 errors; `Tests: 1457 passed, 1457 total` / `Test Suites: 91 passed, 91 total`; lint 0 warnings.

- [ ] **Step 8: Commit**

```bash
git add utils/photoStorage.ts utils/logoPicker.ts __tests__/photoStorage.test.js __tests__/logoPicker.test.js
git commit -m "feat: cap picked logos at 512px and store them as png"
```

---

### Task 5: Docs, final verification, and the owner smoke handoff

Brings the two tracked docs and one stale code comment in line with the change, then verifies the whole branch as a unit.

**Files:**
- Modify: `utils/logoLifecycle.ts:29-31` (doc comment)
- Modify: `ARCHITECTURE.md:344` area (Tech Stack list)
- Modify: `README.md:124` (module map)

**Interfaces:**
- Consumes: everything from Tasks 1-4. Produces no code.

- [ ] **Step 1: Fix the stale filename comment in `logoLifecycle.ts`**

Logo files are no longer always `.jpg`. The sweep only parses the timestamp prefix, so behaviour is unaffected — but the comment now misstates the naming scheme. Replace lines 29-31:

```ts
/**
 * `persistPhoto` names every file `${Date.now()}_${random}.jpg`, so a file's
 * creation time is recoverable from its name — no stat call per file.
```

with:

```ts
/**
 * `persistPhoto` names every file `${Date.now()}_${random}.<ext>` (`.png` for a
 * logo that the pick-time resize re-encoded, `.jpg` otherwise), so a file's
 * creation time is recoverable from its name — no stat call per file. Only the
 * timestamp prefix is parsed, so the extension is irrelevant here.
```

Leave the rest of the comment and all code in the file untouched.

- [ ] **Step 2: Add the dependency to `ARCHITECTURE.md`**

In the "### Mobile app" list under "## Tech Stack", insert a new bullet directly after the `expo-image-picker` line (`ARCHITECTURE.md:344`):

```markdown
- **expo-image-manipulator** — caps the business logo at 512px when it is picked, and again when it is embedded in a PDF
```

- [ ] **Step 3: Update the module map in `README.md`**

Change line 124 from

```
  photoStorage.ts                ← Device photo management (expo-file-system)
```

to

```
  photoStorage.ts                ← Device photo management + logo downscale for PDFs
```

(Keep the existing column alignment: the `←` stays in the same column as the surrounding lines.)

- [ ] **Step 4: Run the full gate one last time**

```bash
npm run typecheck
npm test
npm run lint
```

Expected: typecheck 0 errors; `Tests: 1457 passed, 1457 total` / `Test Suites: 91 passed, 91 total`; lint 0 warnings.

- [ ] **Step 5: Commit**

```bash
git add utils/logoLifecycle.ts ARCHITECTURE.md README.md
git commit -m "docs: record the logo downscale and its new dependency"
```

- [ ] **Step 6: Review the branch as a whole**

```bash
git log --oneline master..feat/pdf-logo-size
git diff master...feat/pdf-logo-size --stat
```

Expected: **six** commits, in this order — `docs:` plan, `build:` dependency + mock, `feat:` readLogoForPdf, `fix:` call sites, `feat:` pick-time resize, `docs:` docs. The `--stat` diff must list **only** these files: `docs/superpowers/plans/2026-08-01-pdf-logo-size.md`, `package.json`, `package-lock.json`, `jest.setup.js`, `utils/photoStorage.ts`, `utils/logoPicker.ts`, `utils/invoicePdfFile.ts`, `utils/logoLifecycle.ts`, `screens/InvoicesScreen.tsx`, `screens/SendEstimateScreen.tsx`, `__tests__/photoStorage.test.js`, `__tests__/invoicePdfFile.test.js`, `__tests__/logoPicker.test.js`, `ARCHITECTURE.md`, `README.md`. **`app.json` must not appear.** If it does, STOP and escalate.

- [ ] **Step 7: Hand the device smoke to the owner**

Report to the owner that the branch is code-complete and gate-green, and that it needs device smoke via Expo Go (SDK 54's Expo Go bundles `expo-image-manipulator`, so no build is required to smoke it). The checklist, from the spec's Testing section:

1. Pick a full-resolution phone photo as the business logo in Settings, save, then email an invoice PDF to yourself. Attachment size should be well under 1MB (was ~40MB).
2. Repeat with a logo that was already stored *before* this branch (do not re-pick it) — this exercises the Layer 2 path only. Attachment should also be small.
3. Export/share an estimate PDF and spot-check that the logo renders.
4. Use a transparent PNG as the logo and confirm the transparency survives in the PDF (no white or black box behind it).
5. Confirm the Settings logo preview still shows the picked image, and that Discard still restores the previous logo.

Also remind the owner: **this branch is not OTA-eligible** — `expo-image-manipulator` is native, so it must ride the next store build and must not be shipped via `eas update` onto the current binary.

---

## Notes for the implementer

**Why `manipulateAsync` and not the newer contextual API.** `expo-image-manipulator@14.0.8` still exports `manipulateAsync`, but marks it `@deprecated` in favour of `ImageManipulator.manipulate(...)`/`useImageManipulator`. The owner-approved spec specifies `manipulateAsync`, and it is not a lint or typecheck problem here: this repo's ESLint config (`.eslintrc.js`, `extends: ["expo"]`) enables no type-aware rules, so `@typescript-eslint/no-deprecated` is not in play, and `tsc` does not error on deprecated symbols. Do not "modernise" it as part of this branch — that is a separate decision for the owner.

**Namespace imports are the house pattern for Expo native modules** (`import * as Print from "expo-print"` in `utils/invoicePdfFile.ts:8`). `.eslintrc.js` turns `import/namespace` off specifically for this. Note that `expo-image-manipulator` also has a *value* export named `ImageManipulator` (the native module object); with the namespace import, `ImageManipulator.manipulateAsync` and the type `ImageManipulator.Action` both resolve correctly.

**`Number.isFinite` in `logoResizeActions` is load-bearing.** `manipulateAsync`'s resize action derives the unspecified dimension from the aspect ratio, so a resize against a `0` or `NaN` dimension would enlarge a small logo instead of shrinking a large one.
