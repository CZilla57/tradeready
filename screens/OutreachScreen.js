// screens/OutreachScreen.js
// Generates AI-powered email and SMS outreach for a specific invoice.
// Uses expo-mail-composer and expo-sms to open the native iOS Mail and
// Messages apps pre-filled with the generated content — no email server needed.

import React, { useState, useEffect, useCallback, useMemo } from "react";
import {
  View,
  Text,
  ScrollView,
  Switch,
  TouchableOpacity,
  StyleSheet,
  Alert,
  ActivityIndicator,
} from "react-native";
import { SafeAreaView } from "react-native-safe-area-context";
import * as Clipboard from "expo-clipboard";
import { composeEmail, composeSMS } from "../utils/messaging";
import { loadInvoices, saveInvoices, loadSettings } from "../utils/storage";
import { getStatus, generateOutreachMessage, resolvePaymentLink, fetchPaymentLink, getProviderKey } from "../utils/invoiceHelpers";
import { formatMoney } from "../utils/format";
import { Badge, Button, Card, Divider } from "../components/UI";
import { spacing, radius, fontSize } from "../utils/theme";
import { useTheme } from '../hooks/useTheme';

const PROVIDER_LABELS = {
  stripe: "Stripe",
  paypal: "PayPal.Me",
  venmo: "Venmo",
  square: "Square",
  custom: "Custom URL",
};

// Returns providers the user has credentials for. Default provider always
// included; Stripe only appears when it IS the default; others appear when a
// key is stored in providerKeys.
function getConfiguredProviders(s) {
  return Object.entries(PROVIDER_LABELS)
    .filter(([id]) => {
      if (id === s.provider) return true;
      if (id === "stripe") return false;
      return !!(s.providerKeys?.[id]);
    })
    .map(([id, label]) => ({ id, label }));
}

