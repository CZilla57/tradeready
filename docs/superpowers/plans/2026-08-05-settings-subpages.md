# Settings Hub + Focused Subpages Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the 1,390-line monolithic SettingsScreen with a menu hub at the same route plus 11 focused subpage screens, preserving every behavior via a shared `useSettingsDraft` hook.

**Architecture:** Faithful extraction, not redesign. A shared hook carries the draft/dirty/guard/save machinery; each subpage owns its slice of `Settings` and moves its JSX + styles verbatim from the monolith. The monolith stays in the repo untouched until the final task, so its committed line numbers are the extraction reference throughout.

**Tech Stack:** Expo 54 / React Native 0.81 / React 19 / TypeScript strict / React Navigation native-stack / Jest + RNTL v14 (async renders).

**Spec:** `docs/superpowers/specs/2026-08-05-settings-subpages-design.md` (owner-approved 2026-08-05). One API refinement vs the spec: the hook option `onLoaded` is realized as `prepare(loaded) => Settings | Promise<Settings>` — an async load-massage that both transforms the loaded settings (dangling-logo blanking, provider-key backfill) and performs page-local seeding, which the spec's read-only `onLoaded` could not.

## Global Constraints

- Repo root: `C:\Users\Chadr\OneDrive\Documents\TraderPro App\tradeready\`. All commands run from there.
- **All "copy lines N–M" references are against `screens/SettingsScreen.tsx` as committed at `e2b7351`.** That file must NOT be edited until Task 17 deletes it.
- Owner rules (tradeready-change-control): green gate before EVERY commit — `npm run typecheck` (0 errors), `npm test` (all suites), `npm run lint` (0 warnings). No dependency changes. No `eslint-disable` / `@ts-ignore`.
- Every new screen uses the theming factory: `const styles = useMemo(() => createStyles(colors, shadow), [colors, shadow])` with a module-level `createStyles(colors: ColorScheme, shadow: ShadowScheme)`. Never import the static `colors` alias.
- Every new form page keeps `KeyboardAvoidingView behavior={Platform.OS === "ios" ? "padding" : undefined}` (NOT `automaticallyAdjustKeyboardInsets` — device finding 2026-07-14) and `...layout.contentColumn` in the scroll `contentContainerStyle` (iPad).
- When moving JSX blocks: **drop the `<SectionHeader …/>` and `<Divider />` lines** (the native header now carries the page title) and **strip ` shadow={shadow}` from `<Field …/>` elements only** (the shared SettingsField no longer takes it; all other `shadow` uses stay).
- Commit messages: imperative subject, `feat:`/`chore:`/`test:` prefix, end with the Co-Authored-By line used in this repo's recent history.
- No persisted data-shape changes anywhere in this plan. Every save goes through the existing `saveSettings` (which strips SECURE_FIELDS).
- Test runs during a task may target one suite (`npx jest __tests__/<file> --silent`); the pre-commit gate is always the full three commands.

## File Structure

| File | Status | Responsibility |
|---|---|---|
| `utils/settingsValidation.ts` | Modify | Split into `validateEmailPhone` + `validateLaborRate`; `validateSettingsInput` becomes their composition (contract unchanged) |
| `hooks/useSettingsDraft.ts` | Create | `useSettingsTabPop` (blur → popToTop) + `useSettingsDraft` (draft, dirty, header Save, beforeRemove guard, save paths) |
| `types/navigation.ts` | Modify | 11 new routes in `TodayStackParamList` |
| `components/SettingsField.tsx` | Create | The settings-form Field wrapper (extracted from the monolith's local `Field`) |
| `utils/stripeStatus.ts` | Create | `fetchStripeConnectStatus()` — shared by Payments page + hub; owns the `markSetupTaskDone("stripe")` side effect |
| `screens/SettingsAppearanceScreen.tsx` | Create | Theme preference (immediate) |
| `screens/SettingsPricingScreen.tsx` | Create | Pricing defaults (draft; labor-rate validation; `markSetupTaskDone("rate")`) |
| `screens/SettingsInvoiceNumberingScreen.tsx` | Create | Invoice prefix + start number (draft) |
| `screens/SettingsAIScreen.tsx` | Create | Advanced toggle + API keys (draft) |
| `screens/SettingsReviewsScreen.tsx` | Create | Review requests (draft) |
| `screens/SettingsBusinessScreen.tsx` | Create | Business fields + trade + logo lifecycle (draft; email/phone validation) |
| `screens/SettingsNotificationsScreen.tsx` | Create | Overdue rules + automation toggles + templates (draft; rule-draft flush) |
| `screens/SettingsPaymentsScreen.tsx` | Create | Provider picker + key (draft) and Stripe Connect (immediate) |
| `screens/SettingsBookingScreen.tsx` | Create | Booking link (immediate; simplified handlers) |
| `screens/SettingsSubscriptionScreen.tsx` | Create | Subscription status + manage/subscribe (immediate) |
| `screens/SettingsAccountScreen.tsx` | Create | Clear sample data / sign out / delete account (immediate) |
| `screens/SettingsHubScreen.tsx` | Create | The menu hub (rows, subtitles, support/legal actions) |
| `App.tsx` | Modify | Register 11 subpage routes (Tasks 5–15); swap `Settings` to the hub (Task 17) |
| `components/SetupChecklistCard.tsx`, `screens/TodayScreen.tsx` | Modify (Task 17) | Checklist deep-links |
| `screens/SettingsScreen.tsx` | **Delete (Task 17 only)** | The extraction reference until then |
| `__tests__/settingsValidation.test.js` | Modify | Add helper coverage |
| `__tests__/useSettingsDraft.test.tsx` | Create | Hook behavior suite |
| `__tests__/settingsPricingScreen.test.tsx`, `__tests__/settingsBusinessScreen.test.tsx`, `__tests__/settingsNotificationsScreen.test.tsx`, `__tests__/settingsPaymentsScreen.test.tsx`, `__tests__/settingsSubscriptionScreen.test.tsx`, `__tests__/settingsAccountScreen.test.tsx`, `__tests__/settingsHubScreen.test.tsx` | Create | Page/hub suites |
| `__tests__/bookingLinkSettings.test.tsx` | Modify (Task 13) | Re-point at SettingsBookingScreen |

Shared test scaffolding (used by every screen suite — copy into each test file, matching `__tests__/bookingLinkSettings.test.tsx` conventions):

```tsx
const navigation = {
  setOptions: jest.fn(),
  addListener: jest.fn(() => jest.fn()),
  getParent: jest.fn(() => undefined),
  popToTop: jest.fn(),
  dispatch: jest.fn(),
  navigate: jest.fn(),
} as any;

// Presses the header Save that useSettingsDraft registers via
// navigation.setOptions({ headerRight }). Renders the latest headerRight
// element and fires its press.
import { render as rtlRender, fireEvent } from "@testing-library/react-native";
function pressHeaderSave(nav: any) {
  const calls = (nav.setOptions as jest.Mock).mock.calls;
  const headerRight = calls[calls.length - 1][0].headerRight;
  const { getByLabelText } = rtlRender(<>{headerRight()}</>);
  fireEvent.press(getByLabelText("Save settings"));
}
```

---

### Task 1: Validation split

**Files:**
- Modify: `utils/settingsValidation.ts`
- Test: `__tests__/settingsValidation.test.js`

**Interfaces:**
- Consumes: nothing new.
- Produces: `validateEmailPhone({ email: string; phone: string }): string[]` and `validateLaborRate(laborRate: number): string[]`; `validateSettingsInput` keeps its exact existing signature and messages.

- [ ] **Step 1: Write the failing tests** — append to `__tests__/settingsValidation.test.js` (match the file's existing import style; shown here as require):

```js
const { validateEmailPhone, validateLaborRate } = require("../utils/settingsValidation");

describe("validateEmailPhone", () => {
  it("passes empty fields (optional)", () => {
    expect(validateEmailPhone({ email: "", phone: "" })).toEqual([]);
  });
  it("flags a malformed non-empty email", () => {
    expect(validateEmailPhone({ email: "nope", phone: "" })).toEqual([
      "Email doesn't look like a valid address.",
    ]);
  });
  it("flags a short phone", () => {
    expect(validateEmailPhone({ email: "", phone: "(555) 123" })).toEqual([
      "Phone number looks incomplete — it needs 10 digits.",
    ]);
  });
});

describe("validateLaborRate", () => {
  it("flags zero and NaN", () => {
    expect(validateLaborRate(0)).toEqual(["Hourly labor rate must be greater than $0."]);
    expect(validateLaborRate(NaN)).toEqual(["Hourly labor rate must be greater than $0."]);
  });
  it("passes a positive rate", () => {
    expect(validateLaborRate(85)).toEqual([]);
  });
});
```

- [ ] **Step 2: Run to verify failure** — `npx jest __tests__/settingsValidation.test.js --silent` → FAIL (`validateEmailPhone is not a function`).

- [ ] **Step 3: Implement** — replace the body of `utils/settingsValidation.ts` from `validateSettingsInput` down (keep the header comment, interface, and `EMAIL_RE` untouched):

```ts
export interface ContactValidationInput {
  email: string;
  phone: string;
}

export function validateEmailPhone({ email, phone }: ContactValidationInput): string[] {
  const errors: string[] = [];
  if (email.trim() && !EMAIL_RE.test(email.trim())) {
    errors.push("Email doesn't look like a valid address.");
  }
  if (phone.trim() && phone.replace(/\D/g, "").length < 10) {
    errors.push("Phone number looks incomplete — it needs 10 digits.");
  }
  return errors;
}

export function validateLaborRate(laborRate: number): string[] {
  if (!Number.isFinite(laborRate) || laborRate <= 0) {
    return ["Hourly labor rate must be greater than $0."];
  }
  return [];
}

export function validateSettingsInput({ email, phone, laborRate }: SettingsValidationInput): string[] {
  return [...validateEmailPhone({ email, phone }), ...validateLaborRate(laborRate)];
}
```

- [ ] **Step 4: Run the suite** — `npx jest __tests__/settingsValidation.test.js --silent` → PASS, including every pre-existing case (contract preserved).

- [ ] **Step 5: Gate + commit**

```bash
npm run typecheck && npm test -- --silent && npm run lint
git add utils/settingsValidation.ts __tests__/settingsValidation.test.js
git commit -m "chore: split settings validation into composable page-scoped helpers"
```

---

### Task 2: useSettingsDraft hook

**Files:**
- Create: `hooks/useSettingsDraft.ts`
- Test: `__tests__/useSettingsDraft.test.tsx`

**Interfaces:**
- Consumes: `loadSettings`/`saveSettings` (`utils/storage`), `syncNotifications` (`utils/notifications`), `settingsEqual` (`utils/settingsDirty`), `useTheme` (`hooks/useTheme`), `TodayStackParamList`/`TodayStackScreenProps` (`types/navigation`).
- Produces (every draft page relies on these exact names):
  - `useSettingsTabPop<R>(navigation)` — blur → conditional `popToTop`.
  - `useSettingsDraft<R>(navigation, opts?: SettingsDraftOptions): { s, setS, update, dirty, saving, handleSave }` with `SettingsDraftOptions = { validate?, flush?, onSaved?, onDiscarded?, prepare? }` (semantics in the code below).

- [ ] **Step 1: Write the hook** — create `hooks/useSettingsDraft.ts`:

```tsx
// hooks/useSettingsDraft.ts
// The Settings subpage draft contract, extracted verbatim from the old
// monolithic SettingsScreen during the 2026-08-05 hub/subpages split
// (docs/superpowers/specs/2026-08-05-settings-subpages-design.md):
// full-Settings draft vs saved snapshot, sticky header Save, tab-switch
// pop, and THE beforeRemove unsaved-edits prompt — one prompt path for
// back, swipe-back, and the tab-switch pop alike.
import React, { useEffect, useLayoutEffect, useRef, useState } from "react";
import { Alert, Text, TouchableOpacity } from "react-native";
import { loadSettings, saveSettings } from "../utils/storage";
import { syncNotifications } from "../utils/notifications";
import { settingsEqual } from "../utils/settingsDirty";
import { fonts, fontSize } from "../utils/theme";
import { useTheme } from "./useTheme";
import type { Settings } from "../types/models";
import type { TodayStackParamList, TodayStackScreenProps } from "../types/navigation";

type SettingsNav<R extends keyof TodayStackParamList> = TodayStackScreenProps<R>["navigation"];

export interface SettingsDraftOptions {
  /**
   * Save-time hard block — header Save ONLY. The guard's Save path skips
   * validation exactly as the old screen did: blocking a navigation removal
   * on a validation alert has no clean resume path. Do not "fix" this.
   */
  validate?: (flushed: Settings) => string[];
  /**
   * Folds page-local editing drafts into the Settings object (e.g. the
   * Notifications page's in-progress rule text). Applied before every
   * dirty check and every save, so in-progress typing counts as a change
   * and is never silently dropped.
   */
  flush?: (s: Settings) => Settings;
  /**
   * Fires on BOTH save paths (header Save and guard-Save) with the
   * just-persisted settings. Pages hang checklist signals, logo-file
   * cleanup, and page-local draft resets here.
   */
  onSaved?: (saved: Settings) => void | Promise<void>;
  /** Fires when the guard's Discard is chosen, with the last saved snapshot. */
  onDiscarded?: (saved: Settings) => void | Promise<void>;
  /**
   * Async massage of the loaded settings before they become the draft —
   * side effects allowed (seeding refs, sweeping orphaned files). The page
   * renders null until this resolves.
   */
  prepare?: (loaded: Settings) => Promise<Settings> | Settings;
}

