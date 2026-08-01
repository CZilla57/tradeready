// components/money/CardScope.tsx
// Tiny mono caption naming a card's data window when the card deliberately
// ignores the Money screen's global date-filter chips — so a card rendered
// under an active "This month" chip can't be misread as filtered. Cards whose
// titles already state their window (Last 6 Months, 12-Month Trend, Tax
// set-aside's period range) don't need one.

import React from "react";
import { Text, StyleSheet } from "react-native";
import { fonts, spacing } from "../../utils/theme";
import { useTheme } from "../../hooks/useTheme";

interface CardScopeProps {
  label: string;
  /** Render without vertical margins, for placement inside a header row. */
  inline?: boolean;
}

export function CardScope({ label, inline }: CardScopeProps) {
  const { colors } = useTheme();
  return (
    <Text
      style={[styles.caption, !inline && styles.stacked, { color: colors.textSecondary }]}
      maxFontSizeMultiplier={1.4}
    >
      {label}
    </Text>
  );
}

const styles = StyleSheet.create({
  caption: {
    fontFamily: fonts.mono,
    fontSize: 11,
    textTransform: "uppercase",
    letterSpacing: 0.4,
  },
  stacked: {
    // Card titles/header rows carry marginBottom: spacing.md — tuck the
    // caption up under the title, then restore the rhythm below it.
    marginTop: -(spacing.md - spacing.xs),
    marginBottom: spacing.md,
  },
});
