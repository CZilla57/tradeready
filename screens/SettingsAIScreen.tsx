// screens/SettingsAIScreen.tsx
import React, { useMemo, useState } from "react";
import { View, Text, ScrollView, StyleSheet, KeyboardAvoidingView, Platform, Switch, TextInput } from "react-native";
import { useSettingsDraft } from "../hooks/useSettingsDraft";
import { useTheme } from "../hooks/useTheme";
import { spacing, radius, fontSize, fonts, layout, type ColorScheme, type ShadowScheme } from "../utils/theme";
import type { TodayStackScreenProps } from "../types/navigation";

export default function SettingsAIScreen({ navigation }: TodayStackScreenProps<'SettingsAI'>) {
  const { colors, shadow } = useTheme();
  const styles = useMemo(() => createStyles(colors, shadow), [colors, shadow]);
  const { s, update } = useSettingsDraft(navigation);
  const [showAdvanced, setShowAdvanced] = useState(false);
  if (!s) return null;

  return (
    <View style={styles.container}>
      <KeyboardAvoidingView behavior={Platform.OS === "ios" ? "padding" : undefined} style={{ flex: 1 }}>
        <ScrollView contentContainerStyle={styles.scroll} showsVerticalScrollIndicator={false} keyboardShouldPersistTaps="handled" keyboardDismissMode="on-drag">
          <View style={styles.card}>
            <Text style={styles.providerHint}>
              AI features work automatically via our cloud service. Toggle Advanced to use your own API keys instead.
            </Text>
            <View style={styles.toggleRow}>
              <Text style={styles.toggleLabel}>Advanced</Text>
              <Switch
                value={showAdvanced}
                onValueChange={setShowAdvanced}
                trackColor={{ false: colors.border, true: colors.accent }}
                accessibilityLabel="Advanced AI settings"
              />
            </View>
          </View>
          {showAdvanced && (
            <>
              <View style={[styles.card, { marginTop: spacing.sm }]}>
                <Text style={styles.providerHint}>Groq API key — powers the AI chat tab (estimates, advice, invoice messages). Get a free key at console.groq.com — no billing required.</Text>
                <TextInput style={styles.input} value={s.groqKey} onChangeText={(v) => update("groqKey", v)} placeholder="gsk_..." placeholderTextColor={colors.textMuted} autoCapitalize="none" autoCorrect={false} secureTextEntry returnKeyType="done" accessibilityLabel="Groq API key" />
                <Text style={styles.keyNote}>Stored only on your device. Never share this key.</Text>
              </View>
              <View style={[styles.card, { marginTop: spacing.sm }]}>
                <Text style={styles.providerHint}>Anthropic (Claude) API key — used for AI-generated invoice outreach messages. Get one at console.anthropic.com.</Text>
                <TextInput style={styles.input} value={s.anthropicKey} onChangeText={(v) => update("anthropicKey", v)} placeholder="sk-ant-..." placeholderTextColor={colors.textMuted} autoCapitalize="none" autoCorrect={false} secureTextEntry returnKeyType="done" accessibilityLabel="Anthropic API key" />
                <Text style={styles.keyNote}>Stored only on your device. Never share this key.</Text>
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
    providerHint: { fontFamily: fonts.bodyRegular, fontSize: fontSize.sm, color: colors.textSecondary, marginBottom: spacing.sm },
    toggleRow: { flexDirection: "row", alignItems: "center", justifyContent: "space-between" },
    toggleLabel: { fontFamily: fonts.bodyRegular, fontSize: fontSize.md, color: colors.textPrimary },
    keyNote: { fontFamily: fonts.bodyRegular, fontSize: fontSize.xs, color: colors.textMuted, marginTop: 6 },
    input: { fontFamily: fonts.bodyRegular, backgroundColor: colors.background, borderRadius: radius.md, minHeight: 44, paddingHorizontal: spacing.md, fontSize: fontSize.md, color: colors.textPrimary, borderWidth: StyleSheet.hairlineWidth, borderColor: colors.border },
  });
}
