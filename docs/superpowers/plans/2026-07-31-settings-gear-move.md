# Settings-to-Gear Move Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove Settings from the bottom tab bar (7 tabs → 6), make it a screen pushed onto the Today stack behind a gear icon in the Today header, and fix the page's layout debt while we're in it: a sticky header Save, account actions moved to the bottom, the one-field Mileage section merged into Pricing defaults, and Appearance hoisted above the long configuration blocks.

**Architecture:** Settings moves from a direct `Tab.Screen` to a `TodayStack.Screen`, reached by a gear `TouchableOpacity` in TodayScreen's custom in-scroll header. The new native header enables a `headerRight` Save (live-enabled from the same `settingsEqual` dirty check the guard uses). The unsaved-changes guard keeps its existing `blur` listener (covers switching tabs while Settings is pushed — the screen stays mounted) and gains a `beforeRemove` listener (covers the back button / swipe-back — the canonical React Navigation intercept, since the screen unmounts on pop and the current after-the-fact alert pattern can't work there). One deep link (ReviewRequestScreen) is rewired to the cross-tab pattern already used app-wide. Page reorganization is pure JSX movement — no persisted data-shape changes.

**Tech Stack:** React Navigation v7 (native-stack + bottom-tabs, fully typed via `types/navigation.ts`), Expo 54 / RN 0.81, Jest + RNTL v14 (async `render()`), Ionicons.

## Global Constraints

- Owner rules (tradeready-change-control): phase-gate each task and STOP for go-ahead between tasks when run interactively; NEVER commit on a red gate (`npm run typecheck` 0 errors / `npm test` all pass / `npm run lint` 0 warnings, run from `tradeready/`); NO dependency, SDK, or `app.json` plugins changes.
- No `eslint-disable` / `@ts-ignore` / `@ts-expect-error` additions.
- Do NOT touch the `inputMultiline: { height: undefined, ... }` style in SettingsScreen — its comment explains why it is load-bearing.
- Blueprint typography rules apply to any new text (none is added — the gear is icon-only).
- Commit messages: imperative subject with `feat:`/`fix:` prefix; end with `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- Do not push to origin; the owner pushes/asks explicitly.
- Feature is NOT done until the owner's Expo Go device smoke passes (checklist in Task 4). Code review is not a smoke test.

**Known accepted behavior:** after ReviewRequest → "Go to Settings", the OS back affordance on Settings pops to TodayHome (the Today tab's stack root), not back to ReviewRequest. This matches every existing cross-tab jump in the app (architecture contract §2).

---

### Task 1: Move the registration, rewire navigation, add the gear (TDD)

**Files:**
- Test (create): `__tests__/TodayScreenSettingsGear.test.tsx`
- Modify: `types/navigation.ts:19-34` (MainTabParamList, TodayStackParamList)
- Modify: `App.tsx:100-105` (TodayTab), `App.tsx:229-237` (TAB_ICONS), `App.tsx:275-284` (remove Settings Tab.Screen)
- Modify: `screens/TodayScreen.tsx` (header JSX + styles + Ionicons import)
- Modify: `screens/SettingsScreen.tsx:106` (props type) and `:897` (PaywallModal call)
- Modify: `screens/ReviewRequestScreen.tsx:158` (deep link)

**Interfaces:**
- Consumes: existing `TodayStackScreenProps<T>` helper in `types/navigation.ts`.
- Produces: route `Settings: undefined` on `TodayStackParamList`, and a themed native header on the Settings screen (Task 2's headerRight Save, Task 3's guard, and the smoke checklist all rely on Settings being a native-stack screen with a header and back navigation).

- [ ] **Step 1: Write the failing test**

Create `__tests__/TodayScreenSettingsGear.test.tsx`:

```tsx
/**
 * The Settings gear in Today's header — the only tab-bar-visible entry point
 * to SettingsScreen after the 7→6 tab consolidation — must push the Settings
 * screen on the Today stack.
 */
import React from "react";
import { render, fireEvent } from "@testing-library/react-native";
import TodayScreen from "../screens/TodayScreen";

