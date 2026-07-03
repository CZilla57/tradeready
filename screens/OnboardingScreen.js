import React, { useState } from 'react';
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
} from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';
import { colors, spacing, radius, fontSize, shadow } from '../utils/theme';
import { TRADE_TYPES } from '../utils/pricingEngine';
import { saveSettings, defaultSettings, markOnboardingComplete, clearSampleData } from '../utils/storage';
import { requestPermissions } from '../utils/notifications';

const STEPS = 5;

function formatPhone(raw) {
  const digits = raw.replace(/\D/g, '').slice(0, 10);
  if (digits.length <= 3) return digits;
  if (digits.length <= 6) return `(${digits.slice(0, 3)}) ${digits.slice(3)}`;
  return `(${digits.slice(0, 3)}) ${digits.slice(3, 6)}-${digits.slice(6)}`;
}

export default function OnboardingScreen({ onComplete }) {
  const [step, setStep] = useState(0);
  const [saving, setSaving] = useState(false);
  const [notifAsked, setNotifAsked] = useState(false);
  const [notifGranted, setNotifGranted] = useState(false);
  const [form, setForm] = useState({
    businessName: '',
    contactName: '',
    phone: '',
    email: '',
    trade: 'plumbing',
    laborRate: '85',
    dataChoice: 'sample', // 'sample' | 'fresh'
  });

  function update(field, value) {
    setForm(prev => ({ ...prev, [field]: value }));
  }

  function canContinue() {
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
    });
    if (form.dataChoice === 'fresh') {
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
    <SafeAreaView style={styles.container} edges={['top', 'bottom']}>
      <View style={styles.dots}>
        {Array.from({ length: STEPS }).map((_, i) => (
          <View key={i} style={[styles.dot, i <= step && styles.dotActive]} />
        ))}
      </View>

      <KeyboardAvoidingView
        style={styles.flex}
        behavior={Platform.OS === 'ios' ? 'padding' : 'height'}
      >
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
          style={[
            styles.nextBtn,
            !canContinue() && styles.nextBtnDisabled,
            step === 0 && styles.nextBtnFull,
          ]}
          onPress={next}
          disabled={!canContinue() || saving}
          activeOpacity={0.85}
        >
          {saving ? (
            <ActivityIndicator color="#fff" />
          ) : (
            <Text style={styles.nextText}>
              {step === 0
                ? "Let's get started"
                : step === STEPS - 1
                ? 'Start using TradeReady'
                : 'Continue'}
            </Text>
          )}
        </TouchableOpacity>
      </View>
    </SafeAreaView>
  );
}

