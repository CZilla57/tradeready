import React, { useState, useRef, useEffect, useMemo } from "react";
import {
  View,
  Text,
  TextInput,
  TouchableOpacity,
  ScrollView,
  StyleSheet,
  KeyboardAvoidingView,
  Platform,
  ActivityIndicator,
} from "react-native";
import { SafeAreaView } from "react-native-safe-area-context";
import { spacing, radius, fontSize, type ColorScheme, type ShadowScheme } from "../utils/theme";
import { useTheme } from "../hooks/useTheme";
import BaseField from "../components/Field";
import { TRADE_TYPES } from "../utils/pricingEngine";
import type { TradeId } from "../types/models";
import { saveSettings, defaultSettings, markOnboardingComplete, clearSampleData } from "../utils/storage";
import { requestPermissions } from "../utils/notifications";
import { sendOnboardingAI } from "../utils/aiService";

const STEPS = 5;

interface OnboardingForm {
  businessName: string;
  contactName: string;
  phone: string;
  email: string;
  trade: TradeId;
  laborRate: string;
  region: string;
  dataChoice: "sample" | "fresh";
}

function formatPhone(raw: string): string {
  const digits = raw.replace(/\D/g, "").slice(0, 10);
  if (digits.length <= 3) return digits;
  if (digits.length <= 6) return `(${digits.slice(0, 3)}) ${digits.slice(3)}`;
  return `(${digits.slice(0, 3)}) ${digits.slice(3, 6)}-${digits.slice(6)}`;
}