export interface SettingsDraft {
  s: Settings | null;
  setS: React.Dispatch<React.SetStateAction<Settings | null>>;
  update: (field: string, value: unknown) => void;
  dirty: boolean;
  saving: boolean;
  handleSave: () => Promise<void>;
}

/**
 * Tab-switch-away pops the settings stack back to TodayHome — used by the
 * hub and every subpage (owner smoke finding, 2026-07-31: returning to the
 * Today tab must not land back inside Settings). The parent-state check
 * keeps root-stack covers (PaywallModal via Subscribe) from popping the
 * screen out from under the modal: those blur without changing the tab.
 */
export function useSettingsTabPop<R extends keyof TodayStackParamList>(
  navigation: SettingsNav<R>
): void {
  useEffect(() => {
    const unsub = navigation.addListener("blur", () => {
      const tabState = navigation.getParent()?.getState();
      const activeTab = tabState ? tabState.routes[tabState.index]?.name : undefined;
      if (activeTab && activeTab !== "Today") {
        navigation.popToTop();
      }
    });
    return unsub;
  }, [navigation]);
}

export function useSettingsDraft<R extends keyof TodayStackParamList>(
  navigation: SettingsNav<R>,
  opts: SettingsDraftOptions = {}
): SettingsDraft {
  const { colors } = useTheme();
  const [s, setS] = useState<Settings | null>(null);
  const [savedSnapshot, setSavedSnapshot] = useState<Settings | null>(null);
  const [saving, setSaving] = useState(false);

  // The blur/beforeRemove listeners are registered once and would close
  // over stale values — they read these refs instead (the old screen's
  // sRef/savedSnapshotRef/ruleDraftsRef pattern; opts carries the page's
  // flush closure, so mirroring opts covers the rule-drafts case too).
  const sRef = useRef<Settings | null>(null);
  const savedSnapshotRef = useRef<Settings | null>(null);
  const optsRef = useRef(opts);
  optsRef.current = opts;
  // Set before each guard-resumed dispatch so re-entering beforeRemove
  // during the resumed removal stays quiet.
  const suppressDirtyWarnRef = useRef(false);

  useEffect(() => { sRef.current = s; }, [s]);
  useEffect(() => { savedSnapshotRef.current = savedSnapshot; }, [savedSnapshot]);

  useEffect(() => {
    loadSettings().then(async (loaded) => {
      const prepared = optsRef.current.prepare ? await optsRef.current.prepare(loaded) : loaded;
      setS(prepared);
      setSavedSnapshot(prepared);
    });
  }, []);

  const flushOf = (settings: Settings): Settings =>
    optsRef.current.flush ? optsRef.current.flush(settings) : settings;

  // Compared against the flushed settings so an in-progress page-local
  // draft still counts as a change; otherwise Save would stay disabled and
  // the guards below would silently let the typing be discarded.
  const dirty = !!s && !!savedSnapshot && !settingsEqual(flushOf(s), savedSnapshot);

  async function handleSave() {
    if (!s) return;
    const flushed = flushOf(s);
    // Hard-block malformed values — the old warn-but-save let bad emails,
    // partial phone numbers and a $0 labor rate reach invoices and estimates.
    const problems = optsRef.current.validate ? optsRef.current.validate(flushed) : [];
    if (problems.length > 0) {
      Alert.alert("Fix before saving", problems.join("\n\n"));
      return;
    }
    setSaving(true);
    await saveSettings(flushed);
    syncNotifications();
    setS(flushed);
    setSavedSnapshot(flushed);
    await optsRef.current.onSaved?.(flushed);
    setSaving(false);
    Alert.alert("Saved", "Your settings have been saved.");
  }

  // Sticky Save in the native header. Enabled exactly when the dirty-guard
  // would fire. Re-registered every render (no dep array) so it always sees
  // current dirty/saving/colors.
  useLayoutEffect(() => {
    navigation.setOptions({
      headerRight: () => (
        <TouchableOpacity
          onPress={handleSave}
          disabled={!dirty || saving}
          hitSlop={{ top: 8, bottom: 8, left: 8, right: 8 }}
          // Header buttons: paddingLeft/alignSelf are what center the text;
          // alignItems/justifyContent are no-ops in a native-stack header
          // slot. marginRight matches CustomerDetail's Edit.
          style={{ alignSelf: "center", marginRight: 8, paddingLeft: 10 }}
          accessibilityRole="button"
          accessibilityLabel="Save settings"
          accessibilityState={{ disabled: !dirty || saving, busy: saving }}
        >
          <Text
            style={{
              fontFamily: fonts.bodySemiBold,
              fontSize: fontSize.md,
              color: !dirty || saving ? colors.textMuted : colors.accent,
            }}
          >
            Save
          </Text>
        </TouchableOpacity>
      ),
    });
  });

  useSettingsTabPop(navigation);

  // THE unsaved-edits guard — the single prompt for every removal path:
  // back button, swipe-back, and the tab-switch pop dispatched by the blur
  // listener above. Intercept the removal, ask, then resume the same action.
  useEffect(() => {
    const unsub = navigation.addListener("beforeRemove", (e) => {
      const current = sRef.current;
      const saved = savedSnapshotRef.current;
      if (suppressDirtyWarnRef.current || !current || !saved) return;
      if (settingsEqual(
        optsRef.current.flush ? optsRef.current.flush(current) : current,
        saved
      )) return;
      e.preventDefault();
      Alert.alert(
        "Unsaved settings",
        "You changed settings but didn't tap Save. Keep your changes?",
        [
          {
            text: "Discard",
            style: "destructive",
            onPress: () => {
              // No setS: the screen is about to unmount; next mount reloads
              // from storage.
              suppressDirtyWarnRef.current = true;
              void optsRef.current.onDiscarded?.(saved);
              navigation.dispatch(e.data.action);
            },
          },
          {
            text: "Save",
            onPress: async () => {
              const cur = sRef.current;
              if (!cur) return;
              // Flush any in-progress page-local draft before saving —
              // saving sRef.current raw would silently drop it. NOTE: no
              // validate here — see SettingsDraftOptions.validate.
              const toSave = optsRef.current.flush ? optsRef.current.flush(cur) : cur;
              await saveSettings(toSave);
              syncNotifications();
              setSavedSnapshot(toSave);
              await optsRef.current.onSaved?.(toSave);
              suppressDirtyWarnRef.current = true;
              navigation.dispatch(e.data.action);
            },
          },
        ]
      );
    });
    return unsub;
  }, [navigation]);

  function update(field: string, value: unknown) {
    setS(prev => prev ? ({ ...prev, [field]: value } as Settings) : prev);
  }

  return { s, setS, update, dirty, saving, handleSave };
}
```

- [ ] **Step 2: Write the test suite** — create `__tests__/useSettingsDraft.test.tsx`:

```tsx
// __tests__/useSettingsDraft.test.tsx
// The extracted Settings draft contract: load→draft, flushed dirty check,
// header Save (validate, save, onSaved), the beforeRemove guard's three
// outcomes (clean pass-through, Discard, Save-without-validate), and the
// tab-switch blur pop.
import React from "react";
import { Alert, Text, TextInput, TouchableOpacity, View } from "react-native";
import { render, fireEvent, waitFor } from "@testing-library/react-native";
import { useSettingsDraft, type SettingsDraftOptions } from "../hooks/useSettingsDraft";
import { loadSettings, saveSettings } from "../utils/storage";
import { syncNotifications } from "../utils/notifications";
import { defaultSettings } from "../utils/storage/defaults";

jest.mock("../utils/storage", () => ({
  loadSettings: jest.fn(),
  saveSettings: jest.fn(() => Promise.resolve()),
}));
jest.mock("../utils/notifications", () => ({ syncNotifications: jest.fn() }));

function makeNavigation() {
  const listeners: Record<string, Array<(e?: any) => void>> = {};
  const nav = {
    setOptions: jest.fn(),
    addListener: jest.fn((type: string, cb: (e?: any) => void) => {
      (listeners[type] = listeners[type] ?? []).push(cb);
      return jest.fn();
    }),
    getParent: jest.fn(() => ({
      getState: () => ({ index: 0, routes: [{ name: "Today" }] }),
    })),
    popToTop: jest.fn(),
    dispatch: jest.fn(),
  } as any;
  return { nav, listeners };
}

function Harness({ navigation, options }: { navigation: any; options?: SettingsDraftOptions }) {
  const { s, update, dirty, handleSave } = useSettingsDraft(navigation, options);
  if (!s) return null;
  return (
    <View>
      <Text testID="dirty">{dirty ? "dirty" : "clean"}</Text>
      <TextInput
        accessibilityLabel="Business name"
        value={s.businessName}
        onChangeText={(v) => update("businessName", v)}
      />
      <TouchableOpacity accessibilityLabel="Save now" onPress={handleSave}>
        <Text>Save now</Text>
      </TouchableOpacity>
    </View>
  );
}

function removalEvent() {
  return { preventDefault: jest.fn(), data: { action: { type: "POP" } } };
}

