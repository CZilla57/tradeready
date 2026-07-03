// screens/SettingsScreen.js
// Business info, payment processor selection, and notification rules.
// All saved to AsyncStorage so they persist between app launches.

import React, { useState, useEffect } from "react";
import {
  View,
  Text,
  TextInput,
  ScrollView,
  TouchableOpacity,
  StyleSheet,
  Alert,
} from "react-native";
import { SafeAreaView } from "react-native-safe-area-context";
import { loadSettings, saveSettings, clearSampleData } from "../utils/storage";
import { supabase } from "../utils/supabase";
import { Button, SectionHeader, Divider } from "../components/UI";
import { TRADE_TYPES } from "../utils/pricingEngine";
import { colors, spacing, radius, fontSize, shadow } from "../utils/theme";

function formatPhone(raw) {
  const digits = raw.replace(/\D/g, "").slice(0, 10);
  if (digits.length <= 3) return digits;
  if (digits.length <= 6) return `(${digits.slice(0, 3)}) ${digits.slice(3)}`;
  return `(${digits.slice(0, 3)}) ${digits.slice(3, 6)}-${digits.slice(6)}`;
}

const PROVIDERS = [
  { id: "stripe", label: "Stripe", hint: "Paste your Stripe Secret Key (starts with sk_)" },
  { id: "square", label: "Square", hint: "Paste your Square Access Token" },
  { id: "paypal", label: "PayPal", hint: "Paste your PayPal Client ID" },
  { id: "venmo", label: "Venmo", hint: "Enter your Venmo username" },
  { id: "quickbooks", label: "QuickBooks", hint: "Enter your QuickBooks Company ID" },
  { id: "custom", label: "Custom URL", hint: "Paste your payment page URL" },
];

