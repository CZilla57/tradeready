// components/money/MoneySection.tsx
// Collapsible group header for the Money overview — the screen stacks a lot
// of analytics cards, and sectioning keeps the daily glance short while the
// deeper cards stay one tap away. Expansion state is per-session on purpose
// (no persisted key): defaults re-assert the "short glance" on next launch.

import React, { useState } from "react";
import { View, Text, TouchableOpacity, StyleSheet } from "react-native";
import { Ionicons } from "@expo/vector-icons";
import { fonts, spacing } from "../../utils/theme";
import { useTheme } from "../../hooks/useTheme";

interface MoneySectionProps {
  title: string;
  defaultExpanded?: boolean;
  children: React.ReactNode;
}

export function MoneySection({ title, defaultExpanded = false, children }: MoneySectionProps) {
  const { colors } = useTheme();
  const [expanded, setExpanded] = useState<boolean>(defaultExpanded);

  return (
    <View>
      <TouchableOpacity
        style={styles.header}
        onPress={() => setExpanded((e) => !e)}
        activeOpacity={0.7}
        accessibilityRole="button"
        accessibilityLabel={`${title} section`}
        accessibilityState={{ expanded }}
      >
        <Text
          style={[styles.title, { color: colors.textSecondary }]}
          maxFontSizeMultiplier={1.4}
        >
          {title}
        </Text>
        <Ionicons
          name={expanded ? "chevron-up" : "chevron-down"}
          size={16}
          color={colors.textSecondary}
        />
      </TouchableOpacity>
      {expanded ? children : null}
    </View>
  );
}

const styles = StyleSheet.create({
  header: {
    flexDirection: "row",
    alignItems: "center",
    justifyContent: "space-between",
    paddingHorizontal: spacing.lg,
    paddingVertical: spacing.sm,
    marginTop: spacing.xs,
    minHeight: 44,
  },
  title: {
    fontFamily: fonts.mono,
    fontSize: 11,
    textTransform: "uppercase",
    letterSpacing: 0.8,
  },
});
