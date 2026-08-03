import React, { useState, useEffect, useMemo } from "react";
import {
  View,
  Text,
  ScrollView,
  TouchableOpacity,
  StyleSheet,
  Alert,
} from "react-native";
import * as Clipboard from "expo-clipboard";
import { composeEmailWithOutcome, composeSMSWithOutcome } from "../utils/messaging";
import { loadSettings, loadJobs, loadCustomers, resolveCustomer } from "../utils/storage";
import {
  buildReviewMessage,
  reviewMessageMissingLink,
  getReviewRequestRecord,
  markReviewRequestSent,
} from "../utils/reviewRequest";
import { Button, Card, Divider, EmptyState } from "../components/UI";
import { spacing, radius, fontSize, fonts, layout, type ColorScheme, type ShadowScheme } from "../utils/theme";
import { useTheme } from "../hooks/useTheme";
import type { Settings } from "../types/models";
import { track } from '../utils/analytics';
import type { JobStackScreenProps } from "../types/navigation";

export default function ReviewRequestScreen({
  route,
  navigation,
}: JobStackScreenProps<'ReviewRequest'>) {
  const { colors, shadow } = useTheme();
  const styles = useMemo(() => createStyles(colors, shadow), [colors, shadow]);

  const { jobId, source } = route.params;

  const [settings, setSettings] = useState<Settings | null>(null);
  const [customerName, setCustomerName] = useState("");
  const [customerPhone, setCustomerPhone] = useState("");
  const [customerEmail, setCustomerEmail] = useState("");
  const [message, setMessage] = useState("");
  const [missingLink, setMissingLink] = useState(false);
  const [sent, setSent] = useState(false);
  const [copied, setCopied] = useState(false);
  const [notFound, setNotFound] = useState(false);
  const [fallbackCustomer, setFallbackCustomer] = useState<{
    customerId: string;
    customerName: string;
    customerPhone: string;
    customerEmail: string;
  } | null>(null);

  useEffect(() => {
    (async () => {
      const [s, record, jobs, customers] = await Promise.all([
        loadSettings(),
        // This read can throw (raw getItem + JSON.parse); a bad record must
        // not leave the screen on the blank loading frame — degrade to the
        // live-customer path below.
        getReviewRequestRecord(jobId).catch(() => null),
        loadJobs(),
        loadCustomers(),
      ]);
      setSettings(s);
      setMissingLink(reviewMessageMissingLink(s.reviewRequestTemplate, s.googleReviewLink));
      if (record?.sentAt) setSent(true);

      // The LIVE customer drives contact info on every path — a phone or
      // email corrected after the job completed must be what we send to.
      // The record is the sent-state truth, and a last-resort contact
      // snapshot only when the customer record itself is gone.
      const job = jobs.find((j) => j.id === jobId);
      const cust = job ? resolveCustomer(customers, job) : null;

      if (!cust) {
        if (!record) {
          setNotFound(true);
          return;
        }
        setCustomerName(record.customerName);
        setCustomerPhone(record.customerPhone);
        setCustomerEmail(record.customerEmail);
        setMessage(
          buildReviewMessage(
            s.reviewRequestTemplate,
            s.businessName,
            record.customerName,
            s.googleReviewLink,
          ),
        );
        return;
      }

      if (!record) {
        // Sending creates the record (upsert) — snapshot the live customer.
        setFallbackCustomer({
          customerId: cust.id,
          customerName: cust.name,
          customerPhone: cust.phone,
          customerEmail: cust.email,
        });
      }
      setCustomerName(cust.name);
      setCustomerPhone(cust.phone);
      setCustomerEmail(cust.email);
      setMessage(
        buildReviewMessage(
          s.reviewRequestTemplate,
          s.businessName,
          cust.name,
          s.googleReviewLink,
        ),
      );
    })();
  }, [jobId]);

  // Cancelling out of a composer must not burn the one-shot or the pending
  // auto-reminder — only a real (or unreportable-platform) send counts.
  async function handleSendSMS() {
    const { opened, outcome } = await composeSMSWithOutcome({
      recipients: customerPhone ? [customerPhone] : [],
      body: message,
    });
    if (opened && outcome !== "notSent") {
      await markReviewRequestSent(jobId, fallbackCustomer ?? undefined);
      setSent(true);
      track('review_request_sent', { channel: 'sms', source: source ?? 'notification' });
      Alert.alert("Review request sent", `Sent to ${customerName} by text.`);
    }
  }

  async function handleSendEmail() {
    const { opened, outcome } = await composeEmailWithOutcome({
      recipients: customerEmail ? [customerEmail] : [],
      subject: `Thanks for choosing ${settings?.businessName ?? "us"}!`,
      body: message,
    });
    if (opened && outcome !== "notSent") {
      await markReviewRequestSent(jobId, fallbackCustomer ?? undefined);
      setSent(true);
      track('review_request_sent', { channel: 'email', source: source ?? 'notification' });
      Alert.alert("Review request sent", `Sent to ${customerName} by email.`);
    }
  }

  async function handleCopy() {
    await Clipboard.setStringAsync(message);
    setCopied(true);
    setTimeout(() => setCopied(false), 2000);
  }

  function handleSkip() {
    Alert.alert(
      "Skip review request?",
      "You can always send it later from the job detail.",
      [
        { text: "Cancel", style: "cancel" },
        {
          text: "Skip",
          onPress: () => navigation.goBack(),
        },
      ],
    );
  }

  if (notFound) {
    return (
      <View style={styles.container}>
        <EmptyState message="This job or its customer no longer exists, so there's no one to send a review request to." />
      </View>
    );
  }

  if (!settings || !message) return null;

  return (
    <View style={styles.container}>
      <ScrollView
        contentContainerStyle={styles.scroll}
        showsVerticalScrollIndicator={false}
      >
        <Card style={styles.headerCard}>
          <Text style={styles.customerName}>{customerName}</Text>
          {customerPhone ? (
            <Text style={styles.contactInfo}>{customerPhone}</Text>
          ) : null}
          {customerEmail ? (
            <Text style={styles.contactInfo}>{customerEmail}</Text>
          ) : null}
        </Card>

        <Card style={styles.messageCard}>
          <Text style={styles.messageLabel}>Message preview</Text>
          <Text style={styles.messageText}>{message}</Text>
        </Card>

        {sent ? (
          <Card style={styles.sentCard}>
            <Text style={styles.sentTitle}>Review request sent</Text>
            <Text style={styles.sentSub}>
              You already sent a review request for this job.
            </Text>
          </Card>
        ) : missingLink ? (
          <Card style={styles.noticeCard}>
            <Text style={styles.noticeTitle}>Add your Google review link</Text>
            <Text style={styles.noticeSub}>
              Review requests need a link for customers to leave a review. Add your
              Google review link in Settings, then come back to send this request.
            </Text>
            <Button
              label="Go to Settings"
              onPress={() => navigation.navigate("Today", { screen: "Settings" })}
              style={{ marginTop: spacing.md }}
            />
            <TouchableOpacity
              style={[styles.skipBtn, { alignSelf: "center", marginTop: spacing.sm }]}
              onPress={handleSkip}
              accessibilityRole="button"
              accessibilityLabel="Skip review request"
            >
              <Text style={styles.skipBtnText}>Skip</Text>
            </TouchableOpacity>
          </Card>
        ) : (
          <>
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

            <View style={styles.actionRow}>
              <TouchableOpacity style={styles.copyBtn} onPress={handleCopy} accessibilityRole="button" accessibilityLabel={copied ? "Copied" : "Copy message"}>
                <Text style={styles.copyBtnText}>
                  {copied ? "Copied!" : "Copy message"}
                </Text>
              </TouchableOpacity>
              <TouchableOpacity style={styles.skipBtn} onPress={handleSkip} accessibilityRole="button" accessibilityLabel="Skip review request">
                <Text style={styles.skipBtnText}>Skip</Text>
              </TouchableOpacity>
            </View>
          </>
        )}
      </ScrollView>
    </View>
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
    contactInfo: {
      fontFamily: fonts.bodyRegular,
      fontSize: fontSize.sm,
      color: colors.textSecondary,
      marginTop: 2,
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
    messageText: {
      fontFamily: fonts.bodyRegular,
      fontSize: fontSize.md,
      color: colors.textPrimary,
      lineHeight: 22,
    },
    sentCard: {
      backgroundColor: colors.successBg,
      marginTop: spacing.sm,
    },
    sentTitle: {
      fontFamily: fonts.bodySemiBold,
      fontSize: fontSize.md,
      color: colors.success,
    },
    sentSub: {
      fontFamily: fonts.bodyRegular,
      fontSize: fontSize.sm,
      color: colors.success,
      marginTop: 2,
    },
    noticeCard: {
      backgroundColor: colors.warningBg,
      marginTop: spacing.sm,
    },
    noticeTitle: {
      fontFamily: fonts.bodySemiBold,
      fontSize: fontSize.md,
      color: colors.warning,
    },
    noticeSub: {
      fontFamily: fonts.bodyRegular,
      fontSize: fontSize.sm,
      color: colors.textSecondary,
      marginTop: spacing.xs,
      lineHeight: 20,
    },
    sendLabel: {
      fontFamily: fonts.mono,
      fontSize: fontSize.xs,
      color: colors.textSecondary,
      textTransform: "uppercase",
      letterSpacing: 0.8,
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
    skipBtn: {
      paddingHorizontal: 16,
      paddingVertical: 10,
      borderRadius: radius.md,
    },
    skipBtnText: {
      fontFamily: fonts.bodyMedium,
      fontSize: fontSize.sm,
      color: colors.textMuted,
    },
  });
}
