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
  advanceJobStatus: vi.fn(),
  updateJobPricing: vi.fn(),
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
  useData: () => ({
    jobs: store.jobs,
    customers: [],
    invoices: [],
    settings: { minimumJobFee: 0 },
    retry,
  }),
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
  writes.advanceJobStatus.mockReset().mockResolvedValue(job());
  writes.updateJobPricing.mockReset().mockResolvedValue(job());
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

describe('JobDetailScreen — status advance', () => {
  it('shows "Start job" for a scheduled job and advances via advanceJobStatus', async () => {
    store.jobs = [job({ status: 'scheduled' })];
    renderScreen();
    await userEvent.click(screen.getByRole('button', { name: 'Start job' }));

    await waitFor(() =>
      expect(writes.advanceJobStatus).toHaveBeenCalledWith('job-1'),
    );
    expect(retry).toHaveBeenCalledWith(['jobs']);
  });

  it('shows "Mark complete" for an in-progress job', () => {
    store.jobs = [job({ status: 'in_progress' })];
    renderScreen();
    expect(
      screen.getByRole('button', { name: 'Mark complete' }),
    ).toBeInTheDocument();
  });

  it('offers no advance control for a status the portal must not drive', () => {
    store.jobs = [job({ status: 'complete' })];
    renderScreen();
    expect(screen.queryByRole('button', { name: 'Start job' })).toBeNull();
    expect(screen.queryByRole('button', { name: 'Mark complete' })).toBeNull();
  });

  it('offers no advance control for an archived job', () => {
    store.jobs = [job({ status: 'scheduled', archivedAt: '2026-08-01' })];
    renderScreen();
    expect(screen.queryByRole('button', { name: 'Start job' })).toBeNull();
  });

  it('keeps the error visible when the advance fails', async () => {
    store.jobs = [job({ status: 'scheduled' })];
    writes.advanceJobStatus.mockRejectedValueOnce(new Error('rls denied'));
    renderScreen();
    await userEvent.click(screen.getByRole('button', { name: 'Start job' }));

    expect(await screen.findByRole('alert')).toHaveTextContent('rls denied');
    expect(retry).not.toHaveBeenCalled();
  });
});