export default function SettingsScreen() {
  const [s, setS] = useState(null);
  const [saving, setSaving] = useState(false);

  useEffect(() => {
    loadSettings().then(setS);
  }, []);

  function update(field, value) {
    setS((prev) => ({ ...prev, [field]: value }));
  }

  function updateRule(index, days) {
    const rules = [...s.rules];
    rules[index] = { days: parseInt(days) || 1 };
    setS((prev) => ({ ...prev, rules }));
  }

  function addRule() {
    setS((prev) => ({ ...prev, rules: [...prev.rules, { days: 7 }] }));
  }

  function removeRule(index) {
    const rules = s.rules.filter((_, i) => i !== index);
    setS((prev) => ({ ...prev, rules }));
  }

  async function handleSave() {
    setSaving(true);
    await saveSettings(s);
    setSaving(false);
    Alert.alert("Saved", "Your settings have been saved.");
  }

  if (!s) return null;

  const selectedProvider = PROVIDERS.find((p) => p.id === s.provider);

  return (
    <SafeAreaView style={styles.container} edges={["bottom"]}>
      <ScrollView
        contentContainerStyle={styles.scroll}
        showsVerticalScrollIndicator={false}
        keyboardShouldPersistTaps="handled"
        automaticallyAdjustKeyboardInsets
      >

        {/* Business info */}
        <SectionHeader title="Your business" />
        <View style={styles.card}>
          <Field label="Business name" value={s.businessName} onChange={(v) => update("businessName", v)} />
          <Field label="Your name" value={s.contactName} onChange={(v) => update("contactName", v)} />
          <Field label="Phone" value={s.phone} onChange={(v) => update("phone", formatPhone(v))} keyboardType="phone-pad" />
          <Field label="Email" value={s.email} onChange={(v) => update("email", v)} keyboardType="email-address" />
          <Field label="Payment instructions" value={s.paymentNotes} onChange={(v) => update("paymentNotes", v)} multiline autoCapitalize="sentences" />

          {/* Trade type */}
          <Text style={[styles.fieldLabel, { marginTop: spacing.sm }]}>Your trade</Text>
          <View style={styles.tradeGrid}>
            {TRADE_TYPES.map((t) => (
              <TouchableOpacity
                key={t.id}
                style={[styles.tradeBtn, s.trade === t.id && styles.tradeBtnActive]}
                onPress={() => update("trade", t.id)}
              >
                <Text style={[styles.tradeLabel, s.trade === t.id && styles.tradeLabelActive]}>
                  {t.label}
                </Text>
              </TouchableOpacity>
            ))}
          </View>
        </View>

        <Divider />

        {/* Pricing defaults */}
        <SectionHeader title="Pricing defaults" />
        <Text style={styles.ruleSubtitle}>
          These pre-fill your estimate calculator. You can always override them per job.
        </Text>
        <View style={styles.card}>
          <Field label="Your hourly labor rate ($)" value={String(s.laborRate || "")} onChange={(v) => update("laborRate", parseFloat(v) || 0)} keyboardType="decimal-pad" />
          <Field label="Material markup (%)" value={String(s.materialMarkup || "")} onChange={(v) => update("materialMarkup", parseFloat(v) || 0)} keyboardType="decimal-pad" />
          <Field label="Overhead % (insurance, truck, tools)" value={String(s.overheadPercent || "")} onChange={(v) => update("overheadPercent", parseFloat(v) || 0)} keyboardType="decimal-pad" />
          <Field label="Profit margin %" value={String(s.marginPercent || "")} onChange={(v) => update("marginPercent", parseFloat(v) || 0)} keyboardType="decimal-pad" />
          <Field label="Minimum job fee ($)" value={String(s.minimumJobFee || "")} onChange={(v) => update("minimumJobFee", parseFloat(v) || 0)} keyboardType="decimal-pad" />
          <Field label="Emergency/after-hours multiplier (e.g. 1.5 = 50% extra)" value={String(s.emergencyMultiplier || "")} onChange={(v) => update("emergencyMultiplier", parseFloat(v) || 1)} keyboardType="decimal-pad" />
        </View>

        <Divider />

        {/* Payment processor */}
        <SectionHeader title="Payment processor" />
        <View style={styles.providerGrid}>
          {PROVIDERS.map((p) => (
            <TouchableOpacity
              key={p.id}
              style={[styles.providerBtn, s.provider === p.id && styles.providerBtnActive]}
              onPress={() => update("provider", p.id)}
            >
              <Text style={[styles.providerLabel, s.provider === p.id && styles.providerLabelActive]}>
                {p.label}
              </Text>
            </TouchableOpacity>
          ))}
        </View>
        {selectedProvider && (
          <View style={styles.card}>
            <Text style={styles.providerHint}>{selectedProvider.hint}</Text>
            <TextInput
              style={styles.input}
              value={s.providerKey}
              onChangeText={(v) => update("providerKey", v)}
              placeholder="Paste key or ID here"
              placeholderTextColor={colors.textMuted}
              autoCapitalize="none"
              autoCorrect={false}
              secureTextEntry={s.provider === "stripe" || s.provider === "square" || s.provider === "paypal"}
            />
            <Text style={styles.keyNote}>
              This key is stored only on your device. Never share it with anyone.
            </Text>
          </View>
        )}

        <Divider />

        {/* AI Assistant */}
        <SectionHeader title="AI Assistant" />
        <View style={styles.card}>
          <Text style={styles.providerHint}>
            Groq API key — powers the AI chat tab (estimates, advice, invoice messages).
            Get a free key at console.groq.com — no billing required.
          </Text>
          <TextInput
            style={styles.input}
            value={s.geminiKey}
            onChangeText={(v) => update("geminiKey", v)}
            placeholder="gsk_..."
            placeholderTextColor={colors.textMuted}
            autoCapitalize="none"
            autoCorrect={false}
            secureTextEntry
          />
          <Text style={styles.keyNote}>
            Stored only on your device. Never share this key.
          </Text>
        </View>
        <View style={[styles.card, { marginTop: spacing.sm }]}>
          <Text style={styles.providerHint}>
            Anthropic (Claude) API key — used for AI-generated invoice outreach messages.
            Get one at console.anthropic.com.
          </Text>
          <TextInput
            style={styles.input}
            value={s.anthropicKey}
            onChangeText={(v) => update("anthropicKey", v)}
            placeholder="sk-ant-..."
            placeholderTextColor={colors.textMuted}
            autoCapitalize="none"
            autoCorrect={false}
            secureTextEntry
          />
          <Text style={styles.keyNote}>
            Stored only on your device. Never share this key.
          </Text>
        </View>

        <Divider />

        {/* Notification rules */}
        <SectionHeader title="Notification rules" />
        <Text style={styles.ruleSubtitle}>Get notified when an invoice is this many days past due:</Text>
        {s.rules.map((rule, i) => (
          <View key={i} style={styles.ruleRow}>
            <TextInput
              style={styles.ruleInput}
              value={String(rule.days)}
              onChangeText={(v) => updateRule(i, v)}
              keyboardType="number-pad"
              maxLength={3}
            />
            <Text style={styles.ruleSuffix}>days past due</Text>
            <TouchableOpacity onPress={() => removeRule(i)} style={styles.removeBtn}>
              <Text style={styles.removeBtnText}>✕</Text>
            </TouchableOpacity>
          </View>
        ))}
        <TouchableOpacity style={styles.addRuleBtn} onPress={addRule}>
          <Text style={styles.addRuleBtnText}>+ Add rule</Text>
        </TouchableOpacity>

        <Divider />

        <Button label="Save settings" onPress={handleSave} loading={saving} />

        <TouchableOpacity
          style={styles.clearSampleBtn}
          onPress={() =>
            Alert.alert(
              "Clear sample data",
              "This permanently removes all sample customers, jobs, and invoices. Your own data is not affected.",
              [
                { text: "Cancel", style: "cancel" },
                {
                  text: "Clear sample data",
                  style: "destructive",
                  onPress: async () => {
                    await clearSampleData();
                    Alert.alert("Done", "Sample data has been removed.");
                  },
                },
              ]
            )
          }
        >
          <Text style={styles.clearSampleText}>Clear Sample Data</Text>
        </TouchableOpacity>

        <TouchableOpacity
          style={styles.signOutBtn}
          onPress={() =>
            Alert.alert("Sign out", "Are you sure you want to sign out?", [
              { text: "Cancel", style: "cancel" },
              { text: "Sign out", style: "destructive", onPress: () => supabase.auth.signOut() },
            ])
          }
        >
          <Text style={styles.signOutText}>Sign Out</Text>
        </TouchableOpacity>

      </ScrollView>
    </SafeAreaView>
  );
}

