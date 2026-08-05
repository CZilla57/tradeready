// screens/SettingsPaymentsScreen.tsx
import React, { useEffect, useMemo, useRef, useState } from "react";
import {
  View,
  Text,
  TextInput,
  ScrollView,
  TouchableOpacity,
  StyleSheet,
  Alert,
  Linking,
  AppState,
  ActivityIndicator,
  Platform,
  KeyboardAvoidingView,
  type AppStateStatus,
} from "react-native";
import Constants from "expo-constants";
import { useSettingsDraft } from "../hooks/useSettingsDraft";
import { supabase } from "../utils/supabase";
import { reportError } from "../utils/analytics";
import { fetchStripeConnectStatus, type StripeStatus } from "../utils/stripeStatus";
import { useTheme } from "../hooks/useTheme";
import { spacing, radius, fontSize, fonts, layout, type ColorScheme, type ShadowScheme } from "../utils/theme";
import type { TodayStackScreenProps } from "../types/navigation";

const VERCEL_URL = Constants.expoConfig?.extra?.backendUrl ?? "";

interface Provider {
  id: string;
  label: string;
  hint?: string;
}

const PROVIDERS: Provider[] = [
  { id: "stripe", label: "Stripe" },
  { id: "square", label: "Square", hint: "Paste your Square payment link (create one in Square Dashboard → Payment Links, e.g. https://square.link/u/abc123)" },
  { id: "paypal", label: "PayPal.Me", hint: "Enter your PayPal.Me username (e.g. johndoe)" },
  { id: "venmo", label: "Venmo", hint: "Enter your Venmo username" },
  { id: "custom", label: "Custom URL", hint: "Paste your payment page URL" },
];

