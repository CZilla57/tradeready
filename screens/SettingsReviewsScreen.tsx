// screens/SettingsReviewsScreen.tsx
import React, { useMemo } from "react";
import { View, Text, ScrollView, StyleSheet, KeyboardAvoidingView, Platform, Switch } from "react-native";
import { useSettingsDraft } from "../hooks/useSettingsDraft";
import { SettingsField as Field } from "../components/SettingsField";
import { useTheme } from "../hooks/useTheme";
import { spacing, radius, fontSize, fonts, layout, type ColorScheme, type ShadowScheme } from "../utils/theme";
import type { TodayStackScreenProps } from "../types/navigation";

export default function SettingsReviewsScreen({ navigation }: TodayStackScreenProps<'SettingsReviews'>) {
  const { colors, shadow } = useTheme();
  const styles = useMemo(() => createStyles(colors, shadow), [colors, shadow]);
  const { s, update } = useSettingsDraft(navigation);
  if (!s) return null;

  return (
    <View style={styles.container}>
      <KeyboardAvoidingView behavior={Platform.OS === "ios" ? "padding" : undefined} style={{ flex: 1 }}>
        <ScrollView contentContainerStyle={styles.scroll} showsVerticalScrollIndicator={false} keyboardShouldPersistTaps="handled" keyboardDismissMode="on-drag">
          <Text style={styles.ruleSubtitle}>
            Automatically prompt customers for a Google review after you complete a job.
          </Text>
          <View style={styles.card}>
            <View style={styles.toggleRow}>
              <Text style={styles.toggleLabel}>Enable review requests</Text>
              <Switch
                value={s.reviewRequestEnabled}
                onValueChange={(v) => update("reviewRequestEnabled", v)}
                trackColor={{ true: colors.accent }}
                accessibilityLabel="Enable review requests"
              />
            </View>
          </View>
          {s.reviewRequestEnabled && (
            <>
              <View style={styles.card}>
                <Field
                  label="Google review link"
                  value={s.googleReviewLink}
                  onChangeText={(v) => update("googleReviewLink", v)}
                  autoCapitalize="none"
                  colors={colors}
                />
                <Text style={styles.keyNote}>
                  Find this in your Google Business Profile → "Ask for reviews" → copy the link.
                </Text>
              </View>
              <View style={styles.card}>
                <Field
                  label="Delay after job completion (hours)"
                  value={String(s.reviewRequestDelayHours || 3)}
                  onChangeText={(v) => update("reviewRequestDelayHours", parseInt(v) || 3)}
                  keyboardType="number-pad"
                  colors={colors}
                />
              </View>
              <View style={styles.card}>
                <Field
                  label="Message template"
                  value={s.reviewRequestTemplate}
                  onChangeText={(v) => update("reviewRequestTemplate", v)}
                  multiline
                  autoCapitalize="sentences"
                  colors={colors}
                />
                <Text style={styles.keyNote}>
                  Use {"{businessName}"}, {"{customerName}"}, and {"{googleReviewLink}"} as placeholders.
                </Text>
              </View>
            </>
          )}
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
    toggleRow: { flexDirection: "row", alignItems: "center", justifyContent: "space-between" },
    toggleLabel: { fontFamily: fonts.bodyRegular, fontSize: fontSize.md, color: colors.textPrimary },
    keyNote: { fontFamily: fonts.bodyRegular, fontSize: fontSize.xs, color: colors.textMuted, marginTop: 6 },
  });
}