jest.mock("react-native-safe-area-context", () => ({
  useSafeAreaInsets: () => ({ top: 0, bottom: 0, left: 0, right: 0 }),
  SafeAreaProvider: ({ children }: { children: React.ReactNode }) => children,
}));

// TodayScreen only uses useFocusEffect from this module; run it as a mount effect.
jest.mock("@react-navigation/native", () => ({
  useFocusEffect: (cb: () => void | (() => void)) => {
    const React = require("react");
    React.useEffect(cb, []);
  },
}));

jest.mock("../utils/storage", () => ({
  loadJobs: jest.fn(() => Promise.resolve([])),
  getExpectedEarningsForDate: jest.fn(() => Promise.resolve(0)),
  loadOverdueInvoices: jest.fn(() => Promise.resolve([])),
  loadLeadJobs: jest.fn(() => Promise.resolve([])),
  loadCustomers: jest.fn(() => Promise.resolve([])),
  loadSettings: jest.fn(() => Promise.resolve({})),
  resolveCustomer: jest.fn(() => null),
}));

jest.mock("../utils/appointmentSend", () => ({
  sendAppointmentMessage: jest.fn(() => Promise.resolve(false)),
}));

describe("TodayScreen settings gear", () => {
  it("navigates to Settings on the Today stack when pressed", async () => {
    const navigate = jest.fn();
    const navigation = { navigate, getParent: jest.fn() } as any;

    const { getByLabelText } = await render(
      <TodayScreen navigation={navigation} route={{} as any} />
    );

    fireEvent.press(getByLabelText("Open settings"));
    expect(navigate).toHaveBeenCalledWith("Settings");
  });
});
```

(No local `@expo/vector-icons` mock needed — the global mock lives in `jest.setup.js` since the Blueprint Money round.)

- [ ] **Step 2: Run the test to verify it fails**

Run: `npm test -- TodayScreenSettingsGear`
Expected: FAIL — "Unable to find an element with accessibilityLabel: Open settings".

- [ ] **Step 3: Update `types/navigation.ts`**

In `MainTabParamList`, delete the line:

```ts
  Settings: undefined;
```

In `TodayStackParamList`, add `Settings`:

```ts
export type TodayStackParamList = {
  TodayHome: undefined;
  Route: undefined;
  Settings: undefined;
};
```

- [ ] **Step 4: Update `App.tsx`**

In `TodayTab()` (line ~101), register the screen:

```tsx
    <TodayStack.Navigator screenOptions={navOpts}>
      <TodayStack.Screen name="TodayHome" component={TodayScreen} options={{ headerShown: false }} />
      <TodayStack.Screen name="Route" component={RouteScreen} options={{ title: "Today's Route" }} />
      <TodayStack.Screen name="Settings" component={SettingsScreen} options={{ title: "Settings" }} />
    </TodayStack.Navigator>
```

(The stack's `navOpts` already provides the themed header + back button — the removed tab-screen header options below are fully replaced by this.)

In `TAB_ICONS` (line ~236), delete:

```ts
  Settings:  { active: "settings",             inactive: "settings-outline" },
```

In `MainTabs()` (lines ~275-284), delete the whole Settings `Tab.Screen`:

```tsx
      <Tab.Screen
        name="Settings"
        component={SettingsScreen}
        options={{
          headerShown:      true,
          title:            "Settings",
          headerStyle:      { backgroundColor: colors.surface },
          headerTitleStyle: { color: colors.textPrimary, fontWeight: "600" as const },
        }}
      />
```

- [ ] **Step 5: Add the gear to TodayScreen's header**

In `screens/TodayScreen.tsx`, add the import:

```tsx
import { Ionicons } from '@expo/vector-icons';
```

Replace the header block:

```tsx
      {/* Header */}
      <View style={styles.header}>
        <Text style={styles.greeting}>{getGreeting()}</Text>
        <Text style={styles.dateText}>{formatDisplayDate(todayString)}</Text>
      </View>