export default function SettingsPaymentsScreen({ navigation }: TodayStackScreenProps<'SettingsPayments'>) {
  const { colors, shadow } = useTheme();
  const styles = useMemo(() => createStyles(colors, shadow), [colors, shadow]);

  const [stripeStatus, setStripeStatus] = useState<StripeStatus | null>(null);
  const [stripeConnecting, setStripeConnecting] = useState(false);
  const [stripeDisconnecting, setStripeDisconnecting] = useState(false);
  const appStateRef = useRef<AppStateStatus>(AppState.currentState);

  const { s, setS, update } = useSettingsDraft(navigation, {
    // The old load effect's provider half (monolith lines 307-316): a legacy
    // non-Stripe providerKey is backfilled into providerKeys before it
    // becomes the draft.
    prepare: (loaded) => {
      if (loaded.provider !== "stripe" && loaded.providerKey && !loaded.providerKeys?.[loaded.provider]) {
        return { ...loaded, providerKeys: { ...loaded.providerKeys, [loaded.provider]: loaded.providerKey } };
      }
      return loaded;
    },
  });

  function updateProviderKey(value: string) {
    if (!s) return;
    if (s.provider === "stripe") {
      update("providerKey", value);
    } else {
      setS(prev => prev ? {
        ...prev,
        providerKeys: { ...prev.providerKeys, [prev.provider]: value },
      } : prev);
    }
  }

  async function handleStripeConnect() {
    setStripeConnecting(true);
    try {
      const { data: { session } } = await supabase.auth.getSession();
      if (!session?.access_token) throw new Error("You must be signed in.");
      const res = await fetch(`${VERCEL_URL}/api/stripe/create-connect-account`, {
        method: "POST",
        headers: { Authorization: `Bearer ${session.access_token}`, "Content-Type": "application/json" },
      });
      const data = await res.json();
      if (data.error) throw new Error(data.error);
      await Linking.openURL(data.onboarding_url);
    } catch (err: unknown) {
      reportError(err, { context: 'stripeConnect' });
      Alert.alert("Stripe Connect error", (err as Error).message || "Could not start Stripe onboarding.");
    } finally {
      setStripeConnecting(false);
    }
  }

  async function handleStripeDisconnect() {
    Alert.alert("Disconnect Stripe", "Your Stripe account will be unlinked. Payment links will stop working until you reconnect.", [
      { text: "Cancel", style: "cancel" },
      {
        text: "Disconnect",
        style: "destructive",
        onPress: async () => {
          setStripeDisconnecting(true);
          try {
            const { data: { session } } = await supabase.auth.getSession();
            if (!session?.access_token) throw new Error("You must be signed in.");
            const res = await fetch(`${VERCEL_URL}/api/stripe/disconnect`, {
              method: "POST",
              headers: { Authorization: `Bearer ${session.access_token}` },
            });
            if (!res.ok) throw new Error("Failed to disconnect.");
            setStripeStatus({ connected: false });
          } catch (err: unknown) {
            reportError(err, { context: 'stripeDisconnect' });
            Alert.alert("Error", (err as Error).message || "Could not disconnect Stripe account.");
          } finally {
            setStripeDisconnecting(false);
          }
        },
      },
    ]);
  }

  useEffect(() => {
    async function refreshStripeStatus() {
      setStripeStatus(await fetchStripeConnectStatus());
    }
    refreshStripeStatus();
    const sub = AppState.addEventListener("change", (nextState) => {
      if (appStateRef.current.match(/inactive|background/) && nextState === "active") {
        refreshStripeStatus();
      }
      appStateRef.current = nextState;
    });
    return () => sub.remove();
  }, []);

  if (!s) return null;

  const selectedProvider = PROVIDERS.find((p) => p.id === s.provider);

  return (
    <View style={styles.container}>
      <KeyboardAvoidingView
        behavior={Platform.OS === "ios" ? "padding" : undefined}
        style={{ flex: 1 }}
      >
        <ScrollView
          contentContainerStyle={styles.scroll}
          showsVerticalScrollIndicator={false}
          keyboardShouldPersistTaps="handled"
          keyboardDismissMode="on-drag"
        >
          <View style={styles.providerGrid}>
            {PROVIDERS.map((p) => (
              <TouchableOpacity
                key={p.id}
                style={[styles.providerBtn, s.provider === p.id && styles.providerBtnActive]}
                onPress={() => update("provider", p.id)}
                accessibilityRole="radio"
                accessibilityLabel={p.label}
                accessibilityState={{ selected: s.provider === p.id }}
              >
                <Text style={[styles.providerLabel, s.provider === p.id && styles.providerLabelActive]}>{p.label}</Text>
              </TouchableOpacity>
            ))}
          </View>
          {s.provider === "stripe" ? (
            <View style={styles.card}>
              {stripeStatus === null ? (
                <ActivityIndicator size="small" color={colors.accent} />
              ) : stripeStatus.connected ? (
                <>
                  <View style={styles.stripeConnectedRow}>
                    <View style={styles.stripeConnectedDot} />
                    <Text style={styles.stripeConnectedLabel}>
                      {stripeStatus.details_submitted
                        ? (stripeStatus.display_name ? `Connected — ${stripeStatus.display_name}` : "Connected")
                        : "Connected — finish onboarding"}
                    </Text>
                  </View>
                  {!stripeStatus.details_submitted && (
                    <Text style={styles.stripeOnboardingHint}>
                      Tap below to complete your Stripe account setup before accepting payments.
                    </Text>
                  )}
                  <View style={styles.stripeButtonRow}>
                    {!stripeStatus.details_submitted && (
                      <TouchableOpacity style={[styles.stripeBtn, stripeConnecting && { opacity: 0.5 }]} onPress={handleStripeConnect} disabled={stripeConnecting} accessibilityRole="button" accessibilityLabel="Complete Stripe setup" accessibilityState={{ disabled: stripeConnecting, busy: stripeConnecting }}>
                        {stripeConnecting ? <ActivityIndicator size="small" color={colors.accent} /> : <Text style={styles.stripeBtnText}>Complete setup</Text>}
                      </TouchableOpacity>
                    )}
                    <TouchableOpacity style={[styles.stripeBtnDanger, stripeDisconnecting && { opacity: 0.5 }]} onPress={handleStripeDisconnect} disabled={stripeDisconnecting} accessibilityRole="button" accessibilityLabel="Disconnect Stripe" accessibilityState={{ disabled: stripeDisconnecting, busy: stripeDisconnecting }}>
                      {stripeDisconnecting ? <ActivityIndicator size="small" color={colors.danger} /> : <Text style={styles.stripeBtnDangerText}>Disconnect</Text>}
                    </TouchableOpacity>
                  </View>
                </>
              ) : (
                <>
                  <Text style={styles.providerHint}>Connect your Stripe account to generate payment links for your customers. Payments go directly to your Stripe account.</Text>
                  <TouchableOpacity style={[styles.stripeConnectBtn, stripeConnecting && { opacity: 0.5 }]} onPress={handleStripeConnect} disabled={stripeConnecting} accessibilityRole="button" accessibilityLabel="Connect Stripe account" accessibilityState={{ disabled: stripeConnecting, busy: stripeConnecting }}>
                    {stripeConnecting ? <ActivityIndicator size="small" color="#fff" /> : <Text style={styles.stripeConnectBtnText}>Connect Stripe account</Text>}
                  </TouchableOpacity>
                </>
              )}
            </View>
          ) : selectedProvider ? (
            <View style={styles.card}>
              <Text style={styles.providerHint}>{selectedProvider.hint}</Text>
              <TextInput
                style={styles.input}
                value={s.provider === "stripe" ? s.providerKey : (s.providerKeys?.[s.provider] ?? "")}
                onChangeText={updateProviderKey}
                placeholder="Paste link or username here"
                placeholderTextColor={colors.textMuted}
                autoCapitalize="none"
                autoCorrect={false}
                returnKeyType="done"
                accessibilityLabel={`${selectedProvider.label} link or username`}
              />
              <Text style={styles.keyNote}>This appears in the payment links you send to customers — never paste a password, API key, or access token here.</Text>
            </View>
          ) : null}
        </ScrollView>
      </KeyboardAvoidingView>
    </View>
  );
}

