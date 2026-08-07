// screens/SettingsHubScreen.tsx
// The Settings menu — replaced the 1,390-line monolithic SettingsScreen at
// the 2026-08-05 hub/subpages split. Every row pushes a focused subpage;
// Support/Legal are single actions and live here directly (spec decision).
import React, { useEffect, useMemo, useState } from "react";
import { View, Text, ScrollView, StyleSheet, TouchableOpacity, Linking, Platform } from "react-native";
import { Ionicons } from "@expo/vector-icons";
import Constants from "expo-constants";
import { SectionHeader } from "../components/UI";
import { composeEmail } from "../utils/messaging";
import { fetchStripeConnectStatus, type StripeStatus } from "../utils/stripeStatus";
import { useSettingsTabPop } from "../hooks/useSettingsDraft";
import { useSubscription } from "../context/SubscriptionContext";
import { useTheme } from "../hooks/useTheme";
import { spacing, radius, fontSize, fonts, layout, type ColorScheme, type ShadowScheme } from "../utils/theme";
import type { TodayStackScreenProps } from "../types/navigation";

const PRIVACY_URL = Constants.expoConfig?.extra?.privacyPolicyUrl ?? "https://tradeready.app/privacy";
const TERMS_URL   = Constants.expoConfig?.extra?.termsUrl          ?? "https://tradeready.app/terms";
// Must match the address published in the privacy policy (§ Contact) —
// the domain is gettradereadyapp.com, NOT tradeready.app (which doesn't exist).
const SUPPORT_EMAIL = "support@gettradereadyapp.com";
const APP_VERSION   = Constants.expoConfig?.version ?? "1.0.0";

interface HubRow {
  icon: keyof typeof Ionicons.glyphMap;
  label: string;
  subtitle?: string;
  onPress: () => void;
  role?: "button" | "link";
  accessibilityLabel?: string;
}

