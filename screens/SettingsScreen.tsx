import React, { useState, useEffect, useRef, useMemo } from "react";
import {
  View,
  Text,
  TextInput,
  ScrollView,
  TouchableOpacity,
  Switch,
  StyleSheet,
  Alert,
  Linking,
  AppState,
  ActivityIndicator,
  Platform,
  type AppStateStatus,
} from "react-native";
import { SafeAreaView } from "react-native-safe-area-context";
import AsyncStorage from "@react-native-async-storage/async-storage";
import Constants from "expo-constants";
import { loadSettings, saveSettings, clearSampleData, clearAllUserData } from "../utils/storage";
import { syncNotifications } from "../utils/notifications";
import { syncIfOnline } from "../utils/sync";
import { supabase } from "../utils/supabase";
import { resetUser } from "../utils/analytics";
import { Button, SectionHeader, Divider } from "../components/UI";
import BaseField from "../components/Field";
import { TRADE_TYPES } from "../utils/pricingEngine";
import { spacing, radius, fontSize, type ColorScheme, type ShadowScheme } from "../utils/theme";
import { useSubscription } from "../context/SubscriptionContext";
import { showManageSubscriptions } from "../utils/subscription";
import { useTheme } from "../hooks/useTheme";
import type { Settings } from "../types/models";

const PRIVACY_URL = Constants.expoConfig?.extra?.privacyPolicyUrl ?? "https://tradeready.app/privacy";
const TERMS_URL   = Constants.expoConfig?.extra?.termsUrl          ?? "https://tradeready.app/terms";
const VERCEL_URL  = Constants.expoConfig?.extra?.backendUrl        ?? "";

interface StripeStatus {
  connected: boolean;
  details_submitted?: boolean;
  display_name?: string;
  _error?: string;
}

interface Provider {
  id: string;
  label: string;
  hint?: string;
}

const PROVIDERS: Provider[] = [
  { id: "stripe", label: "Stripe" },
  { id: "square", label: "Square", hint: "Paste your Square Access Token" },
  { id: "paypal", label: "PayPal.Me", hint: "Enter your PayPal.Me username (e.g. johndoe)" },
  { id: "venmo", label: "Venmo", hint: "Enter your Venmo username" },
  { id: "custom", label: "Custom URL", hint: "Paste your payment page URL" },
];

function formatPhone(raw: string): string {
  const digits = raw.replace(/\D/g, "").slice(0, 10);
  if (digits.length <= 3) return digits;
  if (digits.length <= 6) return `(${digits.slice(0, 3)}) ${digits.slice(3)}`;
  return `(${digits.slice(0, 3)}) ${digits.slice(3, 6)}-${digits.slice(6)}`;
}

