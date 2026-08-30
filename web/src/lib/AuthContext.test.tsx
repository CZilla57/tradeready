import { describe, it, expect, vi, beforeEach } from 'vitest';
import { render, screen, act, waitFor } from '@testing-library/react';
import { AuthProvider, useAuth } from './AuthContext';

// Controllable Supabase auth mock. `fireAuthEvent` lets a test drive the
// onAuthStateChange callback the provider subscribes to (e.g. PASSWORD_RECOVERY).
const h = vi.hoisted(() => {
  let authCallback: (event: string, session: unknown) => void = () => {};
  const auth = {
    getSession: vi.fn(async () => ({ data: { session: null as unknown } })),
    onAuthStateChange: vi.fn((cb: (event: string, session: unknown) => void) => {
      authCallback = cb;
      return { data: { subscription: { unsubscribe: vi.fn() } } };
    }),
    signInWithPassword: vi.fn(async () => ({ error: null })),
    signUp: vi.fn(async () => ({ error: null })),
    signInWithOAuth: vi.fn(async () => ({ error: null })),
    resetPasswordForEmail: vi.fn(async () => ({ error: null })),
    updateUser: vi.fn(async () => ({ error: null })),
    signOut: vi.fn(async () => ({ error: null })),
  };
  return {
    auth,
    fireAuthEvent: (event: string, session: unknown) =>
      authCallback(event, session),
  };
});

vi.mock('./supabase', () => ({ supabase: { auth: h.auth } }));

function Probe() {
  const auth = useAuth();
  return (
    <div>
      <span data-testid="initializing">{String(auth.initializing)}</span>
      <span data-testid="recovery">{String(auth.recovery)}</span>
      <span data-testid="email">{auth.session?.user?.email ?? 'none'}</span>
      <button onClick={() => void auth.signIn('a@b.com', 'pw')}>signin</button>
      <button onClick={() => void auth.signUp('a@b.com', 'pw')}>signup</button>
      <button onClick={() => void auth.signInWithGoogle()}>google</button>
      <button onClick={() => void auth.resetPassword('a@b.com')}>reset</button>
      <button onClick={() => void auth.updatePassword('newpassword')}>update</button>
      <button onClick={() => void auth.signOut()}>signout</button>
    </div>
  );
}

async function renderProvider() {
  const utils = render(
    <AuthProvider>
      <Probe />
    </AuthProvider>,
  );
  // Let the initial getSession promise resolve.
  await waitFor(() =>
    expect(screen.getByTestId('initializing')).toHaveTextContent('false'),
  );
  return utils;
}

beforeEach(() => {
  vi.clearAllMocks();
  h.auth.getSession.mockResolvedValue({ data: { session: null } });
});

describe('AuthProvider', () => {
  it('restores the initial session on mount', async () => {
    h.auth.getSession.mockResolvedValueOnce({
      data: { session: { user: { email: 'restored@b.com' } } },
    });
    await renderProvider();
    expect(h.auth.getSession).toHaveBeenCalledTimes(1);
    expect(screen.getByTestId('email')).toHaveTextContent('restored@b.com');
  });

  it('requests a reset email that redirects to /reset-password', async () => {
    await renderProvider();
    await act(async () => {
      screen.getByText('reset').click();
    });
    expect(h.auth.resetPasswordForEmail).toHaveBeenCalledWith('a@b.com', {
      redirectTo: `${window.location.origin}/reset-password`,
    });
  });

  it('enters recovery mode on the PASSWORD_RECOVERY event', async () => {
    await renderProvider();
    expect(screen.getByTestId('recovery')).toHaveTextContent('false');
    await act(async () => {
      h.fireAuthEvent('PASSWORD_RECOVERY', { user: { email: 'r@b.com' } });
    });
    expect(screen.getByTestId('recovery')).toHaveTextContent('true');
    // Persisted in localStorage (shared with the Supabase session) so other tabs
    // see recovery mode too.
    expect(window.localStorage.getItem('tradeready.passwordRecovery')).toBe('1');
  });

  it('restores recovery mode in a fresh tab from the persisted flag + session', async () => {
    // A second/reopened tab: the one-shot PASSWORD_RECOVERY event never fires
    // here, but the flag and the recovery session are both in localStorage.
    window.localStorage.setItem('tradeready.passwordRecovery', '1');
    h.auth.getSession.mockResolvedValueOnce({
      data: { session: { user: { email: 'r@b.com' } } },
    });
    await renderProvider();
    expect(screen.getByTestId('recovery')).toHaveTextContent('true');
    expect(screen.getByTestId('email')).toHaveTextContent('r@b.com');
  });

  it('drops a stale recovery flag when there is no live session', async () => {
    window.localStorage.setItem('tradeready.passwordRecovery', '1');
    h.auth.getSession.mockResolvedValueOnce({ data: { session: null } });
    await renderProvider();
    expect(screen.getByTestId('recovery')).toHaveTextContent('false');
    expect(window.localStorage.getItem('tradeready.passwordRecovery')).toBeNull();
  });

  it('leaves recovery mode on SIGNED_OUT', async () => {
    await renderProvider();
    await act(async () => {
      h.fireAuthEvent('PASSWORD_RECOVERY', { user: { email: 'r@b.com' } });
    });
    expect(screen.getByTestId('recovery')).toHaveTextContent('true');
    await act(async () => {
      h.fireAuthEvent('SIGNED_OUT', null);
    });
    expect(screen.getByTestId('recovery')).toHaveTextContent('false');
    expect(window.localStorage.getItem('tradeready.passwordRecovery')).toBeNull();
  });

  it('updatePassword calls supabase.auth.updateUser', async () => {
    await renderProvider();
    await act(async () => {
      screen.getByText('update').click();
    });
    expect(h.auth.updateUser).toHaveBeenCalledWith({ password: 'newpassword' });
  });

  it('keeps email/password, sign-up, Google, and sign-out wired up', async () => {
    await renderProvider();
    await act(async () => screen.getByText('signin').click());
    expect(h.auth.signInWithPassword).toHaveBeenCalledWith({
      email: 'a@b.com',
      password: 'pw',
    });
    await act(async () => screen.getByText('signup').click());
    expect(h.auth.signUp).toHaveBeenCalledWith({ email: 'a@b.com', password: 'pw' });
    await act(async () => screen.getByText('google').click());
    expect(h.auth.signInWithOAuth).toHaveBeenCalledWith({
      provider: 'google',
      options: { redirectTo: window.location.origin },
    });
    await act(async () => screen.getByText('signout').click());
    expect(h.auth.signOut).toHaveBeenCalled();
  });
});
