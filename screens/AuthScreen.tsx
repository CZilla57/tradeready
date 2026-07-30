import React, { useState, useMemo, useEffect } from 'react';
import {
  View,
  Text,
  TextInput,
  TouchableOpacity,
  StyleSheet,
  KeyboardAvoidingView,
  Platform,
  ActivityIndicator,
  Alert,
  ScrollView,
} from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import { Ionicons } from '@expo/vector-icons';
import Constants from 'expo-constants';
import { supabase } from '../utils/supabase';
import { spacing, radius, fontSize, type ColorScheme, type ShadowScheme } from '../utils/theme';
import { useTheme } from '../hooks/useTheme';
import { track } from '../utils/analytics';
import { canResend, resendSecondsRemaining } from '../utils/resendCooldown';
import { friendlyAuthError } from '../utils/authErrors';
import * as AppleAuthentication from 'expo-apple-authentication';
import { signInWithApple, signInWithGoogle } from '../utils/socialAuth';

type AuthMode = 'login' | 'signup' | 'forgot';

// Hosted page that exchanges the recovery token and lets the user set a new
// password (tradeready-legal/reset.html). Must be listed in the Supabase
// dashboard's Auth → URL Configuration → Redirect URLs or Supabase falls back
// to the project Site URL and the link dead-ends.
const PASSWORD_RESET_URL: string = Constants.expoConfig?.extra?.passwordResetUrl ?? '';
// Hosted landing page for the signup confirmation link (tradeready-legal/
// confirmed.html). Without an explicit redirect the link lands on the
// project's Site URL, which showed testers an error page. Must be in the
// Supabase Auth redirect allowlist, like the reset page.
const EMAIL_CONFIRMED_URL: string = Constants.expoConfig?.extra?.emailConfirmedUrl ?? '';

