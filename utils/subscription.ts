import { Platform } from 'react-native';
import Constants from 'expo-constants';

const RC_APPLE_KEY  = Constants.expoConfig?.extra?.rcAppleApiKey  ?? '';
const RC_GOOGLE_KEY = Constants.expoConfig?.extra?.rcGoogleApiKey ?? '';
const RC_API_KEY    = Platform.select({ ios: RC_APPLE_KEY, android: RC_GOOGLE_KEY, default: '' }) ?? '';

// Lazy-require so Expo Go doesn't crash on the unlinked native module.
let Purchases: any = null;
let PurchasesLogLevel: any = null;
try {
  const rc = require('react-native-purchases');
  Purchases         = rc.default ?? rc;
  PurchasesLogLevel = rc.LOG_LEVEL;
} catch {
  // Native module unavailable — Expo Go or simulator without dev build.
}

export const RC_CONFIGURED = Boolean(Purchases) && RC_API_KEY.length > 0;

export const ENTITLEMENT_ID = 'TradeReady Pro';

export function configurePurchases(): void {
  if (!RC_CONFIGURED) return;
  if (__DEV__ && PurchasesLogLevel) Purchases.setLogLevel(PurchasesLogLevel.DEBUG);
  Purchases.configure({ apiKey: RC_API_KEY });
}

export async function loginPurchases(userId: string): Promise<void> {
  if (!RC_CONFIGURED) return;
  try { await Purchases.logIn(userId); } catch { /* silent — non-fatal */ }
}

export async function logoutPurchases(): Promise<void> {
  if (!RC_CONFIGURED) return;
  try { await Purchases.logOut(); } catch { /* silent */ }
}

export async function getCustomerInfo(): Promise<unknown> {
  return Purchases.getCustomerInfo();
}

export async function getOfferings(): Promise<unknown> {
  return Purchases.getOfferings();
}

export async function purchasePackage(pkg: unknown): Promise<unknown> {
  return Purchases.purchasePackage(pkg);
}

export async function restorePurchases(): Promise<unknown> {
  return Purchases.restorePurchases();
}

export async function showManageSubscriptions(): Promise<void> {
  if (!RC_CONFIGURED) return;
  if (typeof Purchases.showManageSubscriptions === 'function') {
    await Purchases.showManageSubscriptions();
  } else {
    throw new Error('Not supported on this platform');
  }
}

export function isEntitlementActive(customerInfo: unknown): boolean {
  if (!RC_CONFIGURED) return true;
  return (customerInfo as any)?.entitlements?.active?.[ENTITLEMENT_ID] != null;
}

export function isTrialingEntitlement(customerInfo: unknown): boolean {
  return (customerInfo as any)?.entitlements?.active?.[ENTITLEMENT_ID]?.periodType === 'TRIAL';
}

export function addCustomerInfoListener(listener: (info: unknown) => void): () => void {
  if (!RC_CONFIGURED) return () => {};
  const sub = Purchases.addCustomerInfoUpdateListener(listener);
  return typeof sub === 'function' ? sub : () => sub?.remove?.();
}
