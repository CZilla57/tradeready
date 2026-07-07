// screens/PaywallScreen.js
// Subscription paywall shown in two contexts:
//   1. Hard gate (canDismiss=false, default): trial expired / no subscription.
//      Rendered by RootNavigator — user cannot bypass it.
//   2. Soft modal (canDismiss=true): navigated from Settings → "Upgrade".
//      Has a close button in the top-right corner.

import React, { useState, useEffect, useMemo } from 'react';
import {
  View,
  Text,
  ScrollView,
  TouchableOpacity,
  StyleSheet,
  ActivityIndicator,
  Alert,
  Linking,
  Platform,
} from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';
import { Ionicons } from '@expo/vector-icons';
import Constants from 'expo-constants';
import { useSubscription } from '../context/SubscriptionContext';
import { getOfferings, purchasePackage, restorePurchases, ENTITLEMENT_ID } from '../utils/subscription';
import { spacing, radius, fontSize } from '../utils/theme';
import { useTheme } from '../hooks/useTheme';

const PRIVACY_URL = Constants.expoConfig?.extra?.privacyPolicyUrl ?? '';
const TERMS_URL   = Constants.expoConfig?.extra?.termsUrl ?? '';

const FEATURES = [
  'Unlimited jobs, invoices & customers',
  'Trade pricing calculator with break-even alerts',
  'Stripe payment links — get paid fast',
  'P&L dashboard & expense tracking',
  'AI assistant for estimates & outreach messages',
  'Invoice reminder notifications',
];

