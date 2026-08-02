import React, { useState, useEffect, useMemo } from "react";
import {
  View,
  Text,
  ScrollView,
  TextInput,
  TouchableOpacity,
  StyleSheet,
  Alert,
} from "react-native";
import { SafeAreaView } from "react-native-safe-area-context";
import * as Clipboard from "expo-clipboard";
import { composeEmailWithOutcome, composeSMSWithOutcome } from "../utils/messaging";
import { loadSettings, loadJobs, loadCustomers, resolveCustomer } from "../utils/storage";
import { buildFollowUpMessage } from "../utils/estimateFollowUps";
import { formatQuote } from "../utils/format";
import { daysAgo } from "../utils/dateHelpers";
import { Button, Card, Divider, EmptyState } from "../components/UI";
import { spacing, radius, fontSize, fonts, layout, type ColorScheme, type ShadowScheme } from "../utils/theme";
import { useTheme } from "../hooks/useTheme";
import type { Settings } from "../types/models";
import { track } from "../utils/analytics";
import type { JobStackScreenProps } from "../types/navigation";

export default function EstimateFollowUpScreen({
  route,
  navigation,
}: JobStackScreenProps<'EstimateFollowUp'>) {
  const { colors, shadow } = useTheme();
  const styles = useMemo(() => createStyles(colors, shadow), [colors, shadow]);

  const { jobId, source } = route.params;

  const [settings, setSettings] = useState<Settings | null>(null);
  const [customerName, setCustomerName] = useState("");
  const [customerPhone, setCustomerPhone] = useState("");
  const [customerEmail, setCustomerEmail] = useState("");
  const [jobTitle, setJobTitle] = useState("");
  const [estimateTotal, setEstimateTotal] = useState(0);
  const [sentLabel, setSentLabel] = useState("");
  const [message, setMessage] = useState("");
  const [copied, setCopied] = useState(false);
  const [notFound, setNotFound] = useState(false);
  const [answered, setAnswered] = useState(false);

  useEffect(() => {
    (async () => {
      const [s, jobs, customers] = await Promise.all([
        loadSettings(),
        loadJobs(),
        loadCustomers(),
      ]);
      setSettings(s);
      // The LIVE customer record drives contact info — a phone or email
      // corrected after the estimate went out must be what we send to.
      const job = jobs.find((j) => j.id === jobId);
      const cust = job ? resolveCustomer(customers, job) : null;
      if (!job || !cust) {
        setNotFound(true);
        return;
      }
      // A stale notification tap can land after the customer already decided
      // (the sweep cancels on status change, but a tap can race one sweep).
      if (job.status !== "estimate_sent") {
        setAnswered(true);
        return;
      }
      setCustomerName(cust.name);
      setCustomerPhone(cust.phone);
      setCustomerEmail(cust.email);
      setJobTitle(job.title);
      setEstimateTotal(job.estimateTotal);
      const sentRaw = job.estimateSentAt ?? job.approval?.sentAt;
      // daysAgo parses bare "YYYY-MM-DD" as UTC midnight (fine for its existing
      // callers, wrong here — the label must agree with the local-frame fire-date
      // math, FA-039 class). Suffix date-only values into the local frame.
      const sentLocal = sentRaw && /^\d{4}-\d{2}-\d{2}$/.test(sentRaw) ? sentRaw + "T00:00:00" : sentRaw;
      setSentLabel(sentLocal ? `Sent ${daysAgo(sentLocal)}` : "");
      const firstName = cust.name.trim().split(/\s+/)[0] || cust.name;
      setMessage(buildFollowUpMessage(job, firstName));
    })();
  }, [jobId]);

  // Cancelling out of the OS composer must not count as sent.
  async function handleSendSMS() {
    const { opened, outcome } = await composeSMSWithOutcome({
      recipients: customerPhone ? [customerPhone] : [],
      body: message,
    });
    if (opened && outcome !== "notSent") {
      track("estimate_follow_up_sent", { channel: "sms", source: source ?? "notification" });
      Alert.alert("Follow-up sent", `Sent to ${customerName} by text.`, [
        { text: "OK", onPress: () => navigation.goBack() },
      ]);
    }
  }

  async function handleSendEmail() {
    const { opened, outcome } = await composeEmailWithOutcome({
      recipients: customerEmail ? [customerEmail] : [],
      subject: `Checking in on your estimate — ${settings?.businessName ?? ""}`.trim(),
      body: message,
    });
    if (opened && outcome !== "notSent") {
      track("estimate_follow_up_sent", { channel: "email", source: source ?? "notification" });
      Alert.alert("Follow-up sent", `Sent to ${customerName} by email.`, [
        { text: "OK", onPress: () => navigation.goBack() },
      ]);
    }
  }

  async function handleCopy() {
    await Clipboard.setStringAsync(message);
    setCopied(true);
    setTimeout(() => setCopied(false), 2000);
  }

  if (notFound) {
    return (
      <SafeAreaView style={styles.container} edges={["bottom"]}>
        <EmptyState message="This job or its customer no longer exists, so there's no one to follow up with." />
      </SafeAreaView>
    );
  }

  if (answered) {
    return (
      <SafeAreaView style={styles.container} edges={["bottom"]}>
        <EmptyState message="This estimate has already been answered — no follow-up needed." />
      </SafeAreaView>
    );
  }

  if (!settings || !message) return null;

  return (
    <SafeAreaView style={styles.container} edges={["bottom"]}>
      <ScrollView
        contentContainerStyle={styles.scroll}
        showsVerticalScrollIndicator={false}
        keyboardShouldPersistTaps="handled"
      >
        <Card style={styles.headerCard}>
          <Text style={styles.customerName}>{customerName}</Text>
          <Text style={styles.estimateLine}>
            {jobTitle} · {formatQuote(estimateTotal)}
          </Text>
          {sentLabel ? <Text style={styles.sentLine}>{sentLabel}</Text> : null}
        </Card>

        <Card style={styles.messageCard}>
          <Text style={styles.messageLabel}>Message — edit before sending</Text>
          <TextInput
            style={styles.messageInput}
            value={message}
            onChangeText={setMessage}
            multiline
            textAlignVertical="top"
            accessibilityLabel="Follow-up message"
          />
        </Card>

        <Divider />
        <Text style={styles.sendLabel}>Send via</Text>

        {customerPhone ? (
          <Button
            label="Send via SMS"
            onPress={handleSendSMS}
            style={{ marginBottom: spacing.sm }}
          />
        ) : null}

        {customerEmail ? (
          <Button
            label="Send via Email"
            onPress={handleSendEmail}
            variant={customerPhone ? "ghost" : "primary"}
            style={{ marginBottom: spacing.sm }}
          />
        ) : null}

        {!customerPhone && !customerEmail ? (
          <Text style={styles.noContactNote}>
            This customer has no phone or email on file — copy the message and
            send it another way, or add contact info on the customer.
          </Text>
        ) : null}

        <View style={styles.actionRow}>
          <TouchableOpacity
            style={styles.copyBtn}
            onPress={handleCopy}
            accessibilityRole="button"
            accessibilityLabel={copied ? "Copied" : "Copy message"}
          >
            <Text style={styles.copyBtnText}>{copied ? "Copied!" : "Copy message"}</Text>
          </TouchableOpacity>
        </View>
      </ScrollView>
    </SafeAreaView>
  );
}

