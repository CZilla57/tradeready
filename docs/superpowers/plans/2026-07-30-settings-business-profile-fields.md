# Settings business address & logo — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the user edit their business address and logo from Settings → "Your business", not only during onboarding.

**Architecture:** Both fields already exist end-to-end on the `Settings` model, so this adds UI only. The logo's filesystem side effects are reconciled with the screen's draft-then-Save contract by extracting one pure helper (`orphanedLogoPaths`) that decides which image files may be deleted; the screen accumulates every logo path touched during the session and calls the helper at each of the **three** commit points.

**Tech Stack:** React Native (Expo 54, RN 0.81, React 19), TypeScript strict, Jest (CommonJS unit tests), `expo-image`, `expo-image-picker`, `expo-file-system/legacy` via `utils/photoStorage.ts`.

**Spec:** `docs/superpowers/specs/2026-07-30-settings-business-profile-fields-design.md`

## Global Constraints

- **Branch:** `feat/settings-business-profile`. Repo root for all commands: `C:\Users\Chadr\OneDrive\Documents\TraderPro App\tradeready\`.
- **Gate must be green before every commit** — `npm run typecheck` (0 errors), `npm test` (all pass), `npm run lint` (0 warnings, `--max-warnings=0`). Never commit on red.
- **No `package.json` change.** `expo-image`, `expo-image-picker` and `utils/photoStorage` are already project dependencies used by `OnboardingScreen.tsx`. Adding a dependency requires owner approval (Rule 3).
- **No persisted data-shape change.** `address` and `logoPhoto` already exist (`types/models.ts:323,325`) and are already initialized (`utils/storage/defaults.ts:205,207`).
- **No new `eslint-disable` / `@ts-ignore` / `@ts-expect-error`.** In particular, do not add an import in one task and first use it in a later task — an unused import is an eslint warning, which is a red gate. Each task imports only what it uses.
- **`deletePhoto` may only ever be called on a path the *persisted* settings no longer reference.** This is the single rule preventing a "Discard" from destroying a user's logo.
- **Tests are pure-logic CommonJS** (`__tests__/*.test.js`, `require(...)`). Do not add a screen render test — the repo has 66 suites and none render a screen (see spec §Testing).
- **User-visible copy** is reused verbatim from onboarding: label `Your logo`, hint `Optional — appears on invoices and estimates.`, alert title `Add your logo`, buttons `Take Photo` / `Choose from Library` / `Cancel`, remove button `Remove`.

## File Structure

| File | Responsibility |
|---|---|
| **Create** `utils/logoLifecycle.ts` | Pure decision: which logo paths are safe to delete. No I/O, no React. |
| **Create** `__tests__/logoLifecycle.test.js` | Covers all six pick/remove/save/discard scenarios. |
| **Modify** `screens/SettingsScreen.tsx` | Address field, logo picker UI, and cleanup wiring at three commit points. |
| **Modify** spec doc | Only if reality diverges; note it in the phase report. |

**Why a separate util:** the data-loss edge is pure logic, and isolating it makes it fully testable without a screen harness. Matches the project's established born-typed-util pattern (`utils/settingsDirty.ts`, `utils/deleteConfirm.ts`).

### Anchors in `screens/SettingsScreen.tsx` (verified 2026-07-30)

| Line(s) | What |
|---|---|
| 1–41 | import block |
| 104–109 | `savedSnapshot` state + mirroring refs |
| 111–140 | blur handler — **Discard branch :124**, **Save branch :128–134** |
| 154–155 | load effect: `setS(loaded); setSavedSnapshot(loaded);` |
| 237–239 | `update(field, value)` |
| 303–314 | `handleSave()` — **third commit point** |
| 361–384 | "Your business" card JSX (Email at :366, trade grid ends :383) |
| 875–896 | local `Field` wrapper (`FieldProps` supports `multiline`, `autoCapitalize`) |
| 906 | `inputMultiline: { height: 80, ... }` — the fixed height to change |

---

### Task 1: Pure logo-lifecycle helper

**Files:**
- Create: `utils/logoLifecycle.ts`
- Test: `__tests__/logoLifecycle.test.js`

**Interfaces:**
- Consumes: nothing.
- Produces: `orphanedLogoPaths(touched: readonly string[], keepPath: string | null | undefined): string[]` — returns the de-duplicated subset of `touched` that is non-empty and not equal to `keepPath`, preserving input order. Task 4 calls this at all three commit points.

- [ ] **Step 1: Write the failing test**

Create `__tests__/logoLifecycle.test.js`:

```js
// Which logo image files may be deleted once settings are committed.
// The Settings screen edits a draft, so a file is only deletable when the
// PERSISTED settings no longer reference it — otherwise "Discard" would
// destroy an image the saved settings still point at.

const { orphanedLogoPaths } = require("../utils/logoLifecycle");

const ORIGINAL = "file:///docs/logos/original.jpg";
const PICKED_A = "file:///docs/logos/a.jpg";
const PICKED_B = "file:///docs/logos/b.jpg";

describe("orphanedLogoPaths", () => {
  test("logo untouched — nothing is deleted", () => {
    expect(orphanedLogoPaths([ORIGINAL], ORIGINAL)).toEqual([]);
  });

  test("replaced then saved — the old file is orphaned", () => {
    expect(orphanedLogoPaths([ORIGINAL, PICKED_A], PICKED_A)).toEqual([ORIGINAL]);
  });

  test("removed then saved — the old file is orphaned", () => {
    expect(orphanedLogoPaths([ORIGINAL], "")).toEqual([ORIGINAL]);
  });

  test("picked then discarded — the new copy is orphaned, the saved one survives", () => {
    expect(orphanedLogoPaths([ORIGINAL, PICKED_A], ORIGINAL)).toEqual([PICKED_A]);
  });

  test("removed then discarded — nothing is deleted", () => {
    expect(orphanedLogoPaths([ORIGINAL], ORIGINAL)).toEqual([]);
  });

  test("picked twice then saved — every superseded file is orphaned", () => {
    expect(orphanedLogoPaths([ORIGINAL, PICKED_A, PICKED_B], PICKED_B))
      .toEqual([ORIGINAL, PICKED_A]);
  });

  test("no prior logo, picked then discarded — the new copy is orphaned", () => {
    expect(orphanedLogoPaths(["", PICKED_A], "")).toEqual([PICKED_A]);
  });

  test("empty strings are never returned as deletable paths", () => {
    expect(orphanedLogoPaths(["", ""], PICKED_A)).toEqual([]);
  });

  test("duplicates collapse to a single deletion", () => {
    expect(orphanedLogoPaths([PICKED_A, PICKED_A], "")).toEqual([PICKED_A]);
  });

  test("null and undefined keepPath behave like no logo", () => {
    expect(orphanedLogoPaths([PICKED_A], null)).toEqual([PICKED_A]);
    expect(orphanedLogoPaths([PICKED_A], undefined)).toEqual([PICKED_A]);
  });

  test("no touched paths — nothing to delete", () => {
    expect(orphanedLogoPaths([], PICKED_A)).toEqual([]);
  });
});
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
npm test -- logoLifecycle
```

Expected: FAIL — `Cannot find module '../utils/logoLifecycle'`.

- [ ] **Step 3: Write the implementation**

Create `utils/logoLifecycle.ts`:

```ts
/**
 * Decides which logo image files may be deleted from disk.
 *
 * The Settings screen edits a draft: logo changes are not persisted until the
 * user taps Save, and "Discard" must restore the previous image. A logo file is
 * therefore only deletable once the PERSISTED settings no longer reference it.
 *
 * Callers accumulate every logo path touched during the session (the one loaded
 * from settings, plus each file copied in by the picker) and pass the path the
 * persisted settings now hold. Everything else is an orphan.
 */
