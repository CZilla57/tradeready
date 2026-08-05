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