function StepWelcome() {
  return (
    <View style={styles.stepContent}>
      <Text style={styles.appName}>TradeReady</Text>
      <Text style={styles.welcomeTagline}>Built to work. Ready to grow.</Text>
      <Text style={styles.welcomeBody}>
        Set up your account in 2 minutes and start managing jobs, invoices, and customers — all in one place.
      </Text>
      <View style={styles.featureList}>
        {[
          ['📅', 'Today', 'Your schedule and earnings at a glance'],
          ['🔨', 'Jobs', 'From lead to invoice in seconds'],
          ['💰', 'Invoices', 'Send, track, and get paid faster'],
          ['🤖', 'AI', 'Your personal business assistant'],
        ].map(([icon, title, desc]) => (
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

function StepBusiness({ form, update }) {
  return (
    <View style={styles.stepContent}>
      <Text style={styles.stepTitle}>Your business</Text>
      <Text style={styles.stepSubtitle}>
        This appears on your invoices and estimates.
      </Text>
      <Field
        label="Business name *"
        value={form.businessName}
        onChangeText={v => update('businessName', v)}
        placeholder="ABC Plumbing LLC"
      />
      <Field
        label="Your name *"
        value={form.contactName}
        onChangeText={v => update('contactName', v)}
        placeholder="John Smith"
      />
      <Field
        label="Phone"
        value={form.phone}
        onChangeText={v => update('phone', formatPhone(v))}
        placeholder="(555) 000-0000"
        keyboardType="phone-pad"
      />
      <Field
        label="Email"
        value={form.email}
        onChangeText={v => update('email', v)}
        placeholder="you@example.com"
        keyboardType="email-address"
        autoCapitalize="none"
      />
    </View>
  );
}

function StepTrade({ form, update }) {
  return (
    <View style={styles.stepContent}>
      <Text style={styles.stepTitle}>Your trade</Text>
      <Text style={styles.stepSubtitle}>
        Used to tailor job categories and smart pricing defaults.
      </Text>
      <View style={styles.tradeGrid}>
        {TRADE_TYPES.map(t => (
          <TouchableOpacity
            key={t.id}
            style={[styles.tradeBtn, form.trade === t.id && styles.tradeBtnActive]}
            onPress={() => update('trade', t.id)}
          >
            <Text style={[styles.tradeLabel, form.trade === t.id && styles.tradeLabelActive]}>
              {t.label}
            </Text>
          </TouchableOpacity>
        ))}
      </View>
      <Text style={styles.rateLabel}>Your hourly labor rate ($)</Text>
      <TextInput
        style={styles.rateInput}
        value={form.laborRate}
        onChangeText={v => update('laborRate', v)}
        keyboardType="decimal-pad"
        placeholder="85"
        placeholderTextColor={colors.textMuted}
      />
      <Text style={styles.rateNote}>You can adjust this any time in Settings.</Text>
    </View>
  );
}

function StepDataChoice({ form, update }) {
  const options = [
    {
      id: 'sample',
      emoji: '📊',
      title: 'Show me around',
      desc: 'Start with sample jobs, customers, and invoices already set up so you can explore the app right away.',
    },
    {
      id: 'fresh',
      emoji: '✨',
      title: 'Start fresh',
      desc: 'Begin with a clean slate. Add your own customers and jobs from day one.',
    },
  ];

  return (
    <View style={styles.stepContent}>
      <Text style={styles.stepTitle}>How do you want to start?</Text>
      <Text style={styles.stepSubtitle}>
        You can always clear sample data later from Settings.
      </Text>
      {options.map(opt => {
        const active = form.dataChoice === opt.id;
        return (
          <TouchableOpacity
            key={opt.id}
            style={[styles.dataCard, active && styles.dataCardActive]}
            onPress={() => update('dataChoice', opt.id)}
            activeOpacity={0.8}
          >
            <View style={styles.dataCardHeader}>
              <Text style={styles.dataCardEmoji}>{opt.emoji}</Text>
              <Text style={[styles.dataCardTitle, active && styles.dataCardTitleActive]}>
                {opt.title}
              </Text>
              <View style={[styles.radioOuter, active && styles.radioOuterActive]}>
                {active && <View style={styles.radioInner} />}
              </View>
            </View>
            <Text style={[styles.dataCardDesc, active && styles.dataCardDescActive]}>
              {opt.desc}
            </Text>
          </TouchableOpacity>
        );
      })}
    </View>
  );
}

function StepDone({ form, notifAsked, notifGranted, onRequestNotif }) {
  const firstName = form.contactName.trim().split(' ')[0] || 'there';
  return (
    <View style={styles.doneContent}>
      <Text style={styles.doneEmoji}>✅</Text>
      <Text style={styles.doneTitle}>You're all set, {firstName}!</Text>

      <View style={styles.notifCard}>
        <View style={styles.notifHeader}>
          <Text style={styles.notifIcon}>🔔</Text>
          <View style={styles.notifText}>
            <Text style={styles.notifTitle}>Invoice reminders</Text>
            <Text style={styles.notifDesc}>
              Get notified when invoices go overdue so nothing slips through the cracks.
            </Text>
          </View>
        </View>
        {notifAsked ? (
          <View style={styles.notifResult}>
            <Text style={styles.notifResultText}>
              {notifGranted ? '✅ Notifications enabled' : 'Notifications off — enable in device Settings any time.'}
            </Text>
          </View>
        ) : (
          <TouchableOpacity style={styles.notifBtn} onPress={onRequestNotif} activeOpacity={0.85}>
            <Text style={styles.notifBtnText}>Enable Notifications</Text>
          </TouchableOpacity>
        )}
      </View>

      <Text style={styles.doneBody}>
        Head to Settings any time to update your pricing defaults, payment processor, or AI assistant keys.
      </Text>
    </View>
  );
}

function Field({ label, value, onChangeText, placeholder, keyboardType, autoCapitalize }) {
  const cap = autoCapitalize ?? (keyboardType === 'email-address' ? 'none' : 'words');
  return (
    <View style={styles.fieldGroup}>
      <Text style={styles.fieldLabel}>{label}</Text>
      <TextInput
        style={styles.fieldInput}
        value={value}
        onChangeText={onChangeText}
        placeholder={placeholder}
        placeholderTextColor={colors.textMuted}
        keyboardType={keyboardType || 'default'}
        autoCapitalize={cap}
        autoCorrect={false}
      />
    </View>
  );
}

const styles = StyleSheet.create({
  container: { flex: 1, backgroundColor: colors.background },
  flex: { flex: 1 },
  dots: {
    flexDirection: 'row',
    justifyContent: 'center',
    gap: 6,
    paddingTop: spacing.md,
    paddingBottom: spacing.sm,
  },
  dot: { width: 8, height: 8, borderRadius: 4, backgroundColor: colors.border },
  dotActive: { backgroundColor: colors.accent },
  scroll: { padding: spacing.lg, paddingBottom: spacing.xl },
  stepContent: {},

  // Welcome
  appName: {
    fontSize: 44,
    fontWeight: '800',
    color: colors.accent,
    letterSpacing: -1,
    textAlign: 'center',
    marginTop: spacing.xl,
  },
  welcomeTagline: {
    fontSize: fontSize.lg,
    color: colors.textSecondary,
    textAlign: 'center',
    marginTop: spacing.xs,
    marginBottom: spacing.xl,
  },
  welcomeBody: {
    fontSize: fontSize.md,
    color: colors.textSecondary,
    textAlign: 'center',
    lineHeight: 22,
    marginBottom: spacing.xl,
  },
  featureList: {
    backgroundColor: colors.surface,
    borderRadius: radius.lg,
    padding: spacing.md,
    gap: spacing.md,
    ...shadow.card,
  },
  featureRow: { flexDirection: 'row', alignItems: 'center', gap: spacing.md },
  featureIcon: { fontSize: 24 },
  featureText: { flex: 1 },
  featureTitle: { fontSize: fontSize.md, fontWeight: '600', color: colors.textPrimary },
  featureDesc: { fontSize: fontSize.sm, color: colors.textSecondary, marginTop: 2 },

  // Step header
  stepTitle: {
    fontSize: fontSize.xxl,
    fontWeight: '700',
    color: colors.textPrimary,
    marginBottom: spacing.xs,
  },
  stepSubtitle: {
    fontSize: fontSize.md,
    color: colors.textSecondary,
    marginBottom: spacing.lg,
    lineHeight: 22,
  },

  // Field
  fieldGroup: { marginBottom: spacing.md },
  fieldLabel: {
    fontSize: fontSize.sm,
    fontWeight: '600',
    color: colors.textSecondary,
    marginBottom: spacing.xs,
  },
  fieldInput: {
    backgroundColor: colors.surface,
    borderRadius: radius.md,
    height: 48,
    paddingHorizontal: spacing.md,
    fontSize: fontSize.md,
    color: colors.textPrimary,
    borderWidth: StyleSheet.hairlineWidth,
    borderColor: colors.border,
    ...shadow.card,
  },

  // Trade
  tradeGrid: { flexDirection: 'row', flexWrap: 'wrap', gap: spacing.sm, marginBottom: spacing.lg },
  tradeBtn: {
    paddingHorizontal: 14,
    paddingVertical: 8,
    borderRadius: radius.full,
    borderWidth: 1,
    borderColor: colors.border,
    backgroundColor: colors.surface,
  },
  tradeBtnActive: { backgroundColor: colors.accentBg, borderColor: colors.accent },
  tradeLabel: { fontSize: fontSize.sm, color: colors.textSecondary },
  tradeLabelActive: { color: colors.accent, fontWeight: '600' },
  rateLabel: {
    fontSize: fontSize.sm,
    fontWeight: '600',
    color: colors.textSecondary,
    marginBottom: spacing.xs,
  },
  rateInput: {
    backgroundColor: colors.surface,
    borderRadius: radius.md,
    height: 48,
    paddingHorizontal: spacing.md,
    fontSize: fontSize.md,
    color: colors.textPrimary,
    borderWidth: StyleSheet.hairlineWidth,
    borderColor: colors.border,
    ...shadow.card,
  },
  rateNote: { fontSize: fontSize.xs, color: colors.textMuted, marginTop: spacing.xs },

  // Data choice
  dataCard: {
    backgroundColor: colors.surface,
    borderRadius: radius.lg,
    padding: spacing.md,
    marginBottom: spacing.md,
    borderWidth: 2,
    borderColor: colors.border,
    ...shadow.card,
  },
  dataCardActive: {
    borderColor: colors.accent,
    backgroundColor: colors.accentBg,
  },
  dataCardHeader: {
    flexDirection: 'row',
    alignItems: 'center',
    marginBottom: spacing.sm,
    gap: spacing.sm,
  },
  dataCardEmoji: { fontSize: 22 },
  dataCardTitle: {
    flex: 1,
    fontSize: fontSize.lg,
    fontWeight: '600',
    color: colors.textPrimary,
  },
  dataCardTitleActive: { color: colors.accent },
  dataCardDesc: { fontSize: fontSize.sm, color: colors.textSecondary, lineHeight: 20 },
  dataCardDescActive: { color: colors.accent + 'cc' },
  radioOuter: {
    width: 20,
    height: 20,
    borderRadius: 10,
    borderWidth: 2,
    borderColor: colors.border,
    alignItems: 'center',
    justifyContent: 'center',
  },
  radioOuterActive: { borderColor: colors.accent },
  radioInner: {
    width: 10,
    height: 10,
    borderRadius: 5,
    backgroundColor: colors.accent,
  },

  // Done
  doneContent: {
    alignItems: 'center',
    paddingTop: spacing.xl,
  },
  doneEmoji: { fontSize: 64, marginBottom: spacing.md },
  doneTitle: {
    fontSize: fontSize.xxl,
    fontWeight: '700',
    color: colors.textPrimary,
    textAlign: 'center',
    marginBottom: spacing.lg,
  },
  notifCard: {
    width: '100%',
    backgroundColor: colors.surface,
    borderRadius: radius.lg,
    padding: spacing.md,
    marginBottom: spacing.lg,
    ...shadow.card,
  },
  notifHeader: { flexDirection: 'row', gap: spacing.sm, marginBottom: spacing.md },
  notifIcon: { fontSize: 24 },
  notifText: { flex: 1 },
  notifTitle: { fontSize: fontSize.md, fontWeight: '600', color: colors.textPrimary, marginBottom: 2 },
  notifDesc: { fontSize: fontSize.sm, color: colors.textSecondary, lineHeight: 20 },
  notifBtn: {
    backgroundColor: colors.accent,
    borderRadius: radius.md,
    paddingVertical: 12,
    alignItems: 'center',
  },
  notifBtnText: { color: '#fff', fontSize: fontSize.md, fontWeight: '600' },
  notifResult: { paddingTop: spacing.xs },
  notifResultText: { fontSize: fontSize.sm, color: colors.textSecondary, textAlign: 'center' },
  doneBody: {
    fontSize: fontSize.md,
    color: colors.textSecondary,
    textAlign: 'center',
    lineHeight: 22,
    paddingHorizontal: spacing.md,
  },

  // Footer
  footer: {
    flexDirection: 'row',
    padding: spacing.lg,
    gap: spacing.sm,
    borderTopWidth: StyleSheet.hairlineWidth,
    borderTopColor: colors.border,
    backgroundColor: colors.background,
  },
  backBtn: {
    height: 50,
    justifyContent: 'center',
    alignItems: 'center',
    paddingHorizontal: spacing.lg,
    borderRadius: radius.md,
    borderWidth: 1,
    borderColor: colors.border,
    backgroundColor: colors.surface,
  },
  backText: { fontSize: fontSize.md, color: colors.textSecondary, fontWeight: '500' },
  nextBtn: {
    flex: 1,
    height: 50,
    justifyContent: 'center',
    alignItems: 'center',
    backgroundColor: colors.accent,
    borderRadius: radius.md,
  },
  nextBtnFull: { flex: 1 },
  nextBtnDisabled: { opacity: 0.5 },
  nextText: { color: '#fff', fontSize: fontSize.md, fontWeight: '700' },
});
