// screens/OnboardingScreen.tsx
// Steps 1–2 of the three-step first-run flow (2026-08-03 restructure):
// Welcome (with the subscription/trial disclosure) → quick personalization
// (business name, your name, trade). The subscription decision and the
// sample-vs-fresh starting point come AFTER this wizard — see App.tsx's root
// gate and StartingPointScreen. Everything else the old five-step wizard
// collected (contact details, logo, labor rate, notifications, Stripe) moved
// to the in-product setup checklist on Today (utils/setupChecklist.ts).

import React, { useState, useRef, useEffect, useMemo } from "react";
import {
  View,
  Text,
  TouchableOpacity,
  ScrollView,
  StyleSheet,
  KeyboardAvoidingView,
  Platform,
  ActivityIndicator,
  Alert,
} from "react-native";
import { SafeAreaView } from "react-native-safe-area-context";
import { Ionicons } from "@expo/vector-icons";
import { spacing, radius, fontSize, fonts, layout, type ColorScheme, type ShadowScheme } from "../utils/theme";
import { useTheme } from "../hooks/useTheme";
import BaseField from "../components/Field";
import { TRADE_TYPES } from "../utils/pricingEngine";
import type { TradeId } from "../types/models";
import { saveSettings, defaultSettings, markOnboardingComplete, markOnboardingPersonalized } from "../utils/storage";
import {
  loadOnboardingDraft,
  saveOnboardingDraft,
  clearOnboardingDraft,
} from "../utils/onboardingDraft";
import { useAuth } from "../context/AuthContext";
import { track, reportError } from "../utils/analytics";

// The flow the user sees is 3 steps; this wizard renders the first two and
// StartingPointScreen (post-paywall) is step 3.
const FLOW_STEPS = 3;
const STEP_NAMES = ["Welcome", "Your business"];
const STEP_EVENT_NAMES = ["welcome", "business"];

interface OnboardingForm {
  businessName: string;
  contactName: string;
  trade: TradeId;
}

