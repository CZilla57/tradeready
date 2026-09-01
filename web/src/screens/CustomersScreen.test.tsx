import { describe, it, expect, vi, beforeEach } from 'vitest';
import { render, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { MemoryRouter } from 'react-router-dom';
import type { Customer, Invoice } from '@shared/types/models';
import CustomersScreen from './CustomersScreen';

const writes = vi.hoisted(() => ({ createCustomer: vi.fn() }));
vi.mock('../lib/writeRepository', () => writes);

const navigate = vi.hoisted(() => vi.fn());
vi.mock('react-router-dom', async (importOriginal) => ({
  ...(await importOriginal<typeof import('react-router-dom')>()),
  useNavigate: () => navigate,
}));

const retry = vi.hoisted(() => vi.fn());
const store = vi.hoisted(() => ({
  customers: [] as Customer[],
  invoices: [] as Invoice[],
}));
vi.mock('../lib/DataContext', () => ({
  useData: () => ({ customers: store.customers, invoices: store.invoices, retry }),
  useResources: () => ({ loading: false, error: null, refreshing: false, retry }),
}));

function customer(over: Partial<Customer> = {}): Customer {
  return { id: 'c1', name: 'Acme', email: '', phone: '', address: '', notes: '', ...over };
}

function renderScreen() {
  return render(
    <MemoryRouter>
      <CustomersScreen />
    </MemoryRouter>,
  );
}

beforeEach(() => {
  writes.createCustomer.mockReset().mockResolvedValue(customer({ id: 'c-new', name: 'New Co' }));
  navigate.mockReset();
  retry.mockReset();
  store.customers = [customer()];
  store.invoices = [];
});

describe('CustomersScreen — create', () => {
  it('creates a customer and navigates to the new record', async () => {
    renderScreen();
    await userEvent.click(screen.getByRole('button', { name: 'New customer' }));

    await userEvent.type(screen.getByLabelText('Name'), 'New Co');
    await userEvent.type(screen.getByLabelText('Phone'), '555-9000');
    await userEvent.type(screen.getByLabelText('Email'), 'new@co.com');
    await userEvent.click(screen.getByRole('button', { name: 'Create customer' }));

    await waitFor(() => expect(writes.createCustomer).toHaveBeenCalledTimes(1));
    expect(writes.createCustomer).toHaveBeenCalledWith({
      name: 'New Co',
      email: 'new@co.com',
      phone: '555-9000',
      address: '',
      notes: '',
    });
    expect(navigate).toHaveBeenCalledWith('/customers/c-new');
  });

  it('requires a name', async () => {
    renderScreen();
    await userEvent.click(screen.getByRole('button', { name: 'New customer' }));
    await userEvent.click(screen.getByRole('button', { name: 'Create customer' }));

    expect(screen.getByRole('alert')).toHaveTextContent(/name is required/i);
    expect(writes.createCustomer).not.toHaveBeenCalled();
  });

  it('blocks a duplicate name (case-insensitive) instead of creating one', async () => {
    store.customers = [customer({ id: 'c1', name: 'Acme' })];
    renderScreen();
    await userEvent.click(screen.getByRole('button', { name: 'New customer' }));
    await userEvent.type(screen.getByLabelText('Name'), '  acme  ');
    await userEvent.click(screen.getByRole('button', { name: 'Create customer' }));

    expect(screen.getByRole('alert')).toHaveTextContent(/already exists/i);
    expect(writes.createCustomer).not.toHaveBeenCalled();
  });

  it('allows a name that clashes only with an archived customer', async () => {
    store.customers = [customer({ id: 'c1', name: 'Acme', archivedAt: '2026-01-01' })];
    renderScreen();
    await userEvent.click(screen.getByRole('button', { name: 'New customer' }));
    await userEvent.type(screen.getByLabelText('Name'), 'Acme');
    await userEvent.click(screen.getByRole('button', { name: 'Create customer' }));

    await waitFor(() => expect(writes.createCustomer).toHaveBeenCalledTimes(1));
  });

  it('surfaces a write error and keeps the form open', async () => {
    writes.createCustomer.mockRejectedValue(new Error('rls denied'));
    renderScreen();
    await userEvent.click(screen.getByRole('button', { name: 'New customer' }));
    await userEvent.type(screen.getByLabelText('Name'), 'New Co');
    await userEvent.click(screen.getByRole('button', { name: 'Create customer' }));

    await waitFor(() =>
      expect(screen.getByRole('alert')).toHaveTextContent('rls denied'),
    );
    expect(screen.getByRole('button', { name: 'Create customer' })).toBeInTheDocument();
    expect(navigate).not.toHaveBeenCalled();
  });
});