describe('JobDetailScreen — estimate/pricing editing', () => {
  it('edits pricing + a material and saves via updateJobPricing', async () => {
    // job(): laborHours 4, laborRate 90, markup/overhead/margin 0, minimumJobFee 0.
    store.jobs = [job({ status: 'lead' })];
    renderScreen();
    await userEvent.click(screen.getByRole('button', { name: 'Edit estimate' }));

    const rate = screen.getByLabelText('Labor rate ($/hr)');
    await userEvent.clear(rate);
    await userEvent.type(rate, '100');
    await userEvent.click(screen.getByRole('button', { name: '+ Add material' }));
    await userEvent.type(screen.getByLabelText('Material name'), 'Pipe');
    const cost = screen.getByLabelText('Material unit cost');
    await userEvent.clear(cost);
    await userEvent.type(cost, '25'); // qty defaults to 1
    await userEvent.click(screen.getByRole('button', { name: 'Save estimate' }));

    await waitFor(() => expect(writes.updateJobPricing).toHaveBeenCalledTimes(1));
    const [id, edit] = writes.updateJobPricing.mock.calls[0];
    expect(id).toBe('job-1');
    expect(edit.laborRate).toBe(100);
    expect(edit.materials).toHaveLength(1);
    expect(edit.materials[0]).toMatchObject({ name: 'Pipe', quantity: 1, unitCost: 25 });
    // labor 4×100=400; material 25×1 (0% markup); overhead/margin 0; fee 0 → 425.
    expect(edit.estimateTotal).toBeCloseTo(425, 2);
    expect(retry).toHaveBeenCalledWith(['jobs']);
  });

  it('rejects a blank pricing field', async () => {
    store.jobs = [job({ status: 'lead' })];
    renderScreen();
    await userEvent.click(screen.getByRole('button', { name: 'Edit estimate' }));
    await userEvent.clear(screen.getByLabelText('Labor rate ($/hr)'));
    await userEvent.click(screen.getByRole('button', { name: 'Save estimate' }));

    expect(screen.getByRole('alert')).toHaveTextContent(/non-negative number/i);
    expect(writes.updateJobPricing).not.toHaveBeenCalled();
  });

  it('authors a direct-cost line and writes it as a passthrough permit', async () => {
    store.jobs = [job({ status: 'lead' })];
    renderScreen();
    await userEvent.click(screen.getByRole('button', { name: 'Edit estimate' }));

    await userEvent.click(screen.getByRole('button', { name: '+ Add cost' }));
    await userEvent.type(screen.getByLabelText('Cost description'), 'City permit');
    // Category defaults to "other" (priced in); switch to Permit → passthrough.
    await userEvent.selectOptions(screen.getByLabelText('Cost category'), 'permit');
    const cost = screen.getByLabelText('Cost unit cost');
    await userEvent.clear(cost);
    await userEvent.type(cost, '120');
    await userEvent.click(screen.getByRole('button', { name: 'Save estimate' }));

    await waitFor(() => expect(writes.updateJobPricing).toHaveBeenCalledTimes(1));
    const edit = writes.updateJobPricing.mock.calls[0][1];
    expect(edit.jobCosts).toHaveLength(1);
    expect(edit.jobCosts[0]).toMatchObject({
      label: 'City permit',
      category: 'permit',
      unitCost: 120,
      markupPolicy: 'passthrough', // re-derived from the category
    });
    // A passthrough permit is added on top at cost, so the total grew by 120.
    // job(): labor 4×90=360, no materials/markup/overhead/margin → 360; + 120 = 480.
    expect(edit.estimateTotal).toBeCloseTo(480, 2);
  });

  it('seeds the direct-cost editor from the job and round-trips hidden knobs', async () => {
    store.jobs = [
      job({
        status: 'lead',
        jobCosts: [
          {
            id: 'jc1',
            label: 'Sub',
            category: 'subcontractor',
            quantity: 1,
            unitCost: 500,
            markupPercent: 15,
            markupPolicy: 'in_margin_base',
            taxable: true,
            customerVisible: false,
          },
        ],
      } as Partial<Job>),
    ];
    renderScreen();
    await userEvent.click(screen.getByRole('button', { name: 'Edit estimate' }));
    expect(screen.getByDisplayValue('Sub')).toBeInTheDocument();
    await userEvent.click(screen.getByRole('button', { name: 'Save estimate' }));

    await waitFor(() => expect(writes.updateJobPricing).toHaveBeenCalledTimes(1));
    // The unshown knobs (markupPercent / taxable / customerVisible) round-trip.
    expect(writes.updateJobPricing.mock.calls[0][1].jobCosts[0]).toMatchObject({
      markupPercent: 15,
      taxable: true,
      customerVisible: false,
    });
  });

  it('locks the estimate once the customer has decided', () => {
    store.jobs = [
      job({ status: 'approved', approval: { decision: 'approved' } } as Partial<Job>),
    ];
    renderScreen();
    expect(screen.getByText(/locked/i)).toBeInTheDocument();
    expect(screen.queryByRole('button', { name: 'Edit estimate' })).toBeNull();
  });

  it('keeps the error visible when the pricing write fails', async () => {
    store.jobs = [job({ status: 'lead' })];
    writes.updateJobPricing.mockRejectedValueOnce(new Error('rls denied'));
    renderScreen();
    await userEvent.click(screen.getByRole('button', { name: 'Edit estimate' }));
    await userEvent.click(screen.getByRole('button', { name: 'Save estimate' }));

    expect(await screen.findByRole('alert')).toHaveTextContent('rls denied');
    expect(retry).not.toHaveBeenCalled();
  });
});