export default function OnboardingScreen({ onComplete }: { onComplete: () => void }) {
  const { colors, shadow } = useTheme();
  const styles = useMemo(() => createStyles(colors, shadow), [colors, shadow]);
  const [step, setStep] = useState(0);
  const [saving, setSaving] = useState(false);
  const [showErrors, setShowErrors] = useState(false);
  const [form, setForm] = useState<OnboardingForm>({
    businessName: "",
    contactName: "",
    trade: "plumbing",
  });

  const { session } = useAuth();

  // Draft autosave: an interruption (call, app kill) must not erase typed
  // input. Hydrate once, then persist debounced on every change.
  const hydratedRef = useRef(false);
  useEffect(() => {
    loadOnboardingDraft().then((draft) => {
      if (draft) {
        setForm({ businessName: draft.businessName, contactName: draft.contactName, trade: draft.trade });
        if (draft.step === 1) setStep(1);
      }
      hydratedRef.current = true;
    });
  }, []);

  const draftTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  useEffect(() => {
    if (!hydratedRef.current) return;
    if (draftTimerRef.current) clearTimeout(draftTimerRef.current);
    draftTimerRef.current = setTimeout(() => {
      saveOnboardingDraft({ ...form, step });
    }, 400);
    return () => {
      if (draftTimerRef.current) clearTimeout(draftTimerRef.current);
    };
  }, [form, step]);

  useEffect(() => {
    track("onboarding_step_viewed", { step: STEP_EVENT_NAMES[step] });
  }, [step]);

  function update<K extends keyof OnboardingForm>(field: K, value: OnboardingForm[K]) {
    setForm(prev => ({ ...prev, [field]: value }));
  }

  const businessNameMissing = !form.businessName.trim();
  const contactNameMissing  = !form.contactName.trim();

  async function finish() {
    setSaving(true);
    try {
      await saveSettings({
        ...defaultSettings(),
        businessName: form.businessName.trim(),
        contactName: form.contactName.trim(),
        trade: form.trade,
        // Silent prefill from the signed-in account — editable in Settings.
        email: session?.user?.email ?? "",
      });
      // Stage first: if the app dies between the two writes the user simply
      // redoes personalization; the reverse order could skip the start choice.
      await markOnboardingPersonalized();
      await markOnboardingComplete();
      await clearOnboardingDraft();
      track("onboarding_completed", { trade: form.trade });
      onComplete();
    } catch (err: unknown) {
      reportError(err, { context: "onboardingFinish" });
      Alert.alert(
        "Couldn't save your setup",
        "Something went wrong while saving your business info. Please try again."
      );
    } finally {
      setSaving(false);
    }
  }

  // Continue stays tappable even with missing fields; an invalid tap reveals
  // the required-field errors instead of a silently disabled button.
  function next() {
    if (step === 0) {
      setStep(1);
      return;
    }
    if (businessNameMissing || contactNameMissing) {
      setShowErrors(true);
      return;
    }
    finish();
  }

  function back() {
    setStep(s => s - 1);
  }

  return (
    <SafeAreaView style={styles.container} edges={["top", "bottom"]}>
      <Text style={styles.stepIndicator} accessibilityRole="header">
        Step {step + 1} of {FLOW_STEPS} · {STEP_NAMES[step]}
      </Text>

      <KeyboardAvoidingView style={styles.flex} behavior={Platform.OS === "ios" ? "padding" : "height"}>
        <ScrollView
          contentContainerStyle={styles.scroll}
          keyboardShouldPersistTaps="handled"
          keyboardDismissMode="on-drag"
          showsVerticalScrollIndicator={false}
        >
          {step === 0 && <StepWelcome />}
          {step === 1 && (
            <StepBusiness
              form={form}
              update={update}
              showErrors={showErrors}
              businessNameMissing={businessNameMissing}
              contactNameMissing={contactNameMissing}
            />
          )}
        </ScrollView>
      </KeyboardAvoidingView>

      <View style={styles.footer}>
        {step > 0 && (
          <TouchableOpacity style={styles.backBtn} onPress={back} accessibilityRole="button" accessibilityLabel="Back">
            <Text style={styles.backText}>Back</Text>
          </TouchableOpacity>
        )}
        <TouchableOpacity
          style={[styles.nextBtn, step === 0 && styles.nextBtnFull]}
          onPress={next}
          disabled={saving}
          activeOpacity={0.85}
          accessibilityRole="button"
          accessibilityLabel={step === 0 ? "Let's get started" : "Continue"}
          accessibilityState={{ busy: saving }}
        >
          {saving ? (
            <ActivityIndicator color="#fff" />
          ) : (
            <Text style={styles.nextText}>{step === 0 ? "Let's get started" : "Continue"}</Text>
          )}
        </TouchableOpacity>
      </View>
    </SafeAreaView>
  );
}

function StepWelcome() {
  const { colors, shadow } = useTheme();
  const styles = useMemo(() => createStyles(colors, shadow), [colors, shadow]);
  return (
    <View style={styles.stepContent}>
      <Text style={styles.appName}>TradeReady</Text>
      <Text style={styles.welcomeTagline}>Built to work. Ready to grow.</Text>
      <Text style={styles.welcomeBody}>
        Manage jobs, invoices, and customers — all in one place.
      </Text>
      <View style={styles.featureList}>
        {([
          ["calendar-outline", "Today", "Your schedule and earnings at a glance"],
          ["hammer-outline", "Jobs", "From lead to invoice in seconds"],
          ["cash-outline", "Invoices", "Send, track, and get paid faster"],
          ["sparkles-outline", "AI", "Your personal business assistant"],
        ] as const).map(([icon, title, desc]) => (
          <View key={title} style={styles.featureRow}>
            <Ionicons name={icon} size={22} color={colors.accent} style={styles.featureIcon} />
            <View style={styles.featureText}>
              <Text style={styles.featureTitle}>{title}</Text>
              <Text style={styles.featureDesc}>{desc}</Text>
            </View>
          </View>
        ))}
      </View>
      {/* Up-front disclosure: the old flow revealed the subscription only
          after five setup screens said "you're all set" — bait-and-switch
          feedback. Say what's coming before any effort is invested. */}
      <View style={styles.expectList}>
        <View style={styles.expectRow}>
          <Ionicons name="time-outline" size={18} color={colors.textSecondary} style={styles.expectIcon} />
          <Text style={styles.expectText}>Setup takes about a minute — just your name, business, and trade.</Text>
        </View>
        <View style={styles.expectRow}>
          <Ionicons name="card-outline" size={18} color={colors.textSecondary} style={styles.expectIcon} />
          <Text style={styles.expectText}>
            TradeReady is a subscription with a free trial. You'll see plans and pricing right after setup — cancel anytime.
          </Text>
        </View>
      </View>
    </View>
  );
}

