import { describe, it, expect, vi, beforeEach } from 'vitest';
import { render, screen, act, waitFor } from '@testing-library/react';
import { DataProvider, useData, useResources } from './DataContext';

// Controllable repository + auth mocks. Each fetcher is a vi.fn the test drives
// per case (resolve a value, reject, or hand back a pending promise).
const repo = vi.hoisted(() => ({
  fetchJobs: vi.fn(),
  fetchInvoices: vi.fn(),
  fetchCustomers: vi.fn(),
  fetchExpenses: vi.fn(),
  fetchSettings: vi.fn(),
  fetchCustomerNotes: vi.fn(),
  fetchPricebook: vi.fn(),
  fetchRecurringJobs: vi.fn(),
  fetchRecurringInvoices: vi.fn(),
}));
vi.mock('./repository', () => repo);

const auth = vi.hoisted(() => ({
  session: { user: { id: 'u1' } } as { user: { id: string } } | null,
}));
vi.mock('./AuthContext', () => ({ useAuth: () => ({ session: auth.session }) }));

function deferred<T>() {
  let resolve!: (value: T) => void;
  let reject!: (reason?: unknown) => void;
  const promise = new Promise<T>((res, rej) => {
    resolve = res;
    reject = rej;
  });
  return { promise, resolve, reject };
}

function Probe() {
  const data = useData();
  const jobs = useResources('jobs');
  const pricebook = useResources('pricebook');
  return (
    <div>
      <span data-testid="jobs">{data.jobs.map((j) => j.id).join(',')}</span>
      <span data-testid="pricebook">
        {data.pricebook.map((p) => p.id).join(',')}
      </span>
      <span data-testid="jobs-loading">{String(jobs.loading)}</span>
      <span data-testid="jobs-refreshing">{String(jobs.refreshing)}</span>
      <span data-testid="jobs-error">{jobs.error ?? ''}</span>
      <span data-testid="pb-error">{pricebook.error ?? ''}</span>
      <button onClick={() => jobs.retry()}>retry-jobs</button>
      <button onClick={() => data.reload()}>reload</button>
    </div>
  );
}

function renderProvider() {
  return render(
    <DataProvider>
      <Probe />
    </DataProvider>,
  );
}

// Every fetcher resolves empty by default; a test overrides only what it needs.
function resolveAllEmpty() {
  repo.fetchJobs.mockResolvedValue([]);
  repo.fetchInvoices.mockResolvedValue([]);
  repo.fetchCustomers.mockResolvedValue([]);
  repo.fetchExpenses.mockResolvedValue([]);
  repo.fetchSettings.mockResolvedValue(null);
  repo.fetchCustomerNotes.mockResolvedValue({});
  repo.fetchPricebook.mockResolvedValue([]);
  repo.fetchRecurringJobs.mockResolvedValue([]);
  repo.fetchRecurringInvoices.mockResolvedValue([]);
}

beforeEach(() => {
  vi.clearAllMocks();
  auth.session = { user: { id: 'u1' } };
  resolveAllEmpty();
});

