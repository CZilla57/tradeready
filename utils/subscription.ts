import { Platform, Linking } from 'react-native';
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

// Guarded like its siblings: without the native module (Expo Go, simulator
// without a dev build) this used to throw a raw TypeError on a null Purchases,
// which the paywall reported as a connection problem. Returning no offerings
// instead lands on the paywall's designed "empty" state, which explains itself
// and offers a retry.
export async function getOfferings(): Promise<PurchasesOfferings> {
  if (!RC_CONFIGURED) return { all: {}, current: null } as PurchasesOfferings;
  return Purchases.getOfferings();
}

export async function purchasePackage(pkg: PurchasesPackage): Promise<MakePurchaseResult> {
  return Purchases.purchasePackage(pkg);
}

export async function restorePurchases(): Promise<CustomerInfo> {
  return Purchases.restorePurchases();
}

// Store deep link for managing subscriptions. iOS uses the itms-apps scheme so
// it opens the App Store's subscription screen directly instead of bouncing
// through a Safari page that a sandbox Apple ID cannot load.
const MANAGE_SUBSCRIPTIONS_URL = Platform.select({
  ios: 'itms-apps://apps.apple.com/account/subscriptions',
  android: 'https://play.google.com/store/account/subscriptions',
  default: '',
}) ?? '';

// Opens the platform's subscription-management UI. Tries RevenueCat's native
// StoreKit sheet first, then the store deep link. Returns false only when both
// paths fail, so the caller can show manual instructions instead of letting an
// error reach the user.
//
// App Review rejected 1.0(5) under guideline 2.1(a) for an error on this
// button, reviewed on an iPad running the iPhone-compatibility build against a
// sandbox account — an environment where the StoreKit sheet is unavailable.
// The previous version awaited only the native call and fired the fallback
// openURL without awaiting or catching it, so a second failure surfaced raw.
export async function openManageSubscriptions(): Promise<boolean> {
  if (RC_CONFIGURED && typeof Purchases.showManageSubscriptions === 'function') {
    try {
      await Purchases.showManageSubscriptions();
      return true;
    } catch {
      // Sheet unavailable — fall through to the store deep link.
    }
  }
  if (!MANAGE_SUBSCRIPTIONS_URL) return false;
  try {
    await Linking.openURL(MANAGE_SUBSCRIPTIONS_URL);
    return true;
  } catch {
    return false;
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