function Field({ label, value, onChange, keyboardType, multiline, autoCapitalize }) {
  const cap = autoCapitalize ?? (keyboardType === "email-address" ? "none" : "words");
  return (
    <View style={styles.fieldGroup}>
      <Text style={styles.fieldLabel}>{label}</Text>
      <TextInput
        style={[styles.input, multiline && styles.inputMultiline]}
        value={value}
        onChangeText={onChange}
        keyboardType={keyboardType || "default"}
        autoCapitalize={cap}
        autoCorrect={false}
        multiline={multiline}
        numberOfLines={multiline ? 3 : 1}
        placeholderTextColor={colors.textMuted}
      />
    </View>
  );
}

const styles = StyleSheet.create({
  container: { flex: 1, backgroundColor: colors.background },
  scroll: { padding: spacing.md, paddingBottom: 60 },
  card: {
    backgroundColor: colors.surface,
    borderRadius: radius.lg,
    padding: spacing.md,
    marginBottom: spacing.sm,
    ...shadow.card,
  },
  fieldGroup: { marginBottom: spacing.sm },
  fieldLabel: { fontSize: fontSize.sm, color: colors.textSecondary, marginBottom: 5, fontWeight: "500" },
  input: {
    backgroundColor: colors.background,
    borderRadius: radius.md,
    height: 44,
    paddingHorizontal: spacing.md,
    fontSize: fontSize.md,
    color: colors.textPrimary,
    borderWidth: StyleSheet.hairlineWidth,
    borderColor: colors.border,
  },
  inputMultiline: { height: 80, paddingTop: spacing.sm, textAlignVertical: "top" },
  providerGrid: {
    flexDirection: "row",
    flexWrap: "wrap",
    gap: 8,
    marginBottom: spacing.sm,
  },
  providerBtn: {
    paddingHorizontal: 14,
    paddingVertical: 8,
    borderRadius: radius.full,
    borderWidth: 1,
    borderColor: colors.border,
    backgroundColor: colors.surface,
  },
  providerBtnActive: {
    backgroundColor: colors.accentBg,
    borderColor: colors.accent,
  },
  providerLabel: { fontSize: fontSize.sm, color: colors.textSecondary },
  providerLabelActive: { color: colors.accent, fontWeight: "600" },
  providerHint: { fontSize: fontSize.sm, color: colors.textSecondary, marginBottom: spacing.sm },
  keyNote: { fontSize: fontSize.xs, color: colors.textMuted, marginTop: 6 },
  ruleSubtitle: { fontSize: fontSize.sm, color: colors.textSecondary, marginBottom: spacing.sm },
  ruleRow: {
    flexDirection: "row",
    alignItems: "center",
    backgroundColor: colors.surface,
    borderRadius: radius.md,
    padding: spacing.sm,
    marginBottom: spacing.sm,
    ...shadow.card,
  },
  ruleInput: {
    width: 56,
    height: 36,
    backgroundColor: colors.background,
    borderRadius: radius.sm,
    textAlign: "center",
    fontSize: fontSize.md,
    color: colors.textPrimary,
    borderWidth: StyleSheet.hairlineWidth,
    borderColor: colors.border,
    marginRight: spacing.sm,
  },
  ruleSuffix: { flex: 1, fontSize: fontSize.sm, color: colors.textSecondary },
  removeBtn: { padding: spacing.sm },
  removeBtnText: { color: colors.danger, fontSize: fontSize.md },
  addRuleBtn: {
    paddingVertical: spacing.sm,
    alignItems: "center",
    borderRadius: radius.md,
    borderWidth: 1,
    borderColor: colors.border,
    borderStyle: "dashed",
    marginBottom: spacing.sm,
  },
  addRuleBtnText: { fontSize: fontSize.sm, color: colors.accent, fontWeight: "500" },
  clearSampleBtn: {
    marginTop: spacing.lg,
    paddingVertical: 14,
    alignItems: "center",
    borderRadius: radius.md,
    borderWidth: 1,
    borderColor: colors.border,
    backgroundColor: colors.surface,
  },
  clearSampleText: { color: colors.textSecondary, fontSize: fontSize.md, fontWeight: "500" },
  signOutBtn: {
    marginTop: spacing.sm,
    paddingVertical: 14,
    alignItems: "center",
    borderRadius: radius.md,
    borderWidth: 1,
    borderColor: colors.danger + "50",
    backgroundColor: colors.dangerBg,
  },
  signOutText: { color: colors.danger, fontSize: fontSize.md, fontWeight: "600" },
  tradeGrid: {
    flexDirection: "row", flexWrap: "wrap", gap: 6, marginTop: 4,
  },
  tradeBtn: {
    paddingHorizontal: 12, paddingVertical: 7,
    borderRadius: radius.full, borderWidth: 1, borderColor: colors.border,
    backgroundColor: colors.background,
  },
  tradeBtnActive: { backgroundColor: colors.accentBg, borderColor: colors.accent },
  tradeLabel: { fontSize: fontSize.sm, color: colors.textSecondary },
  tradeLabelActive: { color: colors.accent, fontWeight: "600" },
});
