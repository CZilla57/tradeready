import React, { createContext, useContext, useEffect, useState } from 'react';
import { AppState } from 'react-native';
import type { Session } from '@supabase/supabase-js';
import { supabase } from '../utils/supabase';
import { initialSync, syncIfOnline } from '../utils/sync';
import { setupNotifications, requestPermissions, syncNotifications } from '../utils/notifications';
import { configurePurchases, loginPurchases, logoutPurchases } from '../utils/subscription';
import { checkAndGenerateRecurringJobs } from '../utils/recurringJobs';
import { checkAndGenerateRecurringInvoices } from '../utils/recurringInvoices';
import { identifyUser } from '../utils/analytics';
import { applyEstimateDecisions, applyBookingRequests } from '../utils/storage';
import { registerPushToken } from '../utils/pushToken';
import { replayWidgetActions } from '../utils/widgetActions';
import { uploadPendingPhotos, backfillMissingPhotos } from '../utils/photoSync';
import { registerBackgroundRefresh } from '../utils/backgroundRefresh';

interface AuthContextValue {
  session: Session | null;
  initializing: boolean;
  /** True while initialSync for the current session is in flight. The root
   *  gate must not evaluate onboarding state until this settles: after a
   *  sign-out wipe, local state says "new user" until the cloud pull lands,
   *  and evaluating early re-onboarded returning users whose onboarding save
   *  then clobbered the pulled settings (2026-07-16). */
  bootstrapping: boolean;
}

const AuthContext = createContext<AuthContextValue | null>(null);

export function AuthProvider({ children }: { children: React.ReactNode }) {
  const [session, setSession] = useState<Session | null>(null);
  const [initializing, setInitializing] = useState(true);
  const [bootstrapping, setBootstrapping] = useState(false);

  useEffect(() => {
    configurePurchases();
    setupNotifications();

    // initialSync never rejects (it catches internally); finally is a guard.
    const runInitialSync = (userId: string) => {
      setBootstrapping(true);
      initialSync(userId).finally(() => setBootstrapping(false));
    };

    supabase.auth.getSession().then(({ data: { session } }) => {
      setSession(session);
      setInitializing(false);
      if (session?.user?.id) {
        loginPurchases(session.user.id);
        runInitialSync(session.user.id);
        requestPermissions().then(granted => { if (granted) syncNotifications(); });
        identifyUser(session.user.id);
      }
    }).catch(() => {
      // The session lives in the iOS Keychain; on a background cold launch
      // with the device locked (BGTask wake, prewarming) the read can fail
      // with errSecInteractionNotAllowed (Sentry REACT-NATIVE-9). Settle the
      // root gate rather than hanging on the spinner — the auth listener
      // below picks the session up once it becomes readable.
      setInitializing(false);
    });

    // supabase-js starts its token auto-refresh ticker unconditionally in
    // React Native. Stop it while backgrounded: with the device locked, the
    // Keychain-backed session read fails (errSecInteractionNotAllowed) and
    // surfaces as an unhandled rejection (Sentry REACT-NATIVE-9). Nothing is
    // lost — getSession() still refreshes an expired token on demand during
    // background wakes (utils/backgroundRefresh.ts), and the 'active' branch
    // restarts the ticker on foreground.
    const appStateSub = AppState.addEventListener('change', state => {
      if (state === 'active') supabase.auth.startAutoRefresh();
      else supabase.auth.stopAutoRefresh();
    });
    if (AppState.currentState !== 'active') supabase.auth.stopAutoRefresh();

    const { data: { subscription } } = supabase.auth.onAuthStateChange((_event, session) => {
      setSession(session);
      if (_event === 'SIGNED_OUT') {
        logoutPurchases();
        // Do NOT wipe local data here. The __dataOwner guard in initialSync
        // prevents a new user from inheriting stale data, and wiping here would
        // destroy offline changes made before a token-expiry sign-out.
        // Explicit sign-outs go through SettingsAccountScreen, which calls
        // clearAllUserData() before supabase.auth.signOut().
        return;
      }
      if (session?.user?.id) {
        loginPurchases(session.user.id);
        identifyUser(session.user.id);
        runInitialSync(session.user.id);
        requestPermissions().then(granted => { if (granted) syncNotifications(); });
      }
    });

    return () => {
      subscription.unsubscribe();
      appStateSub.remove();
    };
  }, []);

  useEffect(() => {
    if (session?.user?.id) {
      checkAndGenerateRecurringJobs();
      checkAndGenerateRecurringInvoices();
      // Replay any widget/Siri actions queued while the app was closed, then
      // seed the widget snapshot at launch/sign-in; save paths keep it fresh
      // from here (no-op until the WidgetBridge native module ships).
      replayWidgetActions();
      // Register (or confirm) the periodic background wake so remote changes
      // and queued widget/Siri actions reach the widget even when the app
      // never opens again for a while. No-op until the EAS build that ships
      // expo-background-task's native module; sign-out deliberately leaves
      // this registered (see utils/backgroundRefresh.ts).
      registerBackgroundRefresh();
    }
    const sub = AppState.addEventListener('change', state => {
      if (state === 'active' && session?.user?.id) {
        syncIfOnline(session.user.id)
          .then(() => applyEstimateDecisions())
          .then(() => applyBookingRequests())
          .then(() => registerPushToken())
          // Mirror any job photos captured offline to R2, then pull down any
          // that other devices uploaded (reinstall self-heal + cross-device).
          .then(() => uploadPendingPhotos())
          .then(() => backfillMissingPhotos())
          // Replay queued widget/Siri actions, then re-mirror: remote changes
          // land via raw writes that never pass through the save-path mirror
          // hooks, and replayWidgetActions ends in its own refresh.
          .then(() => replayWidgetActions())
          .catch(() => {});
        syncNotifications();
        checkAndGenerateRecurringJobs();
        checkAndGenerateRecurringInvoices();
      }
    });
    return () => sub.remove();
  }, [session]);

  return (
    <AuthContext.Provider value={{ session, initializing, bootstrapping }}>
      {children}
    </AuthContext.Provider>
  );
}

export function useAuth(): AuthContextValue {
  const ctx = useContext(AuthContext);
  if (!ctx) throw new Error('useAuth must be used within AuthProvider');
  return ctx;
}