describe("useSettingsDraft", () => {
  beforeEach(() => {
    jest.clearAllMocks();
    (loadSettings as jest.Mock).mockResolvedValue(defaultSettings());
    jest.spyOn(Alert, "alert").mockImplementation(() => {});
  });

  it("loads settings into a clean draft and registers a header Save", async () => {
    const { nav } = makeNavigation();
    const { findByTestId } = await render(<Harness navigation={nav} />);
    expect((await findByTestId("dirty")).props.children).toBe("clean");
    const lastOpts = (nav.setOptions as jest.Mock).mock.calls.at(-1)[0];
    expect(typeof lastOpts.headerRight).toBe("function");
  });

  it("prepare massages the loaded settings before they become the draft", async () => {
    const { nav } = makeNavigation();
    const options: SettingsDraftOptions = {
      prepare: (loaded) => ({ ...loaded, businessName: "Prepared Co" }),
    };
    const { findByLabelText } = await render(<Harness navigation={nav} options={options} />);
    expect((await findByLabelText("Business name")).props.value).toBe("Prepared Co");
  });

  it("an edit makes the draft dirty; a save makes it clean and persists", async () => {
    const { nav } = makeNavigation();
    const onSaved = jest.fn();
    const { findByLabelText, getByTestId, getByLabelText } = await render(
      <Harness navigation={nav} options={{ onSaved }} />
    );
    fireEvent.changeText(await findByLabelText("Business name"), "Acme Plumbing");
    expect(getByTestId("dirty").props.children).toBe("dirty");

    fireEvent.press(getByLabelText("Save now"));
    await waitFor(() => expect(saveSettings).toHaveBeenCalledTimes(1));
    expect(saveSettings).toHaveBeenCalledWith(
      expect.objectContaining({ businessName: "Acme Plumbing" })
    );
    expect(syncNotifications).toHaveBeenCalledTimes(1);
    expect(onSaved).toHaveBeenCalledWith(
      expect.objectContaining({ businessName: "Acme Plumbing" })
    );
    await waitFor(() => expect(getByTestId("dirty").props.children).toBe("clean"));
  });

  it("validate problems block the header save with an alert", async () => {
    const { nav } = makeNavigation();
    const options: SettingsDraftOptions = { validate: () => ["Bad value."] };
    const { findByLabelText, getByLabelText } = await render(
      <Harness navigation={nav} options={options} />
    );
    fireEvent.changeText(await findByLabelText("Business name"), "x");
    fireEvent.press(getByLabelText("Save now"));
    await waitFor(() =>
      expect(Alert.alert).toHaveBeenCalledWith("Fix before saving", "Bad value.")
    );
    expect(saveSettings).not.toHaveBeenCalled();
  });

  it("flush folds page-local drafts into dirty checks and saves", async () => {
    const { nav } = makeNavigation();
    const options: SettingsDraftOptions = {
      flush: (s) => ({ ...s, businessName: s.businessName + "!" }),
    };
    const { findByTestId, getByLabelText } = await render(
      <Harness navigation={nav} options={options} />
    );
    // flush alone makes the flushed draft differ from the snapshot.
    expect((await findByTestId("dirty")).props.children).toBe("dirty");
    fireEvent.press(getByLabelText("Save now"));
    await waitFor(() =>
      expect(saveSettings).toHaveBeenCalledWith(
        expect.objectContaining({ businessName: expect.stringMatching(/!$/) })
      )
    );
  });

  it("beforeRemove passes a clean draft through untouched", async () => {
    const { nav, listeners } = makeNavigation();
    await render(<Harness navigation={nav} />);
    const e = removalEvent();
    listeners["beforeRemove"][0](e);
    expect(e.preventDefault).not.toHaveBeenCalled();
  });

  it("beforeRemove on a dirty draft prompts; Discard fires onDiscarded and resumes", async () => {
    const { nav, listeners } = makeNavigation();
    const onDiscarded = jest.fn();
    const { findByLabelText } = await render(
      <Harness navigation={nav} options={{ onDiscarded }} />
    );
    fireEvent.changeText(await findByLabelText("Business name"), "Dirty Co");

    const e = removalEvent();
    listeners["beforeRemove"][0](e);
    expect(e.preventDefault).toHaveBeenCalled();

    const buttons = (Alert.alert as jest.Mock).mock.calls.at(-1)[2];
    const discard = buttons.find((b: any) => b.text === "Discard");
    discard.onPress();
    expect(onDiscarded).toHaveBeenCalledTimes(1);
    expect(nav.dispatch).toHaveBeenCalledWith(e.data.action);
    expect(saveSettings).not.toHaveBeenCalled();
  });

  it("guard-Save saves WITHOUT validate, fires onSaved, and resumes", async () => {
    const { nav, listeners } = makeNavigation();
    const validate = jest.fn(() => ["Would block."]);
    const onSaved = jest.fn();
    const { findByLabelText } = await render(
      <Harness navigation={nav} options={{ validate, onSaved }} />
    );
    fireEvent.changeText(await findByLabelText("Business name"), "Guarded Co");

    const e = removalEvent();
    listeners["beforeRemove"][0](e);
    const buttons = (Alert.alert as jest.Mock).mock.calls.at(-1)[2];
    const save = buttons.find((b: any) => b.text === "Save");
    await save.onPress();

    expect(validate).not.toHaveBeenCalled(); // the pinned asymmetry
    expect(saveSettings).toHaveBeenCalledWith(
      expect.objectContaining({ businessName: "Guarded Co" })
    );
    expect(onSaved).toHaveBeenCalledTimes(1);
    expect(nav.dispatch).toHaveBeenCalledWith(e.data.action);
  });

  it("blur pops to top only when the active tab is not Today", async () => {
    const { nav, listeners } = makeNavigation();
    await render(<Harness navigation={nav} />);

    listeners["blur"][0]();
    expect(nav.popToTop).not.toHaveBeenCalled(); // active tab is Today

    (nav.getParent as jest.Mock).mockReturnValue({
      getState: () => ({ index: 1, routes: [{ name: "Today" }, { name: "Jobs" }] }),
    });
    listeners["blur"][0]();
    expect(nav.popToTop).toHaveBeenCalledTimes(1);
  });
});
```

- [ ] **Step 3: Run to verify failure first** (before Step 1's file exists the suite fails on import; after writing both, run) — `npx jest __tests__/useSettingsDraft.test.tsx --silent` → PASS (all 9).

- [ ] **Step 4: Gate + commit**

```bash
npm run typecheck && npm test -- --silent && npm run lint
git add hooks/useSettingsDraft.ts __tests__/useSettingsDraft.test.tsx
git commit -m "feat: extract the Settings draft/guard machinery into useSettingsDraft"
```

---

### Task 3: Navigation types for the 11 subpage routes

**Files:**
- Modify: `types/navigation.ts:31-36`

**Interfaces:**
- Produces: route names every later task uses verbatim: `SettingsBusiness`, `SettingsPricing`, `SettingsInvoiceNumbering`, `SettingsAppearance`, `SettingsPayments`, `SettingsBooking`, `SettingsAI`, `SettingsNotifications`, `SettingsReviews`, `SettingsSubscription`, `SettingsAccount`.

- [ ] **Step 1: Edit the param list** — replace the `TodayStackParamList` block:

```ts
export type TodayStackParamList = {
  TodayHome: undefined;
  Route: undefined;
  Settings: undefined;
  SettingsBusiness: undefined;
  SettingsPricing: undefined;
  SettingsInvoiceNumbering: undefined;
  SettingsAppearance: undefined;
  SettingsPayments: undefined;
  SettingsBooking: undefined;
  SettingsAI: undefined;
  SettingsNotifications: undefined;
  SettingsReviews: undefined;
  SettingsSubscription: undefined;
  SettingsAccount: undefined;
  Search: undefined;
};
```

- [ ] **Step 2: Gate + commit**

```bash
npm run typecheck && npm test -- --silent && npm run lint
git add types/navigation.ts
git commit -m "chore: add the 11 settings subpage routes to TodayStackParamList"
```

---

### Task 4: SettingsField component

**Files:**
- Create: `components/SettingsField.tsx`

**Interfaces:**
- Consumes: `BaseField` (`components/Field.tsx`).
- Produces: `SettingsField` (named export) with props `{ label, value, onChangeText, keyboardType?, multiline?, placeholder?, autoCapitalize?, colors }`. Every form page imports it as `import { SettingsField as Field } from "../components/SettingsField";` so moved JSX compiles after stripping only ` shadow={shadow}`.

- [ ] **Step 1: Create the component** (the monolith's local `Field` wrapper, lines 1279–1301, minus the unused `shadow` prop; its two input styles come from monolith createStyles lines 1314–1320 with their comments):

```tsx
// components/SettingsField.tsx
// The Settings pages' form field — BaseField with the settings look
// (background-colored input on a surface card). Extracted from the old
// monolithic SettingsScreen's local Field during the 2026-08-05 split so
// the subpages don't each re-declare it.
import React, { useMemo } from "react";
import { StyleSheet } from "react-native";
import BaseField from "./Field";
import { spacing, radius, fontSize, fonts, type ColorScheme } from "../utils/theme";

interface SettingsFieldProps {
  label: string;
  value: string;
  onChangeText: (v: string) => void;
  keyboardType?: string;
  multiline?: boolean;
  placeholder?: string;
  autoCapitalize?: "none" | "sentences" | "words" | "characters";
  colors: ColorScheme;
}

export function SettingsField({ multiline, colors, ...props }: SettingsFieldProps) {
  const styles = useMemo(() => createStyles(colors), [colors]);
  return (
    <BaseField
      {...(props as any)}
      multiline={multiline}
      containerStyle={styles.fieldGroup}
      inputStyle={multiline ? [styles.input, styles.inputMultiline] : styles.input}
    />
  );
}

function createStyles(colors: ColorScheme) {
  return StyleSheet.create({
    fieldGroup: { marginBottom: spacing.sm },
    // minHeight (not height) so larger accessibility text grows the field
    // instead of clipping — components/Field.tsx pattern.
    input: { fontFamily: fonts.bodyRegular, backgroundColor: colors.background, borderRadius: radius.md, minHeight: 44, paddingHorizontal: spacing.md, fontSize: fontSize.md, color: colors.textPrimary, borderWidth: StyleSheet.hairlineWidth, borderColor: colors.border },
    // `minHeight: 88` is load-bearing — do NOT delete it as redundant. This
    // style is applied after `input` above (whose minHeight: 44 would
    // otherwise override BaseField's own 88pt `inputMulti` floor).
    inputMultiline: { minHeight: 88, paddingTop: spacing.sm, textAlignVertical: "top" },
  });
}
```

- [ ] **Step 2: Gate + commit** (exercised by every page suite from Task 6 on; no standalone suite)

```bash
npm run typecheck && npm test -- --silent && npm run lint
git add components/SettingsField.tsx
git commit -m "feat: add SettingsField, the shared settings-form field wrapper"
```

---

### Task 5: SettingsAppearanceScreen

**Files:**
- Create: `screens/SettingsAppearanceScreen.tsx`
- Modify: `App.tsx` (import + one `TodayStack.Screen` line after the `Settings` registration at App.tsx:124)
- Test: `__tests__/settingsAppearanceScreen.test.tsx`

**Interfaces:**
- Consumes: `useSettingsTabPop` (Task 2), `useTheme` (`preference`, `setTheme`).
- Produces: route `SettingsAppearance` registered with title "Appearance".

- [ ] **Step 1: Create the screen** (option grid copied from monolith lines 738–752; styles from createStyles lines 1305–1306, 1307, 1329–1334):

```tsx
// screens/SettingsAppearanceScreen.tsx
// Appearance is an IMMEDIATE-action page: setTheme persists on tap via
// ThemeContext (__themePreference), never through the Settings draft.
import React, { useMemo } from "react";
import { View, Text, ScrollView, StyleSheet, TouchableOpacity } from "react-native";
import { useSettingsTabPop } from "../hooks/useSettingsDraft";
import { useTheme } from "../hooks/useTheme";
import { spacing, radius, fontSize, fonts, layout, type ColorScheme, type ShadowScheme } from "../utils/theme";
import type { TodayStackScreenProps } from "../types/navigation";

export default function SettingsAppearanceScreen({ navigation }: TodayStackScreenProps<'SettingsAppearance'>) {
  const { colors, shadow, preference, setTheme } = useTheme();
  const styles = useMemo(() => createStyles(colors, shadow), [colors, shadow]);
  useSettingsTabPop(navigation);

  return (
    <View style={styles.container}>
      <ScrollView contentContainerStyle={styles.scroll} showsVerticalScrollIndicator={false}>
        <View style={styles.card}>
          <Text style={styles.providerHint}>Choose how TradeReady looks on your device.</Text>
          <View style={styles.providerGrid}>
            {([{ key: "light", label: "Light" }, { key: "system", label: "System" }, { key: "dark", label: "Dark" }] as const).map((opt) => (
              <TouchableOpacity
                key={opt.key}
                style={[styles.providerBtn, preference === opt.key && styles.providerBtnActive]}
                onPress={() => setTheme(opt.key)}
                accessibilityRole="radio"
                accessibilityLabel={`${opt.label} appearance`}
                accessibilityState={{ selected: preference === opt.key }}
              >
                <Text style={[styles.providerLabel, preference === opt.key && styles.providerLabelActive]}>{opt.label}</Text>
              </TouchableOpacity>
            ))}
          </View>
        </View>
      </ScrollView>
    </View>
  );
}

function createStyles(colors: ColorScheme, shadow: ShadowScheme) {
  return StyleSheet.create({
    container: { flex: 1, backgroundColor: colors.background },
    scroll: { padding: spacing.md, paddingBottom: 60, ...layout.contentColumn },
    card: { backgroundColor: colors.surface, borderRadius: radius.lg, padding: spacing.md, marginBottom: spacing.sm, ...shadow.card },
    providerGrid: { flexDirection: "row", flexWrap: "wrap", gap: 8, marginBottom: spacing.sm },
    providerBtn: { paddingHorizontal: 14, paddingVertical: 8, borderRadius: radius.full, borderWidth: 1, borderColor: colors.border, backgroundColor: colors.surface },
    providerBtnActive: { backgroundColor: colors.accentBg, borderColor: colors.accent },
    providerLabel: { fontFamily: fonts.bodyMedium, fontSize: fontSize.sm, color: colors.textSecondary },
    providerLabelActive: { fontFamily: fonts.bodySemiBold, color: colors.accent },
    providerHint: { fontFamily: fonts.bodyRegular, fontSize: fontSize.sm, color: colors.textSecondary, marginBottom: spacing.sm },
  });
}
```

- [ ] **Step 2: Register the route** — in `App.tsx`, add after line 124's `Settings` registration:

```tsx
<TodayStack.Screen name="SettingsAppearance" component={SettingsAppearanceScreen} options={{ title: "Appearance" }} />
```

with the import `import SettingsAppearanceScreen from "./screens/SettingsAppearanceScreen";` next to the existing `SettingsScreen` import. (Every screen task from here repeats this pattern with its own name/title; the plan won't restate the import sentence.)

- [ ] **Step 3: Write the test** — `__tests__/settingsAppearanceScreen.test.tsx`:

```tsx
import React from "react";
import { render, fireEvent } from "@testing-library/react-native";
import SettingsAppearanceScreen from "../screens/SettingsAppearanceScreen";

const setTheme = jest.fn();
jest.mock("../hooks/useTheme", () => {
  const theme = jest.requireActual("../utils/theme");
  return {
    useTheme: () => ({
      colors: theme.colors,
      shadow: { card: {} } as any,
      preference: "system",
      setTheme,
    }),
  };
});

const navigation = {
  setOptions: jest.fn(),
  addListener: jest.fn(() => jest.fn()),
  getParent: jest.fn(() => undefined),
  popToTop: jest.fn(),
  dispatch: jest.fn(),
  navigate: jest.fn(),
} as any;

describe("SettingsAppearanceScreen", () => {
  it("renders the three options with the preference selected", async () => {
    const { getByLabelText } = await render(
      <SettingsAppearanceScreen navigation={navigation} route={{} as any} />
    );
    expect(getByLabelText("Light appearance")).toBeTruthy();
    expect(getByLabelText("System appearance").props.accessibilityState.selected).toBe(true);
    expect(getByLabelText("Dark appearance").props.accessibilityState.selected).toBe(false);
  });

  it("tapping an option calls setTheme immediately", async () => {
    const { getByLabelText } = await render(
      <SettingsAppearanceScreen navigation={navigation} route={{} as any} />
    );
    fireEvent.press(getByLabelText("Dark appearance"));
    expect(setTheme).toHaveBeenCalledWith("dark");
  });
});
```

- [ ] **Step 4: Run** — `npx jest __tests__/settingsAppearanceScreen.test.tsx --silent` → PASS.

- [ ] **Step 5: Gate + commit**

```bash
npm run typecheck && npm test -- --silent && npm run lint
git add screens/SettingsAppearanceScreen.tsx App.tsx __tests__/settingsAppearanceScreen.test.tsx
git commit -m "feat: add the Appearance settings subpage"
```

---

### Task 6: SettingsPricingScreen

**Files:**
- Create: `screens/SettingsPricingScreen.tsx`
- Modify: `App.tsx` (register `SettingsPricing`, title "Pricing defaults")
- Test: `__tests__/settingsPricingScreen.test.tsx`

**Interfaces:**
- Consumes: `useSettingsDraft` (Task 2), `SettingsField` (Task 4), `validateLaborRate` (Task 1), `markSetupTaskDone` (`utils/setupChecklist`).
- Produces: route `SettingsPricing`; saving here is now THE completion signal for the checklist's "rate" task (spec: deliberate change from "any Settings save").

- [ ] **Step 1: Create the screen.** Shell below; the seven `<Field …/>` lines inside the card are copied verbatim from monolith lines 692–698 (plus the `keyNote` Text at 699–701), stripping ` shadow={shadow}` per Global Constraints:

```tsx
// screens/SettingsPricingScreen.tsx
import React, { useMemo } from "react";
import { View, Text, ScrollView, StyleSheet, KeyboardAvoidingView, Platform } from "react-native";
import { useSettingsDraft } from "../hooks/useSettingsDraft";
import { SettingsField as Field } from "../components/SettingsField";
import { validateLaborRate } from "../utils/settingsValidation";
import { markSetupTaskDone } from "../utils/setupChecklist";
import { useTheme } from "../hooks/useTheme";
import { spacing, radius, fontSize, fonts, layout, type ColorScheme, type ShadowScheme } from "../utils/theme";
import type { TodayStackScreenProps } from "../types/navigation";