interface StepBusinessProps {
  form: OnboardingForm;
  update: <K extends keyof OnboardingForm>(field: K, value: OnboardingForm[K]) => void;
  showErrors: boolean;
  businessNameMissing: boolean;
  contactNameMissing: boolean;
}

function StepBusiness({ form, update, showErrors, businessNameMissing, contactNameMissing }: StepBusinessProps) {
  const { colors, shadow } = useTheme();
  const styles = useMemo(() => createStyles(colors, shadow), [colors, shadow]);
  return (
    <View style={styles.stepContent}>
      <Text style={styles.stepTitle}>Your business</Text>
      <Text style={styles.stepSubtitle}>
        Just the basics — you can add contact details, your logo, and rates later.
      </Text>
      <Field label="Business name *" value={form.businessName} onChangeText={v => update("businessName", v)} placeholder="ABC Plumbing LLC" />
      {showErrors && businessNameMissing && (
        <Text style={styles.errorText} accessibilityLiveRegion="polite">Business name is required.</Text>
      )}
      <Field label="Your name *" value={form.contactName} onChangeText={v => update("contactName", v)} placeholder="John Smith" />
      {showErrors && contactNameMissing && (
        <Text style={styles.errorText} accessibilityLiveRegion="polite">Your name is required.</Text>
      )}

      <Text style={styles.tradeLabelHeader}>Your trade</Text>
      <Text style={styles.tradeHint}>Used to tailor job categories and smart pricing defaults.</Text>
      <View style={styles.tradeGrid}>
        {TRADE_TYPES.map(t => (
          <TouchableOpacity
            key={t.id}
            style={[styles.tradeBtn, form.trade === t.id && styles.tradeBtnActive]}
            onPress={() => update("trade", t.id)}
            accessibilityRole="radio"
            accessibilityLabel={t.label}
            accessibilityState={{ selected: form.trade === t.id }}
          >
            <Text style={[styles.tradeLabel, form.trade === t.id && styles.tradeLabelActive]}>{t.label}</Text>
          </TouchableOpacity>
        ))}
      </View>
    </View>
  );
}

interface FieldProps {
  label: string;
  value: string;
  onChangeText: (v: string) => void;
  placeholder?: string;
}

function Field(props: FieldProps) {
  const { colors, shadow } = useTheme();
  const styles = useMemo(() => createStyles(colors, shadow), [colors, shadow]);
  return (
    <BaseField
      containerStyle={styles.fieldGroup}
      labelStyle={styles.fieldLabel}
      inputStyle={styles.fieldInput}
      {...props}
    />
  );
}