export default function AuthScreen() {
  const { colors, shadow, isDark } = useTheme();
  const styles = useMemo(() => createStyles(colors, shadow), [colors, shadow]);
  const insets = useSafeAreaInsets();
  const [mode, setMode] = useState<AuthMode>('login');
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState('');
  const [showPassword, setShowPassword] = useState(false);
  // Signup-confirmation resend: which address is waiting on a confirm link,
  // when we last (re)sent one, and a 1 Hz clock for the countdown label.
  const [pendingConfirmEmail, setPendingConfirmEmail] = useState<string | null>(null);
  const [resendLastSentAt, setResendLastSentAt] = useState<number | null>(null);
  // Same cooldown for password-reset sends — hammering the button just trips
  // Supabase's hourly email cap (beta finding: raw "rate limit exceeded").
  const [resetLastSentAt, setResetLastSentAt] = useState<number | null>(null);
  const [resendNow, setResendNow] = useState<number>(Date.now());
  const [resending, setResending] = useState(false);
  const [appleAvailable, setAppleAvailable] = useState(false);
  const [socialBusy, setSocialBusy] = useState<null | 'apple' | 'google'>(null);

  const resendReady = canResend(resendLastSentAt, resendNow);
  const resetReady = canResend(resetLastSentAt, resendNow);

  useEffect(() => {
    const cooling =
      (resendLastSentAt !== null && !canResend(resendLastSentAt, resendNow)) ||
      (resetLastSentAt !== null && !canResend(resetLastSentAt, resendNow));
    if (!cooling) return;
    const id = setInterval(() => setResendNow(Date.now()), 1000);
    return () => clearInterval(id);
  }, [resendLastSentAt, resetLastSentAt, resendNow]);

  useEffect(() => {
    if (Platform.OS !== 'ios') return;
    let active = true;
    AppleAuthentication.isAvailableAsync().then(v => { if (active) setAppleAvailable(v); });
    return () => { active = false; };
  }, []);

  async function handleSubmit() {
    if (mode === 'forgot') {
      if (!email.trim()) {
        setError('Please enter your email address.');
        return;
      }
      if (!resetReady) return;
      setError('');
      setLoading(true);
      try {
        const { error } = await supabase.auth.resetPasswordForEmail(
          email.trim(),
          PASSWORD_RESET_URL ? { redirectTo: PASSWORD_RESET_URL } : undefined
        );
        if (error) throw error;
        const now = Date.now();
        setResetLastSentAt(now);
        setResendNow(now);
        Alert.alert('Check your email', 'We sent a reset link to your email address.');
        setMode('login');
      } catch (e: unknown) {
        setError(friendlyAuthError((e as Error).message));
      } finally {
        setLoading(false);
      }
      return;
    }

    if (!email.trim() || !password) {
      setError('Please enter your email and password.');
      return;
    }
    if (mode === 'signup' && password.length < 6) {
      setError('Password must be at least 6 characters.');
      return;
    }
    setError('');
    setLoading(true);
    try {
      if (mode === 'login') {
        const { error } = await supabase.auth.signInWithPassword({ email: email.trim(), password });
        if (error) throw error;
      } else {
        const { error } = await supabase.auth.signUp({
          email: email.trim(),
          password,
          ...(EMAIL_CONFIRMED_URL ? { options: { emailRedirectTo: EMAIL_CONFIRMED_URL } } : {}),
        });
        if (error) throw error;
        track('sign_up');
        setPendingConfirmEmail(email.trim());
        Alert.alert(
          'Check your email',
          'We sent you a confirmation link. Click it to activate your account, then sign in here.'
        );
        setMode('login');
      }
    } catch (e: unknown) {
      setError(friendlyAuthError((e as Error).message));
    } finally {
      setLoading(false);
    }
  }

  async function handleResend() {
    if (!pendingConfirmEmail || resending) return;
    setResending(true);
    try {
      const { error } = await supabase.auth.resend({
        type: 'signup',
        email: pendingConfirmEmail,
        ...(EMAIL_CONFIRMED_URL ? { options: { emailRedirectTo: EMAIL_CONFIRMED_URL } } : {}),
      });
      if (error) throw error;
      track('sign_up_confirmation_resent');
      const now = Date.now();
      setResendLastSentAt(now);
      setResendNow(now);
      Alert.alert('Confirmation email sent', 'Check your inbox — and your spam folder, just in case.');
    } catch (e: unknown) {
      setError(friendlyAuthError((e as Error).message));
    } finally {
      setResending(false);
    }
  }

  async function handleApple() {
    setError('');
    setSocialBusy('apple');
    const res = await signInWithApple();
    setSocialBusy(null);
    if (res.ok) { track('sign_in', { method: 'apple' }); return; }
    if (!res.cancelled) setError(friendlyAuthError(res.error ?? ''));
  }

  async function handleGoogle() {
    setError('');
    setSocialBusy('google');
    const res = await signInWithGoogle();
    setSocialBusy(null);
    if (res.ok) { track('sign_in', { method: 'google' }); return; }
    if (!res.cancelled) setError(friendlyAuthError(res.error ?? ''));
  }

  function toggle() {
    setMode(m => (m === 'login' ? 'signup' : 'login'));
    setError('');
  }

  function goForgot() { setMode('forgot'); setError(''); }
  function goLogin()  { setMode('login');  setError(''); }

  const cardTitle =
    mode === 'forgot' ? 'Reset your password' :
    mode === 'login'  ? 'Sign in' :
                        'Create account';

  const submitLabel =
    mode === 'forgot' ? (resetReady ? 'Send reset link' : `Resend in ${resendSecondsRemaining(resetLastSentAt, resendNow)}s`) :
    mode === 'login'  ? 'Sign In' :
                        'Create Account';

  const submitDisabled = loading || (mode === 'forgot' && !resetReady);

  return (
    <KeyboardAvoidingView
      style={[styles.container, { paddingTop: insets.top, paddingBottom: insets.bottom }]}
      behavior={Platform.OS === 'ios' ? 'padding' : 'height'}
    >
      <ScrollView
        contentContainerStyle={styles.scroll}
        keyboardShouldPersistTaps="handled"
        showsVerticalScrollIndicator={false}
      >
        <View style={styles.header}>
          <Text style={styles.appName}>TradeReady</Text>
          <Text style={styles.tagline}>Built to Work. Ready to Grow.</Text>
        </View>

        <View style={styles.card}>
          <Text style={styles.cardTitle}>{cardTitle}</Text>

          {error ? <Text style={styles.errorText}>{error}</Text> : null}

          <Text style={styles.label}>Email</Text>
          <TextInput
            style={styles.input}
            value={email}
            onChangeText={setEmail}
            placeholder="you@example.com"
            placeholderTextColor={colors.textMuted}
            accessibilityLabel="Email address"
            keyboardType="email-address"
            autoCapitalize="none"
            autoCorrect={false}
            textContentType="username"
            autoComplete="email"
            returnKeyType="done"
          />

          {mode !== 'forgot' && (
            <>
              <Text style={styles.label}>Password</Text>
              <View style={styles.passwordWrap}>
                <TextInput
                  style={[styles.input, styles.inputWithToggle]}
                  value={password}
                  onChangeText={setPassword}
                  placeholder={mode === 'signup' ? 'Min. 6 characters' : '••••••••'}
                  placeholderTextColor={colors.textMuted}
                  secureTextEntry={!showPassword}
                  accessibilityLabel="Password"
                  autoCapitalize="none"
                  autoCorrect={false}
                  textContentType={mode === 'signup' ? 'newPassword' : 'password'}
                  autoComplete={mode === 'signup' ? 'new-password' : 'current-password'}
                  returnKeyType="done"
                />
                <TouchableOpacity
                  style={styles.showToggle}
                  onPress={() => setShowPassword(v => !v)}
                  hitSlop={{ top: 8, bottom: 8, left: 8, right: 8 }}
                  accessibilityRole="button"
                  accessibilityLabel={showPassword ? 'Hide password' : 'Show password'}
                >
                  <Ionicons
                    name={showPassword ? 'eye-off-outline' : 'eye-outline'}
                    size={20}
                    color={colors.textMuted}
                  />
                </TouchableOpacity>
              </View>
              {mode === 'login' && (
                <TouchableOpacity style={styles.toggle} onPress={goForgot} accessibilityRole="button" accessibilityLabel="Forgot password?">
                  <Text style={styles.toggleText}>
                    <Text style={styles.toggleLink}>Forgot password?</Text>
                  </Text>
                </TouchableOpacity>
              )}
            </>
          )}

          <TouchableOpacity
            style={[styles.submitBtn, submitDisabled && styles.submitBtnDisabled]}
            onPress={handleSubmit}
            disabled={submitDisabled}
            activeOpacity={0.85}
            accessibilityRole="button"
            accessibilityLabel={submitLabel}
            accessibilityState={{ disabled: submitDisabled, busy: loading }}
          >
            {loading
              ? <ActivityIndicator color="#fff" />
              : <Text style={styles.submitText}>{submitLabel}</Text>
            }
          </TouchableOpacity>
        </View>

        {mode !== 'forgot' && (
          <View style={styles.socialSection}>
            <View style={styles.dividerRow}>
              <View style={styles.dividerLine} />
              <Text style={styles.dividerText}>or</Text>
              <View style={styles.dividerLine} />
            </View>

            {appleAvailable && (
              <View testID="apple-signin-button" style={styles.appleWrap}>
                <AppleAuthentication.AppleAuthenticationButton
                  buttonType={AppleAuthentication.AppleAuthenticationButtonType.CONTINUE}
                  buttonStyle={
                    isDark
                      ? AppleAuthentication.AppleAuthenticationButtonStyle.WHITE
                      : AppleAuthentication.AppleAuthenticationButtonStyle.BLACK
                  }
                  cornerRadius={radius.md}
                  style={styles.appleBtn}
                  onPress={handleApple}
                />
              </View>
            )}

            <TouchableOpacity
              style={styles.googleBtn}
              onPress={handleGoogle}
              disabled={socialBusy !== null}
              activeOpacity={0.85}
              accessibilityRole="button"
              accessibilityLabel="Continue with Google"
              accessibilityState={{ disabled: socialBusy !== null, busy: socialBusy === 'google' }}
            >
              {socialBusy === 'google' ? (
                <ActivityIndicator color={colors.textPrimary} />
              ) : (
                <>
                  <Ionicons name="logo-google" size={18} color="#4285F4" style={styles.googleIcon} />
                  <Text style={styles.googleBtnText}>Continue with Google</Text>
                </>
              )}
            </TouchableOpacity>
          </View>
        )}

        {mode === 'login' && pendingConfirmEmail ? (
          <View style={styles.resendBox}>
            <Text style={styles.resendText}>
              We sent a confirmation link to {pendingConfirmEmail}. Didn't get it?
            </Text>
            <TouchableOpacity
              style={styles.resendBtn}
              onPress={handleResend}
              disabled={resending || !resendReady}
              accessibilityRole="button"
              accessibilityLabel="Resend confirmation email"
              accessibilityState={{ disabled: resending || !resendReady, busy: resending }}
            >
              <Text style={[styles.resendLink, (resending || !resendReady) && styles.resendLinkDisabled]}>
                {resending
                  ? 'Sending…'
                  : resendReady
                    ? 'Resend confirmation email'
                    : `Resend available in ${resendSecondsRemaining(resendLastSentAt, resendNow)}s`}
              </Text>
            </TouchableOpacity>
          </View>
        ) : null}

        {mode !== 'forgot' ? (
          <TouchableOpacity
            style={styles.toggle}
            onPress={toggle}
            accessibilityRole="button"
            accessibilityLabel={mode === 'login' ? 'Sign up' : 'Sign in'}
          >
            <Text style={styles.toggleText}>
              {mode === 'login' ? "Don't have an account? " : 'Already have an account? '}
              <Text style={styles.toggleLink}>
                {mode === 'login' ? 'Sign up' : 'Sign in'}
              </Text>
            </Text>
          </TouchableOpacity>
        ) : (
          <TouchableOpacity style={styles.toggle} onPress={goLogin} accessibilityRole="button" accessibilityLabel="Back to sign in">
            <Text style={styles.toggleText}>
              <Text style={styles.toggleLink}>Back to sign in</Text>
            </Text>
          </TouchableOpacity>
        )}
      </ScrollView>
    </KeyboardAvoidingView>
  );
}