export default function SettingsPricingScreen({ navigation }: TodayStackScreenProps<'SettingsPricing'>) {
  const { colors, shadow } = useTheme();
  const styles = useMemo(() => createStyles(colors, shadow), [colors, shadow]);
  const { s, update } = useSettingsDraft(navigation, {
    validate: (flushed) => validateLaborRate(flushed.laborRate),
    // Saving the Pricing page is the completion signal for the checklist's
    // "review your pricing defaults" task (moved from any-Settings-save at
    // the 2026-08-05 split — see the spec).
    onSaved: () => markSetupTaskDone("rate"),
  });
  if (!s) return null;

  return (
    <View style={styles.container}>
      <KeyboardAvoidingView behavior={Platform.OS === "ios" ? "padding" : undefined} style={{ flex: 1 }}>
        <ScrollView contentContainerStyle={styles.scroll} showsVerticalScrollIndicator={false} keyboardShouldPersistTaps="handled" keyboardDismissMode="on-drag">
          <Text style={styles.ruleSubtitle}>These pre-fill your estimate calculator. You can always override them per job.</Text>
          <View style={styles.card}>
            {/* monolith lines 692–701 go here, shadow prop stripped */}
          </View>
        </ScrollView>
      </KeyboardAvoidingView>
    </View>
  );
}

function createStyles(colors: ColorScheme, shadow: ShadowScheme) {
  return StyleSheet.create({
    container: { flex: 1, backgroundColor: colors.background },
    scroll: { padding: spacing.md, paddingBottom: 60, ...layout.contentColumn },
    card: { backgroundColor: colors.surface, borderRadius: radius.lg, padding: spacing.md, marginBottom: spacing.sm, ...shadow.card },
    ruleSubtitle: { fontFamily: fonts.bodyRegular, fontSize: fontSize.sm, color: colors.textSecondary, marginBottom: spacing.sm },
    keyNote: { fontFamily: fonts.bodyRegular, fontSize: fontSize.xs, color: colors.textMuted, marginTop: 6 },
  });
}
```

- [ ] **Step 2: Register the route** in `App.tsx` (name `SettingsPricing`, title "Pricing defaults").

- [ ] **Step 3: Write the test** — `__tests__/settingsPricingScreen.test.tsx` (uses the shared scaffolding from File Structure):

```tsx
import React from "react";
import { Alert } from "react-native";
import { render, fireEvent, waitFor, render as rtlRender } from "@testing-library/react-native";
import SettingsPricingScreen from "../screens/SettingsPricingScreen";
import { loadSettings, saveSettings } from "../utils/storage";
import { defaultSettings } from "../utils/storage/defaults";
import { markSetupTaskDone } from "../utils/setupChecklist";

jest.mock("../utils/storage", () => ({
  loadSettings: jest.fn(),
  saveSettings: jest.fn(() => Promise.resolve()),
}));
jest.mock("../utils/notifications", () => ({ syncNotifications: jest.fn() }));
jest.mock("../utils/setupChecklist", () => ({ markSetupTaskDone: jest.fn() }));

const navigation = {
  setOptions: jest.fn(),
  addListener: jest.fn(() => jest.fn()),
  getParent: jest.fn(() => undefined),
  popToTop: jest.fn(),
  dispatch: jest.fn(),
} as any;

function pressHeaderSave(nav: any) {
  const calls = (nav.setOptions as jest.Mock).mock.calls;
  const headerRight = calls[calls.length - 1][0].headerRight;
  const { getByLabelText } = rtlRender(<>{headerRight()}</>);
  fireEvent.press(getByLabelText("Save settings"));
}

describe("SettingsPricingScreen", () => {
  beforeEach(() => {
    jest.clearAllMocks();
    (loadSettings as jest.Mock).mockResolvedValue({ ...defaultSettings(), laborRate: 85 });
    jest.spyOn(Alert, "alert").mockImplementation(() => {});
  });

  it("renders pricing fields from settings", async () => {
    const { findByLabelText } = await render(
      <SettingsPricingScreen navigation={navigation} route={{} as any} />
    );
    expect((await findByLabelText("Your hourly labor rate ($)")).props.value).toBe("85");
  });

  it("a $0 labor rate blocks the save", async () => {
    const { findByLabelText } = await render(
      <SettingsPricingScreen navigation={navigation} route={{} as any} />
    );
    fireEvent.changeText(await findByLabelText("Your hourly labor rate ($)"), "0");
    pressHeaderSave(navigation);
    await waitFor(() =>
      expect(Alert.alert).toHaveBeenCalledWith("Fix before saving", "Hourly labor rate must be greater than $0.")
    );
    expect(saveSettings).not.toHaveBeenCalled();
  });

  it("a valid save persists and marks the rate task done", async () => {
    const { findByLabelText } = await render(
      <SettingsPricingScreen navigation={navigation} route={{} as any} />
    );
    fireEvent.changeText(await findByLabelText("Material markup (%)"), "35");
    pressHeaderSave(navigation);
    await waitFor(() => expect(saveSettings).toHaveBeenCalledTimes(1));
    expect(saveSettings).toHaveBeenCalledWith(expect.objectContaining({ materialMarkup: 35 }));
    expect(markSetupTaskDone).toHaveBeenCalledWith("rate");
  });
});
```

- [ ] **Step 4: Run** — `npx jest __tests__/settingsPricingScreen.test.tsx --silent` → PASS.

- [ ] **Step 5: Gate + commit**

```bash
npm run typecheck && npm test -- --silent && npm run lint
git add screens/SettingsPricingScreen.tsx App.tsx __tests__/settingsPricingScreen.test.tsx
git commit -m "feat: add the Pricing defaults settings subpage"
```

---

### Task 7: SettingsInvoiceNumberingScreen

**Files:**
- Create: `screens/SettingsInvoiceNumberingScreen.tsx`
- Modify: `App.tsx` (register `SettingsInvoiceNumbering`, title "Invoice numbering")

**Interfaces:**
- Consumes: `useSettingsDraft`, `SettingsField as Field`, `normalizeInvoicePrefix` (`utils/invoiceNumber`).
- Produces: route `SettingsInvoiceNumbering`.

- [ ] **Step 1: Create the screen.** Same shell as Task 6 (container/KAV/ScrollView/createStyles with `container`, `scroll`, `card`, `keyNote` styles), route type `TodayStackScreenProps<'SettingsInvoiceNumbering'>`, hook call with NO options (`useSettingsDraft(navigation)`), and the card body copied verbatim from monolith lines 708–731 (the two `Field`s and the preview `keyNote` Text), stripping ` shadow={shadow}`. Import `normalizeInvoicePrefix`.

- [ ] **Step 2: Register the route** in `App.tsx`.

- [ ] **Step 3: Verify by suite** — the hook suite plus typecheck cover this page's behavior (it has no page-specific logic beyond the moved JSX); run the two neighbors as a smoke: `npx jest __tests__/useSettingsDraft.test.tsx __tests__/settingsPricingScreen.test.tsx --silent` → PASS.

- [ ] **Step 4: Gate + commit**

```bash
npm run typecheck && npm test -- --silent && npm run lint
git add screens/SettingsInvoiceNumberingScreen.tsx App.tsx
git commit -m "feat: add the Invoice numbering settings subpage"
```

---

### Task 8: SettingsAIScreen

**Files:**
- Create: `screens/SettingsAIScreen.tsx`
- Modify: `App.tsx` (register `SettingsAI`, title "AI Assistant")

**Interfaces:**
- Consumes: `useSettingsDraft`.
- Produces: route `SettingsAI`.

- [ ] **Step 1: Create the screen.** Task 6's shell (route type `'SettingsAI'`, hook with no options) plus:
  - Local state `const [showAdvanced, setShowAdvanced] = useState(false);` (monolith line 140).
  - Body copied verbatim from monolith lines 876–903: the intro card with the Advanced `Switch`, and the two conditional key cards (`s.groqKey` / `s.anthropicKey` raw `TextInput`s with `secureTextEntry`). These are raw TextInputs, NOT `Field` — nothing to strip.
  - createStyles keys: `container`, `scroll`, `card`, `providerHint`, `toggleRow`, `toggleLabel`, `keyNote` (monolith lines 1334–1335, 1343–1344), and `input` copied verbatim from monolith line 1314 (the raw TextInputs style it directly).
  - Imports: `Switch`, `TextInput` from react-native.

- [ ] **Step 2: Register the route** in `App.tsx`.

- [ ] **Step 3: Run smoke** — `npx jest __tests__/useSettingsDraft.test.tsx --silent` → PASS (keys ride the generic draft path; the SECURE_FIELDS strip lives inside `saveSettings`, untouched).

- [ ] **Step 4: Gate + commit**

```bash
npm run typecheck && npm test -- --silent && npm run lint
git add screens/SettingsAIScreen.tsx App.tsx
git commit -m "feat: add the AI Assistant settings subpage"
```

---

### Task 9: SettingsReviewsScreen

**Files:**
- Create: `screens/SettingsReviewsScreen.tsx`
- Modify: `App.tsx` (register `SettingsReviews`, title "Review requests")

**Interfaces:**
- Consumes: `useSettingsDraft`, `SettingsField as Field`.
- Produces: route `SettingsReviews`.

- [ ] **Step 1: Create the screen.** Task 6's shell (route type `'SettingsReviews'`, hook with no options), body copied verbatim from monolith lines 1030–1084: the intro `ruleSubtitle` Text, the enable-toggle card, and the three conditional cards (Google review link `Field`, delay `Field`, template `Field`) — strip ` shadow={shadow}` from the three `Field`s. createStyles keys: `container`, `scroll`, `card`, `ruleSubtitle`, `toggleRow`, `toggleLabel`, `keyNote`. Imports: `Switch`.

- [ ] **Step 2: Register the route** in `App.tsx`.

- [ ] **Step 3: Run smoke** — `npx jest __tests__/useSettingsDraft.test.tsx --silent` → PASS.

- [ ] **Step 4: Gate + commit**

```bash
npm run typecheck && npm test -- --silent && npm run lint
git add screens/SettingsReviewsScreen.tsx App.tsx
git commit -m "feat: add the Review requests settings subpage"
```

---

### Task 10: SettingsBusinessScreen (logo lifecycle moves here)

**Files:**
- Create: `screens/SettingsBusinessScreen.tsx`
- Modify: `App.tsx` (register `SettingsBusiness`, title "Business profile")
- Test: `__tests__/settingsBusinessScreen.test.tsx`

**Interfaces:**
- Consumes: `useSettingsDraft` (`validate`/`onSaved`/`onDiscarded`/`prepare`), `SettingsField as Field`, `validateEmailPhone` (Task 1), `TRADE_TYPES` (`utils/pricingEngine`), `promptForLogo` (`utils/logoPicker`), `deletePhoto`/`photoExists`/`listPhotos` (`utils/photoStorage`), `orphanedLogoPaths`/`sweepableLogoPaths` (`utils/logoLifecycle`), `useAuth` (`bootstrapping`).
- Produces: route `SettingsBusiness`.

- [ ] **Step 1: Create the screen.** This page inherits ALL the logo-lifecycle machinery — move each block **with its comments intact**:
  - Module level: `formatPhone` (monolith lines 81–86) and `sweepOrphanedLogos` + its comment block (lines 110–129).
  - In the component: the bootstrapping ref machinery with its comment (lines 146–154); `touchedLogoPathsRef` + `cleanupLogoFiles` with comments (lines 216–229); `handlePickLogo`/`handleRemoveLogo` with the draft-contract comment (lines 496–509).
  - Hook wiring:

```tsx
const { bootstrapping } = useAuth();
const bootstrappingRef = useRef(bootstrapping);
useEffect(() => { if (bootstrapping) bootstrappingRef.current = true; }, [bootstrapping]);

