import {
  createContext,
  useContext,
  useEffect,
  useState,
  type ReactNode,
} from 'react';
import type { Session } from '@supabase/supabase-js';
import { supabase } from './supabase';

// Flag that keeps the app in password-recovery mode after Supabase's one-shot
// PASSWORD_RECOVERY event. It lives in localStorage — the same store Supabase
// persists the session in (see ./supabase) — not sessionStorage, so it travels
// with the recovery session into every tab. The one-shot event only fires in
// the tab that consumed the link; a second tab (or a reopened one) restores the
// session from localStorage but never sees that event, so a tab-local flag
// would leave it treating the recovery session as an ordinary login and letting
// it into the portal before the password is changed. A stale flag left with no
// live session is dropped on init (see below).
const RECOVERY_FLAG = 'tradeready.passwordRecovery';

function readRecoveryFlag(): boolean {
  try {
    return localStorage.getItem(RECOVERY_FLAG) === '1';
  } catch {
    return false;
  }
}

function writeRecoveryFlag(on: boolean): void {
  try {
    if (on) localStorage.setItem(RECOVERY_FLAG, '1');
    else localStorage.removeItem(RECOVERY_FLAG);
  } catch {
    // Private-mode / disabled storage: recovery still works within the current
    // render via React state; only cross-reload/cross-tab persistence is lost.
  }
}

interface AuthValue {
  session: Session | null;
  initializing: boolean;
  /**
   * True once Supabase has established a password-recovery session (via the
   * PASSWORD_RECOVERY event). While true the app must route to the
   * password-update screen instead of the normal authenticated portal.
   */
  recovery: boolean;
  signIn: (email: string, password: string) => Promise<void>;
  signUp: (email: string, password: string) => Promise<void>;
  signInWithGoogle: () => Promise<void>;
  signInWithApple: () => Promise<void>;
  resetPassword: (email: string) => Promise<void>;
  updatePassword: (password: string) => Promise<void>;
  clearRecovery: () => void;
  signOut: () => Promise<void>;
}

const AuthCtx = createContext<AuthValue | null>(null);

export function AuthProvider({ children }: { children: ReactNode }) {
  const [session, setSession] = useState<Session | null>(null);
  const [initializing, setInitializing] = useState(true);
  const [recovery, setRecovery] = useState<boolean>(readRecoveryFlag);

  useEffect(() => {
    supabase.auth
      .getSession()
      .then(({ data }) => {
        setSession(data.session);
        // A persisted recovery flag with no live session is stale — the recovery
        // session expired or was already used/cleared elsewhere. Drop it so a
        // later ordinary sign-in isn't trapped on the recovery screen. When a
        // session IS present the flag stands, so a recovery session restored in a
        // fresh tab (which never sees the one-shot event) still routes to the
        // password-update screen.
        if (!data.session) {
          setRecovery(false);
          writeRecoveryFlag(false);
        }
      })
      .finally(() => setInitializing(false));

    const {
      data: { subscription },
    } = supabase.auth.onAuthStateChange((event, next) => {
      if (event === 'PASSWORD_RECOVERY') {
        setRecovery(true);
        writeRecoveryFlag(true);
      } else if (event === 'SIGNED_OUT') {
        setRecovery(false);
        writeRecoveryFlag(false);
      }
      setSession(next);
    });
    return () => subscription.unsubscribe();
  }, []);

  const value: AuthValue = {
    session,
    initializing,
    recovery,
    async signIn(email, password) {
      const { error } = await supabase.auth.signInWithPassword({
        email: email.trim(),
        password,
      });
      if (error) throw error;
    },
    async signUp(email, password) {
      const { error } = await supabase.auth.signUp({
        email: email.trim(),
        password,
      });
      if (error) throw error;
    },
    async signInWithGoogle() {
      const { error } = await supabase.auth.signInWithOAuth({
        provider: 'google',
        options: { redirectTo: window.location.origin },
      });
      if (error) throw error;
    },
    async signInWithApple() {
      const { error } = await supabase.auth.signInWithOAuth({
        provider: 'apple',
        options: { redirectTo: window.location.origin },
      });
      if (error) throw error;
    },
    async resetPassword(email) {
      // Land recovery links on the dedicated password-update route rather than
      // the app root, so the user can set a new password. The origin +
      // '/reset-password' URL must be listed under Supabase Auth → Redirect URLs
      // (see web/README.md).
      const { error } = await supabase.auth.resetPasswordForEmail(email.trim(), {
        redirectTo: `${window.location.origin}/reset-password`,
      });
      if (error) throw error;
    },
    async updatePassword(password) {
      const { error } = await supabase.auth.updateUser({ password });
      if (error) throw error;
    },
    clearRecovery() {
      setRecovery(false);
      writeRecoveryFlag(false);
    },
    async signOut() {
      await supabase.auth.signOut();
    },
  };

  return <AuthCtx.Provider value={value}>{children}</AuthCtx.Provider>;
}

export function useAuth(): AuthValue {
  const ctx = useContext(AuthCtx);
  if (!ctx) throw new Error('useAuth must be used within AuthProvider');
  return ctx;
}