```

with:

```tsx
      {/* Header */}
      <View style={styles.header}>
        <View style={styles.headerText}>
          <Text style={styles.greeting}>{getGreeting()}</Text>
          <Text style={styles.dateText}>{formatDisplayDate(todayString)}</Text>
        </View>
        <TouchableOpacity
          style={styles.settingsBtn}
          onPress={() => navigation.navigate('Settings')}
          hitSlop={{ top: 8, bottom: 8, left: 8, right: 8 }}
          accessibilityRole="button"
          accessibilityLabel="Open settings"
        >
          <Ionicons name="settings-outline" size={22} color={colors.textSecondary} />
        </TouchableOpacity>
      </View>
```

In `createStyles`, replace the `header` style and add the two new ones:

```ts
    header: {
      flexDirection: 'row',
      alignItems: 'flex-start',
      justifyContent: 'space-between',
      paddingHorizontal: spacing.lg,
      paddingTop: spacing.md,
      paddingBottom: spacing.sm,
    },
    headerText: {
      flex: 1,
      marginRight: spacing.sm,
    },
    settingsBtn: {
      minWidth: 44,
      minHeight: 44,
      alignItems: 'center',
      justifyContent: 'center',
    },
```

- [ ] **Step 6: Re-type SettingsScreen and fix its PaywallModal hop**

In `screens/SettingsScreen.tsx` line ~106, change the signature:

```tsx
export default function SettingsScreen({ navigation }: TodayStackScreenProps<'Settings'>) {
```

Update imports accordingly: remove the now-unused `BottomTabScreenProps` / `MainTabParamList` imports and import the helper instead:

```tsx
import type { TodayStackScreenProps } from "../types/navigation";
```

At line ~897, the parent chain gains a hop (Settings' parent is now the tab navigator, whose parent is the root stack):

```tsx
onPress={() => navigation.getParent()?.getParent()?.navigate("PaywallModal", { canDismiss: true })}
```

Add a one-line comment above it stating the constraint the code can't show:

```tsx
{/* PaywallModal lives on the ROOT stack: TodayStack → MainTabs → RootStack, hence two hops. */}
```

- [ ] **Step 7: Rewire the ReviewRequest deep link**

In `screens/ReviewRequestScreen.tsx` line ~158, replace:

```tsx
              onPress={() => navigation.navigate("Settings")}
```

with the app's established cross-tab pattern:

```tsx
              onPress={() => navigation.navigate("Today", { screen: "Settings" })}
```

- [ ] **Step 8: Run the new test to verify it passes**

Run: `npm test -- TodayScreenSettingsGear`
Expected: PASS.

- [ ] **Step 9: Run the full gate**

Run: `npm run typecheck` then `npm test` then `npm run lint`
Expected: 0 errors / all suites pass (1350 tests expected: 1349 + the new one) / 0 warnings. If `tsc` flags any other `navigate("Settings")` call site this plan missed, fix it with the Step 7 pattern before committing.

- [ ] **Step 10: Commit**

```bash
git add types/navigation.ts App.tsx screens/TodayScreen.tsx screens/SettingsScreen.tsx screens/ReviewRequestScreen.tsx __tests__/TodayScreenSettingsGear.test.tsx
git commit -m "feat: move Settings off the tab bar behind a Today-header gear

Settings becomes a screen on the Today stack (7 tabs -> 6), opened by a
gear icon in Today's header. ReviewRequest's Go-to-Settings deep link
uses the cross-tab pattern; SettingsScreen's PaywallModal call gains the
extra getParent hop.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: Settings page reorganization — header Save, section order, mileage merge

**Files:**
- Modify: `screens/SettingsScreen.tsx` only (imports line 1; render JSX ~lines 459-941; no style changes needed)

**Interfaces:**
- Consumes: the themed native header from Task 1; existing `handleSave()` (hoisted `async function`, line ~400), `saving` state (line ~111), `settingsEqual` from `utils/settingsDirty`, `s` / `savedSnapshot` state.
- Produces: nothing consumed by later tasks. Task 3's guard is independent; Task 4's smoke exercises this.

**Why no automated test:** all four changes are JSX movement plus a `headerRight` wired to the already-unit-tested `settingsEqual` decision. Rendering SettingsScreen requires Auth/Subscription/SyncStatus providers plus supabase mocks — same reason the D2 guard shipped wiring-untested. Verification is the Task 4 device smoke.

- [ ] **Step 1: Add the headerRight Save**

In `screens/SettingsScreen.tsx` line 1, add `useLayoutEffect` to the React import:

```tsx
import React, { useState, useEffect, useLayoutEffect, useRef, useMemo } from "react";
```

Inside the component, directly below the `const [savedSnapshot, ...]` block (line ~140), add:

```tsx
  // Sticky Save in the native header (the screen only has a header at all
  // since the gear move). Enabled exactly when the dirty-guard would fire.
  const dirty = !!s && !!savedSnapshot && !settingsEqual(s, savedSnapshot);
  useLayoutEffect(() => {
    navigation.setOptions({
      headerRight: () => (
        <TouchableOpacity
          onPress={handleSave}
          disabled={!dirty || saving}
          hitSlop={{ top: 8, bottom: 8, left: 8, right: 8 }}
          // Header buttons: paddingLeft/alignSelf are what center the text;
          // alignItems/justifyContent are no-ops in a native-stack header slot.
          style={{ alignSelf: "center", paddingLeft: 10 }}
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
```

Notes: `handleSave` is a hoisted `function` declaration, so referencing it above its definition is fine. The effect runs every render deliberately (no dep array): `handleSave` has a fresh identity each render, so listing exhaustive deps would re-run it every render anyway — and `setOptions` per render is the documented React Navigation pattern. `fonts`/`fontSize` are module constants; `colors` is in scope. The bottom "Save settings" `Button` (line ~816) STAYS — someone at the end of the scroll shouldn't have to travel back up.

- [ ] **Step 2: Merge the mileage rate into Pricing defaults**

Inside the Pricing defaults card, directly after the "Emergency/after-hours multiplier" `Field` (line ~523), add:

```tsx
          <Field label="Mileage rate ($ per mile)" value={String(s.mileageRate ?? 0.70)} onChangeText={(v) => update("mileageRate", parseFloat(v) || 0)} keyboardType="decimal-pad" colors={colors} shadow={shadow} />
          <Text style={styles.keyNote}>
            Used to estimate the tax deduction for logged trips (Money → Mileage). Set to the standard mileage rate for your tax year.
          </Text>
```

Then delete the whole standalone Mileage section (lines ~526-534): its `<Divider />`, `<SectionHeader title="Mileage deduction" />`, the `ruleSubtitle` explainer `<Text>`, and the one-field card.

- [ ] **Step 3: Hoist Appearance above Payment processor**

Cut the Appearance block — `<SectionHeader title="Appearance" />` through its card's closing `</View>` plus ONE adjacent `<Divider />` (lines ~643-662) — and paste it between the Pricing defaults card's closing `</View>` and the `<SectionHeader title="Payment processor" />` block, keeping a `<Divider />` between each pair of sections.

- [ ] **Step 4: Move the account actions to the very bottom**

Cut the three action buttons — the `clearSampleBtn`, `signOutBtn`, and `deleteAccountBtn` `TouchableOpacity` blocks (lines ~818-862, everything between the "Save settings" `Button` and the `<Divider />` before Subscription).

Paste them after the Legal card's closing `</View>` (line ~941), introduced by:

```tsx
        <Divider />

        <SectionHeader title="Account" />
```

Resulting section order (verify by reading the render top to bottom):
**Your business → Pricing defaults (incl. mileage rate) → Appearance → Payment processor → AI Assistant → Notification rules → Review requests → Save settings → Subscription → Help & Support → Legal → Account (Clear Sample Data / Sign Out / Delete Account).**

- [ ] **Step 5: Run the full gate**

Run: `npm run typecheck` then `npm test` then `npm run lint`
Expected: 0 / all pass / 0. Watch lint specifically — the `useLayoutEffect` deliberately has no dependency array; if `react-hooks/exhaustive-deps` flags it, switch to a dep array of `[navigation, dirty, saving, colors]` and accept the extra re-runs rather than adding any disable comment.

- [ ] **Step 6: Commit**

```bash
git add screens/SettingsScreen.tsx
git commit -m "feat: reorganize Settings — header Save, account actions last

Sticky Save in the new native header (enabled while edits are unsaved);
Clear Sample Data / Sign Out / Delete Account move to a trailing Account
section; the one-field Mileage section folds into Pricing defaults;
Appearance hoists above the long configuration blocks.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: Unsaved-changes guard for the back/pop path

**Files:**
- Modify: `screens/SettingsScreen.tsx:164-201` (the existing `blur`-listener effect block — keep it, add a sibling effect)

**Interfaces:**
- Consumes: `Settings` route on `TodayStackParamList` (Task 1) — `beforeRemove` only exists on stack navigation props, which is why this task requires Task 1's re-typing.
- Produces: nothing consumed by later tasks; device-smoke items in Task 4 exercise it.

**Why no automated test:** the existing `blur` guard (fix D2) shipped wiring-untested by design — the dirty *decision* is unit-tested in `utils/settingsDirty.ts`, and rendering SettingsScreen requires Auth/Subscription/SyncStatus providers plus supabase mocks. This task follows that precedent; verification is the Task 4 device smoke.

- [ ] **Step 1: Add the `beforeRemove` listener**

Directly below the existing `blur`-listener `useEffect` (after line ~201), add:

```tsx
  // Back/pop path of the unsaved-edits guard. The blur listener above covers
  // switching TABS while Settings is pushed (screen stays mounted, alert shows
  // after the fact); popping the stack UNMOUNTS the screen, so that pattern
  // can't work here — intercept the removal, ask, then resume the same action.
  // suppressDirtyWarnRef is set before dispatching so the blur listener (which
  // fires during the resumed removal, before the refs settle) stays quiet.
  useEffect(() => {
    const unsub = navigation.addListener("beforeRemove", (e) => {
      const current = sRef.current;
      const saved = savedSnapshotRef.current;
      if (suppressDirtyWarnRef.current || !current || !saved) return;
      if (settingsEqual(current, saved)) return;
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
              // from storage. Logo files copied during the abandoned edit are
              // orphans now — same cleanup as the blur path.
              suppressDirtyWarnRef.current = true;
              cleanupLogoFiles(saved.logoPhoto);
              navigation.dispatch(e.data.action);
            },
          },
          {
            text: "Save",
            onPress: async () => {
              const toSave = sRef.current;
              if (!toSave) return;
              await saveSettings(toSave);
              syncNotifications();
              setSavedSnapshot(toSave);
              await cleanupLogoFiles(toSave.logoPhoto);
              suppressDirtyWarnRef.current = true;
              navigation.dispatch(e.data.action);
            },
          },
        ]
      );
    });
    return unsub;
  }, [navigation]);