export default function OnboardingScreen({ onComplete }: { onComplete: () => void }) {
  const { colors, shadow } = useTheme();
  const styles = useMemo(() => createStyles(colors, shadow), [colors, shadow]);
  const [step, setStep] = useState(0);
  const [saving, setSaving] = useState(false);
  const [notifAsked, setNotifAsked] = useState(false);
  const [notifGranted, setNotifGranted] = useState(false);
  const [form, setForm] = useState<OnboardingForm>({
    businessName: "",
    contactName: "",
    phone: "",
    email: "",
    trade: "plumbing",
    laborRate: "85",
    region: "",
    dataChoice: "sample",
  });

  function update<K extends keyof OnboardingForm>(field: K, value: OnboardingForm[K]) {
    setForm(prev => ({ ...prev, [field]: value }));
  }

  function canContinue(): boolean {
    if (step === 1) return form.businessName.trim().length > 0 && form.contactName.trim().length > 0;
    return true;
  }

  async function handleRequestNotif() {
    const granted = await requestPermissions();
    setNotifAsked(true);
    setNotifGranted(granted);
  }

  async function finish() {
    setSaving(true);
    await saveSettings({
      ...defaultSettings(),
      businessName: form.businessName.trim(),
      contactName: form.contactName.trim(),
      phone: form.phone,
      email: form.email,
      trade: form.trade,
      laborRate: parseFloat(form.laborRate) || 85,
      region: form.region.trim(),
    });
    if (form.dataChoice === "fresh") {
      await clearSampleData();
    }
    await markOnboardingComplete();
    onComplete();
  }

  function next() {
    if (step < STEPS - 1) {
      setStep(s => s + 1);
    } else {
      finish();
    }
  }

  function back() {
    setStep(s => s - 1);
  }

  return (
    <SafeAreaView style={styles.container} edges={["top", "bottom"]}>
      <View style={styles.dots}>
        {Array.from({ length: STEPS }).map((_, i) => (
          <View key={i} style={[styles.dot, i <= step && styles.dotActive]} />
        ))}
      </View>

      <KeyboardAvoidingView style={styles.flex} behavior={Platform.OS === "ios" ? "padding" : "height"}>
        <ScrollView
          contentContainerStyle={styles.scroll}
          keyboardShouldPersistTaps="handled"
          showsVerticalScrollIndicator={false}
        >
          {step === 0 && <StepWelcome />}
          {step === 1 && <StepBusiness form={form} update={update} />}
          {step === 2 && <StepTrade form={form} update={update} />}
          {step === 3 && <StepDataChoice form={form} update={update} />}
          {step === 4 && (
            <StepDone
              form={form}
              notifAsked={notifAsked}
              notifGranted={notifGranted}
              onRequestNotif={handleRequestNotif}
            />
          )}
        </ScrollView>
      </KeyboardAvoidingView>

      <View style={styles.footer}>
        {step > 0 && (
          <TouchableOpacity style={styles.backBtn} onPress={back}>
            <Text style={styles.backText}>Back</Text>
          </TouchableOpacity>
        )}
        <TouchableOpacity
          style={[styles.nextBtn, !canContinue() && styles.nextBtnDisabled, step === 0 && styles.nextBtnFull]}
          onPress={next}
          disabled={!canContinue() || saving}
          activeOpacity={0.85}
        >
          {saving ? (
            <ActivityIndicator color="#fff" />
          ) : (
            <Text style={styles.nextText}>
              {step === 0 ? "Let's get started" : step === STEPS - 1 ? "Start using TradeReady" : "Continue"}
            </Text>
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
        Set up your account in 2 minutes and start managing jobs, invoices, and customers — all in one place.
      </Text>
      <View style={styles.featureList}>
        {([
          ["📅", "Today", "Your schedule and earnings at a glance"],
          ["🔨", "Jobs", "From lead to invoice in seconds"],
          ["💰", "Invoices", "Send, track, and get paid faster"],
          ["🤖", "AI", "Your personal business assistant"],
        ] as const).map(([icon, title, desc]) => (
          <View key={title} style={styles.featureRow}>
            <Text style={styles.featureIcon}>{icon}</Text>
            <View style={styles.featureText}>
              <Text style={styles.featureTitle}>{title}</Text>
              <Text style={styles.featureDesc}>{desc}</Text>
            </View>
          </View>
        ))}
      </View>
    </View>
  );
}

interface StepProps {
  form: OnboardingForm;
  update: <K extends keyof OnboardingForm>(field: K, value: OnboardingForm[K]) => void;
}

function StepBusiness({ form, update }: StepProps) {
  const { colors, shadow } = useTheme();
  const styles = useMemo(() => createStyles(colors, shadow), [colors, shadow]);
  return (
    <View style={styles.stepContent}>
      <Text style={styles.stepTitle}>Your business</Text>
      <Text style={styles.stepSubtitle}>This appears on your invoices and estimates.</Text>
      <Field label="Business name *" value={form.businessName} onChangeText={v => update("businessName", v)} placeholder="ABC Plumbing LLC" />
      <Field label="Your name *" value={form.contactName} onChangeText={v => update("contactName", v)} placeholder="John Smith" />
      <Field label="Phone" value={form.phone} onChangeText={v => update("phone", formatPhone(v))} placeholder="(555) 000-0000" keyboardType="phone-pad" />
      <Field label="Email" value={form.email} onChangeText={v => update("email", v)} placeholder="you@example.com" keyboardType="email-address" autoCapitalize="none" />
    </View>
  );
}

function StepTrade({ form, update }: StepProps) {
  const { colors, shadow } = useTheme();
  const styles = useMemo(() => createStyles(colors, shadow), [colors, shadow]);
  const [tips, setTips] = useState<string[]>([]);
  const [tipsLoading, setTipsLoading] = useState(false);
  const tipsTradeRef = useRef<string>("");

  useEffect(() => {
    if (form.trade === tipsTradeRef.current) return;
    tipsTradeRef.current = form.trade;
    setTips([]);
    setTipsLoading(true);
    const tradeLabel = TRADE_TYPES.find(t => t.id === form.trade)?.label || form.trade;
    sendOnboardingAI({
      prompt: `Give 2-3 short, practical tips for someone starting a ${tradeLabel} business using a job management app. Each tip should be one sentence. Focus on how they'll use features like job tracking, invoicing, and estimates in their trade. Reply with ONLY a JSON array of strings.`,
    }).then(raw => {
      if (tipsTradeRef.current !== form.trade) return;
      try {
        const match = raw.match(/\[[\s\S]*\]/);
        if (match) {
          const parsed = JSON.parse(match[0]);
          if (Array.isArray(parsed)) setTips(parsed.map(String).slice(0, 3));
        }
      } catch {}
      setTipsLoading(false);
    });
  }, [form.trade]);

  return (
    <View style={styles.stepContent}>
      <Text style={styles.stepTitle}>Your trade</Text>
      <Text style={styles.stepSubtitle}>Used to tailor job categories and smart pricing defaults.</Text>
      <View style={styles.tradeGrid}>
        {TRADE_TYPES.map(t => (
          <TouchableOpacity
            key={t.id}
            style={[styles.tradeBtn, form.trade === t.id && styles.tradeBtnActive]}
            onPress={() => update("trade", t.id)}
          >
            <Text style={[styles.tradeLabel, form.trade === t.id && styles.tradeLabelActive]}>{t.label}</Text>
          </TouchableOpacity>
        ))}
      </View>

      {(tipsLoading || tips.length > 0) && (
        <View style={styles.aiCard}>
          {tipsLoading ? (
            <View style={styles.aiLoadingRow}>
              <ActivityIndicator size="small" color={colors.accent} />
              <Text style={styles.aiLoadingText}>Getting tips for your trade...</Text>
            </View>
          ) : (
            tips.map((tip, i) => (
              <View key={i} style={styles.tipRow}>
                <Text style={styles.tipBullet}>💡</Text>
                <Text style={styles.tipText}>{tip}</Text>
              </View>
            ))
          )}
        </View>
      )}

      <Text style={[styles.rateLabel, { marginTop: spacing.md }]}>Your region</Text>
      <TextInput
        style={styles.rateInput}
        value={form.region}
        onChangeText={v => update("region", v)}
        placeholder="e.g., Dallas, TX"
        placeholderTextColor={colors.textMuted}
      />
      <Text style={styles.rateNote}>Used to suggest competitive rates for your area.</Text>

      <RateSuggestion form={form} update={update} />
    </View>
  );
}

function RateSuggestion({ form, update }: StepProps) {
  const { colors, shadow } = useTheme();
  const styles = useMemo(() => createStyles(colors, shadow), [colors, shadow]);
  const [suggestion, setSuggestion] = useState<{ low: number; typical: number; high: number } | null>(null);
  const [loading, setLoading] = useState(false);
  const lastQueryRef = useRef("");

  useEffect(() => {
    const region = form.region.trim();
    if (region.length < 2) {
      setSuggestion(null);
      lastQueryRef.current = "";
      return;
    }
    const queryKey = `${form.trade}|${region}`;
    if (queryKey === lastQueryRef.current) return;

    const timeout = setTimeout(() => {
      lastQueryRef.current = queryKey;
      setSuggestion(null);
      setLoading(true);
      const tradeLabel = TRADE_TYPES.find(t => t.id === form.trade)?.label || form.trade;
      sendOnboardingAI({
        prompt: `What is a typical hourly labor rate for a ${tradeLabel} professional in ${region}? Reply with ONLY a JSON object: {"low": number, "typical": number, "high": number}. No other text.`,
      }).then(raw => {
        try {
          const match = raw.match(/\{[\s\S]*\}/);
          if (match) {
            const parsed = JSON.parse(match[0]);
            if (typeof parsed.low === "number" && typeof parsed.typical === "number" && typeof parsed.high === "number") {
              setSuggestion({ low: parsed.low, typical: parsed.typical, high: parsed.high });
            }
          }
        } catch {}
        setLoading(false);
      });
    }, 1000);

    return () => clearTimeout(timeout);
  }, [form.trade, form.region]);

  return (
    <>
      <Text style={[styles.rateLabel, { marginTop: spacing.md }]}>Your hourly labor rate ($)</Text>
      <TextInput
        style={styles.rateInput}
        value={form.laborRate}
        onChangeText={v => update("laborRate", v)}
        keyboardType="decimal-pad"
        placeholder="85"
        placeholderTextColor={colors.textMuted}
      />
      <Text style={styles.rateNote}>You can adjust this any time in Settings.</Text>

      {loading && (
        <View style={[styles.aiCard, { marginTop: spacing.sm }]}>
          <View style={styles.aiLoadingRow}>
            <ActivityIndicator size="small" color={colors.accent} />
            <Text style={styles.aiLoadingText}>Checking rates in your area...</Text>
          </View>
        </View>
      )}

      {suggestion && !loading && (
        <View style={[styles.aiCard, { marginTop: spacing.sm }]}>
          <Text style={styles.rateSuggestTitle}>
            Typical rate in {form.region.trim()}: ${suggestion.typical}/hr
          </Text>
          <Text style={styles.rateSuggestRange}>
            Range: ${suggestion.low} – ${suggestion.high}
          </Text>
          <TouchableOpacity
            style={styles.useRateBtn}
            onPress={() => update("laborRate", String(suggestion.typical))}
            activeOpacity={0.85}
          >
            <Text style={styles.useRateBtnText}>Use this rate</Text>
          </TouchableOpacity>
        </View>
      )}
    </>
  );
}

function StepDataChoice({ form, update }: StepProps) {
  const { colors, shadow } = useTheme();
  const styles = useMemo(() => createStyles(colors, shadow), [colors, shadow]);
  const options = [
    { id: "sample" as const, emoji: "📊", title: "Show me around", desc: "Start with sample jobs, customers, and invoices already set up so you can explore the app right away." },
    { id: "fresh" as const, emoji: "✨", title: "Start fresh", desc: "Begin with a clean slate. Add your own customers and jobs from day one." },
  ];

  return (
    <View style={styles.stepContent}>
      <Text style={styles.stepTitle}>How do you want to start?</Text>
      <Text style={styles.stepSubtitle}>You can always clear sample data later from Settings.</Text>
      {options.map(opt => {
        const active = form.dataChoice === opt.id;
        return (
          <TouchableOpacity
            key={opt.id}
            style={[styles.dataCard, active && styles.dataCardActive]}
            onPress={() => update("dataChoice", opt.id)}
            activeOpacity={0.8}
          >
            <View style={styles.dataCardHeader}>
              <Text style={styles.dataCardEmoji}>{opt.emoji}</Text>
              <Text style={[styles.dataCardTitle, active && styles.dataCardTitleActive]}>{opt.title}</Text>
              <View style={[styles.radioOuter, active && styles.radioOuterActive]}>
                {active && <View style={styles.radioInner} />}
              </View>
            </View>
            <Text style={[styles.dataCardDesc, active && styles.dataCardDescActive]}>{opt.desc}</Text>
          </TouchableOpacity>
        );
      })}
    </View>
  );
}

interface StepDoneProps {
  form: OnboardingForm;
  notifAsked: boolean;
  notifGranted: boolean;
  onRequestNotif: () => void;
}

function StepDone({ form, notifAsked, notifGranted, onRequestNotif }: StepDoneProps) {
  const { colors, shadow } = useTheme();
  const styles = useMemo(() => createStyles(colors, shadow), [colors, shadow]);
  const firstName = form.contactName.trim().split(" ")[0] || "there";
  const [actions, setActions] = useState<string[]>([]);
  const fetchedRef = useRef(false);

  useEffect(() => {
    if (fetchedRef.current) return;
    fetchedRef.current = true;
    const tradeLabel = TRADE_TYPES.find(t => t.id === form.trade)?.label || form.trade;
    const regionStr = form.region.trim() ? ` in ${form.region.trim()}` : "";
    sendOnboardingAI({
      prompt: `A ${tradeLabel} business owner named ${firstName} just set up their account in a job management app. Their business is ${form.businessName.trim()}${regionStr}. Suggest 3 specific first actions they should take in the app. Each action should be one short sentence starting with a verb. Reply with ONLY a JSON array of 3 strings.`,
    }).then(raw => {
      try {
        const match = raw.match(/\[[\s\S]*\]/);
        if (match) {
          const parsed = JSON.parse(match[0]);
          if (Array.isArray(parsed)) setActions(parsed.map(String).slice(0, 3));
        }
      } catch {}
    });
  }, [firstName, form.businessName, form.region, form.trade]);

  return (
    <View style={styles.doneContent}>
      <Text style={styles.doneEmoji}>✅</Text>
      <Text style={styles.doneTitle}>You're all set, {firstName}!</Text>
      <View style={styles.notifCard}>
        <View style={styles.notifHeader}>
          <Text style={styles.notifIcon}>🔔</Text>
          <View style={styles.notifText}>
            <Text style={styles.notifTitle}>Invoice reminders</Text>
            <Text style={styles.notifDesc}>Get notified when invoices go overdue so nothing slips through the cracks.</Text>
          </View>
        </View>
        {notifAsked ? (
          <View style={styles.notifResult}>
            <Text style={styles.notifResultText}>
              {notifGranted ? "✅ Notifications enabled" : "Notifications off — enable in device Settings any time."}
            </Text>
          </View>
        ) : (
          <TouchableOpacity style={styles.notifBtn} onPress={onRequestNotif} activeOpacity={0.85}>
            <Text style={styles.notifBtnText}>Enable Notifications</Text>
          </TouchableOpacity>
        )}
      </View>
      {actions.length > 0 ? (
        <View style={styles.aiCard}>
          <Text style={styles.actionsTitle}>Your first steps</Text>
          {actions.map((action, i) => (
            <View key={i} style={styles.tipRow}>
              <Text style={styles.tipBullet}>{i + 1}.</Text>
              <Text style={styles.tipText}>{action}</Text>
            </View>
          ))}
        </View>
      ) : (
        <Text style={styles.doneBody}>
          Head to Settings any time to update your pricing defaults, payment processor, or AI assistant keys.
        </Text>
      )}
    </View>
  );
}

interface FieldProps {
  label: string;
  value: string;
  onChangeText: (v: string) => void;
  placeholder?: string;
  keyboardType?: string;
  autoCapitalize?: "none" | "sentences" | "words" | "characters";
}

function Field(props: FieldProps) {
  const { colors, shadow } = useTheme();
  const styles = useMemo(() => createStyles(colors, shadow), [colors, shadow]);
  return (
    <BaseField
      containerStyle={styles.fieldGroup}
      labelStyle={styles.fieldLabel}
      inputStyle={styles.fieldInput}
      {...(props as any)}
    />
  );
}

function createStyles(colors: ColorScheme, shadow: ShadowScheme) {
  return StyleSheet.create({
    container: { flex: 1, backgroundColor: colors.background },
    flex: { flex: 1 },
    dots: { flexDirection: "row", justifyContent: "center", gap: 6, paddingTop: spacing.md, paddingBottom: spacing.sm },
    dot: { width: 8, height: 8, borderRadius: 4, backgroundColor: colors.border },
    dotActive: { backgroundColor: colors.accent },
    scroll: { padding: spacing.lg, paddingBottom: spacing.xl },
    stepContent: {},
    appName: { fontSize: 44, fontWeight: "800", color: colors.accent, letterSpacing: -1, textAlign: "center", marginTop: spacing.xl },
    welcomeTagline: { fontSize: fontSize.lg, color: colors.textSecondary, textAlign: "center", marginTop: spacing.xs, marginBottom: spacing.xl },
    welcomeBody: { fontSize: fontSize.md, color: colors.textSecondary, textAlign: "center", lineHeight: 22, marginBottom: spacing.xl },
    featureList: { backgroundColor: colors.surface, borderRadius: radius.lg, padding: spacing.md, gap: spacing.md, ...shadow.card },
    featureRow: { flexDirection: "row", alignItems: "center", gap: spacing.md },
    featureIcon: { fontSize: 24 },
    featureText: { flex: 1 },
    featureTitle: { fontSize: fontSize.md, fontWeight: "600", color: colors.textPrimary },
    featureDesc: { fontSize: fontSize.sm, color: colors.textSecondary, marginTop: 2 },
    stepTitle: { fontSize: fontSize.xxl, fontWeight: "700", color: colors.textPrimary, marginBottom: spacing.xs },
    stepSubtitle: { fontSize: fontSize.md, color: colors.textSecondary, marginBottom: spacing.lg, lineHeight: 22 },
    fieldGroup: { marginBottom: spacing.md },
    fieldLabel: { fontSize: fontSize.sm, fontWeight: "600", color: colors.textSecondary, marginBottom: spacing.xs },
    fieldInput: { backgroundColor: colors.surface, borderRadius: radius.md, height: 48, paddingHorizontal: spacing.md, fontSize: fontSize.md, color: colors.textPrimary, borderWidth: StyleSheet.hairlineWidth, borderColor: colors.border, ...shadow.card },
    tradeGrid: { flexDirection: "row", flexWrap: "wrap", gap: spacing.sm, marginBottom: spacing.lg },
    tradeBtn: { paddingHorizontal: 14, paddingVertical: 8, borderRadius: radius.full, borderWidth: 1, borderColor: colors.border, backgroundColor: colors.surface },
    tradeBtnActive: { backgroundColor: colors.accentBg, borderColor: colors.accent },
    tradeLabel: { fontSize: fontSize.sm, color: colors.textSecondary },
    tradeLabelActive: { color: colors.accent, fontWeight: "600" },
    rateLabel: { fontSize: fontSize.sm, fontWeight: "600", color: colors.textSecondary, marginBottom: spacing.xs },
    rateInput: { backgroundColor: colors.surface, borderRadius: radius.md, height: 48, paddingHorizontal: spacing.md, fontSize: fontSize.md, color: colors.textPrimary, borderWidth: StyleSheet.hairlineWidth, borderColor: colors.border, ...shadow.card },
    rateNote: { fontSize: fontSize.xs, color: colors.textMuted, marginTop: spacing.xs },
    dataCard: { backgroundColor: colors.surface, borderRadius: radius.lg, padding: spacing.md, marginBottom: spacing.md, borderWidth: 2, borderColor: colors.border, ...shadow.card },
    dataCardActive: { borderColor: colors.accent, backgroundColor: colors.accentBg },
    dataCardHeader: { flexDirection: "row", alignItems: "center", marginBottom: spacing.sm, gap: spacing.sm },
    dataCardEmoji: { fontSize: 22 },
    dataCardTitle: { flex: 1, fontSize: fontSize.lg, fontWeight: "600", color: colors.textPrimary },
    dataCardTitleActive: { color: colors.accent },
    dataCardDesc: { fontSize: fontSize.sm, color: colors.textSecondary, lineHeight: 20 },
    dataCardDescActive: { color: colors.accent + "cc" },
    radioOuter: { width: 20, height: 20, borderRadius: 10, borderWidth: 2, borderColor: colors.border, alignItems: "center", justifyContent: "center" },
    radioOuterActive: { borderColor: colors.accent },
    radioInner: { width: 10, height: 10, borderRadius: 5, backgroundColor: colors.accent },
    doneContent: { alignItems: "center", paddingTop: spacing.xl },
    doneEmoji: { fontSize: 64, marginBottom: spacing.md },
    doneTitle: { fontSize: fontSize.xxl, fontWeight: "700", color: colors.textPrimary, textAlign: "center", marginBottom: spacing.lg },
    notifCard: { width: "100%", backgroundColor: colors.surface, borderRadius: radius.lg, padding: spacing.md, marginBottom: spacing.lg, ...shadow.card },
    notifHeader: { flexDirection: "row", gap: spacing.sm, marginBottom: spacing.md },
    notifIcon: { fontSize: 24 },
    notifText: { flex: 1 },
    notifTitle: { fontSize: fontSize.md, fontWeight: "600", color: colors.textPrimary, marginBottom: 2 },
    notifDesc: { fontSize: fontSize.sm, color: colors.textSecondary, lineHeight: 20 },
    notifBtn: { backgroundColor: colors.accent, borderRadius: radius.md, paddingVertical: 12, alignItems: "center" },
    notifBtnText: { color: "#fff", fontSize: fontSize.md, fontWeight: "600" },
    notifResult: { paddingTop: spacing.xs },
    notifResultText: { fontSize: fontSize.sm, color: colors.textSecondary, textAlign: "center" },
    doneBody: { fontSize: fontSize.md, color: colors.textSecondary, textAlign: "center", lineHeight: 22, paddingHorizontal: spacing.md },
    footer: { flexDirection: "row", padding: spacing.lg, gap: spacing.sm, borderTopWidth: StyleSheet.hairlineWidth, borderTopColor: colors.border, backgroundColor: colors.background },
    backBtn: { height: 50, justifyContent: "center", alignItems: "center", paddingHorizontal: spacing.lg, borderRadius: radius.md, borderWidth: 1, borderColor: colors.border, backgroundColor: colors.surface },
    backText: { fontSize: fontSize.md, color: colors.textSecondary, fontWeight: "500" },
    nextBtn: { flex: 1, height: 50, justifyContent: "center", alignItems: "center", backgroundColor: colors.accent, borderRadius: radius.md },
    nextBtnFull: { flex: 1 },
    nextBtnDisabled: { opacity: 0.5 },
    nextText: { color: "#fff", fontSize: fontSize.md, fontWeight: "700" },
    aiCard: { backgroundColor: colors.surface, borderRadius: radius.lg, padding: spacing.md, marginTop: spacing.md, ...shadow.card },
    aiLoadingRow: { flexDirection: "row", alignItems: "center", gap: spacing.sm },
    aiLoadingText: { fontSize: fontSize.sm, color: colors.textMuted, fontStyle: "italic" },
    tipRow: { flexDirection: "row", gap: spacing.sm, marginTop: spacing.xs },
    tipBullet: { fontSize: fontSize.sm },
    tipText: { flex: 1, fontSize: fontSize.sm, color: colors.textSecondary, lineHeight: 20 },
    rateSuggestTitle: { fontSize: fontSize.md, fontWeight: "600", color: colors.textPrimary },
    rateSuggestRange: { fontSize: fontSize.sm, color: colors.textSecondary, marginTop: 2 },
    useRateBtn: { marginTop: spacing.sm, backgroundColor: colors.accent, borderRadius: radius.md, paddingVertical: 10, alignItems: "center" },
    useRateBtnText: { color: "#fff", fontSize: fontSize.sm, fontWeight: "600" },
    actionsTitle: { fontSize: fontSize.md, fontWeight: "600", color: colors.textPrimary, marginBottom: spacing.sm },
  });
}
