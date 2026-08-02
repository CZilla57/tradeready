import React, { useState, useEffect, useCallback, useMemo } from "react";
import {
  View,
  Text,
  ScrollView,
  TouchableOpacity,
  StyleSheet,
  ActivityIndicator,
  Alert,
} from "react-native";
import { SafeAreaView } from "react-native-safe-area-context";
import { Ionicons } from "@expo/vector-icons";
import * as Clipboard from "expo-clipboard";
import { composeEmail, composeSMS } from "../utils/messaging";
import { loadJobs, loadCustomers, loadSettings, saveJobs, resolveCustomer } from "../utils/storage";
import { track } from '../utils/analytics';
import { formatQuote } from "../utils/format";
import { computeEstimateBreakdown } from "../utils/pricingEngine";
import { generateEstimateMessage } from "../utils/invoiceHelpers";
import { createApprovalLink } from "../utils/estimateApprovalLink";
import { stampEstimateSent } from "../utils/estimateFollowUps";
import { estimateHtml } from "../utils/pdfTemplates";
import { exportPdf } from "../utils/pdfExport";
import { readLogoForPdf } from "../utils/photoStorage";
import { Button, Card, Divider } from "../components/UI";
import { spacing, radius, fontSize, fonts } from "../utils/theme";
import type { ColorScheme, ShadowScheme } from "../utils/theme";
import { useTheme } from '../hooks/useTheme';
import type { Job, Customer, Settings } from "../types/models";
import type { JobStackScreenProps } from "../types/navigation";


interface ScreenData {
  job: Job;
  customer: Customer;
  settings: Settings;
}

