// components/KeyboardDoneBar.tsx
// Single home for the iOS keyboard "Done" accessory bar (generalizes the
// OnboardingScreen rate-input precedent, 2026-07-14). iOS pad keyboards
// (decimal-pad, number-pad, numeric, phone-pad) have no return key, and
// multiline inputs use return for newlines — without this bar those
// keyboards have no way to be dismissed. Android keyboards carry their own
// dismiss/checkmark key, so the bar renders nothing there.
//
// Usage: give the TextInput `inputAccessoryViewID={SOME_ID}` and mount
// `<KeyboardDoneBar nativeID={SOME_ID} />` anywhere in the same screen.
// One bar can serve every input on the screen that references its ID.

import React, { useMemo } from "react";
import {
  InputAccessoryView,
  Keyboard,
  Platform,
  StyleSheet,
  Text,
  TouchableOpacity,
  View,
  type TextInputProps,
} from "react-native";
import { spacing, fontSize } from "../utils/theme";
import type { ColorScheme } from "../utils/theme";
import { useTheme } from "../hooks/useTheme";

// Keyboard types that lack a return key on iOS and therefore need the bar.
const PAD_KEYBOARDS: readonly TextInputProps["keyboardType"][] = [
  "decimal-pad",
  "number-pad",
  "numeric",
  "phone-pad",
];

/** True when an input's keyboard has no built-in way to dismiss on iOS. */
export function needsDoneBar(
  keyboardType?: TextInputProps["keyboardType"],
  multiline?: boolean
): boolean {
  return (
    Platform.OS === "ios" &&
    (multiline === true || PAD_KEYBOARDS.includes(keyboardType))
  );
}

export function KeyboardDoneBar({ nativeID }: { nativeID: string }) {
  const { colors } = useTheme();
  const styles = useMemo(() => createStyles(colors), [colors]);

  if (Platform.OS !== "ios") return null;

  return (
    <InputAccessoryView nativeID={nativeID}>
      <View style={styles.bar}>
        <TouchableOpacity
          onPress={() => Keyboard.dismiss()}
          style={styles.btn}
          accessibilityRole="button"
          accessibilityLabel="Dismiss keyboard"
        >
          <Text style={styles.btnText}>Done</Text>
        </TouchableOpacity>
      </View>
    </InputAccessoryView>
  );
}

function createStyles(colors: ColorScheme) {
  return StyleSheet.create({
    bar: {
      backgroundColor: colors.surface,
      borderTopWidth: StyleSheet.hairlineWidth,
      borderTopColor: colors.border,
      flexDirection: "row",
      justifyContent: "flex-end",
      paddingHorizontal: spacing.md,
      paddingVertical: spacing.xs,
    },
    btn: { paddingVertical: 6, paddingHorizontal: 10 },
    btnText: { color: colors.accent, fontSize: fontSize.md, fontWeight: "600" },
  });
}