const { s, update } = useSettingsDraft(navigation, {
  validate: (flushed) => validateEmailPhone({ email: flushed.email, phone: flushed.phone }),
  // Both save paths and the guard's Discard reclaim logo files the
  // committed settings no longer reference — the old screen's
  // cleanupLogoFiles contract, unchanged.
  onSaved: (saved) => cleanupLogoFiles(saved.logoPhoto),
  onDiscarded: (saved) => cleanupLogoFiles(saved.logoPhoto),
  // The old load effect's logo half (monolith lines 317–341), verbatim
  // including the raw-path-before-sanitization comment. The provider-key
  // half (lines 307–316) belongs to SettingsPaymentsScreen.
  prepare: async (loaded) => {
    const persistedLogoPath = loaded.logoPhoto;
    let next = loaded;
    if (next.logoPhoto && !(await photoExists(next.logoPhoto))) {
      next = { ...next, logoPhoto: "" };
    }
    if (!bootstrappingRef.current) {
      await sweepOrphanedLogos(persistedLogoPath);
    }
    touchedLogoPathsRef.current = next.logoPhoto ? [next.logoPhoto] : [];
    return next;
  },
});
```

  - Body: monolith lines 634–685 verbatim (fields card, trade grid, logo picker/remove), stripping ` shadow={shadow}` from the six `Field`s.
  - createStyles keys: `container`, `scroll`, `card`, `fieldLabel`, `tradeGrid`, `tradeBtn`, `tradeBtnActive`, `tradeLabel`, `tradeLabelActive`, `logoHint`, `logoPicker`, `logoImage`, `logoPlaceholder`, `logoPlaceholderIcon`, `logoPlaceholderText`, `logoRemoveBtn`, `logoRemoveText` (monolith lines 1305–1309, 1321–1328, 1363–1367).
  - Imports: `Image` from expo-image, `Ionicons`, plus everything in Consumes.

- [ ] **Step 2: Register the route** in `App.tsx`.

- [ ] **Step 3: Write the test** — `__tests__/settingsBusinessScreen.test.tsx` (shared navigation scaffolding + `pressHeaderSave` helper from File Structure):

```tsx
import React from "react";
import { Alert } from "react-native";
import { render, fireEvent, waitFor, render as rtlRender } from "@testing-library/react-native";
import SettingsBusinessScreen from "../screens/SettingsBusinessScreen";
import { loadSettings, saveSettings } from "../utils/storage";
import { defaultSettings } from "../utils/storage/defaults";
import { listPhotos, photoExists } from "../utils/photoStorage";

jest.mock("../utils/storage", () => ({
  loadSettings: jest.fn(),
  saveSettings: jest.fn(() => Promise.resolve()),
}));
jest.mock("../utils/notifications", () => ({ syncNotifications: jest.fn() }));
jest.mock("../utils/photoStorage", () => ({
  deletePhoto: jest.fn(() => Promise.resolve()),
  photoExists: jest.fn(() => Promise.resolve(true)),
  listPhotos: jest.fn(() => Promise.resolve([])),
}));
jest.mock("../utils/logoPicker", () => ({ promptForLogo: jest.fn() }));
jest.mock("../context/AuthContext", () => ({
  useAuth: () => ({ session: null, initializing: false, bootstrapping: false }),
}));

const navigation = {
  setOptions: jest.fn(),
  addListener: jest.fn(() => jest.fn()),
  getParent: jest.fn(() => undefined),
  popToTop: jest.fn(),
  dispatch: jest.fn(),
} as any;

function pressHeaderSave(nav: any) {
  const calls = (nav.setOptions as jest.Mock).mock.calls;
  const headerRight = calls[calls.length - 1][0].headerRight;
  const { getByLabelText } = rtlRender(<>{headerRight()}</>);
  fireEvent.press(getByLabelText("Save settings"));
}

describe("SettingsBusinessScreen", () => {
  beforeEach(() => {
    jest.clearAllMocks();
    (loadSettings as jest.Mock).mockResolvedValue(defaultSettings());
    jest.spyOn(Alert, "alert").mockImplementation(() => {});
  });

  it("renders the business fields and sweeps the logo folder on open", async () => {
    const { findByLabelText } = await render(
      <SettingsBusinessScreen navigation={navigation} route={{} as any} />
    );
    expect(await findByLabelText("Business name")).toBeTruthy();
    await waitFor(() => expect(listPhotos).toHaveBeenCalledWith("logos"));
  });

  it("a dangling logo path is treated as unset", async () => {
    (loadSettings as jest.Mock).mockResolvedValue({ ...defaultSettings(), logoPhoto: "logos/gone.jpg" });
    (photoExists as jest.Mock).mockResolvedValue(false);
    const { findByLabelText } = await render(
      <SettingsBusinessScreen navigation={navigation} route={{} as any} />
    );
    expect(await findByLabelText("Add your business logo")).toBeTruthy();
  });

  it("a malformed email blocks the save", async () => {
    const { findByLabelText } = await render(
      <SettingsBusinessScreen navigation={navigation} route={{} as any} />
    );
    fireEvent.changeText(await findByLabelText("Email"), "not-an-email");
    pressHeaderSave(navigation);
    await waitFor(() =>
      expect(Alert.alert).toHaveBeenCalledWith("Fix before saving", "Email doesn't look like a valid address.")
    );
    expect(saveSettings).not.toHaveBeenCalled();
  });

  it("phone input formats as (xxx) xxx-xxxx and saves", async () => {
    const { findByLabelText } = await render(
      <SettingsBusinessScreen navigation={navigation} route={{} as any} />
    );
    const phone = await findByLabelText("Phone");
    fireEvent.changeText(phone, "5551234567");
    pressHeaderSave(navigation);
    await waitFor(() =>
      expect(saveSettings).toHaveBeenCalledWith(
        expect.objectContaining({ phone: "(555) 123-4567" })
      )
    );
  });
});
```

- [ ] **Step 4: Run** — `npx jest __tests__/settingsBusinessScreen.test.tsx --silent` → PASS.

- [ ] **Step 5: Gate + commit**

```bash
npm run typecheck && npm test -- --silent && npm run lint
git add screens/SettingsBusinessScreen.tsx App.tsx __tests__/settingsBusinessScreen.test.tsx
git commit -m "feat: add the Business profile settings subpage with the logo lifecycle"
```

---

### Task 11: SettingsNotificationsScreen (rule drafts move here)

**Files:**
- Create: `screens/SettingsNotificationsScreen.tsx`
- Modify: `App.tsx` (register `SettingsNotifications`, title "Notifications")
- Test: `__tests__/settingsNotificationsScreen.test.tsx`

**Interfaces:**
- Consumes: `useSettingsDraft` (`flush`/`onSaved`), `SettingsField as Field`, `KeyboardDoneBar`, `DEFAULT_CONFIRM_TEMPLATE`/`DEFAULT_ON_MY_WAY_TEMPLATE` (`utils/appointmentTemplates`).
- Produces: route `SettingsNotifications`.

- [ ] **Step 1: Create the screen.**
  - Module level: `applyRuleDrafts` with its full comment block, copied verbatim from monolith lines 88–108.
  - Component: `const [ruleDrafts, setRuleDrafts] = useState<Record<number, string>>({});` (lines 141–143 with comment); the four rule handlers verbatim from lines 511–546 (`updateRule`, `commitRule`, `addRule`, `removeRule` — they call the hook's `setS`).
  - Hook wiring:

```tsx
const { s, setS, update } = useSettingsDraft(navigation, {
  // Folds any notification-rule box still being edited into rules, so
  // saving while a field is focused persists what's typed (see
  // applyRuleDrafts). The hook reads this through a ref, so the closure
  // over ruleDrafts is always current.
  flush: (settings) => applyRuleDrafts(settings, ruleDrafts),
  // The flushed rules are already committed into the saved draft; the raw
  // text drafts are stale now.
  onSaved: () => setRuleDrafts({}),
});
```

  - Body: monolith lines 908–1025 verbatim (rules subtitle + rows + add button, the five toggle cards — `autoOutreachEnabled`, `autoSendEmailEnabled`, `appointmentRemindersEnabled`, `estimateFollowUpsEnabled`, `autoInvoiceOnComplete` — and the two template cards), stripping ` shadow={shadow}` from the two template `Field`s. Note the estimate toggle keeps `value={s.estimateFollowUpsEnabled !== false}` — ABSENT MEANS ON, do not normalize.
  - After the ScrollView/KAV close, `<KeyboardDoneBar nativeID="settingsDone" />` with its comment (lines 1221–1222).
  - createStyles keys: `container`, `scroll`, `card`, `ruleSubtitle`, `ruleRow`, `ruleInput`, `ruleSuffix`, `removeBtn`, `addRuleBtn`, `addRuleBtnText`, `toggleRow`, `toggleLabel`, `keyNote` (monolith lines 1336–1344).
  - Imports: `TextInput`, `Switch`, `TouchableOpacity`, `Ionicons`.

- [ ] **Step 2: Register the route** in `App.tsx`.

- [ ] **Step 3: Write the test** — `__tests__/settingsNotificationsScreen.test.tsx` (shared scaffolding + `pressHeaderSave`):

```tsx
import React from "react";
import { Alert } from "react-native";
import { render, fireEvent, waitFor, render as rtlRender } from "@testing-library/react-native";
import SettingsNotificationsScreen from "../screens/SettingsNotificationsScreen";
import { loadSettings, saveSettings } from "../utils/storage";
import { defaultSettings } from "../utils/storage/defaults";

jest.mock("../utils/storage", () => ({
  loadSettings: jest.fn(),
  saveSettings: jest.fn(() => Promise.resolve()),
}));
jest.mock("../utils/notifications", () => ({ syncNotifications: jest.fn() }));

const navigation = {
  setOptions: jest.fn(),
  addListener: jest.fn(() => jest.fn()),
  getParent: jest.fn(() => undefined),
  popToTop: jest.fn(),
  dispatch: jest.fn(),
} as any;

function pressHeaderSave(nav: any) {
  const calls = (nav.setOptions as jest.Mock).mock.calls;
  const headerRight = calls[calls.length - 1][0].headerRight;
  const { getByLabelText } = rtlRender(<>{headerRight()}</>);
  fireEvent.press(getByLabelText("Save settings"));
}

describe("SettingsNotificationsScreen", () => {
  beforeEach(() => {
    jest.clearAllMocks();
    (loadSettings as jest.Mock).mockResolvedValue({ ...defaultSettings(), rules: [{ days: 7 }] });
    jest.spyOn(Alert, "alert").mockImplementation(() => {});
  });

  it("renders the reminder rule and the automation toggles", async () => {
    const { findByLabelText } = await render(
      <SettingsNotificationsScreen navigation={navigation} route={{} as any} />
    );
    expect((await findByLabelText("Reminder rule 1: days past due")).props.value).toBe("7");
    expect(await findByLabelText("Appointment reminders")).toBeTruthy();
    expect(await findByLabelText("Estimate follow-up reminders")).toBeTruthy();
  });

  it("an IN-PROGRESS rule edit (no blur) is folded into the save", async () => {
    const { findByLabelText } = await render(
      <SettingsNotificationsScreen navigation={navigation} route={{} as any} />
    );
    // Type without blurring — the raw text lives only in ruleDrafts.
    fireEvent.changeText(await findByLabelText("Reminder rule 1: days past due"), "14");
    pressHeaderSave(navigation);
    await waitFor(() =>
      expect(saveSettings).toHaveBeenCalledWith(
        expect.objectContaining({ rules: [{ days: 14 }] })
      )
    );
  });

  it("a toggle flip rides the draft and saves", async () => {
    const { findByLabelText } = await render(
      <SettingsNotificationsScreen navigation={navigation} route={{} as any} />
    );
    const toggle = await findByLabelText("Appointment reminders");
    await fireEvent(toggle, "valueChange", true);
    pressHeaderSave(navigation);
    await waitFor(() =>
      expect(saveSettings).toHaveBeenCalledWith(
        expect.objectContaining({ appointmentRemindersEnabled: true })
      )
    );
  });
});
```

- [ ] **Step 4: Run** — `npx jest __tests__/settingsNotificationsScreen.test.tsx --silent` → PASS.

- [ ] **Step 5: Gate + commit**

```bash
npm run typecheck && npm test -- --silent && npm run lint
git add screens/SettingsNotificationsScreen.tsx App.tsx __tests__/settingsNotificationsScreen.test.tsx
git commit -m "feat: add the Notifications settings subpage with the rule-draft machinery"
```

---

### Task 12: stripeStatus util + SettingsPaymentsScreen

**Files:**
- Create: `utils/stripeStatus.ts`
- Create: `screens/SettingsPaymentsScreen.tsx`
- Modify: `App.tsx` (register `SettingsPayments`, title "Payments")
- Test: `__tests__/settingsPaymentsScreen.test.tsx`

**Interfaces:**
- Consumes: `useSettingsDraft` (`prepare`), monolith Stripe machinery.
- Produces: `fetchStripeConnectStatus(): Promise<StripeStatus>` and `interface StripeStatus { connected: boolean; details_submitted?: boolean; display_name?: string; _error?: string }` from `utils/stripeStatus.ts` — the hub (Task 16) imports BOTH. The util owns the `markSetupTaskDone("stripe")` side effect. Route `SettingsPayments`.

- [ ] **Step 1: Create `utils/stripeStatus.ts`** (the monolith's `fetchStripeStatus` body, lines 355–374, minus the setState — callers own state):

```ts
// utils/stripeStatus.ts
// Stripe Connect status for the signed-in user — shared by the Settings
// hub (Payments row subtitle) and SettingsPaymentsScreen. Never throws.
// Owns the setup checklist's "stripe" completion signal, exactly where the
// old SettingsScreen fetch fired it.
import Constants from "expo-constants";
import { supabase } from "./supabase";
import { markSetupTaskDone } from "./setupChecklist";

const VERCEL_URL = Constants.expoConfig?.extra?.backendUrl ?? "";

export interface StripeStatus {
  connected: boolean;
  details_submitted?: boolean;
  display_name?: string;
  _error?: string;
}

