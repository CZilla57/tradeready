import { useState, type FormEvent } from 'react';
import { useAuth } from '../lib/AuthContext';
import logo from '../assets/logo.png';

type Mode = 'signin' | 'signup' | 'reset';

export default function LoginScreen() {
  const { signIn, signUp, signInWithGoogle, signInWithApple, resetPassword } =
    useAuth();
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

  async function apple() {
    setBusy(true);
    setError(null);
    try {
      await signInWithApple();
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Apple sign-in failed.');
      setBusy(false);
    }
  }

  return (
    <main className="login-wrap login-split">
      <section className="login-story" aria-label="TradeReady overview">
        <div className="login-story-inner">
          <div className="login-story-brand">
            <img src={logo} alt="" width="48" height="48" />
            <span>TradeReady</span>
          </div>
          <p className="login-eyebrow">Built for the work between jobs</p>
          <p className="login-story-title">
            Your business, ready for the next job.
          </p>
          <p className="login-story-copy">
            Plan the day, price the work, and keep every dollar moving from
            estimate to paid.
          </p>
          <ul className="login-benefits">
            <li>See today’s work at a glance</li>
            <li>Build estimates from real job costs</li>
            <li>Track invoices, expenses, and recurring work</li>
          </ul>
        </div>
        <div className="login-story-foot">Straightforward tools for solo trades.</div>
      </section>
      <section className="login-card" aria-labelledby="login-title">
        <div className="login-brand">
          <img className="dot" src={logo} alt="" width="36" height="36" />
          <span>
            TradeReady
            <small>Owner workspace</small>
          </span>
        </div>
        <h1 className="login-title" id="login-title">
          {mode === 'signin'
            ? 'Sign in to your portal'
            : mode === 'signup'
              ? 'Create your account'
              : 'Reset your password'}
        </h1>
        <p className="login-sub">
          The same account you use in the TradeReady app.
        </p>

        {error && <div className="login-alert error" role="alert">{error}</div>}
        {notice && <div className="login-alert notice" role="status">{notice}</div>}

        <form onSubmit={submit} className="login-form">
          <label className="login-label">
            Email
            <input
              type="email"
              name="email"
              autoComplete="email"
              spellCheck={false}
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
                name="password"
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
            <button
              type="button"
              className="login-btn apple"
              onClick={apple}
              disabled={busy}
            >
              Continue with Apple
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
      </section>
    </main>
  );
}