export default function OutreachScreen({ route, navigation }) {
  const { colors, shadow } = useTheme();
  const styles = useMemo(() => createStyles(colors, shadow), [colors, shadow]);
  const { invoiceId } = route.params;

  const [invoice, setInvoice] = useState(null);
  const [settings, setSettings] = useState(null);
  const [channel, setChannel] = useState("email");
  const [message, setMessage] = useState("");
  const [subject, setSubject] = useState("");
  const [generating, setGenerating] = useState(false);
  const [generatingLink, setGeneratingLink] = useState(false);
  const [paymentLink, setPaymentLink] = useState("");
  const [paymentPlanEnabled, setPaymentPlanEnabled] = useState(false);
  const [installments, setInstallments] = useState("3");
  const [frequency, setFrequency] = useState("Bi-weekly");
  const [copied, setCopied] = useState(false);
  const [selectedProvider, setSelectedProvider] = useState(null);

  useEffect(() => {
    async function load() {
      const [invoices, s] = await Promise.all([loadInvoices(), loadSettings()]);
      const inv = invoices.find((i) => i.id === invoiceId);
      setInvoice(inv);
      setSettings(s);
      setSelectedProvider(s.provider);
      navigation.setOptions({ title: inv?.customer || "Outreach" });

      // Restore cached payment link so the message can auto-generate immediately
      if (inv?.paymentLinkUrl) {
        setPaymentLink(inv.paymentLinkUrl);
      }
    }
    load();
  }, [invoiceId, navigation]);

  async function handleGenerateLink(providerOverride) {
    const provider = providerOverride ?? selectedProvider;
    setGeneratingLink(true);
    try {
      // When explicitly switching providers, bypass the invoice's cached link —
      // it was generated for a different provider. On initial "Generate" tap,
      // the cache is fine (same provider, same amount).
      const link = providerOverride
        ? await fetchPaymentLink(invoice, provider, getProviderKey(settings, provider))
        : await resolvePaymentLink(invoice, provider, getProviderKey(settings, provider));
      setPaymentLink(link);
      // Persist so the link survives navigation and doesn't get re-created next time
      const allInvoices = await loadInvoices();
      await saveInvoices(
        allInvoices.map((i) =>
          i.id === invoice.id
            ? { ...i, paymentLinkUrl: link, paymentLinkAmount: invoice.amount }
            : i
        )
      );
    } catch (err) {
      Alert.alert(
        "Payment link error",
        err?.message || "Could not generate payment link. Check your backend configuration in Settings."
      );
    }
    setGeneratingLink(false);
  }

  function handleSwitchProvider(provider) {
    if (provider === selectedProvider) return;
    setSelectedProvider(provider);
    setPaymentLink("");
    handleGenerateLink(provider);
  }

  const generate = useCallback(async () => {
    setGenerating(true);
    setMessage("");
    try {
      const raw = await generateOutreachMessage({
        invoice,
        channel,
        biz: settings,
        paymentLink,
        paymentPlan: paymentPlanEnabled
          ? { enabled: true, installments, frequency }
          : { enabled: false },
        apiKey: settings.anthropicKey,
      });

      // If it's an email, split the Subject line off the top
      if (channel === "email" && raw.startsWith("Subject:")) {
        const lines = raw.split("\n");
        setSubject(lines[0].replace("Subject:", "").trim());
        setMessage(lines.slice(2).join("\n").trim());
      } else {
        setSubject("");
        setMessage(raw);
      }
    } catch {
      setMessage("Error generating message. Check your connection.");
    }
    setGenerating(false);
  }, [invoice, channel, settings, paymentLink, paymentPlanEnabled, installments, frequency]);

  // Re-generate whenever channel or payment plan changes (skip for paid invoices)
  useEffect(() => {
    if (invoice && !invoice.paid && settings) {
      generate();
    }
  }, [channel, paymentPlanEnabled, installments, frequency, paymentLink, invoice, settings, generate]);

  async function sendEmail() {
    await composeEmail({
      recipients: [invoice.email],
      subject: subject || `Payment reminder: ${invoice.number}`,
      body: message,
    });
  }

  async function sendSMS() {
    await composeSMS({ recipients: [invoice.phone], body: message });
  }

  async function copyToClipboard() {
    const full = channel === "email" && subject ? `Subject: ${subject}\n\n${message}` : message;
    await Clipboard.setStringAsync(full);
    setCopied(true);
    setTimeout(() => setCopied(false), 2000);
  }

  if (!invoice || !settings) {
    return (
      <View style={styles.loading}>
        <ActivityIndicator color={colors.accent} size={36} />
      </View>
    );
  }

  const status = getStatus(invoice);
  const configuredProviders = getConfiguredProviders(settings);

  return (
    <SafeAreaView style={styles.container} edges={["bottom"]}>
      <ScrollView contentContainerStyle={styles.scroll} showsVerticalScrollIndicator={false}>

        {/* Invoice summary */}
        <Card style={styles.summaryCard}>
          <View style={styles.summaryRow}>
            <View style={{ flex: 1 }}>
              <Text style={styles.customerName}>{invoice.customer}</Text>
              <Text style={styles.invoiceMeta}>{invoice.number} · {formatMoney(invoice.amount)}</Text>
            </View>
            <Badge label={status.label} color={status.color} />
          </View>

          {/* Provider selector — only shown when multiple providers are configured */}
          {!invoice.paid && configuredProviders.length > 1 && (
            <View style={styles.providerRow}>
              <Text style={styles.providerRowLabel}>Pay via</Text>
              <View style={styles.providerChips}>
                {configuredProviders.map((p) => (
                  <TouchableOpacity
                    key={p.id}
                    style={[styles.providerChip, selectedProvider === p.id && styles.providerChipActive]}
                    onPress={() => handleSwitchProvider(p.id)}
                  >
                    <Text style={[styles.providerChipText, selectedProvider === p.id && styles.providerChipTextActive]}>
                      {p.label}
                    </Text>
                  </TouchableOpacity>
                ))}
              </View>
            </View>
          )}

          {paymentLink ? (
            <View style={styles.linkBadge}>
              <Text style={styles.linkBadgeText}>
                ✓ {PROVIDER_LABELS[selectedProvider] ?? "Payment"} link ready
              </Text>
            </View>
          ) : !invoice.paid ? (
            <TouchableOpacity
              style={styles.generateLinkBtn}
              onPress={() => handleGenerateLink()}
              disabled={generatingLink}
            >
              {generatingLink ? (
                <ActivityIndicator size="small" color={colors.accent} />
              ) : (
                <Text style={styles.generateLinkText}>Generate payment link</Text>
              )}
            </TouchableOpacity>
          ) : null}
        </Card>

        {invoice.paid ? (
          <Card style={styles.paidCard}>
            <Text style={styles.paidTitle}>Invoice paid</Text>
            <Text style={styles.paidSub}>No further outreach needed.</Text>
          </Card>
        ) : (
          <>
            {/* Payment plan toggle */}
            <Card style={styles.section}>
              <View style={styles.toggleRow}>
                <Text style={styles.toggleLabel}>Offer a payment plan</Text>
                <Switch
                  value={paymentPlanEnabled}
                  onValueChange={setPaymentPlanEnabled}
                  trackColor={{ true: colors.accent }}
                />
              </View>
              {paymentPlanEnabled && (
                <View style={styles.planOptions}>
                  <Text style={styles.planLabel}>Installments</Text>
                  {["2", "3", "4", "6"].map((n) => (
                    <TouchableOpacity
                      key={n}
                      style={[styles.chipBtn, installments === n && styles.chipBtnActive]}
                      onPress={() => setInstallments(n)}
                    >
                      <Text style={[styles.chipText, installments === n && styles.chipTextActive]}>
                        {n} payments
                      </Text>
                    </TouchableOpacity>
                  ))}
                  <Text style={[styles.planLabel, { marginTop: spacing.sm }]}>Frequency</Text>
                  {["Weekly", "Bi-weekly", "Monthly"].map((f) => (
                    <TouchableOpacity
                      key={f}
                      style={[styles.chipBtn, frequency === f && styles.chipBtnActive]}
                      onPress={() => setFrequency(f)}
                    >
                      <Text style={[styles.chipText, frequency === f && styles.chipTextActive]}>{f}</Text>
                    </TouchableOpacity>
                  ))}
                </View>
              )}
            </Card>

            {/* Channel tabs */}
            <View style={styles.channelTabs}>
              {["email", "text"].map((ch) => (
                <TouchableOpacity
                  key={ch}
                  style={[styles.tab, channel === ch && styles.tabActive]}
                  onPress={() => setChannel(ch)}
                >
                  <Text style={[styles.tabText, channel === ch && styles.tabTextActive]}>
                    {ch === "email" ? "✉ Email" : "💬 Text message"}
                  </Text>
                </TouchableOpacity>
              ))}
            </View>

            {/* Generated message */}
            <Card style={styles.messageCard}>
              {channel === "email" && subject ? (
                <Text style={styles.subjectLine}>Subject: {subject}</Text>
              ) : null}
              {generating ? (
                <View style={styles.generatingRow}>
                  <ActivityIndicator color={colors.accent} size="small" />
                  <Text style={styles.generatingText}>  Generating message…</Text>
                </View>
              ) : (
                <Text style={styles.messageText}>{message}</Text>
              )}
            </Card>

            {/* Actions */}
            <View style={styles.actionRow}>
              <TouchableOpacity style={styles.copyBtn} onPress={copyToClipboard}>
                <Text style={styles.copyBtnText}>{copied ? "✓ Copied" : "Copy"}</Text>
              </TouchableOpacity>
              <TouchableOpacity style={styles.regenBtn} onPress={generate}>
                <Text style={styles.regenBtnText}>↺ Regenerate</Text>
              </TouchableOpacity>
            </View>

            <Divider />

            {/* Send buttons */}
            <Text style={styles.sendLabel}>Send via</Text>
            <Button
              label={`Open in ${channel === "email" ? "Mail" : "Messages"}`}
              onPress={channel === "email" ? sendEmail : sendSMS}
              style={{ marginBottom: spacing.sm }}
            />
            <Button
              label="Copy to clipboard"
              variant="ghost"
              onPress={copyToClipboard}
            />
          </>
        )}

      </ScrollView>
    </SafeAreaView>
  );
}