export async function fetchStripeConnectStatus(): Promise<StripeStatus> {
  if (!VERCEL_URL) return { connected: false };
  try {
    const { data: { session } } = await supabase.auth.getSession();
    if (!session?.access_token) return { connected: false };
    const res = await fetch(`${VERCEL_URL}/api/stripe/connect-status`, {
      headers: { Authorization: `Bearer ${session.access_token}` },
    });
    const data = await res.json();
    if (res.ok) {
      if (data?.connected) markSetupTaskDone("stripe");
      return data;
    }
    return { connected: false, _error: data?.error };
  } catch {
    return { connected: false };
  }
}
```

- [ ] **Step 2: Create the screen.** Task 6's shell (route type `'SettingsPayments'`) plus:
  - Module level: `PROVIDERS` + `Provider` interface verbatim from monolith lines 67–79; the `VERCEL_URL` constant (line 54); import `StripeStatus`/`fetchStripeConnectStatus` from `../utils/stripeStatus`.
  - Component state: `stripeStatus`/`stripeConnecting`/`stripeDisconnecting`/`appStateRef` (lines 156–159).
  - Hook wiring:

```tsx
const { s, setS, update } = useSettingsDraft(navigation, {
  // The old load effect's provider half (monolith lines 307–316): a legacy
  // non-Stripe providerKey is backfilled into providerKeys before it
  // becomes the draft.
  prepare: (loaded) => {
    if (loaded.provider !== "stripe" && loaded.providerKey && !loaded.providerKeys?.[loaded.provider]) {
      return { ...loaded, providerKeys: { ...loaded.providerKeys, [loaded.provider]: loaded.providerKey } };
    }
    return loaded;
  },
});
```

  - `updateProviderKey` verbatim from lines 548–558 (uses `update`/`setS`); `handleStripeConnect`/`handleStripeDisconnect` verbatim from lines 376–422; the AppState refetch effect from lines 344–353 with the fetch replaced by:

```tsx
async function refreshStripeStatus() {
  setStripeStatus(await fetchStripeConnectStatus());
}
```

  called on mount and on foreground return (the effect's shape is unchanged).
  - `const selectedProvider = PROVIDERS.find((p) => p.id === s.provider);` (line 616) after the null gate.
  - Body: monolith lines 758–827 verbatim (provider grid, Stripe card variants, non-Stripe key card).
  - createStyles keys: `container`, `scroll`, `card`, `providerGrid`, `providerBtn`, `providerBtnActive`, `providerLabel`, `providerLabelActive`, `providerHint`, `input`, `keyNote`, `stripeConnectedRow`, `stripeConnectedDot`, `stripeConnectedLabel`, `stripeOnboardingHint`, `stripeButtonRow`, `stripeBtn`, `stripeBtnText`, `stripeBtnDanger`, `stripeBtnDangerText`, `stripeConnectBtn`, `stripeConnectBtnText` (monolith lines 1305–1307, 1314, 1329–1335, 1376–1386).
  - Imports: `TextInput`, `TouchableOpacity`, `ActivityIndicator`, `AppState` + `AppStateStatus`, `Alert`, `Linking`, `supabase`, `reportError` (`utils/analytics`).

- [ ] **Step 3: Register the route** in `App.tsx`.

- [ ] **Step 4: Write the test** — `__tests__/settingsPaymentsScreen.test.tsx` (shared scaffolding + `pressHeaderSave`):

```tsx
import React from "react";
import { render, fireEvent, waitFor, render as rtlRender } from "@testing-library/react-native";
import SettingsPaymentsScreen from "../screens/SettingsPaymentsScreen";
import { loadSettings, saveSettings } from "../utils/storage";
import { defaultSettings } from "../utils/storage/defaults";
import { fetchStripeConnectStatus } from "../utils/stripeStatus";

jest.mock("../utils/storage", () => ({
  loadSettings: jest.fn(),
  saveSettings: jest.fn(() => Promise.resolve()),
}));
jest.mock("../utils/notifications", () => ({ syncNotifications: jest.fn() }));
jest.mock("../utils/stripeStatus", () => ({
  fetchStripeConnectStatus: jest.fn(() => Promise.resolve({ connected: false })),
}));

const navigation = {
  setOptions: jest.fn(),
  addListener: jest.fn(() => jest.fn()),
  getParent: jest.fn(() => undefined),
  popToTop: jest.fn(),
  dispatch: jest.fn(),
} as any;

function pressHeaderSave(nav: any) {
  const calls = (nav.setOptions as jest.Mock).mock.calls;
  const headerRight = calls[calls.length - 1][0].headerRight;
  const { getByLabelText } = rtlRender(<>{headerRight()}</>);
  fireEvent.press(getByLabelText("Save settings"));
}

describe("SettingsPaymentsScreen", () => {
  beforeEach(() => {
    jest.clearAllMocks();
    (loadSettings as jest.Mock).mockResolvedValue(defaultSettings());
  });

  it("fetches Stripe status on mount and shows the connect button when disconnected", async () => {
    const { findByLabelText } = await render(
      <SettingsPaymentsScreen navigation={navigation} route={{} as any} />
    );
    expect(await findByLabelText("Connect Stripe account")).toBeTruthy();
    expect(fetchStripeConnectStatus).toHaveBeenCalledTimes(1);
  });

  it("selecting a non-Stripe provider shows its key input; saving persists it under providerKeys", async () => {
    const { findByLabelText } = await render(
      <SettingsPaymentsScreen navigation={navigation} route={{} as any} />
    );
    fireEvent.press(await findByLabelText("Venmo"));
    const keyInput = await findByLabelText("Venmo link or username");
    fireEvent.changeText(keyInput, "my-venmo");
    pressHeaderSave(navigation);
    await waitFor(() =>
      expect(saveSettings).toHaveBeenCalledWith(
        expect.objectContaining({
          provider: "venmo",
          providerKeys: expect.objectContaining({ venmo: "my-venmo" }),
        })
      )
    );
  });

  it("a legacy providerKey is backfilled into providerKeys on load", async () => {
    (loadSettings as jest.Mock).mockResolvedValue({
      ...defaultSettings(),
      provider: "venmo",
      providerKey: "legacy-handle",
      providerKeys: undefined,
    });
    const { findByLabelText } = await render(
      <SettingsPaymentsScreen navigation={navigation} route={{} as any} />
    );
    expect((await findByLabelText("Venmo link or username")).props.value).toBe("legacy-handle");
  });
});
```

- [ ] **Step 5: Run** — `npx jest __tests__/settingsPaymentsScreen.test.tsx --silent` → PASS.

- [ ] **Step 6: Gate + commit**

```bash
npm run typecheck && npm test -- --silent && npm run lint
git add utils/stripeStatus.ts screens/SettingsPaymentsScreen.tsx App.tsx __tests__/settingsPaymentsScreen.test.tsx
git commit -m "feat: add the Payments settings subpage and shared Stripe status fetch"
```

---

### Task 13: SettingsBookingScreen + test re-point

**Files:**
- Create: `screens/SettingsBookingScreen.tsx`
- Modify: `App.tsx` (register `SettingsBooking`, title "Booking link")
- Modify: `__tests__/bookingLinkSettings.test.tsx`

**Interfaces:**
- Consumes: `useSettingsTabPop`, `mintBookingToken`/`buildBookingUrl` (`utils/bookingLink`), `loadSettings`/`saveSettings`, `reportError`.
- Produces: route `SettingsBooking`.

- [ ] **Step 1: Create the screen.** Immediate-action page, NO draft hook:

```tsx
// screens/SettingsBookingScreen.tsx
// Booking link is an IMMEDIATE-action page: loadSettings/saveSettings at
// action time, local state, no draft. On the old monolithic screen these
// handlers also had to patch the just-persisted link into the screen's
// `s`/`savedSnapshot` draft so a later "Save settings" wouldn't clobber it
// (the Task-10 data-loss bug). This page has no coexisting draft, so that
// machinery is gone by design — do not reintroduce a draft here.
import React, { useEffect, useMemo, useState } from "react";
import { View, Text, ScrollView, StyleSheet, Switch, TouchableOpacity, Alert, Share } from "react-native";
import { loadSettings, saveSettings } from "../utils/storage";
import { mintBookingToken, buildBookingUrl } from "../utils/bookingLink";
import { reportError } from "../utils/analytics";
import { Button } from "../components/UI";
import { useSettingsTabPop } from "../hooks/useSettingsDraft";
import { useTheme } from "../hooks/useTheme";
import { spacing, radius, fontSize, fonts, layout, type ColorScheme, type ShadowScheme } from "../utils/theme";
import type { Settings } from "../types/models";
import type { TodayStackScreenProps } from "../types/navigation";

export default function SettingsBookingScreen({ navigation }: TodayStackScreenProps<'SettingsBooking'>) {
  const { colors, shadow } = useTheme();
  const styles = useMemo(() => createStyles(colors, shadow), [colors, shadow]);
  const [bookingLink, setBookingLink] = useState<Settings["bookingLink"] | null>(null);
  const [loaded, setLoaded] = useState(false);
  useSettingsTabPop(navigation);

  useEffect(() => {
    loadSettings().then((l) => {
      setBookingLink(l.bookingLink ?? null);
      setLoaded(true);
    });
  }, []);

  const handleCreateBookingLink = async () => {
    try {
      const out = await mintBookingToken();
      if (!out.ok) { Alert.alert("Couldn't create link", out.message); return; }
      const current = await loadSettings();
      const next = { token: out.token, enabled: true };
      await saveSettings({ ...current, bookingLink: next });
      setBookingLink(next);
    } catch (err: unknown) {
      reportError(err, { context: 'bookingLinkCreate' });
      Alert.alert("Couldn't create link", (err as Error).message || "Please try again.");
    }
  };

  const handleToggleBooking = async (enabled: boolean) => {
    try {
      const current = await loadSettings();
      if (!current.bookingLink) return;
      const next = { ...current.bookingLink, enabled };
      await saveSettings({ ...current, bookingLink: next });
      setBookingLink(next);
    } catch (err: unknown) {
      reportError(err, { context: 'bookingLinkToggle' });
      Alert.alert("Couldn't update", (err as Error).message || "Please try again.");
    }
  };

  const handleShareBookingLink = async (token: string) => {
    try {
      await Share.share({ message: buildBookingUrl(token) });
    } catch (err: unknown) {
      reportError(err, { context: 'bookingLinkShare' });
    }
  };

  const handleNewBookingLink = () => {
    Alert.alert(
      "Get a new link?",
      "Your current booking link will stop working immediately. Anywhere you've shared it will show an invalid-link message.",
      [
        { text: "Cancel", style: "cancel" },
        { text: "Get new link", style: "destructive", onPress: () => { void handleCreateBookingLink(); } },
      ]
    );
  };

  if (!loaded) return null;

  return (
    <View style={styles.container}>
      <ScrollView contentContainerStyle={styles.scroll} showsVerticalScrollIndicator={false}>
        {/* monolith lines 832–871 go here verbatim (the bookingLink
            conditional card), unchanged — it references only the local
            state and handlers above */}
      </ScrollView>
    </View>
  );
}

function createStyles(colors: ColorScheme, shadow: ShadowScheme) {
  return StyleSheet.create({
    container: { flex: 1, backgroundColor: colors.background },
    scroll: { padding: spacing.md, paddingBottom: 60, ...layout.contentColumn },
    card: { backgroundColor: colors.surface, borderRadius: radius.lg, padding: spacing.md, marginBottom: spacing.sm, ...shadow.card },
    providerHint: { fontFamily: fonts.bodyRegular, fontSize: fontSize.sm, color: colors.textSecondary, marginBottom: spacing.sm },
    bookingUrlText: { fontFamily: fonts.mono, fontSize: fontSize.sm, color: colors.textPrimary, marginBottom: spacing.sm },
    toggleRow: { flexDirection: "row", alignItems: "center", justifyContent: "space-between" },
    toggleLabel: { fontFamily: fonts.bodyRegular, fontSize: fontSize.md, color: colors.textPrimary },
    listRow: { flexDirection: "row", alignItems: "center", paddingVertical: 13 },
    listRowText: { fontFamily: fonts.bodyRegular, flex: 1, fontSize: fontSize.md, color: colors.textPrimary },
    listRowChevron: { fontSize: 20, color: colors.textMuted },
    stripeBtn: { paddingHorizontal: 16, paddingVertical: 8, borderRadius: radius.md, borderWidth: 1, borderColor: colors.accent, alignItems: "center", justifyContent: "center" },
    stripeBtnText: { fontFamily: fonts.bodySemiBold, fontSize: fontSize.sm, color: colors.accent },
  });
}
```

- [ ] **Step 2: Register the route** in `App.tsx`.

- [ ] **Step 3: Re-point the test.** In `__tests__/bookingLinkSettings.test.tsx`:
  - Import/render `SettingsBookingScreen` instead of `SettingsScreen`; update the header comment to say the page (not section) is immediate-action.
  - Drop the `AuthContext` and `SubscriptionContext` mocks (this page uses neither).
  - Keep tests 1–5 (create / render / toggle / mint-failure) exactly as they are — labels and flows are unchanged.
  - Replace the final regression test ("a later 'Save settings' does not revert…") with the page-form assertion of the same invariant:

```tsx
  // The old monolith had to patch a fresh booking link into its draft so a
  // later "Save settings" wouldn't clobber it. This page's guarantee is
  // simpler: it has NO draft — it never registers a header Save at all.
  it("the booking page registers no header Save (no draft to clobber)", async () => {
    (mintBookingToken as jest.Mock).mockResolvedValue({ ok: true, token: TOKEN });
    const { findByText } = await render(
      <SettingsBookingScreen navigation={navigation} route={{} as any} />
    );
    await fireEvent.press(await findByText("Create my booking link"));
    await waitFor(() => expect(saveSettings).toHaveBeenCalledTimes(1));
    expect(navigation.setOptions).not.toHaveBeenCalled();
  });