export default function PaywallScreen({ route, navigation }) {
  const { colors, shadow } = useTheme();
  const styles = useMemo(() => createStyles(colors, shadow), [colors, shadow]);
  const canDismiss = route?.params?.canDismiss ?? false;
  const { refresh } = useSubscription();

  const [offerings, setOfferings]           = useState(null);
  const [selectedPkg, setSelectedPkg]       = useState(null);
  const [purchasing, setPurchasing]         = useState(false);
  const [restoring, setRestoring]           = useState(false);
  const [loadError, setLoadError]           = useState(null);

  useEffect(() => { loadOfferings(); }, []);

  async function loadOfferings() {
    setLoadError(null);
    try {
      const result = await getOfferings();
      const pkgs = result?.current?.availablePackages ?? [];
      setOfferings(pkgs);
      const annual = pkgs.find(p => p.packageType === 'ANNUAL');
      setSelectedPkg(annual ?? pkgs[0] ?? null);
    } catch {
      setLoadError('Could not load subscription options. Check your connection and try again.');
    }
  }

  async function handlePurchase() {
    if (!selectedPkg) return;
    setPurchasing(true);
    try {
      await purchasePackage(selectedPkg);
      await refresh();
      if (canDismiss && navigation?.canGoBack?.()) navigation.goBack();
    } catch (err) {
      if (!err.userCancelled) {
        Alert.alert('Purchase failed', err.message ?? 'Something went wrong. Please try again.');
      }
    } finally {
      setPurchasing(false);
    }
  }

  async function handleRestore() {
    setRestoring(true);
    try {
      const info = await restorePurchases();
      await refresh();
      const hasEntitlement = info?.entitlements?.active?.[ENTITLEMENT_ID] != null;
      if (hasEntitlement) {
        Alert.alert('Restored!', 'Your subscription has been restored.');
        if (canDismiss && navigation?.canGoBack?.()) navigation.goBack();
      } else {
        Alert.alert('Nothing to restore', "We couldn't find an active subscription for this account.");
      }
    } catch (err) {
      Alert.alert('Restore failed', err.message ?? 'Could not restore purchases. Please try again.');
    } finally {
      setRestoring(false);
    }
  }

  const monthlyPkg = offerings?.find(p => p.packageType === 'MONTHLY');
  const annualPkg  = offerings?.find(p => p.packageType === 'ANNUAL');
  const annualMonthlyCost = annualPkg
    ? `$${(annualPkg.product.price / 12).toFixed(2)}/mo`
    : null;

  return (
    <SafeAreaView style={styles.container} edges={['top', 'bottom']}>
      {canDismiss && (
        <TouchableOpacity
          style={styles.closeBtn}
          onPress={() => navigation.goBack()}
          hitSlop={{ top: 12, bottom: 12, left: 12, right: 12 }}
        >
          <Ionicons name="close" size={22} color={colors.textSecondary} />
        </TouchableOpacity>
      )}

      <ScrollView
        contentContainerStyle={styles.scroll}
        showsVerticalScrollIndicator={false}
      >
        {/* Header */}
        <View style={styles.header}>
          <View style={styles.iconWrap}>
            <Ionicons name="hammer" size={36} color={colors.accent} />
          </View>
          <Text style={styles.title}>TradeReady Pro</Text>
          <Text style={styles.subtitle}>Everything you need to run your trade business</Text>
        </View>

        {/* Trial badge */}
        <View style={styles.trialBadge}>
          <Ionicons name="gift-outline" size={15} color={colors.success} />
          <Text style={styles.trialBadgeText}>14-day free trial — no charge until it ends</Text>
        </View>

        {/* Feature list */}
        <View style={styles.featureCard}>
          {FEATURES.map((text, i) => (
            <View key={i} style={[styles.featureRow, i > 0 && styles.featureRowBorder]}>
              <View style={styles.checkCircle}>
                <Ionicons name="checkmark" size={12} color="#fff" />
              </View>
              <Text style={styles.featureText}>{text}</Text>
            </View>
          ))}
        </View>

        {/* Plan picker */}
        {loadError ? (
          <View style={styles.errorCard}>
            <Text style={styles.errorText}>{loadError}</Text>
            <TouchableOpacity style={styles.retryBtn} onPress={loadOfferings}>
              <Text style={styles.retryBtnText}>Try again</Text>
            </TouchableOpacity>
          </View>
        ) : offerings === null ? (
          <ActivityIndicator color={colors.accent} style={{ marginVertical: spacing.xl }} />
        ) : (
          <View style={styles.plans}>
            {annualPkg && (
              <TouchableOpacity
                style={[styles.planCard, selectedPkg?.packageType === 'ANNUAL' && styles.planCardSelected]}
                onPress={() => setSelectedPkg(annualPkg)}
                activeOpacity={0.85}
              >
                <View style={styles.planLeft}>
                  <View style={[styles.radio, selectedPkg?.packageType === 'ANNUAL' && styles.radioSelected]}>
                    {selectedPkg?.packageType === 'ANNUAL' && <View style={styles.radioDot} />}
                  </View>
                  <View>
                    <Text style={[styles.planName, selectedPkg?.packageType === 'ANNUAL' && styles.planNameSelected]}>
                      Annual
                    </Text>
                    {annualMonthlyCost && (
                      <Text style={styles.planSub}>{annualMonthlyCost} — billed yearly</Text>
                    )}
                  </View>
                </View>
                <View style={styles.planRight}>
                  <View style={styles.saveBadge}>
                    <Text style={styles.saveBadgeText}>BEST VALUE</Text>
                  </View>
                  <Text style={[styles.planPrice, selectedPkg?.packageType === 'ANNUAL' && styles.planPriceSelected]}>
                    {annualPkg.product.priceString}
                  </Text>
                </View>
              </TouchableOpacity>
            )}

            {monthlyPkg && (
              <TouchableOpacity
                style={[styles.planCard, selectedPkg?.packageType === 'MONTHLY' && styles.planCardSelected]}
                onPress={() => setSelectedPkg(monthlyPkg)}
                activeOpacity={0.85}
              >
                <View style={styles.planLeft}>
                  <View style={[styles.radio, selectedPkg?.packageType === 'MONTHLY' && styles.radioSelected]}>
                    {selectedPkg?.packageType === 'MONTHLY' && <View style={styles.radioDot} />}
                  </View>
                  <View>
                    <Text style={[styles.planName, selectedPkg?.packageType === 'MONTHLY' && styles.planNameSelected]}>
                      Monthly
                    </Text>
                    <Text style={styles.planSub}>billed monthly, cancel anytime</Text>
                  </View>
                </View>
                <Text style={[styles.planPrice, selectedPkg?.packageType === 'MONTHLY' && styles.planPriceSelected]}>
                  {monthlyPkg.product.priceString}
                </Text>
              </TouchableOpacity>
            )}
          </View>
        )}

        {/* CTA */}
        <TouchableOpacity
          style={[styles.cta, (!selectedPkg || purchasing) && styles.ctaDisabled]}
          onPress={handlePurchase}
          disabled={!selectedPkg || purchasing}
          activeOpacity={0.85}
        >
          {purchasing
            ? <ActivityIndicator color="#fff" />
            : <Text style={styles.ctaText}>Start Free Trial</Text>}
        </TouchableOpacity>

        <Text style={styles.ctaSub}>No charge for 14 days. Cancel anytime.</Text>

        {/* Restore */}
        <TouchableOpacity style={styles.restoreBtn} onPress={handleRestore} disabled={restoring}>
          {restoring
            ? <ActivityIndicator color={colors.textMuted} size="small" />
            : <Text style={styles.restoreText}>Restore purchases</Text>}
        </TouchableOpacity>

        {/* Legal */}
        <View style={styles.legalRow}>
          {PRIVACY_URL ? (
            <TouchableOpacity onPress={() => Linking.openURL(PRIVACY_URL)}>
              <Text style={styles.legalLink}>Privacy Policy</Text>
            </TouchableOpacity>
          ) : null}
          {PRIVACY_URL && TERMS_URL ? <Text style={styles.legalDot}> · </Text> : null}
          {TERMS_URL ? (
            <TouchableOpacity onPress={() => Linking.openURL(TERMS_URL)}>
              <Text style={styles.legalLink}>Terms of Service</Text>
            </TouchableOpacity>
          ) : null}
        </View>

        <Text style={styles.legalNote}>
          Subscription renews automatically unless cancelled at least 24 hours before the end of
          the current period. Manage in your{' '}
          {Platform.OS === 'ios' ? 'Apple ID' : 'Google Play'} account settings.
        </Text>
      </ScrollView>
    </SafeAreaView>
  );
}

