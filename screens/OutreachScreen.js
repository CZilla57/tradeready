// screens/OutreachScreen.js
// Generates AI-powered email and SMS outreach for a specific invoice.
// Uses expo-mail-composer and expo-sms to open the native iOS Mail and
// Messages apps pre-filled with the generated content — no email server needed.

import React, { useState, useEffect } from "react";
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
import * as MailComposer from "expo-mail-composer";
import * as SMS from "expo-sms";
import * as Clipboard from "expo-clipboard";
import { loadInvoices, loadSettings } from "../utils/storage";
import { getStatus, formatCurrency, generateOutreachMessage, fetchPaymentLink } from "../utils/invoiceHelpers";
import { Badge, Button, Card, Divider } from "../components/UI";
import { colors, spacing, radius, fontSize, shadow } from "../utils/theme";

export default function OutreachScreen({ route, navigation }) {
  const { invoiceId } = route.params;

  const [invoice, setInvoice] = useState(null);
  const [settings, setSettings] = useState(null);
  const [channel, setChannel] = useState("email");
  const [message, setMessage] = useState("");
  const [subject, setSubject] = useState("");
  const [generating, setGenerating] = useState(false);
  const [paymentLink, setPaymentLink] = useState("");
  const [paymentPlanEnabled, setPaymentPlanEnabled] = useState(false);
  const [installments, setInstallments] = useState("3");
  const [frequency, setFrequency] = useState("Bi-weekly");
  const [copied, setCopied] = useState(false);

  useEffect(() => {
    async function load() {
      const [invoices, s] = await Promise.all([loadInvoices(), loadSettings()]);
      const inv = invoices.find((i) => i.id === invoiceId);
      setInvoice(inv);
      setSettings(s);
      navigation.setOptions({ title: inv?.customer || "Outreach" });

      // Fetch the payment link from your Vercel backend
      try {
        if (!s.providerKey) {
          Alert.alert(
            "Payment key missing",
            "Go to Settings and paste your Stripe secret key (starts with sk_) to generate real payment links.",
          );
          setPaymentLink("");
        } else {
          const link = await fetchPaymentLink(inv, s.provider, s.providerKey);
          setPaymentLink(link);
        }
      } catch (err) {
        Alert.alert("Payment link error", err?.message || "Could not generate payment link. Check your Stripe key in Settings.");
        setPaymentLink("");
      }
    }
    load();
  }, [invoiceId]);

  // Re-generate whenever channel or payment plan changes
  useEffect(() => {
    if (invoice && settings && paymentLink) {
      generate();
    }
  }, [channel, paymentPlanEnabled, installments, frequency, paymentLink]);

  async function generate() {
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
    } catch (e) {
      setMessage("Error generating message. Check your connection.");
    }
    setGenerating(false);
  }

  async function sendEmail() {
    const available = await MailComposer.isAvailableAsync();
    if (!available) {
      Alert.alert("Mail not available", "Please set up the Mail app on this device first.");
      return;
    }
    await MailComposer.composeAsync({
      recipients: [invoice.email],
      subject: subject || `Payment reminder: ${invoice.number}`,
      body: message,
    });
  }

  async function sendSMS() {
    const available = await SMS.isAvailableAsync();
    if (!available) {
      Alert.alert("SMS not available", "This device can't send text messages.");
      return;
    }
    await SMS.sendSMSAsync([invoice.phone], message);
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

  return (
    <SafeAreaView style={styles.container} edges={["bottom"]}>
      <ScrollView contentContainerStyle={styles.scroll} showsVerticalScrollIndicator={false}>

        {/* Invoice summary */}
        <Card style={styles.summaryCard}>
          <View style={styles.summaryRow}>
            <View style={{ flex: 1 }}>
              <Text style={styles.customerName}>{invoice.customer}</Text>
              <Text style={styles.invoiceMeta}>{invoice.number} · {formatCurrency(invoice.amount)}</Text>
            </View>
            <Badge label={status.label} color={status.color} />
          </View>
          {paymentLink ? (
            <View style={styles.linkBadge}>
              <Text style={styles.linkBadgeText}>✓ Payment link ready</Text>
            </View>
          ) : null}
        </Card>

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
              {/* Note: Picker requires @react-native-picker/picker — see README */}
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

      </ScrollView>
    </SafeAreaView>
  );
}

const styles = StyleSheet.create({
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
  section: { marginBottom: spacing.sm },
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
