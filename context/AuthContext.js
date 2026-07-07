import React, { createContext, useContext, useEffect, useState } from 'react';
import { AppState } from 'react-native';
import { supabase } from '../utils/supabase';
import { initialSync, syncIfOnline } from '../utils/sync';
import { setupNotifications, requestPermissions, syncNotifications } from '../utils/notifications';
import { clearAllUserData } from '../utils/storage';
import { configurePurchases, loginPurchases, logoutPurchases } from '../utils/subscription';

const AuthContext = createContext(null);

export function AuthProvider({ children }) {
  const [session, setSession] = useState(null);
  const [initializing, setInitializing] = useState(true);

  useEffect(() => {
    // configurePurchases must be called once at startup, before any logIn call.
    configurePurchases();
    setupNotifications();

    supabase.auth.getSession().then(({ data: { session } }) => {
      setSession(session);
      setInitializing(false);
      if (session?.user?.id) {
        loginPurchases(session.user.id);
        initialSync(session.user.id);
        requestPermissions().then(granted => { if (granted) syncNotifications(); });
      }
    });

    const { data: { subscription } } = supabase.auth.onAuthStateChange((_event, session) => {
      setSession(session);
      if (_event === 'SIGNED_OUT') {
        logoutPurchases();
        // Do NOT wipe local data here. The __dataOwner guard in initialSync
        // prevents a new user from inheriting stale data, and wiping here would
        // destroy offline changes made before a token-expiry sign-out.
        // Explicit sign-outs go through SettingsScreen, which calls
        // clearAllUserData() before supabase.auth.signOut().
        return;
      }
      if (session?.user?.id) {
        loginPurchases(session.user.id);
        initialSync(session.user.id);
        requestPermissions().then(granted => { if (granted) syncNotifications(); });
      }
    });

    return () => subscription.unsubscribe();
  }, []);

  // Sync whenever the app comes back to the foreground
  useEffect(() => {
    const sub = AppState.addEventListener('change', state => {
      if (state === 'active' && session?.user?.id) {
        syncIfOnline(session.user.id);
        syncNotifications();
      }
    });
    return () => sub.remove();
  }, [session]);

  return (
    <AuthContext.Provider value={{ session, initializing }}>
      {children}
    </AuthContext.Provider>
  );
}

export function useAuth() {
  return useContext(AuthContext);
}
