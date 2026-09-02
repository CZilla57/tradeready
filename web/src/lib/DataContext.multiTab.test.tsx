import { describe, it, expect, vi, beforeEach } from 'vitest';
import { render, screen, act, waitFor } from '@testing-library/react';
import { DataProvider, useData, useResources, type ResourceKey } from './DataContext';

// Multi-tab refresh (roadmap): a backgrounded tab freshens on focus/visibility,
// a sibling tab's write is picked up over the cross-tab channel, and a local
// write announces itself to siblings.

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

// Capture the cross-tab wiring: hold the subscriber callback so a test can play
// the part of "another tab", and spy on what this tab publishes.
const sync = vi.hoisted(() => ({
  publishDataChange: vi.fn(),
  lastSubscriber: null as ((keys: ResourceKey[]) => void) | null,
  unsubscribe: vi.fn(),
}));
vi.mock('./dataSync', () => ({
  publishDataChange: sync.publishDataChange,
  subscribeDataChange: (cb: (keys: ResourceKey[]) => void) => {
    sync.lastSubscriber = cb;
    return sync.unsubscribe;
  },
}));

function Probe() {
  const data = useData();
  const jobs = useResources('jobs');
  return (
    <div>
      <span data-testid="jobs">{data.jobs.map((j) => j.id).join(',')}</span>
      <span data-testid="invoices">{data.invoices.map((i) => i.id).join(',')}</span>
      <span data-testid="jobs-refreshing">{String(jobs.refreshing)}</span>
      <button onClick={() => jobs.retry()}>retry-jobs</button>
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
  sync.lastSubscriber = null;
  resolveAllEmpty();
});

describe('multi-tab refresh', () => {
  it('re-pulls when a backgrounded tab becomes visible again', async () => {
    repo.fetchJobs.mockResolvedValue([{ id: 'j1' }]);
    renderProvider();
    await waitFor(() => expect(screen.getByTestId('jobs')).toHaveTextContent('j1'));

    // A write landed elsewhere while this tab sat in the background.
    repo.fetchJobs.mockResolvedValue([{ id: 'j2' }]);
    await act(async () => {
      document.dispatchEvent(new Event('visibilitychange'));
    });
    await waitFor(() => expect(screen.getByTestId('jobs')).toHaveTextContent('j2'));
  });

  it('keeps loaded rows visible while the focus refresh is in flight', async () => {
    repo.fetchJobs.mockResolvedValue([{ id: 'j1' }]);
    renderProvider();
    await waitFor(() => expect(screen.getByTestId('jobs')).toHaveTextContent('j1'));

    let resolveJobs!: (v: { id: string }[]) => void;
    repo.fetchJobs.mockReturnValue(
      new Promise<{ id: string }[]>((res) => {
        resolveJobs = res;
      }),
    );
    await act(async () => {
      document.dispatchEvent(new Event('visibilitychange'));
    });
    // The prior rows stay on screen; the resource reports refreshing, not loading.
    expect(screen.getByTestId('jobs')).toHaveTextContent('j1');
    expect(screen.getByTestId('jobs-refreshing')).toHaveTextContent('true');
    await act(async () => {
      resolveJobs([{ id: 'j9' }]);
    });
    await waitFor(() => expect(screen.getByTestId('jobs')).toHaveTextContent('j9'));
  });

  it('throttles a burst of focus/visibility events into a single refresh', async () => {
    repo.fetchJobs.mockResolvedValue([{ id: 'j1' }]);
    renderProvider();
    await waitFor(() => expect(screen.getByTestId('jobs')).toHaveTextContent('j1'));
    const callsAfterInitialLoad = repo.fetchJobs.mock.calls.length;

    await act(async () => {
      document.dispatchEvent(new Event('visibilitychange'));
      window.dispatchEvent(new Event('focus'));
      document.dispatchEvent(new Event('visibilitychange'));
    });
    // The three near-instant events collapse to one refresh (throttle window).
    expect(repo.fetchJobs.mock.calls.length).toBe(callsAfterInitialLoad + 1);
  });

  it('does not refresh a signed-out tab on focus', async () => {
    auth.session = null;
    renderProvider();
    // Signed out: no initial load and no focus refresh.
    await act(async () => {
      document.dispatchEvent(new Event('visibilitychange'));
    });
    expect(repo.fetchJobs).not.toHaveBeenCalled();
  });

  it('reloads the collections a sibling tab announces, without re-broadcasting', async () => {
    repo.fetchJobs.mockResolvedValue([{ id: 'j1' }]);
    repo.fetchInvoices.mockResolvedValue([{ id: 'i1' }]);
    renderProvider();
    await waitFor(() => expect(screen.getByTestId('invoices')).toHaveTextContent('i1'));
    sync.publishDataChange.mockClear();

    // Another tab wrote an invoice and announced it.
    repo.fetchInvoices.mockResolvedValue([{ id: 'i1' }, { id: 'i2' }]);
    repo.fetchJobs.mockResolvedValue([{ id: 'jX' }]);
    await act(async () => {
      sync.lastSubscriber?.(['invoices']);
    });
    await waitFor(() => expect(screen.getByTestId('invoices')).toHaveTextContent('i1,i2'));
    // Only the announced collection reloaded — jobs were left alone.
    expect(screen.getByTestId('jobs')).toHaveTextContent('j1');
    // A cross-tab-driven reload must not echo back onto the channel.
    expect(sync.publishDataChange).not.toHaveBeenCalled();
  });

  it('ignores an unknown resource key from the channel', async () => {
    renderProvider();
    await waitFor(() => expect(repo.fetchJobs).toHaveBeenCalled());
    const before = repo.fetchJobs.mock.calls.length;
    await act(async () => {
      sync.lastSubscriber?.(['bogus' as ResourceKey]);
    });
    expect(repo.fetchJobs.mock.calls.length).toBe(before);
  });

  it('announces a local write to sibling tabs via retry', async () => {
    repo.fetchJobs.mockResolvedValue([{ id: 'j1' }]);
    renderProvider();
    await waitFor(() => expect(screen.getByTestId('jobs')).toHaveTextContent('j1'));

    await act(async () => {
      screen.getByText('retry-jobs').click();
    });
    expect(sync.publishDataChange).toHaveBeenCalledWith(['jobs']);
  });
});
