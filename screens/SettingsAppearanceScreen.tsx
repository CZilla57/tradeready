// screens/SettingsAppearanceScreen.tsx
// Appearance is an IMMEDIATE-action page: setTheme persists on tap via
// ThemeContext (__themePreference), never through the Settings draft.
import React, { useMemo } from "react";
import { View, Text, ScrollView, StyleSheet, TouchableOpacity } from "react-native";
import { useSettingsTabPop } from "../hooks/useSettingsDraft";
import { useTheme } from "../hooks/useTheme";
import { spacing, radius, fontSize, fonts, layout, type ColorScheme, type ShadowScheme } from "../utils/theme";
import type { TodayStackScreenProps } from "../types/navigation";

export default function SettingsAppearanceScreen({ navigation }: TodayStackScreenProps<'SettingsAppearance'>) {
  const { colors, shadow, preference, setTheme } = useTheme();
  const styles = useMemo(() => createStyles(colors, shadow), [colors, shadow]);
  useSettingsTabPop(navigation);

  return (
    <View style={styles.container}>
      <ScrollView contentContainerStyle={styles.scroll} showsVerticalScrollIndicator={false}>
        <View style={styles.card}>
          <Text style={styles.providerHint}>Choose how TradeReady looks on your device.</Text>
          <View style={styles.providerGrid}>
            {([{ key: "light", label: "Light" }, { key: "system", label: "System" }, { key: "dark", label: "Dark" }] as const).map((opt) => (
              <TouchableOpacity
                key={opt.key}
                style={[styles.providerBtn, preference === opt.key && styles.providerBtnActive]}
                onPress={() => setTheme(opt.key)}
                accessibilityRole="radio"
                accessibilityLabel={`${opt.label} appearance`}
                accessibilityState={{ selected: preference === opt.key }}
              >
                <Text style={[styles.providerLabel, preference === opt.key && styles.providerLabelActive]}>{opt.label}</Text>
              </TouchableOpacity>
            ))}
          </View>
        </View>
      </ScrollView>
    </View>
  );
}

function createStyles(colors: ColorScheme, shadow: ShadowScheme) {
  return StyleSheet.create({
    container: { flex: 1, backgroundColor: colors.background },
    scroll: { padding: spacing.md, paddingBottom: 60, ...layout.contentColumn },
    card: { backgroundColor: colors.surface, borderRadius: radius.lg, padding: spacing.md, marginBottom: spacing.sm, ...shadow.card },
    providerGrid: { flexDirection: "row", flexWrap: "wrap", gap: 8, marginBottom: spacing.sm },
    providerBtn: { paddingHorizontal: 14, paddingVertical: 8, borderRadius: radius.full, borderWidth: 1, borderColor: colors.border, backgroundColor: colors.surface },
    providerBtnActive: { backgroundColor: colors.accentBg, borderColor: colors.accent },
    providerLabel: { fontFamily: fonts.bodyMedium, fontSize: fontSize.sm, color: colors.textSecondary },
    providerLabelActive: { fontFamily: fonts.bodySemiBold, color: colors.accent },
    providerHint: { fontFamily: fonts.bodyRegular, fontSize: fontSize.sm, color: colors.textSecondary, marginBottom: spacing.sm },
  });
}