export function orphanedLogoPaths(
  touched: readonly string[],
  keepPath: string | null | undefined,
): string[] {
  const seen = new Set<string>();
  const orphans: string[] = [];
  for (const path of touched) {
    if (!path || path === keepPath || seen.has(path)) continue;
    seen.add(path);
    orphans.push(path);
  }
  return orphans;
}
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
npm test -- logoLifecycle
```

Expected: PASS — 11 tests.

- [ ] **Step 5: Run the full gate**

```bash
npm run typecheck && npm test && npm run lint
```

Expected: 0 tsc errors; all suites pass (67 suites now); 0 lint warnings.

- [ ] **Step 6: Commit**

```bash
git add utils/logoLifecycle.ts __tests__/logoLifecycle.test.js
git commit -m "feat: add orphanedLogoPaths helper for draft-safe logo file cleanup"
```

---

### Task 2: Business address field + multiline sizing fix

**Files:**
- Modify: `screens/SettingsScreen.tsx:366` (insert after the Email field), `:906` (`inputMultiline`)

**Interfaces:**
- Consumes: existing `Field` wrapper (`:886`), `update` (`:237`), `s.address`.
- Produces: nothing consumed by later tasks.

No test step: there is no screen-render harness in this repo (see Global Constraints), and this task adds no logic. Verification is the gate plus device smoke.

- [ ] **Step 1: Add the address field**

In `screens/SettingsScreen.tsx`, immediately after the Email `Field` (`:366`) and before the Payment instructions `Field`, insert:

```tsx
          <Field label="Business address" value={s.address} onChangeText={(v) => update("address", v)} multiline autoCapitalize="words" colors={colors} shadow={shadow} />
