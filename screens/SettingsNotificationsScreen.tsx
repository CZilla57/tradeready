// screens/SettingsNotificationsScreen.tsx
import React, { useMemo, useState } from "react";
import { View, Text, TextInput, ScrollView, TouchableOpacity, Switch, StyleSheet, KeyboardAvoidingView, Platform } from "react-native";
import { Ionicons } from "@expo/vector-icons";
import { useSettingsDraft } from "../hooks/useSettingsDraft";
import { SettingsField as Field } from "../components/SettingsField";
import { KeyboardDoneBar } from "../components/KeyboardDoneBar";
import { DEFAULT_CONFIRM_TEMPLATE, DEFAULT_ON_MY_WAY_TEMPLATE } from "../utils/appointmentTemplates";
import { useTheme } from "../hooks/useTheme";
import { spacing, radius, fontSize, fonts, layout, type ColorScheme, type ShadowScheme } from "../utils/theme";
import type { Settings } from "../types/models";
import type { TodayStackScreenProps } from "../types/navigation";

/**
 * Folds any notification-rule box that is still being edited (a pending
 * draft, keyed by rule index, holding raw typed text) into `settings.rules`,
 * so saving while a field is focused persists what's typed instead of the
 * last-committed number. Mirrors commitRule's parse/normalize exactly:
 * an empty or non-numeric draft parses to NaN, and NaN (or anything < 1)
 * falls back to 1 — the same fallback commitRule itself commits, not the
 * previously-committed rule.days. Pure, so it can be applied to either the
 * live `s`/`ruleDrafts` state (handleSave, `dirty`) or the ref mirrors read
 * by the once-registered blur/beforeRemove guards.
 */
function applyRuleDrafts(settings: Settings, drafts: Record<number, string>): Settings {
  if (Object.keys(drafts).length === 0) return settings;
  const rules = settings.rules.map((rule, i) => {
    const draft = drafts[i];
    if (draft === undefined) return rule;
    const parsed = parseInt(draft, 10);
    return { days: Number.isNaN(parsed) || parsed < 1 ? 1 : parsed };
  });
  return { ...settings, rules };
}

