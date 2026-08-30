import { describe, it, expect, vi, beforeEach } from 'vitest';
import type { ReactNode } from 'react';
import { render, screen } from '@testing-library/react';
import { MemoryRouter } from 'react-router-dom';
import App from './App';

const h = vi.hoisted(() => ({
  state: {
    session: null as unknown,
    recovery: false,
    initializing: false,
  },
  updatePassword: vi.fn(async () => {}),
  clearRecovery: vi.fn(),
  signOut: vi.fn(async () => {}),
}));

vi.mock('./lib/AuthContext', () => ({
  useAuth: () => ({
    session: h.state.session,
    recovery: h.state.recovery,
    initializing: h.state.initializing,
    updatePassword: h.updatePassword,
    clearRecovery: h.clearRecovery,
    signOut: h.signOut,
    signIn: vi.fn(),
    signUp: vi.fn(),
    signInWithGoogle: vi.fn(),
    signInWithApple: vi.fn(),
    resetPassword: vi.fn(),
  }),
}));

// Avoid the real data-loading effect (and its network calls) when the portal
// renders; the routing decision is what these tests exercise.
vi.mock('./lib/DataContext', () => ({
  DataProvider: ({ children }: { children: ReactNode }) => <>{children}</>,
  useData: () => ({
    jobs: [],
    invoices: [],
    customers: [],
    expenses: [],
    settings: null,
    notes: {},
    pricebook: [],
    recurringJobs: [],
    recurringInvoices: [],
    loading: {},
    loaded: {},
    errors: {},
    reload: vi.fn(),
    retry: vi.fn(),
  }),
  useResources: () => ({
    loading: false,
    error: null,
    refreshing: false,
    retry: vi.fn(),
  }),
}));

function renderAt(path: string) {
  return render(
    <MemoryRouter initialEntries={[path]}>
      <App />
    </MemoryRouter>,
  );
}

beforeEach(() => {
  vi.clearAllMocks();
  h.state.session = null;
  h.state.recovery = false;
  h.state.initializing = false;
});

describe('App routing', () => {
  it('routes a recovery session to the password-update screen, not the portal', () => {
    h.state.recovery = true;
    h.state.session = { user: { email: 'r@b.com' } };
    renderAt('/');
    expect(screen.getByText('Choose a new password')).toBeInTheDocument();
    expect(screen.queryByRole('button', { name: 'Sign out' })).not.toBeInTheDocument();
  });

  it('lets an ordinary authenticated session enter the portal', () => {
    h.state.recovery = false;
    h.state.session = { user: { email: 'u@b.com' } };
    renderAt('/');
    expect(screen.getByRole('button', { name: 'Sign out' })).toBeInTheDocument();
    expect(screen.queryByText('Choose a new password')).not.toBeInTheDocument();
  });

  it('sends a signed-out visitor to the login screen', () => {
    renderAt('/');
    expect(screen.getByText('Sign in to your portal')).toBeInTheDocument();
  });

  it('shows a not-found view for an unknown path in the authenticated portal', () => {
    h.state.session = { user: { email: 'u@b.com' } };
    renderAt('/does-not-exist');
    expect(screen.getByText('Page not found')).toBeInTheDocument();
    // The shell (and its navigation) stays put rather than redirecting away.
    expect(screen.getByRole('button', { name: 'Sign out' })).toBeInTheDocument();
  });

  it('renders the recovery screen for a signed-out visitor at /reset-password', () => {
    window.location.hash = '';
    renderAt('/reset-password');
    expect(screen.getByText('Choose a new password')).toBeInTheDocument();
    expect(screen.getByText(/invalid or has expired/i)).toBeInTheDocument();
  });
});