export default function SettingsScreen({ navigation }: { navigation: any }) {
  const { colors, shadow, preference, setTheme } = useTheme();
  const styles = useMemo(() => createStyles(colors, shadow), [colors, shadow]);

  const [s, setS] = useState<Settings | null>(null);
  const [saving, setSaving] = useState(false);
  const [deleting, setDeleting] = useState(false);
  const { isSubscribed, isTrialing } = useSubscription();

  const [stripeStatus, setStripeStatus] = useState<StripeStatus | null>(null);
  const [stripeConnecting, setStripeConnecting] = useState(false);
  const [stripeDisconnecting, setStripeDisconnecting] = useState(false);
  const appStateRef = useRef<AppStateStatus>(AppState.currentState);

  useEffect(() => {
    loadSettings().then((loaded) => {
      if (
        loaded.provider !== "stripe" &&
        loaded.providerKey &&
        !loaded.providerKeys?.[loaded.provider]
      ) {
        loaded = {
          ...loaded,
          providerKeys: { ...loaded.providerKeys, [loaded.provider]: loaded.providerKey },
        };
      }
      setS(loaded);
    });
  }, []);

  useEffect(() => {
    fetchStripeStatus();
    const sub = AppState.addEventListener("change", (nextState) => {
      if (appStateRef.current.match(/inactive|background/) && nextState === "active") {
        fetchStripeStatus();
      }
      appStateRef.current = nextState;
    });
    return () => sub.remove();
  }, []);

  async function fetchStripeStatus() {
    if (!VERCEL_URL) { setStripeStatus({ connected: false }); return; }
    try {
      const { data: { session } } = await supabase.auth.getSession();
      if (!session?.access_token) { setStripeStatus({ connected: false }); return; }
      const res = await fetch(`${VERCEL_URL}/api/stripe/connect-status`, {
        headers: { Authorization: `Bearer ${session.access_token}` },
      });
      const data = await res.json();
      if (res.ok) {
        setStripeStatus(data);
      } else {
        setStripeStatus({ connected: false, _error: data?.error });
      }
    } catch {
      setStripeStatus({ connected: false });
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
            Alert.alert("Error", (err as Error).message || "Could not disconnect Stripe account.");
          } finally {
            setStripeDisconnecting(false);
          }
        },
      },
    ]);
  }

  function update(field: string, value: unknown) {
    setS(prev => prev ? { ...prev, [field]: value } as Settings : prev);
  }

  function updateRule(index: number, days: string) {
    if (!s) return;
    const rules = [...s.rules];
    rules[index] = { days: parseInt(days) || 1 };
    setS(prev => prev ? { ...prev, rules } : prev);
  }

  function addRule() {
    setS(prev => prev ? { ...prev, rules: [...prev.rules, { days: 7 }] } : prev);
  }

  function removeRule(index: number) {
    setS(prev => {
      if (!prev) return prev;
      return { ...prev, rules: prev.rules.filter((_, i) => i !== index) };
    });
  }

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

  async function handleSave() {
    if (!s) return;
    setSaving(true);
    await saveSettings(s);
    syncNotifications();
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
        <SectionHeader title="Your business" />
        <View style={styles.card}>
          <Field label="Business name" value={s.businessName} onChangeText={(v) => update("businessName", v)} colors={colors} shadow={shadow} />
          <Field label="Your name" value={s.contactName} onChangeText={(v) => update("contactName", v)} colors={colors} shadow={shadow} />
          <Field label="Phone" value={s.phone} onChangeText={(v) => update("phone", formatPhone(v))} keyboardType="phone-pad" colors={colors} shadow={shadow} />
          <Field label="Email" value={s.email} onChangeText={(v) => update("email", v)} keyboardType="email-address" colors={colors} shadow={shadow} />
          <Field label="Payment instructions" value={s.paymentNotes} onChangeText={(v) => update("paymentNotes", v)} multiline autoCapitalize="sentences" colors={colors} shadow={shadow} />
          <Field label="Region" value={s.region || ""} onChangeText={(v) => update("region", v)} colors={colors} shadow={shadow} />
          <Text style={[styles.fieldLabel, { marginTop: spacing.sm }]}>Your trade</Text>
          <View style={styles.tradeGrid}>
            {TRADE_TYPES.map((t) => (
              <TouchableOpacity
                key={t.id}
                style={[styles.tradeBtn, s.trade === t.id && styles.tradeBtnActive]}
                onPress={() => update("trade", t.id)}
              >
                <Text style={[styles.tradeLabel, s.trade === t.id && styles.tradeLabelActive]}>{t.label}</Text>
              </TouchableOpacity>
            ))}
          </View>
        </View>

        <Divider />

        <SectionHeader title="Pricing defaults" />
        <Text style={styles.ruleSubtitle}>These pre-fill your estimate calculator. You can always override them per job.</Text>
        <View style={styles.card}>
          <Field label="Your hourly labor rate ($)" value={String(s.laborRate || "")} onChangeText={(v) => update("laborRate", parseFloat(v) || 0)} keyboardType="decimal-pad" colors={colors} shadow={shadow} />
          <Field label="Material markup (%)" value={String(s.materialMarkup || "")} onChangeText={(v) => update("materialMarkup", parseFloat(v) || 0)} keyboardType="decimal-pad" colors={colors} shadow={shadow} />
          <Field label="Overhead % (insurance, truck, tools)" value={String(s.overheadPercent || "")} onChangeText={(v) => update("overheadPercent", parseFloat(v) || 0)} keyboardType="decimal-pad" colors={colors} shadow={shadow} />
          <Field label="Profit margin %" value={String(s.marginPercent || "")} onChangeText={(v) => update("marginPercent", parseFloat(v) || 0)} keyboardType="decimal-pad" colors={colors} shadow={shadow} />
          <Field label="Minimum job fee ($)" value={String(s.minimumJobFee || "")} onChangeText={(v) => update("minimumJobFee", parseFloat(v) || 0)} keyboardType="decimal-pad" colors={colors} shadow={shadow} />
          <Field label="Emergency/after-hours multiplier (e.g. 1.5 = 50% extra)" value={String(s.emergencyMultiplier || "")} onChangeText={(v) => update("emergencyMultiplier", parseFloat(v) || 1)} keyboardType="decimal-pad" colors={colors} shadow={shadow} />
        </View>

        <Divider />

        <SectionHeader title="Mileage deduction" />
        <Text style={styles.ruleSubtitle}>
          Used to estimate your tax deduction from logged trips (Money → Mileage). Set this to the standard mileage rate for your tax year.
        </Text>
        <View style={styles.card}>
          <Field label="Mileage rate ($ per mile)" value={String(s.mileageRate ?? 0.70)} onChangeText={(v) => update("mileageRate", parseFloat(v) || 0)} keyboardType="decimal-pad" colors={colors} shadow={shadow} />
        </View>

        <Divider />

        <SectionHeader title="Payment processor" />
        <View style={styles.providerGrid}>
          {PROVIDERS.map((p) => (
            <TouchableOpacity
              key={p.id}
              style={[styles.providerBtn, s.provider === p.id && styles.providerBtnActive]}
              onPress={() => update("provider", p.id)}
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
                    <TouchableOpacity style={[styles.stripeBtn, stripeConnecting && { opacity: 0.5 }]} onPress={handleStripeConnect} disabled={stripeConnecting}>
                      {stripeConnecting ? <ActivityIndicator size="small" color={colors.accent} /> : <Text style={styles.stripeBtnText}>Complete setup</Text>}
                    </TouchableOpacity>
                  )}
                  <TouchableOpacity style={[styles.stripeBtnDanger, stripeDisconnecting && { opacity: 0.5 }]} onPress={handleStripeDisconnect} disabled={stripeDisconnecting}>
                    {stripeDisconnecting ? <ActivityIndicator size="small" color={colors.danger} /> : <Text style={styles.stripeBtnDangerText}>Disconnect</Text>}
                  </TouchableOpacity>
                </View>
              </>
            ) : (
              <>
                <Text style={styles.providerHint}>Connect your Stripe account to generate payment links for your customers. Payments go directly to your Stripe account.</Text>
                <TouchableOpacity style={[styles.stripeConnectBtn, stripeConnecting && { opacity: 0.5 }]} onPress={handleStripeConnect} disabled={stripeConnecting}>
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
              placeholder="Paste key or ID here"
              placeholderTextColor={colors.textMuted}
              autoCapitalize="none"
              autoCorrect={false}
              secureTextEntry={s.provider === "square"}
            />
            <Text style={styles.keyNote}>Stored only on your device. Never share it with anyone.</Text>
          </View>
        ) : null}

        <Divider />

        <SectionHeader title="AI Assistant" />
        <View style={styles.card}>
          <Text style={styles.providerHint}>Groq API key — powers the AI chat tab (estimates, advice, invoice messages). Get a free key at console.groq.com — no billing required.</Text>
          <TextInput style={styles.input} value={s.groqKey} onChangeText={(v) => update("groqKey", v)} placeholder="gsk_..." placeholderTextColor={colors.textMuted} autoCapitalize="none" autoCorrect={false} secureTextEntry />
          <Text style={styles.keyNote}>Stored only on your device. Never share this key.</Text>
        </View>
        <View style={[styles.card, { marginTop: spacing.sm }]}>
          <Text style={styles.providerHint}>Anthropic (Claude) API key — used for AI-generated invoice outreach messages. Get one at console.anthropic.com.</Text>
          <TextInput style={styles.input} value={s.anthropicKey} onChangeText={(v) => update("anthropicKey", v)} placeholder="sk-ant-..." placeholderTextColor={colors.textMuted} autoCapitalize="none" autoCorrect={false} secureTextEntry />
          <Text style={styles.keyNote}>Stored only on your device. Never share this key.</Text>
        </View>

        <Divider />

        <SectionHeader title="Appearance" />
        <View style={styles.card}>
          <Text style={styles.providerHint}>Choose how TradeReady looks on your device.</Text>
          <View style={styles.providerGrid}>
            {([{ key: "light", label: "Light" }, { key: "system", label: "System" }, { key: "dark", label: "Dark" }] as const).map((opt) => (
              <TouchableOpacity key={opt.key} style={[styles.providerBtn, preference === opt.key && styles.providerBtnActive]} onPress={() => setTheme(opt.key)}>
                <Text style={[styles.providerLabel, preference === opt.key && styles.providerLabelActive]}>{opt.label}</Text>
              </TouchableOpacity>
            ))}
          </View>
        </View>

        <Divider />

        <SectionHeader title="Notification rules" />
        <Text style={styles.ruleSubtitle}>Get notified when an invoice is this many days past due:</Text>
        {s.rules.map((rule, i) => (
          <View key={i} style={styles.ruleRow}>
            <TextInput style={styles.ruleInput} value={String(rule.days)} onChangeText={(v) => updateRule(i, v)} keyboardType="number-pad" maxLength={3} />
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

        <SectionHeader title="Review requests" />
        <Text style={styles.ruleSubtitle}>
          Automatically prompt customers for a Google review after you complete a job.
        </Text>
        <View style={styles.card}>
          <View style={styles.toggleRow}>
            <Text style={styles.toggleLabel}>Enable review requests</Text>
            <Switch
              value={s.reviewRequestEnabled}
              onValueChange={(v) => update("reviewRequestEnabled", v)}
              trackColor={{ true: colors.accent }}
            />
          </View>
        </View>
        {s.reviewRequestEnabled && (
          <>
            <View style={styles.card}>
              <Field
                label="Google review link"
                value={s.googleReviewLink}
                onChangeText={(v) => update("googleReviewLink", v)}
                autoCapitalize="none"
                colors={colors}
                shadow={shadow}
              />
              <Text style={styles.keyNote}>
                Find this in your Google Business Profile → "Ask for reviews" → copy the link.
              </Text>
            </View>
            <View style={styles.card}>
              <Field
                label="Delay after job completion (hours)"
                value={String(s.reviewRequestDelayHours || 3)}
                onChangeText={(v) => update("reviewRequestDelayHours", parseInt(v) || 3)}
                keyboardType="number-pad"
                colors={colors}
                shadow={shadow}
              />
            </View>
            <View style={styles.card}>
              <Field
                label="Message template"
                value={s.reviewRequestTemplate}
                onChangeText={(v) => update("reviewRequestTemplate", v)}
                multiline
                autoCapitalize="sentences"
                colors={colors}
                shadow={shadow}
              />
              <Text style={styles.keyNote}>
                Use {"{businessName}"}, {"{customerName}"}, and {"{googleReviewLink}"} as placeholders.
              </Text>
            </View>
          </>
        )}

        <Divider />

        <Button label="Save settings" onPress={handleSave} loading={saving} />

        <TouchableOpacity
          style={styles.clearSampleBtn}
          onPress={() => Alert.alert("Clear sample data", "This permanently removes all sample customers, jobs, and invoices. Your own data is not affected.", [
            { text: "Cancel", style: "cancel" },
            { text: "Clear sample data", style: "destructive", onPress: async () => { await clearSampleData(); Alert.alert("Done", "Sample data has been removed."); } },
          ])}
        >
          <Text style={styles.clearSampleText}>Clear Sample Data</Text>
        </TouchableOpacity>

        <TouchableOpacity
          style={styles.signOutBtn}
          onPress={async () => {
            const raw = await AsyncStorage.getItem("__syncQueue");
            const queue = raw ? JSON.parse(raw) : [];
            const doSignOut = async () => { resetUser(); await clearAllUserData(); await supabase.auth.signOut(); };
            if (queue.length > 0) {
              Alert.alert("Unsynced changes", "You have changes that haven't been saved to the cloud yet. Sync now to keep them.", [
                { text: "Cancel", style: "cancel" },
                { text: "Sync & sign out", onPress: async () => { const { data: { session } } = await supabase.auth.getSession(); if (session?.user?.id) await syncIfOnline(session.user.id); await doSignOut(); } },
                { text: "Sign out anyway", style: "destructive", onPress: doSignOut },
              ]);
            } else {
              Alert.alert("Sign out", "Are you sure you want to sign out?", [
                { text: "Cancel", style: "cancel" },
                { text: "Sign out", style: "destructive", onPress: doSignOut },
              ]);
            }
          }}
        >
          <Text style={styles.signOutText}>Sign Out</Text>
        </TouchableOpacity>

        <TouchableOpacity
          style={[styles.deleteAccountBtn, deleting && { opacity: 0.5 }]}
          disabled={deleting}
          onPress={() => Alert.alert("Delete account", "This permanently deletes your account and all your data — jobs, invoices, customers, and expenses. This cannot be undone.", [
            { text: "Cancel", style: "cancel" },
            {
              text: "Delete my account",
              style: "destructive",
              onPress: async () => {
                setDeleting(true);
                try {
                  const { data: { session } } = await supabase.auth.getSession();
                  if (!session?.access_token) { Alert.alert("Error", "No active session. Please sign in again."); return; }
                  const res = await fetch(`${VERCEL_URL}/api/delete-account`, {
                    method: "POST",
                    headers: { Authorization: `Bearer ${session.access_token}`, "Content-Type": "application/json" },
                  });
                  if (!res.ok) {
                    const body = await res.json().catch(() => ({}));
                    throw new Error(body.error || "Failed to delete account.");
                  }
                  resetUser();
                  await clearAllUserData();
                  await supabase.auth.signOut();
                } catch (err: unknown) {
                  Alert.alert("Error", (err as Error).message || "Something went wrong. Please try again.");
                } finally {
                  setDeleting(false);
                }
              },
            },
          ])}
        >
          <Text style={styles.deleteAccountText}>{deleting ? "Deleting account…" : "Delete Account"}</Text>
        </TouchableOpacity>

        <Divider />

        <SectionHeader title="Subscription" />
        <View style={styles.card}>
          {isTrialing ? (
            <View style={styles.subStatusRow}>
              <View style={[styles.subStatusDot, { backgroundColor: colors.warning }]} />
              <Text style={[styles.subStatusLabel, { color: colors.warning }]}>Free trial active</Text>
            </View>
          ) : isSubscribed ? (
            <View style={styles.subStatusRow}>
              <View style={[styles.subStatusDot, { backgroundColor: colors.success }]} />
              <Text style={[styles.subStatusLabel, { color: colors.success }]}>TradeReady Pro — active</Text>
            </View>
          ) : (
            <Text style={styles.providerHint}>Upgrade to TradeReady Pro to unlock all features.</Text>
          )}
          {isSubscribed || isTrialing ? (
            <TouchableOpacity style={[styles.stripeBtn, { marginTop: spacing.sm }]} onPress={async () => {
              try { await showManageSubscriptions(); } catch {
                const url = Platform.OS === "ios" ? "https://apps.apple.com/account/subscriptions" : "https://play.google.com/store/account/subscriptions";
                Linking.openURL(url);
              }
            }}>
              <Text style={styles.stripeBtnText}>Manage subscription</Text>
            </TouchableOpacity>
          ) : (
            <TouchableOpacity style={[styles.stripeConnectBtn, { marginTop: spacing.sm }]} onPress={() => navigation.navigate("PaywallModal", { canDismiss: true })}>
              <Text style={styles.stripeConnectBtnText}>Upgrade to Pro</Text>
            </TouchableOpacity>
          )}
        </View>

        <Divider />

        <SectionHeader title="Legal" />
        <View style={styles.card}>
          <TouchableOpacity style={styles.listRow} onPress={() => Linking.openURL(PRIVACY_URL)} activeOpacity={0.7}>
            <Text style={styles.listRowText}>Privacy Policy</Text>
            <Text style={styles.listRowChevron}>›</Text>
          </TouchableOpacity>
          <View style={styles.listRowDivider} />
          <TouchableOpacity style={styles.listRow} onPress={() => Linking.openURL(TERMS_URL)} activeOpacity={0.7}>
            <Text style={styles.listRowText}>Terms of Service</Text>
            <Text style={styles.listRowChevron}>›</Text>
          </TouchableOpacity>
        </View>
      </ScrollView>
    </SafeAreaView>
  );
}

interface FieldProps {
  label: string;
  value: string;
  onChangeText: (v: string) => void;
  keyboardType?: string;
  multiline?: boolean;
  autoCapitalize?: "none" | "sentences" | "words" | "characters";
  colors: ColorScheme;
  shadow: ShadowScheme;
}

function Field({ multiline, colors, shadow, ...props }: FieldProps) {
  const styles = useMemo(() => createStyles(colors, shadow), [colors, shadow]);
  return (
    <BaseField
      {...(props as any)}
      multiline={multiline}
      containerStyle={styles.fieldGroup}
      inputStyle={multiline ? [styles.input, styles.inputMultiline] : styles.input}
    />
  );
}

function createStyles(colors: ColorScheme, shadow: ShadowScheme) {
  return StyleSheet.create({
    container: { flex: 1, backgroundColor: colors.background },
    scroll: { padding: spacing.md, paddingBottom: 60 },
    card: { backgroundColor: colors.surface, borderRadius: radius.lg, padding: spacing.md, marginBottom: spacing.sm, ...shadow.card },
    fieldGroup: { marginBottom: spacing.sm },
    fieldLabel: { fontSize: fontSize.sm, color: colors.textSecondary, marginBottom: 5, fontWeight: "500" },
    input: { backgroundColor: colors.background, borderRadius: radius.md, height: 44, paddingHorizontal: spacing.md, fontSize: fontSize.md, color: colors.textPrimary, borderWidth: StyleSheet.hairlineWidth, borderColor: colors.border },
    inputMultiline: { height: 80, paddingTop: spacing.sm, textAlignVertical: "top" },
    providerGrid: { flexDirection: "row", flexWrap: "wrap", gap: 8, marginBottom: spacing.sm },
    providerBtn: { paddingHorizontal: 14, paddingVertical: 8, borderRadius: radius.full, borderWidth: 1, borderColor: colors.border, backgroundColor: colors.surface },
    providerBtnActive: { backgroundColor: colors.accentBg, borderColor: colors.accent },
    providerLabel: { fontSize: fontSize.sm, color: colors.textSecondary },
    providerLabelActive: { color: colors.accent, fontWeight: "600" },
    providerHint: { fontSize: fontSize.sm, color: colors.textSecondary, marginBottom: spacing.sm },
    keyNote: { fontSize: fontSize.xs, color: colors.textMuted, marginTop: 6 },
    ruleSubtitle: { fontSize: fontSize.sm, color: colors.textSecondary, marginBottom: spacing.sm },
    ruleRow: { flexDirection: "row", alignItems: "center", backgroundColor: colors.surface, borderRadius: radius.md, padding: spacing.sm, marginBottom: spacing.sm, ...shadow.card },
    ruleInput: { width: 56, height: 36, backgroundColor: colors.background, borderRadius: radius.sm, textAlign: "center", fontSize: fontSize.md, color: colors.textPrimary, borderWidth: StyleSheet.hairlineWidth, borderColor: colors.border, marginRight: spacing.sm },
    ruleSuffix: { flex: 1, fontSize: fontSize.sm, color: colors.textSecondary },
    removeBtn: { padding: spacing.sm },
    removeBtnText: { color: colors.danger, fontSize: fontSize.md },
    addRuleBtn: { paddingVertical: spacing.sm, alignItems: "center", borderRadius: radius.md, borderWidth: 1, borderColor: colors.border, borderStyle: "dashed", marginBottom: spacing.sm },
    addRuleBtnText: { fontSize: fontSize.sm, color: colors.accent, fontWeight: "500" },
    toggleRow: { flexDirection: "row", alignItems: "center", justifyContent: "space-between" },
    toggleLabel: { fontSize: fontSize.md, color: colors.textPrimary },
    clearSampleBtn: { marginTop: spacing.lg, paddingVertical: 14, alignItems: "center", borderRadius: radius.md, borderWidth: 1, borderColor: colors.border, backgroundColor: colors.surface },
    clearSampleText: { color: colors.textSecondary, fontSize: fontSize.md, fontWeight: "500" },
    signOutBtn: { marginTop: spacing.sm, paddingVertical: 14, alignItems: "center", borderRadius: radius.md, borderWidth: 1, borderColor: colors.danger + "50", backgroundColor: colors.dangerBg },
    signOutText: { color: colors.danger, fontSize: fontSize.md, fontWeight: "600" },
    deleteAccountBtn: { marginTop: spacing.sm, paddingVertical: 14, alignItems: "center", borderRadius: radius.md, backgroundColor: colors.danger },
    deleteAccountText: { color: "#fff", fontSize: fontSize.md, fontWeight: "600" },
    tradeGrid: { flexDirection: "row", flexWrap: "wrap", gap: 6, marginTop: 4 },
    tradeBtn: { paddingHorizontal: 12, paddingVertical: 7, borderRadius: radius.full, borderWidth: 1, borderColor: colors.border, backgroundColor: colors.background },
    tradeBtnActive: { backgroundColor: colors.accentBg, borderColor: colors.accent },
    tradeLabel: { fontSize: fontSize.sm, color: colors.textSecondary },
    tradeLabelActive: { color: colors.accent, fontWeight: "600" },
    listRow: { flexDirection: "row", alignItems: "center", paddingVertical: 13 },
    listRowText: { flex: 1, fontSize: fontSize.md, color: colors.textPrimary },
    listRowChevron: { fontSize: 20, color: colors.textMuted },
    listRowDivider: { height: StyleSheet.hairlineWidth, backgroundColor: colors.border },
    subStatusRow: { flexDirection: "row", alignItems: "center" },
    subStatusDot: { width: 8, height: 8, borderRadius: 4, marginRight: 8 },
    subStatusLabel: { fontSize: fontSize.sm, fontWeight: "600" },
    stripeConnectedRow: { flexDirection: "row", alignItems: "center", marginBottom: 6 },
    stripeConnectedDot: { width: 8, height: 8, borderRadius: 4, backgroundColor: colors.success, marginRight: 8 },
    stripeConnectedLabel: { fontSize: fontSize.sm, color: colors.success, fontWeight: "600" },
    stripeOnboardingHint: { fontSize: fontSize.sm, color: colors.textSecondary, marginBottom: spacing.sm },
    stripeButtonRow: { flexDirection: "row", gap: 8, marginTop: spacing.sm },
    stripeBtn: { paddingHorizontal: 16, paddingVertical: 8, borderRadius: radius.md, borderWidth: 1, borderColor: colors.accent, alignItems: "center", justifyContent: "center" },
    stripeBtnText: { fontSize: fontSize.sm, color: colors.accent, fontWeight: "600" },
    stripeBtnDanger: { paddingHorizontal: 16, paddingVertical: 8, borderRadius: radius.md, borderWidth: 1, borderColor: colors.danger + "80", alignItems: "center", justifyContent: "center" },
    stripeBtnDangerText: { fontSize: fontSize.sm, color: colors.danger },
    stripeConnectBtn: { marginTop: spacing.sm, paddingVertical: 12, borderRadius: radius.md, backgroundColor: colors.accent, alignItems: "center" },
    stripeConnectBtnText: { fontSize: fontSize.sm, color: "#fff", fontWeight: "700" },
  });
}