function createStyles(colors: ColorScheme, shadow: ShadowScheme) {
  return StyleSheet.create({
    container: { flex: 1, backgroundColor: colors.background },
    scroll: {
      flexGrow: 1,
      justifyContent: 'center',
      paddingHorizontal: spacing.lg,
      paddingVertical: spacing.xl,
    },
    header: { alignItems: 'center', marginBottom: spacing.xl },
    appName: { fontSize: 40, fontWeight: '800', color: colors.accent, letterSpacing: -1 },
    tagline: { fontSize: fontSize.md, color: colors.textMuted, marginTop: spacing.xs },
    card: {
      backgroundColor: colors.surface,
      borderRadius: radius.lg,
      padding: spacing.lg,
      borderWidth: 1,
      borderColor: colors.border,
      ...shadow.card,
    },
    cardTitle: { fontSize: fontSize.xl, fontWeight: '700', color: colors.textPrimary, marginBottom: spacing.md },
    errorText: {
      fontSize: fontSize.sm,
      color: colors.danger,
      backgroundColor: colors.dangerBg,
      padding: spacing.sm,
      borderRadius: radius.sm,
      marginBottom: spacing.md,
    },
    label: {
      fontSize: fontSize.sm,
      fontWeight: '600',
      color: colors.textSecondary,
      marginBottom: spacing.xs,
      marginTop: spacing.sm,
    },
    input: {
      backgroundColor: colors.background,
      borderWidth: 1,
      borderColor: colors.border,
      borderRadius: radius.md,
      paddingHorizontal: spacing.md,
      paddingVertical: 12,
      fontSize: fontSize.md,
      color: colors.textPrimary,
    },
    passwordWrap: { justifyContent: 'center' },
    inputWithToggle: { paddingRight: 44 },
    showToggle: {
      position: 'absolute',
      right: 0,
      height: '100%',
      justifyContent: 'center',
      paddingHorizontal: spacing.sm,
    },
    submitBtn: {
      backgroundColor: colors.accent,
      borderRadius: radius.md,
      paddingVertical: 14,
      alignItems: 'center',
      marginTop: spacing.lg,
    },
    submitBtnDisabled: { opacity: 0.6 },
    submitText: { color: '#fff', fontSize: fontSize.md, fontWeight: '700' },
    resendBox: {
      marginTop: spacing.md,
      padding: spacing.md,
      backgroundColor: colors.surface,
      borderRadius: radius.md,
      borderWidth: 1,
      borderColor: colors.border,
    },
    resendText: { fontSize: fontSize.sm, color: colors.textSecondary, textAlign: 'center' },
    resendBtn: { alignItems: 'center', marginTop: spacing.sm, paddingVertical: spacing.xs },
    resendLink: { fontSize: fontSize.sm, color: colors.accent, fontWeight: '600' },
    resendLinkDisabled: { color: colors.textMuted, fontWeight: '400' },
    toggle: { alignItems: 'center', marginTop: spacing.lg, paddingVertical: spacing.sm },
    toggleText: { fontSize: fontSize.sm, color: colors.textMuted },
    toggleLink: { color: colors.accent, fontWeight: '600' },
    socialSection: { marginTop: spacing.lg },
    dividerRow: { flexDirection: 'row', alignItems: 'center', marginBottom: spacing.md },
    dividerLine: { flex: 1, height: 1, backgroundColor: colors.border },
    dividerText: { marginHorizontal: spacing.md, color: colors.textMuted, fontSize: fontSize.sm },
    appleWrap: { marginBottom: spacing.sm },
    appleBtn: { height: 48, width: '100%' },
    googleBtn: {
      flexDirection: 'row',
      alignItems: 'center',
      justifyContent: 'center',
      gap: spacing.sm,
      backgroundColor: colors.surface,
      borderWidth: 1,
      borderColor: colors.border,
      borderRadius: radius.md,
      paddingVertical: 12,
    },
    googleIcon: {},
    googleBtnText: { color: colors.textPrimary, fontSize: fontSize.md, fontWeight: '600' },
  });
}