export default function SettingsNotificationsScreen({ navigation }: TodayStackScreenProps<'SettingsNotifications'>) {
  const { colors, shadow } = useTheme();
  const styles = useMemo(() => createStyles(colors, shadow), [colors, shadow]);
  // While a notification-rule box is being edited we keep its raw text here so it
  // can be empty/intermediate; the numeric model is committed on blur (see commitRule).
  const [ruleDrafts, setRuleDrafts] = useState<Record<number, string>>({});
  const { s, setS, update } = useSettingsDraft(navigation, {
    // Folds any notification-rule box still being edited into rules, so
    // saving while a field is focused persists what's typed (see
    // applyRuleDrafts). The hook reads this through a ref, so the closure
    // over ruleDrafts is always current.
    flush: (settings) => applyRuleDrafts(settings, ruleDrafts),
    // The flushed rules are already committed into the saved draft; the raw
    // text drafts are stale now.
    onSaved: () => setRuleDrafts({}),
  });
  if (!s) return null;

  // Keep only the raw text while typing so the box can be emptied to enter a new
  // number; the value is normalized to a number on blur (commitRule).
  function updateRule(index: number, text: string) {
    setRuleDrafts(prev => ({ ...prev, [index]: text.replace(/[^0-9]/g, "") }));
  }

  function commitRule(index: number) {
    const draft = ruleDrafts[index];
    if (draft === undefined) return;
    const parsed = parseInt(draft, 10);
    const days = Number.isNaN(parsed) || parsed < 1 ? 1 : parsed;
    setS(prev => {
      if (!prev) return prev;
      const rules = [...prev.rules];
      rules[index] = { days };
      return { ...prev, rules };
    });
    setRuleDrafts(prev => {
      const next = { ...prev };
      delete next[index];
      return next;
    });
  }

  function addRule() {
    setRuleDrafts({});
    setS(prev => prev ? { ...prev, rules: [...prev.rules, { days: 7 }] } : prev);
  }

  function removeRule(index: number) {
    setRuleDrafts({});
    setS(prev => {
      if (!prev) return prev;
      return { ...prev, rules: prev.rules.filter((_, i) => i !== index) };
    });
  }

  return (
    <View style={styles.container}>
      <KeyboardAvoidingView behavior={Platform.OS === "ios" ? "padding" : undefined} style={{ flex: 1 }}>
        <ScrollView contentContainerStyle={styles.scroll} showsVerticalScrollIndicator={false} keyboardShouldPersistTaps="handled" keyboardDismissMode="on-drag">
          <Text style={styles.ruleSubtitle}>Get notified when an invoice is this many days past due:</Text>
          {s.rules.map((rule, i) => (
            <View key={i} style={styles.ruleRow}>
              <TextInput style={styles.ruleInput} value={ruleDrafts[i] !== undefined ? ruleDrafts[i] : String(rule.days)} onChangeText={(v) => updateRule(i, v)} onBlur={() => commitRule(i)} keyboardType="number-pad" maxLength={3} inputAccessoryViewID="settingsDone" accessibilityLabel={`Reminder rule ${i + 1}: days past due`} />
              <Text style={styles.ruleSuffix}>days past due</Text>
              <TouchableOpacity onPress={() => removeRule(i)} style={styles.removeBtn} accessibilityRole="button" accessibilityLabel={`Remove reminder rule ${i + 1}`}>
                <Ionicons name="close" size={16} color={colors.danger} />
              </TouchableOpacity>
            </View>
          ))}
          <TouchableOpacity style={styles.addRuleBtn} onPress={addRule} accessibilityRole="button" accessibilityLabel="Add reminder rule">
            <Text style={styles.addRuleBtnText}>+ Add rule</Text>
          </TouchableOpacity>

          <Text style={[styles.ruleSubtitle, { marginTop: spacing.sm }]}>
            Turn those reminders into one-tap outreach: tapping a reminder opens a ready-to-send message for that invoice.
          </Text>
          <View style={styles.card}>
            <View style={styles.toggleRow}>
              <Text style={styles.toggleLabel}>Draft a reminder I can send with one tap</Text>
              <Switch
                value={!!s.autoOutreachEnabled}
                onValueChange={(v) => update("autoOutreachEnabled", v)}
                trackColor={{ true: colors.accent }}
                accessibilityLabel="Draft a reminder I can send with one tap"
              />
            </View>
          </View>

          <View style={styles.card}>
            <View style={styles.toggleRow}>
              <Text style={styles.toggleLabel}>Automatically email overdue reminders</Text>
              <Switch
                value={!!s.autoSendEmailEnabled}
                onValueChange={(v) => update("autoSendEmailEnabled", v)}
                trackColor={{ true: colors.accent }}
                accessibilityLabel="Automatically email overdue reminders"
              />
            </View>
            <Text style={styles.keyNote}>
              When on, TradeReady emails the customer a payment reminder once an invoice passes your earliest reminder age — no tap needed. Sent under your business name; replies come to your email.
            </Text>
          </View>

          <View style={styles.card}>
            <View style={styles.toggleRow}>
              <Text style={styles.toggleLabel}>Appointment reminders</Text>
              <Switch
                value={!!s.appointmentRemindersEnabled}
                onValueChange={(v) => update("appointmentRemindersEnabled", v)}
                trackColor={{ true: colors.accent }}
                accessibilityLabel="Appointment reminders"
              />
            </View>
            <Text style={styles.keyNote}>
              Remind me the evening before a scheduled job to confirm with the customer.
            </Text>
          </View>

          <View style={styles.card}>
            <View style={styles.toggleRow}>
              <Text style={styles.toggleLabel}>Estimate follow-up reminders</Text>
              <Switch
                value={s.estimateFollowUpsEnabled !== false}
                onValueChange={(v) => update("estimateFollowUpsEnabled", v)}
                trackColor={{ true: colors.accent }}
                accessibilityLabel="Estimate follow-up reminders"
              />
            </View>
            <Text style={styles.keyNote}>
              Remind me when an estimate gets no response for 3 days.
            </Text>
          </View>

          <View style={styles.card}>
            <View style={styles.toggleRow}>
              <Text style={styles.toggleLabel}>Auto-invoice completed jobs</Text>
              <Switch
                value={!!s.autoInvoiceOnComplete}
                onValueChange={(v) => update("autoInvoiceOnComplete", v)}
                trackColor={{ true: colors.accent }}
                accessibilityLabel="Auto-invoice completed jobs"
              />
            </View>
            <Text style={styles.keyNote}>
              When you mark a job complete, create the invoice automatically, billing tracked time when the timer was used.
            </Text>
            {!!s.autoInvoiceOnComplete && (
              <>
                <View style={[styles.toggleRow, { marginTop: spacing.sm }]}>
                  <Text style={styles.toggleLabel}>Email it automatically</Text>
                  <Switch
                    value={!!s.autoEmailInvoiceOnComplete}
                    onValueChange={(v) => update("autoEmailInvoiceOnComplete", v)}
                    trackColor={{ true: colors.accent }}
                    accessibilityLabel="Email the auto-created invoice automatically"
                  />
                </View>
                <Text style={styles.keyNote}>
                  Skip the send screen — the invoice is emailed to the customer within about 15 minutes, with a payment link when one can be made. If the customer has no email on file, the send screen opens instead.
                </Text>
              </>
            )}
          </View>

          <Text style={[styles.ruleSubtitle, { marginTop: spacing.sm }]}>Message templates</Text>
          <View style={styles.card}>
            <Field
              label="Confirmation message"
              value={s.appointmentConfirmTemplate ?? DEFAULT_CONFIRM_TEMPLATE}
              onChangeText={(v) => update("appointmentConfirmTemplate", v)}
              multiline
              autoCapitalize="sentences"
              colors={colors}
            />
            <Text style={styles.keyNote}>
              Available: {"{customerName}"}, {"{businessName}"}, {"{date}"}, {"{time}"}, {"{address}"}
            </Text>
          </View>
          <View style={styles.card}>
            <Field
              label="On-my-way message"
              value={s.onMyWayTemplate ?? DEFAULT_ON_MY_WAY_TEMPLATE}
              onChangeText={(v) => update("onMyWayTemplate", v)}
              multiline
              autoCapitalize="sentences"
              colors={colors}
            />
            <Text style={styles.keyNote}>
              Available: {"{customerName}"}, {"{businessName}"}, {"{date}"}, {"{time}"}, {"{address}"}
            </Text>
          </View>
        </ScrollView>
      </KeyboardAvoidingView>
      {/* Serves the number-pad reminder-rule inputs. */}
      <KeyboardDoneBar nativeID="settingsDone" />
    </View>
  );
}

