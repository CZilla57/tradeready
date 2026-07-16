// utils/rootGate.ts
// Pure decision core for RootNavigator's loading gate. After an explicit
// sign-out wipes the device, the truth about a returning user lives in the
// cloud until initialSync's pull lands — evaluating the onboarding gate
// before that treated every returning user as brand-new, re-ran onboarding,
// and the onboarding save then clobbered the pulled settings (2026-07-16
// incident). The App.tsx session effect therefore defers the onboarding
// check while AuthContext's `bootstrapping` flag (initialSync in flight) is
// raised, which keeps `onboardingDone` at null — so null is the single
// "no answer yet" signal here. A mid-session token refresh re-raises
// bootstrapping with onboardingDone already known; that must NOT show the
// spinner, which is why this gate deliberately does not consume the flag.

export interface RootGateArgs {
  initializing: boolean;
  hasSession: boolean;
  onboardingDone: boolean | null;
  subLoading: boolean;
}

export function rootGateLoading({
  initializing,
  hasSession,
  onboardingDone,
  subLoading,
}: RootGateArgs): boolean {
  if (initializing) return true;
  if (!hasSession) return false; // Auth screen renders immediately
  if (onboardingDone === null) return true;
  return onboardingDone && subLoading;
}
