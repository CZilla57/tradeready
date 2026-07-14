import { Platform } from 'react-native';
import Constants from 'expo-constants';
import type { CustomerInfo, PurchasesOfferings, PurchasesPackage, MakePurchaseResult } from 'react-native-purchases';

const RC_APPLE_KEY  = Constants.expoConfig?.extra?.rcAppleApiKey  ?? '';
const RC_GOOGLE_KEY = Constants.expoConfig?.extra?.rcGoogleApiKey ?? '';
const RC_API_KEY    = Platform.select({ ios: RC_APPLE_KEY, android: RC_GOOGLE_KEY, default: '' }) ?? '';

// Lazy-require so Expo Go doesn't crash on the unlinked native module.
let Purchases: any = null;
let PurchasesLogLevel: any = null;
try {
  // eslint-disable-next-line @typescript-eslint/no-require-imports -- react-native-purchases is an unlinked native module; static import crashes Expo Go and bare Jest
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

export async function getCustomerInfo(): Promise<CustomerInfo> {
  return Purchases.getCustomerInfo();
}

export async function getOfferings(): Promise<PurchasesOfferings> {
  return Purchases.getOfferings();
}

export async function purchasePackage(pkg: PurchasesPackage): Promise<MakePurchaseResult> {
  return Purchases.purchasePackage(pkg);
}

export async function restorePurchases(): Promise<CustomerInfo> {
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

// Per-product trial/intro eligibility. Only a definitive INELIGIBLE (status 1)
// marks a product false — UNKNOWN (0, the norm on Android and on iOS before
// StoreKit responds) keeps trial copy visible; the store's purchase sheet
// always shows the authoritative terms. Fails open to {} so the paywall
// renders normally in Expo Go and on any SDK error.
export async function checkTrialEligibility(productIds: string[]): Promise<Record<string, boolean>> {
  if (!RC_CONFIGURED || productIds.length === 0) return {};
  if (typeof Purchases.checkTrialOrIntroductoryPriceEligibility !== 'function') return {};
  try {
    const INELIGIBLE = 1;
    const result = await Purchases.checkTrialOrIntroductoryPriceEligibility(productIds);
    const map: Record<string, boolean> = {};
    for (const [id, info] of Object.entries(result ?? {})) {
      map[id] = (info as { status?: number })?.status !== INELIGIBLE;
    }
    return map;
  } catch {
    return {};
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