function createStyles(colors: ColorScheme, shadow: ShadowScheme) {
  return StyleSheet.create({
    container: { flex: 1, backgroundColor: colors.background },
    flex: { flex: 1 },
    stepIndicator: {
      fontFamily: fonts.mono,
      fontSize: 12,
      color: colors.textSecondary,
      textAlign: "center",
      textTransform: "uppercase",
      letterSpacing: 1,
      paddingTop: spacing.md,
      paddingBottom: spacing.sm,
      ...layout.contentColumn,
    },
    scroll: { padding: spacing.lg, paddingBottom: spacing.xl, ...layout.contentColumn },
    stepContent: {},
    appName: { fontFamily: fonts.display, fontSize: 44, color: colors.accent, letterSpacing: -1, textAlign: "center", marginTop: spacing.xl },
    welcomeTagline: { fontFamily: fonts.mono, fontSize: 12, color: colors.textSecondary, textAlign: "center", textTransform: "uppercase", letterSpacing: 1.2, marginTop: spacing.sm, marginBottom: spacing.xl },
    welcomeBody: { fontFamily: fonts.bodyRegular, fontSize: fontSize.md, color: colors.textSecondary, textAlign: "center", lineHeight: 22, marginBottom: spacing.xl },
    featureList: { backgroundColor: colors.surface, borderRadius: radius.lg, padding: spacing.md, gap: spacing.md, ...shadow.card },
    featureRow: { flexDirection: "row", alignItems: "center", gap: spacing.md },
    featureIcon: { width: 26, textAlign: "center" },
    featureText: { flex: 1 },
    featureTitle: { fontFamily: fonts.bodySemiBold, fontSize: fontSize.md, color: colors.textPrimary },
    featureDesc: { fontFamily: fonts.bodyRegular, fontSize: fontSize.sm, color: colors.textSecondary, marginTop: 2 },
    expectList: { marginTop: spacing.lg, gap: spacing.sm },
    expectRow: { flexDirection: "row", alignItems: "flex-start", gap: spacing.sm },
    expectIcon: { marginTop: 2 },
    expectText: { fontFamily: fonts.bodyRegular, flex: 1, fontSize: fontSize.sm, color: colors.textSecondary, lineHeight: 20 },
    stepTitle: { fontFamily: fonts.display, fontSize: fontSize.xxl, color: colors.textPrimary, marginBottom: spacing.xs },
    stepSubtitle: { fontFamily: fonts.bodyRegular, fontSize: fontSize.md, color: colors.textSecondary, marginBottom: spacing.lg, lineHeight: 22 },
    fieldGroup: { marginBottom: spacing.md },
    fieldLabel: { fontFamily: fonts.bodySemiBold, fontSize: fontSize.sm, color: colors.textSecondary, marginBottom: spacing.xs },
    // minHeight (not height): a fixed height fought BaseField's multiline
    // sizing — the address input painted taller than its layout box and the
    // logo section rendered on top of it (device finding, 2026-07-14).
    fieldInput: { fontFamily: fonts.bodyRegular, backgroundColor: colors.surface, borderRadius: radius.md, minHeight: 48, paddingHorizontal: spacing.md, fontSize: fontSize.md, color: colors.textPrimary, borderWidth: StyleSheet.hairlineWidth, borderColor: colors.border, ...shadow.card },
    errorText: { fontFamily: fonts.bodyRegular, fontSize: fontSize.xs, color: colors.danger, marginTop: -spacing.sm, marginBottom: spacing.sm },
    tradeLabelHeader: { fontFamily: fonts.bodySemiBold, fontSize: fontSize.sm, color: colors.textSecondary, marginTop: spacing.sm, marginBottom: spacing.xs },
    tradeHint: { fontFamily: fonts.bodyRegular, fontSize: fontSize.xs, color: colors.textMuted, marginBottom: spacing.sm },
    tradeGrid: { flexDirection: "row", flexWrap: "wrap", gap: spacing.sm, marginBottom: spacing.lg },
    tradeBtn: { paddingHorizontal: 14, paddingVertical: 8, borderRadius: radius.full, borderWidth: 1, borderColor: colors.border, backgroundColor: colors.surface },
    tradeBtnActive: { backgroundColor: colors.accentBg, borderColor: colors.accent },
    tradeLabel: { fontFamily: fonts.bodyMedium, fontSize: fontSize.sm, color: colors.textSecondary },
    tradeLabelActive: { fontFamily: fonts.bodySemiBold, color: colors.accent },
    footer: { flexDirection: "row", padding: spacing.lg, gap: spacing.sm, borderTopWidth: StyleSheet.hairlineWidth, borderTopColor: colors.border, backgroundColor: colors.background, ...layout.contentColumn },
    backBtn: { height: 50, justifyContent: "center", alignItems: "center", paddingHorizontal: spacing.lg, borderRadius: radius.md, borderWidth: 1, borderColor: colors.border, backgroundColor: colors.surface },
    backText: { fontFamily: fonts.bodyMedium, fontSize: fontSize.md, color: colors.textSecondary },
    nextBtn: { flex: 1, height: 50, justifyContent: "center", alignItems: "center", backgroundColor: colors.accent, borderRadius: radius.md },
    nextBtnFull: { flex: 1 },
    nextText: { fontFamily: fonts.bodyBold, color: "#fff", fontSize: fontSize.md },
  });
}
