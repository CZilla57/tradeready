import React, { useState, useMemo } from 'react';
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
import Constants from 'expo-constants';
import { supabase } from '../utils/supabase';
import { spacing, radius, fontSize, type ColorScheme, type ShadowScheme } from '../utils/theme';
import { useTheme } from '../hooks/useTheme';
import { track } from '../utils/analytics';

type AuthMode = 'login' | 'signup' | 'forgot';

// Hosted page that exchanges the recovery token and lets the user set a new
// password (tradeready-legal/reset.html). Must be listed in the Supabase
// dashboard's Auth → URL Configuration → Redirect URLs or Supabase falls back
// to the project Site URL and the link dead-ends.
const PASSWORD_RESET_URL: string = Constants.expoConfig?.extra?.passwordResetUrl ?? '';

export default function AuthScreen() {
  const { colors, shadow } = useTheme();
  const styles = useMemo(() => createStyles(colors, shadow), [colors, shadow]);
  const insets = useSafeAreaInsets();
  const [mode, setMode] = useState<AuthMode>('login');
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState('');

  async function handleSubmit() {
    if (mode === 'forgot') {
      if (!email.trim()) {
        setError('Please enter your email address.');
        return;
      }
      setError('');
      setLoading(true);
      try {
        const { error } = await supabase.auth.resetPasswordForEmail(
          email.trim(),
          PASSWORD_RESET_URL ? { redirectTo: PASSWORD_RESET_URL } : undefined
        );
        if (error) throw error;
        Alert.alert('Check your email', 'We sent a reset link to your email address.');
        setMode('login');
      } catch (e: unknown) {
        setError((e as Error).message);
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
        const { error } = await supabase.auth.signUp({ email: email.trim(), password });
        if (error) throw error;
        track('sign_up');
        Alert.alert(
          'Check your email',
          'We sent you a confirmation link. Click it to activate your account, then sign in here.'
        );
        setMode('login');
      }
    } catch (e: unknown) {
      setError((e as Error).message);
    } finally {
      setLoading(false);
    }
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
    mode === 'forgot' ? 'Send reset link' :
    mode === 'login'  ? 'Sign In' :
                        'Create Account';

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
          />

          {mode !== 'forgot' && (
            <>
              <Text style={styles.label}>Password</Text>
              <TextInput
                style={styles.input}
                value={password}
                onChangeText={setPassword}
                placeholder={mode === 'signup' ? 'Min. 6 characters' : '••••••••'}
                placeholderTextColor={colors.textMuted}
                secureTextEntry
                accessibilityLabel="Password"
              />
              {mode === 'login' && (
                <TouchableOpacity style={styles.toggle} onPress={goForgot}>
                  <Text style={styles.toggleText}>
                    <Text style={styles.toggleLink}>Forgot password?</Text>
                  </Text>
                </TouchableOpacity>
              )}
            </>
          )}

          <TouchableOpacity
            style={[styles.submitBtn, loading && styles.submitBtnDisabled]}
            onPress={handleSubmit}
            disabled={loading}
            activeOpacity={0.85}
          >
            {loading
              ? <ActivityIndicator color="#fff" />
              : <Text style={styles.submitText}>{submitLabel}</Text>
            }
          </TouchableOpacity>
        </View>

        {mode !== 'forgot' ? (
          <TouchableOpacity style={styles.toggle} onPress={toggle}>
            <Text style={styles.toggleText}>
              {mode === 'login' ? "Don't have an account? " : 'Already have an account? '}
              <Text style={styles.toggleLink}>
                {mode === 'login' ? 'Sign up' : 'Sign in'}
              </Text>
            </Text>
          </TouchableOpacity>
        ) : (
          <TouchableOpacity style={styles.toggle} onPress={goLogin}>
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
    submitBtn: {
      backgroundColor: colors.accent,
      borderRadius: radius.md,
      paddingVertical: 14,
      alignItems: 'center',
      marginTop: spacing.lg,
    },
    submitBtnDisabled: { opacity: 0.6 },
    submitText: { color: '#fff', fontSize: fontSize.md, fontWeight: '700' },
    toggle: { alignItems: 'center', marginTop: spacing.lg, paddingVertical: spacing.sm },
    toggleText: { fontSize: fontSize.sm, color: colors.textMuted },
    toggleLink: { color: colors.accent, fontWeight: '600' },
  });
}
