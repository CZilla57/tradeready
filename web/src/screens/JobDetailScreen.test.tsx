import { describe, it, expect, vi, beforeEach } from 'vitest';
import { render, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { MemoryRouter, Routes, Route } from 'react-router-dom';
import type { Job } from '@shared/types/models';
import JobDetailScreen from './JobDetailScreen';

const writes = vi.hoisted(() => ({
  updateJobDetails: vi.fn(),
  setJobArchived: vi.fn(),
  deleteJob: vi.fn(),
}));
vi.mock('../lib/writeRepository', () => writes);

const navigate = vi.hoisted(() => vi.fn());
vi.mock('react-router-dom', async (importOriginal) => ({
  ...(await importOriginal<typeof import('react-router-dom')>()),
  useNavigate: () => navigate,
}));

const retry = vi.hoisted(() => vi.fn());
const store = vi.hoisted(() => ({ jobs: [] as Job[] }));
vi.mock('../lib/DataContext', () => ({
  useData: () => ({ jobs: store.jobs, customers: [], invoices: [], retry }),
  useResources: () => ({ loading: false, error: null, refreshing: false, retry }),
}));

function job(over: Partial<Job> = {}): Job {
  return {
    id: 'job-1',
    customerId: 'c1',
    customerName: 'Acme',
    title: 'Kitchen remodel',
    description: '',
    status: 'scheduled',
    scheduledDate: null,
    scheduledStartTime: null,
    scheduledEndTime: null,
    address: '',
    estimateTotal: 500,
    laborHours: 4,
    laborRate: 90,
    materials: [],
    materialMarkup: 0,
    overhead: 0,
    margin: 0,
    notes: '',
    invoiceId: null,
    createdAt: '2026-08-01',
    ...over,
  };
}

function renderScreen() {
  return render(
    <MemoryRouter initialEntries={['/jobs/job-1']}>
      <Routes>
        <Route path="/jobs/:id" element={<JobDetailScreen />} />
      </Routes>
    </MemoryRouter>,
  );
}

beforeEach(() => {
  writes.updateJobDetails.mockReset().mockResolvedValue(job());
  writes.setJobArchived.mockReset().mockResolvedValue(job());
  writes.deleteJob.mockReset().mockResolvedValue(undefined);
  retry.mockReset();
  navigate.mockReset();
  store.jobs = [job()];
});

describe('JobDetailScreen — edit', () => {
  it('saves the operational-field edit via updateJobDetails and refreshes', async () => {
    renderScreen();
    await userEvent.click(screen.getByRole('button', { name: 'Edit job' }));

    const titleInput = screen.getByDisplayValue('Kitchen remodel');
    await userEvent.clear(titleInput);
    await userEvent.type(titleInput, 'Kitchen remodel — phase 2');
    await userEvent.click(screen.getByRole('button', { name: 'Save changes' }));

    await waitFor(() => expect(writes.updateJobDetails).toHaveBeenCalledTimes(1));
    const [id, edit] = writes.updateJobDetails.mock.calls[0];
    expect(id).toBe('job-1');
    expect(edit).toMatchObject({ title: 'Kitchen remodel — phase 2' });
    expect(retry).toHaveBeenCalledWith(['jobs']);
  });

  it('rejects an end time before the start time', async () => {
    renderScreen();
    await userEvent.click(screen.getByRole('button', { name: 'Edit job' }));
    await userEvent.type(screen.getByLabelText('Start time'), '11:00');
    await userEvent.type(screen.getByLabelText('End time'), '09:00');
    await userEvent.click(screen.getByRole('button', { name: 'Save changes' }));

    expect(screen.getByRole('alert')).toHaveTextContent(/before start time/i);
    expect(writes.updateJobDetails).not.toHaveBeenCalled();
  });
});

describe('JobDetailScreen — archive & delete', () => {
  it('archives via setJobArchived and navigates to the list', async () => {
    renderScreen();
    await userEvent.click(screen.getByRole('button', { name: 'Archive' }));

    await waitFor(() =>
      expect(writes.setJobArchived).toHaveBeenCalledWith('job-1', true),
    );
    expect(navigate).toHaveBeenCalledWith('/jobs');
  });

  it('shows Unarchive + an Archived badge for an archived job', () => {
    store.jobs = [job({ archivedAt: '2026-08-01' })];
    renderScreen();
    expect(screen.getByText('Archived')).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Unarchive' })).toBeInTheDocument();
  });

  it('deletes after confirmation and navigates to the list', async () => {
    renderScreen();
    await userEvent.click(screen.getByRole('button', { name: 'Edit job' }));
    await userEvent.click(screen.getByRole('button', { name: 'Delete job' }));
    await userEvent.click(screen.getByRole('button', { name: 'Delete' }));

    await waitFor(() => expect(writes.deleteJob).toHaveBeenCalledWith('job-1'));
    expect(navigate).toHaveBeenCalledWith('/jobs');
  });
});
