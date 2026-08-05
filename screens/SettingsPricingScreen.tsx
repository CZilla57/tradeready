// screens/SettingsPricingScreen.tsx
import React, { useMemo } from "react";
import { View, Text, ScrollView, StyleSheet, KeyboardAvoidingView, Platform } from "react-native";
import { useSettingsDraft } from "../hooks/useSettingsDraft";
import { SettingsField as Field } from "../components/SettingsField";
import { validateLaborRate } from "../utils/settingsValidation";
import { markSetupTaskDone } from "../utils/setupChecklist";
import { useTheme } from "../hooks/useTheme";
import { spacing, radius, fontSize, fonts, layout, type ColorScheme, type ShadowScheme } from "../utils/theme";
import type { TodayStackScreenProps } from "../types/navigation";

export default function SettingsPricingScreen({ navigation }: TodayStackScreenProps<'SettingsPricing'>) {
  const { colors, shadow } = useTheme();
  const styles = useMemo(() => createStyles(colors, shadow), [colors, shadow]);
  const { s, update } = useSettingsDraft(navigation, {
    validate: (flushed) => validateLaborRate(flushed.laborRate),
    // Saving the Pricing page is the completion signal for the checklist's
    // "review your pricing defaults" task (moved from any-Settings-save at
    // the 2026-08-05 split — see the spec).
    onSaved: () => markSetupTaskDone("rate"),
  });
  if (!s) return null;

  return (
    <View style={styles.container}>
      <KeyboardAvoidingView behavior={Platform.OS === "ios" ? "padding" : undefined} style={{ flex: 1 }}>
        <ScrollView contentContainerStyle={styles.scroll} showsVerticalScrollIndicator={false} keyboardShouldPersistTaps="handled" keyboardDismissMode="on-drag">
          <Text style={styles.ruleSubtitle}>These pre-fill your estimate calculator. You can always override them per job.</Text>
          <View style={styles.card}>
            <Field label="Your hourly labor rate ($)" value={String(s.laborRate || "")} onChangeText={(v) => update("laborRate", parseFloat(v) || 0)} keyboardType="decimal-pad" colors={colors} />
            <Field label="Material markup (%)" value={String(s.materialMarkup || "")} onChangeText={(v) => update("materialMarkup", parseFloat(v) || 0)} keyboardType="decimal-pad" colors={colors} />
            <Field label="Overhead % (insurance, truck, tools)" value={String(s.overheadPercent || "")} onChangeText={(v) => update("overheadPercent", parseFloat(v) || 0)} keyboardType="decimal-pad" colors={colors} />
            <Field label="Profit margin %" value={String(s.marginPercent || "")} onChangeText={(v) => update("marginPercent", parseFloat(v) || 0)} keyboardType="decimal-pad" colors={colors} />
            <Field label="Minimum job fee ($)" value={String(s.minimumJobFee || "")} onChangeText={(v) => update("minimumJobFee", parseFloat(v) || 0)} keyboardType="decimal-pad" colors={colors} />
            <Field label="Emergency/after-hours multiplier (e.g. 1.5 = 50% extra)" value={String(s.emergencyMultiplier || "")} onChangeText={(v) => update("emergencyMultiplier", parseFloat(v) || 1)} keyboardType="decimal-pad" colors={colors} />
            <Field label="Mileage rate ($ per mile)" value={String(s.mileageRate ?? 0.70)} onChangeText={(v) => update("mileageRate", parseFloat(v) || 0)} keyboardType="decimal-pad" colors={colors} />
            <Text style={styles.keyNote}>
              Used to estimate the tax deduction for logged trips (Money → Mileage). Set to the standard mileage rate for your tax year.
            </Text>
          </View>
        </ScrollView>
      </KeyboardAvoidingView>
    </View>
  );
}

function createStyles(colors: ColorScheme, shadow: ShadowScheme) {
  return StyleSheet.create({
    container: { flex: 1, backgroundColor: colors.background },
    scroll: { padding: spacing.md, paddingBottom: 60, ...layout.contentColumn },
    card: { backgroundColor: colors.surface, borderRadius: radius.lg, padding: spacing.md, marginBottom: spacing.sm, ...shadow.card },
    ruleSubtitle: { fontFamily: fonts.bodyRegular, fontSize: fontSize.sm, color: colors.textSecondary, marginBottom: spacing.sm },
    keyNote: { fontFamily: fonts.bodyRegular, fontSize: fontSize.xs, color: colors.textMuted, marginTop: 6 },
  });
}