```

Notes for the implementer:
- `settingsEqual`, `saveSettings`, `syncNotifications`, `cleanupLogoFiles`, and all three refs already exist in this component — no new imports.
- The sign-out / delete-account flows already set `suppressDirtyWarnRef.current = true` before tearing navigation down; the first guard line keeps those flows alert-free when the root reset removes this screen.
- `suppressDirtyWarnRef` is deliberately not reset after dispatch — the component unmounts with the ref.

- [ ] **Step 2: Run the full gate**

Run: `npm run typecheck` then `npm test` then `npm run lint`
Expected: 0 / all pass / 0. (`beforeRemove` typechecks because Task 1 re-typed `navigation` as a native-stack prop.)

- [ ] **Step 3: Commit**

```bash
git add screens/SettingsScreen.tsx
git commit -m "feat: guard unsaved Settings edits on back navigation

beforeRemove intercept with the same Save/Discard choice as the existing
tab-blur guard; the resumed dispatch is suppressed from double-prompting.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: Documentation, skill cross-references, and device smoke

**Files:**
- Modify: `..\.claude\skills\tradeready-architecture-contract\SKILL.md` (§2 tab table + gate-chain notes)
- Modify: `..\.claude\skills\tradeready-launch-readiness\SKILL.md` (the "7-tab layout" polish line)
- Check/modify: `README.md`, `ARCHITECTURE.md` (only if they mention the tab count)