function createStyles(colors, shadow) {
  return StyleSheet.create({
    container:    { flex: 1, backgroundColor: colors.background },
    closeBtn:     { position: 'absolute', top: 52, right: 20, zIndex: 10, padding: 4 },
    scroll:       { padding: spacing.lg, paddingTop: spacing.xl, paddingBottom: 48 },

    header:       { alignItems: 'center', marginBottom: spacing.lg },
    iconWrap: {
      width: 72, height: 72, borderRadius: 20,
      backgroundColor: colors.accentBg,
      alignItems: 'center', justifyContent: 'center',
      marginBottom: spacing.md,
    },
    title:    { fontSize: fontSize.xxl, fontWeight: '800', color: colors.textPrimary, marginBottom: 6 },
    subtitle: { fontSize: fontSize.md, color: colors.textSecondary, textAlign: 'center' },

    trialBadge: {
      flexDirection: 'row', alignItems: 'center', gap: 6,
      backgroundColor: colors.successBg,
      borderRadius: radius.full,
      paddingVertical: 8, paddingHorizontal: 14,
      alignSelf: 'center', marginBottom: spacing.lg,
    },
    trialBadgeText: { fontSize: fontSize.sm, color: colors.success, fontWeight: '600' },

    featureCard: {
      backgroundColor: colors.surface, borderRadius: radius.lg,
      padding: spacing.md, marginBottom: spacing.lg, ...shadow.card,
    },
    featureRow:       { flexDirection: 'row', alignItems: 'center', paddingVertical: 8, gap: 12 },
    featureRowBorder: { borderTopWidth: StyleSheet.hairlineWidth, borderTopColor: colors.border },
    checkCircle: {
      width: 22, height: 22, borderRadius: 11,
      backgroundColor: colors.success,
      alignItems: 'center', justifyContent: 'center',
      flexShrink: 0,
    },
    featureText: { flex: 1, fontSize: fontSize.sm, color: colors.textPrimary },

    plans: { gap: spacing.sm, marginBottom: spacing.md },
    planCard: {
      backgroundColor: colors.surface, borderRadius: radius.lg,
      padding: spacing.md,
      flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between',
      borderWidth: 2, borderColor: colors.border,
      ...shadow.card,
    },
    planCardSelected: { borderColor: colors.accent, backgroundColor: colors.accentBg },
    planLeft:         { flexDirection: 'row', alignItems: 'center', gap: 12, flex: 1 },
    planRight:        { alignItems: 'flex-end', gap: 4 },
    radio: {
      width: 20, height: 20, borderRadius: 10,
      borderWidth: 2, borderColor: colors.border,
      alignItems: 'center', justifyContent: 'center',
    },
    radioSelected: { borderColor: colors.accent },
    radioDot:      { width: 10, height: 10, borderRadius: 5, backgroundColor: colors.accent },
    planName:         { fontSize: fontSize.md, fontWeight: '600', color: colors.textPrimary },
    planNameSelected: { color: colors.accent },
    planSub:          { fontSize: fontSize.xs, color: colors.textSecondary, marginTop: 2 },
    saveBadge:        { backgroundColor: colors.success, paddingHorizontal: 6, paddingVertical: 2, borderRadius: radius.sm },
    saveBadgeText:    { fontSize: 10, fontWeight: '700', color: '#fff', letterSpacing: 0.5 },
    planPrice:        { fontSize: fontSize.md, fontWeight: '700', color: colors.textPrimary },
    planPriceSelected: { color: colors.accent },

    errorCard: {
      backgroundColor: colors.dangerBg, borderRadius: radius.lg,
      padding: spacing.md, marginBottom: spacing.md, alignItems: 'center',
    },
    errorText:    { fontSize: fontSize.sm, color: colors.danger, marginBottom: spacing.sm, textAlign: 'center' },
    retryBtn:     { paddingVertical: 8, paddingHorizontal: 16, backgroundColor: colors.danger, borderRadius: radius.md },
    retryBtnText: { color: '#fff', fontWeight: '600', fontSize: fontSize.sm },

    cta: {
      backgroundColor: colors.accent, borderRadius: radius.lg,
      paddingVertical: 16, alignItems: 'center', marginBottom: spacing.sm,
    },
    ctaDisabled: { opacity: 0.6 },
    ctaText:     { fontSize: fontSize.lg, fontWeight: '700', color: '#fff' },
    ctaSub:      { textAlign: 'center', fontSize: fontSize.xs, color: colors.textSecondary, marginBottom: spacing.lg },

    restoreBtn:  { alignItems: 'center', paddingVertical: spacing.sm, marginBottom: spacing.md },
    restoreText: { fontSize: fontSize.sm, color: colors.textMuted },

    legalRow:  { flexDirection: 'row', justifyContent: 'center', alignItems: 'center', marginBottom: spacing.sm },
    legalLink: { fontSize: fontSize.xs, color: colors.textMuted },
    legalDot:  { fontSize: fontSize.xs, color: colors.textMuted },
    legalNote: { fontSize: fontSize.xs, color: colors.textMuted, textAlign: 'center', lineHeight: 17 },
  });
}
