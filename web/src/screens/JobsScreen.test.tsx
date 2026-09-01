import { describe, it, expect, vi, beforeEach } from 'vitest';
import { render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { MemoryRouter } from 'react-router-dom';
import type { Customer, Job, Settings } from '@shared/types/models';
import JobsScreen from './JobsScreen';

const jobs: Job[] = [
  { id: 'j1', status: 'in_progress', title: 'Active Job', createdAt: '2026-08-03' },
  { id: 'j2', status: 'paid', title: 'Paid Job', createdAt: '2026-08-02' },
  { id: 'j3', status: 'lead', title: 'Lead Job', createdAt: '2026-08-01' },
] as Job[];

const store = vi.hoisted(() => ({
  customers: [] as Customer[],
  settings: null as Settings | null,
}));
vi.mock('../lib/DataContext', () => ({
  useData: () => ({ jobs, customers: store.customers, settings: store.settings }),
  useResources: () => ({
    loading: false,
    error: null,
    refreshing: false,
    retry: vi.fn(),
  }),
}));

const writes = vi.hoisted(() => ({ createJob: vi.fn() }));
vi.mock('../lib/writeRepository', () => writes);

const navigate = vi.hoisted(() => vi.fn());
vi.mock('react-router-dom', async (importOriginal) => ({
  ...(await importOriginal<typeof import('react-router-dom')>()),
  useNavigate: () => navigate,
}));

beforeEach(() => {
  store.customers = [{ id: 'c1', name: 'Acme' } as Customer];
  store.settings = null;
  writes.createJob.mockReset().mockResolvedValue({ id: 'j-new' });
  navigate.mockReset();
});

function renderScreen() {
  return render(
    <MemoryRouter>
      <JobsScreen />
    </MemoryRouter>,
  );
}

describe('JobsScreen filters', () => {
  it('shows active (non-done, non-declined) jobs by default', () => {
    renderScreen();
    expect(screen.getByText('Active Job')).toBeInTheDocument();
    expect(screen.getByText('Lead Job')).toBeInTheDocument();
    expect(screen.queryByText('Paid Job')).not.toBeInTheDocument();
  });

  it('filters to completed jobs', async () => {
    renderScreen();
    await userEvent.click(screen.getByRole('button', { name: 'Completed' }));
    expect(screen.getByText('Paid Job')).toBeInTheDocument();
    expect(screen.queryByText('Active Job')).not.toBeInTheDocument();
    expect(screen.queryByText('Lead Job')).not.toBeInTheDocument();
  });

  it('filters to estimate-stage jobs', async () => {
    renderScreen();
    await userEvent.click(screen.getByRole('button', { name: 'Estimates' }));
    expect(screen.getByText('Lead Job')).toBeInTheDocument();
    expect(screen.queryByText('Active Job')).not.toBeInTheDocument();
  });

  it('narrows results by the search box', async () => {
    renderScreen();
    await userEvent.type(
      screen.getByPlaceholderText(/Search jobs/i),
      'lead',
    );
    expect(screen.getByText('Lead Job')).toBeInTheDocument();
    expect(screen.queryByText('Active Job')).not.toBeInTheDocument();
  });
});

describe('JobsScreen — new job', () => {
  it('creates an unpriced lead via createJob and navigates to it', async () => {
    store.settings = { laborRate: 100, materialMarkup: 30, overheadPercent: 12, marginPercent: 25 } as Settings;
    renderScreen();
    await userEvent.click(screen.getByRole('button', { name: 'New job' }));

    await userEvent.selectOptions(screen.getByRole('combobox'), 'c1');
    await userEvent.type(screen.getByLabelText('Title'), 'Fence repair');
    await userEvent.click(screen.getByRole('button', { name: 'Create job' }));

    expect(writes.createJob).toHaveBeenCalledTimes(1);
    expect(writes.createJob.mock.calls[0][0]).toMatchObject({
      customerId: 'c1',
      customerName: 'Acme',
      title: 'Fence repair',
      // Rates seeded from settings.
      laborRate: 100,
      materialMarkup: 30,
      overhead: 12,
      margin: 25,
    });
    expect(navigate).toHaveBeenCalledWith('/jobs/j-new');
  });

  it('blocks submit until a customer and title are given', async () => {
    renderScreen();
    await userEvent.click(screen.getByRole('button', { name: 'New job' }));
    // No customer chosen yet.
    await userEvent.click(screen.getByRole('button', { name: 'Create job' }));
    expect(screen.getByRole('alert')).toHaveTextContent(/choose a customer/i);
    expect(writes.createJob).not.toHaveBeenCalled();

    // Customer chosen, but title still blank.
    await userEvent.selectOptions(screen.getByRole('combobox'), 'c1');
    await userEvent.click(screen.getByRole('button', { name: 'Create job' }));
    expect(screen.getByRole('alert')).toHaveTextContent(/title is required/i);
    expect(writes.createJob).not.toHaveBeenCalled();
  });

  it('prompts to add a customer first when none exist', async () => {
    store.customers = [];
    renderScreen();
    await userEvent.click(screen.getByRole('button', { name: 'New job' }));
    expect(screen.getByText(/add a customer first/i)).toBeInTheDocument();
    expect(screen.queryByRole('button', { name: 'Create job' })).toBeNull();
  });

  it('keeps the error visible when the write fails', async () => {
    writes.createJob.mockRejectedValueOnce(new Error('rls denied'));
    renderScreen();
    await userEvent.click(screen.getByRole('button', { name: 'New job' }));
    await userEvent.selectOptions(screen.getByRole('combobox'), 'c1');
    await userEvent.type(screen.getByLabelText('Title'), 'Fence repair');
    await userEvent.click(screen.getByRole('button', { name: 'Create job' }));

    expect(await screen.findByRole('alert')).toHaveTextContent('rls denied');
    expect(navigate).not.toHaveBeenCalled();
  });
});
