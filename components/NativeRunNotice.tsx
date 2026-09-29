import React, { useCallback, useEffect, useState } from 'react';
import { View, Text, TouchableOpacity, StyleSheet } from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import { useThemeContext } from '../context/ThemeContext';
import {
  dismissNativeRunWarning,
  getNativeRunNotice,
  subscribeNativeRun,
} from '../utils/nativeRunRuntime';

// E-1 pending notice + E-2 warning (P12-012). The wording below is a
// PLACEHOLDER: the playbook says the owner approves it. It must keep saying
// that (a) empty lists are not lost data while the cloud copy loads, (b)
// settings may be out of date, (c) invoices can be created once it loaded, and
// (d) timer taps, trips and expenses from the widget or Siri are added then.
export const NATIVE_RUN_PENDING_TEXT =
  'Getting your latest data from the cloud. Empty lists are not lost data. ' +
  'Settings such as your business name and rates may be out of date until it finishes. ' +
  'Invoices can be created once the cloud copy has loaded, and timer taps, trips and ' +
  'expenses from the widget or Siri are added then.';
export const NATIVE_RUN_WARNING_TEXT =
  "Changes made in the newer version that hadn't finished uploading may be missing. " +
  'Open the newer version again to upload them, or contact support.';

export function NativeRunNotice() {
  const { colors } = useThemeContext();
  const insets = useSafeAreaInsets();
  const [state, setState] = useState({ pending: false, warn: false });

  const refresh = useCallback(() => {
    getNativeRunNotice().then(setState).catch(() => {});
  }, []);

  useEffect(() => {
    refresh();
    return subscribeNativeRun(refresh);
  }, [refresh]);

  if (!state.pending && !state.warn) return null;

  return (
    <View
      style={[styles.container, { paddingTop: insets.top + 4, backgroundColor: colors.warningBg, borderBottomColor: colors.warning }]}
      testID="native-run-notice"
    >
      {state.pending && (
        <Text style={[styles.text, { color: colors.textPrimary }]} maxFontSizeMultiplier={1.3}>
          {NATIVE_RUN_PENDING_TEXT}
        </Text>
      )}
      {state.warn && (
        <View style={styles.row}>
          <Text style={[styles.text, styles.flex, { color: colors.textPrimary }]} maxFontSizeMultiplier={1.3}>
            {NATIVE_RUN_WARNING_TEXT}
          </Text>
          <TouchableOpacity
            onPress={() => { void dismissNativeRunWarning(); }}
            accessibilityRole="button"
            accessibilityLabel="Dismiss warning"
            style={[styles.button, { backgroundColor: colors.warning }]}
          >
            <Text style={styles.buttonText} maxFontSizeMultiplier={1.3}>OK</Text>
          </TouchableOpacity>
        </View>
      )}
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    position: 'absolute',
    top: 0,
    left: 0,
    right: 0,
    borderBottomWidth: 1,
    zIndex: 998,
    paddingHorizontal: 16,
    paddingBottom: 8,
    gap: 6,
  },
  row: { flexDirection: 'row', alignItems: 'center', gap: 8 },
  flex: { flex: 1 },
  text: { fontSize: 13 },
  button: { paddingHorizontal: 12, paddingVertical: 6, borderRadius: 6 },
  buttonText: { color: '#fff', fontWeight: '600', fontSize: 13 },
});
