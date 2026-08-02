// components/SearchField.tsx
// The one search input. Jobs, Invoices, and Customers each grew their own
// (icon-less 40pt, icon-less shadowed, icon+border 44pt) — this replaces all
// three so search looks and behaves identically everywhere: leading icon,
// 44pt touch height, themed surface + border.

import React from "react";
import { View, TextInput, StyleSheet } from "react-native";
import { Ionicons } from "@expo/vector-icons";
import { useTheme } from "../hooks/useTheme";
import { spacing, radius, fontSize, fonts } from "../utils/theme";

interface SearchFieldProps {
  value: string;
  onChangeText: (text: string) => void;
  placeholder: string;
  accessibilityLabel: string;
  /** Focus on mount — for screens whose whole point is the search box. */
  autoFocus?: boolean;
}

export function SearchField({ value, onChangeText, placeholder, accessibilityLabel, autoFocus }: SearchFieldProps) {
  const { colors } = useTheme();
  return (
    <View style={[styles.wrap, { backgroundColor: colors.surface, borderColor: colors.border }]}>
      <Ionicons name="search" size={16} color={colors.textMuted} style={styles.icon} />
      <TextInput
        style={[styles.input, { color: colors.textPrimary }]}
        placeholder={placeholder}
        placeholderTextColor={colors.textMuted}
        value={value}
        onChangeText={onChangeText}
        autoCorrect={false}
        clearButtonMode="while-editing"
        returnKeyType="search"
        autoFocus={autoFocus}
        accessibilityLabel={accessibilityLabel}
        maxFontSizeMultiplier={1.4}
      />
    </View>
  );
}

const styles = StyleSheet.create({
  wrap: {
    flexDirection: "row",
    alignItems: "center",
    borderRadius: radius.md,
    paddingHorizontal: spacing.md,
    borderWidth: 1,
  },
  icon: {
    marginRight: spacing.sm,
  },
  input: {
    fontFamily: fonts.bodyRegular,
    flex: 1,
    // minHeight (not height) so larger accessibility text grows the field
    // instead of clipping inside it — same pattern as components/Field.tsx.
    minHeight: 44,
    fontSize: fontSize.md,
  },
});
