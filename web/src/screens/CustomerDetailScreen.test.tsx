import { describe, it, expect, vi, beforeEach } from 'vitest';
import { render, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { MemoryRouter, Routes, Route } from 'react-router-dom';
import type { Customer } from '@shared/types/models';
import { getTodayDateString } from '@shared/utils/dateHelpers';
import CustomerDetailScreen from './CustomerDetailScreen';

const writes = vi.hoisted(() => ({
  saveCustomer: vi.fn(),
  deleteCustomer: vi.fn(),
}));
vi.mock('../lib/writeRepository', () => writes);

const navigate = vi.hoisted(() => vi.fn());
vi.mock('react-router-dom', async (importOriginal) => ({
  ...(await importOriginal<typeof import('react-router-dom')>()),
  useNavigate: () => navigate,
}));

const retry = vi.hoisted(() => vi.fn());
const store = vi.hoisted(() => ({ customers: [] as Customer[] }));
vi.mock('../lib/DataContext', () => ({
  useData: () => ({
    customers: store.customers,
    jobs: [],
    invoices: [],
    notes: {},
    retry,
  }),
  useResources: () => ({ loading: false, error: null, refreshing: false, retry }),
}));

function customer(over: Partial<Customer> = {}): Customer {
  return {
    id: 'c1',
    name: 'Acme',
    email: 'a@b.co',
    phone: '555',
    address: '1 St',
    notes: '',
    ...over,
  };
}

function renderScreen() {
  return render(
    <MemoryRouter initialEntries={['/customers/c1']}>
      <Routes>
        <Route path="/customers/:id" element={<CustomerDetailScreen />} />
      </Routes>
    </MemoryRouter>,
  );
}

beforeEach(() => {
  writes.saveCustomer.mockReset().mockResolvedValue(customer());
  writes.deleteCustomer.mockReset().mockResolvedValue(undefined);
  retry.mockReset();
  navigate.mockReset();
  store.customers = [customer()];
});

describe('CustomerDetailScreen — edit', () => {
  it('saves edited fields via saveCustomer and refreshes', async () => {
    renderScreen();
    await userEvent.click(screen.getByRole('button', { name: 'Edit customer' }));

    const nameInput = screen.getByDisplayValue('Acme');
    await userEvent.clear(nameInput);
    await userEvent.type(nameInput, 'Acme Renovations');
    await userEvent.click(screen.getByRole('button', { name: 'Save changes' }));

    await waitFor(() => expect(writes.saveCustomer).toHaveBeenCalledTimes(1));
    expect(writes.saveCustomer.mock.calls[0][0]).toMatchObject({
      id: 'c1',
      name: 'Acme Renovations',
    });
    expect(retry).toHaveBeenCalledWith(['customers']);
  });

  it('requires a name', async () => {
    renderScreen();
    await userEvent.click(screen.getByRole('button', { name: 'Edit customer' }));
    await userEvent.clear(screen.getByDisplayValue('Acme'));
    await userEvent.click(screen.getByRole('button', { name: 'Save changes' }));

    expect(screen.getByRole('alert')).toHaveTextContent(/name is required/i);
    expect(writes.saveCustomer).not.toHaveBeenCalled();
  });
});

describe('CustomerDetailScreen — archive', () => {
  it('archives via saveCustomer (archivedAt stamped) and leaves the detail view', async () => {
    renderScreen();
    await userEvent.click(screen.getByRole('button', { name: 'Archive' }));

    await waitFor(() => expect(writes.saveCustomer).toHaveBeenCalledTimes(1));
    expect(writes.saveCustomer.mock.calls[0][0]).toMatchObject({
      id: 'c1',
      archivedAt: getTodayDateString(),
    });
    expect(navigate).toHaveBeenCalledWith('/customers');
  });

  it('shows an Unarchive action and Archived badge for an archived customer', () => {
    store.customers = [customer({ archivedAt: '2026-08-01' })];
    renderScreen();
    expect(screen.getByText('Archived')).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Unarchive' })).toBeInTheDocument();
  });
});

describe('CustomerDetailScreen — delete', () => {
  it('deletes after confirmation and navigates to the list', async () => {
    renderScreen();
    await userEvent.click(screen.getByRole('button', { name: 'Edit customer' }));
    await userEvent.click(screen.getByRole('button', { name: 'Delete customer' }));
    await userEvent.click(screen.getByRole('button', { name: 'Delete' }));

    await waitFor(() =>
      expect(writes.deleteCustomer).toHaveBeenCalledWith('c1'),
    );
    expect(navigate).toHaveBeenCalledWith('/customers');
  });
});
