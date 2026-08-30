import { describe, it, expect, vi } from 'vitest';
import { render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { MemoryRouter } from 'react-router-dom';
import type { Job } from '@shared/types/models';
import JobsScreen from './JobsScreen';

const jobs: Job[] = [
  { id: 'j1', status: 'in_progress', title: 'Active Job', createdAt: '2026-08-03' },
  { id: 'j2', status: 'paid', title: 'Paid Job', createdAt: '2026-08-02' },
  { id: 'j3', status: 'lead', title: 'Lead Job', createdAt: '2026-08-01' },
] as Job[];

vi.mock('../lib/DataContext', () => ({
  useData: () => ({ jobs }),
  useResources: () => ({
    loading: false,
    error: null,
    refreshing: false,
    retry: vi.fn(),
  }),
}));

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