export default function SendEstimateScreen({ route, navigation }: JobStackScreenProps<'SendEstimate'>) {
  const { colors, shadow } = useTheme();
  const styles = useMemo(() => createStyles(colors, shadow), [colors, shadow]);
  const { jobId } = route.params;

  const [data, setData] = useState<ScreenData | null>(null);
  const [channel, setChannel] = useState<"text" | "email">("email");
  const [message, setMessage] = useState<string>("");
  const [subject, setSubject] = useState<string>("");
  const [generating, setGenerating] = useState<boolean>(false);
  const [copied, setCopied] = useState<boolean>(false);
  const [marking, setMarking] = useState<boolean>(false);
  const [approvalLink, setApprovalLink] = useState<string>("");
  const [linking, setLinking] = useState<boolean>(false);

  useEffect(() => {
    async function load() {
      const [jobs, customers, settings] = await Promise.all([
        loadJobs(),
        loadCustomers(),
        loadSettings(),
      ]);
      const job = jobs.find((j: Job) => j.id === jobId);
      if (!job) { navigation.goBack(); return; }
      // resolveCustomer falls back to the normalized-name join when the id
      // link dangles (e.g. a recurring rule outliving a sample-id remap), so
      // the email/phone on file still reach the composer.
      const customer = resolveCustomer(customers, job) || {
        name: job.customerName,
        email: "",
        phone: "",
      } as Customer;
      navigation.setOptions({ title: job.customerName || "Send Estimate" });
      setData({ job, customer, settings });
    }
    load();
  }, [jobId, navigation]);

  const generate = useCallback(async (d: ScreenData | null = data) => {
    if (!d) return;
    setGenerating(true);
    setMessage("");
    try {
      const raw = await generateEstimateMessage({
        job: d.job,
        customer: d.customer,
        channel,
        biz: d.settings,
        apiKey: (d.settings as any).anthropicKey,
      });
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
  }, [channel, data]);

  useEffect(() => {
    if (!data) return;
    generate(data);
  }, [data, channel, generate]);

  async function sendEmail() {
    if (!data) return;
    await composeEmail({
      recipients: (data.customer as any).email ? [(data.customer as any).email] : [],
      subject: subject || `Estimate for ${data.job.title}`,
      body: message,
    });
  }

  async function sendSMS() {
    if (!data) return;
    await composeSMS({
      recipients: (data.customer as any).phone ? [(data.customer as any).phone] : [],
      body: message,
    });
  }

  async function handleExportPdf() {
    if (!data) return;
    const { job, customer, settings } = data;
    const logoDataUri = settings.logoPhoto
      ? await readLogoForPdf(settings.logoPhoto)
      : null;
    const html = estimateHtml(job, customer, settings, logoDataUri ?? undefined);
    const filename = `Estimate-${job.title.replace(/\s+/g, "-")}-${customer.name.replace(/\s+/g, "-")}`;
    await exportPdf(html, filename);
  }

  async function copyToClipboard() {
    const full =
      channel === "email" && subject ? `Subject: ${subject}\n\n${message}` : message;
    await Clipboard.setStringAsync(full);
    setCopied(true);
    setTimeout(() => setCopied(false), 2000);
  }

  async function markAsSent() {
    setMarking(true);
    const jobs = await loadJobs();
    const updated = jobs.map((j): Job =>
      j.id === jobId ? stampEstimateSent(j, new Date()) : j
    );
    await saveJobs(updated);
    track('estimate_sent');
    navigation.goBack();
  }

  async function createLink(): Promise<string | null> {
    if (!data) return null;
    setLinking(true);
    try {
      const result = await createApprovalLink(data.job, data.customer, data.settings);
      if (!result.ok) {
        Alert.alert(result.reason === "signed-out" ? "Sign in required" : "Couldn't create link", result.message);
        return null;
      }
      setApprovalLink(result.url);
      track("estimate_sent");
      return result.url;
    } finally {
      setLinking(false);
    }
  }

  async function sendForApproval() {
    const url = approvalLink || (await createLink());
    if (!url || !data) return;
    // Regenerate with the link so the customer gets a message that contains it.
    // generate() then refreshes the on-screen preview to match what was sent —
    // the preview used to show link-less text while this sent something else.
    const raw = await generateEstimateMessage({
      job: data.job, customer: data.customer, channel, biz: data.settings,
      apiKey: (data.settings as any).anthropicKey, approvalLink: url,
    });
    const body = channel === "email" && raw.startsWith("Subject:") ? raw.split("\n").slice(2).join("\n").trim() : raw;
    setMessage(body);
    if (channel === "email") {
      await composeEmail({ recipients: (data.customer as any).email ? [(data.customer as any).email] : [], subject: subject || `Estimate for ${data.job.title}`, body });
    } else {
      await composeSMS({ recipients: (data.customer as any).phone ? [(data.customer as any).phone] : [], body });
    }
  }

  if (!data) {
    return (
      <View style={styles.loading}>
        <ActivityIndicator color={colors.accent} size={36} />
      </View>
    );
  }

  const { job, customer } = data;
  const { laborCost, materialCost, overheadLine, hasMaterials } = computeEstimateBreakdown(job);

  return (
    <SafeAreaView style={styles.container} edges={["bottom"]}>
      <ScrollView
        contentContainerStyle={styles.scroll}
        showsVerticalScrollIndicator={false}
        keyboardShouldPersistTaps="handled"
      >
        {/* Estimate summary */}
        <Card style={styles.summaryCard}>
          <Text style={styles.jobTitle}>{job.title}</Text>
          <Text style={styles.customerName}>{customer.name}</Text>

          <Divider />

          <View style={styles.lineRow}>
            <Text style={styles.lineLabel}>
              Labor ({job.laborHours} hrs @ ${job.laborRate}/hr)
            </Text>
            <Text style={styles.lineValue}>{formatQuote(laborCost)}</Text>
          </View>
          {hasMaterials && (
            <View style={styles.lineRow}>
              <Text style={styles.lineLabel}>
                Materials ({job.materials.length} item{job.materials.length !== 1 ? "s" : ""})
              </Text>
              <Text style={styles.lineValue}>{formatQuote(materialCost)}</Text>
            </View>
          )}
          {overheadLine > 0 && (
            <View style={styles.lineRow}>
              <Text style={styles.lineLabel}>Overhead & operating costs</Text>
              <Text style={styles.lineValue}>{formatQuote(overheadLine)}</Text>
            </View>
          )}

          <Divider />

          <View style={styles.lineRow}>
            <Text style={[styles.lineLabel, styles.totalLabel]}>TOTAL ESTIMATE</Text>
            <Text style={[styles.lineValue, styles.totalValue]}>
              {formatQuote(job.estimateTotal)}
            </Text>
          </View>
        </Card>

        {/* Channel tabs */}
        <View style={styles.channelTabs}>
          {(["email", "text"] as const).map((ch) => (
            <TouchableOpacity
              key={ch}
              style={[styles.tab, channel === ch && styles.tabActive]}
              onPress={() => setChannel(ch)}
              accessibilityRole="tab"
              accessibilityLabel={ch === "email" ? "Email" : "Text message"}
              accessibilityState={{ selected: channel === ch }}
            >
              <Ionicons
                name={ch === "email" ? "mail-outline" : "chatbubble-outline"}
                size={14}
                color={channel === ch ? colors.accent : colors.textSecondary}
              />
              <Text style={[styles.tabText, channel === ch && styles.tabTextActive]}>
                {ch === "email" ? "Email" : "Text message"}
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
              <Text style={styles.generatingText}>  Writing message…</Text>
            </View>
          ) : (
            <Text style={styles.messageText}>{message}</Text>
          )}
        </Card>

        {/* Copy / Regenerate / PDF */}
        <View style={styles.actionRow}>
          <TouchableOpacity style={styles.actionBtn} onPress={copyToClipboard} accessibilityRole="button" accessibilityLabel={copied ? "Copied" : "Copy message"}>
            <Text style={styles.actionBtnText}>{copied ? "✓ Copied" : "Copy"}</Text>
          </TouchableOpacity>
          <TouchableOpacity style={styles.actionBtn} onPress={() => generate()} accessibilityRole="button" accessibilityLabel="Regenerate message">
            <Text style={styles.actionBtnText}>↺ Regenerate</Text>
          </TouchableOpacity>
          <TouchableOpacity style={styles.actionBtn} onPress={handleExportPdf} accessibilityRole="button" accessibilityLabel="Save as PDF">
            <Text style={styles.actionBtnText}>Save PDF</Text>
          </TouchableOpacity>
        </View>

        <Divider />

        <Text style={styles.sendLabel}>Send via</Text>
        <Button
          label={`Open in ${channel === "email" ? "Mail" : "Messages"}`}
          onPress={channel === "email" ? sendEmail : sendSMS}
          style={{ marginBottom: spacing.sm }}
        />
        <Button
          label={approvalLink ? `Send approval request via ${channel === "email" ? "Mail" : "Messages"}` : "Create approval link & send"}
          onPress={sendForApproval}
          loading={linking}
          style={{ marginBottom: spacing.sm }}
        />
        {approvalLink ? (
          <TouchableOpacity onPress={() => Clipboard.setStringAsync(approvalLink)} accessibilityRole="button" accessibilityLabel="Copy approval link">
            <Text style={styles.markHint}>Tap to copy link: {approvalLink}</Text>
          </TouchableOpacity>
        ) : null}
        <Button
          label="Mark estimate as sent"
          variant="secondary"
          onPress={markAsSent}
          loading={marking}
        />
        <Text style={styles.markHint}>
          No email needed — advances the job to "Estimate sent" so you can
          track approval, however you delivered the estimate.
        </Text>
      </ScrollView>
    </SafeAreaView>
  );
}

function createStyles(colors: ColorScheme, shadow: ShadowScheme) {
  return StyleSheet.create({
  container: { flex: 1, backgroundColor: colors.background },
  loading: { flex: 1, alignItems: "center", justifyContent: "center" },
  scroll: { padding: spacing.md, paddingBottom: 40 },

  summaryCard: { marginBottom: spacing.sm },
  jobTitle: { fontFamily: fonts.bodyBold, fontSize: fontSize.lg, color: colors.textPrimary, marginBottom: 2 },
  customerName: { fontFamily: fonts.bodyRegular, fontSize: fontSize.sm, color: colors.textSecondary, marginBottom: spacing.sm },
  lineRow: {
    flexDirection: "row",
    justifyContent: "space-between",
    alignItems: "center",
    marginBottom: 6,
  },
  lineLabel: { fontFamily: fonts.bodyRegular, fontSize: fontSize.sm, color: colors.textSecondary, flex: 1, marginRight: spacing.sm },
  lineValue: { fontFamily: fonts.mono, fontSize: 12, color: colors.textPrimary },
  totalLabel: { fontFamily: fonts.bodySemiBold, color: colors.textPrimary },
  totalValue: { fontFamily: fonts.display, fontSize: fontSize.lg, color: colors.textPrimary, fontVariant: ["tabular-nums"] },

  channelTabs: { flexDirection: "row", gap: 8, marginBottom: spacing.sm },
  tab: {
    flex: 1,
    paddingVertical: 8,
    borderRadius: radius.md,
    borderWidth: 1,
    borderColor: colors.border,
    alignItems: "center",
    justifyContent: "center",
    flexDirection: "row",
    gap: 6,
    backgroundColor: colors.surface,
  },
  tabActive: { backgroundColor: colors.accentBg, borderColor: colors.accent },
  tabText: { fontFamily: fonts.bodyMedium, fontSize: fontSize.sm, color: colors.textSecondary },
  tabTextActive: { fontFamily: fonts.bodySemiBold, color: colors.accent },

  messageCard: { marginBottom: spacing.sm, minHeight: 120 },
  subjectLine: {
    fontFamily: fonts.bodySemiBold,
    fontSize: fontSize.sm,
    color: colors.textSecondary,
    marginBottom: spacing.sm,
    paddingBottom: spacing.sm,
    borderBottomWidth: StyleSheet.hairlineWidth,
    borderBottomColor: colors.border,
  },
  generatingRow: { flexDirection: "row", alignItems: "center", paddingVertical: spacing.sm },
  generatingText: { fontFamily: fonts.bodyRegular, fontSize: fontSize.sm, color: colors.textMuted, fontStyle: "italic" },
  messageText: { fontFamily: fonts.bodyRegular, fontSize: fontSize.sm, color: colors.textPrimary, lineHeight: 22 },

  actionRow: { flexDirection: "row", gap: 8, marginBottom: spacing.md },
  actionBtn: {
    flex: 1,
    // minHeight (not height): accessibility text grows the buttons instead
    // of clipping — components/Field.tsx pattern.
    minHeight: 44,
    borderRadius: radius.md,
    borderWidth: 1,
    borderColor: colors.borderStrong,
    alignItems: "center",
    justifyContent: "center",
  },
  actionBtnText: { fontFamily: fonts.bodyMedium, fontSize: fontSize.sm, color: colors.textPrimary },

  sendLabel: {
    fontFamily: fonts.mono,
    fontSize: fontSize.xs,
    color: colors.textSecondary,
    textTransform: "uppercase",
    letterSpacing: 0.8,
    marginBottom: spacing.sm,
  },
  markHint: {
    fontFamily: fonts.bodyRegular,
    fontSize: fontSize.xs,
    color: colors.textMuted,
    textAlign: "center",
    marginTop: spacing.sm,
  },
  });
}
