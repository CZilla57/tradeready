import { describe, it, expect, vi, beforeEach } from 'vitest';
import { render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { MemoryRouter } from 'react-router-dom';
import ResetPasswordScreen from './ResetPasswordScreen';

const h = vi.hoisted(() => ({
  updatePassword: vi.fn(async () => {}),
  clearRecovery: vi.fn(),
  signOut: vi.fn(async () => {}),
  navigate: vi.fn(),
  state: { recovery: true, session: null as unknown },
}));

vi.mock('../lib/AuthContext', () => ({
  useAuth: () => ({
    session: h.state.session,
    recovery: h.state.recovery,
    updatePassword: h.updatePassword,
    clearRecovery: h.clearRecovery,
    signOut: h.signOut,
  }),
}));

vi.mock('react-router-dom', async (importOriginal) => {
  const actual = await importOriginal<typeof import('react-router-dom')>();
  return { ...actual, useNavigate: () => h.navigate };
});

function renderScreen() {
  return render(
    <MemoryRouter>
      <ResetPasswordScreen />
    </MemoryRouter>,
  );
}

beforeEach(() => {
  vi.clearAllMocks();
  h.state.recovery = true;
  h.state.session = null;
  window.location.hash = '';
});

describe('ResetPasswordScreen', () => {
  it('rejects passwords that are too short', async () => {
    const user = userEvent.setup();
    renderScreen();
    await user.type(screen.getByLabelText('New password'), 'short');
    await user.type(screen.getByLabelText('Confirm new password'), 'short');
    await user.click(screen.getByRole('button', { name: 'Update password' }));
    expect(screen.getByRole('alert')).toHaveTextContent(/at least 8 characters/i);
    expect(h.updatePassword).not.toHaveBeenCalled();
  });

  it('rejects mismatched confirmation', async () => {
    const user = userEvent.setup();
    renderScreen();
    await user.type(screen.getByLabelText('New password'), 'longenough1');
    await user.type(screen.getByLabelText('Confirm new password'), 'different1');
    await user.click(screen.getByRole('button', { name: 'Update password' }));
    expect(screen.getByRole('alert')).toHaveTextContent(/do not match/i);
    expect(h.updatePassword).not.toHaveBeenCalled();
  });

  it('calls updateUser and shows a success state on a valid update', async () => {
    const user = userEvent.setup();
    renderScreen();
    await user.type(screen.getByLabelText('New password'), 'longenough1');
    await user.type(screen.getByLabelText('Confirm new password'), 'longenough1');
    await user.click(screen.getByRole('button', { name: 'Update password' }));
    expect(h.updatePassword).toHaveBeenCalledWith('longenough1');
    expect(await screen.findByRole('status')).toHaveTextContent(/updated/i);
  });

  it('surfaces an update failure without duplicating submissions', async () => {
    h.updatePassword.mockRejectedValueOnce(new Error('Session expired'));
    const user = userEvent.setup();
    renderScreen();
    await user.type(screen.getByLabelText('New password'), 'longenough1');
    await user.type(screen.getByLabelText('Confirm new password'), 'longenough1');
    await user.click(screen.getByRole('button', { name: 'Update password' }));
    expect(await screen.findByRole('alert')).toHaveTextContent('Session expired');
    expect(h.updatePassword).toHaveBeenCalledTimes(1);
    // The form is still usable after a failure.
    expect(
      screen.getByRole('button', { name: 'Update password' }),
    ).toBeEnabled();
  });

  it('offers a path back to reset when there is no recovery session', async () => {
    h.state.recovery = false;
    h.state.session = null;
    renderScreen();
    expect(screen.getByText(/invalid or has expired/i)).toBeInTheDocument();
    expect(screen.queryByLabelText('New password')).not.toBeInTheDocument();
    await userEvent.click(
      screen.getByRole('button', { name: /request another reset email/i }),
    );
    expect(h.clearRecovery).toHaveBeenCalled();
    expect(h.navigate).toHaveBeenCalledWith('/login', { replace: true });
  });

  it('shows the Supabase error from an expired link fragment', async () => {
    h.state.recovery = false;
    h.state.session = null;
    window.location.hash =
      '#error=access_denied&error_code=otp_expired&error_description=Email+link+is+invalid+or+has+expired';
    renderScreen();
    expect(
      screen.getByText(/Email link is invalid or has expired/i),
    ).toBeInTheDocument();
  });
});
