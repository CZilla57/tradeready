import { useEffect, useState, type FormEvent } from 'react';
import { useNavigate } from 'react-router-dom';
import { useAuth } from '../lib/AuthContext';
import logo from '../assets/logo.png';

// Supabase's password minimum is 6; we ask for a stronger 8 on the recovery
// screen. The <input minLength> mirrors this for native browser validation.
const MIN_PASSWORD_LENGTH = 8;

// After a successful update we drop the recovery session and send the user to
// the sign-in screen so they confirm the new password. A short pause lets the
// success state register (including for screen readers) before we redirect.
const REDIRECT_DELAY_MS = 1800;

/**
 * Reads a recovery error that Supabase encoded in the URL fragment when a link
 * is invalid, expired, or already used (e.g. `#error=access_denied&
 * error_code=otp_expired&error_description=...`). Such links never produce a
 * PASSWORD_RECOVERY event or a session, so the fragment is the only signal.
 */
function readRecoveryLinkError(): string | null {
  if (typeof window === 'undefined') return null;
  const hash = window.location.hash.startsWith('#')
    ? window.location.hash.slice(1)
    : window.location.hash;
  if (!hash) return null;
  const params = new URLSearchParams(hash);
  if (!params.get('error') && !params.get('error_code')) return null;
  const description = params.get('error_description');
  return description ? description.replace(/\+/g, ' ') : 'This link is no longer valid.';
}

export default function ResetPasswordScreen() {
  const { session, recovery, updatePassword, clearRecovery, signOut } = useAuth();
  const navigate = useNavigate();

  const [password, setPassword] = useState('');
  const [confirm, setConfirm] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [success, setSuccess] = useState(false);
  const [linkError] = useState<string | null>(readRecoveryLinkError);

  // A recovery session is required to change the password. `recovery` is the
  // authoritative signal; we also accept an active `session` so the screen keeps
  // working across the brief window before the PASSWORD_RECOVERY event lands.
  const canReset = recovery || Boolean(session);

  useEffect(() => {
    if (!success) return;
    const timer = setTimeout(() => {
      clearRecovery();
      void signOut().finally(() => navigate('/login', { replace: true }));
    }, REDIRECT_DELAY_MS);
    return () => clearTimeout(timer);
  }, [success, clearRecovery, signOut, navigate]);

  async function submit(e: FormEvent) {
    e.preventDefault();
    if (busy) return; // guard against duplicate submissions
    setError(null);

    if (password.length < MIN_PASSWORD_LENGTH) {
      setError(`Password must be at least ${MIN_PASSWORD_LENGTH} characters.`);
      return;
    }
    if (password !== confirm) {
      setError('Passwords do not match.');
      return;
    }

    setBusy(true);
    try {
      await updatePassword(password);
      setSuccess(true);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Could not update password.');
    } finally {
      setBusy(false);
    }
  }

  function backToReset() {
    clearRecovery();
    navigate('/login', { replace: true });
  }

  return (
    <div className="login-wrap">
      <div className="login-card">
        <div className="login-brand">
          <img className="dot" src={logo} alt="TradeReady logo" />
          <span>TradeReady</span>
        </div>
        <h1 className="login-title">Choose a new password</h1>
        <p className="login-sub">
          Set the password you&rsquo;ll use to sign in to your portal.
        </p>

        {/* Assertive so errors are announced immediately to screen readers. */}
        <div role="alert" aria-live="assertive">
          {error && <div className="login-alert error">{error}</div>}
        </div>

        {!canReset ? (
          <>
            <div className="login-alert error">
              {linkError ??
                'This password reset link is invalid or has expired. Reset links can only be used once.'}
            </div>
            <button
              type="button"
              className="login-btn primary"
              onClick={backToReset}
            >
              Request another reset email
            </button>
          </>
        ) : success ? (
          <div
            className="login-alert notice"
            role="status"
            aria-live="polite"
          >
            Your password has been updated. Redirecting you to sign in&hellip;
          </div>
        ) : (
          <>
            <div aria-live="polite">
              {busy && (
                <div className="login-alert notice" role="status">
                  Updating your password&hellip;
                </div>
              )}
            </div>
            <form onSubmit={submit} className="login-form">
              <label className="login-label">
                New password
                <input
                  type="password"
                  autoComplete="new-password"
                  required
                  minLength={MIN_PASSWORD_LENGTH}
                  value={password}
                  onChange={(e) => setPassword(e.target.value)}
                  className="login-input"
                  disabled={busy}
                />
              </label>
              <label className="login-label">
                Confirm new password
                <input
                  type="password"
                  autoComplete="new-password"
                  required
                  minLength={MIN_PASSWORD_LENGTH}
                  value={confirm}
                  onChange={(e) => setConfirm(e.target.value)}
                  className="login-input"
                  disabled={busy}
                />
              </label>
              <button
                type="submit"
                className="login-btn primary"
                disabled={busy}
                aria-busy={busy}
              >
                {busy ? 'Please wait…' : 'Update password'}
              </button>
            </form>
          </>
        )}
      </div>
    </div>
  );
}
