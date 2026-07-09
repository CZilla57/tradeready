// components/Field.tsx
// Single home for the labelled text input (roadmap #? — replaces 6 divergent
// `Field` copies across the Add/Edit/Onboarding/Settings screens).
//
// The baseline look (surface fill, 44pt height, hairline border) matches the
// four Add/Edit screens verbatim, so those migrate with zero visual change.
// Onboarding (taller, shadowed, bolder label) and Settings (background-filled
// input for card contrast) keep their intentional looks by passing the
// containerStyle / labelStyle / inputStyle escape hatches — inputStyle is
// applied last so it wins over the baseline and the multiline override.
//
// autoCapitalize defaults smartly: email keyboards get "none", everything else
// "words" (good for names, titles, addresses). Pass the prop to override.

import React, { useMemo } from "react";
import {
  View,
  Text,
  TextInput,
  StyleSheet,
  type TextInputProps,
  type StyleProp,
  type ViewStyle,
  type TextStyle,
} from "react-native";
import { spacing, radius, fontSize } from "../utils/theme";
import type { ColorScheme, ShadowScheme } from "../utils/theme";
import { useTheme } from "../hooks/useTheme";

type FieldProps = {
  label: string;
  value: string;
  onChangeText: (text: string) => void;
  placeholder?: string;
  keyboardType?: TextInputProps["keyboardType"];
  autoCapitalize?: TextInputProps["autoCapitalize"];
  multiline?: boolean;
  autoFocus?: boolean;
  onBlur?: () => void;
  flex?: boolean;
  containerStyle?: StyleProp<ViewStyle>;
  labelStyle?: StyleProp<TextStyle>;
  inputStyle?: StyleProp<TextStyle>;
};

export default function Field({
  label,
  value,
  onChangeText,
  placeholder,
  keyboardType,
  autoCapitalize,
  multiline,
  autoFocus,
  onBlur,
  flex,
  containerStyle,
  labelStyle,
  inputStyle,
}: FieldProps) {
  const { colors, shadow } = useTheme();
  const styles = useMemo(() => createStyles(colors, shadow), [colors, shadow]);

  const cap =
    autoCapitalize ?? (keyboardType === "email-address" ? "none" : "words");

  return (
    <View style={[styles.fieldGroup, flex && styles.flex, containerStyle]}>
      <Text style={[styles.label, labelStyle]}>{label}</Text>
      <TextInput
        style={[styles.input, multiline && styles.inputMulti, inputStyle]}
        value={value}
        onChangeText={onChangeText}
        onBlur={onBlur}
        placeholder={placeholder}
        placeholderTextColor={colors.textMuted}
        keyboardType={keyboardType || "default"}
        autoCapitalize={cap}
        autoCorrect={false}
        multiline={multiline}
        numberOfLines={multiline ? 3 : 1}
        autoFocus={autoFocus}
        accessibilityLabel={label}
      />
    </View>
  );
}

function createStyles(colors: ColorScheme, shadow: ShadowScheme) {
  return StyleSheet.create({
    fieldGroup: { marginBottom: spacing.md },
    flex: { flex: 1 },
    label: {
      fontSize: fontSize.sm,
      color: colors.textSecondary,
      marginBottom: 5,
      fontWeight: "500",
    },
    input: {
      backgroundColor: colors.surface,
      borderRadius: radius.md,
      height: 44,
      paddingHorizontal: spacing.md,
      fontSize: fontSize.md,
      color: colors.textPrimary,
      borderWidth: StyleSheet.hairlineWidth,
      borderColor: colors.border,
    },
    inputMulti: {
      height: 88,
      paddingTop: spacing.sm,
      textAlignVertical: "top",
    },
  });
}
