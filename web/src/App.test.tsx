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

// Screens are lazy-loaded (route-level code splitting), so each assertion uses
// findBy*, which polls until the async chunk resolves and its content mounts.
describe('App routing', () => {
  it('routes a recovery session to the password-update screen, not the portal', async () => {
    h.state.recovery = true;
    h.state.session = { user: { email: 'r@b.com' } };
    renderAt('/');
    expect(await screen.findByText('Choose a new password')).toBeInTheDocument();
    expect(screen.queryByRole('button', { name: 'Sign out' })).not.toBeInTheDocument();
  });

  it('lets an ordinary authenticated session enter the portal', async () => {
    h.state.recovery = false;
    h.state.session = { user: { email: 'u@b.com' } };
    renderAt('/');
    expect(
      await screen.findByRole('button', { name: 'Sign out' }),
    ).toBeInTheDocument();
    expect(screen.queryByText('Choose a new password')).not.toBeInTheDocument();
  });

  it('sends a signed-out visitor to the login screen', async () => {
    renderAt('/');
    expect(await screen.findByText('Sign in to your portal')).toBeInTheDocument();
  });

  it('shows a not-found view for an unknown path in the authenticated portal', async () => {
    h.state.session = { user: { email: 'u@b.com' } };
    renderAt('/does-not-exist');
    expect(await screen.findByText('Page not found')).toBeInTheDocument();
    // The shell (and its navigation) stays put rather than redirecting away.
    expect(screen.getByRole('button', { name: 'Sign out' })).toBeInTheDocument();
  });

  it('sends an authenticated session parked on /login into the portal', async () => {
    // The signed-out catch-all parks visitors on /login; after they sign in the
    // session flips truthy while the URL is still /login, which must land in the
    // portal rather than the not-found view.
    h.state.session = { user: { email: 'u@b.com' } };
    renderAt('/login');
    expect(
      await screen.findByRole('button', { name: 'Sign out' }),
    ).toBeInTheDocument();
    expect(screen.queryByText('Page not found')).not.toBeInTheDocument();
  });

  it('renders the recovery screen for a signed-out visitor at /reset-password', async () => {
    window.location.hash = '';
    renderAt('/reset-password');
    expect(await screen.findByText('Choose a new password')).toBeInTheDocument();
    expect(screen.getByText(/invalid or has expired/i)).toBeInTheDocument();
  });
});