```

- [ ] **Step 2: Fix the multiline height**

At `:906`, change the fixed height to a minimum height. Replace:

```ts
    inputMultiline: { height: 80, paddingTop: spacing.sm, textAlignVertical: "top" },
```

with:

```ts
    // minHeight (not height): a fixed height fights BaseField's multiline sizing —
    // the input paints taller than its layout box and later siblings (the logo
    // block) render on top of it (device finding, 2026-07-14, see OnboardingScreen).
    inputMultiline: { minHeight: 80, paddingTop: spacing.sm, textAlignVertical: "top" },
```

- [ ] **Step 3: Run the gate**

```bash
npm run typecheck && npm test && npm run lint
```

Expected: 0 tsc errors; all tests pass; 0 lint warnings.

- [ ] **Step 4: Commit**

```bash
git add screens/SettingsScreen.tsx
git commit -m "feat: let users edit their business address from Settings"
```

---

### Task 3: Logo picker UI (draft-only)

**Files:**
- Modify: `screens/SettingsScreen.tsx` — imports (`:1–41`), handlers (after `update`, `:239`), JSX (after the trade grid, `:383`), styles (in `createStyles`, near `:906`)

**Interfaces:**
- Consumes: `persistPhoto` from `utils/photoStorage`, `update` (`:237`), `s.logoPhoto`.
- Produces: `handlePickLogo(): void` and `handleRemoveLogo(): void`. Task 4 modifies the body of `handlePickLogo` to record picked paths; it does not rename either function.

**Deliberately incomplete:** this task never calls `deletePhoto`, so replaced files linger on disk. That is safe (nothing is destroyed) and Task 4 closes it. Do **not** import `deletePhoto` here — it would be an unused import and a red gate.

- [ ] **Step 1: Add the imports**

In the import block of `screens/SettingsScreen.tsx`, add:

```tsx
import { Image } from "expo-image";
import * as ImagePicker from "expo-image-picker";
import { persistPhoto } from "../utils/photoStorage";
```

Place `import { Image } from "expo-image";` after the `react-native` import block (matching `OnboardingScreen.tsx:14`), and the other two alongside the existing `../utils/*` imports.

- [ ] **Step 2: Add the handlers**

Immediately after the `update` function (`:239`), insert:

```tsx
  // The logo follows this screen's draft contract: picking copies the file in and
  // points the draft at it, removing only clears the draft reference. Neither
  // deletes anything — cleanup happens once settings are committed, so "Discard"
  // can still restore the previous image. See utils/logoLifecycle.ts.
  function handlePickLogo() {
    Alert.alert("Add your logo", "", [
      {
        text: "Take Photo",
        onPress: async () => {
          const { status } = await ImagePicker.requestCameraPermissionsAsync();
          if (status !== "granted") {
            Alert.alert("Permission needed", "Camera access is required to take a photo.");
            return;
          }
          const result = await ImagePicker.launchCameraAsync({ mediaTypes: ["images"] as any, quality: 0.8 });
          if (!result.canceled) {
            const uri = await persistPhoto(result.assets[0].uri, "logos");
            update("logoPhoto", uri);
          }
        },
      },
      {
        text: "Choose from Library",
        onPress: async () => {
          const { status } = await ImagePicker.requestMediaLibraryPermissionsAsync();
          if (status !== "granted") {
            Alert.alert("Permission needed", "Photo library access is required.");
            return;
          }
          const result = await ImagePicker.launchImageLibraryAsync({ mediaTypes: ["images"] as any, quality: 0.8 });
          if (!result.canceled) {
            const uri = await persistPhoto(result.assets[0].uri, "logos");
            update("logoPhoto", uri);
          }
        },
      },
      { text: "Cancel", style: "cancel" },
    ]);
  }

  function handleRemoveLogo() {
    update("logoPhoto", "");
  }
```

`mediaTypes: ["images"] as any` matches `OnboardingScreen.tsx:117,132` — keep the cast so typecheck stays green against the installed `expo-image-picker` types.

- [ ] **Step 3: Add the JSX**

In the "Your business" card, after the trade-grid closing `</View>` (`:383`) and before the card's closing `</View>` (`:384`), insert:

```tsx
          <Text style={[styles.fieldLabel, { marginTop: spacing.md }]}>Your logo</Text>
          <Text style={styles.logoHint}>Optional — appears on invoices and estimates.</Text>
          <TouchableOpacity
            style={styles.logoPicker}
            onPress={handlePickLogo}
            activeOpacity={0.7}
            accessibilityRole="button"
            accessibilityLabel={s.logoPhoto ? "Change your business logo" : "Add your business logo"}
          >
            {s.logoPhoto ? (
              <Image source={{ uri: s.logoPhoto }} style={styles.logoImage} contentFit="cover" />
            ) : (
              <View style={styles.logoPlaceholder}>
                <Text style={styles.logoPlaceholderIcon}>📷</Text>
                <Text style={styles.logoPlaceholderText}>Add logo</Text>
              </View>
            )}
          </TouchableOpacity>
          {!!s.logoPhoto && (
            <TouchableOpacity
              onPress={handleRemoveLogo}
              style={styles.logoRemoveBtn}
              accessibilityRole="button"
              accessibilityLabel="Remove your business logo"
            >
              <Text style={styles.logoRemoveText}>Remove</Text>
            </TouchableOpacity>
          )}
```

Use `!!s.logoPhoto &&` (not `s.logoPhoto &&`): `logoPhoto` is a string, and a bare `&&` on `""` would render an empty string child.

- [ ] **Step 4: Add the styles**

Inside `createStyles`, after the `inputMultiline` entry, insert:

```ts
    logoHint: { fontSize: fontSize.xs, color: colors.textMuted, marginBottom: spacing.sm },
    logoPicker: { alignSelf: "flex-start", marginBottom: spacing.xs },
    logoImage: { width: 80, height: 80, borderRadius: 40, backgroundColor: colors.background },
    logoPlaceholder: { width: 80, height: 80, borderRadius: 40, backgroundColor: colors.background, borderWidth: 1, borderColor: colors.border, borderStyle: "dashed", alignItems: "center", justifyContent: "center" },
    logoPlaceholderIcon: { fontSize: 24, marginBottom: 2 },
    logoPlaceholderText: { fontSize: fontSize.xs, color: colors.textMuted },
    logoRemoveBtn: { alignSelf: "flex-start", marginTop: 4, minHeight: 44, justifyContent: "center" },
    logoRemoveText: { fontSize: fontSize.xs, color: colors.danger },
```

Two deliberate differences from onboarding's copies: the thumbnail sits on `colors.background` (onboarding uses `colors.surface`, but in Settings the card itself is `colors.surface`, so the placeholder would have no contrast), and `logoRemoveBtn` carries `minHeight: 44` for the project's 44pt touch-target standard.

- [ ] **Step 5: Run the gate**

```bash
npm run typecheck && npm test && npm run lint
```

Expected: 0 tsc errors; all tests pass; 0 lint warnings. If lint reports `Image` or `ImagePicker` unused, a JSX or handler insert was missed.

- [ ] **Step 6: Commit**

```bash
git add screens/SettingsScreen.tsx
git commit -m "feat: add a logo picker to the Settings business section"
```

---

### Task 4: Wire file cleanup into all three commit points

**Files:**
- Modify: `screens/SettingsScreen.tsx` — imports, a new ref near `:107`, load effect `:154–155`, blur handler `:124` and `:128–134`, `handleSave` `:303–314`, `handlePickLogo` (from Task 3)

**Interfaces:**
- Consumes: `orphanedLogoPaths` (Task 1), `handlePickLogo` (Task 3), `deletePhoto` from `utils/photoStorage`.
- Produces: nothing further.

**The three commit points.** `handleSave` is not the only one — the blur handler has its own Save branch that calls `saveSettings` directly, and its Discard branch abandons draft files. All three must clean up, or the blur paths leak.

- [ ] **Step 1: Extend the imports**

Change the Task 3 photoStorage import to add `deletePhoto`, and import the helper:

```tsx
import { persistPhoto, deletePhoto } from "../utils/photoStorage";
import { orphanedLogoPaths } from "../utils/logoLifecycle";
```

- [ ] **Step 2: Add the tracking ref**

After `suppressDirtyWarnRef` (`:107`), insert:

```tsx
  // Every logo path this session has referenced — the one loaded from settings plus
  // each file the picker copied in. At each commit point, whichever of these the
  // persisted settings no longer reference is deleted. Seeded on load so an
  // untouched logo is trivially "kept".
  const touchedLogoPathsRef = useRef<string[]>([]);

  // Delete the image files the just-committed settings no longer reference, then
  // reset the session's tracking to that surviving path.
  async function cleanupLogoFiles(committedLogoPath: string | undefined) {
    const orphans = orphanedLogoPaths(touchedLogoPathsRef.current, committedLogoPath);
    touchedLogoPathsRef.current = committedLogoPath ? [committedLogoPath] : [];
    for (const path of orphans) {
      await deletePhoto(path);
    }
  }
```

- [ ] **Step 3: Seed the ref on load**

In the load effect, change `:154–155` from:

```tsx
      setS(loaded);
      setSavedSnapshot(loaded);
```

to:

```tsx
      setS(loaded);
      setSavedSnapshot(loaded);
      touchedLogoPathsRef.current = loaded.logoPhoto ? [loaded.logoPhoto] : [];
```

- [ ] **Step 4: Record each picked file**

In `handlePickLogo`, in **both** the Take Photo and Choose from Library branches, change:

```tsx
            const uri = await persistPhoto(result.assets[0].uri, "logos");
            update("logoPhoto", uri);
```

to:

```tsx
            const uri = await persistPhoto(result.assets[0].uri, "logos");
            touchedLogoPathsRef.current = [...touchedLogoPathsRef.current, uri];
            update("logoPhoto", uri);
```

- [ ] **Step 5: Clean up in `handleSave`**

In `handleSave` (`:303`), after `setSavedSnapshot(flushed);` and before `setSaving(false);`, insert:

```tsx
    await cleanupLogoFiles(flushed.logoPhoto);
```

- [ ] **Step 6: Clean up in both blur branches**

In the blur handler, change the Discard branch (`:121–125`) to:

```tsx
          {
            text: "Discard",
            style: "destructive",
            onPress: () => {
              const saved = savedSnapshotRef.current;
              if (!saved) return;
              setS(saved);
              // Files copied in during the abandoned edit are unreferenced now;
              // the saved logo is passed as the keeper so it is never deleted.
              cleanupLogoFiles(saved.logoPhoto);
            },
          },
```

and the Save branch (`:126–135`) to:

```tsx
          {
            text: "Save",
            onPress: async () => {
              const toSave = sRef.current;
              if (!toSave) return;
              await saveSettings(toSave);
              syncNotifications();
              setSavedSnapshot(toSave);
              await cleanupLogoFiles(toSave.logoPhoto);
            },
          },
```

- [ ] **Step 7: Run the gate**

```bash
npm run typecheck && npm test && npm run lint
```

Expected: 0 tsc errors; all tests pass; 0 lint warnings.

- [ ] **Step 8: Verify the rule by inspection**

```bash
grep -n "deletePhoto\|cleanupLogoFiles\|orphanedLogoPaths" screens/SettingsScreen.tsx
```

Expected: `deletePhoto` appears exactly twice — the import and the single call inside `cleanupLogoFiles`. **If `deletePhoto` is called anywhere else, the draft-safety rule is broken.** `cleanupLogoFiles` should appear four times (definition + three commit points).

- [ ] **Step 9: Commit**

```bash
git add screens/SettingsScreen.tsx
git commit -m "fix: delete superseded logo files only once settings are committed"
```

---

## Device smoke checklist (owner, after Task 4)

Jest cannot reach any of this. Run on a physical device:

- [ ] Settings → Your business shows **Business address** (multi-line) and, at the card's end, **Your logo**.
- [ ] The address input does **not** overlap the logo block while typing several lines — the 2026-07-14 bug.
- [ ] Add logo → Take Photo: permission prompt, capture, thumbnail appears.
- [ ] Add logo → Choose from Library: permission prompt, pick, thumbnail appears.
- [ ] Deny each permission once: the "Permission needed" alert shows and nothing changes.
- [ ] Pick a logo → **Save settings** → leave and return: the logo persists.
- [ ] Replace the logo → Save → the new one shows.
- [ ] Remove → Save → placeholder shows; return to confirm it stayed removed.
- [ ] **Remove → leave the tab → Discard: the original logo is still there.** The data-loss edge this design exists to prevent.
- [ ] **Pick a new logo → leave the tab → Discard: the previous logo is restored.**
- [ ] Save an address, then generate an invoice PDF and an estimate: the address and logo appear.
- [ ] Dark mode: the dashed placeholder and Remove text are legible.

## Self-review notes

- **Spec coverage:** §1 address → Task 2. §2 picker → Task 3. §3 draft semantics → Tasks 1 + 4. §4 `minHeight` + logo placement → Task 2 (style) + Task 3 (placement at card end). §Testing → Task 1 unit tests + the device checklist. All six of the spec's lifecycle scenarios appear as named tests in Task 1, plus five edge cases.
- **Deviation from spec, flagged:** the spec's "render test" bullet is dropped — the repo has zero screen render tests. Recorded in the spec's Testing section, reasoning included.
- **Type consistency:** `orphanedLogoPaths(touched, keepPath)` is defined in Task 1 and called only via `cleanupLogoFiles(committedLogoPath)` in Task 4. `handlePickLogo` / `handleRemoveLogo` keep the same names across Tasks 3 and 4. `logoPhoto` is typed `string | undefined` (optional on `Settings`), which is why `cleanupLogoFiles` takes `string | undefined` and `orphanedLogoPaths` accepts `null | undefined` for `keepPath`.
- **Task independence:** Task 1 is standalone. Task 2 is standalone. Task 3 depends on nothing but itself (safe-but-leaky). Task 4 depends on 1 and 3. Each ends on a green gate.