**Interfaces:** none — prose only.

- [ ] **Step 1: Update the architecture-contract skill**

In `tradeready-architecture-contract/SKILL.md` §2 "The 7 tabs (MainTabs)": retitle to "The 6 tabs (MainTabs)"; change the Today row's screens to `TodayHome, Route, Settings (opened via the gear in Today's header)`; delete the Settings row; add one line after the table: "Settings moved off the tab bar 2026-07-31 (gear in Today's header); its unsaved-edits guard listens on BOTH `blur` (tab-switch away) and `beforeRemove` (back/pop)." Update the re-verification row for the tab table if it quotes expected tab names.

- [ ] **Step 2: Update the launch-readiness skill**

In `tradeready-launch-readiness/SKILL.md`, "What 'polish' concretely means now": replace "The 7-tab layout remains a deliberate launch-scope decision, not a defect." with "The tab bar went 7 → 6 on 2026-07-31 (Settings behind a gear in the Today header); the remaining 6-tab layout is a deliberate decision."

- [ ] **Step 3: Sweep repo docs for the stale count**

Run: `npx rg -n -i "seven tabs|7 tabs|7-tab" README.md ARCHITECTURE.md docs/`
Expected: fix any hits that describe the CURRENT app (leave historical audit/plan documents untouched — they describe their own moment).

- [ ] **Step 4: Run the gate and commit**

Run: `npm run typecheck && npm test && npm run lint` (unchanged code — belt and braces).

```bash
git add README.md ARCHITECTURE.md
git commit -m "docs: record the 6-tab layout after the Settings gear move

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

