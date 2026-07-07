// utils/subscription.js
// RevenueCat SDK helpers. All RC interactions go through here so the rest of
// the app never imports react-native-purchases directly.
//
// RC_CONFIGURED is false when:
//   - Running in Expo Go (native module not linked)
//   - API keys are not set in app.json extra
//
// When RC_CONFIGURED is false, all checks return permissive defaults so
// development in Expo Go works without a paywall.

import { Platform } from 'react-native';
import Constants from 'expo-constants';

const RC_APPLE_KEY  = Constants.expoConfig?.extra?.rcAppleApiKey  ?? '';
const RC_GOOGLE_KEY = Constants.expoConfig?.extra?.rcGoogleApiKey ?? '';
const RC_API_KEY    = Platform.select({ ios: RC_APPLE_KEY, android: RC_GOOGLE_KEY, default: '' });

// Lazy-require so Expo Go doesn't crash on the unlinked native module.
let Purchases = null;
let PurchasesLogLevel = null;
try {
  const rc = require('react-native-purchases');
  Purchases       = rc.default ?? rc;
  PurchasesLogLevel = rc.LOG_LEVEL;
} catch {
  // Native module unavailable — Expo Go or simulator without dev build.
}

export const RC_CONFIGURED = Boolean(Purchases) && RC_API_KEY.length > 0;

export const ENTITLEMENT_ID = 'TradeReady Pro';

export function configurePurchases() {
  if (!RC_CONFIGURED) return;
  if (__DEV__ && PurchasesLogLevel) Purchases.setLogLevel(PurchasesLogLevel.DEBUG);
  Purchases.configure({ apiKey: RC_API_KEY });
}

export async function loginPurchases(userId) {
  if (!RC_CONFIGURED) return;
  try { await Purchases.logIn(userId); } catch { /* silent — non-fatal */ }
}

export async function logoutPurchases() {
  if (!RC_CONFIGURED) return;
  try { await Purchases.logOut(); } catch { /* silent */ }
}

export async function getCustomerInfo() {
  return Purchases.getCustomerInfo();
}

export async function getOfferings() {
  return Purchases.getOfferings();
}

export async function purchasePackage(pkg) {
  return Purchases.purchasePackage(pkg);
}

export async function restorePurchases() {
  return Purchases.restorePurchases();
}

export async function showManageSubscriptions() {
  if (!RC_CONFIGURED) return;
  if (typeof Purchases.showManageSubscriptions === 'function') {
    await Purchases.showManageSubscriptions();
  } else {
    throw new Error('Not supported on this platform');
  }
}

// Returns true if the user has an active 'pro' entitlement.
// Also returns true when RC is not configured (dev bypass).
export function isEntitlementActive(customerInfo) {
  if (!RC_CONFIGURED) return true;
  return customerInfo?.entitlements?.active?.[ENTITLEMENT_ID] != null;
}

// Returns true if the active entitlement is in its trial period.
export function isTrialingEntitlement(customerInfo) {
  return customerInfo?.entitlements?.active?.[ENTITLEMENT_ID]?.periodType === 'TRIAL';
}

// Add a listener that fires whenever customer info changes (e.g. after purchase).
// Returns a cleanup function.
export function addCustomerInfoListener(listener) {
  if (!RC_CONFIGURED) return () => {};
  const sub = Purchases.addCustomerInfoUpdateListener(listener);
  // RC SDK returns either a function or an EmitterSubscription depending on version.
  return typeof sub === 'function' ? sub : () => sub?.remove?.();
}