function createStyles(colors: ColorScheme, shadow: ShadowScheme) {
  return StyleSheet.create({
    container: { flex: 1, backgroundColor: colors.background },
    scroll: { padding: spacing.md, paddingBottom: 60, ...layout.contentColumn },
    card: { backgroundColor: colors.surface, borderRadius: radius.lg, padding: spacing.md, marginBottom: spacing.sm, ...shadow.card },
    ruleSubtitle: { fontFamily: fonts.bodyRegular, fontSize: fontSize.sm, color: colors.textSecondary, marginBottom: spacing.sm },
    ruleRow: { flexDirection: "row", alignItems: "center", backgroundColor: colors.surface, borderRadius: radius.md, padding: spacing.sm, marginBottom: spacing.sm, ...shadow.card },
    ruleInput: { fontFamily: fonts.bodyRegular, width: 56, height: 36, backgroundColor: colors.background, borderRadius: radius.sm, textAlign: "center", fontSize: fontSize.md, color: colors.textPrimary, borderWidth: StyleSheet.hairlineWidth, borderColor: colors.border, marginRight: spacing.sm },
    ruleSuffix: { fontFamily: fonts.bodyRegular, flex: 1, fontSize: fontSize.sm, color: colors.textSecondary },
    removeBtn: { padding: spacing.sm },
    addRuleBtn: { paddingVertical: spacing.sm, alignItems: "center", borderRadius: radius.md, borderWidth: 1, borderColor: colors.border, borderStyle: "dashed", marginBottom: spacing.sm },
    addRuleBtnText: { fontFamily: fonts.bodyMedium, fontSize: fontSize.sm, color: colors.accent },
    toggleRow: { flexDirection: "row", alignItems: "center", justifyContent: "space-between" },
    toggleLabel: { fontFamily: fonts.bodyRegular, fontSize: fontSize.md, color: colors.textPrimary },
    keyNote: { fontFamily: fonts.bodyRegular, fontSize: fontSize.xs, color: colors.textMuted, marginTop: 6 },
  });
}