function createStyles(colors: ColorScheme, shadow: ShadowScheme) {
  return StyleSheet.create({
    container: { flex: 1, backgroundColor: colors.background },
    scroll: { padding: spacing.md, paddingBottom: 60, ...layout.contentColumn },
    card: { backgroundColor: colors.surface, borderRadius: radius.lg, padding: spacing.md, marginBottom: spacing.sm, ...shadow.card },
    providerGrid: { flexDirection: "row", flexWrap: "wrap", gap: 8, marginBottom: spacing.sm },
    providerBtn: { paddingHorizontal: 14, paddingVertical: 8, borderRadius: radius.full, borderWidth: 1, borderColor: colors.border, backgroundColor: colors.surface },
    providerBtnActive: { backgroundColor: colors.accentBg, borderColor: colors.accent },
    providerLabel: { fontFamily: fonts.bodyMedium, fontSize: fontSize.sm, color: colors.textSecondary },
    providerLabelActive: { fontFamily: fonts.bodySemiBold, color: colors.accent },
    providerHint: { fontFamily: fonts.bodyRegular, fontSize: fontSize.sm, color: colors.textSecondary, marginBottom: spacing.sm },
    // minHeight (not height) so larger accessibility text grows the field
    // instead of clipping — components/Field.tsx pattern.
    input: { fontFamily: fonts.bodyRegular, backgroundColor: colors.background, borderRadius: radius.md, minHeight: 44, paddingHorizontal: spacing.md, fontSize: fontSize.md, color: colors.textPrimary, borderWidth: StyleSheet.hairlineWidth, borderColor: colors.border },
    keyNote: { fontFamily: fonts.bodyRegular, fontSize: fontSize.xs, color: colors.textMuted, marginTop: 6 },
    stripeConnectedRow: { flexDirection: "row", alignItems: "center", marginBottom: 6 },
    stripeConnectedDot: { width: 8, height: 8, borderRadius: 4, backgroundColor: colors.success, marginRight: 8 },
    stripeConnectedLabel: { fontFamily: fonts.bodySemiBold, fontSize: fontSize.sm, color: colors.success },
    stripeOnboardingHint: { fontFamily: fonts.bodyRegular, fontSize: fontSize.sm, color: colors.textSecondary, marginBottom: spacing.sm },
    stripeButtonRow: { flexDirection: "row", gap: 8, marginTop: spacing.sm },
    stripeBtn: { paddingHorizontal: 16, paddingVertical: 8, borderRadius: radius.md, borderWidth: 1, borderColor: colors.accent, alignItems: "center", justifyContent: "center" },
    stripeBtnText: { fontFamily: fonts.bodySemiBold, fontSize: fontSize.sm, color: colors.accent },
    stripeBtnDanger: { paddingHorizontal: 16, paddingVertical: 8, borderRadius: radius.md, borderWidth: 1, borderColor: colors.danger + "80", alignItems: "center", justifyContent: "center" },
    stripeBtnDangerText: { fontFamily: fonts.bodyMedium, fontSize: fontSize.sm, color: colors.danger },
    stripeConnectBtn: { marginTop: spacing.sm, paddingVertical: 12, borderRadius: radius.md, backgroundColor: colors.accent, alignItems: "center" },
    stripeConnectBtnText: { fontFamily: fonts.bodyBold, fontSize: fontSize.sm, color: "#fff" },
  });
}