export default function SettingsHubScreen({ navigation }: TodayStackScreenProps<'Settings'>) {
  const { colors, shadow } = useTheme();
  const styles = useMemo(() => createStyles(colors, shadow), [colors, shadow]);
  const { isSubscribed, isTrialing } = useSubscription();
  const [stripeStatus, setStripeStatus] = useState<StripeStatus | null>(null);
  useSettingsTabPop(navigation);

  // Fetched on mount and every focus: keeps the Payments subtitle fresh
  // after a visit to the Payments page, and preserves the old screen's
  // checklist-signal timing (the util marks "stripe" done when connected).
  useEffect(() => {
    const refresh = () => { void fetchStripeConnectStatus().then(setStripeStatus); };
    refresh();
    const unsub = navigation.addListener("focus", refresh);
    return unsub;
  }, [navigation]);

  const stripeSubtitle =
    stripeStatus === null ? undefined
    : stripeStatus.connected
      ? (stripeStatus.display_name ? `Connected — ${stripeStatus.display_name}` : "Connected")
      : "Not connected";
  const subSubtitle = isTrialing ? "Free trial active" : isSubscribed ? "Active" : "Not subscribed";

  const groups: { title: string; rows: HubRow[] }[] = [
    {
      title: "Your business",
      rows: [
        { icon: "business-outline", label: "Business profile", onPress: () => navigation.navigate("SettingsBusiness") },
        { icon: "time-outline", label: "Schedule", onPress: () => navigation.navigate("SettingsSchedule") },
        { icon: "calculator-outline", label: "Pricing defaults", onPress: () => navigation.navigate("SettingsPricing") },
        { icon: "receipt-outline", label: "Invoice numbering", onPress: () => navigation.navigate("SettingsInvoiceNumbering") },
        { icon: "cloud-upload-outline", label: "Import data", onPress: () => navigation.navigate("SettingsImport") },
      ],
    },
    {
      title: "Getting paid",
      rows: [
        { icon: "card-outline", label: "Payments", subtitle: stripeSubtitle, onPress: () => navigation.navigate("SettingsPayments") },
        { icon: "calendar-outline", label: "Booking link", onPress: () => navigation.navigate("SettingsBooking") },
      ],
    },
    {
      title: "App",
      rows: [
        { icon: "color-palette-outline", label: "Appearance", onPress: () => navigation.navigate("SettingsAppearance") },
        { icon: "sparkles-outline", label: "AI Assistant", onPress: () => navigation.navigate("SettingsAI") },
        { icon: "notifications-outline", label: "Notifications", onPress: () => navigation.navigate("SettingsNotifications") },
        { icon: "star-outline", label: "Review requests", onPress: () => navigation.navigate("SettingsReviews") },
      ],
    },
    {
      title: "Subscription & support",
      rows: [
        { icon: "diamond-outline", label: "Subscription", subtitle: subSubtitle, onPress: () => navigation.navigate("SettingsSubscription") },
        {
          icon: "mail-outline",
          label: "Contact Support",
          accessibilityLabel: "Contact support by email",
          subtitle: SUPPORT_EMAIL,
          onPress: () => {
            void composeEmail({
              recipients: [SUPPORT_EMAIL],
              subject: `TradeReady support (v${APP_VERSION}, ${Platform.OS})`,
              body: "",
            });
          },
        },
        { icon: "shield-outline", label: "Privacy Policy", role: "link", onPress: () => { void Linking.openURL(PRIVACY_URL); } },
        { icon: "document-text-outline", label: "Terms of Service", role: "link", onPress: () => { void Linking.openURL(TERMS_URL); } },
      ],
    },
    {
      title: "Account",
      rows: [
        { icon: "person-circle-outline", label: "Account", onPress: () => navigation.navigate("SettingsAccount") },
      ],
    },
  ];

  return (
    <View style={styles.container}>
      <ScrollView contentContainerStyle={styles.scroll} showsVerticalScrollIndicator={false}>
        {groups.map((group) => (
          <View key={group.title}>
            <SectionHeader title={group.title} />
            <View style={styles.card}>
              {group.rows.map((row, i) => (
                <View key={row.label}>
                  {i > 0 && <View style={styles.listRowDivider} />}
                  <TouchableOpacity
                    style={styles.listRow}
                    onPress={row.onPress}
                    activeOpacity={0.7}
                    accessibilityRole={row.role ?? "button"}
                    accessibilityLabel={row.accessibilityLabel ?? row.label}
                  >
                    <Ionicons name={row.icon} size={20} color={colors.textSecondary} style={styles.listRowIcon} />
                    <View style={{ flex: 1 }}>
                      <Text style={styles.listRowText}>{row.label}</Text>
                      {!!row.subtitle && <Text style={styles.listRowSub}>{row.subtitle}</Text>}
                    </View>
                    <Text style={styles.listRowChevron}>›</Text>
                  </TouchableOpacity>
                </View>
              ))}
            </View>
          </View>
        ))}
      </ScrollView>
    </View>
  );
}

function createStyles(colors: ColorScheme, shadow: ShadowScheme) {
  return StyleSheet.create({
    container: { flex: 1, backgroundColor: colors.background },
    scroll: { padding: spacing.md, paddingBottom: 60, ...layout.contentColumn },
    card: { backgroundColor: colors.surface, borderRadius: radius.lg, paddingHorizontal: spacing.md, marginBottom: spacing.sm, ...shadow.card },
    listRow: { flexDirection: "row", alignItems: "center", paddingVertical: 13 },
    listRowIcon: { marginRight: spacing.sm },
    listRowText: { fontFamily: fonts.bodyRegular, fontSize: fontSize.md, color: colors.textPrimary },
    listRowSub: { fontFamily: fonts.bodyRegular, fontSize: fontSize.xs, color: colors.textMuted, marginTop: 2 },
    listRowChevron: { fontSize: 20, color: colors.textMuted },
    listRowDivider: { height: StyleSheet.hairlineWidth, backgroundColor: colors.border },
  });
}
