import { describe, it, expect, vi, beforeEach } from 'vitest';
import { render, screen, waitFor, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { MemoryRouter } from 'react-router-dom';
import type { Job, Settings } from '@shared/types/models';
import CalendarScreen from './CalendarScreen';

const writes = vi.hoisted(() => ({ scheduleJob: vi.fn() }));
vi.mock('../lib/writeRepository', () => writes);

const retry = vi.hoisted(() => vi.fn());
const store = vi.hoisted(() => ({
  jobs: [] as Job[],
  settings: null as Settings | null,
}));
vi.mock('../lib/DataContext', () => ({
  useData: () => ({ jobs: store.jobs, settings: store.settings, retry }),
  useResources: () => ({ loading: false, error: null, refreshing: false, retry }),
}));

function job(over: Partial<Job> = {}): Job {
  return {
    id: 'j1',
    customerId: 'c1',
    customerName: 'Acme',
    title: 'Fix sink',
    status: 'approved',
    scheduledDate: null,
    scheduledStartTime: null,
    scheduledEndTime: null,
    estimateTotal: 400,
    createdAt: '2026-08-01',
    ...over,
  } as Job;
}

function renderScreen() {
  return render(
    <MemoryRouter>
      <CalendarScreen />
    </MemoryRouter>,
  );
}

beforeEach(() => {
  writes.scheduleJob.mockReset().mockResolvedValue(job());
  retry.mockReset();
  store.jobs = [job()];
  store.settings = null;
});

describe('CalendarScreen — schedule a job that needs a date', () => {
  it('assigns a date (and optional time) via scheduleJob and refreshes', async () => {
    renderScreen();
    const row = screen.getByText('Fix sink').closest('.row') as HTMLElement;
    await userEvent.click(within(row).getByRole('button', { name: 'Schedule' }));

    const dateInput = within(row).getByLabelText('Date');
    await userEvent.clear(dateInput);
    await userEvent.type(dateInput, '2026-09-10');
    await userEvent.type(within(row).getByLabelText('Start (optional)'), '09:00');
    await userEvent.type(within(row).getByLabelText('End (optional)'), '11:00');
    await userEvent.click(within(row).getByRole('button', { name: 'Schedule job' }));

    await waitFor(() => expect(writes.scheduleJob).toHaveBeenCalledTimes(1));
    expect(writes.scheduleJob).toHaveBeenCalledWith(
      'j1',
      {
        scheduledDate: '2026-09-10',
        scheduledStartTime: '09:00',
        scheduledEndTime: '11:00',
      },
      job(),
    );
    expect(retry).toHaveBeenCalledWith(['jobs']);
  });

  it('schedules with no time (anytime) when times are left blank', async () => {
    renderScreen();
    const row = screen.getByText('Fix sink').closest('.row') as HTMLElement;
    await userEvent.click(within(row).getByRole('button', { name: 'Schedule' }));

    const dateInput = within(row).getByLabelText('Date');
    await userEvent.clear(dateInput);
    await userEvent.type(dateInput, '2026-09-10');
    await userEvent.click(within(row).getByRole('button', { name: 'Schedule job' }));

    await waitFor(() => expect(writes.scheduleJob).toHaveBeenCalledTimes(1));
    expect(writes.scheduleJob).toHaveBeenCalledWith(
      'j1',
      {
        scheduledDate: '2026-09-10',
        scheduledStartTime: null,
        scheduledEndTime: null,
      },
      job(),
    );
  });

  it('rejects an end time before the start without writing', async () => {
    renderScreen();
    const row = screen.getByText('Fix sink').closest('.row') as HTMLElement;
    await userEvent.click(within(row).getByRole('button', { name: 'Schedule' }));

    const dateInput = within(row).getByLabelText('Date');
    await userEvent.clear(dateInput);
    await userEvent.type(dateInput, '2026-09-10');
    await userEvent.type(within(row).getByLabelText('Start (optional)'), '11:00');
    await userEvent.type(within(row).getByLabelText('End (optional)'), '09:00');
    await userEvent.click(within(row).getByRole('button', { name: 'Schedule job' }));

    await waitFor(() =>
      expect(within(row).getByRole('alert')).toHaveTextContent(/after the start time/i),
    );
    expect(writes.scheduleJob).not.toHaveBeenCalled();
    expect(retry).not.toHaveBeenCalled();
  });

  it('surfaces a write error and keeps the form open', async () => {
    writes.scheduleJob.mockRejectedValue(new Error('rls denied'));
    renderScreen();
    const row = screen.getByText('Fix sink').closest('.row') as HTMLElement;
    await userEvent.click(within(row).getByRole('button', { name: 'Schedule' }));
    await userEvent.click(within(row).getByRole('button', { name: 'Schedule job' }));

    await waitFor(() =>
      expect(within(row).getByRole('alert')).toHaveTextContent('rls denied'),
    );
    expect(within(row).getByRole('button', { name: 'Schedule job' })).toBeInTheDocument();
    expect(retry).not.toHaveBeenCalled();
  });

  it('only lists approved/scheduled jobs without a date under Needs scheduling', () => {
    store.jobs = [
      job({ id: 'j1', title: 'Approved no date', status: 'approved' }),
      job({ id: 'j2', title: 'Already scheduled', status: 'scheduled', scheduledDate: '2026-09-01' }),
      job({ id: 'j3', title: 'Just a lead', status: 'lead' }),
    ];
    renderScreen();
    expect(screen.getByText('Needs scheduling (1)')).toBeInTheDocument();
    expect(screen.getByText('Approved no date')).toBeInTheDocument();
    expect(screen.queryByText('Just a lead')).not.toBeInTheDocument();
  });
});
