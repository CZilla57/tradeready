// components/NavHeader.tsx
// A flat JS header used as native-stack's custom `header` on sub-screens, so
// their back button and any action buttons are plain React (not native
// headerLeft/headerRight items) and therefore don't get the un-removable iOS 26
// "Liquid Glass" capsule react-native-screens forces onto native header buttons.
// Renders on the screen background like the Today tab and the tab home screens.
//
// It honors each screen's existing options: `headerLeft` (rendered instead of
// the default back chevron — e.g. a modal's Cancel button), `headerRight`, and
// `title`/`headerTitle`. Title is shown only when a screen set one explicitly,
// so untitled modals show just the controls.

import React, { useMemo } from "react";
import { View, Text, TouchableOpacity, StyleSheet } from "react-native";
import { Ionicons } from "@expo/vector-icons";
import { useSafeAreaInsets } from "react-native-safe-area-context";
import { getHeaderTitle } from "@react-navigation/elements";
import type { NativeStackHeaderProps } from "@react-navigation/native-stack";
import { spacing, fontSize, fonts, layout, type ColorScheme } from "../utils/theme";
import { useTheme } from "../hooks/useTheme";

export function NavHeader({ navigation, route, options, back }: NativeStackHeaderProps) {
  const insets = useSafeAreaInsets();
  const { colors } = useTheme();
  const styles = useMemo(() => createStyles(colors), [colors]);

  const tintColor = colors.accent;
  const hasExplicitTitle = options.headerTitle !== undefined || options.title !== undefined;
  const title = hasExplicitTitle ? getHeaderTitle(options, route.name) : "";

  const left = options.headerLeft
    ? options.headerLeft({ tintColor, canGoBack: !!back })
    : back
      ? (
        <TouchableOpacity
          onPress={navigation.goBack}
          hitSlop={{ top: 8, bottom: 8, left: 8, right: 8 }}
          style={styles.backBtn}
          accessibilityRole="button"
          accessibilityLabel="Back"
        >
          <Ionicons name="chevron-back" size={26} color={colors.accent} />
        </TouchableOpacity>
      )
      : null;

  const right = options.headerRight ? options.headerRight({ tintColor, canGoBack: !!back }) : null;

  return (
    <View style={[styles.header, { paddingTop: insets.top + spacing.sm }]}>
      <View style={styles.left}>
        {left}
        {title ? <Text style={styles.title} numberOfLines={1}>{title}</Text> : null}
      </View>
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
      paddingHorizontal: spacing.md,
      paddingBottom: spacing.sm,
      backgroundColor: colors.background,
      ...layout.contentColumn,
    },
    left: { flexDirection: "row", alignItems: "center", flex: 1, marginRight: spacing.sm },
    backBtn: { minWidth: 32, minHeight: 32, justifyContent: "center", marginRight: 2 },
    title: {
      fontFamily: fonts.display,
      fontSize: fontSize.lg,
      color: colors.textPrimary,
      flexShrink: 1,
    },
    right: { flexDirection: "row", alignItems: "center" },
  });
}
