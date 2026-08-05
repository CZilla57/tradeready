// hooks/useSettingsDraft.tsx
// The Settings subpage draft contract, extracted verbatim from the old
// monolithic SettingsScreen during the 2026-08-05 hub/subpages split
// (docs/superpowers/specs/2026-08-05-settings-subpages-design.md):
// full-Settings draft vs saved snapshot, sticky header Save, tab-switch
// pop, and THE beforeRemove unsaved-edits prompt — one prompt path for
// back, swipe-back, and the tab-switch pop alike.
//
// Form-page conventions: form subpages wrap their scrollable content in
// KeyboardAvoidingView using the iOS-padding pattern
// (behavior={Platform.OS === "ios" ? "padding" : undefined}), never
// automaticallyAdjustKeyboardInsets — that prop accumulated a phantom
// bottom inset on device (endless empty scroll space; beta finding,
// 2026-07-14). Seven form pages share this pattern; subpage authors must
// not "simplify" it back to automaticallyAdjustKeyboardInsets.
import React, { useEffect, useLayoutEffect, useRef, useState } from "react";
import { Alert, Text, TouchableOpacity } from "react-native";
import { loadSettings, saveSettings } from "../utils/storage";
import { syncNotifications } from "../utils/notifications";
import { reportError } from "../utils/analytics";
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
    try {
      await saveSettings(flushed);
      syncNotifications();
      setS(flushed);
      setSavedSnapshot(flushed);
      await optsRef.current.onSaved?.(flushed);
    } catch (err: unknown) {
      // A rejected write used to leave `saving` stuck true — header Save
      // permanently disabled — and surfaced nothing. Keep the draft dirty
      // (no snapshot reset happened on the saveSettings path), tell the
      // user, and let them retry. A failure thrown by onSaved AFTER the
      // write landed also arrives here; the alert is conservative in that
      // rare case, but the snapshot was already reset so a retry is a
      // harmless no-op save.
      reportError(err, { context: "settingsSave" });
      Alert.alert("Couldn't save", "Your changes weren't saved. Please try again.");
      return;
    } finally {
      setSaving(false);
    }
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
