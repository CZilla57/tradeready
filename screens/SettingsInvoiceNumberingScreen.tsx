// screens/SettingsInvoiceNumberingScreen.tsx
import React, { useMemo } from "react";
import { View, Text, ScrollView, StyleSheet, KeyboardAvoidingView, Platform } from "react-native";
import { useSettingsDraft } from "../hooks/useSettingsDraft";
import { SettingsField as Field } from "../components/SettingsField";
import { normalizeInvoicePrefix } from "../utils/invoiceNumber";
import { useTheme } from "../hooks/useTheme";
import { spacing, radius, fontSize, fonts, layout, type ColorScheme, type ShadowScheme } from "../utils/theme";
import type { TodayStackScreenProps } from "../types/navigation";

export default function SettingsInvoiceNumberingScreen({ navigation }: TodayStackScreenProps<'SettingsInvoiceNumbering'>) {
  const { colors, shadow } = useTheme();
  const styles = useMemo(() => createStyles(colors, shadow), [colors, shadow]);
  const { s, update } = useSettingsDraft(navigation);
  if (!s) return null;

  return (
    <View style={styles.container}>
      <KeyboardAvoidingView behavior={Platform.OS === "ios" ? "padding" : undefined} style={{ flex: 1 }}>
        <ScrollView contentContainerStyle={styles.scroll} showsVerticalScrollIndicator={false} keyboardShouldPersistTaps="handled" keyboardDismissMode="on-drag">
          <View style={styles.card}>
            <Field
              label="Invoice number prefix"
              value={s.invoicePrefix ?? ""}
              onChangeText={(v: string) => update("invoicePrefix", v)}
              placeholder="INV"
              autoCapitalize="characters"
              colors={colors}
            />
            <Field
              label="Numbers start at"
              value={s.invoiceStartNumber != null ? String(s.invoiceStartNumber) : ""}
              onChangeText={(v: string) => {
                const parsed = parseInt(v.replace(/[^0-9]/g, ""), 10);
                update("invoiceStartNumber", Number.isNaN(parsed) ? undefined : parsed);
              }}
              placeholder="1"
              keyboardType="number-pad"
              colors={colors}
            />
            <Text style={styles.keyNote}>
              Auto-numbers look like {normalizeInvoicePrefix(s.invoicePrefix)}-{String(Math.max(1, Math.floor(s.invoiceStartNumber || 1))).padStart(4, "0")}. The starting number only matters until your numbering grows past it — existing invoices keep their numbers.
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
    keyNote: { fontFamily: fonts.bodyRegular, fontSize: fontSize.xs, color: colors.textMuted, marginTop: 6 },
  });
}
