import {
  createContext,
  useContext,
  useEffect,
  useState,
  type ReactNode,
} from 'react';
import type { Session } from '@supabase/supabase-js';
import { supabase } from './supabase';

// sessionStorage flag that keeps the app in password-recovery mode across the
// re-render (and any manual reload) that follows Supabase's one-shot
// PASSWORD_RECOVERY event, so a recovery link cannot silently fall through into
// the authenticated portal before the user sets a new password.
const RECOVERY_FLAG = 'tradeready.passwordRecovery';

function readRecoveryFlag(): boolean {
  try {
    return sessionStorage.getItem(RECOVERY_FLAG) === '1';
  } catch {
    return false;
  }
}

function writeRecoveryFlag(on: boolean): void {
  try {
    if (on) sessionStorage.setItem(RECOVERY_FLAG, '1');
    else sessionStorage.removeItem(RECOVERY_FLAG);
  } catch {
    // Private-mode / disabled storage: recovery still works within the current
    // render via React state; only cross-reload persistence is lost.
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
      .then(({ data }) => setSession(data.session))
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
