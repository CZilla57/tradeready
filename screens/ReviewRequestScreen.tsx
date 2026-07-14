import React, { useState, useEffect, useMemo } from "react";
import {
  View,
  Text,
  ScrollView,
  TouchableOpacity,
  StyleSheet,
  Alert,
} from "react-native";
import { SafeAreaView } from "react-native-safe-area-context";
import * as Clipboard from "expo-clipboard";
import { composeEmail, composeSMS } from "../utils/messaging";
import { loadSettings } from "../utils/storage";
import {
  buildReviewMessage,
  getReviewRequestRecord,
  markReviewRequestSent,
} from "../utils/reviewRequest";
import { Button, Card, Divider } from "../components/UI";
import { spacing, radius, fontSize, type ColorScheme, type ShadowScheme } from "../utils/theme";
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

  const { jobId } = route.params;

  const [settings, setSettings] = useState<Settings | null>(null);
  const [customerName, setCustomerName] = useState("");
  const [customerPhone, setCustomerPhone] = useState("");
  const [customerEmail, setCustomerEmail] = useState("");
  const [message, setMessage] = useState("");
  const [sent, setSent] = useState(false);
  const [copied, setCopied] = useState(false);

  useEffect(() => {
    (async () => {
      const [s, record] = await Promise.all([
        loadSettings(),
        getReviewRequestRecord(jobId),
      ]);
      setSettings(s);

      if (record) {
        setCustomerName(record.customerName);
        setCustomerPhone(record.customerPhone);
        setCustomerEmail(record.customerEmail);
        if (record.sentAt) setSent(true);

        setMessage(
          buildReviewMessage(
            s.reviewRequestTemplate,
            s.businessName,
            record.customerName,
            s.googleReviewLink,
          ),
        );
      }
    })();
  }, [jobId]);

  async function handleSendSMS() {
    const opened = await composeSMS({
      recipients: customerPhone ? [customerPhone] : [],
      body: message,
    });
    if (opened) {
      await markReviewRequestSent(jobId);
      setSent(true);
      track('review_request_sent', { channel: 'sms' });
      Alert.alert("Review request sent", `SMS composer opened for ${customerName}.`);
    }
  }

  async function handleSendEmail() {
    const opened = await composeEmail({
      recipients: customerEmail ? [customerEmail] : [],
      subject: `Thanks for choosing ${settings?.businessName ?? "us"}!`,
      body: message,
    });
    if (opened) {
      await markReviewRequestSent(jobId);
      setSent(true);
      track('review_request_sent', { channel: 'email' });
      Alert.alert("Review request sent", `Email composer opened for ${customerName}.`);
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

  if (!settings || !message) return null;

  return (
    <SafeAreaView style={styles.container} edges={["bottom"]}>
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
    </SafeAreaView>
  );
}

function createStyles(colors: ColorScheme, shadow: ShadowScheme) {
  return StyleSheet.create({
    container: { flex: 1, backgroundColor: colors.background },
    scroll: { padding: spacing.md, paddingBottom: 40 },
    headerCard: { marginBottom: spacing.sm },
    customerName: {
      fontSize: fontSize.lg,
      fontWeight: "600",
      color: colors.textPrimary,
    },
    contactInfo: {
      fontSize: fontSize.sm,
      color: colors.textSecondary,
      marginTop: 2,
    },
    messageCard: { marginBottom: spacing.sm },
    messageLabel: {
      fontSize: fontSize.xs,
      fontWeight: "600",
      color: colors.textMuted,
      textTransform: "uppercase",
      letterSpacing: 0.5,
      marginBottom: spacing.sm,
    },
    messageText: {
      fontSize: fontSize.md,
      color: colors.textPrimary,
      lineHeight: 22,
    },
    sentCard: {
      backgroundColor: colors.successBg,
      marginTop: spacing.sm,
    },
    sentTitle: {
      fontSize: fontSize.md,
      fontWeight: "600",
      color: colors.success,
    },
    sentSub: {
      fontSize: fontSize.sm,
      color: colors.success,
      marginTop: 2,
    },
    sendLabel: {
      fontSize: fontSize.sm,
      fontWeight: "600",
      color: colors.textSecondary,
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
      fontSize: fontSize.sm,
      color: colors.textSecondary,
      fontWeight: "500",
    },
    skipBtn: {
      paddingHorizontal: 16,
      paddingVertical: 10,
      borderRadius: radius.md,
    },
    skipBtnText: {
      fontSize: fontSize.sm,
      color: colors.textMuted,
      fontWeight: "500",
    },
  });
}
