import { describe, it, expect, vi, beforeEach } from 'vitest';
import { render, screen, waitFor, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import type { RecurringInvoice, RecurringJob } from '@shared/types/models';
import RecurringScreen from './RecurringScreen';

const writes = vi.hoisted(() => ({
  setRecurringJobActive: vi.fn(),
  setRecurringInvoiceActive: vi.fn(),
  deleteRecurringJob: vi.fn(),
  deleteRecurringInvoice: vi.fn(),
}));
vi.mock('../lib/writeRepository', () => writes);

const retry = vi.hoisted(() => vi.fn());
const store = vi.hoisted(() => ({
  recurringJobs: [] as RecurringJob[],
  recurringInvoices: [] as RecurringInvoice[],
}));
vi.mock('../lib/DataContext', () => ({
  useData: () => ({
    recurringJobs: store.recurringJobs,
    recurringInvoices: store.recurringInvoices,
    retry,
  }),
  useResources: () => ({ loading: false, error: null, refreshing: false, retry }),
}));

function job(over: Partial<RecurringJob> = {}): RecurringJob {
  return {
    id: 'rj1',
    customerId: 'c1',
    customerName: 'Acme',
    title: 'Gutter clean',
    description: '',
    address: '',
    notes: '',
    estimateTotal: 300,
    laborHours: 2,
    laborRate: 90,
    materials: [],
    materialMarkup: 0,
    overhead: 0,
    margin: 0,
    cadence: 'monthly',
    endCondition: 'never',
    occurrenceCount: 3,
    lastGeneratedDate: '2026-08-01',
    nextDueDate: '2026-09-01',
    isActive: true,
    createdAt: '2026-01-01',
    ...over,
  };
}

function plan(over: Partial<RecurringInvoice> = {}): RecurringInvoice {
  return {
    id: 'ri1',
    customerId: 'c1',
    customerName: 'Beta LLC',
    description: 'Monthly service',
    amount: 150,
    dueDays: 30,
    cadence: 'monthly',
    endCondition: 'never',
    occurrenceCount: 5,
    lastGeneratedDate: '2026-08-01',
    nextDueDate: '2026-09-01',
    isActive: true,
    createdAt: '2026-01-01',
    ...over,
  };
}

/** The row (`.row`) whose title text matches. */
function rowFor(title: string): HTMLElement {
  return screen.getByText(title).closest('.row') as HTMLElement;
}

beforeEach(() => {
  writes.setRecurringJobActive.mockReset().mockResolvedValue(job());
  writes.setRecurringInvoiceActive.mockReset().mockResolvedValue(plan());
  writes.deleteRecurringJob.mockReset().mockResolvedValue(undefined);
  writes.deleteRecurringInvoice.mockReset().mockResolvedValue(undefined);
  retry.mockReset();
  store.recurringJobs = [job()];
  store.recurringInvoices = [plan()];
});

describe('RecurringScreen — pause/resume', () => {
  it('pauses an active recurring job and refreshes', async () => {
    render(<RecurringScreen />);
    const row = rowFor('Gutter clean');
    await userEvent.click(within(row).getByRole('button', { name: 'Pause' }));

    await waitFor(() =>
      expect(writes.setRecurringJobActive).toHaveBeenCalledWith('rj1', false),
    );
    expect(retry).toHaveBeenCalledWith(['recurringJobs']);
  });

  it('resumes a paused maintenance plan', async () => {
    store.recurringInvoices = [plan({ isActive: false })];
    render(<RecurringScreen />);
    const row = rowFor('Beta LLC');
    await userEvent.click(within(row).getByRole('button', { name: 'Resume' }));

    await waitFor(() =>
      expect(writes.setRecurringInvoiceActive).toHaveBeenCalledWith('ri1', true),
    );
    expect(retry).toHaveBeenCalledWith(['recurringInvoices']);
  });

  it('surfaces a toggle error and leaves the row unchanged', async () => {
    writes.setRecurringJobActive.mockRejectedValue(new Error('rls denied'));
    render(<RecurringScreen />);
    const row = rowFor('Gutter clean');
    await userEvent.click(within(row).getByRole('button', { name: 'Pause' }));

    await waitFor(() =>
      expect(within(row).getByRole('alert')).toHaveTextContent('rls denied'),
    );
    expect(retry).not.toHaveBeenCalled();
  });
});

describe('RecurringScreen — delete', () => {
  it('deletes a plan behind an inline confirm', async () => {
    render(<RecurringScreen />);
    const row = rowFor('Beta LLC');

    await userEvent.click(within(row).getByRole('button', { name: 'Delete' }));
    // The toggle is now hidden behind the confirm; nothing written yet.
    expect(writes.deleteRecurringInvoice).not.toHaveBeenCalled();

    await userEvent.click(within(row).getByRole('button', { name: 'Delete plan' }));
    await waitFor(() =>
      expect(writes.deleteRecurringInvoice).toHaveBeenCalledWith('ri1'),
    );
    expect(retry).toHaveBeenCalledWith(['recurringInvoices']);
  });

  it('cancels a pending delete without writing', async () => {
    render(<RecurringScreen />);
    const row = rowFor('Gutter clean');

    await userEvent.click(within(row).getByRole('button', { name: 'Delete' }));
    await userEvent.click(within(row).getByRole('button', { name: 'Cancel' }));

    expect(within(row).getByRole('button', { name: 'Pause' })).toBeInTheDocument();
    expect(writes.deleteRecurringJob).not.toHaveBeenCalled();
  });
});
