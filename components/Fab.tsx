// components/Fab.tsx
// The one floating add button. Jobs and Invoices each carried an identical
// local copy (text "+" glyph); Customers used a header pill instead — this
// standardizes the add action across all three list screens.

import React from "react";
import { TouchableOpacity, StyleSheet } from "react-native";
import { Ionicons } from "@expo/vector-icons";
import { useTheme } from "../hooks/useTheme";
import { spacing } from "../utils/theme";

interface FabProps {
  onPress: () => void;
  accessibilityLabel: string;
}

export function Fab({ onPress, accessibilityLabel }: FabProps) {
  const { colors } = useTheme();
  return (
    <TouchableOpacity
      style={[styles.fab, { backgroundColor: colors.accent, shadowColor: colors.accent }]}
      onPress={onPress}
      activeOpacity={0.85}
      accessibilityRole="button"
      accessibilityLabel={accessibilityLabel}
    >
      <Ionicons name="add" size={28} color={colors.textOnAccent} />
    </TouchableOpacity>
  );
}

const styles = StyleSheet.create({
  fab: {
    position: "absolute",
    right: spacing.lg,
    bottom: spacing.xl,
    width: 56,
    height: 56,
    borderRadius: 28,
    alignItems: "center",
    justifyContent: "center",
    shadowOffset: { width: 0, height: 4 },
    shadowOpacity: 0.35,
    shadowRadius: 8,
    elevation: 6,
  },
});
