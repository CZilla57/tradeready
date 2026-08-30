import { useState, type FormEvent } from 'react';
import { useAuth } from '../lib/AuthContext';

type Mode = 'signin' | 'signup' | 'reset';

export default function LoginScreen() {
  const { signIn, signUp, signInWithGoogle, resetPassword } = useAuth();
  const [mode, setMode] = useState<Mode>('signin');
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);

  async function submit(e: FormEvent) {
    e.preventDefault();
    setBusy(true);
    setError(null);
    setNotice(null);
    try {
      if (mode === 'signin') {
        await signIn(email, password);
      } else if (mode === 'signup') {
        await signUp(email, password);
        setNotice('Check your email to confirm your account, then sign in.');
        setMode('signin');
      } else {
        await resetPassword(email);
        setNotice('If that email has an account, a reset link is on its way.');
        setMode('signin');
      }
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Something went wrong.');
    } finally {
      setBusy(false);
    }
  }

  async function google() {
    setBusy(true);
    setError(null);
    try {
      await signInWithGoogle();
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Google sign-in failed.');
      setBusy(false);
    }
  }

  return (
    <div className="login-wrap">
      <div className="login-card">
        <div className="login-brand">
          <span className="dot">🔧</span>
          <span>TradeReady</span>
        </div>
        <h1 className="login-title">
          {mode === 'signin'
            ? 'Sign in to your portal'
            : mode === 'signup'
              ? 'Create your account'
              : 'Reset your password'}
        </h1>
        <p className="login-sub">
          The same account you use in the TradeReady app.
        </p>

        {error && <div className="login-alert error">{error}</div>}
        {notice && <div className="login-alert notice">{notice}</div>}

        <form onSubmit={submit} className="login-form">
          <label className="login-label">
            Email
            <input
              type="email"
              autoComplete="email"
              required
              value={email}
              onChange={(e) => setEmail(e.target.value)}
              className="login-input"
            />
          </label>
          {mode !== 'reset' && (
            <label className="login-label">
              Password
              <input
                type="password"
                autoComplete={
                  mode === 'signup' ? 'new-password' : 'current-password'
                }
                required
                minLength={6}
                value={password}
                onChange={(e) => setPassword(e.target.value)}
                className="login-input"
              />
            </label>
          )}
          <button type="submit" className="login-btn primary" disabled={busy}>
            {busy
              ? 'Please wait…'
              : mode === 'signin'
                ? 'Sign in'
                : mode === 'signup'
                  ? 'Create account'
                  : 'Send reset link'}
          </button>
        </form>

        {mode === 'signin' && (
          <>
            <div className="login-divider">
              <span>or</span>
            </div>
            <button
              type="button"
              className="login-btn google"
              onClick={google}
              disabled={busy}
            >
              Continue with Google
            </button>
          </>
        )}

        <div className="login-links">
          {mode === 'signin' && (
            <>
              <button type="button" onClick={() => setMode('reset')}>
                Forgot password?
              </button>
              <button type="button" onClick={() => setMode('signup')}>
                Create an account
              </button>
            </>
          )}
          {mode !== 'signin' && (
            <button type="button" onClick={() => setMode('signin')}>
              Back to sign in
            </button>
          )}
        </div>
      </div>
    </div>
  );
}
