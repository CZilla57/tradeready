// screens/SettingsSubscriptionScreen.tsx
// Subscription is an IMMEDIATE-action page: navigation and Stripe calls
// happen on tap via openManageSubscriptions (or navigate to PaywallModal),
// never through the Settings draft.
import React, { useMemo } from "react";
import { View, Text, ScrollView, StyleSheet, TouchableOpacity, Alert, Platform } from "react-native";
import { useSettingsTabPop } from "../hooks/useSettingsDraft";
import { useSubscription } from "../context/SubscriptionContext";
import { openManageSubscriptions } from "../utils/subscription";
import { useTheme } from "../hooks/useTheme";
import { spacing, radius, fontSize, fonts, layout, type ColorScheme, type ShadowScheme } from "../utils/theme";
import type { TodayStackScreenProps } from "../types/navigation";

export default function SettingsSubscriptionScreen({ navigation }: TodayStackScreenProps<'SettingsSubscription'>) {
  const { colors, shadow } = useTheme();
  const { isSubscribed, isTrialing } = useSubscription();
  const styles = useMemo(() => createStyles(colors, shadow), [colors, shadow]);
  useSettingsTabPop(navigation);

  return (
    <View style={styles.container}>
      <ScrollView contentContainerStyle={styles.scroll} showsVerticalScrollIndicator={false}>
        <View style={styles.card}>
          {isTrialing ? (
            <View style={styles.subStatusRow}>
              <View style={[styles.subStatusDot, { backgroundColor: colors.warning }]} />
              <Text style={[styles.subStatusLabel, { color: colors.warning }]}>Free trial active</Text>
            </View>
          ) : isSubscribed ? (
            <View style={styles.subStatusRow}>
              <View style={[styles.subStatusDot, { backgroundColor: colors.success }]} />
              <Text style={[styles.subStatusLabel, { color: colors.success }]}>Subscription active</Text>
            </View>
          ) : (
            <Text style={styles.providerHint}>Subscribe to unlock all features.</Text>
          )}
          {isSubscribed || isTrialing ? (
            <TouchableOpacity style={[styles.stripeBtn, { marginTop: spacing.sm }]} accessibilityRole="button" accessibilityLabel="Manage subscription" onPress={async () => {
              if (await openManageSubscriptions()) return;
              // Neither the StoreKit sheet nor the store deep link is available
              // (sandbox / iPad compatibility mode) — tell the user where to go
              // rather than letting the failure surface as an error.
              Alert.alert(
                "Manage your subscription",
                Platform.OS === "ios"
                  ? "Open the Settings app, tap your name, then tap Subscriptions to change or cancel TradeReady Pro."
                  : "Open the Google Play Store, tap your profile picture, then tap Payments & subscriptions."
              );
            }}>
              <Text style={styles.stripeBtnText}>Manage subscription</Text>
            </TouchableOpacity>
          ) : (
            /* PaywallModal lives on the ROOT stack: TodayStack → MainTabs → RootStack, hence two hops. */
            <TouchableOpacity style={[styles.stripeConnectBtn, { marginTop: spacing.sm }]} accessibilityRole="button" accessibilityLabel="Subscribe" onPress={() => navigation.getParent()?.getParent()?.navigate("PaywallModal", { canDismiss: true })}>
              <Text style={styles.stripeConnectBtnText}>Subscribe</Text>
            </TouchableOpacity>
          )}
        </View>
      </ScrollView>
    </View>
  );
}

function createStyles(colors: ColorScheme, shadow: ShadowScheme) {
  return StyleSheet.create({
    container: { flex: 1, backgroundColor: colors.background },
    scroll: { padding: spacing.md, paddingBottom: 60, ...layout.contentColumn },
    card: { backgroundColor: colors.surface, borderRadius: radius.lg, padding: spacing.md, marginBottom: spacing.sm, ...shadow.card },
    providerHint: { fontFamily: fonts.bodyRegular, fontSize: fontSize.sm, color: colors.textSecondary, marginBottom: spacing.sm },
    subStatusRow: { flexDirection: "row", alignItems: "center" },
    subStatusDot: { width: 8, height: 8, borderRadius: 4, marginRight: 8 },
    subStatusLabel: { fontFamily: fonts.bodySemiBold, fontSize: fontSize.sm },
    stripeBtn: { paddingHorizontal: 16, paddingVertical: 8, borderRadius: radius.md, borderWidth: 1, borderColor: colors.accent, alignItems: "center", justifyContent: "center" },
    stripeBtnText: { fontFamily: fonts.bodySemiBold, fontSize: fontSize.sm, color: colors.accent },
    stripeConnectBtn: { marginTop: spacing.sm, paddingVertical: 12, borderRadius: radius.md, backgroundColor: colors.accent, alignItems: "center" },
    stripeConnectBtnText: { fontFamily: fonts.bodyBold, fontSize: fontSize.sm, color: "#fff" },
  });
}