function createStyles(colors, shadow) {
  return StyleSheet.create({
  container: { flex: 1, backgroundColor: colors.background },
  loading: { flex: 1, alignItems: "center", justifyContent: "center" },
  scroll: { padding: spacing.md, paddingBottom: 40 },
  summaryCard: { marginBottom: spacing.sm },
  summaryRow: { flexDirection: "row", alignItems: "flex-start" },
  customerName: { fontSize: fontSize.lg, fontWeight: "600", color: colors.textPrimary },
  invoiceMeta: { fontSize: fontSize.sm, color: colors.textSecondary, marginTop: 2 },
  linkBadge: {
    marginTop: spacing.sm,
    backgroundColor: colors.successBg,
    borderRadius: radius.sm,
    paddingHorizontal: 10,
    paddingVertical: 4,
    alignSelf: "flex-start",
  },
  linkBadgeText: { fontSize: fontSize.xs, color: colors.success, fontWeight: "600" },
  generateLinkBtn: {
    marginTop: spacing.sm,
    paddingHorizontal: 14,
    paddingVertical: 8,
    borderRadius: radius.sm,
    borderWidth: 1,
    borderColor: colors.accent,
    alignSelf: "flex-start",
    minWidth: 44,
    alignItems: "center",
  },
  generateLinkText: { fontSize: fontSize.xs, color: colors.accent, fontWeight: "600" },
  providerRow: {
    marginTop: spacing.sm,
    flexDirection: "row",
    alignItems: "center",
    flexWrap: "wrap",
    gap: spacing.sm,
  },
  providerRowLabel: {
    fontSize: fontSize.xs,
    color: colors.textMuted,
    fontWeight: "500",
  },
  providerChips: {
    flexDirection: "row",
    flexWrap: "wrap",
    gap: 6,
  },
  providerChip: {
    paddingHorizontal: 10,
    paddingVertical: 4,
    borderRadius: radius.full,
    borderWidth: 1,
    borderColor: colors.border,
    backgroundColor: colors.surface,
  },
  providerChipActive: {
    backgroundColor: colors.accentBg,
    borderColor: colors.accent,
  },
  providerChipText: {
    fontSize: fontSize.xs,
    color: colors.textSecondary,
    fontWeight: "500",
  },
  providerChipTextActive: {
    color: colors.accent,
    fontWeight: "600",
  },
  section: { marginBottom: spacing.sm },
  paidCard: {
    marginBottom: spacing.sm,
    alignItems: "center",
    paddingVertical: spacing.lg,
  },
  paidTitle: { fontSize: fontSize.md, fontWeight: "700", color: colors.success },
  paidSub: { fontSize: fontSize.sm, color: colors.textMuted, marginTop: 4 },
  toggleRow: { flexDirection: "row", alignItems: "center", justifyContent: "space-between" },
  toggleLabel: { fontSize: fontSize.md, color: colors.textPrimary },
  planOptions: { marginTop: spacing.sm },
  planLabel: { fontSize: fontSize.sm, color: colors.textSecondary, marginBottom: 6, fontWeight: "500" },
  chipBtn: {
    display: "flex", flexDirection: "row", flexWrap: "wrap",
    paddingHorizontal: 12, paddingVertical: 6,
    borderRadius: radius.full, borderWidth: 1, borderColor: colors.border,
    marginBottom: 6, marginRight: 6, alignSelf: "flex-start",
    backgroundColor: colors.surface,
  },
  chipBtnActive: { backgroundColor: colors.accentBg, borderColor: colors.accent },
  chipText: { fontSize: fontSize.sm, color: colors.textSecondary },
  chipTextActive: { color: colors.accent, fontWeight: "600" },
  channelTabs: {
    flexDirection: "row", gap: 8, marginBottom: spacing.sm,
  },
  tab: {
    flex: 1, paddingVertical: 8, borderRadius: radius.md,
    borderWidth: 1, borderColor: colors.border,
    alignItems: "center", backgroundColor: colors.surface,
  },
  tabActive: { backgroundColor: colors.accentBg, borderColor: colors.accent },
  tabText: { fontSize: fontSize.sm, color: colors.textSecondary },
  tabTextActive: { color: colors.accent, fontWeight: "600" },
  messageCard: { marginBottom: spacing.sm, minHeight: 120 },
  subjectLine: {
    fontSize: fontSize.sm, fontWeight: "600", color: colors.textSecondary,
    marginBottom: spacing.sm, paddingBottom: spacing.sm,
    borderBottomWidth: StyleSheet.hairlineWidth, borderBottomColor: colors.border,
  },
  generatingRow: { flexDirection: "row", alignItems: "center", paddingVertical: spacing.sm },
  generatingText: { fontSize: fontSize.sm, color: colors.textMuted, fontStyle: "italic" },
  messageText: { fontSize: fontSize.sm, color: colors.textPrimary, lineHeight: 22 },
  actionRow: { flexDirection: "row", gap: 8, marginBottom: spacing.md },
  copyBtn: {
    flex: 1, height: 36, borderRadius: radius.md,
    borderWidth: 1, borderColor: colors.borderStrong,
    alignItems: "center", justifyContent: "center",
  },
  copyBtnText: { fontSize: fontSize.sm, color: colors.textPrimary },
  regenBtn: {
    flex: 1, height: 36, borderRadius: radius.md,
    borderWidth: 1, borderColor: colors.borderStrong,
    alignItems: "center", justifyContent: "center",
  },
  regenBtnText: { fontSize: fontSize.sm, color: colors.textPrimary },
  sendLabel: {
    fontSize: fontSize.sm, color: colors.textSecondary,
    fontWeight: "500", marginBottom: spacing.sm,
  },
  });
}
