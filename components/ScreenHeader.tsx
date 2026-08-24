// components/ScreenHeader.tsx
// A flat, in-screen header (title + optional right actions) drawn on the screen
// background — the same approach the Today tab uses. Tab home screens render
// this instead of the native navigation header so their action buttons aren't
// wrapped in the iOS 26 "Liquid Glass" capsule that react-native-screens forces
// onto native headerLeft/headerRight items (no JS opt-out; see the project
// note). Handles the top safe-area inset itself.

import React, { useMemo } from "react";
import { View, Text, StyleSheet } from "react-native";
import { useSafeAreaInsets } from "react-native-safe-area-context";
import { spacing, fontSize, fonts, layout, type ColorScheme } from "../utils/theme";
import { useTheme } from "../hooks/useTheme";

interface Props {
  title: string;
  /** Action button(s) shown on the right, e.g. an icon or a text toggle. */
  right?: React.ReactNode;
}

export function ScreenHeader({ title, right }: Props) {
  const insets = useSafeAreaInsets();
  const { colors } = useTheme();
  const styles = useMemo(() => createStyles(colors), [colors]);
  return (
    <View style={[styles.header, { paddingTop: insets.top + spacing.sm }]}>
      <Text style={styles.title} numberOfLines={1}>{title}</Text>
      {right ? <View style={styles.right}>{right}</View> : null}
    </View>
  );
}

function createStyles(colors: ColorScheme) {
  return StyleSheet.create({
    header: {
      flexDirection: "row",
      alignItems: "center",
      justifyContent: "space-between",
      paddingHorizontal: spacing.lg,
      paddingBottom: spacing.sm,
      backgroundColor: colors.background,
      ...layout.contentColumn,
    },
    title: {
      fontFamily: fonts.display,
      fontSize: fontSize.xl,
      color: colors.textPrimary,
      flex: 1,
      marginRight: spacing.sm,
    },
    right: { flexDirection: "row", alignItems: "center" },
  });
}