describe('DataProvider resilience', () => {
  it('commits successful resources even when another one fails', async () => {
    repo.fetchJobs.mockResolvedValue([{ id: 'j1' }]);
    repo.fetchPricebook.mockRejectedValue(new Error('pricebook is down'));

    renderProvider();

    await waitFor(() =>
      expect(screen.getByTestId('jobs')).toHaveTextContent('j1'),
    );
    // The pricebook rejection did not erase the jobs that loaded fine.
    expect(screen.getByTestId('jobs')).toHaveTextContent('j1');
    expect(screen.getByTestId('pricebook')).toHaveTextContent('');
  });

  it('scopes failure to the resources a screen actually requires', async () => {
    repo.fetchJobs.mockResolvedValue([{ id: 'j1' }]);
    repo.fetchPricebook.mockRejectedValue(new Error('pricebook is down'));

    renderProvider();

    await waitFor(() =>
      expect(screen.getByTestId('pb-error')).toHaveTextContent(
        'pricebook is down',
      ),
    );
    // A Jobs screen (needs 'jobs') sees no error; only a pricebook-scoped
    // screen does.
    expect(screen.getByTestId('jobs-error')).toHaveTextContent('');
    expect(screen.getByTestId('jobs-loading')).toHaveTextContent('false');
  });

  it('reloads all resources and reflects fresh values', async () => {
    repo.fetchJobs.mockResolvedValue([{ id: 'j1' }]);
    renderProvider();
    await waitFor(() =>
      expect(screen.getByTestId('jobs')).toHaveTextContent('j1'),
    );

    repo.fetchJobs.mockResolvedValue([{ id: 'j2' }]);
    await act(async () => {
      screen.getByText('reload').click();
    });
    await waitFor(() =>
      expect(screen.getByTestId('jobs')).toHaveTextContent('j2'),
    );
  });

  it('keeps already-loaded data visible during a manual retry', async () => {
    repo.fetchJobs.mockResolvedValue([{ id: 'j1' }]);
    renderProvider();
    await waitFor(() =>
      expect(screen.getByTestId('jobs')).toHaveTextContent('j1'),
    );

    // Retry with a still-pending fetch: the old rows stay on screen and the
    // resource reports `refreshing`, not a blocking `loading`.
    const pending = deferred<{ id: string }[]>();
    repo.fetchJobs.mockReturnValue(pending.promise);
    await act(async () => {
      screen.getByText('retry-jobs').click();
    });
    expect(screen.getByTestId('jobs')).toHaveTextContent('j1');
    expect(screen.getByTestId('jobs-loading')).toHaveTextContent('false');
    expect(screen.getByTestId('jobs-refreshing')).toHaveTextContent('true');

    await act(async () => {
      pending.resolve([{ id: 'j3' }]);
      await pending.promise;
    });
    await waitFor(() =>
      expect(screen.getByTestId('jobs')).toHaveTextContent('j3'),
    );
  });

  it('clears one user’s data the instant the session changes to another', async () => {
    repo.fetchJobs.mockResolvedValue([{ id: 'j1' }]);
    const { rerender } = renderProvider();
    await waitFor(() =>
      expect(screen.getByTestId('jobs')).toHaveTextContent('j1'),
    );

    // User switches; the new user's jobs are still in flight.
    const pending = deferred<{ id: string }[]>();
    repo.fetchJobs.mockReturnValue(pending.promise);
    auth.session = { user: { id: 'u2' } };
    await act(async () => {
      rerender(
        <DataProvider>
          <Probe />
        </DataProvider>,
      );
    });

    // User u1's rows must be gone immediately — never shown under u2.
    expect(screen.getByTestId('jobs')).toHaveTextContent('');

    await act(async () => {
      pending.resolve([{ id: 'j2' }]);
      await pending.promise;
    });
    await waitFor(() =>
      expect(screen.getByTestId('jobs')).toHaveTextContent('j2'),
    );
  });

  it('drops user data on sign-out', async () => {
    repo.fetchJobs.mockResolvedValue([{ id: 'j1' }]);
    const { rerender } = renderProvider();
    await waitFor(() =>
      expect(screen.getByTestId('jobs')).toHaveTextContent('j1'),
    );

    auth.session = null;
    await act(async () => {
      rerender(
        <DataProvider>
          <Probe />
        </DataProvider>,
      );
    });
    expect(screen.getByTestId('jobs')).toHaveTextContent('');
  });

  it('ignores a late response from a superseded request', async () => {
    // First load hangs; a reload starts a newer request that resolves first.
    const first = deferred<{ id: string }[]>();
    repo.fetchJobs.mockReturnValueOnce(first.promise);
    renderProvider();

    repo.fetchJobs.mockResolvedValue([{ id: 'new' }]);
    await act(async () => {
      screen.getByText('reload').click();
    });
    await waitFor(() =>
      expect(screen.getByTestId('jobs')).toHaveTextContent('new'),
    );

    // The stale first request now resolves — it must NOT overwrite the newer
    // committed value.
    await act(async () => {
      first.resolve([{ id: 'stale' }]);
      await first.promise;
    });
    expect(screen.getByTestId('jobs')).toHaveTextContent('new');
  });
});