```

- [ ] **Step 4: Run** — `npx jest __tests__/bookingLinkSettings.test.tsx --silent` → PASS (6 tests).

- [ ] **Step 5: Gate + commit**

```bash
npm run typecheck && npm test -- --silent && npm run lint
git add screens/SettingsBookingScreen.tsx App.tsx __tests__/bookingLinkSettings.test.tsx
git commit -m "feat: add the Booking link settings subpage; retire the draft-clobber patching"
```

---

### Task 14: SettingsSubscriptionScreen

**Files:**
- Create: `screens/SettingsSubscriptionScreen.tsx`
- Modify: `App.tsx` (register `SettingsSubscription`, title "Subscription")
- Test: `__tests__/settingsSubscriptionScreen.test.tsx`

**Interfaces:**
- Consumes: `useSettingsTabPop`, `useSubscription` (`context/SubscriptionContext`), `openManageSubscriptions` (`utils/subscription`).
- Produces: route `SettingsSubscription`.

- [ ] **Step 1: Create the screen.** Immediate-action page: Task 5's shell shape (no draft hook, `useSettingsTabPop` only), route type `'SettingsSubscription'`, with `const { isSubscribed, isTrialing } = useSubscription();` and the body copied verbatim from monolith lines 1093–1128 (the status card with Manage/Subscribe). The Subscribe `onPress` keeps `navigation.getParent()?.getParent()?.navigate("PaywallModal", { canDismiss: true })` — the stack nesting depth is unchanged for subpages; keep the PaywallModal comment (line 1123). createStyles keys: `container`, `scroll`, `card`, `providerHint`, `subStatusRow`, `subStatusDot`, `subStatusLabel`, `stripeBtn`, `stripeBtnText`, `stripeConnectBtn`, `stripeConnectBtnText`. Imports: `Alert`, `Platform`, `TouchableOpacity`.

- [ ] **Step 2: Register the route** in `App.tsx`.

- [ ] **Step 3: Write the test** — `__tests__/settingsSubscriptionScreen.test.tsx`:

```tsx
import React from "react";
import { render, fireEvent } from "@testing-library/react-native";
import SettingsSubscriptionScreen from "../screens/SettingsSubscriptionScreen";

const mockSub = { isSubscribed: false, isTrialing: false };
jest.mock("../context/SubscriptionContext", () => ({
  useSubscription: () => mockSub,
}));
jest.mock("../utils/subscription", () => ({
  openManageSubscriptions: jest.fn(() => Promise.resolve(true)),
}));

const rootNavigate = jest.fn();
const navigation = {
  setOptions: jest.fn(),
  addListener: jest.fn(() => jest.fn()),
  getParent: jest.fn(() => ({ getParent: () => ({ navigate: rootNavigate }) })),
  popToTop: jest.fn(),
  dispatch: jest.fn(),
} as any;

describe("SettingsSubscriptionScreen", () => {
  beforeEach(() => {
    jest.clearAllMocks();
    mockSub.isSubscribed = false;
    mockSub.isTrialing = false;
  });

  it("unsubscribed: Subscribe navigates to the root PaywallModal", async () => {
    const { findByLabelText } = await render(
      <SettingsSubscriptionScreen navigation={navigation} route={{} as any} />
    );
    fireEvent.press(await findByLabelText("Subscribe"));
    expect(rootNavigate).toHaveBeenCalledWith("PaywallModal", { canDismiss: true });
  });

  it("subscribed: shows the active status and Manage button", async () => {
    mockSub.isSubscribed = true;
    const { findByText, findByLabelText } = await render(
      <SettingsSubscriptionScreen navigation={navigation} route={{} as any} />
    );
    expect(await findByText("Subscription active")).toBeTruthy();
    expect(await findByLabelText("Manage subscription")).toBeTruthy();
  });
});
```

- [ ] **Step 4: Run** — `npx jest __tests__/settingsSubscriptionScreen.test.tsx --silent` → PASS.

- [ ] **Step 5: Gate + commit**

```bash
npm run typecheck && npm test -- --silent && npm run lint
git add screens/SettingsSubscriptionScreen.tsx App.tsx __tests__/settingsSubscriptionScreen.test.tsx
git commit -m "feat: add the Subscription settings subpage"
```

---

### Task 15: SettingsAccountScreen

**Files:**
- Create: `screens/SettingsAccountScreen.tsx`
- Modify: `App.tsx` (register `SettingsAccount`, title "Account")
- Test: `__tests__/settingsAccountScreen.test.tsx`

**Interfaces:**
- Consumes: `useSettingsTabPop`, `clearSampleData`/`clearAllUserData` (`utils/storage`), `syncIfOnline` (`utils/sync`), `supabase`, `resetUser`/`reportError` (`utils/analytics`), `useSyncStatusContext` (`pendingCount`), `DELETE_CONFIRM_PHRASE`/`deleteConfirmMatches` (`utils/deleteConfirm`).
- Produces: route `SettingsAccount`.

- [ ] **Step 1: Create the screen.** Immediate-action page (no draft hook, `useSettingsTabPop` only), route type `'SettingsAccount'`:
  - Module level: `VERCEL_URL` constant (monolith line 54).
  - State: `deleting`, `deleteModalVisible`, `deleteConfirmText` (lines 137–139); `const { pendingCount } = useSyncStatusContext();`.
  - `performDeleteAccount` copied from lines 588–612 **minus the two `suppressDirtyWarnRef` lines and their comments** — this page has no draft guard to suppress (spec: "What gets simpler"). The sign-out button's `doSignOut` likewise drops its `suppressDirtyWarnRef.current = true;` statement.
  - Body: monolith lines 1174–1218 verbatim (Clear Sample Data / Sign Out / Delete Account buttons with their Alert flows), then the delete-confirm `Modal` from lines 1224–1274 verbatim.
  - createStyles keys: `container`, `scroll`, `input`, `clearSampleBtn`, `clearSampleText`, `signOutBtn`, `signOutText`, `deleteAccountBtn`, `deleteAccountText`, `modalBackdrop`, `modalCard` (with its iPad comment), `modalTitle`, `modalBody`, `modalBtnRow`, `modalCancelBtn`, `modalCancelText`, `modalDeleteBtn`, `modalDeleteText` (monolith lines 1305–1306, 1314, 1345–1362).
  - Imports: `Alert`, `Modal`, `TextInput`, `TouchableOpacity`, `KeyboardAvoidingView`, `Platform`.

- [ ] **Step 2: Register the route** in `App.tsx`.

- [ ] **Step 3: Write the test** — `__tests__/settingsAccountScreen.test.tsx`:

```tsx
import React from "react";
import { Alert } from "react-native";
import { render, fireEvent, waitFor } from "@testing-library/react-native";
import SettingsAccountScreen from "../screens/SettingsAccountScreen";
import { clearAllUserData } from "../utils/storage";
import { supabase } from "../utils/supabase";

jest.mock("../utils/storage", () => ({
  clearSampleData: jest.fn(() => Promise.resolve()),
  clearAllUserData: jest.fn(() => Promise.resolve()),
}));
jest.mock("../utils/supabase", () => ({
  supabase: {
    auth: {
      getSession: jest.fn(() => Promise.resolve({ data: { session: null } })),
      signOut: jest.fn(() => Promise.resolve()),
    },
  },
}));
jest.mock("../utils/sync", () => ({ syncIfOnline: jest.fn(() => Promise.resolve()) }));
jest.mock("../context/SyncStatusContext", () => ({
  useSyncStatusContext: () => ({ pendingCount: 0 }),
}));

const navigation = {
  setOptions: jest.fn(),
  addListener: jest.fn(() => jest.fn()),
  getParent: jest.fn(() => undefined),
  popToTop: jest.fn(),
  dispatch: jest.fn(),
} as any;

describe("SettingsAccountScreen", () => {
  beforeEach(() => {
    jest.clearAllMocks();
    jest.spyOn(Alert, "alert").mockImplementation(() => {});
  });

  it("renders the three account actions", async () => {
    const { findByLabelText } = await render(
      <SettingsAccountScreen navigation={navigation} route={{} as any} />
    );
    expect(await findByLabelText("Clear sample data")).toBeTruthy();
    expect(await findByLabelText("Sign out")).toBeTruthy();
    expect(await findByLabelText("Delete account")).toBeTruthy();
  });

  it("sign out with no pending changes confirms, then wipes and signs out", async () => {
    const { findByLabelText } = await render(
      <SettingsAccountScreen navigation={navigation} route={{} as any} />
    );
    fireEvent.press(await findByLabelText("Sign out"));
    const buttons = (Alert.alert as jest.Mock).mock.calls.at(-1)[2];
    await buttons.find((b: any) => b.text === "Sign out").onPress();
    await waitFor(() => expect(clearAllUserData).toHaveBeenCalledTimes(1));
    expect(supabase.auth.signOut).toHaveBeenCalledTimes(1);
  });

  it("delete is disabled until the confirm phrase matches", async () => {
    const { findByLabelText, getByLabelText } = await render(
      <SettingsAccountScreen navigation={navigation} route={{} as any} />
    );
    fireEvent.press(await findByLabelText("Delete account"));
    const deleteBtn = getByLabelText("Delete my account");
    expect(deleteBtn.props.accessibilityState.disabled).toBe(true);
    fireEvent.changeText(
      getByLabelText(/to confirm account deletion$/),
      "DELETE"
    );
    expect(getByLabelText("Delete my account").props.accessibilityState.disabled).toBe(false);
  });
});
```

  (If `DELETE_CONFIRM_PHRASE` is not the literal `DELETE`, read `utils/deleteConfirm.ts` and use the real phrase in the changeText line.)

- [ ] **Step 4: Run** — `npx jest __tests__/settingsAccountScreen.test.tsx --silent` → PASS.

- [ ] **Step 5: Gate + commit**

```bash
npm run typecheck && npm test -- --silent && npm run lint
git add screens/SettingsAccountScreen.tsx App.tsx __tests__/settingsAccountScreen.test.tsx
git commit -m "feat: add the Account settings subpage"
```

---

### Task 16: SettingsHubScreen

**Files:**
- Create: `screens/SettingsHubScreen.tsx`
- Test: `__tests__/settingsHubScreen.test.tsx`

**Interfaces:**
- Consumes: `useSettingsTabPop`, `fetchStripeConnectStatus`/`StripeStatus` (Task 12), `useSubscription`, `composeEmail` (`utils/messaging`), `SectionHeader` (`components/UI`), all 11 route names (Task 3).
- Produces: the hub component. NOT yet wired to the `Settings` route — that swap is Task 17, so the monolith keeps serving the route until everything is in place.

- [ ] **Step 1: Create the screen:**

```tsx
// screens/SettingsHubScreen.tsx
// The Settings menu — replaced the 1,390-line monolithic SettingsScreen at
// the 2026-08-05 hub/subpages split. Every row pushes a focused subpage;
// Support/Legal are single actions and live here directly (spec decision).
import React, { useEffect, useMemo, useState } from "react";
import { View, Text, ScrollView, StyleSheet, TouchableOpacity, Linking, Platform } from "react-native";
import { Ionicons } from "@expo/vector-icons";
import Constants from "expo-constants";
import { SectionHeader } from "../components/UI";
import { composeEmail } from "../utils/messaging";
import { fetchStripeConnectStatus, type StripeStatus } from "../utils/stripeStatus";
import { useSettingsTabPop } from "../hooks/useSettingsDraft";
import { useSubscription } from "../context/SubscriptionContext";
import { useTheme } from "../hooks/useTheme";
import { spacing, radius, fontSize, fonts, layout, type ColorScheme, type ShadowScheme } from "../utils/theme";
import type { TodayStackScreenProps } from "../types/navigation";

const PRIVACY_URL = Constants.expoConfig?.extra?.privacyPolicyUrl ?? "https://tradeready.app/privacy";
const TERMS_URL   = Constants.expoConfig?.extra?.termsUrl          ?? "https://tradeready.app/terms";
// Must match the address published in the privacy policy (§ Contact) —
// the domain is gettradereadyapp.com, NOT tradeready.app (which doesn't exist).
const SUPPORT_EMAIL = "support@gettradereadyapp.com";
const APP_VERSION   = Constants.expoConfig?.version ?? "1.0.0";

interface HubRow {
  icon: keyof typeof Ionicons.glyphMap;
  label: string;
  subtitle?: string;
  onPress: () => void;
  role?: "button" | "link";
}