(Skill-file changes live outside the repo — no git action for them.)

- [ ] **Step 5: Owner device smoke (Expo Go, light AND dark) — feature is not done until this passes**

1. Today header shows the gear, right-aligned, tappable; VoiceOver reads "Open settings".
2. Gear opens Settings with a themed header + back button; back returns to Today.
3. Tab bar shows 6 items with comfortable spacing; AI tab still shows the trade nickname.
4. Header Save: dimmed on open; edit any field → turns accent; tap → persists (leave and reopen to confirm) and dims again; VoiceOver reads "Save settings" with the disabled state.
5. Section order matches Task 2 Step 4's list; Delete Account is the last thing on the page; the mileage-rate field sits inside Pricing defaults and its value still drives the Money → Mileage deduction figure.
6. Dirty guard, back path: change any Settings field → tap back (do NOT tap Save) → Save/Discard alert; "Save" persists (reopen and confirm), "Discard" reverts; no second alert either way.
7. Dirty guard, tab path: change a field → switch to Jobs tab via the tab bar → existing alert still appears.
8. Settings → Subscribe opens PaywallModal (the two-hop getParent).
9. Jobs → a paid job → Review request with no Google link → "Go to Settings" lands on Settings (Today tab).
10. Theme toggle inside Settings still switches the whole app live (and is now above Payment processor).
11. Sign out from Settings: no spurious unsaved-settings alert.

---

## Self-review (done at plan time)

- **Spec coverage:** tab removal ✓ (Task 1 Steps 3-4), gear entry ✓ (Step 5), typed-nav integrity ✓ (Steps 3, 6, 9), header Save ✓ (Task 2 Step 1), account actions last ✓ (Task 2 Step 4), mileage merge ✓ (Task 2 Step 2), Appearance hoist ✓ (Task 2 Step 3), dirty guard both paths ✓ (Task 3), the one deep link ✓ (Task 1 Step 7), docs/skills ✓ (Task 4). No other `navigate("Settings")`/`jumpTo("Settings")` call sites exist (repo-wide grep, 2026-07-31).
- **Placeholder scan:** none.
- **Type consistency:** `Settings: undefined` on `TodayStackParamList` matches `TodayStackScreenProps<'Settings'>` (Task 1 Step 6) and the `navigate("Today", { screen: "Settings" })` params (Task 1 Step 7). Task 2's `dirty` check uses the same `settingsEqual(s, savedSnapshot)` the Task 3 guard relies on — one source of truth for "unsaved".