function createStyles(colors: ColorScheme, shadow: ShadowScheme) {
  return StyleSheet.create({
    container: { flex: 1, backgroundColor: colors.background },
    scroll: { padding: spacing.md, paddingBottom: 40, ...layout.contentColumn },
    headerCard: { marginBottom: spacing.sm },
    customerName: {
      fontFamily: fonts.bodySemiBold,
      fontSize: fontSize.lg,
      color: colors.textPrimary,
    },
    estimateLine: {
      fontFamily: fonts.bodyRegular,
      fontSize: fontSize.sm,
      color: colors.textSecondary,
      marginTop: 2,
    },
    sentLine: {
      fontFamily: fonts.mono,
      fontSize: fontSize.xs,
      color: colors.textMuted,
      marginTop: 4,
    },
    messageCard: { marginBottom: spacing.sm },
    messageLabel: {
      fontFamily: fonts.mono,
      fontSize: fontSize.xs,
      color: colors.textMuted,
      textTransform: "uppercase",
      letterSpacing: 0.8,
      marginBottom: spacing.sm,
    },
    messageInput: {
      fontFamily: fonts.bodyRegular,
      fontSize: fontSize.md,
      color: colors.textPrimary,
      lineHeight: 22,
      minHeight: 120,
      padding: 0,
    },
    sendLabel: {
      fontFamily: fonts.mono,
      fontSize: fontSize.xs,
      color: colors.textSecondary,
      textTransform: "uppercase",
      letterSpacing: 0.8,
      marginBottom: spacing.sm,
    },
    noContactNote: {
      fontFamily: fonts.bodyRegular,
      fontSize: fontSize.sm,
      color: colors.textSecondary,
      lineHeight: 20,
      marginBottom: spacing.sm,
    },
    actionRow: {
      flexDirection: "row",
      justifyContent: "center",
      gap: spacing.md,
      marginTop: spacing.sm,
    },
    copyBtn: {
      paddingHorizontal: 16,
      paddingVertical: 10,
      borderRadius: radius.md,
      borderWidth: 1,
      borderColor: colors.border,
    },
    copyBtnText: {
      fontFamily: fonts.bodyMedium,
      fontSize: fontSize.sm,
      color: colors.textSecondary,
    },
  });
}