export default function SettingsHubScreen({ navigation }: TodayStackScreenProps<'Settings'>) {
  const { colors, shadow } = useTheme();
  const styles = useMemo(() => createStyles(colors, shadow), [colors, shadow]);
  const { isSubscribed, isTrialing } = useSubscription();
  const [stripeStatus, setStripeStatus] = useState<StripeStatus | null>(null);
  useSettingsTabPop(navigation);

  // Fetched on mount and every focus: keeps the Payments subtitle fresh
  // after a visit to the Payments page, and preserves the old screen's
  // checklist-signal timing (the util marks "stripe" done when connected).
  useEffect(() => {
    const refresh = () => { void fetchStripeConnectStatus().then(setStripeStatus); };
    refresh();
    const unsub = navigation.addListener("focus", refresh);
    return unsub;
  }, [navigation]);

  const stripeSubtitle =
    stripeStatus === null ? undefined
    : stripeStatus.connected
      ? (stripeStatus.display_name ? `Connected — ${stripeStatus.display_name}` : "Connected")
      : "Not connected";
  const subSubtitle = isTrialing ? "Free trial active" : isSubscribed ? "Active" : "Not subscribed";

  const groups: Array<{ title: string; rows: HubRow[] }> = [
    {
      title: "Your business",
      rows: [
        { icon: "business-outline", label: "Business profile", onPress: () => navigation.navigate("SettingsBusiness") },
        { icon: "calculator-outline", label: "Pricing defaults", onPress: () => navigation.navigate("SettingsPricing") },
        { icon: "receipt-outline", label: "Invoice numbering", onPress: () => navigation.navigate("SettingsInvoiceNumbering") },
      ],
    },
    {
      title: "Getting paid",
      rows: [
        { icon: "card-outline", label: "Payments", subtitle: stripeSubtitle, onPress: () => navigation.navigate("SettingsPayments") },
        { icon: "calendar-outline", label: "Booking link", onPress: () => navigation.navigate("SettingsBooking") },
      ],
    },
    {
      title: "App",
      rows: [
        { icon: "color-palette-outline", label: "Appearance", onPress: () => navigation.navigate("SettingsAppearance") },
        { icon: "sparkles-outline", label: "AI Assistant", onPress: () => navigation.navigate("SettingsAI") },
        { icon: "notifications-outline", label: "Notifications", onPress: () => navigation.navigate("SettingsNotifications") },
        { icon: "star-outline", label: "Review requests", onPress: () => navigation.navigate("SettingsReviews") },
      ],
    },
    {
      title: "Subscription & support",
      rows: [
        { icon: "diamond-outline", label: "Subscription", subtitle: subSubtitle, onPress: () => navigation.navigate("SettingsSubscription") },
        {
          icon: "mail-outline",
          label: "Contact Support",
          subtitle: SUPPORT_EMAIL,
          onPress: () => {
            void composeEmail({
              recipients: [SUPPORT_EMAIL],
              subject: `TradeReady support (v${APP_VERSION}, ${Platform.OS})`,
              body: "",
            });
          },
        },
        { icon: "shield-outline", label: "Privacy Policy", role: "link", onPress: () => { void Linking.openURL(PRIVACY_URL); } },
        { icon: "document-text-outline", label: "Terms of Service", role: "link", onPress: () => { void Linking.openURL(TERMS_URL); } },
      ],
    },
    {
      title: "Account",
      rows: [
        { icon: "person-circle-outline", label: "Account", onPress: () => navigation.navigate("SettingsAccount") },
      ],
    },
  ];

  return (
    <View style={styles.container}>
      <ScrollView contentContainerStyle={styles.scroll} showsVerticalScrollIndicator={false}>
        {groups.map((group) => (
          <View key={group.title}>
            <SectionHeader title={group.title} />
            <View style={styles.card}>
              {group.rows.map((row, i) => (
                <View key={row.label}>
                  {i > 0 && <View style={styles.listRowDivider} />}
                  <TouchableOpacity
                    style={styles.listRow}
                    onPress={row.onPress}
                    activeOpacity={0.7}
                    accessibilityRole={row.role ?? "button"}
                    accessibilityLabel={row.label}
                  >
                    <Ionicons name={row.icon} size={20} color={colors.textSecondary} style={styles.listRowIcon} />
                    <View style={{ flex: 1 }}>
                      <Text style={styles.listRowText}>{row.label}</Text>
                      {!!row.subtitle && <Text style={styles.listRowSub}>{row.subtitle}</Text>}
                    </View>
                    <Text style={styles.listRowChevron}>›</Text>
                  </TouchableOpacity>
                </View>
              ))}
            </View>
          </View>
        ))}
      </ScrollView>
    </View>
  );
}

function createStyles(colors: ColorScheme, shadow: ShadowScheme) {
  return StyleSheet.create({
    container: { flex: 1, backgroundColor: colors.background },
    scroll: { padding: spacing.md, paddingBottom: 60, ...layout.contentColumn },
    card: { backgroundColor: colors.surface, borderRadius: radius.lg, paddingHorizontal: spacing.md, marginBottom: spacing.sm, ...shadow.card },
    listRow: { flexDirection: "row", alignItems: "center", paddingVertical: 13 },
    listRowIcon: { marginRight: spacing.sm },
    listRowText: { fontFamily: fonts.bodyRegular, fontSize: fontSize.md, color: colors.textPrimary },
    listRowSub: { fontFamily: fonts.bodyRegular, fontSize: fontSize.xs, color: colors.textMuted, marginTop: 2 },
    listRowChevron: { fontSize: 20, color: colors.textMuted },
    listRowDivider: { height: StyleSheet.hairlineWidth, backgroundColor: colors.border },
  });
}
```

- [ ] **Step 2: Write the test** — `__tests__/settingsHubScreen.test.tsx`:

```tsx
import React from "react";
import { Linking } from "react-native";
import { render, fireEvent, waitFor } from "@testing-library/react-native";
import SettingsHubScreen from "../screens/SettingsHubScreen";
import { fetchStripeConnectStatus } from "../utils/stripeStatus";
import { composeEmail } from "../utils/messaging";

jest.mock("../utils/stripeStatus", () => ({
  fetchStripeConnectStatus: jest.fn(() => Promise.resolve({ connected: true, display_name: "Acme LLC" })),
}));
jest.mock("../utils/messaging", () => ({ composeEmail: jest.fn(() => Promise.resolve(true)) }));
jest.mock("../context/SubscriptionContext", () => ({
  useSubscription: () => ({ isSubscribed: false, isTrialing: true }),
}));

const navigation = {
  setOptions: jest.fn(),
  addListener: jest.fn(() => jest.fn()),
  getParent: jest.fn(() => undefined),
  popToTop: jest.fn(),
  dispatch: jest.fn(),
  navigate: jest.fn(),
} as any;

// Every navigating row and its target route — a missed App.tsx
// registration surfaces as a runtime crash, so this table is the map.
const NAV_ROWS: Array<[string, string]> = [
  ["Business profile", "SettingsBusiness"],
  ["Pricing defaults", "SettingsPricing"],
  ["Invoice numbering", "SettingsInvoiceNumbering"],
  ["Payments", "SettingsPayments"],
  ["Booking link", "SettingsBooking"],
  ["Appearance", "SettingsAppearance"],
  ["AI Assistant", "SettingsAI"],
  ["Notifications", "SettingsNotifications"],
  ["Review requests", "SettingsReviews"],
  ["Subscription", "SettingsSubscription"],
  ["Account", "SettingsAccount"],
];

describe("SettingsHubScreen", () => {
  beforeEach(() => jest.clearAllMocks());

  it("every menu row navigates to its subpage route", async () => {
    const { findByLabelText } = await render(
      <SettingsHubScreen navigation={navigation} route={{} as any} />
    );
    for (const [label, route] of NAV_ROWS) {
      fireEvent.press(await findByLabelText(label));
      expect(navigation.navigate).toHaveBeenLastCalledWith(route);
    }
  });

  it("shows the Stripe and subscription status subtitles", async () => {
    const { findByText } = await render(
      <SettingsHubScreen navigation={navigation} route={{} as any} />
    );
    expect(await findByText("Connected — Acme LLC")).toBeTruthy();
    expect(await findByText("Free trial active")).toBeTruthy();
    await waitFor(() => expect(fetchStripeConnectStatus).toHaveBeenCalled());
  });

  it("Contact Support composes the support email; legal rows open their URLs", async () => {
    const openURL = jest.spyOn(Linking, "openURL").mockResolvedValue(true as any);
    const { findByLabelText } = await render(
      <SettingsHubScreen navigation={navigation} route={{} as any} />
    );
    fireEvent.press(await findByLabelText("Contact Support"));
    expect(composeEmail).toHaveBeenCalledWith(
      expect.objectContaining({ recipients: ["support@gettradereadyapp.com"] })
    );
    fireEvent.press(await findByLabelText("Privacy Policy"));
    fireEvent.press(await findByLabelText("Terms of Service"));
    expect(openURL).toHaveBeenCalledTimes(2);
  });
});
```

- [ ] **Step 3: Run** — `npx jest __tests__/settingsHubScreen.test.tsx --silent` → PASS.

- [ ] **Step 4: Gate + commit**

```bash
npm run typecheck && npm test -- --silent && npm run lint
git add screens/SettingsHubScreen.tsx __tests__/settingsHubScreen.test.tsx
git commit -m "feat: add the Settings hub menu screen"
```

---

### Task 17: Swap the route, deep-link the checklist, delete the monolith

**Files:**
- Modify: `App.tsx` (the `Settings` registration + imports)
- Modify: `components/SetupChecklistCard.tsx:26-31, 73-80`
- Modify: `screens/TodayScreen.tsx:722` (+ a module-level map + one type import)
- Delete: `screens/SettingsScreen.tsx`
- Modify: `README.md` / `ARCHITECTURE.md` (stale file-map mentions)

**Interfaces:**
- Consumes: everything. After this task the hub serves route `Settings`; the monolith is gone.

- [ ] **Step 1: Swap the route.** In `App.tsx`: replace the `SettingsScreen` import with `import SettingsHubScreen from "./screens/SettingsHubScreen";` and change line 124's registration to:

```tsx
<TodayStack.Screen name="Settings" component={SettingsHubScreen} options={{ title: "Settings" }} />
```

- [ ] **Step 2: Checklist deep-links.** In `components/SetupChecklistCard.tsx`, change the prop and its one call site:

```tsx
interface SetupChecklistCardProps {
  settings: Settings | null;
  onOpenSettings: (task: SetupTaskId) => void;
}
```

and in `handleTask` (line 79): `onOpenSettings(id);`

In `screens/TodayScreen.tsx`, add at module level (importing `type SetupTaskId` from `../utils/setupChecklist`):

```tsx
// Checklist tasks deep-link to their owning settings subpage. The
// notifications task never reaches this map (handled in-card), but the
// Record is total so tsc keeps it in sync with SetupTaskId.
const SETTINGS_ROUTE_FOR_TASK: Record<SetupTaskId, "Settings" | "SettingsBusiness" | "SettingsPricing" | "SettingsPayments"> = {
  contact: "SettingsBusiness",
  logo: "SettingsBusiness",
  rate: "SettingsPricing",
  stripe: "SettingsPayments",
  notifications: "Settings",
};
```

and change line 722 to:

```tsx
<SetupChecklistCard settings={settings} onOpenSettings={(task) => navigation.navigate(SETTINGS_ROUTE_FOR_TASK[task])} />
```

The gear (line 669) keeps `navigation.navigate('Settings')` — it lands on the hub.

- [ ] **Step 3: Delete the monolith** — `git rm screens/SettingsScreen.tsx`. Then verify nothing dangles:

```bash
grep -rn "screens/SettingsScreen" --include="*.ts" --include="*.tsx" .
```

Expected: no source hits (docs/plan mentions are fine).

- [ ] **Step 4: Docs sweep.** `grep -n "SettingsScreen" README.md ARCHITECTURE.md` — replace each stale file-map entry with `SettingsHubScreen` plus the 11 subpage files, one line each in the file's existing list style. Also update any "Settings screen sections" prose to say the hub + subpage structure.

- [ ] **Step 5: Full gate** — `npm run typecheck && npm test -- --silent && npm run lint` → 0 / all pass (the gear suite and every settings suite must be green; expected new-suite delta: +8 files vs the pre-plan baseline) / 0.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat: Settings becomes a hub of focused subpages; retire the monolith"
```

- [ ] **Step 7: STOP for the phase gate.** Report Confidence / Missing Context / Recommended Next Step to the owner. Do NOT push without the owner's go-ahead; after any push, verify CI: `gh run list --workflow "Verify gate" --limit 1`. Owner device smoke is required before the feature is claimable (Expo Go; the web preview cannot render this app). Flag for the skill library: `tradeready-architecture-contract` §2's Settings description and `tradeready-config-and-flags`' Settings-screen references now describe the hub + subpages.

---

## Plan Self-Review (completed at authoring)

- **Spec coverage:** per-page Save ✓ (Task 2 hook, Tasks 6–12 pages); hub keeps route name ✓ (Tasks 16–17); booking own page + simplification ✓ (Task 13); support/legal hub rows ✓ (Task 16); sign-out on Account page + suppress-flag deletion ✓ (Task 15); validation split ✓ (Task 1, wired Tasks 6/10); rate signal move ✓ (Task 6); stripe signal timing via hub fetch ✓ (Tasks 12/16); checklist deep-links ✓ (Task 17); logo lifecycle move ✓ (Task 10); rule-draft move ✓ (Task 11); guard-save-skips-validate pinned ✓ (Task 2 test); booking test re-point ✓ (Task 13); gear test untouched ✓ (verified: it imports only TodayScreen).
- **Known judgment call:** `prepare` replaces the spec's `onLoaded` (noted in the header) — same duty, strictly more capable.
- **Type consistency:** route names match Task 3's param list everywhere; `SettingsField` takes `colors` only (the ` shadow={shadow}` strip is a Global Constraint); `StripeStatus` lives in `utils/stripeStatus.ts` from Task 12 on and is the only definition new code imports (the monolith keeps its private copy until deletion).
- **Verify-at-implementation notes:** the `DELETE_CONFIRM_PHRASE` literal (Task 15 test), the exact import style of `settingsValidation.test.js` (Task 1), and BaseField's accessibility-label pass-through (all `findByLabelText` calls assume label text = accessibility label, which the existing bookingLink suite already relies on).
